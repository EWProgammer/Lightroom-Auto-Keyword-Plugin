# ============================================================================
# OLLAMAKEYWORDBRIDGE.PS1
# Windows PowerShell Script for Ollama-based Keyword Suggestion
# ============================================================================
#
# PURPOSE:
# This script is called by the Lightroom plugin to generate keyword suggestions
# using Ollama's vision models. It handles Ollama installation, model downloads,
# API communication, and vision analysis of photos.
#
# USAGE:
# OllamaKeywordBridge.ps1 <ImagePath> <HistoryFile> <OutputFile> [<MaxSuggestions>] [<SettingsFile>]
#
# PARAMETERS:
#   ImagePath        - Absolute path to the photo file to analyze
#   HistoryFile      - Path to file containing previously used keywords (context)
#   OutputFile       - Path where keyword suggestions should be written
#   MaxSuggestions   - Maximum number of suggestions to generate (default: 10)
#   SettingsFile     - Path to settings file with MODEL, CPU_ONLY, etc. (optional)
#
# OUTPUT:
# Writes generated keywords to OutputFile, comma or newline separated
# Keywords can come from multiple models if the configured one isn't available
#
# FEATURES:
# - Auto-installs Ollama if not found
# - Auto-pulls vision models if not cached locally
# - Polls Ollama API until it's ready
# - Supports model specification via environment or settings file
# - Handles CPU-only mode for systems without GPU
# - Includes existing keywords in context for better suggestions
# ============================================================================

param(
    [string]$ImagePath,
    [string]$HistoryFile,
    [string]$OutputFile,
    [int]$MaxSuggestions = 10,
    [string]$SettingsFile
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-EmptyOutput {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        Set-Content -Path $Path -Value '' -NoNewline
    }
}

function Load-BridgeSettings {
    param([string]$Path)

    $settings = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $settings
    }

    foreach ($line in Get-Content -Path $Path) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '=') {
            continue
        }
        $parts = $line -split '=', 2
        $key = $parts[0].Trim()
        $value = if ($parts.Length -gt 1) { $parts[1].Trim() } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $settings[$key] = $value
        }
    }

    return $settings
}

function Resolve-OllamaBin {
    if (-not [string]::IsNullOrWhiteSpace($env:OLLAMA_BIN) -and (Test-Path $env:OLLAMA_BIN)) {
        return $env:OLLAMA_BIN
    }

    $command = Get-Command ollama -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return $command.Source
    }

    $candidates = @(
        'C:\Program Files\Ollama\ollama.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe')
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Resolve-OllamaHost {
    $ollamaHost = if ([string]::IsNullOrWhiteSpace($env:OLLAMA_HOST)) { 'http://127.0.0.1:11434' } else { $env:OLLAMA_HOST }
    if ($ollamaHost -notmatch '^https?://') {
        $ollamaHost = 'http://' + $ollamaHost
    }
    return $ollamaHost.TrimEnd('/')
}

function Test-OllamaApi {
    param([string]$OllamaHost)

    if ([string]::IsNullOrWhiteSpace($OllamaHost)) {
        return $false
    }

    try {
        Invoke-RestMethod -Uri ($OllamaHost + '/api/tags') -Method Get -TimeoutSec 5 *> $null
        return $true
    } catch {
        return $false
    }
}

function Wait-OllamaApi {
    param(
        [string]$OllamaHost,
        [int]$Seconds = 60
    )

    for ($i = 0; $i -lt $Seconds; $i++) {
        if (Test-OllamaApi -OllamaHost $OllamaHost) {
            return $true
        }
        Start-Sleep -Seconds 1
    }

    return $false
}

function Install-OllamaWindows {
    try {
        $installerScript = Invoke-RestMethod -Uri 'https://ollama.com/install.ps1'
        Invoke-Expression $installerScript
        return $true
    } catch {
        return $false
    }
}

function Save-ProcessPid {
    param(
        [int]$ProcessId,
        [string]$FilePath
    )

    $tempDir = [System.IO.Path]::GetTempPath()
    $pidFile = Join-Path $tempDir 'lrkw_ollama_started_by_plugin.pid'
    
    try {
        Set-Content -Path $pidFile -Value $ProcessId -NoNewline
    } catch {
    }
}

function Ensure-OllamaReady {
    param([hashtable]$BridgeSettings)

    $ollamaBin = Resolve-OllamaBin
    if ([string]::IsNullOrWhiteSpace($ollamaBin)) {
        if (-not (Install-OllamaWindows)) {
            return $null
        }
        $ollamaBin = Resolve-OllamaBin
        if ([string]::IsNullOrWhiteSpace($ollamaBin)) {
            return $null
        }
    }

    $ollamaHost = Resolve-OllamaHost
    if (-not (Test-OllamaApi -OllamaHost $ollamaHost)) {
        try {
            if ($BridgeSettings['CPU_ONLY'] -eq 'true') {
                $env:OLLAMA_LLM_LIBRARY = 'cpu'
            }
            $process = Start-Process -FilePath $ollamaBin -ArgumentList 'serve' -WindowStyle Hidden -PassThru
            if ($process) {
                Save-ProcessPid -ProcessId $process.Id
            }
        } catch {
        }
    }

    if (-not (Wait-OllamaApi -OllamaHost $ollamaHost -Seconds 60)) {
        return $null
    }

    return @{
        Bin = $ollamaBin
        Host = $ollamaHost
    }
}

function Test-OllamaModel {
    param(
        [string]$OllamaBin,
        [string]$Model
    )

    if ([string]::IsNullOrWhiteSpace($OllamaBin) -or [string]::IsNullOrWhiteSpace($Model)) {
        return $false
    }

    try {
        & $OllamaBin show $Model *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Resolve-OllamaModel {
    param(
        [string]$OllamaBin,
        [string]$OllamaHost,
        [hashtable]$BridgeSettings
    )

    $preferredModel = if (-not [string]::IsNullOrWhiteSpace($BridgeSettings['MODEL'])) { $BridgeSettings['MODEL'] } elseif ([string]::IsNullOrWhiteSpace($env:OLLAMA_MODEL)) { 'llava:latest' } else { $env:OLLAMA_MODEL }

    if (Test-OllamaModel -OllamaBin $OllamaBin -Model $preferredModel) {
        return $preferredModel
    }

    foreach ($candidate in @('llava:latest', 'llava:7b', 'gemma3:4b')) {
        if (Test-OllamaModel -OllamaBin $OllamaBin -Model $candidate) {
            return $candidate
        }
    }

    try {
        $pullBody = @{
            name   = $preferredModel
            stream = $false
        } | ConvertTo-Json -Depth 3 -Compress

        Invoke-RestMethod -Uri ($OllamaHost + '/api/pull') -Method Post -ContentType 'application/json' -Body $pullBody -TimeoutSec 1800 *> $null
    } catch {
        try {
            & $OllamaBin pull $preferredModel *> $null
        } catch {
        }
    }

    if (Test-OllamaModel -OllamaBin $OllamaBin -Model $preferredModel) {
        return $preferredModel
    }

    return $null
}

try {
    if ([string]::IsNullOrWhiteSpace($ImagePath) -or [string]::IsNullOrWhiteSpace($OutputFile)) {
        Write-EmptyOutput -Path $OutputFile
        exit 0
    }

    $bridgeSettings = Load-BridgeSettings -Path $SettingsFile
    $ollama = Ensure-OllamaReady -BridgeSettings $bridgeSettings
    if ($null -eq $ollama) {
        Write-EmptyOutput -Path $OutputFile
        exit 0
    }

    $ollamaBin = $ollama.Bin
    $ollamaHost = $ollama.Host
    $model = Resolve-OllamaModel -OllamaBin $ollamaBin -OllamaHost $ollamaHost -BridgeSettings $bridgeSettings
    if ([string]::IsNullOrWhiteSpace($model)) {
        Write-EmptyOutput -Path $OutputFile
        exit 0
    }

    $historyText = ''
    if (-not [string]::IsNullOrWhiteSpace($HistoryFile) -and (Test-Path $HistoryFile)) {
        $historyText = (Get-Content -Path $HistoryFile -Raw).Trim()
    }

    $promptParts = @(
        'You are a Lightroom keyword assistant. Analyze this photo and return concise Lightroom keywords only.',
        "Return about $MaxSuggestions keywords, comma-separated, no numbering, no explanations.",
        'Prefer concrete subjects, scene, action, mood, lighting, and style.'
    )

    if (-not [string]::IsNullOrWhiteSpace($historyText)) {
        $promptParts += "If relevant, align with this historical keyword style: $historyText"
    }
    if (-not [string]::IsNullOrWhiteSpace($bridgeSettings['EXISTING_KEYWORDS'])) {
        $promptParts += "Do not repeat keywords already attached to this photo: $($bridgeSettings['EXISTING_KEYWORDS'])"
    }

    $promptParts += 'Return keywords only.'
    $prompt = $promptParts -join ' '

    $imageBytes = [System.IO.File]::ReadAllBytes($ImagePath)
    $imageBase64 = [Convert]::ToBase64String($imageBytes)
    $body = @{
        model      = $model
        prompt     = $prompt
        stream     = $false
        keep_alive = '10m'
        images     = @($imageBase64)
        options    = @{
            num_ctx = if ([string]::IsNullOrWhiteSpace($bridgeSettings['NUM_CTX'])) { 2048 } else { [int]$bridgeSettings['NUM_CTX'] }
        }
    } | ConvertTo-Json -Depth 5 -Compress

    $response = Invoke-RestMethod -Uri ($ollamaHost + '/api/generate') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 300
    $text = [string]$response.response
    $text = $text -replace '[\r\n;]+', ', '
    $text = $text -replace '\s+', ' '
    $text = $text.Trim(' ', ',')

    Set-Content -Path $OutputFile -Value $text -NoNewline
    exit 0
} catch {
    Write-EmptyOutput -Path $OutputFile
    exit 0
}

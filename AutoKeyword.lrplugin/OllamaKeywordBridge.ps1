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
$DebugFile = Join-Path ([System.IO.Path]::GetTempPath()) "lrkw_ps_debug_$([datetime]::Now.Ticks).log"

function Write-DebugLog {
    param([string]$Message)
    Add-Content -Path $DebugFile -Value $Message
}

Write-DebugLog "=== OllamaKeywordBridge.ps1 Started ==="
Write-DebugLog "ImagePath: $ImagePath"
Write-DebugLog "HistoryFile: $HistoryFile"
Write-DebugLog "OutputFile: $OutputFile"
Write-DebugLog "MaxSuggestions: $MaxSuggestions"
Write-DebugLog "SettingsFile: $SettingsFile"
Write-DebugLog ""

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
        'C:\Program Files (x86)\Ollama\ollama.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Programs\Ollama\ollama.exe')
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            Write-DebugLog "Found Ollama at: $candidate"
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
        [int]$Seconds = 120
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
        [string]$StartedAt
    )

    $tempDir = [System.IO.Path]::GetTempPath()
    $pidFile = Join-Path $tempDir 'lrkw_ollama_started_by_plugin.pid'
    
    try {
        $payload = if ([string]::IsNullOrWhiteSpace($StartedAt)) { [string]$ProcessId } else { "$ProcessId|$StartedAt" }
        Set-Content -Path $pidFile -Value $payload -NoNewline
    } catch {
    }
}

function Get-ParentProcessId {
    param([int]$ProcessId)

    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        return [int]$proc.ParentProcessId
    } catch {
        return 0
    }
}

function Resolve-LightroomProcessId {
    $currentPid = $PID

    for ($i = 0; $i -lt 12 -and $currentPid -gt 0; $i++) {
        try {
            $proc = Get-Process -Id $currentPid -ErrorAction Stop
            if ($proc.ProcessName -match '(?i)lightroom') {
                return $proc.Id
            }
        } catch {
        }

        $currentPid = Get-ParentProcessId -ProcessId $currentPid
    }

    return 0
}

function Get-ProcessStartMarker {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return ''
    }

    try {
        return $Process.StartTime.ToUniversalTime().ToString('o')
    } catch {
        return ''
    }
}

function Start-OllamaWatchdog {
    param([int]$LightroomPid)

    $watchdogPath = Join-Path $PSScriptRoot 'OllamaWatchdog.ps1'
    if (-not (Test-Path $watchdogPath)) {
        Write-DebugLog "Watchdog script not found at $watchdogPath"
        return
    }

    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $watchdogPath,
            '-LightroomPID', ([string]$LightroomPid)
        ) | Out-Null
        Write-DebugLog "Started watchdog from $watchdogPath for Lightroom PID $LightroomPid"
    } catch {
        Write-DebugLog "Failed to start watchdog: $_"
    }
}

function Kill-AllOllamaProcesses {
    try {
        $processes = Get-Process ollama -ErrorAction SilentlyContinue
        if ($processes) {
            Write-DebugLog "Found $($processes.Count) Ollama process(es) to clean up"
            foreach ($proc in $processes) {
                try {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    Write-DebugLog "Killed Ollama process PID $($proc.Id)"
                } catch {
                    Write-DebugLog "Failed to kill PID $($proc.Id): $_"
                }
            }
            Start-Sleep -Milliseconds 500
        }
    } catch {
        Write-DebugLog "Error checking for existing Ollama processes: $_"
    }
}

function Test-OllamaInstallation {
    param([string]$OllamaBin)

    if ([string]::IsNullOrWhiteSpace($OllamaBin)) {
        return $false
    }

    try {
        $output = & $OllamaBin --version 2>&1
        Write-DebugLog "Ollama version check: $output"
        return $LASTEXITCODE -eq 0
    } catch {
        Write-DebugLog "Ollama version check failed: $_"
        return $false
    }
}

function Ensure-OllamaReady {
    param([hashtable]$BridgeSettings)

    $ollamaBin = Resolve-OllamaBin
    if ([string]::IsNullOrWhiteSpace($ollamaBin)) {
        Write-DebugLog "Ollama not found, attempting installation..."
        if (-not (Install-OllamaWindows)) {
            Write-DebugLog "Ollama installation failed"
            return $null
        }
        $ollamaBin = Resolve-OllamaBin
        if ([string]::IsNullOrWhiteSpace($ollamaBin)) {
            Write-DebugLog "Ollama still not found after installation attempt"
            return $null
        }
    }

    # Verify the Ollama installation is valid
    if (-not (Test-OllamaInstallation -OllamaBin $ollamaBin)) {
        Write-DebugLog "Ollama installation verification failed at: $ollamaBin"
        return $null
    }

    Write-DebugLog "Using Ollama binary: $ollamaBin"

    $ollamaHost = Resolve-OllamaHost
    Write-DebugLog "Using Ollama host: $ollamaHost"
    
    # Check if Ollama API is already responding
    if (Test-OllamaApi -OllamaHost $ollamaHost) {
        Write-DebugLog "Ollama is already running and responding"
        Start-OllamaWatchdog -LightroomPid (Resolve-LightroomProcessId)
        return @{
            Bin = $ollamaBin
            Host = $ollamaHost
        }
    }

    # API not responding, kill any stale processes and start fresh
    Write-DebugLog "Ollama API not responding, cleaning up stale processes..."
    Kill-AllOllamaProcesses

    # Ollama is not responding, try to start it
    Write-DebugLog "Starting Ollama serve..."
    try {
        if ($BridgeSettings['CPU_ONLY'] -eq 'true') {
            $env:OLLAMA_LLM_LIBRARY = 'cpu'
            Write-DebugLog "CPU_ONLY mode enabled"
        }
        $process = Start-Process -FilePath $ollamaBin -ArgumentList 'serve' -WindowStyle Hidden -PassThru -ErrorAction Stop
        if ($process) {
            Write-DebugLog "Ollama started with PID $($process.Id)"
            $lightroomPid = Resolve-LightroomProcessId
            $startedAt = Get-ProcessStartMarker -Process $process
            Save-ProcessPid -ProcessId $process.Id -StartedAt $startedAt
            Start-OllamaWatchdog -LightroomPid $lightroomPid
            Start-Sleep -Seconds 1
        }
    } catch {
        Write-DebugLog "Failed to start Ollama: $_"
        return $null
    }

    # Wait for Ollama API to become available (up to 180 seconds - longer for first startup with potential model download)
    Write-DebugLog "Waiting for Ollama API to be ready (up to 180 seconds)..."
    if (-not (Wait-OllamaApi -OllamaHost $ollamaHost -Seconds 180)) {
        Write-DebugLog "ERROR: Ollama API failed to become ready within 180 seconds"
        return $null
    }

    Write-DebugLog "Ollama is ready"
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
        Write-DebugLog "ERROR: Missing required parameters (IMAGE_PATH or OUTPUT_FILE)"
        Write-EmptyOutput -Path $OutputFile
        exit 1
    }

    Write-DebugLog "Loading bridge settings..."
    $bridgeSettings = Load-BridgeSettings -Path $SettingsFile
    Write-DebugLog "Ensuring Ollama is ready..."
    $ollama = Ensure-OllamaReady -BridgeSettings $bridgeSettings
    if ($null -eq $ollama) {
        Write-DebugLog "ERROR: Ollama failed to start or is not available"
        Write-EmptyOutput -Path $OutputFile
        Write-Error "Ollama failed to start or is not available"
        exit 1
    }

    $ollamaBin = $ollama.Bin
    $ollamaHost = $ollama.Host
    Write-DebugLog "Ollama ready at: $ollamaHost"
    
    Write-DebugLog "Resolving model..."
    $model = Resolve-OllamaModel -OllamaBin $ollamaBin -OllamaHost $ollamaHost -BridgeSettings $bridgeSettings
    if ([string]::IsNullOrWhiteSpace($model)) {
        Write-DebugLog "ERROR: No valid Ollama model available"
        Write-EmptyOutput -Path $OutputFile
        Write-Error "No valid Ollama model available. Tried: llava:latest, llava:7b, gemma3:4b"
        exit 1
    }

    Write-DebugLog "Model: $model"
    $historyText = ''
    if (-not [string]::IsNullOrWhiteSpace($HistoryFile) -and (Test-Path $HistoryFile)) {
        $historyRaw = Get-Content -Path $HistoryFile -Raw -ErrorAction SilentlyContinue
        if ($null -ne $historyRaw) {
            $historyText = [string]$historyRaw
            $historyText = $historyText.Trim()
        }
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

    Write-DebugLog "Reading image: $ImagePath"
    if (-not (Test-Path $ImagePath)) {
        Write-DebugLog "ERROR: Image file not found"
        Write-EmptyOutput -Path $OutputFile
        Write-Error "Image file not found: $ImagePath"
        exit 1
    }
    
    $imageBytes = [System.IO.File]::ReadAllBytes($ImagePath)
    Write-DebugLog "Image file size: $($imageBytes.Length) bytes"
    
    $imageBase64 = [Convert]::ToBase64String($imageBytes)
    Write-DebugLog "Image Base64 length: $($imageBase64.Length) chars"
    
    $numCtx = if ([string]::IsNullOrWhiteSpace($bridgeSettings['NUM_CTX'])) { 2048 } else { [int]$bridgeSettings['NUM_CTX'] }
    Write-DebugLog "Building API request with model: $model, num_ctx: $numCtx"
    
    $body = @{
        model      = $model
        prompt     = $prompt
        stream     = $false
        keep_alive = '10m'
        images     = @($imageBase64)
        options    = @{
            num_ctx = $numCtx
        }
    } | ConvertTo-Json -Depth 5 -Compress
    Write-DebugLog "Request body size: $($body.Length) bytes"

    Write-DebugLog "Calling Ollama API..."
    try {
        $response = Invoke-RestMethod -Uri ($ollamaHost + '/api/generate') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 300 -ErrorAction Stop
        Write-DebugLog "API call successful, response type: $($response.GetType().FullName)"
    } catch {
        Write-DebugLog "ERROR: API call failed: $_"
        Write-EmptyOutput -Path $OutputFile
        Write-Error "Ollama API call failed: $_"
        exit 1
    }
    
    if ($null -eq $response) {
        Write-DebugLog "ERROR: API response is null"
        Write-EmptyOutput -Path $OutputFile
        Write-Error "Ollama API returned null response"
        exit 1
    }
    
    Write-DebugLog "Extracting response text..."
    $text = $null
    if ($null -ne $response) {
        if ($response -is [string]) {
            $text = $response.Trim()
            Write-DebugLog "Response is string type: $($text.Length) chars"
        } elseif ($null -ne $response.response) {
            $text = [string]$response.response
            Write-DebugLog "Response from .response property: $($text.Length) chars"
        } else {
            $text = [string]$response
            Write-DebugLog "Response converted to string: $($text.Length) chars"
        }
    }
    
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-DebugLog "ERROR: Empty response text after extraction"
        Write-EmptyOutput -Path $OutputFile
        Write-Error "Ollama model returned empty response"
        exit 1
    }
    
    $text = $text -replace '[\r\n;]+', ', '
    $text = $text -replace '\s+', ' '
    $text = $text.Trim(' ', ',')

    Write-DebugLog "Writing output to: $OutputFile"
    Set-Content -Path $OutputFile -Value $text -NoNewline
    Write-DebugLog "Success! Keywords written."
    exit 0
} catch {
    Write-DebugLog "=== EXCEPTION CAUGHT ==="
    Write-DebugLog "Error Type: $($_.Exception.GetType().FullName)"
    Write-DebugLog "Error Message: $($_.Exception.Message)"
    Write-DebugLog "Error Line: $($_.InvocationInfo.ScriptLineNumber)"
    Write-DebugLog "Full Stack: $($_.Exception.ToString())"
    Write-DebugLog ""
    
    Write-EmptyOutput -Path $OutputFile
    
    # Write error details to both stderr and the debug file
    $errorMsg = "ERROR: $($_.Exception.Message)"
    Write-Host $errorMsg -ForegroundColor Red -ErrorAction SilentlyContinue
    Write-Host "Debug Log: $DebugFile" -ForegroundColor Yellow -ErrorAction SilentlyContinue
    Write-DebugLog "Debug file written to: $DebugFile"
    
    exit 1
}

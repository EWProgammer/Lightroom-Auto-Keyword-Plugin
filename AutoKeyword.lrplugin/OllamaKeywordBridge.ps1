param(
    [string]$ImagePath,
    [string]$HistoryFile,
    [string]$OutputFile,
    [int]$MaxSuggestions = 10
)

$ErrorActionPreference = 'Stop'

function Write-EmptyOutput {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        Set-Content -Path $Path -Value '' -NoNewline
    }
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
    param([string]$OllamaBin)

    if (Test-OllamaModel -OllamaBin $OllamaBin -Model $env:OLLAMA_MODEL) {
        return $env:OLLAMA_MODEL
    }

    foreach ($candidate in @('llava:latest', 'llava:7b', 'gemma3:4b')) {
        if (Test-OllamaModel -OllamaBin $OllamaBin -Model $candidate) {
            return $candidate
        }
    }

    return $null
}

try {
    if ([string]::IsNullOrWhiteSpace($ImagePath) -or [string]::IsNullOrWhiteSpace($OutputFile)) {
        Write-EmptyOutput -Path $OutputFile
        exit 0
    }

    $ollamaBin = Resolve-OllamaBin
    if ([string]::IsNullOrWhiteSpace($ollamaBin)) {
        Write-EmptyOutput -Path $OutputFile
        exit 0
    }

    $model = Resolve-OllamaModel -OllamaBin $ollamaBin
    if ([string]::IsNullOrWhiteSpace($model)) {
        Write-EmptyOutput -Path $OutputFile
        exit 0
    }

    $ollamaHost = if ([string]::IsNullOrWhiteSpace($env:OLLAMA_HOST)) { 'http://127.0.0.1:11434' } else { $env:OLLAMA_HOST }
    if ($ollamaHost -notmatch '^https?://') {
        $ollamaHost = 'http://' + $ollamaHost
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

    $promptParts += 'Return keywords only.'
    $prompt = $promptParts -join ' '

    $imageBytes = [System.IO.File]::ReadAllBytes($ImagePath)
    $imageBase64 = [Convert]::ToBase64String($imageBytes)
    $body = @{
        model  = $model
        prompt = $prompt
        stream = $false
        images = @($imageBase64)
    } | ConvertTo-Json -Depth 5 -Compress

    $response = Invoke-RestMethod -Uri ($ollamaHost.TrimEnd('/') + '/api/generate') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 300
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

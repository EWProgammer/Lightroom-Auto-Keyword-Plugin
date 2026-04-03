# ============================================================================
# OLLAMADIAGNOSTICS.PS1
# Troubleshooting script to diagnose Ollama installation issues
# ============================================================================
# Run this script to help identify why the plugin can't find Ollama
# ============================================================================

Write-Host "Ollama Installation Diagnostic" -ForegroundColor Cyan
Write-Host "==============================" -ForegroundColor Cyan
Write-Host ""

# Check common installation paths
$candidates = @(
    'C:\Program Files\Ollama\ollama.exe',
    'C:\Program Files (x86)\Ollama\ollama.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
    (Join-Path $env:USERPROFILE 'AppData\Local\Programs\Ollama\ollama.exe')
)

Write-Host "Checking common installation paths..." -ForegroundColor Yellow
foreach ($path in $candidates) {
    if (Test-Path $path) {
        Write-Host "✓ Found: $path" -ForegroundColor Green
    } else {
        Write-Host "✗ Not found: $path" -ForegroundColor Gray
    }
}
Write-Host ""

# Check PATH
Write-Host "Checking PATH for Ollama..." -ForegroundColor Yellow
$command = Get-Command ollama -ErrorAction SilentlyContinue
if ($command) {
    Write-Host "✓ ollama command found in PATH: $($command.Source)" -ForegroundColor Green
} else {
    Write-Host "✗ ollama command not found in PATH" -ForegroundColor Red
}
Write-Host ""

# Environment variable check
Write-Host "Checking environment variables..." -ForegroundColor Yellow
if ([string]::IsNullOrWhiteSpace($env:OLLAMA_BIN)) {
    Write-Host "  OLLAMA_BIN: Not set" -ForegroundColor Gray
} else {
    Write-Host "  OLLAMA_BIN: $env:OLLAMA_BIN" -ForegroundColor Cyan
}

if ([string]::IsNullOrWhiteSpace($env:OLLAMA_HOST)) {
    Write-Host "  OLLAMA_HOST: Not set (will use default: http://127.0.0.1:11434)" -ForegroundColor Gray
} else {
    Write-Host "  OLLAMA_HOST: $env:OLLAMA_HOST" -ForegroundColor Cyan
}
Write-Host ""

# Try to run ollama --version
Write-Host "Attempting to run Ollama..." -ForegroundColor Yellow
try {
    # Try from PATH first
    $output = ollama --version 2>&1
    Write-Host "✓ Ollama version output: $output" -ForegroundColor Green
} catch {
    Write-Host "✗ Failed to run ollama --version from PATH" -ForegroundColor Red
    
    # Try common paths
    $found = $false
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            try {
                $output = & $path --version 2>&1
                Write-Host "✓ Ollama version at $path : $output" -ForegroundColor Green
                $found = $true
                break
            } catch {
                # Try next path
            }
        }
    }
    
    if (-not $found) {
        Write-Host "✗ Could not run ollama --version from any location" -ForegroundColor Red
    }
}
Write-Host ""

# Check if Ollama service is running
Write-Host "Checking if Ollama is running..." -ForegroundColor Yellow
$processes = Get-Process ollama -ErrorAction SilentlyContinue
if ($processes) {
    Write-Host "✓ Ollama process(es) running:" -ForegroundColor Green
    foreach ($proc in $processes) {
        Write-Host "  - PID $($proc.Id): $($proc.Path)" -ForegroundColor Green
    }
} else {
    Write-Host "✗ No Ollama processes currently running" -ForegroundColor Gray
}
Write-Host ""

# Check if Ollama API is responding
Write-Host "Checking Ollama API on http://127.0.0.1:11434..." -ForegroundColor Yellow
try {
    $response = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -Method Get -TimeoutSec 5 -ErrorAction Stop
    Write-Host "✓ Ollama API is responding!" -ForegroundColor Green
    Write-Host "  Models available: $($response.models.Length)" -ForegroundColor Green
    if ($response.models) {
        foreach ($model in $response.models) {
            Write-Host "    - $($model.name)" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "✗ Ollama API not responding at http://127.0.0.1:11434" -ForegroundColor Yellow
    Write-Host "  (This is normal if Ollama hasn't been started yet)" -ForegroundColor Gray
}
Write-Host ""

Write-Host "Diagnostic Complete" -ForegroundColor Cyan
Write-Host ""
Write-Host "SOLUTIONS:" -ForegroundColor Yellow
Write-Host "1. If Ollama is not found anywhere, download and install it from https://ollama.ai"
Write-Host "2. After installation, restart Lightroom to re-scan for Ollama"
Write-Host "3. If you see green checkmarks for all items, the plugin should work"
Write-Host ""

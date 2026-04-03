# ============================================================================
# OllamaWatchdog.ps1
# Monitors Lightroom process and kills Ollama when Lightroom closes
# ============================================================================

param(
    [int]$LightroomPID = 0
)

$ErrorActionPreference = 'SilentlyContinue'
$logFile = "$env:TEMP\lrkw_watchdog.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "$timestamp - $Message" -ErrorAction SilentlyContinue
}

Write-Log "=== OllamaWatchdog Started ==="
Write-Log "Lightroom PID: $LightroomPID"

function Get-LightroomPIDs {
    param([int]$RequestedPID)

    $pids = @()

    if ($RequestedPID -gt 0) {
        $p = Get-Process -Id $RequestedPID -ErrorAction SilentlyContinue
        if ($p) {
            $pids += $p.Id
        }
    }

    try {
        $ps = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match '(?i)lightroom'
        }
        if ($ps) {
            $pids += $ps.Id
        }
    } catch {
    }

    return $pids | Sort-Object -Unique
}

if ($LightroomPID -le 0) {
    Write-Log "WARNING: Invalid Lightroom PID provided: $LightroomPID. Falling back to process lookup."
} else {
    Write-Log "Lightroom PID from launcher: $LightroomPID"
}

$lrPids = Get-LightroomPIDs -RequestedPID $LightroomPID
if (-not $lrPids) {
    Write-Log "WARNING: Could not identify Lightroom process at startup. Watchdog will still run and kill Ollama if no Lightroom process is detected."
}

# Monitor for Lightroom process to exit (or disappear)
$checkCount = 0
$maxChecks = 1800  # 1 hour (checks every 2 seconds)

while ($checkCount -lt $maxChecks) {
    $lrPids = Get-LightroomPIDs -RequestedPID $LightroomPID
    if (-not $lrPids) {
        Write-Log "No Lightroom process found in watch loop (or it exited). Killing Ollama."
        break
    }

    Start-Sleep -Seconds 2
    $checkCount++
}

if ($checkCount -ge $maxChecks) {
    Write-Log "Timeout reached ($maxChecks checks). Assuming Lightroom has exited; killing Ollama anyway."
}

# Lightroom has closed - kill all Ollama processes
Write-Log "Executing taskkill for Ollama..."
$killOutput = taskkill /F /IM ollama.exe 2>&1
Write-Log "taskkill output: $killOutput"

# Wait a moment and try again to be sure
Start-Sleep -Seconds 1
$ollama = Get-Process -Name ollama -ErrorAction SilentlyContinue
if ($ollama) {
    Write-Log "Ollama still running, trying again..."
    taskkill /F /IM ollama.exe 2>&1 | Out-Null
    Start-Sleep -Seconds 1
}

# Verify Ollama is gone
$ollama = Get-Process -Name ollama -ErrorAction SilentlyContinue
if ($ollama) {
    Write-Log "WARNING: Ollama still running after kill attempts"
} else {
    Write-Log "SUCCESS: Ollama killed successfully"
}

Write-Log "=== OllamaWatchdog Exiting ==="
exit 0


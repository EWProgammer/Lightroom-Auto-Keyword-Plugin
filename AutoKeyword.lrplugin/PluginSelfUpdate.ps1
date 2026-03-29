param(
    [string]$DownloadUrl,
    [string]$PluginPath,
    [string]$ResultFile
)

$ErrorActionPreference = 'Stop'

function Write-Result {
    param(
        [string]$Status,
        [string]$Message,
        [string]$BackupPath = ''
    )

    $lines = @(
        "status=$Status",
        "message=$Message",
        "backup=$BackupPath"
    )
    Set-Content -Path $ResultFile -Value $lines -Encoding UTF8
}

try {
    if ([string]::IsNullOrWhiteSpace($DownloadUrl) -or [string]::IsNullOrWhiteSpace($PluginPath) -or [string]::IsNullOrWhiteSpace($ResultFile)) {
        throw "Missing updater parameters."
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lrkw-update-" + [guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tempRoot "update.zip"
    $extractDir = Join-Path $tempRoot "extract"
    $pluginDirName = Split-Path -Leaf $PluginPath
    $pluginParent = Split-Path -Parent $PluginPath
    $backupPath = Join-Path $pluginParent ($pluginDirName + ".backup." + (Get-Date -Format "yyyyMMddHHmmss"))

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    Invoke-WebRequest -UseBasicParsing -Uri $DownloadUrl -OutFile $zipPath -TimeoutSec 180
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $sourcePlugin = Get-ChildItem -Path $extractDir -Recurse -Directory | Where-Object { $_.Name -eq $pluginDirName } | Select-Object -First 1 -ExpandProperty FullName
    if (-not $sourcePlugin) {
        throw "Downloaded update package did not contain $pluginDirName."
    }

    Copy-Item -LiteralPath $PluginPath -Destination $backupPath -Recurse -Force
    Copy-Item -Path (Join-Path $sourcePlugin '*') -Destination $PluginPath -Recurse -Force

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Result -Status "ok" -Message "Update installed." -BackupPath $backupPath
    exit 0
}
catch {
    try {
        Write-Result -Status "error" -Message $_.Exception.Message
    } catch {
    }
    exit 1
}

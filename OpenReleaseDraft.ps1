$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

$infoPath = Join-Path $repoRoot 'AutoKeyword.lrplugin\Info.lua'
$infoText = Get-Content -Raw -Path $infoPath

$match = [regex]::Match($infoText, 'VERSION\s*=\s*\{\s*major\s*=\s*(\d+)\s*,\s*minor\s*=\s*(\d+)\s*,\s*revision\s*=\s*(\d+)\s*,\s*build\s*=\s*(\d+)')
if (-not $match.Success) {
    throw "Could not read VERSION from $infoPath"
}

$version = '{0}.{1}.{2}.{3}' -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value, $match.Groups[4].Value
$tag = "v$version"
$title = "Release $tag"

$template = @"
New
- 

Improved
- 

Fixed
- 

Notes
- 
"@

Set-Clipboard -Value $template

$repoUrl = 'https://github.com/EWProgammer/Lightroom-Auto-Keyword-Plugin'
$releaseUrl = "$repoUrl/releases/new?tag=$tag&title=$([uri]::EscapeDataString($title))"

Start-Process $releaseUrl

Write-Host "Opened GitHub release draft for $tag"
Write-Host "A release notes template has been copied to your clipboard."

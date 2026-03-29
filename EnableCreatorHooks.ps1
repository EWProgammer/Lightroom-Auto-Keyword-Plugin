$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

git config core.hooksPath .githooks

Write-Host "Configured local git hooks for this repo."
Write-Host "Future commits from VS Code will auto-bump AutoKeyword.lrplugin/Info.lua when plugin files are staged."

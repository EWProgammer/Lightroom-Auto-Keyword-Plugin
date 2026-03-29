$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

git config --local --unset core.hooksPath

Write-Host "Disabled local creator git hooks for this repo."
Write-Host "Commits from VS Code will no longer auto-bump the plugin version."

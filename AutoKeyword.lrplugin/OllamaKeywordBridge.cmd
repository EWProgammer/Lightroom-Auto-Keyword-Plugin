@echo off
REM ============================================================================
REM OLLAMAKEYWORDBRIDGE.CMD
REM Windows Batch Script for Launching PowerShell Keyword Bridge
REM ============================================================================
REM
REM PURPOSE:
REM This is a lightweight wrapper batch script that launches the PowerShell
REM version of the Ollama keyword bridge (OllamaKeywordBridge.ps1). This is
REM necessary because Lightroom on Windows may not have proper PowerShell
REM execution permissions in all environments.
REM
REM USAGE:
REM OllamaKeywordBridge.cmd <ImagePath> <HistoryFile> <OutputFile> [<MaxSuggestions>] [<SettingsFile>]
REM
REM PARAMETERS:
REM   ImagePath        - Absolute path to the photo file to analyze
REM   HistoryFile      - Path to file containing previously used keywords
REM   OutputFile       - Path where keyword suggestions should be written
REM   MaxSuggestions   - Maximum number of suggestions (default: 10)
REM   SettingsFile     - Path to settings file with configuration options
REM
REM DETAILS:
REM This script:
REM   1. Validates input parameters
REM   2. Locates the corresponding PowerShell script
REM   3. Executes PowerShell with proper execution policies
REM   4. Passes all parameters through to the PowerShell script
REM   5. Returns the exit code from PowerShell
REM
REM ============================================================================

setlocal enableextensions

REM Parse command-line arguments
set "IMAGE_PATH=%~1"
set "HISTORY_FILE=%~2"
set "OUTPUT_FILE=%~3"
set "MAX_SUGGESTIONS=%~4"
set "SETTINGS_FILE=%~5"

REM Set default for MAX_SUGGESTIONS if not provided
if "%MAX_SUGGESTIONS%"=="" set "MAX_SUGGESTIONS=10"

REM Validate required parameters
if "%IMAGE_PATH%"=="" goto write_empty
if "%OUTPUT_FILE%"=="" goto write_empty

REM Find the PowerShell script in the same directory as this batch file
set "BRIDGE_PS1=%~dp0OllamaKeywordBridge.ps1"
if not exist "%BRIDGE_PS1%" goto write_empty

REM Execute PowerShell script with proper parameters and exit policies
powershell -NoProfile -ExecutionPolicy Bypass -File "%BRIDGE_PS1%" -ImagePath "%IMAGE_PATH%" -HistoryFile "%HISTORY_FILE%" -OutputFile "%OUTPUT_FILE%" -MaxSuggestions "%MAX_SUGGESTIONS%" -SettingsFile "%SETTINGS_FILE%"
exit /b %ERRORLEVEL%

:write_empty
REM If we get here, write an empty output file (indicates error or no suggestions)
if not "%OUTPUT_FILE%"=="" (
  >"%OUTPUT_FILE%" echo.
)
exit /b 0

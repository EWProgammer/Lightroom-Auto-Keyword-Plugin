@echo off
setlocal enableextensions

set "IMAGE_PATH=%~1"
set "HISTORY_FILE=%~2"
set "OUTPUT_FILE=%~3"
set "MAX_SUGGESTIONS=%~4"
set "SETTINGS_FILE=%~5"
if "%MAX_SUGGESTIONS%"=="" set "MAX_SUGGESTIONS=10"
if "%IMAGE_PATH%"=="" goto write_empty
if "%OUTPUT_FILE%"=="" goto write_empty

set "BRIDGE_PS1=%~dp0OllamaKeywordBridge.ps1"
if not exist "%BRIDGE_PS1%" goto write_empty

powershell -NoProfile -ExecutionPolicy Bypass -File "%BRIDGE_PS1%" -ImagePath "%IMAGE_PATH%" -HistoryFile "%HISTORY_FILE%" -OutputFile "%OUTPUT_FILE%" -MaxSuggestions "%MAX_SUGGESTIONS%" -SettingsFile "%SETTINGS_FILE%"
exit /b %ERRORLEVEL%

:write_empty
if not "%OUTPUT_FILE%"=="" (
  >"%OUTPUT_FILE%" echo.
)
exit /b 0

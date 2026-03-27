@echo off
setlocal enableextensions enabledelayedexpansion

set "IMAGE_PATH=%~1"
set "HISTORY_FILE=%~2"
set "OUTPUT_FILE=%~3"
set "MAX_SUGGESTIONS=%~4"
if "%MAX_SUGGESTIONS%"=="" set "MAX_SUGGESTIONS=10"
if "%IMAGE_PATH%"=="" goto write_empty
if "%OUTPUT_FILE%"=="" goto write_empty

where ollama >nul 2>nul
if errorlevel 1 goto write_empty

set "MODEL=%OLLAMA_MODEL%"
if "%MODEL%"=="" set "MODEL=llava:7b"
set "OLLAMA_BIN=%OLLAMA_BIN%"
if "%OLLAMA_BIN%"=="" (
  where ollama >nul 2>nul && set "OLLAMA_BIN=ollama"
)
if "%OLLAMA_BIN%"=="" if exist "C:\Program Files\Ollama\ollama.exe" set "OLLAMA_BIN=C:\Program Files\Ollama\ollama.exe"
if "%OLLAMA_BIN%"=="" goto write_empty

set "HISTORY_TEXT="
if exist "%HISTORY_FILE%" (
  set /p HISTORY_TEXT=<"%HISTORY_FILE%"
)

set "PROMPT=%IMAGE_PATH% Analyze this photo and return concise Lightroom keywords only."
set "PROMPT=%PROMPT% Return about %MAX_SUGGESTIONS% keywords, comma-separated, no numbering, no explanations."
set "PROMPT=%PROMPT% Prefer concrete subjects, scene, action, mood, and style."
set "PROMPT=%PROMPT% If relevant, align with this historical keyword style: %HISTORY_TEXT%."
set "PROMPT=%PROMPT% Return keywords only."

for /f "delims=" %%A in ('"%OLLAMA_BIN%" run "%MODEL%" "%PROMPT%" 2^>nul') do (
  >>"%OUTPUT_FILE%" <nul set /p =%%A,
)

goto done

:write_empty
if not "%OUTPUT_FILE%"=="" (
  >"%OUTPUT_FILE%" echo.
)

:done
endlocal
exit /b 0

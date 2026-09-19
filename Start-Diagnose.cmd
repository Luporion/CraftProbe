@echo off
setlocal
cd /d "%~dp0"
title Minecraft Diagnose Recorder

if "%~1"=="" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Minecraft-Diagnose-Recorder.ps1"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Minecraft-Diagnose-Recorder.ps1" -ProfilePath "%~1"
)

set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  echo.
  echo Diagnose recorder ended with exit code %EXITCODE%.
  pause
)
exit /b %EXITCODE%

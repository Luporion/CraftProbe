@echo off
setlocal
set "INVOCATION_DIR=%CD%"
set "RECORDER=%~dp0src\Minecraft-Diagnose-Recorder.ps1"
set "TUI=%~dp0tui\bin\CraftProbe.Tui.exe"
title CraftProbe

if /I "%~1"=="--cli" (
  shift
  goto :cli
)
if /I "%~1"=="--settings" goto :settings
if /I "%~1"=="--install-path" goto :install
if /I "%~1"=="--remove-path" goto :remove
if /I "%~1"=="--help" goto :help
if /I "%~1"=="--build-tui" goto :build
if /I "%~1"=="--build-companion" goto :companion
if not "%~1"=="" goto :cli
if exist "%TUI%" goto :launch-tui
echo CraftProbe Terminal.Gui TUI ist noch nicht gebaut.
echo Einmalig .\CraftProbe.cmd --build-tui ausfuehren ^(benoetigt .NET 10 SDK^).
echo Starte solange die bewaehrte CLI...
goto :cli
:launch-tui
"%TUI%"
set "CODE=%ERRORLEVEL%"
if not "%CODE%"=="0" (
  echo TUI konnte nicht gestartet werden; alternativ craftprobe --cli.
  pause
)
exit /b %CODE%
:build
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Build-TUI.ps1"
exit /b %ERRORLEVEL%
:companion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Build-Companion.ps1"
exit /b %ERRORLEVEL%
:settings
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RECORDER%" -ManageSettings
exit /b %ERRORLEVEL%
:install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RECORDER%" -InstallPath
exit /b %ERRORLEVEL%
:remove
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RECORDER%" -RemovePath
exit /b %ERRORLEVEL%
:cli
if "%~1"=="" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RECORDER%" -InvocationDirectory "%INVOCATION_DIR%"
) else if /I "%~1"=="--cli" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RECORDER%" -InvocationDirectory "%INVOCATION_DIR%"
) else if "%~2"=="" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RECORDER%" -ProfilePath "%~1" -InvocationDirectory "%INVOCATION_DIR%"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RECORDER%" -ProfilePath "%~1" -OutputPath "%~2" -InvocationDirectory "%INVOCATION_DIR%"
)
set "CODE=%ERRORLEVEL%"
if not "%CODE%"=="0" (
  echo CraftProbe CLI ended with exit code %CODE%.
  pause
)
exit /b %CODE%
:help
echo CraftProbe 0.6.3
echo    craftprobe            TUI starten, falls gebaut; sonst CLI
echo    craftprobe --cli      Alte PowerShell-CLI

echo    craftprobe --build-tui  Einmalig TUI kompilieren ^(.NET 10 SDK^)
echo    craftprobe --build-companion  Client-Mod bauen ^(Gradle + JDK 21^)
echo    craftprobe --settings    Profile und PATH verwalten ^(CLI^)
echo    craftprobe --install-path / --remove-path
exit /b 0

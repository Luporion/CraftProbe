@echo off
setlocal
set "APP_HOME=%~dp0"
rem Obtain and validate the official wrapper JAR, if needed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%APP_HOME%scripts\Ensure-GradleWrapper.ps1"
if errorlevel 1 exit /b 1
if defined JAVA_HOME (
    set "JAVA_EXE=%JAVA_HOME%\bin\java.exe"
) else (
    set "JAVA_EXE=java.exe"
)
"%JAVA_EXE%" -classpath "%APP_HOME%gradle\wrapper\gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain %*
exit /b %ERRORLEVEL%

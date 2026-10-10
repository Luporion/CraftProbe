#requires -Version 5.1
param(
    [switch]$CopyToProfile,
    [string]$ProfilePath,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $Root 'companion/NeoForge-1.21.1'
$Wrapper = Join-Path $Project 'gradlew.bat'
$Java = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin/java.exe' } else { 'java.exe' }

if ($CopyToProfile -and [string]::IsNullOrWhiteSpace($ProfilePath)) {
    throw 'Bitte mit -CopyToProfile auch -ProfilePath angeben.'
}
if (-not (Test-Path -LiteralPath $Wrapper -PathType Leaf)) {
    throw "Gradle Wrapper fehlt: $Wrapper"
}
function Get-ExecutableVersion {
    param([string]$Executable)
    # java -version writes to STDERR; a normal 2>&1 pipeline can throw
    # NativeCommandError with ErrorActionPreference=Stop on PowerShell 5.1.
    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $Executable
    $StartInfo.Arguments = '-version'
    $StartInfo.UseShellExecute = $false
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.CreateNoWindow = $true
    try {
        $Process = [System.Diagnostics.Process]::Start($StartInfo)
        $ErrorText = $Process.StandardError.ReadToEnd()
        $OutputText = $Process.StandardOutput.ReadToEnd()
        if (-not $Process.WaitForExit(15000)) {
            try { $Process.Kill() } catch {}
            throw "Zeitueberschreitung: $Executable"
        }
        if ($Process.ExitCode -ne 0) { throw "Exit $($Process.ExitCode): $ErrorText $OutputText" }
        return ($ErrorText + [Environment]::NewLine + $OutputText)
    } catch { throw "Java-Tool nicht ausfuehrbar ($Executable): $($_.Exception.Message)" }
}
$JavaVersion = Get-ExecutableVersion -Executable $Java
if ($JavaVersion -notmatch '(?m)(?:openjdk|java) version "21(?:[.\-+"]|$)') {
    throw "Companion benoetigt JDK 21. Gefunden: $JavaVersion"
}
$Javac = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin/javac.exe' } else { 'javac.exe' }
$JavacVersion = Get-ExecutableVersion -Executable $Javac
if ($JavacVersion -notmatch 'javac 21(?:[.\-+\s]|$)') {
    throw "Companion benoetigt JDK 21 javac. Gefunden: $JavacVersion"
}
Write-Host "JDK OK: $(($JavaVersion -split "\r?\n")[0])"
Write-Host 'Gradle: 8.14 Wrapper (ohne globale Installation)'
if ($CheckOnly) {
    Write-Host 'Build-Voraussetzungen vorhanden. Wrapper/NeoForge-Abhaengigkeiten werden beim eigentlichen Build heruntergeladen.' -ForegroundColor Green
    return
}
Push-Location -LiteralPath $Project
try {
    & $Wrapper build --no-daemon --console=plain
    if ($LASTEXITCODE -ne 0) { throw "Companion Build fehlgeschlagen (Exit $LASTEXITCODE). Siehe docs/COMPANION.md" }
} finally { Pop-Location }
$Jar = Get-ChildItem -LiteralPath (Join-Path $Project 'build/libs') -Filter 'craftprobe_companion-*.jar' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '(sources|plain)' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $Jar -or $Jar.Length -le 0) { throw 'Companion-Mod-JAR fehlt oder ist leer.' }
Write-Host "Companion-Mod fertig: $($Jar.FullName)" -ForegroundColor Green
if ($CopyToProfile) {
    $Dest = Join-Path $ProfilePath 'mods'
    if (-not (Test-Path -LiteralPath $Dest -PathType Container)) { throw "Kein mods-Ordner: $Dest" }
    Copy-Item -LiteralPath $Jar.FullName -Destination (Join-Path $Dest $Jar.Name) -Force
    Write-Host "Kopiert nach: $Dest"
}

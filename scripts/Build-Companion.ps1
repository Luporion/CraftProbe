param([switch]$CopyToProfile, [string]$ProfilePath)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $Root 'companion/NeoForge-1.21.1'
$Gradle = Get-Command gradle -ErrorAction SilentlyContinue
if (-not $Gradle) { throw 'Gradle 8.x ist nicht im PATH. Gradle installieren oder GitHub Actions Build-Artefakt verwenden. Siehe docs/COMPANION.md' }
& $Gradle.Source -p $Project build
if ($LASTEXITCODE -ne 0) { throw "Companion Build fehlgeschlagen: $LASTEXITCODE" }
$Jar = Get-ChildItem -LiteralPath (Join-Path $Project 'build/libs') -Filter 'craftprobe_companion-*.jar' | Where-Object { $_.Name -notmatch '(sources|plain)' } | Select-Object -First 1
if (-not $Jar) { throw 'Companion-Mod-JAR nicht gefunden.' }
Write-Host "Companion-Mod fertig: $($Jar.FullName)"
if ($CopyToProfile) {
    if (-not $ProfilePath) { throw 'Bitte -ProfilePath angeben.' }
    $Dest = Join-Path $ProfilePath 'mods'
    if (-not (Test-Path -LiteralPath $Dest -PathType Container)) { throw "Kein mods-Ordner: $Dest" }
    Copy-Item -LiteralPath $Jar.FullName -Destination (Join-Path $Dest $Jar.Name)
    Write-Host "Kopiert nach: $Dest"
}

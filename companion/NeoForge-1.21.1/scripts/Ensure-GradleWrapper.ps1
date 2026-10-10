#requires -Version 5.1
# Verified on first use; no globally installed Gradle is required.
param()
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Jar = Join-Path $Root 'gradle/wrapper/gradle-wrapper.jar'
$Expected = '7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172'
$Urls = @(
    'https://raw.githubusercontent.com/gradle/gradle/v8.14.0/gradle/wrapper/gradle-wrapper.jar',
    'https://services.gradle.org/distributions/gradle-8.14-wrapper.jar'
)
if (Test-Path -LiteralPath $Jar -PathType Leaf) {
    $Actual = (Get-FileHash -LiteralPath $Jar -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) {
        throw "Unsichere/falsche Gradle Wrapper-JAR: $Jar`nErwartet: $Expected`nGefunden: $Actual"
    }
    exit 0
}
$Parent = Split-Path -Parent $Jar
[void](New-Item -ItemType Directory -Path $Parent -Force)
$Temp = Join-Path $Parent ('.gradle-wrapper-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    Write-Host 'Lade verifizierten Gradle 8.14 Wrapper (einmalig)...'
    # On Windows PowerShell 5.1, force modern TLS for Gradle's distribution endpoint.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Downloaded = $false
    $LastDownloadError = $null
    foreach ($Candidate in $Urls) {
        try {
            if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp -Force }
            Write-Host "  Quelle: $Candidate"
            Invoke-WebRequest -Uri $Candidate -OutFile $Temp -UseBasicParsing -ErrorAction Stop
            $Actual = (Get-FileHash -LiteralPath $Temp -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($Actual -ne $Expected) {
                # Security error: never try another mirror after a checksum mismatch.
                throw "SHA256-Pruefung fehlgeschlagen: $Actual (erwartet $Expected)"
            }
            $Downloaded = $true
            break
        } catch {
            if ($_.Exception.Message -like 'SHA256-Pruefung fehlgeschlagen*') { throw }
            $LastDownloadError = $_.Exception.Message
            Write-Warning "Wrapper-Download fehlgeschlagen: $LastDownloadError"
        }
    }
    if (-not $Downloaded) { throw "Keine Wrapper-Quelle erreichbar. Letzter Fehler: $LastDownloadError" }
    if (Test-Path -LiteralPath $Jar -PathType Leaf) {
        $Existing = (Get-FileHash -LiteralPath $Jar -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Existing -ne $Expected) { throw 'Bestehende Wrapper-JAR hat falsche SHA256.' }
    } else {
        Move-Item -LiteralPath $Temp -Destination $Jar
    }
    Write-Host 'Gradle Wrapper-JAR verifiziert.' -ForegroundColor Green
} catch {
    throw "Gradle Wrapper konnte nicht sicher geladen werden. Internetzugriff auf GitHub oder Gradle pruefen: $($_.Exception.Message)"
} finally {
    if (Test-Path -LiteralPath $Temp -PathType Leaf) { Remove-Item -LiteralPath $Temp -Force }
}

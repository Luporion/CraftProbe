#requires -Version 5.1
# Download and verify the official Gradle 8.14 wrapper JAR. Global Gradle not required.
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-CraftProbeSha256.ps1')

$Root = Split-Path -Parent $PSScriptRoot
$Jar = Join-Path $Root 'gradle/wrapper/gradle-wrapper.jar'
$Expected = '7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172'
$Url = 'https://raw.githubusercontent.com/gradle/gradle/v8.14.0/gradle/wrapper/gradle-wrapper.jar'

# Always validate cached binaries, even on subsequent executions.
if (Test-Path -LiteralPath $Jar -PathType Leaf) {
    $Actual = Get-CraftProbeSha256 -LiteralPath $Jar
    if ($Actual -ne $Expected) {
        throw "Gradle Wrapper-JAR hat eine ungueltige SHA-256-Pruefsumme.`nDatei: $Jar`nErwartet: $Expected`nGefunden: $Actual`nDatei pruefen; keine Ausfuehrung."
    }
    Write-Host 'Gradle Wrapper-JAR bereits vorhanden und SHA-256 verifiziert.' -ForegroundColor Green
    exit 0
}

$Parent = Split-Path -Parent $Jar
[void](New-Item -ItemType Directory -Path $Parent -Force)
$Temp = Join-Path $Parent ('.gradle-wrapper-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    Write-Host 'Lade Gradle 8.14 Wrapper-JAR (einmalig, SHA-256-geprueft)...'
    Write-Host "  Quelle: $Url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # Only download errors are caught here: hash and filesystem failures are not labelled as network errors.
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Temp -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "Wrapper-DOWNLOAD fehlgeschlagen ($Url): $($_.Exception.Message). Netzwerk, Proxy oder TLS pruefen."
    }

    if (-not (Test-Path -LiteralPath $Temp -PathType Leaf)) {
        throw "Wrapper-DOWNLOAD fehlgeschlagen: Es wurde keine Datei erstellt: $Temp"
    }
    $Actual = Get-CraftProbeSha256 -LiteralPath $Temp
    if ($Actual -ne $Expected) {
        throw "Wrapper-SHA256 fehlgeschlagen. Download wird NICHT ausgefuehrt.`nErwartet: $Expected`nGefunden: $Actual`nQuelle: $Url"
    }

    # A concurrent run may have placed the JAR; do not overwrite a potentially suspicious file.
    if (Test-Path -LiteralPath $Jar -PathType Leaf) {
        $Existing = Get-CraftProbeSha256 -LiteralPath $Jar
        if ($Existing -ne $Expected) {
            throw "Wrapper-SHA256 fehlgeschlagen: bereits vorhandene JAR wurde waehrend des Downloads geaendert: $Jar"
        }
    }
    else {
        try {
            Move-Item -LiteralPath $Temp -Destination $Jar -ErrorAction Stop
        }
        catch {
            throw "Wrapper-DATEISYSTEM fehlgeschlagen beim Speichern nach $Jar : $($_.Exception.Message)"
        }
    }
    Write-Host 'Gradle Wrapper-JAR erfolgreich SHA-256-verifiziert.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $Temp -PathType Leaf) {
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    }
}

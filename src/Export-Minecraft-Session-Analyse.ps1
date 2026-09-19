#requires -Version 5.1

param(
    [string]$ProfilePath,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$RunStarted = Get-Date
$ExporterVersion = "0.1.0"
$SessionToleranceMinutes = 2

# ============================================================
# Portable Minecraft Session Analysis Export
# Works with CurseForge, PrismLauncher/MultiMC, Modrinth App and
# other launchers as long as a normal Minecraft game directory
# (mods/config/logs/saves/...) is available.
# ============================================================

function Test-MinecraftProfileRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $Full=(Get-Item -LiteralPath $Path -ErrorAction Stop).FullName } catch { return $false }
    $Markers=@('mods','config','logs','saves','resourcepacks','shaderpacks','options.txt','defaultconfigs','kubejs')
    $Found=0
    foreach($Marker in $Markers){ if(Test-Path -LiteralPath (Join-Path $Full $Marker)){ $Found++ } }
    return ($Found -ge 2)
}

function Resolve-MinecraftProfilePath {
    param([string]$RequestedPath)
    $RepoParent = Split-Path -Parent $PSScriptRoot
    $RepoGrandParent = Split-Path -Parent $RepoParent
    foreach($Candidate in @($RequestedPath,(Get-Location).Path,$PSScriptRoot,$RepoParent,$RepoGrandParent) | Select-Object -Unique){
        if(-not $Candidate){continue}
        try{$Full=(Get-Item -LiteralPath $Candidate -ErrorAction Stop).FullName.TrimEnd('\')}catch{continue}
        if(Test-MinecraftProfileRoot $Full){return $Full}
        $Dot=Join-Path $Full '.minecraft'
        if(Test-MinecraftProfileRoot $Dot){return (Get-Item -LiteralPath $Dot).FullName.TrimEnd('\')}
    }
    throw 'No plausible Minecraft profile directory supplied.'
}

$ProfilePath = Resolve-MinecraftProfilePath -RequestedPath $ProfilePath
$ProfileName = Split-Path -Leaf $ProfilePath
if ($ProfileName -eq '.minecraft') { $ProfileName = Split-Path -Leaf (Split-Path -Parent $ProfilePath) }
if([string]::IsNullOrWhiteSpace($OutputPath)){
    $OutputPath = Join-Path (Split-Path -Parent $ProfilePath) '_Minecraft-Diagnose-Exports'
}else{
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
}

Write-Host ""
Write-Host "============================================================"
Write-Host " Minecraft Session Diagnose Export"
Write-Host "============================================================"
Write-Host ""
Write-Host "Profil: $ProfileName"
Write-Host "Pfad:   $ProfilePath"
Write-Host "Pruefe Minecraft-Profil..."

# ============================================================
# OFFENSICHTLICH FALSCHE ORTE ABLEHNEN
# ============================================================

if ($ProfilePath -match '^[A-Za-z]:\\?$') {

    Write-Host ""
    Write-Host "ABBRUCH: Ein Laufwerksstamm ist kein Profilordner." `
        -ForegroundColor Red

    exit 1
}



$DangerousLocations = @()

if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $DangerousLocations += $env:USERPROFILE.TrimEnd("\")
}

if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
    $DangerousLocations += $env:SystemRoot.TrimEnd("\")
}

if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $DangerousLocations += $env:ProgramFiles.TrimEnd("\")
}

$ProgramFilesX86 = ${env:ProgramFiles(x86)}

if (-not [string]::IsNullOrWhiteSpace($ProgramFilesX86)) {
    $DangerousLocations += $ProgramFilesX86.TrimEnd("\")
}


foreach ($DangerousPath in $DangerousLocations) {

    if ($ProfilePath -ieq $DangerousPath) {

        Write-Host ""
        Write-Host "ABBRUCH: Das aktuelle Verzeichnis ist kein sinnvoller Profilordner." `
            -ForegroundColor Red

        exit 1
    }
}


# ============================================================
# MINECRAFT-PROFIL PRUEFEN
# ============================================================

if (-not (Test-MinecraftProfileRoot $ProfilePath)) {
    Write-Host ""
    Write-Host "ABBRUCH: Zu wenige typische Minecraft-Profilbestandteile gefunden." -ForegroundColor Red
    exit 1
}

Write-Host "Profilpruefung erfolgreich." -ForegroundColor Green


# ============================================================
# latest.log MUSS VORHANDEN SEIN
# ============================================================

$LatestLogPath = Join-Path `
    $ProfilePath `
    "logs\latest.log"


if (-not (
    Test-Path `
        -LiteralPath $LatestLogPath `
        -PathType Leaf
)) {

    Write-Host ""
    Write-Host "ABBRUCH: logs\latest.log wurde nicht gefunden." `
        -ForegroundColor Red

    Write-Host ""
    Write-Host "Ohne latest.log kann die letzte Session nicht sicher bestimmt werden."
    Write-Host "Dadurch koennten alte Crashreports faelschlich mitgenommen werden."

    exit 1
}


# ============================================================
# SESSION-START AUS latest.log ERMITTELN
# ============================================================

function Get-SessionStartFromLatestLog {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )


    $LogInfo = Get-Item -LiteralPath $Path

    $Culture = `
        [System.Globalization.CultureInfo]::InvariantCulture


    $Lines = Get-Content `
        -LiteralPath $Path `
        -TotalCount 500 `
        -ErrorAction Stop


    foreach ($Line in $Lines) {

        # ----------------------------------------------------
        # Forge / NeoForge:
        #
        # [10Sep2026 17:20:11.123] [...]
        # ----------------------------------------------------

        if (
            $Line -match `
            '^\[(\d{2}[A-Za-z]{3}\d{4} \d{2}:\d{2}:\d{2}(?:[.,]\d+)?)\]'
        ) {

            $Text = $Matches[1].Replace(",", ".")


            foreach ($Format in @(

                "ddMMMyyyy HH:mm:ss.FFFFFFF",
                "ddMMMyyyy HH:mm:ss"

            )) {

                try {

                    return [DateTime]::ParseExact(
                        $Text,
                        $Format,
                        $Culture
                    )

                }
                catch {}
            }
        }


        # ----------------------------------------------------
        # Andere Logger:
        #
        # [2026-09-10 17:20:11.123]
        # ----------------------------------------------------

        if (
            $Line -match `
            '^\[(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)\]'
        ) {

            $Text = $Matches[1]
            $Text = $Text.Replace("T", " ")
            $Text = $Text.Replace(",", ".")


            foreach ($Format in @(

                "yyyy-MM-dd HH:mm:ss.FFFFFFF",
                "yyyy-MM-dd HH:mm:ss"

            )) {

                try {

                    return [DateTime]::ParseExact(
                        $Text,
                        $Format,
                        $Culture
                    )

                }
                catch {}
            }
        }


        # ----------------------------------------------------
        # Logger mit nur Uhrzeit:
        #
        # [17:20:11] [...]
        # ----------------------------------------------------

        if (
            $Line -match `
            '^\[(\d{2}:\d{2}:\d{2})(?:[.,]\d+)?\]'
        ) {

            try {

                $TimeOfDay = [TimeSpan]::Parse(
                    $Matches[1],
                    $Culture
                )


                $Candidate = `
                    $LogInfo.LastWriteTime.Date + $TimeOfDay


                # Session ueber Mitternacht
                if (
                    $Candidate -gt
                    $LogInfo.LastWriteTime.AddMinutes(15)
                ) {

                    $Candidate = $Candidate.AddDays(-1)
                }


                return $Candidate

            }
            catch {}
        }
    }


    # --------------------------------------------------------
    # Fallback:
    # CreationTime nur akzeptieren, wenn es plausibel zur
    # aktuellen latest.log passt.
    # --------------------------------------------------------

    $Creation = $LogInfo.CreationTime
    $Modified = $LogInfo.LastWriteTime


    if (
        $Creation -le $Modified -and
        ($Modified - $Creation).TotalHours -le 24
    ) {

        return $Creation
    }


    throw "Session-Start konnte aus latest.log nicht sicher bestimmt werden."
}


Write-Host ""
Write-Host "Ermittle letzte Minecraft-Session..."


try {

    $SessionStart = `
        Get-SessionStartFromLatestLog `
            -Path $LatestLogPath

}
catch {

    Write-Host ""
    Write-Host "ABBRUCH: Session-Start konnte nicht sicher erkannt werden." `
        -ForegroundColor Red

    Write-Host $_.Exception.Message

    exit 1
}


$SessionWindowStart = `
    $SessionStart.AddMinutes(
        -$SessionToleranceMinutes
    )


Write-Host (
    "Erkannter Session-Start: " +
    $SessionStart.ToString("yyyy-MM-dd HH:mm:ss")
)


# ============================================================
# EXPORTPFADE
# ============================================================

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$SafeProfileName = `
    $ProfileName -replace '[<>:"/\\|?*]', '_'


$ExportParent = $OutputPath


$ExportName = `
    $SafeProfileName +
    "_Session-Analyse_" +
    $Timestamp


$Stage = Join-Path `
    $env:TEMP `
    $ExportName


$ZipFile = Join-Path `
    $ExportParent `
    ($ExportName + ".zip")


$HeavyExportName = `
    $SafeProfileName +
    "_Performance-Diagnose_" +
    $Timestamp


$HeavyStage = Join-Path `
    $env:TEMP `
    $HeavyExportName


$HeavyZipFile = Join-Path `
    $ExportParent `
    ($HeavyExportName + ".zip")


if (Test-Path -LiteralPath $Stage) {

    Remove-Item `
        -LiteralPath $Stage `
        -Recurse `
        -Force
}


if (Test-Path -LiteralPath $HeavyStage) {

    Remove-Item `
        -LiteralPath $HeavyStage `
        -Recurse `
        -Force
}


New-Item `
    -ItemType Directory `
    -Path $Stage `
    -Force |
    Out-Null


New-Item `
    -ItemType Directory `
    -Path $ExportParent `
    -Force |
    Out-Null


Write-Host ""
Write-Host "Exportziele:"
Write-Host ("  Analyse: " + $ZipFile)
Write-Host ("  Performance: " + $HeavyZipFile)


# ============================================================
# HILFSFUNKTIONEN
# ============================================================

function Get-ProfileRelativePath {

    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )


    $Base = $script:ProfilePath.TrimEnd("\") + "\"


    if (
        $FullPath.StartsWith(
            $Base,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {

        return $FullPath.Substring(
            $Base.Length
        )
    }


    return Split-Path -Leaf $FullPath
}


function Test-ShouldExcludeDiagnosticFile {

    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $Relative = Get-ProfileRelativePath -FullPath $File.FullName
    $Normalized = ('\' + $Relative.Replace('/','\').Trim('\') + '\').ToLowerInvariant()

    # Reine Laufzeit-/Download-/Backup-Caches liefern fuer die Diagnose
    # normalerweise keinen Mehrwert und koennen sehr gross werden.
    foreach ($Segment in @('\cache\','\caches\','\.cache\','\backup\','\backups\','\.git\','\.gradle\')) {
        if ($Normalized.Contains($Segment)) { return $true }
    }

    # Crash Assistant speichert viele historische Modlisten und eigene JAR-Kopien.
    # Fuer die aktuelle Session genuegen dessen Logs/Reports; die Historie ist redundant.
    if ($Relative -match '(?i)^local\\crash_assistant\\modlist_history\\') { return $true }
    if ($Relative -match '(?i)^local\\crash_assistant\\.*\.(jar|exe)$') { return $true }

    # Typische Editor-/Temp-Artefakte.
    if ($File.Name -match '(?i)^(thumbs\.db|desktop\.ini)$') { return $true }
    if ($File.Extension -match '(?i)^\.(tmp|bak|old)$') { return $true }

    return $false
}


function Test-IsCurrentSessionFile {

    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )


    if (
        $File.LastWriteTime -lt
        $script:SessionWindowStart
    ) {

        return $false
    }


    if (
        $File.LastWriteTime -gt
        $script:RunStarted.AddMinutes(5)
    ) {

        return $false
    }


    return $true
}


function Copy-FileInfoPreservePath {

    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )


    if (Test-ShouldExcludeDiagnosticFile -File $File) {
        return $false
    }


    $Relative = `
        Get-ProfileRelativePath `
            -FullPath $File.FullName


    $Destination = Join-Path `
        $script:Stage `
        $Relative


    $DestinationParent = `
        Split-Path -Parent $Destination


    if (-not (
        Test-Path `
            -LiteralPath $DestinationParent
    )) {

        New-Item `
            -ItemType Directory `
            -Path $DestinationParent `
            -Force |
            Out-Null
    }


    Copy-Item `
        -LiteralPath $File.FullName `
        -Destination $Destination `
        -Force
}


function Copy-FileRelative {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Relative,

        [switch]$CurrentSessionOnly
    )


    $Source = Join-Path `
        $script:ProfilePath `
        $Relative


    if (-not (
        Test-Path `
            -LiteralPath $Source `
            -PathType Leaf
    )) {

        return $false
    }


    $File = Get-Item `
        -LiteralPath $Source


    if ($CurrentSessionOnly) {

        if (-not (
            Test-IsCurrentSessionFile `
                -File $File
        )) {

            return $false
        }
    }


    Copy-FileInfoPreservePath `
        -File $File


    return $true
}


function Copy-WholeFolderRelative {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Relative
    )

    $Source = Join-Path $script:ProfilePath $Relative

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        return $false
    }

    # Nicht mehr blind den kompletten Ordner kopieren: Cache-/Backup-Dateien
    # werden durch Copy-FileInfoPreservePath gezielt ausgeschlossen.
    $Files = Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($File in $Files) {
        [void](Copy-FileInfoPreservePath -File $File)
    }

    return $true
}


function Copy-CurrentFilesFromFolder {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Relative
    )


    $Source = Join-Path `
        $script:ProfilePath `
        $Relative


    if (-not (
        Test-Path `
            -LiteralPath $Source `
            -PathType Container
    )) {

        return 0
    }


    $Count = 0


    $Files = Get-ChildItem `
        -LiteralPath $Source `
        -File `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue


    foreach ($File in $Files) {

        if (
            Test-IsCurrentSessionFile `
                -File $File
        ) {

            Copy-FileInfoPreservePath `
                -File $File

            $Count++
        }
    }


    return $Count
}


# ============================================================
# CONFIGS
# ============================================================

Write-Host ""
Write-Host "Kopiere aktuelle Modpack-Konfigurationen..."


$ConfigFolders = @(

    "config",
    "defaultconfigs",
    "kubejs",
    "local",
    "fancymenu_data"

)


$CopiedConfigFolders = 0


foreach ($Folder in $ConfigFolders) {

    if (
        Copy-WholeFolderRelative `
            -Relative $Folder
    ) {

        $CopiedConfigFolders++
    }
}


Write-Host (
    "Konfigurationsordner kopiert: " +
    $CopiedConfigFolders
)


# ============================================================
# SERVERCONFIG AUS WELTEN
# ============================================================

Write-Host "Kopiere serverconfig der vorhandenen Welten..."


$Worlds = @()
$LikelyActiveWorlds = @()
$ServerConfigCount = 0

$SavesPath = Join-Path `
    $ProfilePath `
    "saves"


if (
    Test-Path `
        -LiteralPath $SavesPath `
        -PathType Container
) {

    $Worlds = @(
        Get-ChildItem `
            -LiteralPath $SavesPath `
            -Directory `
            -Force `
            -ErrorAction SilentlyContinue
    )


    foreach ($World in $Worlds) {

        # ----------------------------------------------------
        # Versuchen zu erkennen, ob diese Welt in der
        # aktuellen Session geoeffnet wurde.
        # ----------------------------------------------------

        $IsLikelyActive = $false


        foreach ($MarkerName in @(

            "session.lock",
            "level.dat",
            "level.dat_old"

        )) {

            $MarkerPath = Join-Path `
                $World.FullName `
                $MarkerName


            if (
                Test-Path `
                    -LiteralPath $MarkerPath `
                    -PathType Leaf
            ) {

                $Marker = Get-Item `
                    -LiteralPath $MarkerPath


                if (
                    Test-IsCurrentSessionFile `
                        -File $Marker
                ) {

                    $IsLikelyActive = $true
                }
            }
        }


        if ($IsLikelyActive) {

            $LikelyActiveWorlds += $World.Name
        }


        # ----------------------------------------------------
        # serverconfig aller Welten mitnehmen.
        #
        # Die Ordner sind klein und koennen bei Fehlern sehr
        # wichtig sein. Die aktive Welt wird spaeter markiert.
        # ----------------------------------------------------

        $RelativeServerConfig = `
            "saves\" +
            $World.Name +
            "\serverconfig"


        if (
            Copy-WholeFolderRelative `
                -Relative $RelativeServerConfig
        ) {

            $ServerConfigCount++
        }
    }
}


Write-Host (
    "serverconfig-Ordner kopiert: " +
    $ServerConfigCount
)


# ============================================================
# BASISDATEIEN
# ============================================================

Write-Host "Kopiere Profil- und Optionsdateien..."


$BaseFiles = @(

    "minecraftinstance.json",
    "manifest.json",
    "instance.cfg",
    "mmc-pack.json",
    "profile.json",
    "options.txt",
    "optionsof.txt",
    "optionsshaders.txt",
    "ops.json",
    "server.properties",
    "user_jvm_args.txt"

)


foreach ($File in $BaseFiles) {

    [void](
        Copy-FileRelative `
            -Relative $File
    )
}

# PrismLauncher/MultiMC keep instance metadata next to .minecraft.
if ((Split-Path -Leaf $ProfilePath) -eq '.minecraft') {
    $InstanceParent = Split-Path -Parent $ProfilePath
    foreach ($MetaName in @('instance.cfg','mmc-pack.json')) {
        $MetaSource = Join-Path $InstanceParent $MetaName
        if (Test-Path -LiteralPath $MetaSource -PathType Leaf) {
            $MetaTargetDir = Join-Path $Stage '_launcher_metadata'
            New-Item -ItemType Directory -Path $MetaTargetDir -Force | Out-Null
            Copy-Item -LiteralPath $MetaSource -Destination (Join-Path $MetaTargetDir $MetaName) -Force
        }
    }
}


# ============================================================
# SESSION-LOGS
# ============================================================

Write-Host "Kopiere Logs der letzten Session..."


$SessionLogCount = 0


# latest.log ist per Definition die aktuelle/letzte Session
if (
    Copy-FileRelative `
        -Relative "logs\latest.log"
) {

    $SessionLogCount++
}


# debug.log nur dann, wenn es zur Session gehoert
if (
    Copy-FileRelative `
        -Relative "logs\debug.log" `
        -CurrentSessionOnly
) {

    $SessionLogCount++
}


# Explizit gewuenschte einzelne Logdateien
foreach ($Relative in @(

    "logs\instance_audit.txt",
    "logs\modlist.txt",
    "logs\stderr_stream.log",
    "logs\stdout-logs.txt",
    "logs\gpu_debug.log"

)) {

    if (
        Copy-FileRelative `
            -Relative $Relative `
            -CurrentSessionOnly
    ) {

        $SessionLogCount++
    }
}


# Explizit gewuenschte Logordner:
# NUR Dateien mit Zeitstempel aus aktueller Session
foreach ($RelativeFolder in @(

    "logs\almostunified",
    "logs\crash_assistant",
    "logs\kubejs",
    "logs\debugguardian",
    "logs\systrace",
    "logs\observable"

)) {

    $SessionLogCount += `
        Copy-CurrentFilesFromFolder `
            -Relative $RelativeFolder
}


Write-Host (
    "Session-Logdateien kopiert: " +
    $SessionLogCount
)


# Bekannte Doppelung vermeiden: einige Setups schreiben stdout-logs.txt
# byte-identisch zu latest.log. latest.log bleibt immer vollstaendig erhalten.
try {
    $LatestStageLog = Join-Path $Stage 'logs\latest.log'
    $StdoutStageLog = Join-Path $Stage 'logs\stdout-logs.txt'
    if ((Test-Path -LiteralPath $LatestStageLog) -and (Test-Path -LiteralPath $StdoutStageLog)) {
        $A = Get-Item -LiteralPath $LatestStageLog
        $B = Get-Item -LiteralPath $StdoutStageLog
        if ($A.Length -eq $B.Length) {
            $HA = (Get-FileHash -LiteralPath $A.FullName -Algorithm SHA256).Hash
            $HB = (Get-FileHash -LiteralPath $B.FullName -Algorithm SHA256).Hash
            if ($HA -eq $HB) {
                Remove-Item -LiteralPath $StdoutStageLog -Force -ErrorAction SilentlyContinue
                $SessionLogCount = [Math]::Max(0,$SessionLogCount-1)
                Write-Host 'stdout-logs.txt war identisch zu latest.log und wurde nicht doppelt gespeichert.' -ForegroundColor DarkGray
            }
        }
    }
} catch {}


# ============================================================
# CRASHREPORTS NUR AKTUELLE SESSION
# ============================================================

Write-Host "Pruefe Crashreports..."


$CrashReportCount = 0

$CrashPath = Join-Path `
    $ProfilePath `
    "crash-reports"


if (
    Test-Path `
        -LiteralPath $CrashPath `
        -PathType Container
) {

    $CrashFiles = Get-ChildItem `
        -LiteralPath $CrashPath `
        -File `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue


    foreach ($File in $CrashFiles) {

        if (
            Test-IsCurrentSessionFile `
                -File $File
        ) {

            Copy-FileInfoPreservePath `
                -File $File

            $CrashReportCount++
        }
    }
}


Write-Host (
    "Aktuelle Crashreports kopiert: " +
    $CrashReportCount
)


# ============================================================
# JVM / WINDOWS SPEZIALFEHLER
# ============================================================

Write-Host "Pruefe JVM- und Windows-Fehlerdateien..."


$SpecialCount = 0
$SpecialCandidates = @{}


# Root des Profils
$RootSpecialFiles = Get-ChildItem `
    -LiteralPath $ProfilePath `
    -File `
    -Force `
    -ErrorAction SilentlyContinue


foreach ($File in $RootSpecialFiles) {

    $SpecialCandidates[$File.FullName] = $File
}


# logs rekursiv durchsuchen
$LogsRoot = Join-Path `
    $ProfilePath `
    "logs"


if (
    Test-Path `
        -LiteralPath $LogsRoot `
        -PathType Container
) {

    $LogSpecialFiles = Get-ChildItem `
        -LiteralPath $LogsRoot `
        -File `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue


    foreach ($File in $LogSpecialFiles) {

        $SpecialCandidates[$File.FullName] = $File
    }
}


foreach ($File in $SpecialCandidates.Values) {

    if (
        $File.Name -match `
        '^(hs_err_pid\d+\.log|win_event.*\.txt|command_history\.txt)$'
    ) {

        if (
            Test-IsCurrentSessionFile `
                -File $File
        ) {

            Copy-FileInfoPreservePath `
                -File $File

            $SpecialCount++
        }
    }
}


Write-Host (
    "Aktuelle Spezialfehler-Dateien kopiert: " +
    $SpecialCount
)


# ============================================================
# SPARK
# ============================================================

Write-Host "Pruefe spark-Daten..."


$SparkCount = `
    Copy-CurrentFilesFromFolder `
        -Relative "spark"


Write-Host (
    "Aktuelle spark-Dateien kopiert: " +
    $SparkCount
)


# ============================================================
# ZUSAETZLICHE DIAGNOSE-DATEN
# ============================================================

Write-Host "Pruefe Recorder-/Diagnose-Daten..."

$ExtraDiagnosticCount = 0

foreach ($RelativeFolder in @(
    "_diagnose_recorder",
    "systrace",
    "observable",
    "debugguardian",
    "debug_guardian",
    "debug-guardian"
)) {
    $ExtraDiagnosticCount += `
        Copy-CurrentFilesFromFolder `
            -Relative $RelativeFolder
}

Write-Host (
    "Aktuelle zusaetzliche Diagnose-Dateien kopiert: " +
    $ExtraDiagnosticCount
)


# Die wichtigste Zusammenfassung zusaetzlich direkt an die ZIP-Wurzel legen.
try {
    $RecorderStage = Join-Path $Stage '_diagnose_recorder'
    if (Test-Path -LiteralPath $RecorderStage -PathType Container) {
        $LatestSummary = Get-ChildItem -LiteralPath $RecorderStage -Filter 'DIAGNOSE_SUMMARY.txt' -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($LatestSummary) {
            Copy-Item -LiteralPath $LatestSummary.FullName -Destination (Join-Path $Stage 'DIAGNOSE_SUMMARY.txt') -Force
        }
    }
} catch {}


# ============================================================
# MODLISTE MIT SHA256
# ============================================================

Write-Host "Erzeuge aktuelle Modliste mit SHA256..."


$ModListPath = Join-Path `
    $Stage `
    "_MODLISTE_AKTUELL_SHA256.txt"


$ModLines = New-Object `
    System.Collections.Generic.List[string]


[void]$ModLines.Add(
    "SIZE_BYTES`tMODIFIED`tSHA256`tPATH"
)


$ModFiles = @()


foreach ($ModFolderName in @(

    "mods",
    "disabled mods"

)) {

    $ModFolder = Join-Path `
        $ProfilePath `
        $ModFolderName


    if (
        Test-Path `
            -LiteralPath $ModFolder `
            -PathType Container
    ) {

        $Files = Get-ChildItem `
            -LiteralPath $ModFolder `
            -File `
            -Force `
            -ErrorAction SilentlyContinue |
            Where-Object {

                $_.Name -match `
                '\.jar(?:\.disabled)?$'
            }


        $ModFiles += @($Files)
    }
}


$ModFiles = @(
    $ModFiles |
    Sort-Object FullName
)


$ModIndex = 0
$ModCount = $ModFiles.Count


foreach ($Mod in $ModFiles) {

    $ModIndex++


    if ($ModCount -gt 0) {

        Write-Progress `
            -Activity "Berechne Mod-Hashes" `
            -Status ($ModIndex.ToString() + " / " + $ModCount.ToString()) `
            -PercentComplete (
                ($ModIndex / $ModCount) * 100
            )
    }


    try {

        $Hash = (
            Get-FileHash `
                -LiteralPath $Mod.FullName `
                -Algorithm SHA256
        ).Hash

    }
    catch {

        $Hash = "HASH_ERROR"
    }


    $Relative = `
        Get-ProfileRelativePath `
            -FullPath $Mod.FullName


    $Line = `
        [string]$Mod.Length +
        "`t" +
        $Mod.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") +
        "`t" +
        $Hash +
        "`t" +
        $Relative


    [void]$ModLines.Add($Line)
}


Write-Progress `
    -Activity "Berechne Mod-Hashes" `
    -Completed


Set-Content `
    -LiteralPath $ModListPath `
    -Value $ModLines `
    -Encoding UTF8


Write-Host (
    "Mods erfasst: " +
    $ModCount
)


# ============================================================
# DATAPACK-LISTE
# ============================================================

Write-Host "Erzeuge Datapack-, Resourcepack- und Schematics-Listen..."


$DatapackLines = New-Object `
    System.Collections.Generic.List[string]


[void]$DatapackLines.Add(
    "Installierte Datapacks"
)

[void]$DatapackLines.Add(
    "Hinweis: Diese Liste zeigt vorhandene Packs, nicht zwingend deren Aktivierungszustand."
)

[void]$DatapackLines.Add("")


foreach ($World in $Worlds) {

    $WorldMarker = ""


    if (
        $LikelyActiveWorlds -contains $World.Name
    ) {

        $WorldMarker = "  [CURRENT SESSION]"
    }


    [void]$DatapackLines.Add(
        "WORLD: " +
        $World.Name +
        $WorldMarker
    )


    $WorldDatapacks = Join-Path `
        $World.FullName `
        "datapacks"


    if (
        Test-Path `
            -LiteralPath $WorldDatapacks `
            -PathType Container
    ) {

        $Entries = Get-ChildItem `
            -LiteralPath $WorldDatapacks `
            -Force `
            -ErrorAction SilentlyContinue |
            Sort-Object Name


        if (@($Entries).Count -eq 0) {

            [void]$DatapackLines.Add(
                "  <leer>"
            )
        }
        else {

            foreach ($Entry in $Entries) {

                if ($Entry.PSIsContainer) {

                    $Type = "DIR "

                }
                else {

                    $Type = "FILE"
                }


                [void]$DatapackLines.Add(
                    "  " +
                    $Type +
                    "`t" +
                    $Entry.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") +
                    "`t" +
                    $Entry.Name
                )
            }
        }
    }
    else {

        [void]$DatapackLines.Add(
            "  <kein datapacks-Ordner>"
        )
    }


    [void]$DatapackLines.Add("")
}


# Weitere moegliche globale Datapackquellen nur auflisten
foreach ($GlobalPackPath in @(

    "datapacks",
    "global_packs",
    "openloader"

)) {

    $FullGlobalPath = Join-Path `
        $ProfilePath `
        $GlobalPackPath


    if (
        Test-Path `
            -LiteralPath $FullGlobalPath `
            -PathType Container
    ) {

        [void]$DatapackLines.Add(
            "PROFILE: " +
            $GlobalPackPath
        )


        Get-ChildItem `
            -LiteralPath $FullGlobalPath `
            -Force `
            -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object {

                [void]$DatapackLines.Add(
                    "  " +
                    $_.Name
                )
            }


        [void]$DatapackLines.Add("")
    }
}


Set-Content `
    -LiteralPath (Join-Path $Stage "_DATAPACK_LISTE.txt") `
    -Value $DatapackLines `
    -Encoding UTF8


# ============================================================
# RESOURCEPACK-LISTE
# ============================================================

$ResourceLines = New-Object `
    System.Collections.Generic.List[string]


[void]$ResourceLines.Add(
    "TYPE`tSIZE_BYTES`tMODIFIED`tNAME"
)


$ResourcePath = Join-Path `
    $ProfilePath `
    "resourcepacks"


if (
    Test-Path `
        -LiteralPath $ResourcePath `
        -PathType Container
) {

    $ResourceEntries = Get-ChildItem `
        -LiteralPath $ResourcePath `
        -Force `
        -ErrorAction SilentlyContinue |
        Sort-Object Name


    foreach ($Entry in $ResourceEntries) {

        if ($Entry.PSIsContainer) {

            $Type = "DIR"
            $Size = ""

        }
        else {

            $Type = "FILE"
            $Size = [string]$Entry.Length
        }


        [void]$ResourceLines.Add(
            $Type +
            "`t" +
            $Size +
            "`t" +
            $Entry.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") +
            "`t" +
            $Entry.Name
        )
    }
}


Set-Content `
    -LiteralPath (Join-Path $Stage "_RESOURCEPACK_LISTE.txt") `
    -Value $ResourceLines `
    -Encoding UTF8


# ============================================================
# SCHEMATICS-LISTE
# ============================================================

$SchematicLines = New-Object `
    System.Collections.Generic.List[string]


[void]$SchematicLines.Add(
    "SIZE_BYTES`tMODIFIED`tPATH"
)


$SchematicRoots = @()


$TopLevelDirectories = Get-ChildItem `
    -LiteralPath $ProfilePath `
    -Directory `
    -Force `
    -ErrorAction SilentlyContinue


foreach ($Directory in $TopLevelDirectories) {

    if (
        $Directory.Name -match `
        '(?i)(schem|blueprint|structurize)'
    ) {

        $SchematicRoots += $Directory
    }
}


foreach ($Root in $SchematicRoots) {

    $SchematicFiles = Get-ChildItem `
        -LiteralPath $Root.FullName `
        -File `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue


    foreach ($File in $SchematicFiles) {

        $Relative = `
            Get-ProfileRelativePath `
                -FullPath $File.FullName


        [void]$SchematicLines.Add(
            [string]$File.Length +
            "`t" +
            $File.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") +
            "`t" +
            $Relative
        )
    }
}


Set-Content `
    -LiteralPath (Join-Path $Stage "_SCHEMATICS_LISTE.txt") `
    -Value $SchematicLines `
    -Encoding UTF8


# ============================================================
# SESSION-SCOPE FUER ANALYSE
# ============================================================

$ScopeLines = New-Object `
    System.Collections.Generic.List[string]


[void]$ScopeLines.Add(
    "MINECRAFT SESSION SCOPE"
)

[void]$ScopeLines.Add(
    "======================="
)

[void]$ScopeLines.Add("")

[void]$ScopeLines.Add(
    "Profile: " +
    $ProfileName
)

[void]$ScopeLines.Add(
    "Detected session start: " +
    $SessionStart.ToString("yyyy-MM-dd HH:mm:ss")
)

[void]$ScopeLines.Add(
    "Filesystem filter starts: " +
    $SessionWindowStart.ToString("yyyy-MM-dd HH:mm:ss")
)

[void]$ScopeLines.Add(
    "Export time: " +
    $RunStarted.ToString("yyyy-MM-dd HH:mm:ss")
)

[void]$ScopeLines.Add("")

[void]$ScopeLines.Add(
    "IMPORTANT FOR ANALYSIS:"
)

[void]$ScopeLines.Add(
    "- logs/latest.log belongs to the last/current Minecraft session."
)

[void]$ScopeLines.Add(
    "- Files from crash-reports, spark, special JVM logs and"
)

[void]$ScopeLines.Add(
    "  session-specific log folders were included only when their"
)

[void]$ScopeLines.Add(
    "  filesystem modification time matched this session window."
)

[void]$ScopeLines.Add(
    "- Do not interpret omitted older crash reports as part of this session."
)

[void]$ScopeLines.Add(
    "- Some append-style files such as stdout/stderr or command_history"
)

[void]$ScopeLines.Add(
    "  can technically contain older lines inside the same file."
)

[void]$ScopeLines.Add(
    "  For those files, entries before the detected session start are historical."
)

[void]$ScopeLines.Add("")

[void]$ScopeLines.Add(
    "Likely worlds used in this session:"
)


if ($LikelyActiveWorlds.Count -eq 0) {

    [void]$ScopeLines.Add(
        "  <none detected>"
    )

}
else {

    foreach ($WorldName in $LikelyActiveWorlds) {

        [void]$ScopeLines.Add(
            "  " +
            $WorldName
        )
    }
}


[void]$ScopeLines.Add("Exporter version: v7")
[void]$ScopeLines.Add("")

[void]$ScopeLines.Add(
    "Current-session files copied:"
)

[void]$ScopeLines.Add(
    "  Logs: " +
    $SessionLogCount
)

[void]$ScopeLines.Add(
    "  Crash reports: " +
    $CrashReportCount
)

[void]$ScopeLines.Add(
    "  JVM/Windows special files: " +
    $SpecialCount
)

[void]$ScopeLines.Add(
    "  Spark files: " +
    $SparkCount
)


[void]$ScopeLines.Add(
    "  Extra diagnostic files: " +
    $ExtraDiagnosticCount
)


# ============================================================
# PERFORMANCE-DATEN ABTRENNEN
# ============================================================
# Normale Session-ZIP: Logs, Configs, Modliste, Summary sowie kleine
# Serverthread-Auszuege. Schwere Rohdaten kommen in Performance-Diagnose:
#   - alle *.jfr
#   - volle Thread-Dumps aus auto-stalls/incidents
#   - extrem grosse Zusatzlogs (>64 MiB), aber NIEMALS latest.log
# ============================================================

$HeavyFileCount = 0
$HeavyJfrCount = 0
$HeavyThreadDumpCount = 0
$HeavyLargeLogCount = 0
$HeavyBytes = [int64]0
$HeavyManifest = New-Object System.Collections.Generic.List[string]

[void]$HeavyManifest.Add('Minecraft Performance Diagnostics')
[void]$HeavyManifest.Add('Session export: ' + $ExportName)
[void]$HeavyManifest.Add('Created: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
[void]$HeavyManifest.Add('')
[void]$HeavyManifest.Add('Diese ZIP enthaelt schwere Rohdaten fuer Freeze/MSPT/Serverthread-Tiefenanalyse.')
[void]$HeavyManifest.Add('Fuer die meisten Analysen zuerst nur die Session-Analyse-ZIP hochladen.')
[void]$HeavyManifest.Add('')
[void]$HeavyManifest.Add("TYPE`tSIZE_BYTES`tPATH")

function Move-ToPerformanceStage {
    param(
        [Parameter(Mandatory=$true)][System.IO.FileInfo]$File,
        [Parameter(Mandatory=$true)][string]$Type,
        [switch]$LeavePointer
    )

    $StageBase = $script:Stage.TrimEnd('\') + '\'
    $RelativePath = $File.FullName
    if ($RelativePath.StartsWith($StageBase,[System.StringComparison]::OrdinalIgnoreCase)) {
        $RelativePath = $RelativePath.Substring($StageBase.Length)
    } else {
        $RelativePath = $File.Name
    }

    if (-not (Test-Path -LiteralPath $script:HeavyStage -PathType Container)) {
        New-Item -ItemType Directory -Path $script:HeavyStage -Force | Out-Null
    }

    $Target = Join-Path $script:HeavyStage $RelativePath
    $Parent = Split-Path -Parent $Target
    if (-not (Test-Path -LiteralPath $Parent)) {
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    }

    $Size = [int64]$File.Length
    Move-Item -LiteralPath $File.FullName -Destination $Target -Force

    if ($LeavePointer) {
        $Pointer = $File.FullName + '.MOVED_TO_PERFORMANCE.txt'
        Set-Content -LiteralPath $Pointer -Encoding UTF8 -Value @(
            'Original file moved to Performance-Diagnose ZIP because it is very large.'
            'Type: ' + $Type
            'Original size bytes: ' + $Size
            'Performance path: ' + $RelativePath
        )
    }

    $script:HeavyFileCount++
    $script:HeavyBytes += $Size
    [void]$script:HeavyManifest.Add($Type + "`t" + $Size + "`t" + $RelativePath)
}

$script:Stage = $Stage
$script:HeavyStage = $HeavyStage
$script:HeavyFileCount = 0
$script:HeavyBytes = [int64]0
$script:HeavyManifest = $HeavyManifest

$Candidates = @(Get-ChildItem -LiteralPath $Stage -Recurse -File -ErrorAction SilentlyContinue)
foreach ($File in $Candidates) {
    $Rel = Get-ProfileRelativePath -FullPath $File.FullName
    # Get-ProfileRelativePath ist profilbezogen; fuer Stage-Pfade deshalb separat normalisieren.
    $StageBase = $Stage.TrimEnd('\') + '\'
    if ($File.FullName.StartsWith($StageBase,[System.StringComparison]::OrdinalIgnoreCase)) {
        $Rel = $File.FullName.Substring($StageBase.Length)
    }

    if ($File.Extension -ieq '.jfr') {
        Move-ToPerformanceStage -File $File -Type 'JFR'
        $HeavyJfrCount++
        continue
    }

    if ($Rel -match '(?i)^_diagnose_recorder\\.*\\(auto-stalls|incidents)\\.*\\threads(?:_[^\\]*)?\.txt$') {
        Move-ToPerformanceStage -File $File -Type 'FULL_THREAD_DUMP'
        $HeavyThreadDumpCount++
        continue
    }

    if (
        $Rel -match '(?i)^logs\\' -and
        $Rel -notmatch '(?i)^logs\\latest\.log$' -and
        $File.Length -ge 64MB
    ) {
        Move-ToPerformanceStage -File $File -Type 'VERY_LARGE_EXTRA_LOG' -LeavePointer
        $HeavyLargeLogCount++
        continue
    }
}

$HeavyFileCount = $script:HeavyFileCount
$HeavyBytes = $script:HeavyBytes
$HeavyMB = [Math]::Round(($HeavyBytes / 1MB),2)

if ($HeavyFileCount -gt 0) {
    Set-Content -LiteralPath (Join-Path $HeavyStage '_PERFORMANCE_DIAGNOSE_MANIFEST.txt') -Value $HeavyManifest -Encoding UTF8
}

[void]$ScopeLines.Add('  Performance files moved to separate ZIP: ' + $HeavyFileCount)
[void]$ScopeLines.Add('    JFR files: ' + $HeavyJfrCount)
[void]$ScopeLines.Add('    Full stall/incident thread dumps: ' + $HeavyThreadDumpCount)
[void]$ScopeLines.Add('    Very large extra logs: ' + $HeavyLargeLogCount)
[void]$ScopeLines.Add('  Performance uncompressed size moved: ' + $HeavyMB + ' MB')
[void]$ScopeLines.Add('  Separate Performance ZIP: ' + $(if ($HeavyFileCount -gt 0) { Split-Path -Leaf $HeavyZipFile } else { 'not created (no heavy files)' }))


Set-Content `
    -LiteralPath (Join-Path $Stage "_SESSION_SCOPE.txt") `
    -Value $ScopeLines `
    -Encoding UTF8


# ============================================================
# ZIPS ERZEUGEN
# ============================================================

Write-Host ""
Write-Host "[4/4] ZIPs erstellen..." -ForegroundColor Cyan

Add-Type `
    -AssemblyName System.IO.Compression.FileSystem

# Haupt-ZIP
if (Test-Path -LiteralPath $ZipFile) {
    Remove-Item `
        -LiteralPath $ZipFile `
        -Force `
        -ErrorAction SilentlyContinue
}

[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $Stage,
    $ZipFile,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $true
)

# Separate Performance-ZIP nur wenn schwere Rohdaten vorhanden sind
$HeavyZipCreated = $false

if ($HeavyFileCount -gt 0 -and (Test-Path -LiteralPath $HeavyStage)) {

    if (Test-Path -LiteralPath $HeavyZipFile) {
        Remove-Item `
            -LiteralPath $HeavyZipFile `
            -Force `
            -ErrorAction SilentlyContinue
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $HeavyStage,
        $HeavyZipFile,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true
    )

    $HeavyZipCreated = Test-Path -LiteralPath $HeavyZipFile
}


# ============================================================
# TEMP ENTFERNEN
# ============================================================

Remove-Item `
    -LiteralPath $Stage `
    -Recurse `
    -Force

if (Test-Path -LiteralPath $HeavyStage) {
    Remove-Item `
        -LiteralPath $HeavyStage `
        -Recurse `
        -Force
}


# ============================================================
# FERTIG
# ============================================================

$ZipInfo = Get-Item `
    -LiteralPath $ZipFile


$HeavyZipInfo = $null
if ($HeavyZipCreated) {
    $HeavyZipInfo = Get-Item -LiteralPath $HeavyZipFile
}


$Duration = `
    (Get-Date) - $RunStarted


$ZipSizeMB = `
    [Math]::Round(
        ($ZipInfo.Length / 1MB),
        2
    )


$HeavyZipSizeMB = $null
if ($HeavyZipInfo) {
    $HeavyZipSizeMB = [Math]::Round(
        ($HeavyZipInfo.Length / 1MB),
        2
    )
}


Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Green

Write-Host " FERTIG" `
    -ForegroundColor Green

Write-Host "============================================================" `
    -ForegroundColor Green

Write-Host ""
Write-Host "1) NORMALE ANALYSE-ZIP (fuer die meisten Analysen zuerst verwenden):" -ForegroundColor Cyan
Write-Host $ZipFile
Write-Host ("   Groesse: " + $ZipSizeMB + " MB")
Write-Host ""

if ($HeavyZipCreated) {
    Write-Host "2) PERFORMANCE-DIAGNOSE-ZIP (nur bei Freeze/MSPT/Stall-Tiefenanalyse):" -ForegroundColor Yellow
    Write-Host $HeavyZipFile
    Write-Host ("   Groesse: " + $HeavyZipSizeMB + " MB")
    Write-Host ("   Schwere Dateien: " + $HeavyFileCount)
    Write-Host ""
}
else {
    Write-Host "2) Keine Performance-Diagnose-ZIP erzeugt (keine schweren Daten vorhanden)." -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host (
    "Dauer: " +
    $Duration.ToString("hh\:mm\:ss")
)

Write-Host ""
Write-Host "Der Exportordner wird jetzt im Explorer geoeffnet."


Start-Process `
    explorer.exe `
    $ExportParent

# Expliziter Erfolgs-ExitCode fuer den Diagnose-Recorder.
exit 0

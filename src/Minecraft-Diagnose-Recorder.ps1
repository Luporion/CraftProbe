#requires -Version 5.1

param(
    [string]$ProfilePath,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$RecorderVersion = "0.1.0"
$RecorderStartedAt = Get-Date

# ============================================================
# Minecraft Diagnose Recorder
# Portable Windows edition
#
# - launcher-agnostic profile selection
# - no fixed drive, username, Java or launcher paths
# - compact Session-Analyse + optional Performance-Diagnose
# - JFR, JVM snapshots, stall correlation and incident markers
# ============================================================

function Test-MinecraftProfileRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $Full = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName } catch { return $false }
    $Markers = @('mods','config','logs','saves','resourcepacks','shaderpacks','options.txt','defaultconfigs','kubejs')
    $Found = 0
    foreach ($Marker in $Markers) {
        if (Test-Path -LiteralPath (Join-Path $Full $Marker)) { $Found++ }
    }
    return ($Found -ge 2)
}

function Resolve-MinecraftProfilePath {
    param([string]$RequestedPath)

    $Candidates = New-Object System.Collections.Generic.List[string]
    if ($RequestedPath) { [void]$Candidates.Add($RequestedPath) }
    try { [void]$Candidates.Add((Get-Location).Path) } catch {}
    [void]$Candidates.Add($PSScriptRoot)
    try { [void]$Candidates.Add((Split-Path -Parent $PSScriptRoot)) } catch {}
    try { [void]$Candidates.Add((Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) } catch {}

    foreach ($Candidate in @($Candidates | Select-Object -Unique)) {
        if (-not $Candidate) { continue }
        try { $Full = (Get-Item -LiteralPath $Candidate -ErrorAction Stop).FullName.TrimEnd('\') } catch { continue }
        if (Test-MinecraftProfileRoot $Full) { return $Full }
        $DotMinecraft = Join-Path $Full '.minecraft'
        if (Test-MinecraftProfileRoot $DotMinecraft) { return (Get-Item -LiteralPath $DotMinecraft).FullName.TrimEnd('\') }
    }

    # Friendly Windows folder picker. Falls back to a text prompt if unavailable.
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $Dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $Dialog.Description = 'Minecraft profile/game directory select (folder containing mods, config, logs, saves...)'
        $Dialog.ShowNewFolderButton = $false
        if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $Selected = $Dialog.SelectedPath
            if (Test-MinecraftProfileRoot $Selected) { return (Get-Item -LiteralPath $Selected).FullName.TrimEnd('\') }
            $DotMinecraft = Join-Path $Selected '.minecraft'
            if (Test-MinecraftProfileRoot $DotMinecraft) { return (Get-Item -LiteralPath $DotMinecraft).FullName.TrimEnd('\') }
        }
    } catch {}

    $Typed = Read-Host 'Path to Minecraft profile/game directory'
    if ($Typed) {
        $Typed = $Typed.Trim('"').Trim()
        if (Test-MinecraftProfileRoot $Typed) { return (Get-Item -LiteralPath $Typed).FullName.TrimEnd('\') }
        $DotMinecraft = Join-Path $Typed '.minecraft'
        if (Test-MinecraftProfileRoot $DotMinecraft) { return (Get-Item -LiteralPath $DotMinecraft).FullName.TrimEnd('\') }
    }

    throw 'No plausible Minecraft profile directory was selected.'
}

$ProfilePath = Resolve-MinecraftProfilePath -RequestedPath $ProfilePath
$ProfileName = Split-Path -Leaf $ProfilePath
if ($ProfileName -eq '.minecraft') { $ProfileName = Split-Path -Leaf (Split-Path -Parent $ProfilePath) }
$ExporterPath = Join-Path $PSScriptRoot 'Export-Minecraft-Session-Analyse.ps1'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $ProfilePath) '_Minecraft-Diagnose-Exports'
}
else {
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
}

function Write-Utf8File {
    param([string]$Path, $Content)
    $Parent = Split-Path -Parent $Path
    if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    }
    $Content | Out-File -LiteralPath $Path -Encoding utf8 -Force
}

function Protect-CommandLineSecrets {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $Protected = $Text
    foreach ($Name in @('accessToken','clientId','xuid','uuid','userProperties','profileProperties')) {
        $Pattern = '(?i)(--' + [regex]::Escape($Name) + '\s+)("[^"]*"|\S+)'
        $Protected = [regex]::Replace($Protected, $Pattern, '$1<REDACTED>')
    }
    $Protected = [regex]::Replace(
        $Protected,
        '(?i)\beyJ[A-Za-z0-9_\-\.]{40,}\b',
        '<REDACTED_TOKEN>'
    )
    return $Protected
}

function Find-MinecraftJavaProcess {
    param(
        [string]$WantedProfilePath,
        [datetime]$NotBefore = ([datetime]::MinValue)
    )

    $Wanted = $WantedProfilePath.Replace('/', '\').TrimEnd('\')
    $Candidates = New-Object System.Collections.Generic.List[object]

    $Processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('javaw.exe','java.exe') }

    foreach ($Proc in $Processes) {
        $Cmd = [string]$Proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($Cmd)) { continue }
        $Normalized = $Cmd.Replace('/', '\')
        $Score = 0

        if ($Normalized.IndexOf($Wanted,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $Score += 100 }
        if ($Normalized -match '(?i)--gameDir\s+') { $Score += 15 }
        if ($Normalized -match '(?i)minecraft|neoforge|forge|fabric|quilt|modlauncher') { $Score += 20 }

        $Creation = $null
        try {
            if ($Proc.CreationDate -is [datetime]) { $Creation = [datetime]$Proc.CreationDate }
            else { $Creation = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Proc.CreationDate) }
        } catch {}
        if ($Creation -and $Creation -ge $NotBefore.AddSeconds(-10)) { $Score += 25 }

        if ($Score -gt 0) {
            [void]$Candidates.Add([pscustomobject]@{ Process=$Proc; Score=$Score; Creation=$Creation })
        }
    }

    $Best = $Candidates | Sort-Object Score,Creation -Descending | Select-Object -First 1
    if ($Best -and $Best.Score -ge 40) { return $Best.Process }
    return $null
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 15,
        [string]$OutputPath = $null
    )

    $TempBase = Join-Path $env:TEMP ("mcdiag_" + [guid]::NewGuid().ToString("N"))
    $StdOut = $TempBase + ".out.txt"
    $StdErr = $TempBase + ".err.txt"

    $Result = [ordered]@{
        Success = $false
        TimedOut = $false
        ExitCode = $null
        Output = ""
    }

    try {
        $Proc = Start-Process -FilePath $FilePath `
            -ArgumentList $ArgumentList `
            -RedirectStandardOutput $StdOut `
            -RedirectStandardError $StdErr `
            -WindowStyle Hidden `
            -PassThru

        if (-not $Proc.WaitForExit([Math]::Max(1,$TimeoutSeconds) * 1000)) {
            $Result.TimedOut = $true
            try { $Proc.Kill() } catch {}
            try { $Proc.WaitForExit(3000) | Out-Null } catch {}
        }
        else {
            $Result.ExitCode = $Proc.ExitCode
            $Result.Success = ($Proc.ExitCode -eq 0)
        }

        $Parts = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath $StdOut) {
            $T = Get-Content -LiteralPath $StdOut -Raw -ErrorAction SilentlyContinue
            if ($T) { [void]$Parts.Add($T.TrimEnd()) }
        }
        if (Test-Path -LiteralPath $StdErr) {
            $T = Get-Content -LiteralPath $StdErr -Raw -ErrorAction SilentlyContinue
            if ($T) { [void]$Parts.Add($T.TrimEnd()) }
        }
        if ($Result.TimedOut) {
            [void]$Parts.Add("TIMEOUT after $TimeoutSeconds seconds")
        }
        $Result.Output = ($Parts -join [Environment]::NewLine)
    }
    catch {
        $Result.Output = "ERROR: " + $_.Exception.Message
    }
    finally {
        Remove-Item -LiteralPath $StdOut,$StdErr -Force -ErrorAction SilentlyContinue
    }

    if ($OutputPath) {
        Write-Utf8File -Path $OutputPath -Content $Result.Output
    }

    return [pscustomobject]$Result
}

function Get-JavaExeForTool {
    param([string]$ToolPath)
    if (-not $ToolPath) { return $null }
    try {
        $Bin = Split-Path -Parent $ToolPath
        $Java = Join-Path $Bin "java.exe"
        if (Test-Path -LiteralPath $Java -PathType Leaf) { return $Java }
    } catch {}
    return $null
}

function Get-JavaExeForMinecraftRuntime {
    param([string]$MinecraftJavaExe)
    if (-not $MinecraftJavaExe) { return $null }
    try {
        $Bin = Split-Path -Parent $MinecraftJavaExe
        $Java = Join-Path $Bin "java.exe"
        if (Test-Path -LiteralPath $Java -PathType Leaf) { return $Java }
        if (Test-Path -LiteralPath $MinecraftJavaExe -PathType Leaf) { return $MinecraftJavaExe }
    } catch {}
    return $null
}

function Get-JavaMajorVersion {
    param([string]$JavaExe)
    if (-not $JavaExe -or -not (Test-Path -LiteralPath $JavaExe -PathType Leaf)) { return $null }

    $R = Invoke-ProcessWithTimeout -FilePath $JavaExe -ArgumentList @('-version') -TimeoutSeconds 8
    $Text = [string]$R.Output
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $M = [regex]::Match($Text, 'version\s+"([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $M.Success) {
        $M = [regex]::Match($Text, '(?m)(?:openjdk|java)\s+(?:version\s+)?"?([0-9][0-9A-Za-z._+-]*)')
    }
    if (-not $M.Success) { return $null }

    $V = $M.Groups[1].Value
    if ($V -match '^1\.(\d+)') { return [int]$Matches[1] }
    if ($V -match '^(\d+)') { return [int]$Matches[1] }
    return $null
}

function Get-JavaToolCandidates {
    param([string]$ToolName, [string]$MinecraftJavaExe)

    $Candidates = New-Object System.Collections.Generic.List[string]

    if ($MinecraftJavaExe) {
        try {
            $Bin = Split-Path -Parent $MinecraftJavaExe
            [void]$Candidates.Add((Join-Path $Bin $ToolName))
        } catch {}
    }

    if ($env:JAVA_HOME) {
        try { [void]$Candidates.Add((Join-Path (Join-Path $env:JAVA_HOME 'bin') $ToolName)) } catch {}
    }

    try {
        $C = Get-Command $ToolName -ErrorAction SilentlyContinue
        if ($C -and $C.Source) { [void]$Candidates.Add($C.Source) }
    } catch {}

    $SearchRoots = New-Object System.Collections.Generic.List[string]
    foreach ($Root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:USERPROFILE)) {
        if ($Root -and (Test-Path -LiteralPath $Root)) { [void]$SearchRoots.Add($Root) }
    }

    $Globs = New-Object System.Collections.Generic.List[string]
    foreach ($Root in @($SearchRoots | Select-Object -Unique)) {
        foreach ($Rel in @(
            'Eclipse Adoptium\jdk-*\bin',
            'Java\jdk-*\bin',
            'Microsoft\jdk-*\bin',
            'Zulu\zulu-*\bin',
            'BellSoft\LibericaJDK-*\bin',
            'Programs\Eclipse Adoptium\jdk-*\bin',
            '.jdks\*\bin',
            '.gradle\jdks\*\bin'
        )) {
            [void]$Globs.Add((Join-Path (Join-Path $Root $Rel) $ToolName))
        }
    }

    foreach ($Glob in $Globs) {
        try {
            Get-ChildItem -Path $Glob -File -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                ForEach-Object { [void]$Candidates.Add($_.FullName) }
        } catch {}
    }

    return @($Candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique)
}

function Find-CompatibleJavaTool {
    param(
        [string]$ToolName,
        [string]$MinecraftJavaExe,
        [Nullable[int]]$WantedMajor,
        [string]$ReportPath = $null
    )

    $Report = New-Object System.Collections.Generic.List[string]
    [void]$Report.Add("Wanted Java major: " + $(if ($null -ne $WantedMajor) { $WantedMajor } else { '<unknown>' }))
    [void]$Report.Add("")

    foreach ($Candidate in (Get-JavaToolCandidates -ToolName $ToolName -MinecraftJavaExe $MinecraftJavaExe)) {
        $ToolJava = Get-JavaExeForTool -ToolPath $Candidate
        $Major = Get-JavaMajorVersion -JavaExe $ToolJava
        [void]$Report.Add("Candidate: $Candidate")
        [void]$Report.Add("  Java: $ToolJava")
        [void]$Report.Add("  Major: " + $(if ($null -ne $Major) { $Major } else { '<unknown>' }))

        if ($null -eq $WantedMajor) {
            [void]$Report.Add("  Result: accepted (Minecraft major unknown)")
            if ($ReportPath) { Write-Utf8File $ReportPath $Report }
            return $Candidate
        }

        if ($null -ne $Major -and $Major -eq $WantedMajor) {
            [void]$Report.Add("  Result: accepted")
            if ($ReportPath) { Write-Utf8File $ReportPath $Report }
            return $Candidate
        }

        [void]$Report.Add("  Result: rejected (wrong/unknown Java major)")
        [void]$Report.Add("")
    }

    if ($ReportPath) { Write-Utf8File $ReportPath $Report }
    return $null
}

function Invoke-JcmdToFile {
    param(
        [string]$Jcmd,
        [int]$MinecraftPid,
        [string]$Command,
        [string]$OutputPath,
        [string[]]$ExtraArgs = @(),
        [int]$TimeoutSeconds = 15
    )

    if (-not $Jcmd) {
        Write-Utf8File -Path $OutputPath -Content "SKIPPED: compatible jcmd.exe not available"
        return $false
    }

    $Args = @([string]$MinecraftPid, $Command) + $ExtraArgs
    $R = Invoke-ProcessWithTimeout -FilePath $Jcmd -ArgumentList $Args -TimeoutSeconds $TimeoutSeconds -OutputPath $OutputPath
    return [bool]$R.Success
}

function Get-JfrStatus {
    param(
        [string]$Jcmd,
        [int]$MinecraftPid,
        [string]$RecordingName = "MinecraftAI",
        [string]$OutputPath = $null,
        [int]$TimeoutSeconds = 12
    )

    $Status = [ordered]@{
        CommandWorked = $false
        Running = $false
        Output = ""
    }

    if (-not $Jcmd) {
        $Status.Output = "SKIPPED: compatible jcmd.exe not available"
        if ($OutputPath) { Write-Utf8File -Path $OutputPath -Content $Status.Output }
        return [pscustomobject]$Status
    }

    $R = Invoke-ProcessWithTimeout -FilePath $Jcmd `
        -ArgumentList @([string]$MinecraftPid, "JFR.check") `
        -TimeoutSeconds $TimeoutSeconds `
        -OutputPath $OutputPath

    $Status.CommandWorked = [bool]$R.Success
    $Status.Output = [string]$R.Output

    # jcmd prints e.g.:
    # Recording 1: name=MinecraftAI maxsize=256,0MB maxage=15m (running)
    $EscapedName = [regex]::Escape($RecordingName)
    if ($Status.Output -match ("(?im)name=" + $EscapedName + "\b.*\(running\)")) {
        $Status.Running = $true
    }

    return [pscustomobject]$Status
}

function Ensure-JfrRecording {
    param(
        [string]$Jcmd,
        [int]$MinecraftPid,
        [string]$RecordingName,
        [string]$JfrFile,
        [string]$SessionDir
    )

    $Result = [ordered]@{
        Active = $false
        ReusedExisting = $false
        StartReportedSuccess = $false
        VerifiedByCheck = $false
        Message = ""
    }

    if (-not $Jcmd) {
        $Result.Message = "No compatible jcmd.exe available."
        return [pscustomobject]$Result
    }

    # First check: do not create a duplicate recording if one is already running.
    $Before = Get-JfrStatus -Jcmd $Jcmd -MinecraftPid $MinecraftPid `
        -RecordingName $RecordingName `
        -OutputPath (Join-Path $SessionDir "jfr-check-before-start.txt")

    if ($Before.Running) {
        $Result.Active = $true
        $Result.ReusedExisting = $true
        $Result.VerifiedByCheck = $true
        $Result.Message = "Recording already running; reusing it."
        return [pscustomobject]$Result
    }

    # Start the recording. Do NOT trust only the exit code; some jcmd builds can
    # report success in stdout while our process wrapper sees a non-zero result.
    $Start = Invoke-ProcessWithTimeout -FilePath $Jcmd `
        -ArgumentList @(
            [string]$MinecraftPid,
            "JFR.start",
            ("name=" + $RecordingName),
            "settings=default",
            "disk=true",
            "maxage=15m",
            "maxsize=96m",
            "dumponexit=true",
            ("filename=" + $JfrFile)
        ) `
        -TimeoutSeconds 20 `
        -OutputPath (Join-Path $SessionDir "jfr-start-result.txt")

    $StartText = [string]$Start.Output
    if ($StartText -match '(?im)Started\s+recording\s+\d+') {
        $Result.StartReportedSuccess = $true
    }

    # Verify the actual JVM state. Retry briefly because the recording may need a
    # moment to become visible to JFR.check.
    for ($Attempt = 1; $Attempt -le 4; $Attempt++) {
        Start-Sleep -Milliseconds 500
        $CheckPath = Join-Path $SessionDir ("jfr-check-after-start-{0}.txt" -f $Attempt)
        $After = Get-JfrStatus -Jcmd $Jcmd -MinecraftPid $MinecraftPid `
            -RecordingName $RecordingName -OutputPath $CheckPath

        if ($After.Running) {
            $Result.Active = $true
            $Result.VerifiedByCheck = $true
            $Result.Message = "Recording verified as running by JFR.check."
            return [pscustomobject]$Result
        }
    }

    # If JFR.start explicitly said it started but JFR.check could not verify it,
    # keep it active so periodic dumps can still be attempted. This avoids the
    # false negative seen in recorder v3.
    if ($Result.StartReportedSuccess) {
        $Result.Active = $true
        $Result.Message = "JFR.start reported success, but JFR.check could not verify it."
        return [pscustomobject]$Result
    }

    $Result.Message = "JFR.start was not confirmed and no running recording was found."
    return [pscustomobject]$Result
}

function Capture-JvmSnapshot {
    param(
        [int]$MinecraftPid,
        [string]$Jcmd,
        [string]$Directory,
        [string]$JfrFile = $null
    )

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    if (-not $Jcmd) { return }

    [void](Invoke-JcmdToFile -Jcmd $Jcmd -MinecraftPid $MinecraftPid -Command "Thread.print" `
        -ExtraArgs @("-l") -TimeoutSeconds 15 -OutputPath (Join-Path $Directory "threads.txt"))

    [void](Invoke-JcmdToFile -Jcmd $Jcmd -MinecraftPid $MinecraftPid -Command "GC.heap_info" `
        -TimeoutSeconds 12 -OutputPath (Join-Path $Directory "heap-info.txt"))

    if ($JfrFile) {
        [void](Invoke-JcmdToFile -Jcmd $Jcmd -MinecraftPid $MinecraftPid -Command "JFR.dump" `
            -ExtraArgs @("name=MinecraftAI", ("filename=" + $JfrFile)) `
            -TimeoutSeconds 20 -OutputPath (Join-Path $Directory "jfr-dump-result.txt"))
    }
}

function Get-LatestValidJfrSnapshot {
    param([string]$SnapshotsDir)
    if (-not (Test-Path -LiteralPath $SnapshotsDir -PathType Container)) { return $null }
    try {
        return Get-ChildItem -LiteralPath $SnapshotsDir -Filter "*.jfr" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 0 } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    } catch { return $null }
}


function Get-ServerThreadSection {
    param([string]$ThreadDump)
    if ([string]::IsNullOrWhiteSpace($ThreadDump)) { return "" }
    $M = [regex]::Match($ThreadDump, '(?ms)^"Server thread".*?(?=^"[^\r\n]+"|\z)')
    if ($M.Success) { return $M.Value.TrimEnd() }
    return ""
}

function Test-ServerThreadIdle {
    param([string]$Section)
    if ([string]::IsNullOrWhiteSpace($Section)) { return $false }

    # Normaler Minecraft-Server-Leerlauf. Genau diese Zustaende sollen
    # KEINEN Auto-Stall mehr ausloesen.
    if ($Section -match '(?i)MinecraftServer\.waitUntilNextTick') { return $true }
    if (
        $Section -match '(?i)MinecraftServer\.waitForTasks' -and
        $Section -match '(?i)(TIMED_WAITING|WAITING|LockSupport\.park|Unsafe\.park)'
    ) { return $true }

    return $false
}

function Get-ServerThreadSignature {
    param([string]$Section)
    if ([string]::IsNullOrWhiteSpace($Section)) { return 'no-server-thread' }

    $Frames = New-Object System.Collections.Generic.List[string]
    foreach ($M in [regex]::Matches($Section, '(?m)^\s+at\s+([^\r\n]+)$')) {
        $Frame = $M.Groups[1].Value
        $Frame = [regex]::Replace($Frame, '\$\$Lambda/0x[0-9A-Fa-f]+', '$$Lambda')
        $Frame = [regex]::Replace($Frame, '\([^\)]*\)$', '')
        [void]$Frames.Add($Frame.Trim())
        if ($Frames.Count -ge 12) { break }
    }

    $Basis = if ($Frames.Count -gt 0) { $Frames -join "|" } else { $Section.Substring(0,[Math]::Min(1000,$Section.Length)) }
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Basis)
        $Hash = $Sha.ComputeHash($Bytes)
        return (([BitConverter]::ToString($Hash)).Replace('-','').Substring(0,16))
    }
    finally { $Sha.Dispose() }
}

function Get-SessionRelativePath {
    param([string]$Base,[string]$Path)
    if (-not $Path) { return '' }
    $B = $Base.TrimEnd('\') + '\'
    if ($Path.StartsWith($B,[StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($B.Length)
    }
    return (Split-Path -Leaf $Path)
}

function Save-ServerThreadExcerpt {
    param([string]$ThreadDumpPath,[string]$OutputPath)
    try {
        if (-not (Test-Path -LiteralPath $ThreadDumpPath -PathType Leaf)) { return '' }
        $Text = Get-Content -LiteralPath $ThreadDumpPath -Raw -ErrorAction Stop
        $Section = Get-ServerThreadSection -ThreadDump $Text
        if ($Section) {
            Write-Utf8File -Path $OutputPath -Content $Section
            return $Section
        }
    } catch {}
    return ''
}

function Save-JfrSnapshot {
    param(
        [int]$MinecraftPid,
        [string]$Jcmd,
        [bool]$JfrActive,
        [string]$OutputPath,
        [string]$ResultPath
    )

    if (-not $JfrActive -or -not $Jcmd) { return $false }
    try {
        $Parent = Split-Path -Parent $OutputPath
        if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
            New-Item -ItemType Directory -Path $Parent -Force | Out-Null
        }
        [void](Invoke-JcmdToFile -Jcmd $Jcmd -MinecraftPid $MinecraftPid -Command 'JFR.dump' `
            -ExtraArgs @('name=MinecraftAI',('filename=' + $OutputPath)) -TimeoutSeconds 20 -OutputPath $ResultPath)
        if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
            return ((Get-Item -LiteralPath $OutputPath).Length -gt 0)
        }
    } catch {}
    return $false
}

function Get-InstanceVersions {
    param([string]$ProfilePath)
    $R = [ordered]@{ Minecraft='<unknown>'; Loader='<unknown>'; LoaderVersion='<unknown>'; NeoForge='<unknown>' }

    # CurseForge metadata (optional)
    $Cf = Join-Path $ProfilePath 'minecraftinstance.json'
    if (Test-Path -LiteralPath $Cf) {
        try {
            $Obj = Get-Content -LiteralPath $Cf -Raw | ConvertFrom-Json
            if ($Obj.gameVersion) { $R.Minecraft = [string]$Obj.gameVersion }
            if ($Obj.baseModLoader) {
                $Name = [string]$Obj.baseModLoader.name
                $ForgeVersion = [string]$Obj.baseModLoader.forgeVersion
                if ($Name -match '(?i)neoforge') { $R.Loader='NeoForge' }
                elseif ($Name -match '(?i)forge') { $R.Loader='Forge' }
                if ($ForgeVersion) { $R.LoaderVersion=$ForgeVersion; if ($R.Loader -eq 'NeoForge') { $R.NeoForge=$ForgeVersion } }
                elseif ($Name -match '(?i)neoforge[- ]?(.+)$') { $R.NeoForge=$Matches[1]; $R.LoaderVersion=$Matches[1] }
            }
        } catch {}
    }

    # PrismLauncher/MultiMC metadata (optional, usually one directory above .minecraft)
    foreach ($Base in @($ProfilePath,(Split-Path -Parent $ProfilePath))) {
        $Mmc = Join-Path $Base 'mmc-pack.json'
        if (Test-Path -LiteralPath $Mmc) {
            try {
                $Obj = Get-Content -LiteralPath $Mmc -Raw | ConvertFrom-Json
                foreach ($Comp in @($Obj.components)) {
                    if ($Comp.uid -eq 'net.minecraft' -and $Comp.version) { $R.Minecraft=[string]$Comp.version }
                    if ($Comp.uid -match '(?i)neoforge' -and $Comp.version) { $R.Loader='NeoForge'; $R.LoaderVersion=[string]$Comp.version; $R.NeoForge=[string]$Comp.version }
                    elseif ($Comp.uid -match '(?i)forge' -and $Comp.version) { $R.Loader='Forge'; $R.LoaderVersion=[string]$Comp.version }
                    elseif ($Comp.uid -match '(?i)fabric' -and $Comp.version) { $R.Loader='Fabric'; $R.LoaderVersion=[string]$Comp.version }
                }
            } catch {}
        }
    }

    # Runtime log fallback: launcher-independent.
    $Latest = Join-Path $ProfilePath 'logs\\latest.log'
    if (Test-Path -LiteralPath $Latest) {
        try {
            $Text = Get-Content -LiteralPath $Latest -Raw -ErrorAction Stop
            if ($R.Minecraft -eq '<unknown>') {
                foreach ($Pat in @(
                    '(?i)--fml\.mcVersion[,= ]+([0-9][0-9A-Za-z._+-]*)',
                    '(?i)Minecraft(?: version)?[ :]+([0-9]+\.[0-9]+(?:\.[0-9]+)?)',
                    '(?i)Loading Minecraft ([0-9]+\.[0-9]+(?:\.[0-9]+)?)'
                )) { $M=[regex]::Match($Text,$Pat); if($M.Success){$R.Minecraft=$M.Groups[1].Value;break} }
            }
            foreach ($Pat in @(
                '(?i)--fml\.neoForgeVersion[,= ]+([0-9][0-9A-Za-z._+-]*)',
                '(?i)NeoForge(?: version)?[ :]+([0-9][0-9A-Za-z._+-]*)'
            )) { $M=[regex]::Match($Text,$Pat); if($M.Success){$R.Loader='NeoForge';$R.LoaderVersion=$M.Groups[1].Value;$R.NeoForge=$M.Groups[1].Value;break} }
            if ($R.LoaderVersion -eq '<unknown>') {
                $M=[regex]::Match($Text,'(?i)--fml\.forgeVersion[,= ]+([0-9][0-9A-Za-z._+-]*)')
                if($M.Success){$R.Loader='Forge';$R.LoaderVersion=$M.Groups[1].Value}
                else {
                    $M=[regex]::Match($Text,'(?i)Fabric Loader[ /:]?([0-9][0-9A-Za-z._+-]*)')
                    if($M.Success){$R.Loader='Fabric';$R.LoaderVersion=$M.Groups[1].Value}
                }
            }
            if ($R.Loader -eq '<unknown>') {
                if ($Text -match '(?i)neoforge') { $R.Loader='NeoForge' }
                elseif ($Text -match '(?i)fabric') { $R.Loader='Fabric' }
                elseif ($Text -match '(?i)forge') { $R.Loader='Forge' }
            }
        } catch {}
    }
    return [pscustomobject]$R
}

function Get-LogEventTime {
    param(
        [string]$Line,
        [datetime]$ReferenceTime
    )

    if ($Line -match '\[(?:[^\]]*\s)?(\d{2}:\d{2}:\d{2}(?:[\.,]\d+)?)\]') {
        $T = $Matches[1].Replace(',','.')
        foreach ($Format in @('HH:mm:ss.FFFFFFF','HH:mm:ss')) {
            try {
                $Parsed = [DateTime]::ParseExact($T,$Format,[System.Globalization.CultureInfo]::InvariantCulture)
                $Candidate = $ReferenceTime.Date + $Parsed.TimeOfDay
                if ($Candidate -gt $ReferenceTime.AddMinutes(10)) { $Candidate = $Candidate.AddDays(-1) }
                return $Candidate
            } catch {}
        }
    }
    return $ReferenceTime
}


function Write-DiagnoseSummary {
    param(
        [string]$Path,
        [datetime]$GameStart,
        $StartupCompleteAt,
        $WorldEntryAt,
        [string]$WorldEntryLine,
        [datetime]$EndAt,
        [string]$JavaVersion,
        [string]$MinecraftVersion,
        [string]$LoaderVersion,
        [System.Collections.IEnumerable]$StallEvents,
        [int]$ManualIncidents,
        [int]$IgnoredIdleCandidates,
        [int]$UniqueStallSnapshots,
        [string]$StartupJfr,
        [string]$WorldEntryJfr,
        [string]$WorldEntryFollowupJfr,
        [string]$FinalRollingJfr
    )

    $Lines = New-Object System.Collections.Generic.List[string]
    [void]$Lines.Add('MINECRAFT DIAGNOSE SUMMARY')
    [void]$Lines.Add('==========================')
    [void]$Lines.Add('')
    [void]$Lines.Add('Recorder: ' + $RecorderVersion)
    [void]$Lines.Add('Minecraft: ' + $MinecraftVersion)
    [void]$Lines.Add('Loader: ' + $(if ($script:DetectedLoader) { $script:DetectedLoader } else { '<unknown>' }))
    [void]$Lines.Add('Loader version: ' + $LoaderVersion)
    [void]$Lines.Add('Java: ' + $JavaVersion)
    [void]$Lines.Add('')
    [void]$Lines.Add('TIMELINE')
    [void]$Lines.Add('Game/Java process detected: ' + $GameStart.ToString('yyyy-MM-dd HH:mm:ss.fff'))
    [void]$Lines.Add('Startup/main-menu detected: ' + $(if ($StartupCompleteAt) { ([datetime]$StartupCompleteAt).ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '<not detected>' }))
    [void]$Lines.Add('World entry detected: ' + $(if ($WorldEntryAt) { ([datetime]$WorldEntryAt).ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '<not detected>' }))
    if ($WorldEntryLine) { [void]$Lines.Add('World entry log marker: ' + $WorldEntryLine) }
    [void]$Lines.Add('Diagnosis end: ' + $EndAt.ToString('yyyy-MM-dd HH:mm:ss.fff'))
    [void]$Lines.Add('')
    [void]$Lines.Add('PRESERVED JFR MILESTONES')
    [void]$Lines.Add('Startup: ' + $(if ($StartupJfr) { $StartupJfr } else { '<none>' }))
    [void]$Lines.Add('World entry: ' + $(if ($WorldEntryJfr) { $WorldEntryJfr } else { '<none>' }))
    [void]$Lines.Add('World entry + first chunks: ' + $(if ($WorldEntryFollowupJfr) { $WorldEntryFollowupJfr } else { '<none>' }))
    [void]$Lines.Add('Final/rolling JFR: ' + $(if ($FinalRollingJfr) { $FinalRollingJfr } else { '<none>' }))
    [void]$Lines.Add('')

    $Events = @($StallEvents)
    [void]$Lines.Add('STALLS / HIGH MSPT')
    [void]$Lines.Add('Detected events: ' + $Events.Count)
    [void]$Lines.Add('Unique heavy stall snapshots: ' + $UniqueStallSnapshots)
    [void]$Lines.Add('Ignored normal-idle candidates: ' + $IgnoredIdleCandidates)
    [void]$Lines.Add('Manual E incidents: ' + $ManualIncidents)
    [void]$Lines.Add('Performance-Diagnose recommended: ' + $(if ($Events.Count -gt 0 -or $ManualIncidents -gt 0) { 'YES' } else { 'NO - Session-Analyse should normally be enough' }))
    [void]$Lines.Add('')

    if ($Events.Count -eq 0) {
        [void]$Lines.Add('No verified server-thread stalls/high-MSPT events were detected.')
    }
    else {
        foreach ($E in $Events) {
            [void]$Lines.Add(('[{0}] {1}' -f $E.Id,([datetime]$E.Time).ToString('yyyy-MM-dd HH:mm:ss.fff')))
            [void]$Lines.Add('  Duration: ' + $E.DurationText)
            [void]$Lines.Add('  Trigger: ' + $E.Trigger)
            [void]$Lines.Add('  Source: ' + $E.Source)
            [void]$Lines.Add('  Server-thread signature: ' + $E.Signature)
            [void]$Lines.Add('  Snapshot: ' + $(if ($E.Snapshot) { $E.Snapshot } else { '<metadata only>' }))
            [void]$Lines.Add('  JFR: ' + $(if ($E.Jfr) { $E.Jfr } else { '<none>' }))
            if ($E.DeduplicatedFrom) { [void]$Lines.Add('  Deduplicated from: ' + $E.DeduplicatedFrom) }
            [void]$Lines.Add('')
        }
    }

    Write-Utf8File -Path $Path -Content $Lines
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Minecraft Diagnose Recorder v0.1.0" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Profil: $ProfileName"
Write-Host "Pfad:   $ProfilePath"
Write-Host ""
Write-Host "Warte auf Minecraft..."
Write-Host "Starte Minecraft jetzt ganz normal mit deinem Launcher."
Write-Host ""

$MinecraftProc = $null
while ($null -eq $MinecraftProc) {
    $MinecraftProc = Find-MinecraftJavaProcess -WantedProfilePath $ProfilePath -NotBefore $RecorderStartedAt
    if ($null -eq $MinecraftProc) { Start-Sleep -Seconds 2 }
}

$GameStart = Get-Date
$MinecraftPid = [int]$MinecraftProc.ProcessId
$JavaExe = [string]$MinecraftProc.ExecutablePath
$Stamp = $GameStart.ToString('yyyy-MM-dd_HH-mm-ss')
$SessionDir = Join-Path (Join-Path $ProfilePath '_diagnose_recorder') $Stamp
$SnapshotsDir = Join-Path $SessionDir 'jfr-snapshots'
$MilestonesDir = Join-Path $SessionDir 'milestones'
$AutoStallsDir = Join-Path $SessionDir 'auto-stalls'
$IncidentsDir = Join-Path $SessionDir 'incidents'
New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null

Write-Host "Minecraft erkannt." -ForegroundColor Green
Write-Host "PID:  $MinecraftPid"
Write-Host "Java: $JavaExe"

$MinecraftJavaConsole = Get-JavaExeForMinecraftRuntime -MinecraftJavaExe $JavaExe
$MinecraftJavaMajor = Get-JavaMajorVersion -JavaExe $MinecraftJavaConsole
$JavaVersionText = $(if ($null -ne $MinecraftJavaMajor) { 'Java ' + $MinecraftJavaMajor } else { '<unknown>' })
try {
    $JV = Invoke-ProcessWithTimeout -FilePath $MinecraftJavaConsole -ArgumentList @('-version') -TimeoutSeconds 8
    if ($JV.Output) {
        $First = (($JV.Output -split "`r?`n") | Select-Object -First 1)
        if ($First) { $JavaVersionText = $First.Trim() }
        Write-Utf8File -Path (Join-Path $SessionDir 'java-runtime-version.txt') -Content $JV.Output
    }
} catch {}

Write-Host "Java-Major: " $(if ($null -ne $MinecraftJavaMajor) { $MinecraftJavaMajor } else { "unbekannt" })
Write-Host ""

$Versions = Get-InstanceVersions -ProfilePath $ProfilePath
$script:DetectedLoader = $Versions.Loader

Write-Utf8File -Path (Join-Path $SessionDir '_SESSION.txt') -Content @(
    "Profile: $ProfileName"
    "Profile path: $ProfilePath"
    "Recorder version: $RecorderVersion"
    "Recorder start: " + $GameStart.ToString('yyyy-MM-dd HH:mm:ss.fff')
    "Minecraft PID: $MinecraftPid"
    "Java executable: $JavaExe"
    "Java version: $JavaVersionText"
    "Minecraft version: $($Versions.Minecraft)"
    "Loader: $($Versions.Loader)"
    "Loader version: $($Versions.LoaderVersion)"
    "NeoForge version: $($Versions.NeoForge)"
)

Write-Utf8File -Path (Join-Path $SessionDir 'process-command-line.txt') `
    -Content (Protect-CommandLineSecrets ([string]$MinecraftProc.CommandLine))

try {
    Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption,Version,BuildNumber,OSArchitecture,TotalVisibleMemorySize,FreePhysicalMemory |
        Format-List | Out-File (Join-Path $SessionDir 'system-os.txt') -Encoding utf8
    Get-CimInstance Win32_Processor |
        Select-Object Name,Manufacturer,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed |
        Format-List | Out-File (Join-Path $SessionDir 'system-cpu.txt') -Encoding utf8
    Get-CimInstance Win32_VideoController |
        Select-Object Name,DriverVersion,AdapterRAM |
        Format-List | Out-File (Join-Path $SessionDir 'system-gpu.txt') -Encoding utf8
} catch {}

$Jcmd = Find-CompatibleJavaTool -ToolName 'jcmd.exe' -MinecraftJavaExe $JavaExe -WantedMajor $MinecraftJavaMajor `
    -ReportPath (Join-Path $SessionDir 'jcmd-selection.txt')
$JfrTool = Find-CompatibleJavaTool -ToolName 'jfr.exe' -MinecraftJavaExe $JavaExe -WantedMajor $MinecraftJavaMajor `
    -ReportPath (Join-Path $SessionDir 'jfr-tool-selection.txt')

$JfrFile = Join-Path $SessionDir 'minecraft-session.jfr'
$JfrStarted = $false

if ($Jcmd) {
    Write-Host "JVM-Diagnose: aktiv" -ForegroundColor Green
    Write-Host "jcmd: $Jcmd"

    foreach ($Spec in @(
        @{ C='VM.version'; F='jvm-version.txt'; T=10 },
        @{ C='VM.command_line'; F='jvm-command-line.txt'; T=10 },
        @{ C='VM.flags'; F='jvm-flags.txt'; T=10 },
        @{ C='VM.system_properties'; F='jvm-system-properties.txt'; T=12 },
        @{ C='VM.info'; F='jvm-info.txt'; T=12 },
        @{ C='GC.heap_info'; F='heap-info-start.txt'; T=10 }
    )) {
        [void](Invoke-JcmdToFile -Jcmd $Jcmd -MinecraftPid $MinecraftPid -Command $Spec.C `
            -TimeoutSeconds $Spec.T -OutputPath (Join-Path $SessionDir $Spec.F))
    }

    try {
        $Pth = Join-Path $SessionDir 'jvm-command-line.txt'
        if (Test-Path -LiteralPath $Pth) {
            Write-Utf8File -Path $Pth -Content (Protect-CommandLineSecrets (Get-Content $Pth -Raw))
        }
    } catch {}

    $JfrState = Ensure-JfrRecording -Jcmd $Jcmd -MinecraftPid $MinecraftPid `
        -RecordingName 'MinecraftAI' -JfrFile $JfrFile -SessionDir $SessionDir
    $JfrStarted = [bool]$JfrState.Active

    Write-Utf8File -Path (Join-Path $SessionDir 'jfr-state.txt') -Content @(
        "Active: $($JfrState.Active)"
        "ReusedExisting: $($JfrState.ReusedExisting)"
        "StartReportedSuccess: $($JfrState.StartReportedSuccess)"
        "VerifiedByCheck: $($JfrState.VerifiedByCheck)"
        "Rolling window: maxage=15m, maxsize=96m"
        "Message: $($JfrState.Message)"
    )

    if ($JfrStarted) {
        Write-Host "JFR-Flugschreiber: aktiv (15-Min-Rolling + geschuetzte Meilensteine)" -ForegroundColor Green
    }
    else {
        Write-Host "JFR konnte nicht aktiviert werden; der Rest der Diagnose laeuft weiter." -ForegroundColor Yellow
    }
}
else {
    Write-Host "JVM-Diagnose: nur Basisdaten" -ForegroundColor Yellow
    Write-Host "Kein kompatibles jcmd.exe gefunden; der Session-Export funktioniert trotzdem."
}

Write-Host ""
Write-Host "Du kannst jetzt normal spielen." -ForegroundColor Cyan
Write-Host "E = Problemzeitpunkt markieren (optional; darf auch zu frueh/zu spaet sein)."
Write-Host "Minecraft danach einfach normal schliessen."
Write-Host ""

$Csv = Join-Path $SessionDir 'process-samples.csv'
'TIME,CPU_SECONDS,WORKING_SET_BYTES,PRIVATE_BYTES,HANDLES,THREADS' | Out-File $Csv -Encoding ascii
$LatestLogPath = Join-Path $ProfilePath 'logs\latest.log'

$LastSample = Get-Date
$LastRollingSnapshot = $GameStart
$LastLogScan = [DateTime]::MinValue
$LastHeuristicCheck = [DateTime]::MinValue
$Incident = 0
$IgnoredIdleCandidates = 0
$UniqueStallSnapshots = 0
$MaxUniqueStallSnapshots = 6
$RollingIntervalSeconds = 300
$HeuristicSilenceSeconds = 45
$HeuristicCooldownSeconds = 75
$StallDedupeWindowSeconds = 180

$StartupCompleteAt = $null
$WorldEntryAt = $null
$WorldEntryLine = ''
$StartupSnapshotDone = $false
$WorldEntrySnapshotDone = $false
$WorldEntryFollowupDone = $false
$StartupJfrRel = ''
$WorldEntryJfrRel = ''
$WorldEntryFollowupJfrRel = ''
$FinalRollingJfrRel = ''
$LastCapturedStallSignature = ''
$LastCapturedStallTime = [DateTime]::MinValue
$LastCapturedStallId = ''
$LastCapturedStallSnapshot = ''
$LastCapturedStallJfr = ''
$StallSequence = 0
$script:StallEvents = New-Object System.Collections.Generic.List[object]
$SeenStrongLogEvents = New-Object 'System.Collections.Generic.HashSet[string]'

function Add-VerifiedStall {
    param(
        [datetime]$Time,
        [Int64]$DurationMs,
        [string]$DurationText,
        [string]$Trigger,
        [string]$Source,
        [string]$PreCapturedThreadDump = ''
    )

    $script:StallSequence++
    $Id = ('STALL-{0:D2}' -f $script:StallSequence)
    $ThreadDump = $PreCapturedThreadDump

    if (-not $ThreadDump -and $script:Jcmd) {
        $R = Invoke-ProcessWithTimeout -FilePath $script:Jcmd `
            -ArgumentList @([string]$script:MinecraftPid,'Thread.print','-l') -TimeoutSeconds 15
        $ThreadDump = [string]$R.Output
    }

    $ServerSection = Get-ServerThreadSection -ThreadDump $ThreadDump
    $Signature = Get-ServerThreadSignature -Section $ServerSection
    $Dedup = $false
    $DedupFrom = ''
    $SnapshotRel = ''
    $JfrRel = ''

    if (
        $script:LastCapturedStallSignature -and
        $Signature -eq $script:LastCapturedStallSignature -and
        (($Time - $script:LastCapturedStallTime).TotalSeconds -le $script:StallDedupeWindowSeconds)
    ) {
        $Dedup = $true
        $DedupFrom = $script:LastCapturedStallId
        $SnapshotRel = $script:LastCapturedStallSnapshot
        $JfrRel = $script:LastCapturedStallJfr
    }
    elseif ($script:UniqueStallSnapshots -lt $script:MaxUniqueStallSnapshots) {
        $script:UniqueStallSnapshots++
        $D = Join-Path $script:AutoStallsDir (('{0}_{1}' -f $Id,$Time.ToString('yyyy-MM-dd_HH-mm-ss')))
        New-Item -ItemType Directory -Path $D -Force | Out-Null
        Write-Utf8File -Path (Join-Path $D 'reason.txt') -Content @(
            "Id: $Id"
            "Time: " + $Time.ToString('yyyy-MM-dd HH:mm:ss.fff')
            "Duration: $DurationText"
            "Trigger: $Trigger"
            "Source: $Source"
            "Server-thread signature: $Signature"
        )

        $ThreadsPath = Join-Path $D 'threads.txt'
        if ($ThreadDump) { Write-Utf8File -Path $ThreadsPath -Content $ThreadDump }
        elseif ($script:Jcmd) {
            [void](Invoke-JcmdToFile -Jcmd $script:Jcmd -MinecraftPid $script:MinecraftPid -Command 'Thread.print' `
                -ExtraArgs @('-l') -TimeoutSeconds 15 -OutputPath $ThreadsPath)
        }
        $ServerSection = Save-ServerThreadExcerpt -ThreadDumpPath $ThreadsPath -OutputPath (Join-Path $D 'server-thread.txt')
        if ($script:Jcmd) {
            [void](Invoke-JcmdToFile -Jcmd $script:Jcmd -MinecraftPid $script:MinecraftPid -Command 'GC.heap_info' `
                -TimeoutSeconds 12 -OutputPath (Join-Path $D 'heap-info.txt'))
        }

        $StallJfr = Join-Path $D 'stall.jfr'
        if (Save-JfrSnapshot -MinecraftPid $script:MinecraftPid -Jcmd $script:Jcmd -JfrActive $script:JfrStarted `
            -OutputPath $StallJfr -ResultPath (Join-Path $D 'jfr-dump-result.txt')) {
            $JfrRel = Get-SessionRelativePath -Base $script:SessionDir -Path $StallJfr
        }
        $SnapshotRel = Get-SessionRelativePath -Base $script:SessionDir -Path $D
        $script:LastCapturedStallSignature = $Signature
        $script:LastCapturedStallTime = $Time
        $script:LastCapturedStallId = $Id
        $script:LastCapturedStallSnapshot = $SnapshotRel
        $script:LastCapturedStallJfr = $JfrRel
    }

    $Event = [pscustomobject]@{
        Id=$Id
        Time=$Time
        DurationMs=$DurationMs
        DurationText=$DurationText
        Trigger=$Trigger
        Source=$Source
        Signature=$Signature
        Snapshot=$SnapshotRel
        Jfr=$JfrRel
        DeduplicatedFrom=$DedupFrom
    }
    [void]$script:StallEvents.Add($Event)

    if ($Dedup) {
        Write-Host ("Auto-Stall $Id erkannt; identischer Snapshot wie $DedupFrom -> dedupliziert.") -ForegroundColor DarkYellow
    }
    elseif ($SnapshotRel) {
        Write-Host ("Auto-Stall $Id gespeichert: $DurationText") -ForegroundColor Yellow
    }
    else {
        Write-Host ("Auto-Stall $Id erkannt; Snapshot-Limit erreicht, nur Metadaten gespeichert.") -ForegroundColor DarkYellow
    }
}

# Funktionen greifen auf die aktuellen Session-Variablen zu.
$script:Jcmd = $Jcmd
$script:MinecraftPid = $MinecraftPid
$script:JfrStarted = $JfrStarted
$script:AutoStallsDir = $AutoStallsDir
$script:SessionDir = $SessionDir
$script:UniqueStallSnapshots = $UniqueStallSnapshots
$script:MaxUniqueStallSnapshots = $MaxUniqueStallSnapshots
$script:StallDedupeWindowSeconds = $StallDedupeWindowSeconds
$script:LastCapturedStallSignature = $LastCapturedStallSignature
$script:LastCapturedStallTime = $LastCapturedStallTime
$script:LastCapturedStallId = $LastCapturedStallId
$script:LastCapturedStallSnapshot = $LastCapturedStallSnapshot
$script:LastCapturedStallJfr = $LastCapturedStallJfr
$script:StallSequence = $StallSequence

while ($true) {
    try { $P = Get-Process -Id $MinecraftPid -ErrorAction Stop } catch { break }
    $Now = Get-Date

    if (($Now - $LastSample).TotalSeconds -ge 5) {
        $LastSample = $Now
        Add-Content -LiteralPath $Csv -Encoding ascii -Value (@(
            $Now.ToString('yyyy-MM-dd HH:mm:ss.fff'),
            [Math]::Round($P.CPU,3),
            $P.WorkingSet64,
            $P.PrivateMemorySize64,
            $P.Handles,
            $P.Threads.Count
        ) -join ',')
    }

    # Log-Marker nur alle 2 s pruefen. Der Log bleibt vollstaendig erhalten;
    # diese Suche dient nur der Timeline und starken Stall-Triggern.
    if (($Now - $LastLogScan).TotalSeconds -ge 2 -and (Test-Path -LiteralPath $LatestLogPath)) {
        $LastLogScan = $Now
        try {
            $Tail = @(Get-Content -LiteralPath $LatestLogPath -Tail 320 -ErrorAction SilentlyContinue)
            foreach ($Line in $Tail) {
                $LineTime = Get-LogEventTime -Line $Line -ReferenceTime $Now
                if (-not $StartupCompleteAt -and $Line -match '(?i)(Game took\s+[0-9.,]+\s+seconds to start|ScreenCustomizationLayer registered:\s*title_screen)') {
                    $StartupCompleteAt = $LineTime
                }

                if (-not $WorldEntryAt -and $Line -match '(?i)(logged in with entity id| joined the game|Time from main menu to in-game was)') {
                    $WorldEntryAt = $LineTime
                    $WorldEntryLine = $Line.Trim()
                }

                if ($Line -match '(?i)A single server tick has taken\s+(\d+),\s+more than\s+(\d+)\s+milliseconds') {
                    $Key = 'watchdog|' + $Line
                    if ($SeenStrongLogEvents.Add($Key)) {
                        $Dur = [Int64]$Matches[1]
                        Add-VerifiedStall -Time $LineTime -DurationMs $Dur -DurationText ($Dur.ToString() + ' ms') `
                            -Trigger $Line.Trim() -Source 'ModernFix IntegratedWatchdog'
                    }
                }
                elseif ($Line -match '(?i)Can.t keep up!.*Running\s+([0-9]+)ms.*?([0-9]+)\s+ticks behind') {
                    $Dur = [Int64]$Matches[1]
                    if ($Dur -ge 2000) {
                        $Key = 'cantkeepup|' + $Line
                        if ($SeenStrongLogEvents.Add($Key)) {
                            Add-VerifiedStall -Time $LineTime -DurationMs $Dur -DurationText ($Dur.ToString() + ' ms behind') `
                                -Trigger $Line.Trim() -Source 'Minecraft server lag warning'
                        }
                    }
                }
            }
        } catch {}
    }

    # Geschuetzter Startup-Snapshot: bevorzugt beim Erreichen des Hauptmenues,
    # sonst einmal nach 90 s als Fallback. Er wird nie vom Rolling-Snapshot geloescht.
    if ($JfrStarted -and -not $StartupSnapshotDone -and ($StartupCompleteAt -or (($Now-$GameStart).TotalSeconds -ge 90))) {
        $StartupSnapshotDone = $true
        New-Item -ItemType Directory -Path $MilestonesDir -Force | Out-Null
        $Pth = Join-Path $MilestonesDir ('startup_' + $Now.ToString('yyyy-MM-dd_HH-mm-ss') + '.jfr')
        if (Save-JfrSnapshot -MinecraftPid $MinecraftPid -Jcmd $Jcmd -JfrActive $JfrStarted -OutputPath $Pth `
            -ResultPath ($Pth + '.txt')) {
            $StartupJfrRel = Get-SessionRelativePath -Base $SessionDir -Path $Pth
        }
    }

    # Weltbeitritt wird separat konserviert, damit spaetere Rolling-Aufnahmen
    # Start + erste Chunkgeneration nicht ueberschreiben koennen.
    if ($JfrStarted -and $WorldEntryAt -and -not $WorldEntrySnapshotDone) {
        $WorldEntrySnapshotDone = $true
        New-Item -ItemType Directory -Path $MilestonesDir -Force | Out-Null
        $Pth = Join-Path $MilestonesDir ('world-entry_' + $Now.ToString('yyyy-MM-dd_HH-mm-ss') + '.jfr')
        if (Save-JfrSnapshot -MinecraftPid $MinecraftPid -Jcmd $Jcmd -JfrActive $JfrStarted -OutputPath $Pth `
            -ResultPath ($Pth + '.txt')) {
            $WorldEntryJfrRel = Get-SessionRelativePath -Base $SessionDir -Path $Pth
        }
    }

    if ($JfrStarted -and $WorldEntryAt -and -not $WorldEntryFollowupDone -and (($Now-([datetime]$WorldEntryAt)).TotalSeconds -ge 90)) {
        $WorldEntryFollowupDone = $true
        New-Item -ItemType Directory -Path $MilestonesDir -Force | Out-Null
        $Pth = Join-Path $MilestonesDir ('world-entry-plus-90s_' + $Now.ToString('yyyy-MM-dd_HH-mm-ss') + '.jfr')
        if (Save-JfrSnapshot -MinecraftPid $MinecraftPid -Jcmd $Jcmd -JfrActive $JfrStarted -OutputPath $Pth `
            -ResultPath ($Pth + '.txt')) {
            $WorldEntryFollowupJfrRel = Get-SessionRelativePath -Base $SessionDir -Path $Pth
        }
    }

    # Nur noch alle 5 Minuten ein Force-Close-Sicherungsdump; nur der letzte
    # wird behalten. Bei normalem Ende wird er entfernt, wenn minecraft-session.jfr gueltig ist.
    if ($JfrStarted -and $Jcmd -and (($Now - $LastRollingSnapshot).TotalSeconds -ge $RollingIntervalSeconds)) {
        $LastRollingSnapshot = $Now
        New-Item -ItemType Directory -Path $SnapshotsDir -Force | Out-Null
        $Snap = Join-Path $SnapshotsDir ('rolling_latest_' + $Now.ToString('yyyy-MM-dd_HH-mm-ss') + '.jfr')
        [void](Save-JfrSnapshot -MinecraftPid $MinecraftPid -Jcmd $Jcmd -JfrActive $JfrStarted -OutputPath $Snap `
            -ResultPath ($Snap + '.txt'))
        try {
            $Old = @(Get-ChildItem -LiteralPath $SnapshotsDir -Filter '*.jfr' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip 1)
            foreach ($F in $Old) {
                Remove-Item -LiteralPath $F.FullName -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath ($F.FullName + '.txt') -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }

    # Heuristik nur als zweite Ebene: Log-Stille alleine ist KEIN Stall.
    # Erst zwei Serverthread-Samples muessen ueber mehrere Sekunden aktiv/nicht-idle sein.
    if (
        $Jcmd -and $WorldEntryAt -and (Test-Path -LiteralPath $LatestLogPath) -and
        (($Now - $LastHeuristicCheck).TotalSeconds -ge $HeuristicCooldownSeconds)
    ) {
        try {
            $LogAge = ($Now - (Get-Item -LiteralPath $LatestLogPath).LastWriteTime).TotalSeconds
            if ($LogAge -ge $HeuristicSilenceSeconds) {
                $LastHeuristicCheck = $Now
                $R1 = Invoke-ProcessWithTimeout -FilePath $Jcmd -ArgumentList @([string]$MinecraftPid,'Thread.print','-l') -TimeoutSeconds 15
                $T1 = [string]$R1.Output
                $S1 = Get-ServerThreadSection -ThreadDump $T1
                if (Test-ServerThreadIdle -Section $S1) {
                    $IgnoredIdleCandidates++
                }
                elseif ($S1) {
                    Start-Sleep -Seconds 4
                    try { Get-Process -Id $MinecraftPid -ErrorAction Stop | Out-Null } catch { continue }
                    $R2 = Invoke-ProcessWithTimeout -FilePath $Jcmd -ArgumentList @([string]$MinecraftPid,'Thread.print','-l') -TimeoutSeconds 15
                    $T2 = [string]$R2.Output
                    $S2 = Get-ServerThreadSection -ThreadDump $T2
                    if (Test-ServerThreadIdle -Section $S2) {
                        $IgnoredIdleCandidates++
                    }
                    elseif ($S2) {
                        $Sig1 = Get-ServerThreadSignature -Section $S1
                        $Sig2 = Get-ServerThreadSignature -Section $S2
                        $Why = if ($Sig1 -eq $Sig2) {
                            "Server thread stayed on the same non-idle stack for >=4 s while latest.log was silent for $([Math]::Round($LogAge,1)) s"
                        } else {
                            "Server thread stayed non-idle across two samples for >=4 s while latest.log was silent for $([Math]::Round($LogAge,1)) s"
                        }
                        Add-VerifiedStall -Time $Now -DurationMs 4000 -DurationText '>=4000 ms observed (heuristic)' `
                            -Trigger $Why -Source 'server-thread two-sample heuristic' -PreCapturedThreadDump $T2
                    }
                }
            }
        } catch {}
    }

    try {
        if ([Console]::KeyAvailable) {
            $K = [Console]::ReadKey($true)
            if ($K.Key -eq [ConsoleKey]::E) {
                $Incident++
                $D = Join-Path $IncidentsDir (('Incident_{0:D2}_{1}' -f $Incident,$Now.ToString('yyyy-MM-dd_HH-mm-ss')))
                Capture-JvmSnapshot -MinecraftPid $MinecraftPid -Jcmd $Jcmd -Directory $D `
                    -JfrFile $(if ($JfrStarted) { Join-Path $D 'incident.jfr' } else { $null })
                [void](Save-ServerThreadExcerpt -ThreadDumpPath (Join-Path $D 'threads.txt') -OutputPath (Join-Path $D 'server-thread.txt'))
                Write-Utf8File -Path (Join-Path $D 'marker.txt') -Content @(
                    'Manual incident marker (E)'
                    'Time: ' + $Now.ToString('yyyy-MM-dd HH:mm:ss.fff')
                    'Note: The visible problem may have started earlier or may only have been suspected at this time.'
                )
                Write-Host "Problemzeitpunkt $Incident gespeichert." -ForegroundColor Yellow
            }
        }
    } catch {}

    Start-Sleep -Milliseconds 500
}

$EndAt = Get-Date
Write-Host ""
Write-Host "Minecraft wurde beendet." -ForegroundColor Green
Write-Host ""

Write-Host "[1/4] JFR sichern..." -ForegroundColor Cyan
try {
    Start-Sleep -Seconds 2
    $FinalValid = $false
    if (Test-Path -LiteralPath $JfrFile -PathType Leaf) {
        try { $FinalValid = ((Get-Item -LiteralPath $JfrFile).Length -gt 0) } catch {}
    }

    if ($FinalValid) {
        $FinalRollingJfrRel = Get-SessionRelativePath -Base $SessionDir -Path $JfrFile
        # Periodischer Force-Close-Snapshot ist nach sauberem Exit redundant.
        if (Test-Path -LiteralPath $SnapshotsDir) {
            Remove-Item -LiteralPath $SnapshotsDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "      Finale 15-Min-Rolling-JFR vorhanden; redundante Sicherungsdumps entfernt."
    }
    else {
        $LatestSnapshot = Get-LatestValidJfrSnapshot -SnapshotsDir $SnapshotsDir
        if ($LatestSnapshot) {
            $FinalRollingJfrRel = Get-SessionRelativePath -Base $SessionDir -Path $LatestSnapshot.FullName
            Write-Utf8File -Path (Join-Path $SessionDir '_JFR_RECOVERY.txt') -Content @(
                'Final dumponexit JFR was missing/empty.'
                'No duplicate copy was created.'
                'Use the latest rolling safeguard snapshot: ' + $FinalRollingJfrRel
            )
            Write-Host "      Finale JFR fehlte; letzter Rolling-Snapshot bleibt als Recovery erhalten." -ForegroundColor Yellow
        }
        elseif ($JfrStarted) {
            Write-Host "      Keine gueltige finale/rolling JFR-Datei vorhanden." -ForegroundColor Yellow
        }
        else {
            Write-Host "      JFR war in dieser Session nicht aktiv."
        }
    }
} catch {
    Write-Host "      JFR-Sicherung uebersprungen: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Script-scope counter zuruecklesen.
$UniqueStallSnapshots = $script:UniqueStallSnapshots
$StallSequence = $script:StallSequence

Write-Host "[2/4] Recorder abschliessen..." -ForegroundColor Cyan
try {
    $TimelineLines = @(
        "TYPE`tTIME`tDETAIL"
        "GAME_START`t$($GameStart.ToString('yyyy-MM-dd HH:mm:ss.fff'))`tJava process detected"
        "STARTUP_COMPLETE`t$(if ($StartupCompleteAt) { ([datetime]$StartupCompleteAt).ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '' })`tMain-menu/startup marker"
        "WORLD_ENTRY`t$(if ($WorldEntryAt) { ([datetime]$WorldEntryAt).ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '' })`t$WorldEntryLine"
        "DIAGNOSIS_END`t$($EndAt.ToString('yyyy-MM-dd HH:mm:ss.fff'))`tMinecraft process ended"
    )
    Write-Utf8File -Path (Join-Path $SessionDir 'TIMELINE.tsv') -Content $TimelineLines

    $StallTsv = New-Object System.Collections.Generic.List[string]
    [void]$StallTsv.Add("ID`tTIME`tDURATION_MS`tDURATION_TEXT`tSOURCE`tSIGNATURE`tSNAPSHOT`tJFR`tDEDUP_OF`tTRIGGER")
    foreach ($Ev in $script:StallEvents) {
        $CleanTrigger = ([string]$Ev.Trigger).Replace("`t",' ').Replace("`r",' ').Replace("`n",' ')
        [void]$StallTsv.Add((@(
            $Ev.Id,
            ([datetime]$Ev.Time).ToString('yyyy-MM-dd HH:mm:ss.fff'),
            $Ev.DurationMs,
            $Ev.DurationText,
            $Ev.Source,
            $Ev.Signature,
            $Ev.Snapshot,
            $Ev.Jfr,
            $Ev.DeduplicatedFrom,
            $CleanTrigger
        ) -join "`t"))
    }
    Write-Utf8File -Path (Join-Path $SessionDir 'STALL_EVENTS.tsv') -Content $StallTsv

    Write-DiagnoseSummary -Path (Join-Path $SessionDir 'DIAGNOSE_SUMMARY.txt') `
        -GameStart $GameStart -StartupCompleteAt $StartupCompleteAt -WorldEntryAt $WorldEntryAt `
        -WorldEntryLine $WorldEntryLine -EndAt $EndAt -JavaVersion $JavaVersionText `
        -MinecraftVersion $Versions.Minecraft -LoaderVersion $Versions.LoaderVersion `
        -StallEvents $script:StallEvents -ManualIncidents $Incident -IgnoredIdleCandidates $IgnoredIdleCandidates `
        -UniqueStallSnapshots $UniqueStallSnapshots -StartupJfr $StartupJfrRel -WorldEntryJfr $WorldEntryJfrRel `
        -WorldEntryFollowupJfr $WorldEntryFollowupJfrRel -FinalRollingJfr $FinalRollingJfrRel

    Write-Utf8File -Path (Join-Path $SessionDir '_END.txt') -Content @(
        'Minecraft process ended: ' + $EndAt.ToString('yyyy-MM-dd HH:mm:ss.fff')
        "Manual incidents: $Incident"
        "Verified stall/high-MSPT events: $($script:StallEvents.Count)"
        "Unique auto-stall heavy snapshots: $UniqueStallSnapshots"
        "Ignored normal-idle candidates: $IgnoredIdleCandidates"
        "JFR active/usable: $JfrStarted"
        ('Recorder ' + $RecorderVersion + ': startup/world-entry milestones + 15m rolling JFR; idle-aware stall detection; deduplicated snapshots.')
    )
    Write-Host "      DIAGNOSE_SUMMARY.txt erzeugt."
} catch {
    Write-Host "      Recorder-Abschluss mit Warnung: $($_.Exception.Message)" -ForegroundColor Yellow
}

if (Test-Path -LiteralPath $ExporterPath -PathType Leaf) {
    try {
        Write-Host "[3/4] Session-Daten sammeln..." -ForegroundColor Cyan
        $ExportStartedAt = Get-Date
        $ExporterArgs = @(
            '-NoProfile',
            '-ExecutionPolicy','Bypass',
            '-File',('"' + $ExporterPath + '"'),
            '-ProfilePath',('"' + $ProfilePath + '"'),
            '-OutputPath',('"' + $OutputPath + '"')
        )
        $ExportProc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList $ExporterArgs `
            -NoNewWindow -PassThru

        $ExitedInTime = $ExportProc.WaitForExit(10 * 60 * 1000)
        if (-not $ExitedInTime) {
            try { $ExportProc.Kill() } catch {}
            Write-Host "Der Session-Export wurde nach 10 Minuten beendet (Timeout)." -ForegroundColor Red
            Write-Host "Recorder-Rohdaten: $SessionDir"
            exit 2
        }
        try { $ExportProc.WaitForExit() } catch {}
        try { $ExportProc.Refresh() } catch {}

        $ExporterExitCode = $null
        try { if ($ExportProc.HasExited) { $ExporterExitCode = [int]$ExportProc.ExitCode } } catch {}
        if ($null -ne $ExporterExitCode -and $ExporterExitCode -ne 0) {
            Write-Host "Der Exporter wurde mit ExitCode $ExporterExitCode beendet." -ForegroundColor Yellow
            Write-Host "Recorder-Rohdaten: $SessionDir"
            exit $ExporterExitCode
        }

        if ($null -eq $ExporterExitCode) {
            $ExportParent = $OutputPath
            $RecentZip = $null
            if (Test-Path -LiteralPath $ExportParent) {
                $RecentZip = Get-ChildItem -LiteralPath $ExportParent -Filter ($ProfileName + '_Session-Analyse_*.zip') -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -ge $ExportStartedAt.AddSeconds(-5) -and $_.Length -gt 0 } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
            }
            if (-not $RecentZip) {
                Write-Host "Exporter beendet, aber keine neue Session-ZIP gefunden." -ForegroundColor Yellow
                exit 5
            }
        }

        Write-Host ""
        Write-Host "Recorder und Session-Export erfolgreich abgeschlossen." -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "Session-Export konnte nicht abgeschlossen werden: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Recorder-Rohdaten: $SessionDir"
        exit 3
    }
}
else {
    Write-Host "Export-Skript fehlt: $ExporterPath" -ForegroundColor Red
    Write-Host "Recorder-Rohdaten: $SessionDir"
    exit 4
}

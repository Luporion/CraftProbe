#requires -Version 5.1

param(
    [string]$ProfilePath,
    [string]$OutputPath,
    [string]$InvocationDirectory,
    [switch]$InstallPath,
    [switch]$RemovePath,
    [switch]$ManageSettings,
    [string]$UiEventsPath,
    [string]$UiCommandsPath
)

$ErrorActionPreference = "Stop"
$RecorderVersion = "0.5.0"
$RecorderStartedAt = Get-Date

# Optional TUI IPC uses JSON-lines events and append-only single-line commands.
# Neither channel is used by the normal CLI; the diagnostic core remains standalone.
$script:UiCommandCursor = 0
function Send-CraftProbeUiEvent {
    param([string]$Type,[string]$Message,[string]$Detail = '',[string]$EventId = '')
    if ([string]::IsNullOrWhiteSpace($UiEventsPath)) { return }
    try {
        $Event = [ordered]@{
            timestamp = (Get-Date).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
            type = $Type
            message = $Message
            detail = $Detail
            id = $EventId
        }
        $Line = ConvertTo-Json -InputObject $Event -Depth 4 -Compress
        # Always UTF-8 and one JSON object per line, without BOM.
        $Bytes = ([System.Text.UTF8Encoding]::new($false)).GetBytes($Line + "`n")
        $Stream = [System.IO.FileStream]::new($UiEventsPath,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
        try { $Stream.Write($Bytes,0,$Bytes.Length) } finally { $Stream.Dispose() }
    } catch { } # UI is optional: cannot bring down the recorder
}
function Read-CraftProbeUiCommands {
    if ([string]::IsNullOrWhiteSpace($UiCommandsPath)) { return @() }
    try {
        if (-not (Test-Path -LiteralPath $UiCommandsPath -PathType Leaf)) { return @() }
        $All = @(Get-Content -LiteralPath $UiCommandsPath -ErrorAction Stop)
        if ($All.Count -lt $script:UiCommandCursor) { $script:UiCommandCursor = 0 }
        $New = New-Object System.Collections.Generic.List[string]
        for ($j = $script:UiCommandCursor; $j -lt $All.Count; $j++) {
            $Line = ([string]$All[$j]).Trim().ToLowerInvariant()
            if ($Line -in @('incident','e')) { [void]$New.Add('incident') }
        }
        $script:UiCommandCursor = $All.Count
        return $New.ToArray()
    } catch { return @() }
}
Send-CraftProbeUiEvent -Type 'starting' -Message 'CraftProbe gestartet' -Detail 'Profil wird aufgelöst'

# ============================================================
# CraftProbe
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

function Show-CraftProbeFolderPicker {
    param(
        [string]$InitialDirectory,
        [string]$Title = 'CraftProbe - Minecraft profile/game directory (mods, config, logs, saves...)'
    )

    # Use the native Windows Vista+ IFileOpenDialog in folder-picking mode.
    # Unlike FolderBrowserDialog this provides the normal Explorer UI,
    # including the breadcrumb/address bar and direct path navigation.
    try {
        if (-not ('CraftProbe.NativeFolderPicker' -as [type])) {
            $Source = @"
using System;
using System.Runtime.InteropServices;

namespace CraftProbe {
    internal enum SIGDN : uint {
        FILESYSPATH = 0x80058000
    }

    [Flags]
    internal enum FOS : uint {
        PICKFOLDERS = 0x00000020,
        FORCEFILESYSTEM = 0x00000040,
        PATHMUSTEXIST = 0x00000800,
        DONTADDTORECENT = 0x02000000
    }

    [ComImport]
    [Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(SIGDN sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport]
    [Guid("d57c7288-d4ad-4768-be02-9d969532d960")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOpenDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(FOS fos);
        void GetOptions(out FOS pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        void GetResults(out IntPtr ppenum);
        void GetSelectedItems(out IntPtr ppsai);
    }

    [ComImport]
    [Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogRCW { }

    [ComImport]
    [Guid("B63EA76D-1F85-456F-A19C-48159EFA858B")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItemArray { }

    public static class NativeFolderPicker {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(
            [MarshalAs(UnmanagedType.LPWStr)] string pszPath,
            IntPtr pbc,
            ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);

        public static string Show(string initialDirectory, string title) {
            IFileOpenDialog dialog = null;
            IShellItem initial = null;
            IShellItem result = null;
            try {
                dialog = (IFileOpenDialog)new FileOpenDialogRCW();
                FOS options;
                dialog.GetOptions(out options);
                dialog.SetOptions(options | FOS.PICKFOLDERS | FOS.FORCEFILESYSTEM | FOS.PATHMUSTEXIST | FOS.DONTADDTORECENT);
                dialog.SetTitle(title ?? "Select Minecraft profile/game directory");
                dialog.SetOkButtonLabel("Select folder");

                if (!String.IsNullOrWhiteSpace(initialDirectory) && System.IO.Directory.Exists(initialDirectory)) {
                    Guid iid = typeof(IShellItem).GUID;
                    SHCreateItemFromParsingName(initialDirectory, IntPtr.Zero, ref iid, out initial);
                    dialog.SetFolder(initial);
                }

                int hr = dialog.Show(IntPtr.Zero);
                if (hr == unchecked((int)0x800704C7)) return null; // cancelled
                if (hr < 0) Marshal.ThrowExceptionForHR(hr);

                dialog.GetResult(out result);
                IntPtr ptr;
                result.GetDisplayName(SIGDN.FILESYSPATH, out ptr);
                try { return Marshal.PtrToStringUni(ptr); }
                finally { Marshal.FreeCoTaskMem(ptr); }
            }
            finally {
                if (result != null) Marshal.ReleaseComObject(result);
                if (initial != null) Marshal.ReleaseComObject(initial);
                if (dialog != null) Marshal.ReleaseComObject(dialog);
            }
        }
    }
}
"@
            Add-Type -TypeDefinition $Source -Language CSharp -ErrorAction Stop
        }

        $Start = $InitialDirectory
        if ([string]::IsNullOrWhiteSpace($Start) -or -not (Test-Path -LiteralPath $Start -PathType Container)) {
            try { $Start = (Get-Location).Path } catch { $Start = $env:USERPROFILE }
        }

        return [CraftProbe.NativeFolderPicker]::Show(
            $Start,
            $Title
        )
    }
    catch {
        return $null
    }
}

$SettingsModule = Join-Path $PSScriptRoot 'CraftProbe-Settings.ps1'
if (-not (Test-Path -LiteralPath $SettingsModule -PathType Leaf)) {
    throw "CraftProbe-Settings.ps1 fehlt: $SettingsModule"
}
. $SettingsModule

if ($InstallPath) {
    Install-CraftProbePath
    exit 0
}
if ($RemovePath) {
    Uninstall-CraftProbePath
    exit 0
}
if ($ManageSettings) {
    $ManageState = Get-CraftProbeSettings
    Manage-CraftProbeSettings -Settings $ManageState
    exit 0
}

if ([string]::IsNullOrWhiteSpace($InvocationDirectory)) {
    try { $InvocationDirectory = (Get-Location).Path } catch { $InvocationDirectory = $null }
}

try {
    $StartupPaths = Resolve-CraftProbeStartupPaths -RequestedProfilePath $ProfilePath -RequestedOutputPath $OutputPath -InvocationDirectory $InvocationDirectory
}
catch [System.OperationCanceledException] {
    Write-Host 'CraftProbe wurde abgebrochen.' -ForegroundColor DarkGray
    exit 0
}
$ProfilePath = $StartupPaths.ProfilePath
$OutputPath = $StartupPaths.OutputPath
$SettingsPath = $StartupPaths.SettingsPath

$ProfileName = Split-Path -Leaf $ProfilePath
if ($ProfileName -eq '.minecraft') { $ProfileName = Split-Path -Leaf (Split-Path -Parent $ProfilePath) }
$ExporterPath = Join-Path $PSScriptRoot 'Export-Minecraft-Session-Analyse.ps1'

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

function Get-MinecraftJavaCandidates {
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

        # Launchers such as CurseForge briefly execute java/javaw -version while
        # validating the configured runtime. Never attach to these helper probes.
        $IsJavaProbe = (
            $Cmd -match '(?i)(^|\s)(?:-version|--version|-showversion)(?:\s|$)' -or
            $Cmd -match '(?i)(^|\s)-XshowSettings(?::\S+)?(?:\s|$)'
        )

        $HasProfilePath = ($Normalized.IndexOf($Wanted,[StringComparison]::OrdinalIgnoreCase) -ge 0)
        $HasGameDir = ($Cmd -match '(?i)(^|\s)--gameDir(?:\s|=)')
        $HasMinecraftMain = (
            $Cmd -match '(?i)cpw\.mods\.bootstraplauncher\.BootstrapLauncher' -or
            $Cmd -match '(?i)net\.minecraft\.client\.main\.Main' -or
            $Cmd -match '(?i)net\.minecraft\.server\.Main' -or
            $Cmd -match '(?i)net\.fabricmc\.loader\..*\.KnotClient' -or
            $Cmd -match '(?i)org\.quiltmc\.loader\..*\.KnotClient' -or
            $Cmd -match '(?i)net\.minecraftforge\..*ForgeBootstrap'
        )
        $HasModdedLaunchTarget = ($Cmd -match '(?i)(^|\s)--launchTarget(?:\s|=)\S*(?:client|server)')

        $HasStrongIdentity = ($HasProfilePath -or $HasGameDir -or $HasMinecraftMain -or $HasModdedLaunchTarget)
        if ($IsJavaProbe -and -not $HasStrongIdentity) { continue }
        if (-not $HasStrongIdentity) { continue }

        $Score = 0
        if ($HasProfilePath) { $Score += 200 }
        if ($HasGameDir) { $Score += 100 }
        if ($HasMinecraftMain) { $Score += 120 }
        if ($HasModdedLaunchTarget) { $Score += 80 }
        if ($Cmd -match '(?i)-Dminecraft\.launcher\.(?:brand|version)=') { $Score += 20 }
        if ($Cmd -match '(?i)(?:neoforge|forge|fabric-loader|quilt-loader)') { $Score += 20 }

        $Creation = $null
        try {
            if ($Proc.CreationDate -is [datetime]) { $Creation = [datetime]$Proc.CreationDate }
            else { $Creation = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Proc.CreationDate) }
        } catch {}
        # A late-attach scan intentionally uses DateTime.MinValue to mean
        # "no lower start-time bound". Do not subtract from DateTime.MinValue:
        # doing so throws ArgumentOutOfRangeException before an already-running
        # Minecraft JVM can be selected.
        if ($Creation -and $NotBefore -gt [datetime]::MinValue.AddMinutes(1)) {
            if ($Creation -ge $NotBefore.AddSeconds(-10)) { $Score += 10 }
        }

        [void]$Candidates.Add([pscustomobject]@{
            Process = $Proc
            Score = $Score
            Creation = $Creation
            HasProfilePath = $HasProfilePath
            HasGameDir = $HasGameDir
            HasMinecraftMain = $HasMinecraftMain
        })
    }

    return @($Candidates.ToArray() | Sort-Object Score,Creation -Descending)
}

function Find-MinecraftJavaProcess {
    param(
        [string]$WantedProfilePath,
        [datetime]$NotBefore = ([datetime]::MinValue)
    )

    $Best = @(Get-MinecraftJavaCandidates -WantedProfilePath $WantedProfilePath -NotBefore $NotBefore | Select-Object -First 1)
    if ($Best.Count -gt 0 -and $Best[0].Score -ge 80) { return $Best[0].Process }
    return $null
}

function Get-CraftProbeProcessCreationTime {
    param($Process)
    if ($null -eq $Process) { return $null }
    try {
        if ($Process.CreationDate -is [datetime]) { return [datetime]$Process.CreationDate }
        if ($Process.CreationDate) { return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Process.CreationDate) }
    } catch {}
    return $null
}

function Format-CraftProbeDuration {
    param([double]$Seconds)
    $Seconds = [Math]::Abs($Seconds)
    $Ts = [TimeSpan]::FromSeconds($Seconds)
    if ($Ts.TotalHours -ge 1) { return ('{0}h {1}m {2}s' -f [Math]::Floor($Ts.TotalHours),$Ts.Minutes,$Ts.Seconds) }
    if ($Ts.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [Math]::Floor($Ts.TotalMinutes),$Ts.Seconds) }
    return ('{0:0.0}s' -f $Ts.TotalSeconds)
}

function Select-CraftProbeMinecraftCandidate {
    param(
        [object[]]$Candidates,
        [string]$ProfileName
    )

    $Valid = @($Candidates | Where-Object { $_.Score -ge 80 })
    if ($Valid.Count -eq 0) { return $null }
    if ($Valid.Count -eq 1) { return $Valid[0].Process }

    Write-Host ''
    Write-Host 'Mehrere passende Minecraft-Prozesse laufen bereits:' -ForegroundColor Yellow
    for ($i=0; $i -lt $Valid.Count; $i++) {
        $C = $Valid[$i]
        $Started = if ($C.Creation) { ([datetime]$C.Creation).ToString('yyyy-MM-dd HH:mm:ss') } else { '<unbekannt>' }
        Write-Host ((' {0}. PID {1} | Start {2} | Profil {3}' -f ($i+1),$C.Process.ProcessId,$Started,$ProfileName))
    }
    Write-Host ''
    $Answer = Read-Host ('Auswahl [Enter = 1]')
    if ([string]::IsNullOrWhiteSpace($Answer)) { return $Valid[0].Process }
    $Index = 0
    if ([int]::TryParse($Answer,[ref]$Index) -and $Index -ge 1 -and $Index -le $Valid.Count) {
        return $Valid[$Index-1].Process
    }
    Write-Host 'Ungueltige Auswahl; verwende Eintrag 1.' -ForegroundColor Yellow
    return $Valid[0].Process
}

function ConvertTo-CraftProbeNativeArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument) { return '""' }
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }

    # Windows CreateProcess/C-runtime quoting rules. This is intentionally
    # implemented here instead of relying on Start-Process -ArgumentList,
    # because Windows PowerShell 5.1 can flatten arguments containing spaces.
    $Builder = New-Object System.Text.StringBuilder
    [void]$Builder.Append('"')
    $Backslashes = 0

    foreach ($Ch in $Argument.ToCharArray()) {
        if ($Ch -eq '\') {
            $Backslashes++
            continue
        }

        if ($Ch -eq '"') {
            if ($Backslashes -gt 0) { [void]$Builder.Append(('\' * ($Backslashes * 2))) }
            [void]$Builder.Append('\"')
            $Backslashes = 0
            continue
        }

        if ($Backslashes -gt 0) {
            [void]$Builder.Append(('\' * $Backslashes))
            $Backslashes = 0
        }
        [void]$Builder.Append($Ch)
    }

    if ($Backslashes -gt 0) { [void]$Builder.Append(('\' * ($Backslashes * 2))) }
    [void]$Builder.Append('"')
    return $Builder.ToString()
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 15,
        [string]$OutputPath = $null
    )

    $Result = [ordered]@{
        Success = $false
        TimedOut = $false
        ExitCode = $null
        Output = ''
        CommandLine = ''
    }

    try {
        $QuotedArgs = @($ArgumentList | ForEach-Object { ConvertTo-CraftProbeNativeArgument -Argument ([string]$_) })
        $ArgumentString = ($QuotedArgs -join ' ')
        $Result.CommandLine = (ConvertTo-CraftProbeNativeArgument -Argument $FilePath) + $(if ($ArgumentString) { ' ' + $ArgumentString } else { '' })

        $Psi = New-Object System.Diagnostics.ProcessStartInfo
        $Psi.FileName = $FilePath
        $Psi.Arguments = $ArgumentString
        $Psi.UseShellExecute = $false
        $Psi.CreateNoWindow = $true
        $Psi.RedirectStandardOutput = $true
        $Psi.RedirectStandardError = $true

        $Proc = New-Object System.Diagnostics.Process
        $Proc.StartInfo = $Psi
        if (-not $Proc.Start()) { throw 'Process could not be started.' }

        # Read asynchronously to avoid stdout/stderr pipe deadlocks on large jcmd output.
        $StdOutTask = $Proc.StandardOutput.ReadToEndAsync()
        $StdErrTask = $Proc.StandardError.ReadToEndAsync()

        if (-not $Proc.WaitForExit([Math]::Max(1,$TimeoutSeconds) * 1000)) {
            $Result.TimedOut = $true
            try { $Proc.Kill() } catch {}
            try { $Proc.WaitForExit(3000) | Out-Null } catch {}
        }
        else {
            # Ensure async stream readers are flushed before evaluating the result.
            try { $Proc.WaitForExit() } catch {}
            $Result.ExitCode = $Proc.ExitCode
            $Result.Success = ($Proc.ExitCode -eq 0)
        }

        $Parts = New-Object System.Collections.Generic.List[string]
        try {
            $Out = $StdOutTask.Result
            if ($Out) { [void]$Parts.Add($Out.TrimEnd()) }
        } catch {}
        try {
            $Err = $StdErrTask.Result
            if ($Err) { [void]$Parts.Add($Err.TrimEnd()) }
        } catch {}
        if ($Result.TimedOut) { [void]$Parts.Add("TIMEOUT after $TimeoutSeconds seconds") }
        $Result.Output = ($Parts -join [Environment]::NewLine)
    }
    catch {
        $Result.Output = 'ERROR: ' + $_.Exception.Message
    }

    if ($OutputPath) {
        Write-Utf8File -Path $OutputPath -Content @(
            'Command: ' + $Result.CommandLine
            'ExitCode: ' + $(if ($null -ne $Result.ExitCode) { $Result.ExitCode } else { '<none>' })
            'TimedOut: ' + $Result.TimedOut
            ''
            $Result.Output
        )
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
        [void](Save-JfrSnapshot -MinecraftPid $MinecraftPid -Jcmd $Jcmd -JfrActive $true `
            -OutputPath $JfrFile -ResultPath (Join-Path $Directory "jfr-dump-result.txt"))
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

function Test-JfrArtifact {
    param(
        [string]$Path,
        [string]$ValidationPath = $null,
        [string]$JfrTool = $null
    )

    $Result = [ordered]@{
        Valid = $false
        Exists = $false
        SizeBytes = 0
        ToolVerified = $false
        Status = 'MISSING'
        Message = ''
    }

    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $Result.Message = 'JFR file does not exist.'
        }
        else {
            $Info = Get-Item -LiteralPath $Path -ErrorAction Stop
            $Result.Exists = $true
            $Result.SizeBytes = [int64]$Info.Length
            if ($Info.Length -lt 1024) {
                $Result.Status = 'INVALID'
                $Result.Message = 'JFR file is smaller than 1 KiB.'
            }
            elseif ($JfrTool -and (Test-Path -LiteralPath $JfrTool -PathType Leaf)) {
                $SummaryPath = $ValidationPath
                if (-not $SummaryPath) { $SummaryPath = $Path + '.summary.txt' }
                $Check = Invoke-ProcessWithTimeout -FilePath $JfrTool -ArgumentList @('summary',$Path) `
                    -TimeoutSeconds 20 -OutputPath $SummaryPath
                if ($Check.Success) {
                    $Result.Valid = $true
                    $Result.ToolVerified = $true
                    $Result.Status = 'OK'
                    $Result.Message = 'JFR validated with jfr summary.'
                }
                else {
                    $Result.Status = 'INVALID'
                    $Result.Message = 'jfr summary could not read the recording.'
                }
            }
            else {
                # JFR is still useful when a matching jfr.exe is unavailable; be
                # explicit that only the physical artifact could be verified.
                $Result.Valid = $true
                $Result.Status = 'OK_SIZE_ONLY'
                $Result.Message = 'JFR exists and is non-empty; jfr.exe unavailable for structural validation.'
            }
        }
    }
    catch {
        $Result.Status = 'INVALID'
        $Result.Message = $_.Exception.Message
    }

    if ($ValidationPath -and -not $Result.ToolVerified) {
        Write-Utf8File -Path $ValidationPath -Content @(
            'Status: ' + $Result.Status
            'Exists: ' + $Result.Exists
            'SizeBytes: ' + $Result.SizeBytes
            'ToolVerified: ' + $Result.ToolVerified
            'Message: ' + $Result.Message
        )
    }

    return [pscustomobject]$Result
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

        $Dump = Invoke-JcmdToFile -Jcmd $Jcmd -MinecraftPid $MinecraftPid -Command 'JFR.dump' `
            -ExtraArgs @('name=MinecraftAI',('filename=' + $OutputPath)) -TimeoutSeconds 30 -OutputPath $ResultPath

        if (-not $Dump) { return $false }

        $Validation = Test-JfrArtifact -Path $OutputPath -ValidationPath ($OutputPath + '.validation.txt') -JfrTool $script:JfrTool
        return [bool]$Validation.Valid
    }
    catch {
        try { Write-Utf8File -Path ($OutputPath + '.validation.txt') -Content ('ERROR: ' + $_.Exception.Message) } catch {}
        return $false
    }
}

function Get-CraftProbePhase {
    param(
        [datetime]$Time,
        $StartupCompleteAt,
        $WorldEntryAt
    )

    if ($WorldEntryAt) {
        $SinceEntry = ($Time - [datetime]$WorldEntryAt).TotalSeconds
        if ($SinceEntry -ge 0 -and $SinceEntry -lt 30) { return 'WORLD_ENTRY' }
        if ($SinceEntry -ge 30 -and $SinceEntry -lt 180) { return 'EARLY_CHUNKGEN' }
        if ($SinceEntry -ge 180) { return 'RUNTIME' }
    }
    if ($StartupCompleteAt -and $Time -ge [datetime]$StartupCompleteAt) { return 'MAIN_MENU' }
    return 'STARTUP'
}

function Export-LogContextForEvent {
    param(
        [string]$LatestLogPath,
        [string]$OutputPath,
        [datetime]$EventTime,
        [int]$BeforeSeconds = 30,
        [int]$AfterSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $LatestLogPath -PathType Leaf)) { return $false }
    try {
        $Lines = @(Get-Content -LiteralPath $LatestLogPath -ErrorAction Stop)
        $Selected = New-Object System.Collections.Generic.List[string]
        $From = $EventTime.AddSeconds(-$BeforeSeconds)
        $To = $EventTime.AddSeconds($AfterSeconds)
        foreach ($Line in $Lines) {
            if ($Line -notmatch '\[(?:[^\]]*\s)?\d{2}:\d{2}:\d{2}(?:[\.,]\d+)?\]') { continue }
            $T = Get-LogEventTime -Line $Line -ReferenceTime $EventTime
            if ($T -ge $From -and $T -le $To) { [void]$Selected.Add($Line) }
        }
        if ($Selected.Count -eq 0) {
            [void]$Selected.Add('# No timestamped lines matched the requested window; showing final 400 log lines instead.')
            foreach ($Line in @($Lines | Select-Object -Last 400)) { [void]$Selected.Add($Line) }
        }
        Write-Utf8File -Path $OutputPath -Content @(
            '# CraftProbe event log context'
            '# Event: ' + $EventTime.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
            '# Window: -' + $BeforeSeconds + 's / +' + $AfterSeconds + 's'
            ''
            $Selected
        )
        return $true
    } catch { return $false }
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
        [datetime]$CraftProbeStart,
        [datetime]$AttachAt,
        [bool]$LateAttach,
        [double]$StartDifferenceSeconds,
        $StartupCompleteAt,
        $WorldEntryAt,
        [string]$WorldEntryLine,
        [datetime]$EndAt,
        [string]$JavaVersion,
        [string]$MinecraftVersion,
        [string]$LoaderVersion,
        [System.Collections.IEnumerable]$StallEvents,
        [System.Collections.IEnumerable]$IncidentEvents,
        [int]$IgnoredIdleCandidates,
        [int]$UniqueStallSnapshots,
        [string]$StartupJfr,
        [string]$WorldEntryJfr,
        [string]$WorldEntryFollowupJfr,
        [string]$FinalRollingJfr,
        [string]$CaptureHealth,
        [string[]]$CaptureProblems
    )

    $Lines = New-Object System.Collections.Generic.List[string]
    [void]$Lines.Add('CRAFTPROBE DIAGNOSE SUMMARY')
    [void]$Lines.Add('==========================')
    [void]$Lines.Add('')
    [void]$Lines.Add('Recorder: ' + $RecorderVersion)
    [void]$Lines.Add('CAPTURE HEALTH: ' + $CaptureHealth)
    if ($CaptureProblems -and $CaptureProblems.Count -gt 0) {
        [void]$Lines.Add('Capture limitations / problems:')
        foreach ($Problem in $CaptureProblems) { [void]$Lines.Add('  - ' + $Problem) }
    }
    [void]$Lines.Add('')
    [void]$Lines.Add('Minecraft: ' + $MinecraftVersion)
    [void]$Lines.Add('Loader: ' + $(if ($script:DetectedLoader) { $script:DetectedLoader } else { '<unknown>' }))
    [void]$Lines.Add('Loader version: ' + $LoaderVersion)
    [void]$Lines.Add('Java: ' + $JavaVersion)
    [void]$Lines.Add('')
    [void]$Lines.Add('TIMELINE')
    [void]$Lines.Add('Minecraft process start: ' + $GameStart.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture))
    [void]$Lines.Add('CraftProbe start: ' + $CraftProbeStart.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture))
    [void]$Lines.Add('CraftProbe attached: ' + $AttachAt.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture))
    [void]$Lines.Add('Start difference (CraftProbe - Minecraft): ' + ([Math]::Round($StartDifferenceSeconds,3)) + ' s (' + (Format-CraftProbeDuration $StartDifferenceSeconds) + ')')
    [void]$Lines.Add('Late attach: ' + $(if ($LateAttach) { 'YES' } else { 'NO' }))
    [void]$Lines.Add('Attach delay (attach - Minecraft): ' + ([Math]::Round(($AttachAt-$GameStart).TotalSeconds,3)) + ' s')
    if ((($AttachAt-$GameStart).TotalSeconds) -gt 5) {
        [void]$Lines.Add('Capture coverage warning: JVM/JFR/thread evidence before CraftProbe attach is not available retroactively.')
    }
    [void]$Lines.Add('Startup/main-menu detected: ' + $(if ($StartupCompleteAt) { ([datetime]$StartupCompleteAt).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture) } else { '<not detected>' }))
    [void]$Lines.Add('World entry detected: ' + $(if ($WorldEntryAt) { ([datetime]$WorldEntryAt).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture) } else { '<not detected>' }))
    if ($WorldEntryLine) { [void]$Lines.Add('World entry log marker: ' + $WorldEntryLine) }
    [void]$Lines.Add('Diagnosis end: ' + $EndAt.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture))
    [void]$Lines.Add('')
    [void]$Lines.Add('PRESERVED JFR MILESTONES')
    $StartupWasBeforeAttach = ($StartupCompleteAt -and ([datetime]$StartupCompleteAt -lt $AttachAt.AddSeconds(-2)))
    $WorldWasBeforeAttach = ($WorldEntryAt -and ([datetime]$WorldEntryAt -lt $AttachAt.AddSeconds(-2)))
    [void]$Lines.Add('Startup: ' + $(if ($StartupJfr) { $StartupJfr } elseif ($LateAttach -and ($StartupWasBeforeAttach -or -not $StartupCompleteAt)) { '<NOT_CAPTURED_LATE_ATTACH>' } else { '<none>' }))
    [void]$Lines.Add('World entry: ' + $(if ($WorldEntryJfr) { $WorldEntryJfr } elseif ($WorldWasBeforeAttach) { '<NOT_CAPTURED_LATE_ATTACH>' } else { '<none>' }))
    [void]$Lines.Add('World entry + first chunks: ' + $(if ($WorldEntryFollowupJfr) { $WorldEntryFollowupJfr } elseif ($WorldWasBeforeAttach) { '<NOT_CAPTURED_LATE_ATTACH>' } else { '<none>' }))
    [void]$Lines.Add('Final/rolling JFR: ' + $(if ($FinalRollingJfr) { $FinalRollingJfr } else { '<none>' }))
    [void]$Lines.Add('')

    # Windows PowerShell 5.1 can throw 'Argument types do not match' when
    # an empty generic List[T] is wrapped directly in @(...). Use ToArray().
    $Events = $StallEvents.ToArray()
    $Incidents = $IncidentEvents.ToArray()
    [void]$Lines.Add('STALLS / HIGH MSPT')
    [void]$Lines.Add('Detected events: ' + $Events.Count)
    [void]$Lines.Add('Unique heavy stall snapshots: ' + $UniqueStallSnapshots)
    [void]$Lines.Add('Ignored normal-idle candidates: ' + $IgnoredIdleCandidates)
    [void]$Lines.Add('Manual E incidents: ' + $Incidents.Count)
    $RuntimeEvents = @($Events | Where-Object { $_.Phase -eq 'RUNTIME' })
    $PerfRecommended = ($Events.Count -gt 0 -or $Incidents.Count -gt 0 -or $CaptureHealth -eq 'DEGRADED')
    [void]$Lines.Add('Performance-Diagnose recommended: ' + $(if ($PerfRecommended) { 'YES' } else { 'NO - Session-Analyse should normally be enough' }))
    if ($RuntimeEvents.Count -gt 0) { [void]$Lines.Add('Recommendation reason: runtime server-thread stall/high-MSPT event detected.') }
    elseif ($Events.Count -gt 0) { [void]$Lines.Add('Recommendation reason: verified server-thread stall/high-MSPT event detected during startup/world-entry/chunk generation.') }
    elseif ($Incidents.Count -gt 0) { [void]$Lines.Add('Recommendation reason: manual incident capture exists.') }
    elseif ($CaptureHealth -eq 'DEGRADED') { [void]$Lines.Add('Recommendation reason: capture health is degraded; raw performance evidence may help.') }
    [void]$Lines.Add('')

    if ($Events.Count -eq 0) {
        [void]$Lines.Add('No verified server-thread stalls/high-MSPT events were detected.')
    }
    else {
        foreach ($E in $Events) {
            [void]$Lines.Add(('[{0}] {1}' -f $E.Id,([datetime]$E.Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)))
            [void]$Lines.Add('  Phase: ' + $E.Phase)
            [void]$Lines.Add('  Duration: ' + $E.DurationText)
            [void]$Lines.Add('  Trigger: ' + $E.Trigger)
            [void]$Lines.Add('  Source: ' + $E.Source)
            [void]$Lines.Add('  Server-thread signature: ' + $E.Signature)
            [void]$Lines.Add('  Snapshot: ' + $(if ($E.Snapshot) { $E.Snapshot } else { '<metadata only>' }))
            [void]$Lines.Add('  JFR: ' + $(if ($E.Jfr) { $E.Jfr } else { '<none>' }))
            [void]$Lines.Add('  Log context: log-context/' + $E.Id + '_latest.log.txt')
            if ($E.DeduplicatedFrom) { [void]$Lines.Add('  Deduplicated from: ' + $E.DeduplicatedFrom) }
            [void]$Lines.Add('')
        }
    }

    if ($Incidents.Count -gt 0) {
        [void]$Lines.Add('MANUAL INCIDENTS')
        foreach ($I in $Incidents) {
            [void]$Lines.Add(('[{0}] {1}' -f $I.Id,([datetime]$I.Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)))
            [void]$Lines.Add('  Phase: ' + $I.Phase)
            [void]$Lines.Add('  Snapshot: ' + $I.Directory)
            [void]$Lines.Add('  Log context: log-context/' + $I.Id + '_latest.log.txt')
        }
        [void]$Lines.Add('')
    }

    # Group recurring stalls by server-thread signature. This preserves frequency
    # and first/worst/last timing without storing dozens of duplicate heavy dumps.
    if ($Events.Count -gt 0) {
        [void]$Lines.Add('STALL GROUPS (FIRST / WORST / LAST)')
        foreach ($Group in @($Events | Group-Object Signature)) {
            $Ordered = @($Group.Group | Sort-Object Time)
            $Worst = $Group.Group | Sort-Object DurationMs -Descending | Select-Object -First 1
            [void]$Lines.Add('Signature: ' + $Group.Name)
            [void]$Lines.Add('  Occurrences: ' + $Group.Count)
            [void]$Lines.Add('  First: ' + ([datetime]$Ordered[0].Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture) + ' (' + $Ordered[0].Id + ')')
            [void]$Lines.Add('  Worst: ' + $Worst.DurationText + ' @ ' + ([datetime]$Worst.Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture) + ' (' + $Worst.Id + ')')
            [void]$Lines.Add('  Last: ' + ([datetime]$Ordered[-1].Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture) + ' (' + $Ordered[-1].Id + ')')
        }
    }

    Write-Utf8File -Path $Path -Content $Lines
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " CraftProbe v0.4.1" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Profil: $ProfileName"
Write-Host "Pfad:   $ProfilePath"
Write-Host "Export: $OutputPath"
Write-Host "Settings: $SettingsPath" -ForegroundColor DarkGray
Write-Host ""
Send-CraftProbeUiEvent -Type 'profile' -Message $ProfileName -Detail $ProfilePath
Write-Host "Pruefe, ob Minecraft fuer dieses Profil bereits laeuft..."
Write-Host ""

$MinecraftProc = $null
$ExistingCandidates = @(Get-MinecraftJavaCandidates -WantedProfilePath $ProfilePath -NotBefore ([datetime]::MinValue))
$ExistingCandidates = @($ExistingCandidates | Where-Object { $_.Score -ge 80 })

if ($ExistingCandidates.Count -gt 0) {
    $MinecraftProc = Select-CraftProbeMinecraftCandidate -Candidates $ExistingCandidates -ProfileName $ProfileName
    if ($MinecraftProc) {
        Write-Host "Bereits laufendes Minecraft gefunden; CraftProbe haengt sich an diese Sitzung an." -ForegroundColor Green
    }
}

if ($null -eq $MinecraftProc) {
    Write-Host "Kein laufendes Minecraft gefunden."
    Send-CraftProbeUiEvent -Type 'waiting' -Message 'Warte auf Minecraft' -Detail $ProfileName
    Write-Host "Starte Minecraft jetzt ganz normal mit deinem Launcher."
    Write-Host ""

    while ($null -eq $MinecraftProc) {
        $Candidate = Find-MinecraftJavaProcess -WantedProfilePath $ProfilePath -NotBefore $RecorderStartedAt
        if ($null -eq $Candidate) {
            Start-Sleep -Seconds 2
            continue
        }

        # A real Minecraft JVM must survive the short confirmation window.
        $CandidatePid = [int]$Candidate.ProcessId
        $CandidateCommandLine = [string]$Candidate.CommandLine
        Start-Sleep -Milliseconds 2000
        $Confirmed = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $CandidatePid) -ErrorAction SilentlyContinue
        if ($null -eq $Confirmed) { continue }
        if ([string]$Confirmed.CommandLine -ne $CandidateCommandLine) { continue }

        $MinecraftProc = $Confirmed
    }
}
else {
    # Existing JVMs are also revalidated so stale WMI/PID data cannot be used.
    $CandidatePid = [int]$MinecraftProc.ProcessId
    $CandidateCommandLine = [string]$MinecraftProc.CommandLine
    Start-Sleep -Milliseconds 1000
    $Confirmed = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $CandidatePid) -ErrorAction SilentlyContinue
    if ($null -eq $Confirmed -or [string]$Confirmed.CommandLine -ne $CandidateCommandLine) {
        Write-Host "Der gefundene Prozess ist waehrend der Pruefung verschwunden; warte auf Minecraft..." -ForegroundColor Yellow
        $MinecraftProc = $null
        while ($null -eq $MinecraftProc) {
            $Candidate = Find-MinecraftJavaProcess -WantedProfilePath $ProfilePath -NotBefore $RecorderStartedAt
            if ($null -eq $Candidate) { Start-Sleep -Seconds 2; continue }
            $CandidatePid = [int]$Candidate.ProcessId
            $CandidateCommandLine = [string]$Candidate.CommandLine
            Start-Sleep -Milliseconds 2000
            $Confirmed = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $CandidatePid) -ErrorAction SilentlyContinue
            if ($Confirmed -and [string]$Confirmed.CommandLine -eq $CandidateCommandLine) { $MinecraftProc = $Confirmed }
        }
    }
    else {
        $MinecraftProc = $Confirmed
    }
}

$AttachAt = Get-Date
$ProcCreation = Get-CraftProbeProcessCreationTime -Process $MinecraftProc
$GameStart = if ($ProcCreation) { [datetime]$ProcCreation } else { $AttachAt }
$StartDifferenceSeconds = ($RecorderStartedAt - $GameStart).TotalSeconds
$LateAttach = ($StartDifferenceSeconds -gt 5)
$CaptureCoverageStart = $AttachAt
$AttachDelaySeconds = ($AttachAt - $GameStart).TotalSeconds
$PartialSessionCapture = ($AttachDelaySeconds -gt 5)

$MinecraftPid = [int]$MinecraftProc.ProcessId
$JavaExe = [string]$MinecraftProc.ExecutablePath
$Stamp = $GameStart.ToString('yyyy-MM-dd_HH-mm-ss')
if ($LateAttach) { $Stamp += ('_attach_' + $RecorderStartedAt.ToString('HH-mm-ss')) }
$SessionDir = Join-Path (Join-Path $ProfilePath '_diagnose_recorder') $Stamp
$SnapshotsDir = Join-Path $SessionDir 'jfr-snapshots'
$MilestonesDir = Join-Path $SessionDir 'milestones'
$AutoStallsDir = Join-Path $SessionDir 'auto-stalls'
$IncidentsDir = Join-Path $SessionDir 'incidents'
$LogContextDir = Join-Path $SessionDir 'log-context'
New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null

Send-CraftProbeUiEvent -Type 'minecraft' -Message 'Minecraft verbunden' -Detail ("PID: " + $MinecraftPid + "; late attach: " + $LateAttach + "; delay: " + [Math]::Round($AttachDelaySeconds,1) + "s")
Write-Host "Minecraft erkannt." -ForegroundColor Green
Write-Host "PID:  $MinecraftPid"
Write-Host "Java: $JavaExe"
Write-Host "Minecraft-Start: " $GameStart.ToString('yyyy-MM-dd HH:mm:ss')
Write-Host "CraftProbe-Start: " $RecorderStartedAt.ToString('yyyy-MM-dd HH:mm:ss')
if ($LateAttach) {
    Write-Host ("Spaeter Einstieg: JA - Minecraft lief beim CraftProbe-Start bereits " + (Format-CraftProbeDuration $StartDifferenceSeconds) + ".") -ForegroundColor Yellow
    Write-Host "Hinweis: Daten vor dem CraftProbe-Start koennen nicht rueckwirkend per JFR/Thread-Dump erfasst werden." -ForegroundColor Yellow
}
elseif ($StartDifferenceSeconds -lt -1) {
    Write-Host ("Startdifferenz: CraftProbe lief " + (Format-CraftProbeDuration $StartDifferenceSeconds) + " vor Minecraft.") -ForegroundColor DarkGray
}
else {
    Write-Host ("Startdifferenz: " + (Format-CraftProbeDuration $StartDifferenceSeconds)) -ForegroundColor DarkGray
}
Write-Host "Diagnose-Anhaengezeit: " $AttachAt.ToString('yyyy-MM-dd HH:mm:ss')

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
    "Minecraft process start: " + $GameStart.ToString('yyyy-MM-dd HH:mm:ss.fff')
    "CraftProbe start: " + $RecorderStartedAt.ToString('yyyy-MM-dd HH:mm:ss.fff')
    "Attach time: " + $AttachAt.ToString('yyyy-MM-dd HH:mm:ss.fff')
    "Start difference seconds (CraftProbe - Minecraft): " + ([Math]::Round($StartDifferenceSeconds,3))
    "Attach delay seconds (attach - Minecraft): " + ([Math]::Round($AttachDelaySeconds,3))
    "Late attach: $LateAttach"
    "Partial session capture: $PartialSessionCapture"
    "Capture coverage starts: " + $CaptureCoverageStart.ToString('yyyy-MM-dd HH:mm:ss.fff')
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
$script:JfrTool = $JfrTool

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
        Send-CraftProbeUiEvent -Type 'jfr' -Message 'JFR aktiv' -Detail '15-Minuten-Rolling'
        Write-Host "JFR-Flugschreiber: aktiv (15-Min-Rolling + geschuetzte Meilensteine)" -ForegroundColor Green
    }
    else {
        Send-CraftProbeUiEvent -Type 'warning' -Message 'JFR nicht aktiv' -Detail 'Basisdiagnose laeuft weiter'
        Write-Host "JFR konnte nicht aktiviert werden; der Rest der Diagnose laeuft weiter." -ForegroundColor Yellow
    }
}
else {
    Write-Host "JVM-Diagnose: nur Basisdaten" -ForegroundColor Yellow
    Send-CraftProbeUiEvent -Type 'warning' -Message 'Kein kompatibles jcmd' -Detail 'Basisdiagnose bleibt aktiv'
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
$LastRollingSnapshot = $(if ($LateAttach) { $AttachAt } else { $GameStart })
$LastLogScan = [DateTime]::MinValue
$LastHeuristicCheck = [DateTime]::MinValue
$Incident = 0
$script:IncidentEvents = New-Object System.Collections.Generic.List[object]
$PendingIncidentCaptures = New-Object System.Collections.Generic.List[object]
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
    $Id = ('STALL-{0:D4}' -f $script:StallSequence)
    $Phase = Get-CraftProbePhase -Time $Time -StartupCompleteAt $script:StartupCompleteAt -WorldEntryAt $script:WorldEntryAt
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
        $D = Join-Path $script:AutoStallsDir (('{0}_{1}' -f $Id,$Time.ToString('yyyy-MM-dd_HH-mm-ss-fff')))
        New-Item -ItemType Directory -Path $D -Force | Out-Null
        Write-Utf8File -Path (Join-Path $D 'reason.txt') -Content @(
            "Id: $Id"
            "Time: " + $Time.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
            "Phase: $Phase"
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
        Phase=$Phase
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
    Send-CraftProbeUiEvent -Type 'stall' -Message ("$Id ($DurationText)") -Detail $Trigger -EventId $Id

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


function Capture-IncidentFollowup {
    param(
        [pscustomobject]$Pending,
        [string]$Suffix
    )
    if (-not $script:Jcmd) { return }
    $ThreadPath = Join-Path $Pending.Directory ("threads_$Suffix.txt")
    [void](Invoke-JcmdToFile -Jcmd $script:Jcmd -MinecraftPid $script:MinecraftPid -Command 'Thread.print' `
        -ExtraArgs @('-l') -TimeoutSeconds 15 -OutputPath $ThreadPath)
    [void](Save-ServerThreadExcerpt -ThreadDumpPath $ThreadPath -OutputPath (Join-Path $Pending.Directory ("server-thread_$Suffix.txt")))
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
$script:StartupCompleteAt = $StartupCompleteAt
$script:WorldEntryAt = $WorldEntryAt

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
                    $script:StartupCompleteAt = $StartupCompleteAt
                    Send-CraftProbeUiEvent -Type 'phase' -Message 'Hauptmenue / Startup beendet' -Detail ([string]$LineTime)
                }

                if (-not $WorldEntryAt -and $Line -match '(?i)(logged in with entity id| joined the game|Time from main menu to in-game was)') {
                    $WorldEntryAt = $LineTime
                    $script:WorldEntryAt = $WorldEntryAt
                    $WorldEntryLine = $Line.Trim()
                    Send-CraftProbeUiEvent -Type 'phase' -Message 'Weltbeitritt erkannt' -Detail ([string]$WorldEntryAt)
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
    if ($JfrStarted -and -not $StartupSnapshotDone -and (-not $StartupCompleteAt -or ([datetime]$StartupCompleteAt -ge $AttachAt.AddSeconds(-2))) -and ($StartupCompleteAt -or (-not $LateAttach -and (($Now-$GameStart).TotalSeconds -ge 90)))) {
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
    if ($JfrStarted -and $WorldEntryAt -and ([datetime]$WorldEntryAt -ge $AttachAt.AddSeconds(-2)) -and -not $WorldEntrySnapshotDone) {
        $WorldEntrySnapshotDone = $true
        New-Item -ItemType Directory -Path $MilestonesDir -Force | Out-Null
        $Pth = Join-Path $MilestonesDir ('world-entry_' + $Now.ToString('yyyy-MM-dd_HH-mm-ss') + '.jfr')
        if (Save-JfrSnapshot -MinecraftPid $MinecraftPid -Jcmd $Jcmd -JfrActive $JfrStarted -OutputPath $Pth `
            -ResultPath ($Pth + '.txt')) {
            $WorldEntryJfrRel = Get-SessionRelativePath -Base $SessionDir -Path $Pth
        }
    }

    if ($JfrStarted -and $WorldEntryAt -and ([datetime]$WorldEntryAt -ge $AttachAt.AddSeconds(-2)) -and -not $WorldEntryFollowupDone -and (($Now-([datetime]$WorldEntryAt)).TotalSeconds -ge 90)) {
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

    # Both the existing console key and the TUI incident command use the
    # exact same capture path, including +5s and +15s follow-ups.
    $IncidentRequests = 0
    try {
        if ([Console]::KeyAvailable) {
            $K = [Console]::ReadKey($true)
            if ($K.Key -eq [ConsoleKey]::E) { $IncidentRequests++ }
        }
    } catch {} # redirected stdin does not support KeyAvailable
    foreach ($UiCommand in @(Read-CraftProbeUiCommands)) {
        if ($UiCommand -eq 'incident') { $IncidentRequests++ }
    }
    for ($CmdNo = 0; $CmdNo -lt $IncidentRequests; $CmdNo++) {
        try {
            $Now = Get-Date
            $Incident++
            $IncidentId = ('INCIDENT-{0:D4}' -f $Incident)
            $D = Join-Path $IncidentsDir (($IncidentId + '_' + $Now.ToString('yyyy-MM-dd_HH-mm-ss-fff')))
            Send-CraftProbeUiEvent -Type 'incident' -Message ($IncidentId + ' markiert') -Detail 'Snapshot jetzt; Folgeaufnahmen +5/+15 s' -EventId $IncidentId
            Capture-JvmSnapshot -MinecraftPid $MinecraftPid -Jcmd $Jcmd -Directory $D `
                -JfrFile $(if ($JfrStarted) { Join-Path $D 'incident.jfr' } else { $null })
            [void](Save-ServerThreadExcerpt -ThreadDumpPath (Join-Path $D 'threads.txt') -OutputPath (Join-Path $D 'server-thread.txt'))
            $IncidentPhase = Get-CraftProbePhase -Time $Now -StartupCompleteAt $StartupCompleteAt -WorldEntryAt $WorldEntryAt
            Write-Utf8File -Path (Join-Path $D 'marker.txt') -Content @(
                'Manual incident marker (E / TUI)'
                'Id: ' + $IncidentId
                'Time: ' + $Now.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
                'Phase: ' + $IncidentPhase
                'Note: The visible problem may have started earlier or may only have been suspected at this time.'
                'Follow-up thread dumps are scheduled for +5s and +15s.'
            )
            [void]$script:IncidentEvents.Add([pscustomobject]@{
                Id=$IncidentId; Time=$Now; Phase=$IncidentPhase; Directory=(Get-SessionRelativePath -Base $SessionDir -Path $D)
            })
            [void]$PendingIncidentCaptures.Add([pscustomobject]@{
                Id=$IncidentId; Time=$Now; Directory=$D; Done5=$false; Done15=$false
            })
            Write-Host "Problemzeitpunkt $IncidentId gespeichert; Folge-Snapshots laufen noch 15 s." -ForegroundColor Yellow
        } catch {
            Send-CraftProbeUiEvent -Type 'warning' -Message 'Incident fehlgeschlagen' -Detail $_.Exception.Message
        }
    }

    # E is a time window, not only a single instant. Capture follow-up server
    # thread state without blocking normal gameplay for 15 seconds at once.
    # Do not wrap Generic.List in @(...): Windows PowerShell 5.1 may throw
    # System.ArgumentException ('Argument types do not match') even when empty.
    # The collection is not structurally modified inside this loop.
    foreach ($Pending in $PendingIncidentCaptures) {
        $Age = ($Now - [datetime]$Pending.Time).TotalSeconds
        if (-not $Pending.Done5 -and $Age -ge 5) {
            Capture-IncidentFollowup -Pending $Pending -Suffix '+05s'
            $Pending.Done5 = $true
        }
        if (-not $Pending.Done15 -and $Age -ge 15) {
            Capture-IncidentFollowup -Pending $Pending -Suffix '+15s'
            if ($JfrStarted) {
                [void](Save-JfrSnapshot -MinecraftPid $MinecraftPid -Jcmd $Jcmd -JfrActive $JfrStarted `
                    -OutputPath (Join-Path $Pending.Directory 'incident-plus-15s.jfr') `
                    -ResultPath (Join-Path $Pending.Directory 'incident-plus-15s-jfr-dump-result.txt'))
            }
            $Pending.Done15 = $true
        }
    }

    Start-Sleep -Milliseconds 500
}

$EndAt = Get-Date
Write-Host ""
Send-CraftProbeUiEvent -Type 'stopped' -Message 'Minecraft beendet' -Detail 'Diagnoseexport wird vorbereitet'
Write-Host "Minecraft wurde beendet." -ForegroundColor Green
Write-Host ""

Send-CraftProbeUiEvent -Type 'export' -Message 'JFR wird gesichert' -Detail 'Schritt 1 von 4'
Write-Host "[1/4] JFR sichern..." -ForegroundColor Cyan
try {
    Start-Sleep -Seconds 2
    $FinalValid = $false
    $FinalValidation = Test-JfrArtifact -Path $JfrFile -ValidationPath ($JfrFile + '.validation.txt') -JfrTool $JfrTool
    $FinalValid = [bool]$FinalValidation.Valid

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
        $RecoveryValid = $false
        if ($LatestSnapshot) {
            $RecoveryValidation = Test-JfrArtifact -Path $LatestSnapshot.FullName -ValidationPath ($LatestSnapshot.FullName + '.validation.txt') -JfrTool $JfrTool
            $RecoveryValid = [bool]$RecoveryValidation.Valid
        }
        if ($LatestSnapshot -and $RecoveryValid) {
            $FinalRollingJfrRel = Get-SessionRelativePath -Base $SessionDir -Path $LatestSnapshot.FullName
            Write-Utf8File -Path (Join-Path $SessionDir '_JFR_RECOVERY.txt') -Content @(
                'Final dumponexit JFR was missing/invalid.'
                'No duplicate copy was created.'
                'Use the validated rolling safeguard snapshot: ' + $FinalRollingJfrRel
            )
            Write-Host "      Finale JFR fehlte; validierter Rolling-Snapshot bleibt als Recovery erhalten." -ForegroundColor Yellow
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
    $CaptureProblems = New-Object System.Collections.Generic.List[string]
    $StallEventCount = $script:StallEvents.Count
    $StallJfrEventCount = @($script:StallEvents | Where-Object { $_.Jfr }).Count
    $IncidentJfrCount = 0
    if (Test-Path -LiteralPath $IncidentsDir -PathType Container) {
        $IncidentJfrCount = @(Get-ChildItem -LiteralPath $IncidentsDir -Filter '*.jfr' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 }).Count
    }
    $StallJfrStatus = $(if ($StallEventCount -eq 0) { 'NOT_REQUIRED' } elseif ($StallJfrEventCount -eq $StallEventCount) { 'OK' } elseif ($StallJfrEventCount -gt 0) { 'PARTIAL' } else { 'FAILED' })
    $IncidentJfrStatus = $(if ($script:IncidentEvents.Count -eq 0) { 'NOT_REQUIRED' } elseif ($IncidentJfrCount -ge $script:IncidentEvents.Count) { 'OK' } elseif ($IncidentJfrCount -gt 0) { 'PARTIAL' } else { 'FAILED' })
    $StartupBeforeAttach = ($StartupCompleteAt -and ([datetime]$StartupCompleteAt -lt $AttachAt.AddSeconds(-2)))
    $WorldEntryBeforeAttach = ($WorldEntryAt -and ([datetime]$WorldEntryAt -lt $AttachAt.AddSeconds(-2)))

    $StartupJfrStatus = $(
        if ($StartupJfrRel) { 'OK' }
        elseif ($StartupBeforeAttach) { 'NOT_CAPTURED_LATE_ATTACH' }
        elseif ($LateAttach -and -not $StartupCompleteAt) { 'NOT_CAPTURED_LATE_ATTACH' }
        elseif ($JfrStarted -and $StartupSnapshotDone) { 'FAILED' }
        else { 'NOT_CAPTURED' }
    )
    $WorldEntryJfrStatus = $(
        if ($WorldEntryJfrRel) { 'OK' }
        elseif ($WorldEntryBeforeAttach) { 'NOT_CAPTURED_LATE_ATTACH' }
        elseif ($JfrStarted -and $WorldEntryAt) { 'FAILED' }
        else { 'NOT_CAPTURED' }
    )
    $WorldEntryFollowupJfrStatus = $(
        if ($WorldEntryFollowupJfrRel) { 'OK' }
        elseif ($WorldEntryBeforeAttach) { 'NOT_CAPTURED_LATE_ATTACH' }
        elseif ($JfrStarted -and $WorldEntryAt -and (($EndAt-[datetime]$WorldEntryAt).TotalSeconds -ge 90)) { 'FAILED' }
        else { 'NOT_CAPTURED' }
    )

    $Capture = [ordered]@{
        schema = 2
        craftprobe_version = $RecorderVersion
        overall = 'OK'
        session = $(if ($PartialSessionCapture) { 'PARTIAL_LATE_ATTACH' } else { 'OK' })
        late_attach = $LateAttach
        partial_session_capture = $PartialSessionCapture
        minecraft_start = $GameStart.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
        craftprobe_start = $RecorderStartedAt.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
        attach_time = $AttachAt.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
        start_difference_seconds = [Math]::Round($StartDifferenceSeconds,3)
        attach_delay_seconds = [Math]::Round($AttachDelaySeconds,3)
        capture_coverage_start = $CaptureCoverageStart.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
        latest_log = $(if (Test-Path -LiteralPath $LatestLogPath -PathType Leaf) { 'OK' } else { 'MISSING' })
        jvm_tools = $(if ($Jcmd) { 'OK' } else { 'UNAVAILABLE' })
        jfr_recording = $(if ($JfrStarted) { 'OK' } elseif ($Jcmd) { 'FAILED' } else { 'UNAVAILABLE' })
        startup_jfr = $StartupJfrStatus
        world_entry_jfr = $WorldEntryJfrStatus
        world_entry_plus_90s_jfr = $WorldEntryFollowupJfrStatus
        rolling_final_jfr = $(if ($FinalRollingJfrRel) { 'OK' } elseif ($JfrStarted) { 'FAILED' } else { 'NOT_CAPTURED' })
        stall_events = $StallEventCount
        stall_jfr_events = $StallJfrEventCount
        stall_jfr = $StallJfrStatus
        manual_incidents = $script:IncidentEvents.Count
        incident_jfr_files = $IncidentJfrCount
        incident_jfr = $IncidentJfrStatus
    }

    foreach ($Pair in @(
        @{Key='jfr_recording'; Label='JFR recording could not be verified as active.'},
        @{Key='startup_jfr'; Label='Expected startup JFR milestone is missing or invalid.'},
        @{Key='world_entry_jfr'; Label='Expected world-entry JFR milestone is missing or invalid.'},
        @{Key='world_entry_plus_90s_jfr'; Label='Expected world-entry +90s JFR milestone is missing or invalid.'},
        @{Key='rolling_final_jfr'; Label='Expected final/rolling JFR artifact is missing or invalid.'}
    )) {
        if ($Capture[$Pair.Key] -eq 'FAILED') { [void]$CaptureProblems.Add($Pair.Label) }
    }
    if ($StallJfrStatus -in @('FAILED','PARTIAL')) {
        [void]$CaptureProblems.Add(('Stall JFR evidence is ' + $StallJfrStatus + ' (' + $StallJfrEventCount + '/' + $StallEventCount + ' events reference a JFR snapshot).'))
    }
    if ($IncidentJfrStatus -in @('FAILED','PARTIAL')) {
        [void]$CaptureProblems.Add(('Incident JFR evidence is ' + $IncidentJfrStatus + '.'))
    }

    if ($PartialSessionCapture) {
        $CoverageText = 'Partial session capture: CraftProbe attached ' + (Format-CraftProbeDuration $AttachDelaySeconds) + ' after the Minecraft process started. Evidence before attach is unavailable retroactively.'
        if ($LateAttach) { $CoverageText += ' Minecraft was already running for ' + (Format-CraftProbeDuration $StartDifferenceSeconds) + ' when CraftProbe itself was started.' }
        [void]$CaptureProblems.Add($CoverageText)
    }

    if (-not $Jcmd) {
        $Capture.overall = 'BASIC'
        [void]$CaptureProblems.Add('Compatible jcmd/jfr tooling was unavailable; compact diagnostics remain usable.')
    }
    elseif (@($CaptureProblems | Where-Object { $_ -notmatch '^Partial session capture:' }).Count -gt 0) {
        $Capture.overall = 'DEGRADED'
    }
    elseif ($PartialSessionCapture) {
        $Capture.overall = 'PARTIAL'
    }

    $Capture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $SessionDir 'CAPTURE_STATUS.json') -Encoding UTF8
    New-Item -ItemType Directory -Path $LogContextDir -Force | Out-Null
    foreach ($Ev in $script:StallEvents) {
        [void](Export-LogContextForEvent -LatestLogPath $LatestLogPath `
            -OutputPath (Join-Path $LogContextDir ($Ev.Id + '_latest.log.txt')) -EventTime ([datetime]$Ev.Time))
    }
    foreach ($Inc in $script:IncidentEvents) {
        [void](Export-LogContextForEvent -LatestLogPath $LatestLogPath `
            -OutputPath (Join-Path $LogContextDir ($Inc.Id + '_latest.log.txt')) -EventTime ([datetime]$Inc.Time))
    }

    $TimelineLines = @(
        "TYPE`tTIME`tDETAIL"
        "GAME_START`t$($GameStart.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture))`tMinecraft Java process start"
        "CRAFTPROBE_START`t$($RecorderStartedAt.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture))`tStart difference: $([Math]::Round($StartDifferenceSeconds,3)) s; late attach=$LateAttach"
        "CRAFTPROBE_ATTACH`t$($AttachAt.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture))`tJVM diagnostics can only cover this point forward"
        "STARTUP_COMPLETE`t$(if ($StartupCompleteAt) { ([datetime]$StartupCompleteAt).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture) } else { '' })`tMain-menu/startup marker"
        "WORLD_ENTRY`t$(if ($WorldEntryAt) { ([datetime]$WorldEntryAt).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture) } else { '' })`t$WorldEntryLine"
        "DIAGNOSIS_END`t$($EndAt.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture))`tMinecraft process ended"
    )
    foreach ($Ev in $script:StallEvents) {
        $TimelineLines += ("STALL`t" + ([datetime]$Ev.Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture) + "`t" + $Ev.Id + ' ' + $Ev.Phase + ' ' + $Ev.DurationText)
    }
    foreach ($Inc in $script:IncidentEvents) {
        $TimelineLines += ("INCIDENT`t" + ([datetime]$Inc.Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture) + "`t" + $Inc.Id + ' ' + $Inc.Phase)
    }
    Write-Utf8File -Path (Join-Path $SessionDir 'TIMELINE.tsv') -Content $TimelineLines

    $StallTsv = New-Object System.Collections.Generic.List[string]
    [void]$StallTsv.Add("ID`tTIME`tPHASE`tDURATION_MS`tDURATION_TEXT`tSOURCE`tSIGNATURE`tSNAPSHOT`tJFR`tDEDUP_OF`tTRIGGER")
    foreach ($Ev in $script:StallEvents) {
        $CleanTrigger = ([string]$Ev.Trigger).Replace("`t",' ').Replace("`r",' ').Replace("`n",' ')
        [void]$StallTsv.Add((@(
            $Ev.Id,
            ([datetime]$Ev.Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture),
            $Ev.Phase,
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

    $GroupTsv = New-Object System.Collections.Generic.List[string]
    [void]$GroupTsv.Add("SIGNATURE`tOCCURRENCES`tFIRST_ID`tFIRST_TIME`tWORST_ID`tWORST_TIME`tWORST_DURATION_MS`tLAST_ID`tLAST_TIME")
    foreach ($Group in @($script:StallEvents | Group-Object Signature)) {
        $Ordered = @($Group.Group | Sort-Object Time)
        $Worst = $Group.Group | Sort-Object DurationMs -Descending | Select-Object -First 1
        [void]$GroupTsv.Add((@(
            $Group.Name,
            $Group.Count,
            $Ordered[0].Id,
            ([datetime]$Ordered[0].Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture),
            $Worst.Id,
            ([datetime]$Worst.Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture),
            $Worst.DurationMs,
            $Ordered[-1].Id,
            ([datetime]$Ordered[-1].Time).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
        ) -join "`t"))
    }
    Write-Utf8File -Path (Join-Path $SessionDir 'STALL_GROUPS.tsv') -Content $GroupTsv

    Write-DiagnoseSummary -Path (Join-Path $SessionDir 'DIAGNOSE_SUMMARY.txt') `
        -GameStart $GameStart -CraftProbeStart $RecorderStartedAt -AttachAt $AttachAt -LateAttach $LateAttach -StartDifferenceSeconds $StartDifferenceSeconds `
        -StartupCompleteAt $StartupCompleteAt -WorldEntryAt $WorldEntryAt `
        -WorldEntryLine $WorldEntryLine -EndAt $EndAt -JavaVersion $JavaVersionText `
        -MinecraftVersion $Versions.Minecraft -LoaderVersion $Versions.LoaderVersion `
        -StallEvents $script:StallEvents -IncidentEvents $script:IncidentEvents -IgnoredIdleCandidates $IgnoredIdleCandidates `
        -UniqueStallSnapshots $UniqueStallSnapshots -StartupJfr $StartupJfrRel -WorldEntryJfr $WorldEntryJfrRel `
        -WorldEntryFollowupJfr $WorldEntryFollowupJfrRel -FinalRollingJfr $FinalRollingJfrRel `
        -CaptureHealth $Capture.overall -CaptureProblems $CaptureProblems.ToArray()

    Write-Utf8File -Path (Join-Path $SessionDir '_END.txt') -Content @(
        'Minecraft process ended: ' + $EndAt.ToString('yyyy-MM-dd HH:mm:ss.fff')
        "Manual incidents: $Incident"
        "Verified stall/high-MSPT events: $($script:StallEvents.Count)"
        "Unique auto-stall heavy snapshots: $UniqueStallSnapshots"
        "Ignored normal-idle candidates: $IgnoredIdleCandidates"
        "JFR active/usable: $JfrStarted"
        "Late attach: $LateAttach"
        "Partial session capture: $PartialSessionCapture"
        "Minecraft/CraftProbe start difference seconds: $([Math]::Round($StartDifferenceSeconds,3))"
        "Attach delay seconds: $([Math]::Round($AttachDelaySeconds,3))"
        ('Recorder ' + $RecorderVersion + ': startup/world-entry milestones + 15m rolling JFR; idle-aware stall detection; deduplicated snapshots; late-attach aware.')
    )
    Write-Host "      DIAGNOSE_SUMMARY.txt erzeugt."
} catch {
    Write-Host "      Recorder-Abschluss mit Warnung: $($_.Exception.Message)" -ForegroundColor Yellow
}

if (Test-Path -LiteralPath $ExporterPath -PathType Leaf) {
    try {
        Send-CraftProbeUiEvent -Type 'export' -Message 'Session-Daten sammeln' -Detail 'Schritt 3 von 4'
        Write-Host "[3/4] Session-Daten sammeln..." -ForegroundColor Cyan
        $ExportStartedAt = Get-Date
        $SessionStartIso = $GameStart.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
        $ExporterArgs = @(
            '-NoProfile',
            '-ExecutionPolicy','Bypass',
            '-File',$ExporterPath,
            '-ProfilePath',$ProfilePath,
            '-OutputPath',$OutputPath,
            '-SessionStartOverride',$SessionStartIso,
            '-RecorderSessionPath',$SessionDir
        )
        $ExporterArgumentString = (@($ExporterArgs | ForEach-Object { ConvertTo-CraftProbeNativeArgument -Argument ([string]$_) }) -join ' ')
        $ExportPsi = New-Object System.Diagnostics.ProcessStartInfo
        $ExportPsi.FileName = 'powershell.exe'
        $ExportPsi.Arguments = $ExporterArgumentString
        $ExportPsi.UseShellExecute = $false
        $ExportPsi.CreateNoWindow = -not [string]::IsNullOrWhiteSpace($UiEventsPath)
        if ($ExportPsi.CreateNoWindow) {
            $ExportPsi.RedirectStandardOutput = $true
            $ExportPsi.RedirectStandardError = $true
        }
        $ExportProc = New-Object System.Diagnostics.Process
        $ExportProc.StartInfo = $ExportPsi
        if (-not $ExportProc.Start()) { throw 'Session exporter could not be started.' }
        if ($ExportPsi.RedirectStandardOutput) {
            # Drain both pipes concurrently, otherwise large logs can deadlock WaitForExit.
            $ExportOutTask = $ExportProc.StandardOutput.ReadToEndAsync()
            $ExportErrTask = $ExportProc.StandardError.ReadToEndAsync()
        }

        $ExitedInTime = $ExportProc.WaitForExit(10 * 60 * 1000)
        if (-not $ExitedInTime) {
            try { $ExportProc.Kill() } catch {}
            Write-Host "" 
            Write-Host "EXPORT FEHLGESCHLAGEN" -ForegroundColor Red
            Write-Host "Der Session-Export wurde nach 10 Minuten beendet (Timeout)." -ForegroundColor Red
            Write-Host "Keine fertige ZIP wurde bestaetigt."
            Write-Host "Recorder-Rohdaten: $SessionDir"
            exit 2
        }
        try { $ExportProc.WaitForExit() } catch {}
        if ($ExportPsi.RedirectStandardOutput) {
            try {
                Write-Utf8File -Path (Join-Path $SessionDir 'export-output.txt') -Content @($ExportOutTask.Result, $ExportErrTask.Result)
            } catch {}
        }
        try { $ExportProc.Refresh() } catch {}

        $ExporterExitCode = $null
        try { if ($ExportProc.HasExited) { $ExporterExitCode = [int]$ExportProc.ExitCode } } catch {}
        if ($null -ne $ExporterExitCode -and $ExporterExitCode -ne 0) {
            Write-Host ""
            Write-Host "EXPORT FEHLGESCHLAGEN" -ForegroundColor Red
            Send-CraftProbeUiEvent -Type 'error' -Message 'Session-Export fehlgeschlagen' -Detail ("ExitCode: " + $ExporterExitCode)
            Write-Host "Der Exporter wurde mit ExitCode $ExporterExitCode beendet." -ForegroundColor Red
            Write-Host "Keine fertige ZIP wurde bestaetigt."
            Write-Host "Recorder-Rohdaten: $SessionDir"
            exit $ExporterExitCode
        }

        # Erfolg wird nicht aus einem Exitcode abgeleitet: Es muss wirklich eine
        # neue, nicht-leere Session-ZIP aus genau diesem Exportlauf existieren.
        $RecentZip = $null
        if (Test-Path -LiteralPath $OutputPath -PathType Container) {
            $RecentZip = Get-ChildItem -LiteralPath $OutputPath -Filter ($ProfileName + '_Session-Analyse_*.zip') -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $ExportStartedAt.AddSeconds(-5) -and $_.Length -gt 0 } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }

        if (-not $RecentZip) {
            Write-Host ""
            Write-Host "EXPORT FEHLGESCHLAGEN" -ForegroundColor Red
            Write-Host "Der Exporter wurde beendet, aber es wurde keine neue Session-ZIP gefunden." -ForegroundColor Red
            Write-Host "Keine fertige ZIP wurde bestaetigt."
            Write-Host "Recorder-Rohdaten: $SessionDir"
            exit 5
        }

        Write-Host "[4/4] Export bestaetigt." -ForegroundColor Cyan
        Write-Host "      ZIP: $($RecentZip.FullName)" -ForegroundColor Green
        Write-Host ""
        Send-CraftProbeUiEvent -Type 'completed' -Message 'Export erfolgreich' -Detail $RecentZip.FullName
        Write-Host "Recorder und Session-Export erfolgreich abgeschlossen." -ForegroundColor Green
        exit 0
    } catch {
        Write-Host ""
        Write-Host "EXPORT FEHLGESCHLAGEN" -ForegroundColor Red
        Write-Host "Session-Export konnte nicht abgeschlossen werden: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Recorder-Rohdaten: $SessionDir"
        exit 3
    }
}
else {
    Write-Host ""
    Write-Host "EXPORT FEHLGESCHLAGEN" -ForegroundColor Red
    Write-Host "Export-Skript fehlt: $ExporterPath" -ForegroundColor Red
    Write-Host "Recorder-Rohdaten: $SessionDir"
    exit 4
}

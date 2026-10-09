# CraftProbe persistent path settings and startup selection.
# Windows PowerShell 5.1 compatible.

$script:CraftProbeProfileOutputToken = '__PROFILE__'

function Get-CraftProbeSettingsPath {
    $Base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($Base)) { $Base = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($Base)) {
        $Base = Split-Path -Parent $PSScriptRoot
    }
    return (Join-Path (Join-Path $Base 'CraftProbe') 'settings.json')
}

function New-CraftProbeSettings {
    return [pscustomobject]@{
        schemaVersion          = 2
        profiles               = @()
        defaultProfile         = $null
        exports                = @()
        defaultExport          = $script:CraftProbeProfileOutputToken
        workingDirectoryRules  = @()
    }
}

function Get-CraftProbeNormalizedPath {
    param(
        [string]$Path,
        [switch]$MustExist
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $Expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
        $Full = [System.IO.Path]::GetFullPath($Expanded)
        $Root = [System.IO.Path]::GetPathRoot($Full)
        if ($Full.Length -gt $Root.Length) { $Full = $Full.TrimEnd('\') }
        if ($MustExist -and -not (Test-Path -LiteralPath $Full -PathType Container)) { return $null }
        return $Full
    }
    catch {
        return $null
    }
}

function Test-CraftProbePathEqual {
    param([string]$A,[string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    $NA = Get-CraftProbeNormalizedPath $A
    $NB = Get-CraftProbeNormalizedPath $B
    if (-not $NA -or -not $NB) { return $false }
    return [string]::Equals($NA,$NB,[System.StringComparison]::OrdinalIgnoreCase)
}

function Get-CraftProbeUniquePaths {
    param([object[]]$Paths)
    $Result = New-Object System.Collections.Generic.List[string]
    foreach ($P in @($Paths)) {
        $N = Get-CraftProbeNormalizedPath ([string]$P)
        if (-not $N) { continue }
        $Exists = $false
        foreach ($R in $Result) {
            if (Test-CraftProbePathEqual $R $N) { $Exists = $true; break }
        }
        if (-not $Exists) { [void]$Result.Add($N) }
    }
    return $Result.ToArray()
}

function Get-CraftProbeRootPath {
    return (Get-CraftProbeNormalizedPath (Split-Path -Parent $PSScriptRoot))
}

function Get-CraftProbeNormalizedWorkingDirectoryRules {
    param([object[]]$Rules)
    $Result = New-Object System.Collections.Generic.List[object]
    foreach ($Rule in @($Rules)) {
        if ($null -eq $Rule) { continue }
        $Path = $null
        $Action = $null
        if ($Rule -is [string]) { continue }
        if ($Rule.PSObject.Properties.Name -contains 'path') { $Path = Get-CraftProbeNormalizedPath ([string]$Rule.path) }
        if ($Rule.PSObject.Properties.Name -contains 'action') { $Action = ([string]$Rule.action).ToLowerInvariant() }
        if (-not $Path -or $Action -notin @('use','ignore')) { continue }

        $ExistingIndex = -1
        for ($i = 0; $i -lt $Result.Count; $i++) {
            if (Test-CraftProbePathEqual $Result[$i].path $Path) { $ExistingIndex = $i; break }
        }
        $Entry = [pscustomobject]@{ path = $Path; action = $Action }
        if ($ExistingIndex -ge 0) { $Result[$ExistingIndex] = $Entry }
        else { [void]$Result.Add($Entry) }
    }
    return $Result.ToArray()
}

function Find-CraftProbeProfileFromDirectory {
    param(
        [string]$Directory,
        [int]$MaxParents = 6
    )
    $Current = Get-CraftProbeNormalizedPath $Directory -MustExist
    if (-not $Current) { return $null }

    for ($Depth = 0; $Depth -le $MaxParents; $Depth++) {
        $Resolved = Resolve-CraftProbeProfileCandidate $Current
        if ($Resolved) { return $Resolved }
        $Parent = Split-Path -Parent $Current
        if ([string]::IsNullOrWhiteSpace($Parent) -or (Test-CraftProbePathEqual $Parent $Current)) { break }
        $Current = $Parent
    }
    return $null
}

function Get-CraftProbeWorkingDirectoryRule {
    param($Settings,[string]$ProfilePath)
    foreach ($Rule in @(Get-CraftProbeNormalizedWorkingDirectoryRules @($Settings.workingDirectoryRules))) {
        if (Test-CraftProbePathEqual $Rule.path $ProfilePath) { return $Rule }
    }
    return $null
}

function Set-CraftProbeWorkingDirectoryRule {
    param(
        $Settings,
        [string]$ProfilePath,
        [ValidateSet('use','ignore')][string]$Action
    )
    $Path = Get-CraftProbeNormalizedPath $ProfilePath
    if (-not $Path) { return }
    $Rules = New-Object System.Collections.Generic.List[object]
    foreach ($Rule in @(Get-CraftProbeNormalizedWorkingDirectoryRules @($Settings.workingDirectoryRules))) {
        if (-not (Test-CraftProbePathEqual $Rule.path $Path)) { [void]$Rules.Add($Rule) }
    }
    [void]$Rules.Add([pscustomobject]@{ path=$Path; action=$Action })
    $Settings.workingDirectoryRules = $Rules.ToArray()
    Save-CraftProbeSettings $Settings
}

function Remove-CraftProbeWorkingDirectoryRule {
    param($Settings,[string]$ProfilePath)
    $Settings.workingDirectoryRules = @(
        Get-CraftProbeNormalizedWorkingDirectoryRules @($Settings.workingDirectoryRules) |
            Where-Object { -not (Test-CraftProbePathEqual $_.path $ProfilePath) }
    )
    Save-CraftProbeSettings $Settings
}

function Get-CraftProbePathBinDirectory {
    $Base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($Base)) { $Base = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
    return (Get-CraftProbeNormalizedPath (Join-Path (Join-Path $Base 'CraftProbe') 'bin'))
}

function Get-CraftProbePathShimPath {
    $Bin = Get-CraftProbePathBinDirectory
    if (-not $Bin) { return $null }
    return (Join-Path $Bin 'CraftProbe.cmd')
}

function Get-CraftProbePathTargetFile {
    $Bin = Get-CraftProbePathBinDirectory
    if (-not $Bin) { return $null }
    return (Join-Path $Bin 'target.txt')
}

function Get-CraftProbeUserPathEntries {
    $Raw = [Environment]::GetEnvironmentVariable('Path','User')
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    return @($Raw -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-CraftProbePathInstalled {
    $Bin = Get-CraftProbePathBinDirectory
    if (-not $Bin) { return $false }
    $Found = $false
    foreach ($Entry in @(Get-CraftProbeUserPathEntries)) {
        $Expanded = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"'))
        if (Test-CraftProbePathEqual $Expanded $Bin) { $Found = $true; break }
    }
    $Shim = Get-CraftProbePathShimPath
    return ($Found -and $Shim -and (Test-Path -LiteralPath $Shim -PathType Leaf))
}

function Get-CraftProbeInstalledPathTarget {
    $TargetFile = Get-CraftProbePathTargetFile
    if ($TargetFile -and (Test-Path -LiteralPath $TargetFile -PathType Leaf)) {
        try { return (Get-Content -LiteralPath $TargetFile -Raw -ErrorAction Stop).Trim() } catch {}
    }
    return $null
}

function Send-CraftProbeEnvironmentChanged {
    try {
        if (-not ('CraftProbe.EnvironmentBroadcast' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace CraftProbe {
    public static class EnvironmentBroadcast {
        [DllImport("user32.dll", CharSet=CharSet.Auto, SetLastError=true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
        public static void Notify() {
            UIntPtr result;
            SendMessageTimeout(new IntPtr(0xffff), 0x001A, UIntPtr.Zero, "Environment", 0x0002, 2000, out result);
        }
    }
}
"@ -ErrorAction Stop
        }
        [CraftProbe.EnvironmentBroadcast]::Notify()
    }
    catch {}
}

function Install-CraftProbePath {
    $Root = Get-CraftProbeRootPath
    $Launcher = Join-Path $Root 'CraftProbe.cmd'
    if (-not $Root -or -not (Test-Path -LiteralPath $Launcher -PathType Leaf)) {
        throw 'CraftProbe-Programmordner konnte nicht ermittelt werden.'
    }

    $Bin = Get-CraftProbePathBinDirectory
    $ShimPath = Get-CraftProbePathShimPath
    $TargetFile = Get-CraftProbePathTargetFile
    if (-not $Bin -or -not $ShimPath) { throw 'Lokaler CraftProbe-PATH-Ordner konnte nicht ermittelt werden.' }
    if (-not (Test-Path -LiteralPath $Bin -PathType Container)) { New-Item -ItemType Directory -Path $Bin -Force | Out-Null }

    # Stable shim: the user's PATH only contains %LOCALAPPDATA%\CraftProbe\bin.
    # Re-running --install-path from a newer CraftProbe release retargets the shim
    # without accumulating version-specific directories in PATH.
    $EscapedLauncher = $Launcher.Replace('%','%%')
    $ShimText = "@echo off`r`ncall `"$EscapedLauncher`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    [System.IO.File]::WriteAllText($ShimPath,$ShimText,[System.Text.Encoding]::Default)
    [System.IO.File]::WriteAllText($TargetFile,$Root,[System.Text.Encoding]::UTF8)

    $Entries = New-Object System.Collections.Generic.List[string]
    $Already = $false
    foreach ($Entry in @(Get-CraftProbeUserPathEntries)) {
        $Expanded = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"'))
        if (Test-CraftProbePathEqual $Expanded $Bin) { $Already = $true }
        [void]$Entries.Add($Entry)
    }
    if (-not $Already) { [void]$Entries.Add($Bin) }
    [Environment]::SetEnvironmentVariable('Path',($Entries.ToArray() -join ';'),'User')
    Send-CraftProbeEnvironmentChanged

    Write-Host 'CraftProbe wurde fuer den Benutzer-PATH eingerichtet.' -ForegroundColor Green
    Write-Host ('Starter: ' + $ShimPath)
    Write-Host ('Ziel:    ' + $Root)
    Write-Host 'In neu geoeffneten Terminals kannst du es mit "craftprobe" starten.' -ForegroundColor Cyan
}

function Uninstall-CraftProbePath {
    $Bin = Get-CraftProbePathBinDirectory
    $Root = Get-CraftProbeRootPath
    $Entries = New-Object System.Collections.Generic.List[string]
    foreach ($Entry in @(Get-CraftProbeUserPathEntries)) {
        $Expanded = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"'))
        $Remove = $false
        if ($Bin -and (Test-CraftProbePathEqual $Expanded $Bin)) { $Remove = $true }
        # Also clean a possible direct CraftProbe program-directory entry from
        # development/older builds of this feature.
        if ($Root -and (Test-CraftProbePathEqual $Expanded $Root)) { $Remove = $true }
        if (-not $Remove) { [void]$Entries.Add($Entry) }
    }
    [Environment]::SetEnvironmentVariable('Path',($Entries.ToArray() -join ';'),'User')
    if ($Bin -and (Test-Path -LiteralPath $Bin -PathType Container)) {
        Remove-Item -LiteralPath (Get-CraftProbePathShimPath) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-CraftProbePathTargetFile) -Force -ErrorAction SilentlyContinue
        try {
            if (@(Get-ChildItem -LiteralPath $Bin -Force -ErrorAction Stop).Count -eq 0) { Remove-Item -LiteralPath $Bin -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
    Send-CraftProbeEnvironmentChanged
    Write-Host 'CraftProbe wurde aus dem Benutzer-PATH entfernt.' -ForegroundColor Green
    Write-Host 'Bereits geoeffnete Terminals koennen den alten PATH noch enthalten.' -ForegroundColor DarkGray
}

function Manage-CraftProbePathInstallation {
    while ($true) {
        $Installed = Test-CraftProbePathInstalled
        $Target = Get-CraftProbeInstalledPathTarget
        $CurrentRoot = Get-CraftProbeRootPath
        $NeedsRetarget = ($Installed -and $Target -and -not (Test-CraftProbePathEqual $Target $CurrentRoot))
        Write-Host ''
        Write-Host '--- CraftProbe im PATH ---' -ForegroundColor Cyan
        Write-Host ('Aktuelle Version: ' + $CurrentRoot)
        if ($Installed) {
            Write-Host 'Status: installiert' -ForegroundColor Green
            if ($Target) { Write-Host ('PATH-Starter zeigt auf: ' + $Target) }
            if ($NeedsRetarget) { Write-Host 'Der PATH-Starter zeigt auf eine andere CraftProbe-Version.' -ForegroundColor Yellow }
            Write-Host ' I. PATH-Starter auf diese Version setzen/aktualisieren'
            Write-Host ' R. Aus Benutzer-PATH entfernen'
        }
        else {
            Write-Host 'Status: nicht installiert' -ForegroundColor Yellow
            Write-Host ' I. Zum Benutzer-PATH hinzufuegen'
        }
        Write-Host ' Z. Zurueck'
        $Choice = (Read-Host 'Auswahl').Trim()
        if ([string]::IsNullOrWhiteSpace($Choice) -or $Choice -match '^[zZ]$') { return }
        if ($Choice -match '^[iI]$') { Install-CraftProbePath; continue }
        if ($Installed -and $Choice -match '^[rR]$') { Uninstall-CraftProbePath; continue }
        Write-Host 'Ungueltige Auswahl.' -ForegroundColor Yellow
    }
}

function Manage-CraftProbeWorkingDirectoryRules {
    param($Settings)
    while ($true) {
        $Rules = @(Get-CraftProbeNormalizedWorkingDirectoryRules @($Settings.workingDirectoryRules))
        Write-Host ''
        Write-Host '--- Regeln fuer aktuellen Ordner ---' -ForegroundColor Cyan
        if ($Rules.Count -eq 0) {
            Write-Host 'Keine Regeln gespeichert.' -ForegroundColor DarkGray
        }
        else {
            for ($i = 0; $i -lt $Rules.Count; $i++) {
                $Label = $(if ($Rules[$i].action -eq 'use') { 'automatisch verwenden' } else { 'nicht automatisch anbieten' })
                $Missing = -not (Test-Path -LiteralPath $Rules[$i].path -PathType Container)
                $MissingText = $(if ($Missing) { ' [fehlt]' } else { '' })
                Write-Host (('{0,2}. {1} -> {2}{3}' -f ($i+1),$Rules[$i].path,$Label,$MissingText))
            }
        }
        Write-Host ' R. Regel entfernen'
        Write-Host ' Z. Zurueck'
        $Action = (Read-Host 'Auswahl').Trim()
        if ([string]::IsNullOrWhiteSpace($Action) -or $Action -match '^[zZ]$') { return }
        if ($Action -match '^[rR]$' -and $Rules.Count -gt 0) {
            $Raw = Read-Host 'Nummer der zu entfernenden Regel'
            $Index = 0
            if ([int]::TryParse($Raw,[ref]$Index) -and $Index -ge 1 -and $Index -le $Rules.Count) {
                Remove-CraftProbeWorkingDirectoryRule -Settings $Settings -ProfilePath $Rules[$Index-1].path
            }
            else { Write-Host 'Ungueltige Nummer.' -ForegroundColor Yellow }
        }
    }
}

function Manage-CraftProbeSettings {
    param($Settings)
    while ($true) {
        Write-Host ''
        Write-Host 'CraftProbe-Einstellungen' -ForegroundColor Cyan
        Write-Host '-----------------------'
        Write-Host ' 1. Gespeicherte Profilpfade'
        Write-Host ' 2. Gespeicherte Exportpfade'
        Write-Host ' 3. Regeln fuer Start aus Profilordnern'
        Write-Host ' 4. CraftProbe im PATH'
        Write-Host ' Z. Zurueck'
        $Choice = (Read-Host 'Auswahl').Trim()
        if ([string]::IsNullOrWhiteSpace($Choice) -or $Choice -match '^[zZ]$') { return }
        switch ($Choice) {
            '1' { Manage-CraftProbeSavedPaths -Settings $Settings -Kind Profile }
            '2' { Manage-CraftProbeSavedPaths -Settings $Settings -Kind Export }
            '3' { Manage-CraftProbeWorkingDirectoryRules -Settings $Settings }
            '4' { Manage-CraftProbePathInstallation }
            default { Write-Host 'Ungueltige Auswahl.' -ForegroundColor Yellow }
        }
    }
}

function Get-CraftProbeSettings {
    $SettingsPath = Get-CraftProbeSettingsPath
    $Settings = New-CraftProbeSettings

    if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
        try {
            $Loaded = Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $Loaded) {
                if ($Loaded.PSObject.Properties.Name -contains 'profiles') {
                    $Settings.profiles = @(Get-CraftProbeUniquePaths @($Loaded.profiles))
                }
                if ($Loaded.PSObject.Properties.Name -contains 'defaultProfile') {
                    $Settings.defaultProfile = Get-CraftProbeNormalizedPath ([string]$Loaded.defaultProfile)
                }
                if ($Loaded.PSObject.Properties.Name -contains 'exports') {
                    $Settings.exports = @(Get-CraftProbeUniquePaths @($Loaded.exports))
                }
                if ($Loaded.PSObject.Properties.Name -contains 'defaultExport') {
                    $RawDefaultExport = [string]$Loaded.defaultExport
                    if ($RawDefaultExport -eq $script:CraftProbeProfileOutputToken) {
                        $Settings.defaultExport = $script:CraftProbeProfileOutputToken
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($RawDefaultExport)) {
                        $Settings.defaultExport = Get-CraftProbeNormalizedPath $RawDefaultExport
                    }
                }
                if ($Loaded.PSObject.Properties.Name -contains 'workingDirectoryRules') {
                    $Settings.workingDirectoryRules = @(Get-CraftProbeNormalizedWorkingDirectoryRules @($Loaded.workingDirectoryRules))
                }
            }
        }
        catch {
            Write-Host 'CraftProbe-Einstellungen konnten nicht gelesen werden. Es werden neue Einstellungen verwendet.' -ForegroundColor Yellow
        }
    }

    # Remove stale default references from the in-memory state. Missing folders stay in
    # the saved list so the user can see and remove them explicitly.
    if ($Settings.defaultProfile) {
        $Found = $false
        foreach ($P in @($Settings.profiles)) {
            if (Test-CraftProbePathEqual $P $Settings.defaultProfile) { $Found = $true; break }
        }
        if (-not $Found) { $Settings.defaultProfile = $null }
    }

    if ($Settings.defaultExport -and $Settings.defaultExport -ne $script:CraftProbeProfileOutputToken) {
        $Found = $false
        foreach ($P in @($Settings.exports)) {
            if (Test-CraftProbePathEqual $P $Settings.defaultExport) { $Found = $true; break }
        }
        if (-not $Found) { $Settings.defaultExport = $script:CraftProbeProfileOutputToken }
    }

    return $Settings
}

function Save-CraftProbeSettings {
    param($Settings)
    $SettingsPath = Get-CraftProbeSettingsPath
    $Dir = Split-Path -Parent $SettingsPath
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }

    $Serializable = [ordered]@{
        schemaVersion          = 2
        profiles               = @(Get-CraftProbeUniquePaths @($Settings.profiles))
        defaultProfile         = $Settings.defaultProfile
        exports                = @(Get-CraftProbeUniquePaths @($Settings.exports))
        defaultExport          = $(if ($Settings.defaultExport) { $Settings.defaultExport } else { $script:CraftProbeProfileOutputToken })
        workingDirectoryRules  = @(Get-CraftProbeNormalizedWorkingDirectoryRules @($Settings.workingDirectoryRules))
    }

    $Temp = $SettingsPath + '.tmp'
    $Serializable | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $Temp -Encoding utf8 -Force
    Move-Item -LiteralPath $Temp -Destination $SettingsPath -Force
}

function Read-CraftProbeYesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $true
    )

    $Suffix = $(if ($DefaultYes) { '[J/n]' } else { '[j/N]' })
    while ($true) {
        $Answer = Read-Host ($Prompt + ' ' + $Suffix)
        if ([string]::IsNullOrWhiteSpace($Answer)) { return $DefaultYes }
        switch ($Answer.Trim().ToLowerInvariant()) {
            'j'   { return $true }
            'ja'  { return $true }
            'y'   { return $true }
            'yes' { return $true }
            'n'   { return $false }
            'nein' { return $false }
            'no'  { return $false }
        }
        Write-Host 'Bitte J oder N eingeben.' -ForegroundColor Yellow
    }
}

function Resolve-CraftProbeProfileCandidate {
    param([string]$Path)
    $N = Get-CraftProbeNormalizedPath $Path -MustExist
    if (-not $N) { return $null }
    if (Test-MinecraftProfileRoot $N) { return $N }
    $Dot = Join-Path $N '.minecraft'
    if (Test-MinecraftProfileRoot $Dot) {
        return (Get-CraftProbeNormalizedPath $Dot -MustExist)
    }
    return $null
}

function Get-CraftProbeProfileDisplayName {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '<unbekannt>' }
    $Leaf = Split-Path -Leaf $Path
    if ($Leaf -eq '.minecraft') {
        $Parent = Split-Path -Parent $Path
        $Leaf = Split-Path -Leaf $Parent
    }
    if ([string]::IsNullOrWhiteSpace($Leaf)) { return $Path }
    return $Leaf
}

function Add-CraftProbeSavedPath {
    param(
        $Settings,
        [ValidateSet('Profile','Export')][string]$Kind,
        [string]$Path
    )
    $N = Get-CraftProbeNormalizedPath $Path
    if (-not $N) { return }
    $Property = $(if ($Kind -eq 'Profile') { 'profiles' } else { 'exports' })
    $Current = @($Settings.$Property)
    foreach ($P in $Current) {
        if (Test-CraftProbePathEqual $P $N) { return }
    }
    $Settings.$Property = @($Current + $N)
}

function Register-CraftProbeNewPath {
    param(
        $Settings,
        [ValidateSet('Profile','Export')][string]$Kind,
        [string]$Path
    )

    $Property = $(if ($Kind -eq 'Profile') { 'profiles' } else { 'exports' })
    $AlreadySaved = $false
    foreach ($P in @($Settings.$Property)) {
        if (Test-CraftProbePathEqual $P $Path) { $AlreadySaved = $true; break }
    }
    if ($AlreadySaved) { return }

    $FriendlyKind = $(if ($Kind -eq 'Profile') { 'Profilpfad' } else { 'Exportpfad' })
    if (Read-CraftProbeYesNo -Prompt ($FriendlyKind + ' speichern?') -DefaultYes $true) {
        Add-CraftProbeSavedPath -Settings $Settings -Kind $Kind -Path $Path
        $SetDefault = Read-CraftProbeYesNo -Prompt 'Auch als Standard setzen?' -DefaultYes $false
        if ($SetDefault) {
            if ($Kind -eq 'Profile') { $Settings.defaultProfile = $Path }
            else { $Settings.defaultExport = $Path }
        }
        Save-CraftProbeSettings $Settings
    }
}

function Select-CraftProbeNewProfilePath {
    param([string]$InitialDirectory)
    $Selected = Show-CraftProbeFolderPicker -InitialDirectory $InitialDirectory -Title 'CraftProbe - Minecraft-Profil auswaehlen'
    if ($Selected) {
        $Resolved = Resolve-CraftProbeProfileCandidate $Selected
        if ($Resolved) { return $Resolved }
        Write-Host ''
        Write-Host 'Der ausgewaehlte Ordner sieht nicht wie ein Minecraft-Profil aus.' -ForegroundColor Yellow
        Write-Host 'Erwartet werden z. B. mods, config, logs, saves oder eine .minecraft-Unterstruktur.'
    }

    $Typed = Read-Host 'Profilpfad eingeben (leer = zurueck)'
    if (-not [string]::IsNullOrWhiteSpace($Typed)) {
        $Resolved = Resolve-CraftProbeProfileCandidate $Typed
        if ($Resolved) { return $Resolved }
        Write-Host 'Der eingegebene Pfad ist kein plausibles Minecraft-Profil.' -ForegroundColor Yellow
    }
    return $null
}

function Select-CraftProbeNewExportPath {
    param([string]$InitialDirectory)
    $Selected = Show-CraftProbeFolderPicker -InitialDirectory $InitialDirectory -Title 'CraftProbe - Exportordner auswaehlen'
    if ($Selected) { return (Get-CraftProbeNormalizedPath $Selected -MustExist) }

    $Typed = Read-Host 'Exportpfad eingeben (leer = zurueck)'
    if (-not [string]::IsNullOrWhiteSpace($Typed)) {
        $N = Get-CraftProbeNormalizedPath $Typed
        if ($N) { return $N }
    }
    return $null
}

function Manage-CraftProbeSavedPaths {
    param(
        $Settings,
        [ValidateSet('Profile','Export')][string]$Kind
    )

    $Property = $(if ($Kind -eq 'Profile') { 'profiles' } else { 'exports' })
    $Title = $(if ($Kind -eq 'Profile') { 'gespeicherte Profilpfade' } else { 'gespeicherte Exportpfade' })

    while ($true) {
        Write-Host ''
        Write-Host ('--- ' + $Title + ' ---') -ForegroundColor Cyan
        $Items = @($Settings.$Property)
        if ($Items.Count -eq 0) {
            Write-Host 'Keine Pfade gespeichert.' -ForegroundColor DarkGray
        }
        else {
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $P = $Items[$i]
                $IsDefault = $false
                if ($Kind -eq 'Profile') { $IsDefault = (Test-CraftProbePathEqual $P $Settings.defaultProfile) }
                else { $IsDefault = ($Settings.defaultExport -ne $script:CraftProbeProfileOutputToken -and (Test-CraftProbePathEqual $P $Settings.defaultExport)) }
                $Missing = -not (Test-Path -LiteralPath $P -PathType Container)
                $Flags = @()
                if ($IsDefault) { $Flags += 'Standard' }
                if ($Missing) { $Flags += 'fehlt' }
                $FlagText = $(if ($Flags.Count -gt 0) { ' [' + ($Flags -join ', ') + ']' } else { '' })
                Write-Host (('{0,2}. {1}{2}' -f ($i + 1),$P,$FlagText))
            }
        }
        if ($Kind -eq 'Export') {
            $ProfileDefaultMark = $(if ($Settings.defaultExport -eq $script:CraftProbeProfileOutputToken) { ' [Standard]' } else { '' })
            Write-Host (' P. Profilordner selbst' + $ProfileDefaultMark)
        }
        Write-Host ' R. Pfad entfernen'
        Write-Host ' S. Standard festlegen'
        Write-Host ' Z. Zurueck'
        $Action = (Read-Host 'Auswahl').Trim()
        if ([string]::IsNullOrWhiteSpace($Action) -or $Action -match '^[zZ]$') { return }

        if ($Action -match '^[rR]$') {
            if ($Items.Count -eq 0) { continue }
            $Raw = Read-Host 'Nummer des zu entfernenden Pfads'
            $Index = 0
            if ([int]::TryParse($Raw,[ref]$Index) -and $Index -ge 1 -and $Index -le $Items.Count) {
                $Remove = $Items[$Index - 1]
                if (Read-CraftProbeYesNo -Prompt ('Pfad entfernen: ' + $Remove + '?') -DefaultYes $false) {
                    $Settings.$Property = @($Items | Where-Object { -not (Test-CraftProbePathEqual $_ $Remove) })
                    if ($Kind -eq 'Profile' -and (Test-CraftProbePathEqual $Settings.defaultProfile $Remove)) {
                        $Settings.defaultProfile = $null
                    }
                    if ($Kind -eq 'Export' -and $Settings.defaultExport -ne $script:CraftProbeProfileOutputToken -and (Test-CraftProbePathEqual $Settings.defaultExport $Remove)) {
                        $Settings.defaultExport = $script:CraftProbeProfileOutputToken
                    }
                    Save-CraftProbeSettings $Settings
                }
            }
            else { Write-Host 'Ungueltige Nummer.' -ForegroundColor Yellow }
            continue
        }

        if ($Action -match '^[sS]$') {
            if ($Kind -eq 'Export') {
                $Raw = Read-Host 'Nummer als Standard setzen oder P fuer Profilordner'
                if ($Raw -match '^[pP]$') {
                    $Settings.defaultExport = $script:CraftProbeProfileOutputToken
                    Save-CraftProbeSettings $Settings
                    continue
                }
            }
            else {
                $Raw = Read-Host 'Nummer als Standard setzen'
            }
            $Index = 0
            if ([int]::TryParse($Raw,[ref]$Index) -and $Index -ge 1 -and $Index -le $Items.Count) {
                if ($Kind -eq 'Profile') { $Settings.defaultProfile = $Items[$Index - 1] }
                else { $Settings.defaultExport = $Items[$Index - 1] }
                Save-CraftProbeSettings $Settings
            }
            else { Write-Host 'Ungueltige Nummer.' -ForegroundColor Yellow }
            continue
        }
    }
}

function Select-CraftProbeProfilePath {
    param(
        $Settings,
        [string]$RequestedPath,
        [string]$InvocationDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $Resolved = Resolve-CraftProbeProfileCandidate $RequestedPath
        if (-not $Resolved) { throw 'Der uebergebene Profilpfad ist kein plausibles Minecraft-Profil.' }
        Register-CraftProbeNewPath -Settings $Settings -Kind Profile -Path $Resolved
        return $Resolved
    }

    # When CraftProbe is called from a terminal inside a Minecraft profile (or one of
    # its immediate subfolders), offer that profile before the normal saved-path menu.
    $CurrentProfile = Find-CraftProbeProfileFromDirectory -Directory $InvocationDirectory
    if ($CurrentProfile) {
        $Rule = Get-CraftProbeWorkingDirectoryRule -Settings $Settings -ProfilePath $CurrentProfile
        if ($Rule -and $Rule.action -eq 'use') {
            Write-Host ''
            Write-Host ('Aktuelles Profil automatisch erkannt: ' + $CurrentProfile) -ForegroundColor Green
            return $CurrentProfile
        }
        elseif (-not $Rule -or $Rule.action -ne 'ignore') {
            Write-Host ''
            Write-Host 'CraftProbe wurde aus einem Minecraft-Profil gestartet:' -ForegroundColor Cyan
            Write-Host ('  ' + $CurrentProfile)
            $UseCurrent = Read-CraftProbeYesNo -Prompt 'Dieses Profil fuer die Diagnose verwenden?' -DefaultYes $true
            $Remember = Read-CraftProbeYesNo -Prompt 'Diese Entscheidung fuer dieses Profil merken (nicht nochmal fragen)?' -DefaultYes $false
            if ($Remember) {
                $Action = $(if ($UseCurrent) { 'use' } else { 'ignore' })
                Set-CraftProbeWorkingDirectoryRule -Settings $Settings -ProfilePath $CurrentProfile -Action $Action
                if ($UseCurrent) { Add-CraftProbeSavedPath -Settings $Settings -Kind Profile -Path $CurrentProfile; Save-CraftProbeSettings $Settings }
            }
            elseif ($UseCurrent) {
                Register-CraftProbeNewPath -Settings $Settings -Kind Profile -Path $CurrentProfile
            }
            if ($UseCurrent) { return $CurrentProfile }
        }
    }

    while ($true) {
        $Items = @($Settings.profiles)
        if ($Items.Count -eq 0) {
            Write-Host ''
            Write-Host 'Noch kein Minecraft-Profil gespeichert.' -ForegroundColor Cyan
            Write-Host ' N. Neuen Profilpfad auswaehlen'
            Write-Host ' V. Einstellungen / PATH verwalten'
            Write-Host ' Q. Abbrechen'
            $FirstChoice = (Read-Host 'Auswahl [Enter = N]').Trim()
            if ([string]::IsNullOrWhiteSpace($FirstChoice)) { $FirstChoice = 'N' }
            if ($FirstChoice -match '^[qQ]$') { throw [System.OperationCanceledException]::new('Vom Benutzer abgebrochen.') }
            if ($FirstChoice -match '^[vV]$') { Manage-CraftProbeSettings -Settings $Settings; continue }
            if ($FirstChoice -notmatch '^[nN]$') { Write-Host 'Ungueltige Auswahl.' -ForegroundColor Yellow; continue }
            $New = Select-CraftProbeNewProfilePath -InitialDirectory $InvocationDirectory
            if ($New) {
                Register-CraftProbeNewPath -Settings $Settings -Kind Profile -Path $New
                return $New
            }
            continue
        }

        Write-Host ''
        Write-Host 'Minecraft-Profil waehlen' -ForegroundColor Cyan
        Write-Host '------------------------'
        $DefaultIndex = -1
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $P = $Items[$i]
            $Name = Get-CraftProbeProfileDisplayName $P
            $IsDefault = (Test-CraftProbePathEqual $P $Settings.defaultProfile)
            if ($IsDefault) { $DefaultIndex = $i }
            $Missing = -not (Test-Path -LiteralPath $P -PathType Container)
            $Flags = @()
            if ($IsDefault) { $Flags += 'Standard' }
            if ($Missing) { $Flags += 'fehlt' }
            $FlagText = $(if ($Flags.Count -gt 0) { ' [' + ($Flags -join ', ') + ']' } else { '' })
            Write-Host (('{0,2}. {1} - {2}{3}' -f ($i + 1),$Name,$P,$FlagText))
        }
        Write-Host ' N. Neuen Profilpfad auswaehlen'
        Write-Host ' V. Einstellungen / Pfade / PATH verwalten'
        Write-Host ' Q. Abbrechen'

        $DefaultChoice = 1
        if ($DefaultIndex -ge 0 -and (Test-Path -LiteralPath $Items[$DefaultIndex] -PathType Container)) {
            $DefaultChoice = $DefaultIndex + 1
        }
        else {
            for ($i = 0; $i -lt $Items.Count; $i++) {
                if (Test-Path -LiteralPath $Items[$i] -PathType Container) { $DefaultChoice = $i + 1; break }
            }
        }
        $Choice = Read-Host ('Auswahl [Enter = ' + $DefaultChoice + ']')
        if ([string]::IsNullOrWhiteSpace($Choice)) { $Choice = [string]$DefaultChoice }
        $Choice = $Choice.Trim()

        if ($Choice -match '^[qQ]$') { throw [System.OperationCanceledException]::new('Vom Benutzer abgebrochen.') }
        if ($Choice -match '^[vV]$') { Manage-CraftProbeSettings -Settings $Settings; continue }
        if ($Choice -match '^[nN]$') {
            $Initial = $(if ($Settings.defaultProfile) { $Settings.defaultProfile } else { $Items[0] })
            $New = Select-CraftProbeNewProfilePath -InitialDirectory $Initial
            if ($New) {
                Register-CraftProbeNewPath -Settings $Settings -Kind Profile -Path $New
                return $New
            }
            continue
        }

        $Index = 0
        if ([int]::TryParse($Choice,[ref]$Index) -and $Index -ge 1 -and $Index -le $Items.Count) {
            $Resolved = Resolve-CraftProbeProfileCandidate $Items[$Index - 1]
            if ($Resolved) { return $Resolved }
            Write-Host 'Dieser gespeicherte Profilpfad existiert nicht mehr oder ist ungueltig.' -ForegroundColor Yellow
            continue
        }
        Write-Host 'Ungueltige Auswahl.' -ForegroundColor Yellow
    }
}

function Select-CraftProbeOutputPath {
    param(
        $Settings,
        [string]$ProfilePath,
        [string]$RequestedPath
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $Resolved = Get-CraftProbeNormalizedPath $RequestedPath
        if (-not $Resolved) { throw 'Der uebergebene Exportpfad ist ungueltig.' }
        Register-CraftProbeNewPath -Settings $Settings -Kind Export -Path $Resolved
        return $Resolved
    }

    while ($true) {
        $Items = @($Settings.exports)
        Write-Host ''
        Write-Host 'Exportziel waehlen' -ForegroundColor Cyan
        Write-Host '------------------'

        $ProfileIsDefault = ($Settings.defaultExport -eq $script:CraftProbeProfileOutputToken)
        $ProfileFlag = $(if ($ProfileIsDefault) { ' [Standard]' } else { '' })
        Write-Host (' 1. Profilordner selbst - ' + $ProfilePath + $ProfileFlag)

        $DefaultChoice = 1
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $P = $Items[$i]
            $IsDefault = ($Settings.defaultExport -ne $script:CraftProbeProfileOutputToken -and (Test-CraftProbePathEqual $P $Settings.defaultExport))
            if ($IsDefault) { $DefaultChoice = $i + 2 }
            $Missing = -not (Test-Path -LiteralPath $P -PathType Container)
            $Flags = @()
            if ($IsDefault) { $Flags += 'Standard' }
            if ($Missing) { $Flags += 'fehlt' }
            $FlagText = $(if ($Flags.Count -gt 0) { ' [' + ($Flags -join ', ') + ']' } else { '' })
            Write-Host (('{0,2}. {1}{2}' -f ($i + 2),$P,$FlagText))
        }
        Write-Host ' N. Neuen Exportpfad auswaehlen'
        Write-Host ' V. Gespeicherte Pfade verwalten'

        $Choice = Read-Host ('Auswahl [Enter = ' + $DefaultChoice + ']')
        if ([string]::IsNullOrWhiteSpace($Choice)) { $Choice = [string]$DefaultChoice }
        $Choice = $Choice.Trim()

        if ($Choice -match '^[vV]$') { Manage-CraftProbeSavedPaths -Settings $Settings -Kind Export; continue }
        if ($Choice -match '^[nN]$') {
            $New = Select-CraftProbeNewExportPath -InitialDirectory $ProfilePath
            if ($New) {
                Register-CraftProbeNewPath -Settings $Settings -Kind Export -Path $New
                return $New
            }
            continue
        }

        $Index = 0
        if ([int]::TryParse($Choice,[ref]$Index)) {
            if ($Index -eq 1) { return $ProfilePath }
            $SavedIndex = $Index - 2
            if ($SavedIndex -ge 0 -and $SavedIndex -lt $Items.Count) {
                $Selected = Get-CraftProbeNormalizedPath $Items[$SavedIndex]
                if (-not $Selected) {
                    Write-Host 'Der gespeicherte Exportpfad ist ungueltig.' -ForegroundColor Yellow
                    continue
                }
                return $Selected
            }
        }
        Write-Host 'Ungueltige Auswahl.' -ForegroundColor Yellow
    }
}

function Resolve-CraftProbeStartupPaths {
    param(
        [string]$RequestedProfilePath,
        [string]$RequestedOutputPath,
        [string]$InvocationDirectory
    )

    $Settings = Get-CraftProbeSettings
    $SelectedProfile = Select-CraftProbeProfilePath -Settings $Settings -RequestedPath $RequestedProfilePath -InvocationDirectory $InvocationDirectory
    $SelectedOutput = Select-CraftProbeOutputPath -Settings $Settings -ProfilePath $SelectedProfile -RequestedPath $RequestedOutputPath

    return [pscustomobject]@{
        ProfilePath  = $SelectedProfile
        OutputPath   = $SelectedOutput
        SettingsPath = Get-CraftProbeSettingsPath
    }
}

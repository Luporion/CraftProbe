#requires -Version 5.1
param([switch]$Publish = $true)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Project = Join-Path $Root 'tui\CraftProbe.Tui\CraftProbe.Tui.csproj'
$Dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $Dotnet) {
    Write-Host 'Fehlt: .NET SDK 10 (https://dotnet.microsoft.com/download/dotnet/10.0)' -ForegroundColor Yellow
    exit 2
}
$Dest = Join-Path $Root 'tui\bin'
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Write-Host 'Baue CraftProbe Terminal.Gui 2.5.0 ...'
if ($Publish) {
    & dotnet publish $Project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishTrimmed=false -o $Dest
} else {
    & dotnet build $Project -c Release
}
if ($LASTEXITCODE -ne 0) { throw "TUI build failed ($LASTEXITCODE)." }
$Exe = Join-Path $Dest 'CraftProbe.Tui.exe'
if ($Publish -and -not (Test-Path -LiteralPath $Exe)) { throw 'TUI EXE missing after publish.' }
Write-Host "Build fertig: $Exe" -ForegroundColor Green
Write-Host 'Jetzt .\CraftProbe.cmd starten. Mit --cli weiterhin PowerShell-CLI verwenden.'

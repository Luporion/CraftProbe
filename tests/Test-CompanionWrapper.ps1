#requires -Version 5.1
# Offline smoke test for .NET SHA-256 helper; run with Windows PowerShell 5.1 or PowerShell 7.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'companion/NeoForge-1.21.1/scripts/Get-CraftProbeSha256.ps1')
$Path = Join-Path ([System.IO.Path]::GetTempPath()) ('craftprobe-sha256-test-' + [Guid]::NewGuid().ToString('N'))
try {
    [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::ASCII.GetBytes('abc'))
    # Deliberately shadow the cmdlet to prove the helper has no runtime dependency on it.
    function Get-FileHash { throw 'Get-FileHash darf in diesem Test nicht aufgerufen werden' }
    $Actual = Get-CraftProbeSha256 -LiteralPath $Path
    $Expected = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    if ($Actual -ne $Expected) { throw "SHA256 Fehler: $Actual statt $Expected" }
    Write-Host "PASS CraftProbe .NET SHA256 (Get-FileHash absichtlich blockiert)" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
}

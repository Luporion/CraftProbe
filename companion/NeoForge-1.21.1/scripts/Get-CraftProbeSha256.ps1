#requires -Version 5.1
# Shared SHA-256 implementation; does not depend on Get-FileHash or any PowerShell module.
function Get-CraftProbeSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    $Stream = $null
    try {
        # The stream is closed even when ComputeHash throws.
        $Stream = [System.IO.File]::Open(
            $LiteralPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $Bytes = $Hasher.ComputeHash($Stream)
        return ([System.BitConverter]::ToString($Bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $Stream) { $Stream.Dispose() }
        $Hasher.Dispose()
    }
}

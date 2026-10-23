[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$testRoot = Join-Path $repositoryRoot "artifacts\scan-sensitive-data-test-$([Guid]::NewGuid().ToString('N'))"
$testFile = Join-Path $testRoot 'upstream-example.txt'
$scanner = Join-Path $PSScriptRoot 'scan-sensitive-data.ps1'

function Assert-ScanFails {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $Label
    )

    try {
        & $Action
    }
    catch {
        return
    }
    throw "Expected sensitive-data scan failure: $Label"
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $privateKeyMarker = [string]::Concat('-----BEGIN ', 'PRIVATE KEY----- example marker only')
    Set-Content -LiteralPath $testFile -Value $privateKeyMarker -Encoding utf8NoBOM -NoNewline
    $allowedHash = (Get-FileHash -LiteralPath $testFile -Algorithm SHA256).Hash.ToLowerInvariant()

    Assert-ScanFails -Label 'unapproved pattern' -Action {
        & $scanner -Paths @($testRoot)
    }
    & $scanner -Paths @($testRoot) -AllowedPatternFindingSha256 @($allowedHash)

    Add-Content -LiteralPath $testFile -Value ' changed' -Encoding utf8NoBOM -NoNewline
    Assert-ScanFails -Label 'changed allowlisted content' -Action {
        & $scanner -Paths @($testRoot) -AllowedPatternFindingSha256 @($allowedHash)
    }

    $changedHash = (Get-FileHash -LiteralPath $testFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-ScanFails -Label 'canary remains non-allowlistable' -Action {
        & $scanner `
            -Paths @($testRoot) `
            -CanaryValues @('example marker only') `
            -AllowedPatternFindingSha256 @($changedHash)
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Sensitive-data scan allowlist tests passed: 4/4.'

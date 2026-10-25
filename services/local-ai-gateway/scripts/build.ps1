[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [switch] $NoRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$solutionPath = Join-Path $repositoryRoot 'LocalAIGateway.slnx'

function Invoke-DotNet {
    param([Parameter(Mandatory)][string[]] $Arguments)

    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

Push-Location $repositoryRoot
try {
    if (-not $NoRestore) {
        Invoke-DotNet -Arguments @('restore', $solutionPath)
    }

    Invoke-DotNet -Arguments @(
        'build',
        $solutionPath,
        '--configuration', $Configuration,
        '--no-restore',
        '-p:ContinuousIntegrationBuild=true'
    )

    Invoke-DotNet -Arguments @(
        'test',
        $solutionPath,
        '--configuration', $Configuration,
        '--no-build',
        '--no-restore'
    )

    & (Join-Path $PSScriptRoot 'scan-sensitive-data.ps1') `
        -Paths @($repositoryRoot) `
        -ExcludeGenerated
}
finally {
    Pop-Location
}

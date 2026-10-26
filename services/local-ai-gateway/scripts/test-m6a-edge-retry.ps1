[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$testRoot = Join-Path $artifactsRoot "m6a-edge-retry-check-$([Guid]::NewGuid().ToString('N'))"
$publishRoot = Join-Path $testRoot 'publish'
$runtimeProject = Join-Path $repositoryRoot 'src\LocalAIGateway.Runtime\LocalAIGateway.Runtime.csproj'
$testProject = Join-Path $repositoryRoot 'tests\LocalAIGateway.Runtime.Tests\LocalAIGateway.Runtime.Tests.csproj'

function Invoke-DotNet {
    param([Parameter(Mandatory)][string[]] $Arguments)

    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

try {
    New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
    Invoke-DotNet -Arguments @(
        'test',
        $testProject,
        '--configuration', $Configuration,
        '--no-restore'
    )
    Invoke-DotNet -Arguments @(
        'publish',
        $runtimeProject,
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '--no-restore',
        '--output', $publishRoot,
        '-p:PublishTrimmed=false',
        '-p:PublishSingleFile=false',
        '-p:PublishReadyToRun=false'
    )

    $runtimeExecutable = Join-Path $publishRoot 'aigw-runtime.exe'
    if (-not (Test-Path -LiteralPath $runtimeExecutable -PathType Leaf)) {
        throw 'The self-contained Runtime publish did not produce aigw-runtime.exe.'
    }

    $priorDotnetRoot = $env:DOTNET_ROOT
    $priorMultilevelLookup = $env:DOTNET_MULTILEVEL_LOOKUP
    try {
        $env:DOTNET_ROOT = Join-Path $testRoot 'nonexistent-dotnet-root'
        $env:DOTNET_MULTILEVEL_LOOKUP = '0'
        $versionOutput = & $runtimeExecutable --version
        if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '^Local AI Gateway Runtime ') {
            throw 'The self-contained Runtime executable smoke failed.'
        }

        $headCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch [regex]::Escape($headCommit)) {
            throw 'The Runtime ProductVersion does not identify the current feature commit.'
        }
    }
    finally {
        $env:DOTNET_ROOT = $priorDotnetRoot
        $env:DOTNET_MULTILEVEL_LOOKUP = $priorMultilevelLookup
    }
}
finally {
    $processMatches = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($testRoot, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($processMatches.Count -ne 0) {
        throw "M6a left $($processMatches.Count) process(es) running from its test root."
    }

    if (Test-Path -LiteralPath $testRoot) {
        $artifactsPrefix = [System.IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\', '/') +
            [System.IO.Path]::DirectorySeparatorChar
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTestRoot.StartsWith($artifactsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove an M6a test root outside artifacts: $resolvedTestRoot"
        }

        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Output 'M6a retry tests and self-contained Runtime executable smoke passed with zero test-root residue.'

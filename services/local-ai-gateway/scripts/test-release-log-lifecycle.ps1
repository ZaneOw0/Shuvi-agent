[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$testRoot = Join-Path $artifactsRoot "release-log-lifecycle-check-$([Guid]::NewGuid().ToString('N'))"
$publishRoot = Join-Path $testRoot 'publish'
$realRuntimeRoot = Join-Path $testRoot 'real-runtime'

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
        (Join-Path $repositoryRoot 'tests\LocalAIGateway.Runtime.Tests\LocalAIGateway.Runtime.Tests.csproj'),
        '--configuration', $Configuration,
        '--no-restore',
        '--filter',
        'FullyQualifiedName~GatewayOperationalLogTests|FullyQualifiedName~Lifecycle_log_contains|FullyQualifiedName~GatewayDaemonControlTests'
    )

    if ($Configuration -eq 'Release') {
        & (Join-Path $PSScriptRoot 'test-m3e-runtime.ps1') -TestRoot $realRuntimeRoot
        if ($LASTEXITCODE -ne 0) {
            throw "The real private-Runtime operational-log acceptance failed with exit code $LASTEXITCODE."
        }
    }

    Invoke-DotNet -Arguments @(
        'publish',
        (Join-Path $repositoryRoot 'src\LocalAIGateway.Runtime\LocalAIGateway.Runtime.csproj'),
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
        throw 'The self-contained publish did not produce aigw-runtime.exe.'
    }

    $headCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'The current feature commit could not be resolved.'
    }

    $priorDotnetRoot = $env:DOTNET_ROOT
    $priorMultilevelLookup = $env:DOTNET_MULTILEVEL_LOOKUP
    try {
        $env:DOTNET_ROOT = Join-Path $testRoot 'nonexistent-dotnet-root'
        $env:DOTNET_MULTILEVEL_LOOKUP = '0'
        $versionOutput = & $runtimeExecutable --version
        if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '^Local AI Gateway Runtime') {
            throw 'The self-contained Runtime executable smoke failed.'
        }

        $productVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($runtimeExecutable).ProductVersion
        if ($productVersion -notmatch [regex]::Escape($headCommit)) {
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
    foreach ($processMatch in $processMatches) {
        try {
            $processMatch.Kill($true)
            $processMatch.WaitForExit(5000)
        }
        catch {
            # The exact test-owned process may have exited between enumeration and cleanup.
        }
    }

    if (Test-Path -LiteralPath $testRoot) {
        $artifactsPrefix = [System.IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\', '/') +
            [System.IO.Path]::DirectorySeparatorChar
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTestRoot.StartsWith($artifactsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a log-lifecycle test root outside artifacts: $resolvedTestRoot"
        }

        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }

    $remainingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($testRoot, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($remainingProcesses.Count -ne 0) {
        throw "Log-lifecycle acceptance could not clean $($remainingProcesses.Count) process(es) from its exact test root."
    }
}

Write-Output 'Operational log lifecycle tests, real private-Runtime acceptance, and self-contained Runtime smoke passed with zero test-root residue.'

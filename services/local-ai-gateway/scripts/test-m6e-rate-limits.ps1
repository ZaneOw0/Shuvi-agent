[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$testRoot = Join-Path $artifactsRoot "m6e-rate-limits-check-$([Guid]::NewGuid().ToString('N'))"
$publishRoot = Join-Path $testRoot 'publish'
$testCases = @(
    @{
        Project = 'tests\LocalAIGateway.Core.Tests\LocalAIGateway.Core.Tests.csproj'
        Filter = 'FullyQualifiedName~RequestLimits'
    },
    @{
        Project = 'tests\LocalAIGateway.Cli.Tests\LocalAIGateway.Cli.Tests.csproj'
        Filter = 'FullyQualifiedName~LimitCommands'
    },
    @{
        Project = 'tests\LocalAIGateway.Runtime.Tests\LocalAIGateway.Runtime.Tests.csproj'
        Filter = 'FullyQualifiedName~GatewayRequestLimitRegistryTests|FullyQualifiedName~GatewayResponseUsageTrackerTests|FullyQualifiedName~GatewayRateLimitIntegrationTests'
    }
)
$publishProjects = @(
    @{ Project = 'src\LocalAIGateway.Runtime\LocalAIGateway.Runtime.csproj'; Directory = 'runtime'; Executable = 'aigw-runtime.exe' },
    @{ Project = 'src\LocalAIGateway.Cli\LocalAIGateway.Cli.csproj'; Directory = 'cli'; Executable = 'aigw.exe' }
)

function Invoke-DotNet {
    param([Parameter(Mandatory)][string[]] $Arguments)

    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

try {
    New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
    foreach ($testCase in $testCases) {
        Invoke-DotNet -Arguments @(
            'test',
            (Join-Path $repositoryRoot $testCase.Project),
            '--configuration', $Configuration,
            '--no-restore',
            '--filter', $testCase.Filter
        )
    }

    foreach ($item in $publishProjects) {
        $output = Join-Path $publishRoot $item.Directory
        Invoke-DotNet -Arguments @(
            'publish',
            (Join-Path $repositoryRoot $item.Project),
            '--configuration', $Configuration,
            '--runtime', 'win-x64',
            '--self-contained', 'true',
            '--no-restore',
            '--output', $output,
            '-p:PublishTrimmed=false',
            '-p:PublishSingleFile=false',
            '-p:PublishReadyToRun=false'
        )

        $executable = Join-Path $output $item.Executable
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "The self-contained publish did not produce $($item.Executable)."
        }
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
        foreach ($item in $publishProjects) {
            $executable = Join-Path (Join-Path $publishRoot $item.Directory) $item.Executable
            $versionOutput = & $executable --version
            if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '^Local AI Gateway') {
                throw "The self-contained $($item.Executable) executable smoke failed."
            }

            $productVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($executable).ProductVersion
            if ($productVersion -notmatch [regex]::Escape($headCommit)) {
                throw "$($item.Executable) ProductVersion does not identify the current feature commit."
            }
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
            throw "Refusing to remove an M6e test root outside artifacts: $resolvedTestRoot"
        }

        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }

    $remainingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($testRoot, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($remainingProcesses.Count -ne 0) {
        throw "M6e could not clean $($remainingProcesses.Count) process(es) from its exact test root."
    }
}

Write-Output 'M6e rate-limit tests and self-contained Runtime/CLI executable smoke passed with zero test-root residue.'

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$testRoot = Join-Path $artifactsRoot "m5b-tray-check-$([Guid]::NewGuid().ToString('N'))"
$publishRoot = Join-Path $testRoot 'publish'
$trayProject = Join-Path $repositoryRoot 'src\LocalAIGateway.Tray\LocalAIGateway.Tray.csproj'
$testProject = Join-Path $repositoryRoot 'tests\LocalAIGateway.Tray.Tests\LocalAIGateway.Tray.Tests.csproj'

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
        'restore',
        $trayProject,
        '--runtime', 'win-x64',
        '--ignore-failed-sources',
        '-p:NuGetAudit=false'
    )
    Invoke-DotNet -Arguments @(
        'test',
        $testProject,
        '--configuration', $Configuration,
        '--no-restore'
    )
    Invoke-DotNet -Arguments @(
        'publish',
        $trayProject,
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '--no-restore',
        '--output', $publishRoot,
        '-p:PublishTrimmed=false',
        '-p:PublishSingleFile=false',
        '-p:PublishReadyToRun=false'
    )

    $trayExecutable = Join-Path $publishRoot 'aigw-tray.exe'
    if (-not (Test-Path -LiteralPath $trayExecutable -PathType Leaf)) {
        throw 'The self-contained Tray publish did not produce aigw-tray.exe.'
    }

    $priorDotnetRoot = $env:DOTNET_ROOT
    $priorMultilevelLookup = $env:DOTNET_MULTILEVEL_LOOKUP
    try {
        $env:DOTNET_ROOT = Join-Path $testRoot 'nonexistent-dotnet-root'
        $env:DOTNET_MULTILEVEL_LOOKUP = '0'
        $process = Start-Process `
            -FilePath $trayExecutable `
            -ArgumentList '--version' `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        if ($process.ExitCode -ne 0) {
            throw "The self-contained Tray executable smoke failed with exit code $($process.ExitCode)."
        }
    }
    finally {
        $env:DOTNET_ROOT = $priorDotnetRoot
        $env:DOTNET_MULTILEVEL_LOOKUP = $priorMultilevelLookup
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $artifactsPrefix = [System.IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTestRoot.StartsWith($artifactsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a Tray test root outside artifacts: $resolvedTestRoot"
        }

        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Output 'M5b Tray tests and self-contained executable smoke passed with zero test-root residue.'

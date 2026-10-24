[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$testRoot = Join-Path $artifactsRoot "release-install-experience-check-$([Guid]::NewGuid().ToString('N'))"
$publishRoot = Join-Path $testRoot 'cli'
$isolatedLocalAppData = Join-Path $testRoot 'local-app-data'

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
        (Join-Path $repositoryRoot 'tests\LocalAIGateway.Core.Tests\LocalAIGateway.Core.Tests.csproj'),
        '--configuration', $Configuration,
        '--no-restore',
        '--filter', 'FullyQualifiedName~CurrentUserInstallationPlanTests'
    )
    Invoke-DotNet -Arguments @(
        'test',
        (Join-Path $repositoryRoot 'tests\LocalAIGateway.Windows.Tests\LocalAIGateway.Windows.Tests.csproj'),
        '--configuration', $Configuration,
        '--no-restore',
        '--filter',
        'FullyQualifiedName~CurrentUserAutostartTaskXmlTests|FullyQualifiedName~CurrentUserShellIntegrationTests|FullyQualifiedName~CurrentUserInstallationCoordinatorTests|FullyQualifiedName~CurrentUserUninstallCoordinatorTests'
    )
    Invoke-DotNet -Arguments @(
        'test',
        (Join-Path $repositoryRoot 'tests\LocalAIGateway.Cli.Tests\LocalAIGateway.Cli.Tests.csproj'),
        '--configuration', $Configuration,
        '--no-restore',
        '--filter', 'FullyQualifiedName~M3gLifecycleCommandTests'
    )

    Invoke-DotNet -Arguments @(
        'publish',
        (Join-Path $repositoryRoot 'src\LocalAIGateway.Cli\LocalAIGateway.Cli.csproj'),
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '--no-restore',
        '--output', $publishRoot,
        '-p:PublishTrimmed=false',
        '-p:PublishSingleFile=false',
        '-p:PublishReadyToRun=false'
    )

    $cliExecutable = Join-Path $publishRoot 'aigw.exe'
    if (-not (Test-Path -LiteralPath $cliExecutable -PathType Leaf)) {
        throw 'The self-contained publish did not produce aigw.exe.'
    }

    $headCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'The current feature commit could not be resolved.'
    }

    $priorDotnetRoot = $env:DOTNET_ROOT
    $priorMultilevelLookup = $env:DOTNET_MULTILEVEL_LOOKUP
    $priorLocalAppData = $env:LOCALAPPDATA
    try {
        $env:DOTNET_ROOT = Join-Path $testRoot 'nonexistent-dotnet-root'
        $env:DOTNET_MULTILEVEL_LOOKUP = '0'
        $env:LOCALAPPDATA = $isolatedLocalAppData

        $helpOutput = (& $cliExecutable install --lang en --help 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or
            -not $helpOutput.Contains('--autostart', [StringComparison]::Ordinal) -or
            -not $helpOutput.Contains('user PATH', [StringComparison]::Ordinal) -or
            -not $helpOutput.Contains('Tray Start Menu shortcut', [StringComparison]::Ordinal)) {
            throw 'The self-contained CLI install help does not expose the locked autostart, PATH, and Start Menu behavior.'
        }

        $gateOutput = (& $cliExecutable install --json 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 15 -or
            -not $gateOutput.Contains('aigw_install_autostart_choice_required', [StringComparison]::Ordinal)) {
            throw 'The self-contained CLI did not enforce an explicit JSON autostart choice.'
        }
        if (Test-Path -LiteralPath (Join-Path $isolatedLocalAppData 'Programs\LocalAIGateway')) {
            throw 'The JSON autostart-choice gate unexpectedly created a program installation.'
        }
        if (Test-Path -LiteralPath (Join-Path $isolatedLocalAppData 'LocalAIGateway')) {
            throw 'The JSON autostart-choice gate unexpectedly created gateway state.'
        }

        $productVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($cliExecutable).ProductVersion
        if ($productVersion -notmatch [regex]::Escape($headCommit)) {
            throw 'The CLI ProductVersion does not identify the current feature commit.'
        }
    }
    finally {
        $env:DOTNET_ROOT = $priorDotnetRoot
        $env:DOTNET_MULTILEVEL_LOOKUP = $priorMultilevelLookup
        $env:LOCALAPPDATA = $priorLocalAppData
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
            throw "Refusing to remove an install-experience test root outside artifacts: $resolvedTestRoot"
        }

        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }

    $remainingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($testRoot, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($remainingProcesses.Count -ne 0) {
        throw "Install-experience acceptance could not clean $($remainingProcesses.Count) process(es) from its exact test root."
    }
}

Write-Output 'Release install-experience tests and self-contained CLI gate smoke passed with zero test-root residue.'

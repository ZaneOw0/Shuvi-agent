[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$testRoot = Join-Path $artifactsRoot "m6b-circuit-breaker-check-$([Guid]::NewGuid().ToString('N'))"
$publishRoot = Join-Path $testRoot 'publish'
$packageRoots = @(
    (Join-Path $testRoot 'package-repro-1'),
    (Join-Path $testRoot 'package-repro-2')
)
$extractedPackage = Join-Path $testRoot 'extracted package with spaces'
$packageName = 'LocalAIGateway-0.1.0-dev-win-x64-unsigned.zip'
$testProjects = @(
    'tests\LocalAIGateway.Core.Tests\LocalAIGateway.Core.Tests.csproj',
    'tests\LocalAIGateway.Windows.Tests\LocalAIGateway.Windows.Tests.csproj',
    'tests\LocalAIGateway.Cli.Tests\LocalAIGateway.Cli.Tests.csproj',
    'tests\LocalAIGateway.Runtime.Tests\LocalAIGateway.Runtime.Tests.csproj',
    'tests\LocalAIGateway.Tray.Tests\LocalAIGateway.Tray.Tests.csproj'
)
$publishProjects = @(
    @{ Project = 'src\LocalAIGateway.Runtime\LocalAIGateway.Runtime.csproj'; Directory = 'runtime'; Executable = 'aigw-runtime.exe' },
    @{ Project = 'src\LocalAIGateway.Cli\LocalAIGateway.Cli.csproj'; Directory = 'cli'; Executable = 'aigw.exe' },
    @{ Project = 'src\LocalAIGateway.Tray\LocalAIGateway.Tray.csproj'; Directory = 'tray'; Executable = 'aigw-tray.exe' }
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
    foreach ($relativeProject in $testProjects) {
        Invoke-DotNet -Arguments @(
            'test',
            (Join-Path $repositoryRoot $relativeProject),
            '--configuration', $Configuration,
            '--no-restore'
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
            $productVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($executable).ProductVersion
            if ($productVersion -notmatch [regex]::Escape($headCommit)) {
                throw "$($item.Executable) ProductVersion does not identify the current feature commit."
            }

            if ($item.Executable -eq 'aigw-tray.exe') {
                $process = Start-Process `
                    -FilePath $executable `
                    -ArgumentList '--version' `
                    -WindowStyle Hidden `
                    -Wait `
                    -PassThru
                if ($process.ExitCode -ne 0) {
                    throw "The self-contained Tray executable smoke failed with exit code $($process.ExitCode)."
                }
            }
            else {
                $versionOutput = & $executable --version
                if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '^Local AI Gateway') {
                    throw "The self-contained $($item.Executable) executable smoke failed."
                }
            }
        }
    }
    finally {
        $env:DOTNET_ROOT = $priorDotnetRoot
        $env:DOTNET_MULTILEVEL_LOOKUP = $priorMultilevelLookup
    }

    foreach ($packageRoot in $packageRoots) {
        & (Join-Path $repositoryRoot 'scripts\package.ps1') `
            -Configuration $Configuration `
            -ArtifactsDirectory $packageRoot `
            -NoRestore `
            -RefuseExistingArtifacts `
            -CleanWorkingDirectories
        if ($LASTEXITCODE -ne 0) {
            throw "M6b package build failed with exit code $LASTEXITCODE."
        }
    }

    $firstPackage = Join-Path $packageRoots[0] $packageName
    $secondPackage = Join-Path $packageRoots[1] $packageName
    $packageHash = (Get-FileHash -LiteralPath $firstPackage -Algorithm SHA256).Hash.ToLowerInvariant()
    $secondPackageHash = (Get-FileHash -LiteralPath $secondPackage -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($packageHash -ne $secondPackageHash) {
        throw 'M6b full-package reproducibility verification failed.'
    }

    Expand-Archive -LiteralPath $firstPackage -DestinationPath $extractedPackage
    $manifestPath = Join-Path $extractedPackage 'PACKAGE-MANIFEST.json'
    $signaturePath = Join-Path $extractedPackage 'PACKAGE-SIGNATURE.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $signature = Get-Content -LiteralPath $signaturePath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or -not $manifest.unsigned -or $manifest.files.Count -eq 0) {
        throw 'M6b package manifest metadata is invalid.'
    }

    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($signature.algorithm -ne 'none' -or
        $signature.manifestSha256 -ne $manifestHash -or
        $null -ne $signature.signature) {
        throw 'M6b unsigned package signature metadata does not bind the manifest.'
    }

    foreach ($manifestItem in $manifest.files) {
        $itemPath = Join-Path $extractedPackage $manifestItem.path.Replace('/', '\')
        $item = Get-Item -LiteralPath $itemPath -Force
        $itemHash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($item.Length -ne $manifestItem.size -or $itemHash -ne $manifestItem.sha256) {
            throw "M6b package manifest verification failed for $($manifestItem.path)."
        }
    }

    $packageFiles = @(
        Get-ChildItem -LiteralPath $extractedPackage -Recurse -File -Force
    )
    if ($packageFiles.Count -ne $manifest.files.Count + 2) {
        throw 'M6b package contains files outside the manifest and signature envelope.'
    }

    $packagedExecutables = @(
        'aigw.exe',
        'aigw-runtime.exe',
        'aigw-launcher.exe',
        'tray\aigw-tray.exe',
        'updater\aigw-updater.exe'
    )
    foreach ($executableName in $packagedExecutables) {
        $executablePath = Join-Path $extractedPackage $executableName
        $productVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($executablePath).ProductVersion
        if ($productVersion -notmatch [regex]::Escape($headCommit)) {
            throw "Packaged $executableName ProductVersion does not identify the current feature commit."
        }
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
            throw "Refusing to remove an M6b test root outside artifacts: $resolvedTestRoot"
        }

        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }

    $remainingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($testRoot, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($remainingProcesses.Count -ne 0) {
        throw "M6b could not clean $($remainingProcesses.Count) process(es) from its exact test root."
    }
}

Write-Output "M6b circuit-breaker tests, self-contained EXE smoke, and reproducible full package passed; manifest $($manifest.files.Count), SHA-256 $packageHash, zero test-root residue."

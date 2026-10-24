[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [string] $ArtifactsDirectory = '',
    [string[]] $CanaryValues = @(),
    [switch] $NoRestore,
    [switch] $RefuseExistingArtifacts,
    [switch] $CleanWorkingDirectories
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ArtifactsDirectory)) {
    $ArtifactsDirectory = Join-Path $repositoryRoot 'artifacts'
}
elseif (-not [System.IO.Path]::IsPathFullyQualified($ArtifactsDirectory)) {
    $ArtifactsDirectory = Join-Path $repositoryRoot $ArtifactsDirectory
}

$artifactsRoot = [System.IO.Path]::GetFullPath($ArtifactsDirectory)
$publishDirectory = Join-Path $artifactsRoot 'staging\win-x64'
$isolatedPublishRoot = Join-Path $artifactsRoot 'publish\win-x64'
$cliPublishDirectory = Join-Path $isolatedPublishRoot 'cli'
$launcherPublishDirectory = Join-Path $isolatedPublishRoot 'launcher'
$runtimePublishDirectory = Join-Path $isolatedPublishRoot 'runtime'
$trayPublishDirectory = Join-Path $isolatedPublishRoot 'tray'
$updaterPublishDirectory = Join-Path $isolatedPublishRoot 'updater'
$packageName = 'LocalAIGateway-0.1.0-dev-win-x64-unsigned.zip'
$packagePath = Join-Path $artifactsRoot $packageName
$hashPath = "$packagePath.sha256"
$coreProject = Join-Path $repositoryRoot 'src\LocalAIGateway.Core\LocalAIGateway.Core.csproj'
$windowsProject = Join-Path $repositoryRoot 'src\LocalAIGateway.Windows\LocalAIGateway.Windows.csproj'
$cliProject = Join-Path $repositoryRoot 'src\LocalAIGateway.Cli\LocalAIGateway.Cli.csproj'
$launcherProject = Join-Path $repositoryRoot 'src\LocalAIGateway.Launcher\LocalAIGateway.Launcher.csproj'
$runtimeProject = Join-Path $repositoryRoot 'src\LocalAIGateway.Runtime\LocalAIGateway.Runtime.csproj'
$trayProject = Join-Path $repositoryRoot 'src\LocalAIGateway.Tray\LocalAIGateway.Tray.csproj'
$updaterProject = Join-Path $repositoryRoot 'src\LocalAIGateway.Updater\LocalAIGateway.Updater.csproj'
$privateRuntimeAssembly = Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly'
$privateRuntimeLock = Join-Path $repositoryRoot 'runtime-manifests\m3b-text-runtime.lock.json'
$packageManifestName = 'PACKAGE-MANIFEST.json'
$packageSignatureName = 'PACKAGE-SIGNATURE.json'
$privateRuntimeSensitiveScanAllowlist = @(
    # Exact upstream dependency bytes containing private-key marker examples/schema text.
    # Any dependency change produces a new hash and restores fail-closed scanning.
    '1d5e99a888ea34d68d50be8ce2043234926d67be44b22499b3acb175da81ad62',
    'e7e77bee1c66135f3d33031c0b2018bb125d1dce891027798d8b81e3cde21256'
)

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string] $Parent,
        [Parameter(Mandatory)][string] $Child
    )

    $parentPrefix = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $childFullPath = [System.IO.Path]::GetFullPath($Child)
    if (-not $childFullPath.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the artifacts directory: $childFullPath"
    }
}

function Invoke-DotNet {
    param([Parameter(Mandatory)][string[]] $Arguments)

    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function New-DeterministicZip {
    param(
        [Parameter(Mandatory)][string] $SourceDirectory,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    $relativePaths = @(
        Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File |
            ForEach-Object { [System.IO.Path]::GetRelativePath($SourceDirectory, $_.FullName) }
    )
    [System.Array]::Sort($relativePaths, [System.StringComparer]::Ordinal)

    $fileStream = [System.IO.File]::Open(
        $DestinationPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $fileStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false)
        try {
            foreach ($relativePath in $relativePaths) {
                $entryName = $relativePath.Replace('\', '/')
                $entry = $archive.CreateEntry(
                    $entryName,
                    [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [System.DateTimeOffset]::new(
                    1980, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)

                $sourceStream = [System.IO.File]::OpenRead((Join-Path $SourceDirectory $relativePath))
                try {
                    $entryStream = $entry.Open()
                    try {
                        $sourceStream.CopyTo($entryStream)
                    }
                    finally {
                        $entryStream.Dispose()
                    }
                }
                finally {
                    $sourceStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }
}

function Merge-PublishDirectory {
    param(
        [Parameter(Mandatory)][string] $SourceDirectory,
        [Parameter(Mandatory)][string] $DestinationDirectory
    )

    $sourceFiles = @(
        Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File |
            Sort-Object FullName
    )
    foreach ($sourceFile in $sourceFiles) {
        $relativePath = [System.IO.Path]::GetRelativePath($SourceDirectory, $sourceFile.FullName)
        $destinationPath = Join-Path $DestinationDirectory $relativePath
        if (Test-Path -LiteralPath $destinationPath) {
            $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
            $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
            if (-not $sourceHash.Equals($destinationHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Publish output collision has different content: $relativePath"
            }

            continue
        }

        $destinationParent = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationPath
    }
}

function Copy-FileTree {
    param(
        [Parameter(Mandatory)][string] $SourceDirectory,
        [Parameter(Mandatory)][string] $DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        throw "Required package input directory does not exist: $SourceDirectory"
    }

    $reparsePoints = @(
        Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Force |
            Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 }
    )
    if ($reparsePoints.Count -ne 0) {
        throw "Refusing to package reparse point content: $($reparsePoints.FullName -join ', ')"
    }

    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File -Force | Sort-Object FullName)) {
        $relativePath = [System.IO.Path]::GetRelativePath($SourceDirectory, $sourceFile.FullName)
        $destinationPath = Join-Path $DestinationDirectory $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationPath
    }
}

function Write-PrivateRuntimeComponents {
    param(
        [Parameter(Mandatory)][string] $LockPath,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
    $stream = [System.IO.File]::Open(
        $DestinationPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
    try {
        $writerOptions = [System.Text.Json.JsonWriterOptions]::new()
        $writerOptions.Indented = $true
        $writer = [System.Text.Json.Utf8JsonWriter]::new($stream, $writerOptions)
        try {
            $writer.WriteStartObject()
            $writer.WriteNumber('schemaVersion', 1)
            $writer.WriteStartObject('sourceLock')
            $writer.WriteString('path', 'manifests/m3b-text-runtime.lock.json')
            $writer.WriteString('sha256', (Get-FileHash -LiteralPath $LockPath -Algorithm SHA256).Hash.ToLowerInvariant())
            $writer.WriteEndObject()
            $writer.WriteStartObject('python')
            $writer.WriteString('name', [string]$lock.python.name)
            $writer.WriteString('version', [string]$lock.python.version)
            $writer.WriteString('licenseExpression', [string]$lock.python.licenseExpression)
            $writer.WriteEndObject()
            $writer.WriteStartArray('wheels')
            foreach ($wheel in @($lock.wheels.included | Sort-Object name, version)) {
                $writer.WriteStartObject()
                $writer.WriteString('name', [string]$wheel.name)
                $writer.WriteString('version', [string]$wheel.version)
                $writer.WriteString('filename', [string]$wheel.filename)
                $writer.WriteString('sha256', [string]$wheel.sha256)
                $writer.WriteString('licenseExpression', [string]$wheel.licenseExpression)
                $writer.WriteString('licenseMetadata', [string]$wheel.licenseMetadata)
                $writer.WriteStartArray('licenseClassifiers')
                foreach ($classifier in @($wheel.licenseClassifiers | Sort-Object)) {
                    $writer.WriteStringValue([string]$classifier)
                }
                $writer.WriteEndArray()
                $writer.WriteEndObject()
            }
            $writer.WriteEndArray()
            $writer.WriteStartArray('runtimeData')
            foreach ($runtimeData in @($lock.runtimeData | Sort-Object packagedPath, filename)) {
                $writer.WriteStartObject()
                $writer.WriteString('name', [string]$runtimeData.name)
                $writer.WriteString('filename', [string]$runtimeData.filename)
                $writer.WriteString('packagedPath', [string]$runtimeData.packagedPath)
                $writer.WriteString('sha256', [string]$runtimeData.sha256)
                $writer.WriteEndObject()
            }
            $writer.WriteEndArray()
            $writer.WriteEndObject()
            $writer.Flush()
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Write-PackageManifest {
    param(
        [Parameter(Mandatory)][string] $PackageRoot,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    $relativePaths = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Force |
            Where-Object { -not $_.FullName.Equals($DestinationPath, [System.StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { [System.IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace('\', '/') }
    )
    [System.Array]::Sort($relativePaths, [System.StringComparer]::Ordinal)

    $stream = [System.IO.File]::Open(
        $DestinationPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
    try {
        $writer = [System.Text.Json.Utf8JsonWriter]::new($stream)
        try {
            $writer.WriteStartObject()
            $writer.WriteNumber('schemaVersion', 1)
            $writer.WriteString('packageId', 'LocalAIGateway')
            $writer.WriteString('version', '0.1.0-dev')
            $writer.WriteString('runtimeIdentifier', 'win-x64')
            $writer.WriteBoolean('unsigned', $true)
            $writer.WriteStartArray('files')
            foreach ($relativePath in $relativePaths) {
                $fullPath = Join-Path $PackageRoot $relativePath.Replace('/', '\')
                $file = Get-Item -LiteralPath $fullPath -Force
                if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing to put a reparse point in the package manifest: $relativePath"
                }

                $writer.WriteStartObject()
                $writer.WriteString('path', $relativePath)
                $writer.WriteNumber('size', [long]$file.Length)
                $writer.WriteString('sha256', (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant())
                $writer.WriteEndObject()
            }
            $writer.WriteEndArray()
            $writer.WriteEndObject()
            $writer.Flush()
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

Assert-ChildPath -Parent $artifactsRoot -Child $publishDirectory
Assert-ChildPath -Parent $artifactsRoot -Child $isolatedPublishRoot
Assert-ChildPath -Parent $artifactsRoot -Child $cliPublishDirectory
Assert-ChildPath -Parent $artifactsRoot -Child $launcherPublishDirectory
Assert-ChildPath -Parent $artifactsRoot -Child $runtimePublishDirectory
Assert-ChildPath -Parent $artifactsRoot -Child $trayPublishDirectory
Assert-ChildPath -Parent $artifactsRoot -Child $updaterPublishDirectory
Assert-ChildPath -Parent $artifactsRoot -Child $packagePath
Assert-ChildPath -Parent $artifactsRoot -Child $hashPath

if ($RefuseExistingArtifacts -and (Test-Path -LiteralPath $artifactsRoot)) {
    throw "Refusing to overwrite an existing artifacts directory: $artifactsRoot"
}

New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
if (Test-Path -LiteralPath $publishDirectory) {
    Remove-Item -LiteralPath $publishDirectory -Recurse -Force
}
if (Test-Path -LiteralPath $isolatedPublishRoot) {
    Remove-Item -LiteralPath $isolatedPublishRoot -Recurse -Force
}
if (Test-Path -LiteralPath $packagePath) {
    Remove-Item -LiteralPath $packagePath -Force
}
if (Test-Path -LiteralPath $hashPath) {
    Remove-Item -LiteralPath $hashPath -Force
}
New-Item -ItemType Directory -Path $publishDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $cliPublishDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $launcherPublishDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $runtimePublishDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $trayPublishDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $updaterPublishDirectory -Force | Out-Null

if (-not $NoRestore) {
    Invoke-DotNet -Arguments @('restore', $cliProject, '--runtime', 'win-x64')
    Invoke-DotNet -Arguments @('restore', $launcherProject, '--runtime', 'win-x64')
    Invoke-DotNet -Arguments @('restore', $runtimeProject, '--runtime', 'win-x64')
    Invoke-DotNet -Arguments @('restore', $trayProject, '--runtime', 'win-x64')
    Invoke-DotNet -Arguments @('restore', $updaterProject, '--runtime', 'win-x64')
}
foreach ($project in @($launcherProject, $cliProject, $runtimeProject, $trayProject, $updaterProject)) {
    Invoke-DotNet -Arguments @(
        'clean',
        $project,
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--verbosity', 'quiet',
        '-p:BuildProjectReferences=false'
    )
}

# Build shared projects once in a fixed context. Rebuilding them transitively from
# different executable roots changes GeneratedRegex metadata even when the IL is
# identical, which makes independently produced packages differ.
Invoke-DotNet -Arguments @(
    'build',
    $coreProject,
    '--configuration', $Configuration,
    '--no-restore',
    '-t:Rebuild',
    '-p:ContinuousIntegrationBuild=true',
    '-p:DebugType=None',
    '-p:DebugSymbols=false'
)
Invoke-DotNet -Arguments @(
    'build',
    $windowsProject,
    '--configuration', $Configuration,
    '--no-restore',
    '-t:Rebuild',
    '-p:BuildProjectReferences=false',
    '-p:ContinuousIntegrationBuild=true',
    '-p:DebugType=None',
    '-p:DebugSymbols=false'
)
# Launcher is a compile-time dependency of the CLI adapter layer, so build it
# first while keeping shared project rebuilds deterministic.
foreach ($project in @($launcherProject, $cliProject, $runtimeProject, $trayProject, $updaterProject)) {
    Invoke-DotNet -Arguments @(
        'build',
        $project,
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '--no-restore',
        '-t:Rebuild',
        '-p:BuildProjectReferences=false',
        '-p:ContinuousIntegrationBuild=true',
        '-p:DebugType=None',
        '-p:DebugSymbols=false'
    )
}

Invoke-DotNet -Arguments @(
    'publish',
    $cliProject,
    '--configuration', $Configuration,
    '--runtime', 'win-x64',
    '--self-contained', 'true',
    '--no-restore',
    '--no-build',
    '--output', $cliPublishDirectory,
    '-p:PublishTrimmed=false',
    '-p:PublishSingleFile=false',
    '-p:PublishReadyToRun=false',
    '-p:DebugType=None',
    '-p:DebugSymbols=false',
    '-p:ContinuousIntegrationBuild=true'
)
Invoke-DotNet -Arguments @(
    'publish',
    $launcherProject,
    '--configuration', $Configuration,
    '--runtime', 'win-x64',
    '--self-contained', 'true',
    '--no-restore',
    '--no-build',
    '--output', $launcherPublishDirectory,
    '-p:PublishTrimmed=false',
    '-p:PublishSingleFile=false',
    '-p:PublishReadyToRun=false',
    '-p:DebugType=None',
    '-p:DebugSymbols=false',
    '-p:ContinuousIntegrationBuild=true'
)
Invoke-DotNet -Arguments @(
    'publish',
    $runtimeProject,
    '--configuration', $Configuration,
    '--runtime', 'win-x64',
    '--self-contained', 'true',
    '--no-restore',
    '--no-build',
    '--output', $runtimePublishDirectory,
    '-p:PublishTrimmed=false',
    '-p:PublishSingleFile=false',
    '-p:PublishReadyToRun=false',
    '-p:DebugType=None',
    '-p:DebugSymbols=false',
    '-p:ContinuousIntegrationBuild=true'
)
Invoke-DotNet -Arguments @(
    'publish',
    $trayProject,
    '--configuration', $Configuration,
    '--runtime', 'win-x64',
    '--self-contained', 'true',
    '--no-restore',
    '--no-build',
    '--output', $trayPublishDirectory,
    '-p:PublishTrimmed=false',
    '-p:PublishSingleFile=false',
    '-p:PublishReadyToRun=false',
    '-p:DebugType=None',
    '-p:DebugSymbols=false',
    '-p:ContinuousIntegrationBuild=true'
)
Invoke-DotNet -Arguments @(
    'publish',
    $updaterProject,
    '--configuration', $Configuration,
    '--runtime', 'win-x64',
    '--self-contained', 'true',
    '--no-restore',
    '--no-build',
    '--output', $updaterPublishDirectory,
    '-p:PublishTrimmed=false',
    '-p:PublishSingleFile=false',
    '-p:PublishReadyToRun=false',
    '-p:DebugType=None',
    '-p:DebugSymbols=false',
    '-p:ContinuousIntegrationBuild=true'
)

Merge-PublishDirectory -SourceDirectory $cliPublishDirectory -DestinationDirectory $publishDirectory
Merge-PublishDirectory -SourceDirectory $launcherPublishDirectory -DestinationDirectory $publishDirectory
Merge-PublishDirectory -SourceDirectory $runtimePublishDirectory -DestinationDirectory $publishDirectory
$packagedTrayDirectory = Join-Path $publishDirectory 'tray'
New-Item -ItemType Directory -Path $packagedTrayDirectory -Force | Out-Null
Merge-PublishDirectory -SourceDirectory $trayPublishDirectory -DestinationDirectory $packagedTrayDirectory
$packagedUpdaterDirectory = Join-Path $publishDirectory 'updater'
New-Item -ItemType Directory -Path $packagedUpdaterDirectory -Force | Out-Null
Merge-PublishDirectory -SourceDirectory $updaterPublishDirectory -DestinationDirectory $packagedUpdaterDirectory
Remove-Item -LiteralPath $isolatedPublishRoot -Recurse -Force

& (Join-Path $PSScriptRoot 'verify-m3b-runtime.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "M3b private runtime verification failed with exit code $LASTEXITCODE."
}

$privatePythonSource = Join-Path $privateRuntimeAssembly 'runtime\python'
$privateLicensesSource = Join-Path $privateRuntimeAssembly 'THIRD-PARTY-LICENSES'
$privatePythonDestination = Join-Path $publishDirectory 'runtime\python'
$privateLicensesDestination = Join-Path $publishDirectory 'THIRD-PARTY-LICENSES'
$manifestsDestination = Join-Path $publishDirectory 'manifests'
Copy-FileTree -SourceDirectory $privatePythonSource -DestinationDirectory $privatePythonDestination
Copy-FileTree -SourceDirectory $privateLicensesSource -DestinationDirectory $privateLicensesDestination
New-Item -ItemType Directory -Path $manifestsDestination -Force | Out-Null
Copy-Item -LiteralPath $privateRuntimeLock -Destination (Join-Path $manifestsDestination 'm3b-text-runtime.lock.json')
Copy-Item -LiteralPath (Join-Path $privateRuntimeAssembly 'assembly-receipt.json') `
    -Destination (Join-Path $manifestsDestination 'assembly-receipt.json')
Copy-Item -LiteralPath (Join-Path $privateRuntimeAssembly 'runtime-environment.json') `
    -Destination (Join-Path $manifestsDestination 'runtime-environment.json')
Write-PrivateRuntimeComponents `
    -LockPath $privateRuntimeLock `
    -DestinationPath (Join-Path $publishDirectory 'PRIVATE-RUNTIME-COMPONENTS.json')

$dotnetRoot = Split-Path -Parent (Get-Command dotnet -ErrorAction Stop).Source
$dotnetLicense = Join-Path $dotnetRoot 'LICENSE.txt'
$dotnetNotices = Join-Path $dotnetRoot 'ThirdPartyNotices.txt'
if (-not (Test-Path -LiteralPath $dotnetLicense) -or -not (Test-Path -LiteralPath $dotnetNotices)) {
    throw 'The installed .NET distribution does not expose LICENSE.txt and ThirdPartyNotices.txt.'
}

Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') `
    -Destination (Join-Path $publishDirectory 'LOCAL-AI-GATEWAY-LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'THIRD-PARTY-NOTICES.md') `
    -Destination (Join-Path $publishDirectory 'THIRD-PARTY-NOTICES.md')
Copy-Item -LiteralPath $dotnetLicense `
    -Destination (Join-Path $publishDirectory 'DOTNET-LICENSE.txt')
Copy-Item -LiteralPath $dotnetNotices `
    -Destination (Join-Path $publishDirectory 'DOTNET-THIRD-PARTY-NOTICES.txt')

$unsignedMarker = @'
UNSIGNED DEVELOPMENT BUILD

This package is for development and verification only.
It has not been signed with the Local AI Gateway Ed25519 release key.
'@
Set-Content -LiteralPath (Join-Path $publishDirectory 'UNSIGNED-DEVELOPMENT-BUILD.txt') `
    -Value $unsignedMarker `
    -Encoding utf8NoBOM `
    -NoNewline

Set-Content -LiteralPath (Join-Path $publishDirectory 'TRUSTED-UPDATE-KEYS.json') `
    -Value '{"schemaVersion":1,"keys":[]}' `
    -Encoding utf8NoBOM `
    -NoNewline

& (Join-Path $PSScriptRoot 'scan-sensitive-data.ps1') `
    -Paths @($publishDirectory) `
    -CanaryValues $CanaryValues `
    -AllowedPatternFindingSha256 $privateRuntimeSensitiveScanAllowlist

$forbiddenRuntimeContent = @(
    Get-ChildItem -LiteralPath $publishDirectory -Recurse -Force |
        Where-Object {
            $_.Name -eq 'runtime-state' -or
            $_.Name -eq '__pycache__' -or
            $_.Extension -eq '.pyc'
        }
)
if ($forbiddenRuntimeContent.Count -ne 0) {
    throw "The package contains forbidden runtime state: $($forbiddenRuntimeContent.FullName -join ', ')"
}

$packageManifestPath = Join-Path $publishDirectory $packageManifestName
Write-PackageManifest -PackageRoot $publishDirectory -DestinationPath $packageManifestPath
$manifestHash = (Get-FileHash -LiteralPath $packageManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$signatureDocument = '{"schemaVersion":1,"algorithm":"none","keyId":null,"manifestSha256":"' + `
    $manifestHash + '","signature":null}'
Set-Content -LiteralPath (Join-Path $publishDirectory $packageSignatureName) `
    -Value $signatureDocument `
    -Encoding utf8NoBOM `
    -NoNewline

New-DeterministicZip -SourceDirectory $publishDirectory -DestinationPath $packagePath
$hash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $hashPath -Value "$hash  $packageName" -Encoding ascii -NoNewline

if ($CleanWorkingDirectories) {
    Remove-Item -LiteralPath $publishDirectory -Recurse -Force
    foreach ($emptyWorkingParent in @(
        (Split-Path -Parent $publishDirectory),
        (Split-Path -Parent $isolatedPublishRoot)
    )) {
        if ((Test-Path -LiteralPath $emptyWorkingParent) -and
            @(Get-ChildItem -LiteralPath $emptyWorkingParent -Force).Count -eq 0) {
            Remove-Item -LiteralPath $emptyWorkingParent -Force
        }
    }
}

Write-Output "Package: $packagePath"
Write-Output "SHA-256: $hash"

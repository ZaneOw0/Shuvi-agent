[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [switch] $SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$firstArtifacts = Join-Path $repositoryRoot 'artifacts\repro-1'
$secondArtifacts = Join-Path $repositoryRoot 'artifacts\repro-2'
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "LocalAIGateway-M0-$([Guid]::NewGuid().ToString('N'))"
$canary = "AIGW-CANARY-$([Guid]::NewGuid().ToString('N'))"

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build.ps1') -Configuration $Configuration
}

& (Join-Path $PSScriptRoot 'package.ps1') `
    -Configuration $Configuration `
    -ArtifactsDirectory $firstArtifacts `
    -CanaryValues @($canary)
& (Join-Path $PSScriptRoot 'package.ps1') `
    -Configuration $Configuration `
    -ArtifactsDirectory $secondArtifacts `
    -CanaryValues @($canary)

$firstPackage = @(Get-ChildItem -LiteralPath $firstArtifacts -Filter '*.zip' -File -ErrorAction Stop)
$secondPackage = @(Get-ChildItem -LiteralPath $secondArtifacts -Filter '*.zip' -File -ErrorAction Stop)
if ($firstPackage.Count -ne 1 -or $secondPackage.Count -ne 1) {
    throw 'Expected exactly one ZIP in each reproducibility output directory.'
}

$firstHash = (Get-FileHash -LiteralPath $firstPackage.FullName -Algorithm SHA256).Hash
$secondHash = (Get-FileHash -LiteralPath $secondPackage.FullName -Algorithm SHA256).Hash
if (-not $firstHash.Equals($secondHash, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Package reproducibility check failed: $firstHash != $secondHash"
}

try {
    New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
    Expand-Archive -LiteralPath $firstPackage.FullName -DestinationPath $temporaryDirectory

    $cliExecutable = Join-Path $temporaryDirectory 'aigw.exe'
    $runtimeExecutable = Join-Path $temporaryDirectory 'aigw-runtime.exe'
    $trayExecutable = Join-Path $temporaryDirectory 'tray\aigw-tray.exe'
    $requiredPackageFiles = @(
        'aigw.exe',
        'aigw-runtime.exe',
        'tray\aigw-tray.exe',
        'runtime-tools\aigw_backup_crypto.py',
        'runtime-tools\aigw_usage_query.py',
        'coreclr.dll',
        'hostfxr.dll',
        'LOCAL-AI-GATEWAY-LICENSE.txt',
        'THIRD-PARTY-NOTICES.md',
        'DOTNET-LICENSE.txt',
        'DOTNET-THIRD-PARTY-NOTICES.txt',
        'UNSIGNED-DEVELOPMENT-BUILD.txt'
    )
    foreach ($requiredPackageFile in $requiredPackageFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $temporaryDirectory $requiredPackageFile))) {
            throw "The package does not contain required file '$requiredPackageFile' at its root."
        }
    }

    $unexpectedScripts = @(Get-ChildItem -LiteralPath $temporaryDirectory -Recurse -File -Include '*.ps1', '*.cmd', '*.bat')
    if ($unexpectedScripts.Count -ne 0) {
        throw 'The runtime package unexpectedly contains a PowerShell or command script.'
    }

    $unsignedMarker = Get-Content -LiteralPath (Join-Path $temporaryDirectory 'UNSIGNED-DEVELOPMENT-BUILD.txt') -Raw
    if ($unsignedMarker -notmatch '^UNSIGNED DEVELOPMENT BUILD') {
        throw 'The package is not explicitly marked as an unsigned development build.'
    }

    $priorDotnetRoot = $env:DOTNET_ROOT
    $priorMultilevelLookup = $env:DOTNET_MULTILEVEL_LOOKUP
    try {
        $env:DOTNET_ROOT = Join-Path $temporaryDirectory 'nonexistent-dotnet-root'
        $env:DOTNET_MULTILEVEL_LOOKUP = '0'

        $versionOutput = & $cliExecutable --version
        if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '^Local AI Gateway 0\.1\.0-dev') {
            throw 'Extracted aigw.exe failed the human-readable version smoke test.'
        }

        $jsonOutput = & $cliExecutable --json --version | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or
            -not $jsonOutput.ok -or
            $jsonOutput.schemaVersion -ne 1 -or
            $jsonOutput.command -ne 'version') {
            throw 'Extracted aigw.exe failed the JSON version smoke test.'
        }

        $runtimeVersionOutput = & $runtimeExecutable --version
        if ($LASTEXITCODE -ne 0 -or $runtimeVersionOutput -notmatch '^Local AI Gateway Runtime 0\.1\.0-dev') {
            throw 'Extracted aigw-runtime.exe failed the human-readable version smoke test.'
        }

        $trayProcess = Start-Process `
            -FilePath $trayExecutable `
            -ArgumentList '--version' `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        if ($trayProcess.ExitCode -ne 0) {
            throw 'Extracted aigw-tray.exe failed the version smoke test.'
        }
    }
    finally {
        $env:DOTNET_ROOT = $priorDotnetRoot
        $env:DOTNET_MULTILEVEL_LOOKUP = $priorMultilevelLookup
    }

    & (Join-Path $PSScriptRoot 'scan-sensitive-data.ps1') `
        -Paths @($temporaryDirectory) `
        -CanaryValues @($canary)
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        $resolvedTemporaryDirectory = [System.IO.Path]::GetFullPath($temporaryDirectory)
        $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolvedTemporaryDirectory.StartsWith($temporaryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a directory outside the temporary root: $resolvedTemporaryDirectory"
        }
        Remove-Item -LiteralPath $resolvedTemporaryDirectory -Recurse -Force
    }
}

Write-Output "Deterministic package verification passed: $firstHash"

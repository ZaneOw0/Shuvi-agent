[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$outputRoot = Join-Path $artifactsRoot 'm3f-package-output'
$acceptanceRoot = Join-Path $artifactsRoot 'm3f-install-acceptance'
$firstRoot = Join-Path $acceptanceRoot 'repro-1'
$secondRoot = Join-Path $acceptanceRoot 'repro-2'
$extractedRoot = Join-Path $acceptanceRoot 'extracted package with spaces'
$installRoot = Join-Path $acceptanceRoot 'installed package with spaces'
$runtimeTestRoot = Join-Path $acceptanceRoot 'runtime acceptance state'
$pythonStateRoot = Join-Path $acceptanceRoot 'python smoke state'
$packageName = 'LocalAIGateway-0.1.0-dev-win-x64-unsigned.zip'
$windowsTests = Join-Path $repositoryRoot 'tests\LocalAIGateway.Windows.Tests\LocalAIGateway.Windows.Tests.csproj'
$solution = Join-Path $repositoryRoot 'LocalAIGateway.slnx'
$acceptanceOwned = $false
$outputOwned = $false
$completed = $false

function Invoke-DotNet {
    param([Parameter(Mandatory)][string[]] $Arguments)

    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Invoke-InstallerAction {
    param([Parameter(Mandatory)][ValidateSet('install', 'uninstall')][string] $Action)

    $priorPackageRoot = $env:AIGW_M3F_PACKAGE_ROOT
    $priorInstallRoot = $env:AIGW_M3F_INSTALL_ROOT
    $priorAction = $env:AIGW_M3F_INSTALL_ACTION
    try {
        $env:AIGW_M3F_PACKAGE_ROOT = $extractedRoot
        $env:AIGW_M3F_INSTALL_ROOT = $installRoot
        $env:AIGW_M3F_INSTALL_ACTION = $Action
        Invoke-DotNet -Arguments @(
            'test', $windowsTests,
            '--configuration', $Configuration,
            '--no-build',
            '--filter', 'FullyQualifiedName~M3fPackageInstallerIntegrationTests'
        )
    }
    finally {
        $env:AIGW_M3F_PACKAGE_ROOT = $priorPackageRoot
        $env:AIGW_M3F_INSTALL_ROOT = $priorInstallRoot
        $env:AIGW_M3F_INSTALL_ACTION = $priorAction
    }
}

function Invoke-PrivatePythonSmoke {
    param([Parameter(Mandatory)][string] $ApplicationRoot)

    New-Item -ItemType Directory -Path $pythonStateRoot -Force | Out-Null
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $ApplicationRoot 'runtime\python\python.exe'
    $startInfo.WorkingDirectory = $ApplicationRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['PYTHONNOUSERSITE'] = '1'
    $startInfo.Environment['PYTHONDONTWRITEBYTECODE'] = '1'
    $startInfo.Environment['PYTHONUTF8'] = '1'
    $startInfo.Environment['DO_NOT_TRACK'] = 'true'
    $startInfo.Environment['LITELLM_LOCAL_MODEL_COST_MAP'] = 'True'
    $startInfo.Environment['NO_PROXY'] = '127.0.0.1,localhost'
    foreach ($name in @('TEMP', 'TMP', 'HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'XDG_CACHE_HOME', 'HF_HOME', 'HUGGINGFACE_HUB_CACHE', 'TRANSFORMERS_CACHE', 'TORCH_HOME', 'PIP_CACHE_DIR', 'UV_CACHE_DIR')) {
        $path = Join-Path $pythonStateRoot $name.ToLowerInvariant()
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $startInfo.Environment[$name] = $path
    }
    $startInfo.ArgumentList.Add('-B')
    $startInfo.ArgumentList.Add('-I')
    $startInfo.ArgumentList.Add('-c')
    $startInfo.ArgumentList.Add('import json,sys; import litellm; from litellm import run_server; print(json.dumps({"python":sys.version.split()[0],"run_server":callable(run_server)}))')

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start packaged private Python.'
    }
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(120000)) {
        $process.Kill($true)
        throw 'Packaged private Python import smoke test timed out.'
    }
    $output = $outputTask.GetAwaiter().GetResult()
    $errorOutput = $errorTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        throw "Packaged private Python import smoke failed: $errorOutput"
    }
    $result = $output.Trim() | ConvertFrom-Json
    if ($result.python -ne '3.14.5' -or -not $result.run_server) {
        throw "Packaged private Python returned an unexpected result: $output"
    }
}

function Test-PackageManifest {
    param([Parameter(Mandatory)][string] $PackageRoot)

    $manifestPath = Join-Path $PackageRoot 'PACKAGE-MANIFEST.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or
        $manifest.packageId -ne 'LocalAIGateway' -or
        $manifest.version -ne '0.1.0-dev' -or
        $manifest.runtimeIdentifier -ne 'win-x64' -or
        -not $manifest.unsigned) {
        throw 'PACKAGE-MANIFEST.json has an invalid package identity.'
    }

    $declared = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.files)) {
        $relativePath = [string]$entry.path
        $segments = @($relativePath.Split('/'))
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            $relativePath.Contains('\') -or
            [System.IO.Path]::IsPathFullyQualified($relativePath) -or
            $segments -contains '..' -or
            $relativePath.Equals('PACKAGE-MANIFEST.json', [System.StringComparison]::OrdinalIgnoreCase) -or
            $relativePath.Equals('PACKAGE-SIGNATURE.json', [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $declared.Add($relativePath)) {
            throw "PACKAGE-MANIFEST.json contains an unsafe or duplicate path: $relativePath"
        }
        $fullPath = Join-Path $PackageRoot $relativePath.Replace('/', '\')
        $file = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($file.Length -ne [long]$entry.size -or $hash -ne [string]$entry.sha256) {
            throw "Package manifest verification failed for: $relativePath"
        }
    }

    $actualFiles = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Force |
            ForEach-Object { [System.IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace('\', '/') }
    )
    $signaturePath = Join-Path $PackageRoot 'PACKAGE-SIGNATURE.json'
    $signature = Get-Content -LiteralPath $signaturePath -Raw | ConvertFrom-Json
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($signature.schemaVersion -ne 1 -or $signature.algorithm -ne 'none' -or
        $null -ne $signature.keyId -or $null -ne $signature.signature -or
        $signature.manifestSha256 -ne $manifestHash) {
        throw 'PACKAGE-SIGNATURE.json does not bind the unsigned development manifest.'
    }
    if ($actualFiles.Count -ne ($declared.Count + 2)) {
        throw 'The extracted package file count does not match PACKAGE-MANIFEST.json.'
    }
    foreach ($actualFile in $actualFiles) {
        if (-not $actualFile.Equals('PACKAGE-MANIFEST.json', [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $actualFile.Equals('PACKAGE-SIGNATURE.json', [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $declared.Contains($actualFile)) {
            throw "The extracted package contains an undeclared file: $actualFile"
        }
    }

    return $manifest
}

if (Test-Path -LiteralPath $outputRoot) {
    throw "The exact M3f output root already exists; refusing to overwrite or delete it: $outputRoot"
}
if (Test-Path -LiteralPath $acceptanceRoot) {
    throw "The exact M3f acceptance root already exists; refusing to overwrite or delete it: $acceptanceRoot"
}

try {
    New-Item -ItemType Directory -Path $acceptanceRoot | Out-Null
    $acceptanceOwned = $true

    Invoke-DotNet -Arguments @('build', $solution, '--configuration', $Configuration, '--no-restore')
    & (Join-Path $PSScriptRoot 'package.ps1') `
        -Configuration $Configuration `
        -ArtifactsDirectory $firstRoot `
        -NoRestore `
        -RefuseExistingArtifacts `
        -CleanWorkingDirectories
    & (Join-Path $PSScriptRoot 'package.ps1') `
        -Configuration $Configuration `
        -ArtifactsDirectory $secondRoot `
        -NoRestore `
        -RefuseExistingArtifacts `
        -CleanWorkingDirectories

    $firstPackage = Join-Path $firstRoot $packageName
    $secondPackage = Join-Path $secondRoot $packageName
    $firstHash = (Get-FileHash -LiteralPath $firstPackage -Algorithm SHA256).Hash.ToLowerInvariant()
    $secondHash = (Get-FileHash -LiteralPath $secondPackage -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($firstHash -ne $secondHash) {
        throw "Full package reproducibility failed: $firstHash != $secondHash"
    }
    $expectedHashFile = "$firstHash  $packageName"
    if ((Get-Content -LiteralPath "$firstPackage.sha256" -Raw) -ne $expectedHashFile -or
        (Get-Content -LiteralPath "$secondPackage.sha256" -Raw) -ne $expectedHashFile) {
        throw 'A package SHA-256 sidecar does not match its ZIP.'
    }

    Expand-Archive -LiteralPath $firstPackage -DestinationPath $extractedRoot
    $manifest = Test-PackageManifest -PackageRoot $extractedRoot
    $requiredFiles = @(
        'aigw.exe',
        'aigw-launcher.exe',
        'aigw-runtime.exe',
        'tray\aigw-tray.exe',
        'runtime-tools\aigw_backup_crypto.py',
        'runtime-tools\aigw_usage_query.py',
        'runtime\python\python.exe',
        'runtime\python\Lib\site-packages\litellm\__init__.py',
        'manifests\m3b-text-runtime.lock.json',
        'manifests\assembly-receipt.json',
        'manifests\runtime-environment.json',
        'PRIVATE-RUNTIME-COMPONENTS.json',
        'THIRD-PARTY-LICENSES\tokenizers-0.23.1-LICENSE.txt',
        'LOCAL-AI-GATEWAY-LICENSE.txt',
        'THIRD-PARTY-NOTICES.md',
        'DOTNET-LICENSE.txt',
        'DOTNET-THIRD-PARTY-NOTICES.txt',
        'UNSIGNED-DEVELOPMENT-BUILD.txt'
    )
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $extractedRoot $requiredFile) -PathType Leaf)) {
            throw "The full package is missing required file: $requiredFile"
        }
    }
    $forbidden = @(
        Get-ChildItem -LiteralPath $extractedRoot -Recurse -Force |
            Where-Object {
                $_.Name -eq 'runtime-state' -or
                $_.Name -eq '__pycache__' -or
                $_.Extension -in @('.pyc', '.ps1', '.cmd', '.bat')
            }
    )
    if ($forbidden.Count -ne 0) {
        throw "The full package contains forbidden content: $($forbidden.FullName -join ', ')"
    }
    $components = Get-Content -LiteralPath (Join-Path $extractedRoot 'PRIVATE-RUNTIME-COMPONENTS.json') -Raw | ConvertFrom-Json
    if (@($components.wheels).Count -ne 87 -or @($components.runtimeData).Count -ne 1) {
        throw 'PRIVATE-RUNTIME-COMPONENTS.json has unexpected component counts.'
    }

    $priorDotnetRoot = $env:DOTNET_ROOT
    $priorMultilevelLookup = $env:DOTNET_MULTILEVEL_LOOKUP
    try {
        $env:DOTNET_ROOT = Join-Path $acceptanceRoot 'nonexistent-dotnet-root'
        $env:DOTNET_MULTILEVEL_LOOKUP = '0'
        $cliVersion = & (Join-Path $extractedRoot 'aigw.exe') --version
        if ($LASTEXITCODE -ne 0 -or $cliVersion -notmatch '^Local AI Gateway 0\.1\.0-dev') {
            throw 'Packaged aigw.exe version smoke failed without a global .NET runtime.'
        }
        $runtimeVersion = & (Join-Path $extractedRoot 'aigw-runtime.exe') --version
        if ($LASTEXITCODE -ne 0 -or $runtimeVersion -notmatch '^Local AI Gateway Runtime 0\.1\.0-dev') {
            throw 'Packaged aigw-runtime.exe version smoke failed without a global .NET runtime.'
        }
        $launcherError = & (Join-Path $extractedRoot 'aigw-launcher.exe') 2>&1
        if ($LASTEXITCODE -ne 12 -or $launcherError -ne 'aigw_launcher_arguments_invalid') {
            throw 'Packaged aigw-launcher.exe smoke failed without a global .NET runtime.'
        }
        $trayProcess = Start-Process `
            -FilePath (Join-Path $extractedRoot 'tray\aigw-tray.exe') `
            -ArgumentList '--version' `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        if ($trayProcess.ExitCode -ne 0) {
            throw 'Packaged aigw-tray.exe smoke failed without a global .NET runtime.'
        }
    }
    finally {
        $env:DOTNET_ROOT = $priorDotnetRoot
        $env:DOTNET_MULTILEVEL_LOOKUP = $priorMultilevelLookup
    }

    Invoke-PrivatePythonSmoke -ApplicationRoot $extractedRoot
    Remove-Item -LiteralPath $pythonStateRoot -Recurse -Force
    Invoke-InstallerAction -Action install
    & (Join-Path $PSScriptRoot 'test-m3e-runtime.ps1') `
        -ApplicationRoot $installRoot `
        -TestRoot $runtimeTestRoot
    Invoke-InstallerAction -Action uninstall
    if (Test-Path -LiteralPath $installRoot) {
        throw 'The isolated M3f installation remains after verified uninstall.'
    }
    if (@(Get-ChildItem -LiteralPath $acceptanceRoot -Directory -Filter '*.installing-*').Count -ne 0) {
        throw 'An M3f installer staging directory remains after acceptance.'
    }

    New-Item -ItemType Directory -Path $outputRoot | Out-Null
    $outputOwned = $true
    Copy-Item -LiteralPath $firstPackage -Destination (Join-Path $outputRoot $packageName)
    Copy-Item -LiteralPath "$firstPackage.sha256" -Destination (Join-Path $outputRoot "$packageName.sha256")
    $completed = $true
    Write-Host "M3f full package acceptance passed: $firstHash"
    Write-Host "Manifest entries: $(@($manifest.files).Count)"
    Write-Host "Final package: $(Join-Path $outputRoot $packageName)"
}
finally {
    if ($acceptanceOwned -and (Test-Path -LiteralPath $acceptanceRoot)) {
        Remove-Item -LiteralPath $acceptanceRoot -Recurse -Force
    }
    if ($outputOwned -and -not $completed -and (Test-Path -LiteralPath $outputRoot)) {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force
    }
}

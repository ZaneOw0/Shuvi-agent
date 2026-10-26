[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$testRoot = Join-Path $artifactsRoot "m5d-update-check-$([Guid]::NewGuid().ToString('N'))"
$packageOutput = Join-Path $testRoot 'package-output'
$extractedRoot = Join-Path $testRoot 'extracted package'
$candidateRoot = Join-Path $testRoot 'candidate package'
$rollbackCandidateRoot = Join-Path $testRoot 'rollback candidate package'
$isolatedLocalAppData = Join-Path $testRoot 'local-app-data'
$installRoot = Join-Path $isolatedLocalAppData 'Programs\LocalAIGateway'
$programsRoot = Split-Path -Parent $installRoot
$pythonPath = Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly\runtime\python\python.exe'
$verifyScript = Join-Path $repositoryRoot 'src\LocalAIGateway.Windows\Update\Assets\aigw_update_verify.py'
$artifactPrefix = [System.IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$testFull = [System.IO.Path]::GetFullPath($testRoot)

if (-not $testFull.StartsWith($artifactPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe M5d test root: $testFull"
}

function Invoke-DotNet {
    param([Parameter(Mandatory)][string[]] $Arguments)

    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Copy-ExactTree {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $entry.FullName -Destination $Destination -Recurse
    }
}

function Set-CandidateVersion {
    param(
        [Parameter(Mandatory)][string] $PackageRoot,
        [Parameter(Mandatory)][string] $Version
    )

    $manifestPath = Join-Path $PackageRoot 'PACKAGE-MANIFEST.json'
    $signaturePath = Join-Path $PackageRoot 'PACKAGE-SIGNATURE.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $stream = [System.IO.File]::Open(
        $manifestPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
    try {
        $writer = [System.Text.Json.Utf8JsonWriter]::new($stream)
        try {
            $writer.WriteStartObject()
            $writer.WriteNumber('schemaVersion', [int]$manifest.schemaVersion)
            $writer.WriteString('packageId', [string]$manifest.packageId)
            $writer.WriteString('version', $Version)
            $writer.WriteString('runtimeIdentifier', [string]$manifest.runtimeIdentifier)
            $writer.WriteBoolean('unsigned', [bool]$manifest.unsigned)
            $writer.WriteStartArray('files')
            foreach ($file in @($manifest.files)) {
                $writer.WriteStartObject()
                $writer.WriteString('path', [string]$file.path)
                $writer.WriteNumber('size', [long]$file.size)
                $writer.WriteString('sha256', [string]$file.sha256)
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

    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $signature = '{"schemaVersion":1,"algorithm":"none","keyId":null,"manifestSha256":"' + `
        $manifestHash + '","signature":null}'
    Set-Content -LiteralPath $signaturePath -Value $signature -Encoding utf8NoBOM -NoNewline
}

function Invoke-CliJson {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $output = & $Executable --json @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "CLI command failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

$priorPython = $env:AIGW_M5D_PYTHON_PATH
$priorScript = $env:AIGW_M5D_VERIFY_SCRIPT_PATH
$priorLocalAppData = $env:LOCALAPPDATA
$priorDotnetRoot = $env:DOTNET_ROOT
$priorMultilevelLookup = $env:DOTNET_MULTILEVEL_LOOKUP
try {
    foreach ($required in @($pythonPath, $verifyScript)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required M5d component is missing: $required"
        }
    }
    New-Item -ItemType Directory -Path $testFull -Force | Out-Null
    $env:AIGW_M5D_PYTHON_PATH = $pythonPath
    $env:AIGW_M5D_VERIFY_SCRIPT_PATH = $verifyScript

    Invoke-DotNet -Arguments @(
        'test', (Join-Path $repositoryRoot 'tests\LocalAIGateway.Core.Tests\LocalAIGateway.Core.Tests.csproj'),
        '--configuration', $Configuration, '--no-restore',
        '--filter', 'FullyQualifiedName~PackageSignatureTests|FullyQualifiedName~PackageVersionComparerTests'
    )
    Invoke-DotNet -Arguments @(
        'test', (Join-Path $repositoryRoot 'tests\LocalAIGateway.Windows.Tests\LocalAIGateway.Windows.Tests.csproj'),
        '--configuration', $Configuration, '--no-restore',
        '--filter', 'FullyQualifiedName~PrivatePythonEd25519VerifierTests|FullyQualifiedName~WindowsPackageUpdateServiceTests|FullyQualifiedName~WindowsRestrictedProcessTests'
    )
    Invoke-DotNet -Arguments @(
        'test', (Join-Path $repositoryRoot 'tests\LocalAIGateway.Updater.Tests\LocalAIGateway.Updater.Tests.csproj'),
        '--configuration', $Configuration, '--no-restore'
    )
    Invoke-DotNet -Arguments @(
        'test', (Join-Path $repositoryRoot 'tests\LocalAIGateway.Cli.Tests\LocalAIGateway.Cli.Tests.csproj'),
        '--configuration', $Configuration, '--no-restore',
        '--filter', 'FullyQualifiedName~M5dUpdateCommandTests'
    )

    & (Join-Path $repositoryRoot 'scripts\package.ps1') `
        -Configuration $Configuration `
        -ArtifactsDirectory $packageOutput `
        -NoRestore `
        -RefuseExistingArtifacts `
        -CleanWorkingDirectories
    if ($LASTEXITCODE -ne 0) { throw "M5d package build failed with exit code $LASTEXITCODE." }

    $packages = @(Get-ChildItem -LiteralPath $packageOutput -File -Filter '*.zip')
    if ($packages.Count -ne 1) { throw "Expected exactly one M5d package, found $($packages.Count)." }
    $package = $packages[0]
    $sidecar = "$($package.FullName).sha256"
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) { throw 'The package SHA-256 sidecar is missing.' }
    $expectedZipHash = ((Get-Content -LiteralPath $sidecar -Raw) -split '\s+')[0]
    $actualZipHash = (Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $actualZipHash.Equals($expectedZipHash, [System.StringComparison]::Ordinal)) {
        throw 'The package SHA-256 sidecar does not match the generated ZIP.'
    }

    Expand-Archive -LiteralPath $package.FullName -DestinationPath $extractedRoot
    $manifestPath = Join-Path $extractedRoot 'PACKAGE-MANIFEST.json'
    $signaturePath = Join-Path $extractedRoot 'PACKAGE-SIGNATURE.json'
    $trustedKeysPath = Join-Path $extractedRoot 'TRUSTED-UPDATE-KEYS.json'
    foreach ($required in @($manifestPath, $signaturePath, $trustedKeysPath, (Join-Path $extractedRoot 'updater\aigw-updater.exe'))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Packaged M5d component is missing: $required" }
    }
    $signature = Get-Content -LiteralPath $signaturePath -Raw | ConvertFrom-Json
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($signature.algorithm -ne 'none' -or $signature.manifestSha256 -ne $manifestHash) {
        throw 'The unsigned-development signature descriptor does not bind the package manifest.'
    }
    $trustedKeys = Get-Content -LiteralPath $trustedKeysPath -Raw
    if ($trustedKeys -ne '{"schemaVersion":1,"keys":[]}') {
        throw 'The development package trusted-key store is not the expected canonical empty store.'
    }

    $env:DOTNET_ROOT = Join-Path $testFull 'missing-global-dotnet'
    $env:DOTNET_MULTILEVEL_LOOKUP = '0'
    $updaterExecutable = Join-Path $extractedRoot 'updater\aigw-updater.exe'
    $versionOutput = & $updaterExecutable --version
    if ($LASTEXITCODE -ne 0 -or ($versionOutput -join '') -notmatch '^Local AI Gateway Updater ') {
        throw 'The packaged self-contained updater executable smoke failed.'
    }

    Copy-ExactTree -Source $extractedRoot -Destination $installRoot
    Copy-ExactTree -Source $extractedRoot -Destination $candidateRoot
    Set-CandidateVersion -PackageRoot $candidateRoot -Version '0.1.1-dev'
    New-Item -ItemType Directory -Path $isolatedLocalAppData -Force | Out-Null
    $env:LOCALAPPDATA = $isolatedLocalAppData
    $installedCli = Join-Path $installRoot 'aigw.exe'
    $inspection = Invoke-CliJson -Executable $installedCli -Arguments @(
        'update', 'inspect', '--package', $candidateRoot, '--allow-unsigned-development')
    if ($inspection.data.version -ne '0.1.1-dev' -or
        $inspection.data.trustKind -ne 'unsigned-development' -or
        $inspection.data.applyPerformed) {
        throw 'The installed CLI returned an invalid update inspection.'
    }
    $applied = Invoke-CliJson -Executable $installedCli -Arguments @(
        'update', 'apply', '--package', $candidateRoot,
        '--expected-manifest-sha256', [string]$inspection.data.manifestSha256,
        '--confirm', 'UPDATE', '--allow-unsigned-development')
    if ($applied.data.previousVersion -ne '0.1.0-dev' -or
        $applied.data.candidateVersion -ne '0.1.1-dev' -or
        -not $applied.data.completionPending -or
        [string]::IsNullOrWhiteSpace([string]$applied.data.operationId) -or
        [string]::IsNullOrWhiteSpace([string]$applied.data.receiptPath)) {
        throw 'The installed CLI returned an invalid asynchronous update schedule.'
    }
    $expectedReceipt = Join-Path $isolatedLocalAppData "LocalAIGateway\update-receipts\$($applied.data.operationId).json"
    if (-not ([System.IO.Path]::GetFullPath([string]$applied.data.receiptPath)).Equals(
            [System.IO.Path]::GetFullPath($expectedReceipt),
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The update receipt path is outside the owned operation location.'
    }
    $receiptDeadline = [DateTime]::UtcNow.AddMinutes(5)
    while (-not (Test-Path -LiteralPath $expectedReceipt -PathType Leaf) -and [DateTime]::UtcNow -lt $receiptDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $expectedReceipt -PathType Leaf)) {
        throw 'The asynchronous update worker did not publish a receipt within five minutes.'
    }
    $receipt = Get-Content -LiteralPath $expectedReceipt -Raw | ConvertFrom-Json
    if ($receipt.schemaVersion -ne 1 -or
        $receipt.operationId -ne $applied.data.operationId -or
        $receipt.state -ne 'completed' -or
        -not $receipt.ok -or
        $receipt.result.previousVersion -ne '0.1.0-dev' -or
        $receipt.result.currentVersion -ne '0.1.1-dev' -or
        $receipt.result.rolledBack) {
        $receiptDiagnostic = $receipt | ConvertTo-Json -Compress -Depth 8
        throw "The asynchronous update worker returned an invalid completion receipt: $receiptDiagnostic"
    }
    $installedManifest = Get-Content -LiteralPath (Join-Path $installRoot 'PACKAGE-MANIFEST.json') -Raw | ConvertFrom-Json
    if ($installedManifest.version -ne '0.1.1-dev') { throw 'The candidate installation was not atomically published.' }

    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $transactionDirectories = @(Get-ChildItem -LiteralPath $programsRoot -Directory -Force | Where-Object {
            $_.Name -like 'LocalAIGateway.rollback-*' -or
            $_.Name -like 'LocalAIGateway.updating-*' -or
            $_.Name -like 'LocalAIGateway.failed-*'
        })
        if ($transactionDirectories.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $cleanupDeadline)
    if ($transactionDirectories.Count -ne 0) {
        throw "The deferred updater cleaner left transaction directories: $($transactionDirectories.FullName -join ', ')"
    }
    $workerRoot = Join-Path $isolatedLocalAppData "LocalAIGateway\update-workers\$($applied.data.operationId)"
    $workerDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((Test-Path -LiteralPath $workerRoot) -and [DateTime]::UtcNow -lt $workerDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path -LiteralPath $workerRoot) { throw "The external update worker was not cleaned: $workerRoot" }

    Copy-ExactTree -Source $extractedRoot -Destination $rollbackCandidateRoot
    Set-CandidateVersion -PackageRoot $rollbackCandidateRoot -Version '0.1.2-dev'
    $rollbackInspection = Invoke-CliJson -Executable $installedCli -Arguments @(
        'update', 'inspect', '--package', $rollbackCandidateRoot, '--allow-unsigned-development')
    if ($rollbackInspection.data.version -ne '0.1.2-dev') {
        throw 'The rollback candidate inspection returned an unexpected version.'
    }

    $rollbackFaultJob = Start-Job -ScriptBlock {
        param([string] $InstalledRoot)

        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        $manifestPath = Join-Path $InstalledRoot 'PACKAGE-MANIFEST.json'
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                    if ($manifest.version -eq '0.1.2-dev') {
                        $component = Join-Path $InstalledRoot 'updater\aigw-updater.exe'
                        Remove-Item -LiteralPath $component -Force
                        return 'injected'
                    }
                }
            }
            catch {
                if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                    Start-Sleep -Milliseconds 10
                    continue
                }
            }
            Start-Sleep -Milliseconds 10
        }
        throw 'Timed out waiting to inject the post-switch health failure.'
    } -ArgumentList $installRoot
    try {
        $rollbackScheduled = Invoke-CliJson -Executable $installedCli -Arguments @(
            'update', 'apply', '--package', $rollbackCandidateRoot,
            '--expected-manifest-sha256', [string]$rollbackInspection.data.manifestSha256,
            '--confirm', 'UPDATE', '--allow-unsigned-development')
        $rollbackReceiptPath = Join-Path $isolatedLocalAppData "LocalAIGateway\update-receipts\$($rollbackScheduled.data.operationId).json"
        $rollbackReceiptDeadline = [DateTime]::UtcNow.AddMinutes(5)
        while (-not (Test-Path -LiteralPath $rollbackReceiptPath -PathType Leaf) -and
            [DateTime]::UtcNow -lt $rollbackReceiptDeadline) {
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath $rollbackReceiptPath -PathType Leaf)) {
            throw 'The rollback update worker did not publish a receipt within five minutes.'
        }
        $rollbackReceipt = Get-Content -LiteralPath $rollbackReceiptPath -Raw | ConvertFrom-Json
        if ($rollbackReceipt.schemaVersion -ne 1 -or
            $rollbackReceipt.operationId -ne $rollbackScheduled.data.operationId -or
            $rollbackReceipt.state -ne 'completed' -or
            $rollbackReceipt.ok -or
            $rollbackReceipt.error.code -ne 'aigw_update_rolled_back') {
            $rollbackDiagnostic = $rollbackReceipt | ConvertTo-Json -Compress -Depth 8
            throw "The rollback worker returned an invalid failure receipt: $rollbackDiagnostic"
        }
        $faultResult = Receive-Job -Job $rollbackFaultJob -Wait
        if (($faultResult -join '') -ne 'injected') { throw 'The post-switch health fault was not injected.' }
    }
    finally {
        Stop-Job -Job $rollbackFaultJob -ErrorAction SilentlyContinue
        Remove-Job -Job $rollbackFaultJob -Force -ErrorAction SilentlyContinue
    }

    $restoredManifest = Get-Content -LiteralPath (Join-Path $installRoot 'PACKAGE-MANIFEST.json') -Raw | ConvertFrom-Json
    if ($restoredManifest.version -ne '0.1.1-dev') { throw 'The prior installation was not restored after health failure.' }
    $rollbackWorkerRoot = Join-Path $isolatedLocalAppData "LocalAIGateway\update-workers\$($rollbackScheduled.data.operationId)"
    $rollbackCleanupDeadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $rollbackTransactions = @(Get-ChildItem -LiteralPath $programsRoot -Directory -Force | Where-Object {
            $_.Name -like 'LocalAIGateway.rollback-*' -or
            $_.Name -like 'LocalAIGateway.updating-*' -or
            $_.Name -like 'LocalAIGateway.failed-*'
        })
        if ($rollbackTransactions.Count -eq 0 -and -not (Test-Path -LiteralPath $rollbackWorkerRoot)) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $rollbackCleanupDeadline)
    if ($rollbackTransactions.Count -ne 0) {
        throw "The rollback path left transaction directories: $($rollbackTransactions.FullName -join ', ')"
    }
    if (Test-Path -LiteralPath $rollbackWorkerRoot) { throw "The rollback worker was not cleaned: $rollbackWorkerRoot" }
}
finally {
    $env:AIGW_M5D_PYTHON_PATH = $priorPython
    $env:AIGW_M5D_VERIFY_SCRIPT_PATH = $priorScript
    $env:LOCALAPPDATA = $priorLocalAppData
    $env:DOTNET_ROOT = $priorDotnetRoot
    $env:DOTNET_MULTILEVEL_LOOKUP = $priorMultilevelLookup
    foreach ($process in @(Get-Process -Name 'aigw', 'aigw-updater', 'aigw-runtime', 'aigw-launcher', 'aigw-tray', 'python', 'pythonw' -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -and [System.IO.Path]::GetFullPath($process.Path).StartsWith(
                    $testFull + [System.IO.Path]::DirectorySeparatorChar,
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                $process.Kill($true)
                $process.WaitForExit()
            }
        }
        catch { }
        finally { $process.Dispose() }
    }
    if (Test-Path -LiteralPath $testFull) {
        $verified = [System.IO.Path]::GetFullPath($testFull)
        if (-not $verified.StartsWith($artifactPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean outside artifacts: $verified"
        }
        Remove-Item -LiteralPath $verified -Recurse -Force
    }
}

if (Test-Path -LiteralPath $testFull) { throw "M5d test root still exists: $testFull" }
Write-Output "M5d update acceptance passed: actual Ed25519 verifier, full-package validation, self-contained updater, atomic switch, automatic rollback, and zero test-root residue."

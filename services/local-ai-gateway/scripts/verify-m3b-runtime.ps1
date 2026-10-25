[CmdletBinding()]
param(
    [switch] $ImportSmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$assemblyRoot = Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly'
$downloadRoot = Join-Path $repositoryRoot 'artifacts\m3b-runtime-download'
$manifestPath = Join-Path $repositoryRoot 'runtime-manifests\m3b-text-runtime.lock.json'
$candidatePath = Join-Path $repositoryRoot 'runtime-manifests\m3b-proxy-without-enterprise.candidate.json'
$downloadVerificationPath = Join-Path $repositoryRoot 'runtime-manifests\m3b-download-verification.json'
$receiptPath = Join-Path $assemblyRoot 'assembly-receipt.json'
$expectedExcludedPackages = @(
    'azure-core', 'azure-identity', 'azure-storage-blob', 'croniter', 'granian',
    'gunicorn', 'hf-xet', 'inquirerpy', 'isodate', 'litellm-proxy-extras',
    'msal', 'msal-extensions', 'pfzy', 'polars', 'polars-runtime-32',
    'prompt-toolkit', 'restrictedpython', 'rq', 'soundfile', 'wcwidth'
)

if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    throw "The M3b assembly receipt does not exist: $receiptPath"
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($manifestHash -ne $receipt.sourceManifest.sha256) {
    throw 'The assembly receipt does not match the current source manifest.'
}
$candidateHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
$downloadVerificationHash = (Get-FileHash -LiteralPath $downloadVerificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($candidateHash -ne $manifest.source.candidateManifest.sha256 -or
    $downloadVerificationHash -ne $manifest.source.downloadVerification.sha256) {
    throw 'The final runtime lock provenance no longer matches its immutable inputs.'
}
if ($receipt.wheels.includedCount -ne [int]$manifest.summary.includedWheelCount -or
    $receipt.wheels.excludedCount -ne [int]$manifest.summary.excludedWheelCount) {
    throw "The assembly wheel counts are invalid: included=$($receipt.wheels.includedCount), excluded=$($receipt.wheels.excludedCount)"
}

$actualExcludedPackages = @(
    $receipt.wheels.excluded |
        ForEach-Object { ([string]$_.name).ToLowerInvariant() -replace '[_.]+', '-' } |
        Sort-Object
)
if (Compare-Object -ReferenceObject ($expectedExcludedPackages | Sort-Object) -DifferenceObject $actualExcludedPackages) {
    throw 'The assembly exclusion list does not match the validated text-only runtime boundary.'
}

$sourcePayloads = @($manifest.python) + @($manifest.wheels.included) + @($manifest.wheels.excluded) + @($manifest.runtimeData)
if ($sourcePayloads.Count -ne [int]$manifest.summary.sourceArtifactCount) {
    throw "The final runtime lock source count is invalid: $($sourcePayloads.Count)"
}
$expectedSourceNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($payload in $sourcePayloads) {
    if (-not $expectedSourceNames.Add([string]$payload.filename)) {
        throw "The final runtime lock contains a duplicate source filename: $($payload.filename)"
    }
    $sourcePath = Join-Path $downloadRoot $payload.filename
    $sourceFile = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
    if ($sourceFile.Length -ne [long]$payload.size) {
        throw "A verified source payload size changed after assembly: $($payload.filename)"
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $payload.sha256) {
        throw "A verified source payload changed after assembly: $($payload.filename)"
    }
}
$unexpectedSourceFiles = @(
    Get-ChildItem -LiteralPath $downloadRoot -File -Force |
        Where-Object { -not $expectedSourceNames.Contains($_.Name) }
)
if ($unexpectedSourceFiles.Count -ne 0) {
    throw "The locked download input contains unexpected files: $($unexpectedSourceFiles.Name -join ', ')"
}

$licensePath = Join-Path $assemblyRoot 'THIRD-PARTY-LICENSES\tokenizers-0.23.1-LICENSE.txt'
$licenseHash = (Get-FileHash -LiteralPath $licensePath -Algorithm SHA256).Hash.ToLowerInvariant()
$licenseSupplement = @($manifest.licenseSupplements)[0]
if ($licenseHash -ne $licenseSupplement.sha256) {
    throw "The packaged tokenizers license hash is invalid: $licenseHash"
}

$runtimeData = @($manifest.runtimeData)[0]
$tiktokenDataPath = Join-Path $assemblyRoot ([string]$runtimeData.packagedPath).Replace('/', '\')
$tiktokenDataFile = Get-Item -LiteralPath $tiktokenDataPath -ErrorAction Stop
if ($tiktokenDataFile.Length -ne [long]$runtimeData.size) {
    throw "The packaged cl100k_base data size is invalid: $($tiktokenDataFile.Length)"
}
$tiktokenDataHash = (Get-FileHash -LiteralPath $tiktokenDataPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($tiktokenDataHash -ne $runtimeData.sha256) {
    throw "The packaged cl100k_base data hash is invalid: $tiktokenDataHash"
}

$forbiddenFiles = @(
    Get-ChildItem -LiteralPath $assemblyRoot -Recurse -File |
        Where-Object {
            $_.Name -match '^(soundfile\.py|_soundfile.*|libsndfile.*|.*\.pyc)$' -or
            $_.FullName -match '[\\/]__pycache__[\\/]' -or
            $_.FullName -match 'litellm[_-]enterprise'
        }
)
if ($forbiddenFiles.Count -ne 0) {
    throw "The assembly contains excluded code or cache files: $($forbiddenFiles.FullName -join ', ')"
}

$installedDistributionNames = @(
    Get-ChildItem -LiteralPath (Join-Path $assemblyRoot 'runtime\python\Lib\site-packages') -Directory -Filter '*.dist-info' |
        ForEach-Object {
            $metadataPath = Join-Path $_.FullName 'METADATA'
            $nameLine = Get-Content -LiteralPath $metadataPath -TotalCount 20 |
                Where-Object { $_ -match '^Name:\s*(.+)$' } |
                Select-Object -First 1
            if ($nameLine -match '^Name:\s*(.+)$') {
                $Matches[1].Trim().ToLowerInvariant() -replace '[_.]+', '-'
            }
        }
)
$unexpectedExcludedDistributions = @(
    $expectedExcludedPackages | Where-Object { $_ -in $installedDistributionNames }
)
if ($unexpectedExcludedDistributions.Count -ne 0) {
    throw "Excluded distributions remain installed: $($unexpectedExcludedDistributions -join ', ')"
}

$unexpectedStateFiles = @(Get-ChildItem -LiteralPath (Join-Path $assemblyRoot 'runtime-state') -Recurse -File)
if ($unexpectedStateFiles.Count -ne 0) {
    throw "Runtime state/cache is not clean before smoke testing: $($unexpectedStateFiles.FullName -join ', ')"
}

if ($ImportSmokeTest) {
    $python = Join-Path $assemblyRoot 'runtime\python\python.exe'
    $stateRoot = Join-Path $assemblyRoot 'runtime-state'
    $environment = Get-Content -Raw -LiteralPath (Join-Path $assemblyRoot 'runtime-environment.json') | ConvertFrom-Json -AsHashtable
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $python
    $startInfo.WorkingDirectory = $assemblyRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment.Clear()
    $startInfo.Environment['SystemRoot'] = [System.Environment]::GetFolderPath('Windows')
    foreach ($entry in $environment.GetEnumerator()) {
        $value = [string]$entry.Value
        if ($entry.Key -in @('TEMP', 'TMP', 'HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'XDG_CACHE_HOME', 'HF_HOME', 'HUGGINGFACE_HUB_CACHE', 'TRANSFORMERS_CACHE', 'TORCH_HOME', 'PIP_CACHE_DIR', 'UV_CACHE_DIR')) {
            $value = Join-Path $assemblyRoot $value
        }
        $startInfo.Environment[[string]$entry.Key] = $value
    }
    $startInfo.ArgumentList.Add('-B')
    $startInfo.ArgumentList.Add('-I')
    $startInfo.ArgumentList.Add('-c')
    $startInfo.ArgumentList.Add('import json,sys; import litellm; from litellm import run_server; print(json.dumps({"python":sys.version.split()[0],"litellm":getattr(litellm,"__version__",None),"run_server":callable(run_server)}))')

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start the private Python import smoke test.'
    }
    $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
    $standardErrorTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(60000)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw 'Private Python import smoke test exceeded 60 seconds and was terminated.'
    }
    $standardOutput = $standardOutputTask.Result
    $standardError = $standardErrorTask.Result
    if ($process.ExitCode -ne 0) {
        throw "Private Python import smoke test failed with exit code $($process.ExitCode).`n$standardError"
    }
    Write-Output $standardOutput.Trim()

    $generatedStateFiles = @(Get-ChildItem -LiteralPath $stateRoot -Recurse -File)
    if ($generatedStateFiles.Count -ne 0) {
        Write-Output "Contained runtime state files: $($generatedStateFiles.Count)"
        $generatedStateFiles | ForEach-Object { Write-Output $_.FullName }
    }
}

Write-Output 'M3b runtime assembly verification passed.'

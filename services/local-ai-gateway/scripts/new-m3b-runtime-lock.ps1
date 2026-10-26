[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$candidatePath = Join-Path $repositoryRoot 'runtime-manifests\m3b-proxy-without-enterprise.candidate.json'
$verificationPath = Join-Path $repositoryRoot 'runtime-manifests\m3b-download-verification.json'
$licensePath = Join-Path $repositoryRoot 'runtime-manifests\licenses\tokenizers-0.23.1-LICENSE.txt'
$downloadRoot = Join-Path $repositoryRoot 'artifacts\m3b-runtime-download'
$outputPath = Join-Path $repositoryRoot 'runtime-manifests\m3b-text-runtime.lock.json'

$expectedCandidateHash = '0bb5e21d4b8b20e5d2f0cc6df4a74362ce3c3a595fa49bfb1ee3e92d6c94e361'
$expectedVerificationHash = 'e47f93a9b7c05a36cdd897b1b52eccf39c1df7ddd957418a05d5df2b3f8539ed'
$expectedLicenseHash = 'c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4'
$tiktokenDataFilename = 'cl100k_base.tiktoken'
$expectedTiktokenDataSize = 1681126
$expectedTiktokenDataHash = '223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7'
$tiktokenCacheKey = '9b5ad71b2ce5302211f9c61530b329a4922fc6a4'

$excludedPackageReasons = [ordered]@{
    'azure-core' = 'Azure identity support is outside the API-key-only Azure v1 contract.'
    'azure-identity' = 'Azure identity support is outside the API-key-only Azure v1 contract.'
    'azure-storage-blob' = 'Proxy-managed Azure blob storage is outside the product boundary.'
    'croniter' = 'Proxy background job scheduling is outside the product boundary.'
    'granian' = 'The Windows runtime uses uvicorn; the alternate Granian server is not used.'
    'gunicorn' = 'The Unix Gunicorn server is not used by the Windows runtime.'
    'hf-xet' = 'Hugging Face Xet downloads are outside the offline runtime boundary.'
    'inquirerpy' = 'Interactive LiteLLM CLI prompts are not used.'
    'isodate' = 'Transitive dependency of excluded Azure SDK packages.'
    'litellm-proxy-extras' = 'Proxy database migrations and managed proxy features are outside the product boundary.'
    'msal' = 'Transitive dependency of excluded Azure identity support.'
    'msal-extensions' = 'Transitive dependency of excluded Azure identity support.'
    'pfzy' = 'Transitive dependency of the excluded interactive CLI.'
    'polars' = 'Proxy analytics data frames are outside the product boundary.'
    'polars-runtime-32' = 'Native runtime for the excluded Polars package.'
    'prompt-toolkit' = 'Transitive dependency of the excluded interactive CLI.'
    'restrictedpython' = 'Proxy code execution features are outside the product boundary.'
    'rq' = 'Proxy Redis background queues are outside the product boundary.'
    'soundfile' = 'Optional audio dependency excluded from the text-only runtime; bundled libsndfile is LGPL-2.1.'
    'wcwidth' = 'Transitive dependency of the excluded interactive CLI.'
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-File {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][long] $Size,
        [Parameter(Mandatory)][string] $Sha256
    )

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -ne $Size) {
        throw "File size mismatch for '$Path': expected $Size, found $($file.Length)."
    }
    $actualHash = Get-Sha256 -Path $Path
    if ($actualHash -ne $Sha256) {
        throw "File hash mismatch for '$Path': expected $Sha256, found $actualHash."
    }
}

if ((Get-Sha256 -Path $candidatePath) -ne $expectedCandidateHash) {
    throw 'The immutable candidate manifest hash changed.'
}
if ((Get-Sha256 -Path $verificationPath) -ne $expectedVerificationHash) {
    throw 'The immutable download verification receipt hash changed.'
}
Assert-File -Path $licensePath -Size 11357 -Sha256 $expectedLicenseHash

$candidate = Get-Content -Raw -LiteralPath $candidatePath | ConvertFrom-Json
$verification = Get-Content -Raw -LiteralPath $verificationPath | ConvertFrom-Json
if ($verification.approvedManifest.sha256 -ne $expectedCandidateHash -or
    -not $verification.download.allSizesVerified -or
    -not $verification.download.allSha256Verified) {
    throw 'The download verification receipt does not approve the immutable candidate manifest.'
}

$includedWheels = [System.Collections.Generic.List[object]]::new()
$excludedWheels = [System.Collections.Generic.List[object]]::new()
foreach ($wheel in $candidate.wheels) {
    $normalizedName = ([string]$wheel.name).ToLowerInvariant() -replace '[_.]+', '-'
    if ($excludedPackageReasons.Contains($normalizedName)) {
        $excludedWheels.Add([ordered]@{
            name = [string]$wheel.name
            version = [string]$wheel.version
            filename = [string]$wheel.filename
            url = [string]$wheel.url
            size = [long]$wheel.size
            sha256 = [string]$wheel.sha256
            licenseExpression = $wheel.licenseExpression
            licenseMetadata = $wheel.licenseMetadata
            licenseClassifiers = @($wheel.licenseClassifiers)
            reason = [string]$excludedPackageReasons[$normalizedName]
        })
    }
    else {
        $includedWheels.Add($wheel)
    }
}

if ($includedWheels.Count -ne 87 -or $excludedWheels.Count -ne 20) {
    throw "Unexpected wheel selection: included=$($includedWheels.Count), excluded=$($excludedWheels.Count)."
}

$allSourcePayloads = @($candidate.python) + @($candidate.wheels)
foreach ($payload in $allSourcePayloads) {
    Assert-File `
        -Path (Join-Path $downloadRoot ([string]$payload.filename)) `
        -Size ([long]$payload.size) `
        -Sha256 ([string]$payload.sha256)
}
Assert-File `
    -Path (Join-Path $downloadRoot $tiktokenDataFilename) `
    -Size $expectedTiktokenDataSize `
    -Sha256 $expectedTiktokenDataHash

$expectedNames = @($allSourcePayloads.filename) + $tiktokenDataFilename
$unexpectedFiles = @(
    Get-ChildItem -LiteralPath $downloadRoot -File -Force |
        Where-Object { $_.Name -notin $expectedNames }
)
if ($unexpectedFiles.Count -ne 0) {
    throw "Unexpected files in the locked download input: $($unexpectedFiles.Name -join ', ')."
}

$includedWheelBytes = [long](($includedWheels | Measure-Object -Property size -Sum).Sum)
$excludedWheelBytes = [long](
    ($excludedWheels | ForEach-Object { [long]$_['size'] } | Measure-Object -Sum).Sum)
$sourceBytes = [long]$candidate.summary.payloadBytes + $expectedTiktokenDataSize
$selectedBytes = [long]$candidate.python.size + $includedWheelBytes + $expectedTiktokenDataSize

$lock = [ordered]@{
    schemaVersion = 1
    status = 'locked-validated-text-runtime'
    validationDate = '2026-08-28'
    target = $candidate.target
    source = [ordered]@{
        candidateManifest = [ordered]@{
            path = 'runtime-manifests/m3b-proxy-without-enterprise.candidate.json'
            sha256 = $expectedCandidateHash
        }
        downloadVerification = [ordered]@{
            path = 'runtime-manifests/m3b-download-verification.json'
            sha256 = $expectedVerificationHash
        }
        litellmVersion = [string]$candidate.source.litellmVersion
        resolution = [string]$candidate.source.resolution
    }
    selectionBoundary = [ordered]@{
        workload = 'Text-only OpenAI-compatible, Anthropic, Azure OpenAI v1, and local endpoints.'
        packageManagerInstallRequired = $false
        globalPythonRequired = $false
        realModelCallsUsedForValidation = $false
        independentOsAirGapVerified = $false
    }
    python = $candidate.python
    wheels = [ordered]@{
        included = $includedWheels
        excluded = $excludedWheels
    }
    upstreamExcluded = @($candidate.excluded)
    runtimeData = @(
        [ordered]@{
            name = $tiktokenDataFilename
            url = 'https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken'
            filename = $tiktokenDataFilename
            size = $expectedTiktokenDataSize
            sha256 = $expectedTiktokenDataHash
            cacheKey = $tiktokenCacheKey
            packagedPath = "runtime/python/Lib/site-packages/litellm/litellm_core_utils/tokenizers/$tiktokenCacheKey"
            reason = 'LiteLLM imports cl100k_base through tiktoken during cold startup; packaging this data prevents an implicit network fetch.'
        }
    )
    licenseSupplements = @(
        [ordered]@{
            component = 'tokenizers 0.23.1'
            source = 'https://raw.githubusercontent.com/huggingface/tokenizers/v0.23.1/LICENSE'
            path = 'runtime-manifests/licenses/tokenizers-0.23.1-LICENSE.txt'
            packagedPath = 'THIRD-PARTY-LICENSES/tokenizers-0.23.1-LICENSE.txt'
            size = 11357
            sha256 = $expectedLicenseHash
            licenseExpression = 'Apache-2.0'
        }
    )
    validation = [ordered]@{
        providers = @('openai-compatible', 'local-endpoint', 'anthropic', 'azure-openai-v1')
        protocols = @('openai-chat-completions', 'openai-responses', 'anthropic-messages', 'server-sent-events', 'tool-calls')
        pathContainingSpaces = $true
        runtimeStateContainment = $true
        bytecodeResidueAfterCleanup = 0
    }
    summary = [ordered]@{
        candidateWheelCount = [int]$candidate.wheels.Count
        includedWheelCount = $includedWheels.Count
        excludedWheelCount = $excludedWheels.Count
        includedWheelBytes = $includedWheelBytes
        excludedWheelBytes = $excludedWheelBytes
        selectedArtifactCount = $includedWheels.Count + 2
        selectedCompressedBytes = $selectedBytes
        sourceArtifactCount = $allSourcePayloads.Count + 1
        sourceBytes = $sourceBytes
        unexpectedSourceFileCount = $unexpectedFiles.Count
    }
}

$json = $lock | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($outputPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

$outputHash = Get-Sha256 -Path $outputPath
Write-Output "M3b text runtime lock generated: $outputPath"
Write-Output "Included wheels: $($includedWheels.Count); excluded wheels: $($excludedWheels.Count)"
Write-Output "Selected artifacts: $($lock.summary.selectedArtifactCount); bytes: $selectedBytes"
Write-Output "Source artifacts: $($lock.summary.sourceArtifactCount); bytes: $sourceBytes"
Write-Output "SHA-256: $outputHash"

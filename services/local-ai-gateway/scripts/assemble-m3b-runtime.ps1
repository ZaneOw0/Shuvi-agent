[CmdletBinding()]
param(
    [switch] $Rebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$manifestPath = Join-Path $repositoryRoot 'runtime-manifests\m3b-text-runtime.lock.json'
$candidatePath = Join-Path $repositoryRoot 'runtime-manifests\m3b-proxy-without-enterprise.candidate.json'
$verificationPath = Join-Path $repositoryRoot 'runtime-manifests\m3b-download-verification.json'
$licensePath = Join-Path $repositoryRoot 'runtime-manifests\licenses\tokenizers-0.23.1-LICENSE.txt'
$downloadRoot = Join-Path $repositoryRoot 'artifacts\m3b-runtime-download'
$assemblyRoot = Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly'

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-PathUnderRoot {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Description
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description escapes its allowed root: $fullPath"
    }

    return $fullPath
}

function Expand-CheckedArchive {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $DestinationRoot,
        [scriptblock] $MapEntry
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($entryName)) {
                continue
            }
            if ($entryName.StartsWith('/') -or
                $entryName.Contains([char]0) -or
                $entryName -match '(^|/)\.\.(/|$)' -or
                $entryName -match '^[A-Za-z]:') {
                throw "Unsafe archive entry '$entryName' in '$ArchivePath'."
            }

            $relativePath = if ($null -eq $MapEntry) {
                $entryName
            }
            else {
                & $MapEntry $entryName
            }
            if ($null -eq $relativePath) {
                continue
            }

            $relativePath = ([string]$relativePath).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $targetPath = Assert-PathUnderRoot `
                -Path (Join-Path $DestinationRoot $relativePath) `
                -Root $DestinationRoot `
                -Description 'Archive entry'

            if ($entryName.EndsWith('/')) {
                [System.IO.Directory]::CreateDirectory($targetPath) | Out-Null
                continue
            }

            $targetDirectory = Split-Path -Parent $targetPath
            [System.IO.Directory]::CreateDirectory($targetDirectory) | Out-Null
            if ([System.IO.File]::Exists($targetPath)) {
                throw "Archive extraction would overwrite '$targetPath'."
            }

            $inputStream = $entry.Open()
            try {
                $outputStream = [System.IO.File]::Open(
                    $targetPath,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None)
                try {
                    $inputStream.CopyTo($outputStream)
                }
                finally {
                    $outputStream.Dispose()
                }
            }
            finally {
                $inputStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $downloadRoot -PathType Container)) {
    throw "The verified download directory does not exist: $downloadRoot"
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$verification = Get-Content -Raw -LiteralPath $verificationPath | ConvertFrom-Json
$manifestHash = Get-Sha256 -Path $manifestPath
$candidateHash = Get-Sha256 -Path $candidatePath
$verificationHash = Get-Sha256 -Path $verificationPath
if ($candidateHash -ne $manifest.source.candidateManifest.sha256 -or
    $verificationHash -ne $manifest.source.downloadVerification.sha256 -or
    $verification.approvedManifest.sha256 -ne $candidateHash) {
    throw 'The final runtime lock does not match its immutable candidate and download verification provenance.'
}

$licenseSupplement = @($manifest.licenseSupplements)[0]
$licenseHash = Get-Sha256 -Path $licensePath
if ($licenseHash -ne $licenseSupplement.sha256) {
    throw "The tokenizers license hash is invalid: $licenseHash"
}

$runtimeData = @($manifest.runtimeData)[0]
$tiktokenDataFilename = [string]$runtimeData.filename
$tiktokenDataSource = Join-Path $downloadRoot $tiktokenDataFilename
if (-not (Test-Path -LiteralPath $tiktokenDataSource -PathType Leaf)) {
    throw "The locked cl100k_base data source is missing: $tiktokenDataSource"
}
$tiktokenDataFile = Get-Item -LiteralPath $tiktokenDataSource
if ($tiktokenDataFile.Length -ne [long]$runtimeData.size) {
    throw "The cl100k_base data size is invalid: $($tiktokenDataFile.Length)"
}
$tiktokenDataHash = Get-Sha256 -Path $tiktokenDataSource
if ($tiktokenDataHash -ne $runtimeData.sha256) {
    throw "The cl100k_base data hash is invalid: $tiktokenDataHash"
}

$includedWheelDefinitions = @($manifest.wheels.included)
$excludedWheelDefinitions = @($manifest.wheels.excluded)
if ($includedWheelDefinitions.Count -ne [int]$manifest.summary.includedWheelCount -or
    $excludedWheelDefinitions.Count -ne [int]$manifest.summary.excludedWheelCount) {
    throw 'The wheel arrays do not match the final runtime lock summary.'
}
$payloads = @($manifest.python) + $includedWheelDefinitions + $excludedWheelDefinitions + @($manifest.runtimeData)
if ($payloads.Count -ne [int]$manifest.summary.sourceArtifactCount) {
    throw "The final runtime lock source count is invalid: $($payloads.Count)"
}
$expectedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($payload in $payloads) {
    if (-not $expectedNames.Add([string]$payload.filename)) {
        throw "The candidate manifest contains a duplicate filename: $($payload.filename)"
    }

    $payloadPath = Join-Path $downloadRoot $payload.filename
    $payloadFile = Get-Item -LiteralPath $payloadPath -ErrorAction Stop
    if (($payloadFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "A downloaded payload is a reparse point: $payloadPath"
    }
    if ($payloadFile.Length -ne [long]$payload.size) {
        throw "Downloaded payload size mismatch: $($payload.filename)"
    }
    $payloadHash = Get-Sha256 -Path $payloadPath
    if ($payloadHash -ne $payload.sha256) {
        throw "Downloaded payload hash mismatch: $($payload.filename)"
    }
}

$unexpectedDownloads = @(
    Get-ChildItem -LiteralPath $downloadRoot -File -Force |
        Where-Object { -not $expectedNames.Contains($_.Name) }
)
if ($unexpectedDownloads.Count -ne 0) {
    throw "The download directory contains unexpected files: $($unexpectedDownloads.Name -join ', ')"
}

$expectedAssemblyRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly'))
if (-not $assemblyRoot.Equals($expectedAssemblyRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The assembly target is not the fixed project target: $assemblyRoot"
}

if (Test-Path -LiteralPath $assemblyRoot) {
    if (-not $Rebuild) {
        throw "The assembly directory already exists. Use -Rebuild to replace only this fixed target: $assemblyRoot"
    }
    Remove-Item -LiteralPath $assemblyRoot -Recurse -Force
}

$pythonRoot = Join-Path $assemblyRoot 'runtime\python'
$sitePackages = Join-Path $pythonRoot 'Lib\site-packages'
$licenseRoot = Join-Path $assemblyRoot 'THIRD-PARTY-LICENSES'
$stateRoot = Join-Path $assemblyRoot 'runtime-state'

try {
    [System.IO.Directory]::CreateDirectory($sitePackages) | Out-Null
    [System.IO.Directory]::CreateDirectory($licenseRoot) | Out-Null
    foreach ($stateDirectory in @('temp', 'cache', 'home', 'appdata', 'localappdata')) {
        [System.IO.Directory]::CreateDirectory((Join-Path $stateRoot $stateDirectory)) | Out-Null
    }

    $pythonArchive = Join-Path $downloadRoot $manifest.python.filename
    Expand-CheckedArchive -ArchivePath $pythonArchive -DestinationRoot $pythonRoot

    $includedWheels = [System.Collections.Generic.List[object]]::new()
    foreach ($wheel in $includedWheelDefinitions) {
        $wheelPath = Join-Path $downloadRoot $wheel.filename
        $dataPrefix = ([System.IO.Path]::GetFileNameWithoutExtension([string]$wheel.filename) -replace '-[^-]+-[^-]+-[^-]+$', '')
        Expand-CheckedArchive -ArchivePath $wheelPath -DestinationRoot $sitePackages -MapEntry {
            param($entryName)

            if ($entryName -match '^[^/]+\.data/scripts/') {
                return $null
            }
            if ($entryName -match '^[^/]+\.data/(purelib|platlib)/(.+)$') {
                return $Matches[2]
            }
            if ($entryName -match '^[^/]+\.data/data/(.+)$') {
                return $Matches[1]
            }
            if ($entryName -match '^[^/]+\.data/') {
                throw "Unsupported wheel data scheme entry '$entryName' in '$wheelPath'."
            }
            return $entryName
        }

        $includedWheels.Add([ordered]@{
            name = [string]$wheel.name
            version = [string]$wheel.version
            filename = [string]$wheel.filename
            sha256 = [string]$wheel.sha256
        })
    }
    $excludedWheels = @(
        $excludedWheelDefinitions | ForEach-Object {
            [ordered]@{
                name = [string]$_.name
                version = [string]$_.version
                filename = [string]$_.filename
                reason = [string]$_.reason
            }
        }
    )

    $pthFiles = @(Get-ChildItem -LiteralPath $pythonRoot -Filter 'python*._pth' -File)
    if ($pthFiles.Count -ne 1) {
        throw "Expected exactly one embeddable Python ._pth file, found $($pthFiles.Count)."
    }
    @(
        'python314.zip'
        '.'
        'Lib\site-packages'
    ) | Set-Content -LiteralPath $pthFiles[0].FullName -Encoding utf8NoBOM

    Copy-Item -LiteralPath $licensePath `
        -Destination (Join-Path $licenseRoot 'tokenizers-0.23.1-LICENSE.txt')

    $tiktokenDataTarget = Assert-PathUnderRoot `
        -Path (Join-Path $assemblyRoot ([string]$runtimeData.packagedPath).Replace('/', '\')) `
        -Root $assemblyRoot `
        -Description 'Runtime data target'
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $tiktokenDataTarget)) | Out-Null
    Copy-Item -LiteralPath $tiktokenDataSource -Destination $tiktokenDataTarget

    $environment = [ordered]@{
        PYTHONNOUSERSITE = '1'
        PYTHONDONTWRITEBYTECODE = '1'
        PYTHONUTF8 = '1'
        DO_NOT_TRACK = 'true'
        LITELLM_LOCAL_MODEL_COST_MAP = 'True'
        NO_PROXY = '127.0.0.1,localhost'
        TEMP = 'runtime-state\temp'
        TMP = 'runtime-state\temp'
        HOME = 'runtime-state\home'
        USERPROFILE = 'runtime-state\home'
        APPDATA = 'runtime-state\appdata'
        LOCALAPPDATA = 'runtime-state\localappdata'
        XDG_CACHE_HOME = 'runtime-state\cache'
        HF_HOME = 'runtime-state\cache\huggingface'
        HUGGINGFACE_HUB_CACHE = 'runtime-state\cache\huggingface\hub'
        TRANSFORMERS_CACHE = 'runtime-state\cache\transformers'
        TORCH_HOME = 'runtime-state\cache\torch'
        PIP_CACHE_DIR = 'runtime-state\cache\pip'
        UV_CACHE_DIR = 'runtime-state\cache\uv'
    }
    $environment | ConvertTo-Json | Set-Content `
        -LiteralPath (Join-Path $assemblyRoot 'runtime-environment.json') `
        -Encoding utf8NoBOM

    $receipt = [ordered]@{
        schemaVersion = 1
        assembledAtUtc = [DateTime]::UtcNow.ToString('o')
        sourceManifest = [ordered]@{
            path = 'runtime-manifests/m3b-text-runtime.lock.json'
            sha256 = $manifestHash
        }
        sourceDownload = [ordered]@{
            path = $downloadRoot
            payloadCount = $payloads.Count
            allSizesAndHashesVerified = $true
        }
        python = [ordered]@{
            version = [string]$manifest.python.version
            filename = [string]$manifest.python.filename
            sha256 = [string]$manifest.python.sha256
        }
        wheels = [ordered]@{
            includedCount = $includedWheels.Count
            excludedCount = $excludedWheels.Count
            included = $includedWheels
            excluded = $excludedWheels
        }
        tokenizersLicense = [ordered]@{
            source = 'https://raw.githubusercontent.com/huggingface/tokenizers/v0.23.1/LICENSE'
            sha256 = $licenseHash
            packagedPath = 'THIRD-PARTY-LICENSES/tokenizers-0.23.1-LICENSE.txt'
        }
        runtimeData = @(
            [ordered]@{
                name = 'cl100k_base.tiktoken'
                source = [string]$runtimeData.url
                size = [long]$runtimeData.size
                sha256 = $tiktokenDataHash
                packagedPath = [string]$runtimeData.packagedPath
            }
        )
        isolation = [ordered]@{
            globalInstallUsed = $false
            packageManagerUsed = $false
            userSiteEnabled = $false
            bytecodeWritesEnabled = $false
            runtimeStateRoot = 'runtime-state'
        }
    }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content `
        -LiteralPath (Join-Path $assemblyRoot 'assembly-receipt.json') `
        -Encoding utf8NoBOM
}
catch {
    if (Test-Path -LiteralPath $assemblyRoot) {
        Remove-Item -LiteralPath $assemblyRoot -Recurse -Force
    }
    throw
}

$assembledFiles = @(Get-ChildItem -LiteralPath $assemblyRoot -Recurse -File)
$assembledBytes = ($assembledFiles | Measure-Object -Property Length -Sum).Sum
Write-Output "M3b runtime assembly created: $assemblyRoot"
Write-Output "Included wheels: $($includedWheels.Count); excluded wheels: $($excludedWheels.Count)"
Write-Output "Files: $($assembledFiles.Count); bytes: $assembledBytes"

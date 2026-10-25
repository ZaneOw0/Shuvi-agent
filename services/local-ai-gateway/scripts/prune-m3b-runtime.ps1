[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$assemblyRoot = Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly'
$sitePackagesRoot = Join-Path $assemblyRoot 'runtime\python\Lib\site-packages'
$quarantineRoot = Join-Path $assemblyRoot '.prune-quarantine'
$manifestPath = Join-Path $repositoryRoot 'runtime-manifests\m3b-proxy-without-enterprise.candidate.json'
$downloadRoot = Join-Path $repositoryRoot 'artifacts\m3b-runtime-download'
$receiptPath = Join-Path $assemblyRoot 'assembly-receipt.json'

$prunedPackages = @(
    'azure-core',
    'azure-identity',
    'azure-storage-blob',
    'croniter',
    'granian',
    'gunicorn',
    'hf-xet',
    'inquirerpy',
    'isodate',
    'litellm-proxy-extras',
    'msal',
    'msal-extensions',
    'pfzy',
    'polars',
    'polars-runtime-32',
    'prompt-toolkit',
    'restrictedpython',
    'rq',
    'wcwidth'
)

function Normalize-PackageName {
    param([Parameter(Mandatory)][string] $Name)
    return ($Name.ToLowerInvariant() -replace '[_.]+', '-')
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

function Get-WheelRelativeFilePaths {
    param([Parameter(Mandatory)][string] $WheelPath)

    $archive = [System.IO.Compression.ZipFile]::OpenRead($WheelPath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($entryName) -or $entryName.EndsWith('/')) {
                continue
            }
            if ($entryName.StartsWith('/') -or
                $entryName.Contains([char]0) -or
                $entryName -match '(^|/)\.\.(/|$)' -or
                $entryName -match '^[A-Za-z]:') {
                throw "Unsafe archive entry '$entryName' in '$WheelPath'."
            }
            if ($entryName -match '^[^/]+\.data/scripts/') {
                continue
            }
            if ($entryName -match '^[^/]+\.data/(purelib|platlib)/(.+)$') {
                $entryName = $Matches[2]
            }
            elseif ($entryName -match '^[^/]+\.data/data/(.+)$') {
                $entryName = $Matches[1]
            }
            elseif ($entryName -match '^[^/]+\.data/') {
                throw "Unsupported wheel data scheme entry '$entryName' in '$WheelPath'."
            }
            Write-Output $entryName
        }
    }
    finally {
        $archive.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    throw "The assembled runtime receipt does not exist: $receiptPath"
}
if (Test-Path -LiteralPath $quarantineRoot) {
    throw "The pruning quarantine already exists: $quarantineRoot"
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$wheelsByName = @{}
foreach ($wheel in $manifest.wheels) {
    $wheelsByName[(Normalize-PackageName -Name $wheel.name)] = $wheel
}

$selectedWheels = foreach ($packageName in $prunedPackages) {
    $normalizedName = Normalize-PackageName -Name $packageName
    if (-not $wheelsByName.ContainsKey($normalizedName)) {
        throw "The prune candidate is absent from the source manifest: $packageName"
    }
    $wheelsByName[$normalizedName]
}

$movedFiles = [System.Collections.Generic.List[object]]::new()
$movedBytes = [long]0
try {
    [System.IO.Directory]::CreateDirectory($quarantineRoot) | Out-Null
    foreach ($wheel in $selectedWheels) {
        $wheelPath = Join-Path $downloadRoot $wheel.filename
        foreach ($relativePath in Get-WheelRelativeFilePaths -WheelPath $wheelPath) {
            $sourcePath = Assert-PathUnderRoot `
                -Path (Join-Path $sitePackagesRoot $relativePath) `
                -Root $sitePackagesRoot `
                -Description 'Prune source'
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                continue
            }
            $quarantinePath = Assert-PathUnderRoot `
                -Path (Join-Path $quarantineRoot $relativePath) `
                -Root $quarantineRoot `
                -Description 'Prune quarantine target'
            if (Test-Path -LiteralPath $quarantinePath) {
                throw "Two prune candidates own the same extracted path: $relativePath"
            }
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $quarantinePath)) | Out-Null
            $fileLength = (Get-Item -LiteralPath $sourcePath).Length
            Move-Item -LiteralPath $sourcePath -Destination $quarantinePath
            $movedFiles.Add([pscustomobject]@{
                Source = $sourcePath
                Quarantine = $quarantinePath
                Length = $fileLength
            })
            $movedBytes += $fileLength
        }
    }

    & (Join-Path $PSScriptRoot 'smoke-m3b-runtime.ps1')

    $quarantineFullPath = [System.IO.Path]::GetFullPath($quarantineRoot)
    $expectedQuarantine = [System.IO.Path]::GetFullPath(
        (Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly\.prune-quarantine'))
    if (-not $quarantineFullPath.Equals($expectedQuarantine, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected quarantine directory: $quarantineFullPath"
    }
    Remove-Item -LiteralPath $quarantineFullPath -Recurse -Force

    foreach ($directory in @(
        Get-ChildItem -LiteralPath $sitePackagesRoot -Recurse -Directory -Force |
            Sort-Object { $_.FullName.Length } -Descending)) {
        if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory.FullName -Force
        }
    }

    $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
    $prunedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $prunedPackages) {
        [void]$prunedNames.Add((Normalize-PackageName -Name $name))
    }
    $remainingIncluded = @(
        $receipt.wheels.included |
            Where-Object { -not $prunedNames.Contains((Normalize-PackageName -Name $_.name)) }
    )
    $newExcluded = @($receipt.wheels.excluded) + @(
        $selectedWheels | ForEach-Object {
            [ordered]@{
                name = [string]$_.name
                version = [string]$_.version
                filename = [string]$_.filename
                reason = 'Excluded after offline startup and four-provider loopback protocol smoke testing.'
            }
        }
    )
    $receipt.wheels.includedCount = $remainingIncluded.Count
    $receipt.wheels.excludedCount = $newExcluded.Count
    $receipt.wheels.included = $remainingIncluded
    $receipt.wheels.excluded = $newExcluded
    $receipt | Add-Member -NotePropertyName pruning -NotePropertyValue ([ordered]@{
        verifiedAtUtc = [DateTime]::UtcNow.ToString('o')
        removedFileCount = $movedFiles.Count
        removedBytes = $movedBytes
        offlineSmokeTest = 'openai-compatible, local-endpoint, anthropic, azure-openai-v1'
    }) -Force
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
}
catch {
    foreach ($movedFile in @($movedFiles) | Sort-Object { $_.Source.Length }) {
        if (-not (Test-Path -LiteralPath $movedFile.Quarantine -PathType Leaf)) {
            continue
        }
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $movedFile.Source)) | Out-Null
        if (Test-Path -LiteralPath $movedFile.Source) {
            throw "Cannot restore a pruned file because its original path exists: $($movedFile.Source)"
        }
        Move-Item -LiteralPath $movedFile.Quarantine -Destination $movedFile.Source
    }
    if (Test-Path -LiteralPath $quarantineRoot) {
        Remove-Item -LiteralPath $quarantineRoot -Recurse -Force
    }
    throw
}

Write-Output "M3b runtime pruning passed: $($selectedWheels.Count) wheels, $($movedFiles.Count) files, $movedBytes bytes removed."

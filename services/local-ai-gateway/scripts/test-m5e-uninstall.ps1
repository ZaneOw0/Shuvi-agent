[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$acceptanceRoot = Join-Path $artifactsRoot "m5e-uninstall-check-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $acceptanceRoot 'Local AppData'
$installRoot = Join-Path $localAppData 'Programs\LocalAIGateway'
$stateRoot = Join-Path $localAppData 'LocalAIGateway'
$originalLocalAppData = $env:LOCALAPPDATA

function Invoke-DotNetTest {
    param(
        [Parameter(Mandatory)][string] $Project,
        [Parameter(Mandatory)][string] $Filter
    )

    & dotnet test $Project `
        --configuration $Configuration `
        --no-restore `
        --filter $Filter
    if ($LASTEXITCODE -ne 0) {
        throw "Focused test failed for $Project with exit code $LASTEXITCODE."
    }
}

function Invoke-CliJson {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $raw = & (Join-Path $installRoot 'aigw.exe') --json @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "aigw failed: $raw"
    }
    return $raw | ConvertFrom-Json
}

function Wait-UninstallReceipt {
    param(
        [Parameter(Mandatory)][string] $ReceiptPath,
        [Parameter(Mandatory)][string] $OperationId
    )

    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while (-not (Test-Path -LiteralPath $ReceiptPath) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $ReceiptPath)) {
        throw "Uninstall receipt timed out: $ReceiptPath"
    }

    $receipt = Get-Content -Raw -LiteralPath $ReceiptPath | ConvertFrom-Json
    if ($receipt.operationId -ne $OperationId -or $receipt.state -ne 'completed' -or -not $receipt.ok) {
        throw "Uninstall receipt reported failure: $($receipt | ConvertTo-Json -Compress -Depth 12)"
    }
    return $receipt
}

function Get-AcceptanceProcesses {
    if (-not (Test-Path -LiteralPath $acceptanceRoot)) {
        return @()
    }
    $prefix = [IO.Path]::GetFullPath($acceptanceRoot).TrimEnd('\') + '\'
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith(
                $prefix,
                [StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $false
        }
    })
}

Push-Location $repositoryRoot
try {
    if (Test-Path -LiteralPath $acceptanceRoot) {
        throw "Refusing to reuse uninstall acceptance root: $acceptanceRoot"
    }

    Invoke-DotNetTest `
        -Project 'tests\LocalAIGateway.Core.Tests\LocalAIGateway.Core.Tests.csproj' `
        -Filter 'FullyQualifiedName~BackupFileCleanerTests'
    Invoke-DotNetTest `
        -Project 'tests\LocalAIGateway.Windows.Tests\LocalAIGateway.Windows.Tests.csproj' `
        -Filter 'FullyQualifiedName~CurrentUserUninstallCoordinatorTests|FullyQualifiedName~OwnedCredentialCleanerTests|FullyQualifiedName~OwnedStateDataCleanerTests'
    Invoke-DotNetTest `
        -Project 'tests\LocalAIGateway.Cli.Tests\LocalAIGateway.Cli.Tests.csproj' `
        -Filter 'FullyQualifiedName~M5eUninstallCommandTests|FullyQualifiedName~DirectUninstallServiceTests|FullyQualifiedName~UninstallSelectionResolverTests'
    Invoke-DotNetTest `
        -Project 'tests\LocalAIGateway.Updater.Tests\LocalAIGateway.Updater.Tests.csproj' `
        -Filter 'FullyQualifiedName~UpdaterApplicationTests'

    & (Join-Path $PSScriptRoot 'package.ps1') `
        -Configuration $Configuration `
        -ArtifactsDirectory $acceptanceRoot `
        -NoRestore `
        -RefuseExistingArtifacts
    if ($LASTEXITCODE -ne 0) {
        throw "M5e full package creation failed with exit code $LASTEXITCODE."
    }

    $packageRoot = Join-Path $acceptanceRoot 'staging\win-x64'
    New-Item -ItemType Directory -Path (Split-Path -Parent $installRoot) -Force | Out-Null
    Move-Item -LiteralPath $packageRoot -Destination $installRoot
    $env:LOCALAPPDATA = $localAppData

    $null = Invoke-CliJson -Arguments @('profile', 'create', '--id', 'fixture', '--name', 'Fixture')
    New-Item -ItemType Directory -Path (Join-Path $stateRoot 'usage') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stateRoot 'logs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $stateRoot 'usage\usage.db') -Value 'fixture' -NoNewline
    Set-Content -LiteralPath (Join-Path $stateRoot 'logs\gateway.log') -Value 'fixture' -NoNewline

    $backupPath = Join-Path $acceptanceRoot 'explicit-backup.json'
    $null = Invoke-CliJson -Arguments @('backup', 'create', '--output', $backupPath)

    $integrationRoot = Join-Path $acceptanceRoot 'integration'
    New-Item -ItemType Directory -Path $integrationRoot | Out-Null
    $codexTarget = Join-Path $integrationRoot 'aigw.config.toml'
    $preview = Invoke-CliJson -Arguments @(
        'integrate', 'preview',
        '--client', 'codex-cli',
        '--target', $codexTarget,
        '--client-version', '0.134.0'
    )
    $null = Invoke-CliJson -Arguments @(
        'integrate', 'apply',
        '--client', 'codex-cli',
        '--target', $codexTarget,
        '--client-version', '0.134.0',
        '--expect-absent',
        '--expected-after-sha256', $preview.data.afterSha256,
        '--confirm', 'APPLY'
    )

    $scheduled = Invoke-CliJson -Arguments @(
        'uninstall', '--non-interactive', '--confirm', 'UNINSTALL',
        '--program', 'remove',
        '--autostart', 'keep',
        '--integrations', 'remove',
        '--runtime-credential', 'keep',
        '--provider-credentials', 'keep',
        '--configuration', 'remove',
        '--usage', 'remove',
        '--logs', 'remove',
        '--backups', 'remove',
        '--codex-cli-target', $codexTarget,
        '--backup-path', $backupPath
    )
    if (-not $scheduled.data.completionPending) {
        throw 'Installed CLI did not report pending external uninstall completion.'
    }

    $receipt = Wait-UninstallReceipt `
        -ReceiptPath $scheduled.data.receiptPath `
        -OperationId $scheduled.data.operationId
    if (-not $receipt.result.program.changed -or
        -not $receipt.result.integrations.changed -or
        -not $receipt.result.configuration.changed -or
        -not $receipt.result.usage.changed -or
        -not $receipt.result.logs.changed -or
        -not $receipt.result.backups.changed) {
        throw 'Uninstall receipt did not confirm every selected isolated category.'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (@(Get-AcceptanceProcesses).Count -ne 0 -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (@(Get-AcceptanceProcesses).Count -ne 0) {
        throw 'An M5e acceptance process remained after the uninstall receipt.'
    }
    if (Test-Path -LiteralPath $installRoot) {
        throw 'The manifest-owned isolated installation root remains.'
    }
    if (Test-Path -LiteralPath $stateRoot) {
        throw 'The selected isolated configuration, usage, logs, or runtime state remains.'
    }
    if (Test-Path -LiteralPath $backupPath) {
        throw 'The explicitly selected Local AI Gateway backup remains.'
    }
    if (Test-Path -LiteralPath $codexTarget) {
        throw 'The explicitly selected owned Codex integration remains.'
    }
    $recoveryBackups = @(Get-ChildItem -LiteralPath $integrationRoot -Filter '*.aigw-backup-*.bak' -File)
    if ($recoveryBackups.Count -ne 1) {
        throw 'Owned integration removal did not preserve exactly one recovery backup.'
    }

    Write-Output 'M5e uninstall acceptance passed: explicit selections, external worker, complete isolated cleanup, and recovery evidence.'
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    foreach ($process in Get-AcceptanceProcesses) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $acceptanceRoot) {
        $resolvedAcceptance = [IO.Path]::GetFullPath($acceptanceRoot)
        $resolvedArtifacts = [IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\') + '\'
        if (-not $resolvedAcceptance.StartsWith($resolvedArtifacts, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing unsafe uninstall acceptance cleanup: $resolvedAcceptance"
        }
        Remove-Item -LiteralPath $resolvedAcceptance -Recurse -Force
    }
    Pop-Location
}

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactRoot = Join-Path $repositoryRoot "artifacts\m5c-backup-check-$([Guid]::NewGuid().ToString('N'))"
$artifactPrefix = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'artifacts')).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$artifactFull = [System.IO.Path]::GetFullPath($artifactRoot)
if (-not $artifactFull.StartsWith($artifactPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe M5c artifact root: $artifactFull"
}

$pythonPath = Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly\runtime\python\python.exe'
$cryptoScript = Join-Path $repositoryRoot 'src\LocalAIGateway.Windows\Backup\Assets\aigw_backup_crypto.py'
$sleepScript = Join-Path $repositoryRoot 'tests\fixtures\m5b_usage_query_sleep.py'
$cliDll = Join-Path $repositoryRoot 'src\LocalAIGateway.Cli\bin\Release\net10.0-windows\aigw.dll'
foreach ($required in @($pythonPath, $cryptoScript, $sleepScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required M5c component is missing: $required"
    }
}

$priorPython = $env:AIGW_M5C_PYTHON_PATH
$priorScript = $env:AIGW_M5C_CRYPTO_SCRIPT_PATH
$priorSleepScript = $env:AIGW_M5C_SLEEP_SCRIPT_PATH
$priorLocalAppData = $env:LOCALAPPDATA
try {
    New-Item -ItemType Directory -Path $artifactFull | Out-Null
    $env:AIGW_M5C_PYTHON_PATH = $pythonPath
    $env:AIGW_M5C_CRYPTO_SCRIPT_PATH = $cryptoScript
    $env:AIGW_M5C_SLEEP_SCRIPT_PATH = $sleepScript

    & dotnet test (Join-Path $repositoryRoot 'tests\LocalAIGateway.Core.Tests\LocalAIGateway.Core.Tests.csproj') `
        --configuration Release --no-restore --filter 'FullyQualifiedName~M5cBackupCoordinatorTests'
    if ($LASTEXITCODE -ne 0) { throw "M5c Core tests failed with exit code $LASTEXITCODE." }

    & dotnet test (Join-Path $repositoryRoot 'tests\LocalAIGateway.Windows.Tests\LocalAIGateway.Windows.Tests.csproj') `
        --configuration Release --no-restore --filter 'FullyQualifiedName~PrivatePythonBackupCryptographyTests'
    if ($LASTEXITCODE -ne 0) { throw "M5c Windows tests failed with exit code $LASTEXITCODE." }

    & dotnet test (Join-Path $repositoryRoot 'tests\LocalAIGateway.Cli.Tests\LocalAIGateway.Cli.Tests.csproj') `
        --configuration Release --no-restore --filter 'FullyQualifiedName~M5cBackupCommandTests'
    if ($LASTEXITCODE -ne 0) { throw "M5c CLI tests failed with exit code $LASTEXITCODE." }

    if (-not (Test-Path -LiteralPath $cliDll -PathType Leaf)) {
        throw "The built CLI is missing: $cliDll"
    }
    $isolatedLocalAppData = Join-Path $artifactFull 'local-app-data'
    $backupPath = Join-Path $artifactFull 'plain-backup.json'
    New-Item -ItemType Directory -Path $isolatedLocalAppData | Out-Null
    $env:LOCALAPPDATA = $isolatedLocalAppData

    function Invoke-CliJson {
        param([Parameter(Mandatory)][string[]] $Arguments)
        $output = & dotnet $cliDll --json @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "CLI command failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
        }
        return ($output | ConvertFrom-Json)
    }

    Invoke-CliJson -Arguments @('profile', 'create', '--id', 'work', '--name', 'Work') | Out-Null
    Invoke-CliJson -Arguments @(
        'provider', 'add', '--profile', 'work', '--id', 'primary', '--name', 'Primary',
        '--type', 'openai-compatible', '--endpoint', 'https://api.example.com/v1') | Out-Null
    Invoke-CliJson -Arguments @(
        'model', 'add', '--profile', 'work', '--alias', 'aigw/default',
        '--provider', 'primary', '--upstream', 'fixture-model') | Out-Null
    $created = Invoke-CliJson -Arguments @('backup', 'create', '--output', $backupPath)
    $inspected = Invoke-CliJson -Arguments @('backup', 'inspect', '--input', $backupPath)
    if ($created.data.encrypted -or
        $created.data.runtimeCredentialIncluded -or
        $created.data.secretCount -ne 0 -or
        $created.data.sha256 -ne $inspected.data.sha256) {
        throw 'The product CLI returned an invalid plain-backup summary.'
    }
    $backupAcl = Get-Acl -LiteralPath $backupPath
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $backupRules = @($backupAcl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]))
    if (-not $backupAcl.AreAccessRulesProtected -or
        @($backupRules | Where-Object { $_.IsInherited }).Count -ne 0 -or
        @($backupRules | Where-Object {
            $_.IdentityReference -eq $currentSid -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
                [System.Security.AccessControl.FileSystemRights]::FullControl
        }).Count -ne 1) {
        throw 'The created backup does not have the expected current-user-only ACL.'
    }
    $updated = Invoke-CliJson -Arguments @(
        'provider', 'update', '--profile', 'work', '--id', 'primary', '--name', 'Changed')
    $restored = Invoke-CliJson -Arguments @(
        'backup', 'restore', '--input', $backupPath,
        '--expected-sha256', [string]$inspected.data.sha256,
        '--expected-current-revision', [string]$updated.data.revision,
        '--confirm', 'RESTORE')
    if ($restored.data.currentRevision -ne ($updated.data.revision + 1) -or
        $restored.data.secretsRestored -ne 0) {
        throw 'The product CLI returned an invalid restore result.'
    }
    $provider = Invoke-CliJson -Arguments @('provider', 'show', '--profile', 'work', '--id', 'primary')
    if ($provider.data.name -ne 'Primary') {
        throw 'The product CLI did not restore the backed-up configuration.'
    }

    $temporaryFiles = @(Get-ChildItem -LiteralPath $artifactFull -Recurse -File -Filter '*.tmp')
    if ($temporaryFiles.Count -ne 0) {
        throw "M5c left temporary files: $($temporaryFiles.FullName -join ', ')"
    }
    $privatePythonRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $pythonPath))
    $privatePythonProcesses = @(Get-Process -Name 'python', 'pythonw' -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.Path -and [System.IO.Path]::GetFullPath($_.Path).StartsWith(
                $privatePythonRoot,
                [System.StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $false
        }
    })
    if ($privatePythonProcesses.Count -ne 0) {
        throw "M5c left private Python processes: $($privatePythonProcesses.Id -join ', ')"
    }
    $bytecodeResidue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $cryptoScript) -Recurse -Force | Where-Object {
        $_.Name -eq '__pycache__' -or $_.Extension -eq '.pyc'
    })
    if ($bytecodeResidue.Count -ne 0) {
        throw "M5c left bytecode residue: $($bytecodeResidue.FullName -join ', ')"
    }
}
finally {
    $env:AIGW_M5C_PYTHON_PATH = $priorPython
    $env:AIGW_M5C_CRYPTO_SCRIPT_PATH = $priorScript
    $env:AIGW_M5C_SLEEP_SCRIPT_PATH = $priorSleepScript
    $env:LOCALAPPDATA = $priorLocalAppData
    if (Test-Path -LiteralPath $artifactFull) {
        $verified = [System.IO.Path]::GetFullPath($artifactFull)
        if (-not $verified.StartsWith($artifactPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean outside artifacts: $verified"
        }
        Remove-Item -LiteralPath $verified -Recurse -Force
    }
}

if (Test-Path -LiteralPath $artifactFull) {
    throw "M5c test root still exists: $artifactFull"
}
Write-Output 'M5c backup acceptance passed: transactions, Argon2id/AES-GCM, CLI restore, and zero test-root residue.'

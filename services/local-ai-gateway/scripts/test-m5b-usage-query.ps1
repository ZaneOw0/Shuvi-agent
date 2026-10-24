[CmdletBinding()]
param(
    [string]$PythonPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($PythonPath)) {
    $PythonPath = Join-Path $repositoryRoot 'artifacts\m3b-runtime-assembly\runtime\python\python.exe'
}
$python = [System.IO.Path]::GetFullPath($PythonPath)
$query = Join-Path $repositoryRoot 'src\LocalAIGateway.Windows\UsageData\Assets\aigw_usage_query.py'
$driver = Join-Path $repositoryRoot 'tests\fixtures\m5b_usage_query_driver.py'
$sleepScript = Join-Path $repositoryRoot 'tests\fixtures\m5b_usage_query_sleep.py'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("LocalAIGateway-M5b-" + [Guid]::NewGuid().ToString('N'))

if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Private Python runtime was not found: $python"
}

New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $python
    $startInfo.WorkingDirectory = $temporaryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $environment = $startInfo.EnvironmentVariables
    $environment.Clear()
    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
    if (-not [string]::IsNullOrEmpty($systemRoot)) {
        $environment['SystemRoot'] = $systemRoot
    }
    $environment['PYTHONNOUSERSITE'] = '1'
    $environment['PYTHONDONTWRITEBYTECODE'] = '1'
    $environment['PYTHONUTF8'] = '1'
    $environment['HOME'] = $temporaryRoot
    $environment['USERPROFILE'] = $temporaryRoot
    $environment['APPDATA'] = $temporaryRoot
    $environment['LOCALAPPDATA'] = $temporaryRoot
    $environment['TEMP'] = $temporaryRoot
    $environment['TMP'] = $temporaryRoot
    $environment['XDG_CACHE_HOME'] = (Join-Path $temporaryRoot 'cache')
    $database = Join-Path $temporaryRoot 'state\usage\usage.db'
    $startInfo.Arguments = '-B -I "{0}" "{1}" "{2}"' -f $driver, $query, $database

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'Private Python usage query acceptance process did not start.'
    }
    try {
        $output = $process.StandardOutput.ReadToEnd()
        $errorOutput = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "M5b usage query acceptance failed with exit code $($process.ExitCode).`n$errorOutput"
        }
        Write-Output $output.Trim()
    }
    finally {
        $process.Dispose()
    }

    $previousPython = $env:AIGW_M5B_PYTHON
    $previousScript = $env:AIGW_M5B_QUERY_SCRIPT
    $previousSleepScript = $env:AIGW_M5B_SLEEP_SCRIPT
    $previousTestRoot = $env:AIGW_M5B_TEST_ROOT
    try {
        $env:AIGW_M5B_PYTHON = $python
        $env:AIGW_M5B_QUERY_SCRIPT = $query
        $env:AIGW_M5B_SLEEP_SCRIPT = $sleepScript
        $env:AIGW_M5B_TEST_ROOT = $temporaryRoot
        dotnet test `
            (Join-Path $repositoryRoot 'tests\LocalAIGateway.Windows.Tests\LocalAIGateway.Windows.Tests.csproj') `
            -c Release `
            --no-restore `
            --filter 'FullyQualifiedName~PrivatePythonUsageSummaryReaderIntegrationTests'
        if ($LASTEXITCODE -ne 0) {
            throw "M5b product reader integration test failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        $env:AIGW_M5B_PYTHON = $previousPython
        $env:AIGW_M5B_QUERY_SCRIPT = $previousScript
        $env:AIGW_M5B_SLEEP_SCRIPT = $previousSleepScript
        $env:AIGW_M5B_TEST_ROOT = $previousTestRoot
    }
    $residualProcesses = @(
        Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq $python })
    if ($residualProcesses.Count -ne 0) {
        throw "M5b usage query left $($residualProcesses.Count) private Python process(es)."
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

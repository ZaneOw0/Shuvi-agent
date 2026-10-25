[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Studio')][string]$DevEcoHome,
    [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')][string]$HvigorPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')][string]$SdkHome,
    [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')][string]$JavaHome,
    [ValidateSet('agent_contracts', 'agent_core', 'agent_runtime', 'mcp_client',
        'agent_connectors', 'agent_storage', 'native_tools', 'agent_testkit')]
    [string[]]$Modules = @('agent_contracts', 'agent_core', 'agent_runtime', 'mcp_client',
        'agent_connectors', 'agent_storage', 'native_tools', 'agent_testkit')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $projectRoot 'tests\agent-host'
$moduleRoot = Join-Path $projectRoot 'modules\harmony_agent'
if ($PSCmdlet.ParameterSetName -eq 'Studio') {
    $hvigor = Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.bat'
    $sdk = Join-Path $DevEcoHome 'sdk'
    $jdk = Join-Path $DevEcoHome 'jbr'
} else {
    $hvigor = $HvigorPath
    $sdk = $SdkHome
    $jdk = $JavaHome
}
foreach ($required in @($hvigor, $sdk, $jdk)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing toolchain path: $required" }
}
& node (Join-Path $PSScriptRoot 'verify-agent-host.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Agent import verification failed' }
$runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$outputRoot = Join-Path $projectRoot ".local\agent-tests\$runId"
New-Item -ItemType Directory -Path $outputRoot | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
$oldSdk = $env:DEVECO_SDK_HOME
$oldJava = $env:JAVA_HOME
$failure = $null
Push-Location $testRoot
try {
    $env:DEVECO_SDK_HOME = $sdk
    $env:JAVA_HOME = $jdk
    foreach ($module in ($Modules | Select-Object -Unique)) {
        $started = [DateTime]::UtcNow
        $log = Join-Path $outputRoot "$module.log"
        $resultFile = Join-Path $moduleRoot "$module\.test\default\intermediates\test\coverage_data\test_result.txt"
        Write-Output "Testing $module ..."
        # Native compiler diagnostics can arrive on stderr; check exit code and report.
        $ErrorActionPreference = 'Continue'
        & $hvigor --mode module -p "module=$module@default" -p product=default test --no-daemon *> $log
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) { throw "$module test task failed ($code). See $log" }
        if (-not (Test-Path -LiteralPath $resultFile)) { throw "$module produced no test report" }
        if ((Get-Item -LiteralPath $resultFile).LastWriteTimeUtc -lt $started.AddSeconds(-2)) {
            throw "$module report predates this test run"
        }
        $text = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8
        $summary = [regex]::Match($text, 'Tests run:\s*(\d+), Failure:\s*(\d+), Error:\s*(\d+), Pass:\s*(\d+), Ignore:\s*(\d+)')
        Copy-Item -LiteralPath $resultFile -Destination (Join-Path $outputRoot "$module-result.txt")
        if (-not $summary.Success) { throw "$module report has no recognized test totals" }
        $total = [int]$summary.Groups[1].Value
        $passed = [int]$summary.Groups[4].Value
        $results.Add([pscustomobject]@{
            module = $module; total = $total; passed = $passed
            failed = [int]$summary.Groups[2].Value; errors = [int]$summary.Groups[3].Value
            ignored = [int]$summary.Groups[5].Value; summary = $summary.Value
        })
        Write-Output "$module : $($summary.Value)"
        if ($total -lt 1 -or $passed -ne $total -or
            [int]$summary.Groups[2].Value -ne 0 -or [int]$summary.Groups[3].Value -ne 0 -or
            [int]$summary.Groups[5].Value -ne 0) { throw "$module did not pass every test" }
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    $env:DEVECO_SDK_HOME = $oldSdk
    $env:JAVA_HOME = $oldJava
    Pop-Location
    $report = [ordered]@{
        runId = $runId; environment = 'Windows Hypium host tests; no device or real provider'
        sourceManifestSha256 = (Get-FileHash (Join-Path $moduleRoot 'UPSTREAM.json')).Hash
        requestedModules = $Modules; results = @($results.ToArray()); failure = $failure
        completed = ($null -eq $failure)
    }
    [IO.File]::WriteAllText((Join-Path $outputRoot 'summary.json'),
        ($report | ConvertTo-Json -Depth 6) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Output "Evidence: $outputRoot"
}
if ($null -ne $failure) { throw $failure }

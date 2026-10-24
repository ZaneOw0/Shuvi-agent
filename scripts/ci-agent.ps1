[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$HvigorPath,
    [Parameter(Mandatory = $true)][string]$OhpmPath,
    [Parameter(Mandatory = $true)][string]$SdkHome,
    [Parameter(Mandatory = $true)][string]$JavaHome,
    [switch]$NoInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
foreach ($required in @($HvigorPath, $OhpmPath, $SdkHome, $JavaHome)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing toolchain path: $required" }
}
$oldSdk = $env:DEVECO_SDK_HOME
$oldJava = $env:JAVA_HOME
Push-Location $projectRoot
try {
    $env:DEVECO_SDK_HOME = $SdkHome
    $env:JAVA_HOME = $JavaHome
    & node scripts/verify-agent-host.cjs
    if ($LASTEXITCODE -ne 0) { throw 'Agent source verification failed' }
    & node --test scripts/tests/agent-local-changes.test.cjs
    if ($LASTEXITCODE -ne 0) { throw 'Agent local provenance checks failed' }
    foreach ($script in @('run-host-tests.cjs', 'run-floating-placement-tests.cjs', 'run-mcp-probe-tests.cjs', 'run-direct-model-tests.cjs')) {
        & node "entry/src/test/$script"
        if ($LASTEXITCODE -ne 0) { throw "UX checks failed: $script" }
    }
    Push-Location tests/agent-host
    try {
        if (-not $NoInstall) {
            & $OhpmPath install --all
            if ($LASTEXITCODE -ne 0) { throw 'Agent host dependency install failed' }
        }
        & $HvigorPath assembleHap assembleHar --no-daemon
        if ($LASTEXITCODE -ne 0) { throw 'Agent host / HAR build failed' }
        & $HvigorPath --mode module -p module=test_host@ohosTest -p product=default assembleHap --no-daemon
        if ($LASTEXITCODE -ne 0) { throw 'Agent device-test package build failed' }
    } finally { Pop-Location }
    & "$PSScriptRoot/test-agent-unit.ps1" -HvigorPath $HvigorPath -SdkHome $SdkHome -JavaHome $JavaHome
} finally {
    Pop-Location
    $env:DEVECO_SDK_HOME = $oldSdk
    $env:JAVA_HOME = $oldJava
}

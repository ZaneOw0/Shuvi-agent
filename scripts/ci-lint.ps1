[CmdletBinding(DefaultParameterSetName = 'CLT')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'CLT')][string]$CodeLinterPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'CLT')][string]$LogDirectory,
    [Parameter(Mandatory = $true, ParameterSetName = 'Studio')][string]$NodeScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$runDirectory = Join-Path $projectRoot ".local\ci-lint\$runId"
$tool = if ($PSCmdlet.ParameterSetName -eq 'Studio') { $NodeScript } else { $CodeLinterPath }
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Missing Code Linter executable: $tool" }
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$oldLogPath = $env:logPath
if ($PSCmdlet.ParameterSetName -eq 'Studio') {
    # The installed Studio CLI explicitly supports this environment variable.
    $LogDirectory = $runDirectory
    $env:logPath = Join-Path $runDirectory 'codelinter.log'
} elseif (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
    throw 'Set CODELINTER_LOG_DIR to the actual CLT engine log directory (not the JSON report directory)'
}
$report = Join-Path $runDirectory 'report.json'
$consoleLog = Join-Path $runDirectory 'console.log'
# The known-defect exemption inside verify-lint-report.cjs is pinned to one Code Linter
# build. Record the version the tool reports so a toolchain upgrade cannot silently keep
# the exemption alive.
$toolVersion = ''
try {
    $ErrorActionPreference = 'Continue'
    $versionText = (& $tool -v 2>$null | Out-String)
    $ErrorActionPreference = 'Stop'
    $versionMatch = [regex]::Match($versionText, '\d+\.\d+\.\d+')
    if ($versionMatch.Success) { $toolVersion = $versionMatch.Value }
} catch { $toolVersion = '' }
Write-Output "Code Linter version: $(if ($toolVersion) { $toolVersion } else { 'unreported' })"
Push-Location $projectRoot
try {
    & node scripts/verify-lint-report.cjs snapshot $LogDirectory $runDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Cannot snapshot analyzer log metadata' }
    # Native warnings may use stderr. Evaluate the exit code AND fresh report/logs below.
    $ErrorActionPreference = 'Continue'
    if ($PSCmdlet.ParameterSetName -eq 'Studio') {
        & node $NodeScript -f json -o $report $projectRoot *> $consoleLog
    } else {
        & $CodeLinterPath -f json -o $report $projectRoot *> $consoleLog
    }
    $toolExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    & node scripts/verify-lint-report.cjs verify $runDirectory $toolExit $toolVersion
    if ($LASTEXITCODE -ne 0) { throw "Code Linter gate failed. Evidence: $runDirectory" }
    Write-Output "Code Linter gate passed. Evidence: $runDirectory"
} finally {
    $env:logPath = $oldLogPath
    Pop-Location
}

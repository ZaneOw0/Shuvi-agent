[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$gatewayRoot = Join-Path $projectRoot 'services/local-ai-gateway'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$resultsRoot = Join-Path $projectRoot ".local/gateway-tests/$runId"
& node (Join-Path $PSScriptRoot 'verify-gateway-import.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Gateway source verification failed' }
New-Item -ItemType Directory -Path $resultsRoot | Out-Null
Push-Location $gatewayRoot
try {
    & dotnet --version
    if ($LASTEXITCODE -ne 0) { throw 'Install the .NET SDK required by gateway global.json' }
    & dotnet test LocalAIGateway.slnx -c Release -r win-x64 -p:SelfContained=true --logger trx --results-directory $resultsRoot
    if ($LASTEXITCODE -ne 0) { throw 'Gateway tests failed' }
    $projects = @(Get-ChildItem -LiteralPath tests -Recurse -Filter '*.csproj' | Where-Object {
        [xml]$project = Get-Content -LiteralPath $_.FullName -Raw
        $project.SelectSingleNode('//IsTestProject[text()="true"]') -ne $null
    })
    $reports = @(Get-ChildItem -LiteralPath $resultsRoot -Filter '*.trx')
    if ($projects.Count -eq 0 -or $reports.Count -ne $projects.Count) {
        throw 'Missing gateway test projects or TRX reports'
    }
    $total = 0
    foreach ($report in $reports) {
        [xml]$xml = Get-Content -LiteralPath $report.FullName -Raw
        $counters = $xml.SelectSingleNode('//*[local-name()="ResultSummary"]/*[local-name()="Counters"]')
        if ($null -eq $counters -or [int]$counters.total -lt 1 -or
            [int]$counters.passed -ne [int]$counters.total) {
            throw "Not every test passed: $($report.Name)"
        }
        $total += [int]$counters.total
    }
    Write-Output "Gateway tests passed: $total; reports: $($reports.Count); evidence: $resultsRoot"
} finally { Pop-Location }

[CmdletBinding()]
param(
    [string]$ApplicationRoot = (Join-Path $PSScriptRoot "..\artifacts\m3b-runtime-assembly"),
    [string]$TestRoot = (Join-Path $PSScriptRoot "..\artifacts\m3d daemon acceptance"),
    [ValidateSet("M3d", "M3e")]
    [string]$AcceptanceLabel = "M3d"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$artifactsRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot "artifacts"))
$applicationRootFull = [System.IO.Path]::GetFullPath($ApplicationRoot)
$testRootFull = [System.IO.Path]::GetFullPath($TestRoot)
$artifactsPrefix = $artifactsRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
    [System.IO.Path]::DirectorySeparatorChar
$applicationPrefix = $applicationRootFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
    [System.IO.Path]::DirectorySeparatorChar
$testPrefix = $testRootFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
    [System.IO.Path]::DirectorySeparatorChar

if (-not $applicationRootFull.StartsWith($artifactsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ApplicationRoot must be contained under the repository artifacts directory."
}
if (-not $testRootFull.StartsWith($artifactsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "TestRoot must be contained under the repository artifacts directory."
}
if ($testRootFull.Equals($applicationRootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
    $testRootFull.StartsWith($applicationPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
    $applicationRootFull.StartsWith($testPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "TestRoot and ApplicationRoot must not overlap."
}
if (-not (Test-Path -LiteralPath (Join-Path $applicationRootFull "runtime\python\python.exe") -PathType Leaf)) {
    throw "The assembled private Python runtime is missing from ApplicationRoot."
}
if (Test-Path -LiteralPath $testRootFull) {
    throw "The exact $AcceptanceLabel acceptance TestRoot already exists; refusing to overwrite or delete it."
}

function Get-PrivateRuntimeProcesses {
    @(
        Get-Process -ErrorAction Stop |
            ForEach-Object {
                try {
                    $executablePath = $_.Path
                    if (-not [string]::IsNullOrEmpty($executablePath) -and
                        $executablePath.StartsWith(
                            $applicationPrefix,
                            [System.StringComparison]::OrdinalIgnoreCase)) {
                        $_
                    }
                }
                catch {
                    # Access to unrelated protected processes is not required for
                    # checking executables launched from the current-user test root.
                }
            }
    )
}

$processesBefore = @(Get-PrivateRuntimeProcesses)
if ($processesBefore.Count -ne 0) {
    throw "Private runtime processes already exist before $AcceptanceLabel acceptance; refusing an ambiguous test."
}

$previousApplicationRoot = $env:AIGW_M3D_APPLICATION_ROOT
$previousTestRoot = $env:AIGW_M3D_TEST_ROOT
try {
    $env:AIGW_M3D_APPLICATION_ROOT = $applicationRootFull
    $env:AIGW_M3D_TEST_ROOT = $testRootFull
    & dotnet test `
        (Join-Path $repositoryRoot "tests\LocalAIGateway.Runtime.Tests\LocalAIGateway.Runtime.Tests.csproj") `
        -c Release `
        --no-build `
        --filter "FullyQualifiedName~GatewayDaemonHostIntegrationTests"
    if ($LASTEXITCODE -ne 0) {
        throw "The real $AcceptanceLabel Runtime composition test failed with exit code $LASTEXITCODE."
    }
}
finally {
    $env:AIGW_M3D_APPLICATION_ROOT = $previousApplicationRoot
    $env:AIGW_M3D_TEST_ROOT = $previousTestRoot
}

$residualProcesses = @(Get-PrivateRuntimeProcesses)
$runtimeStateRoot = Join-Path $applicationRootFull "runtime-state"
$runtimeStateFiles = if (Test-Path -LiteralPath $runtimeStateRoot) {
    @(Get-ChildItem -LiteralPath $runtimeStateRoot -Recurse -File -Force).Count
}
else {
    0
}
$bytecodeFiles = @(Get-ChildItem -LiteralPath $applicationRootFull -Recurse -File -Filter "*.pyc").Count
$bytecodeDirectories = @(
    Get-ChildItem -LiteralPath $applicationRootFull -Recurse -Directory -Filter "__pycache__"
).Count

$failures = [System.Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $testRootFull) {
    $failures.Add("The $AcceptanceLabel acceptance TestRoot remains after the test.")
}
if ($residualProcesses.Count -ne 0) {
    $failures.Add("$($residualProcesses.Count) private runtime process(es) remain after the test.")
}
if ($runtimeStateFiles -ne 0) {
    $failures.Add("$runtimeStateFiles file(s) remain in the assembly runtime-state directory.")
}
if ($bytecodeFiles -ne 0 -or $bytecodeDirectories -ne 0) {
    $failures.Add("Python bytecode residue remains: $bytecodeFiles .pyc file(s), $bytecodeDirectories __pycache__ directory/directories.")
}
if ($failures.Count -ne 0) {
    throw ($failures -join [Environment]::NewLine)
}

Write-Host "$AcceptanceLabel real Runtime acceptance passed."
Write-Host "Private runtime processes after cleanup: 0"
Write-Host "Test-root, runtime-state, .pyc, and __pycache__ residue: 0"

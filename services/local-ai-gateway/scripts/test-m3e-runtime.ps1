[CmdletBinding()]
param(
    [string]$ApplicationRoot = (Join-Path $PSScriptRoot "..\artifacts\m3b-runtime-assembly"),
    [string]$TestRoot = (Join-Path $PSScriptRoot "..\artifacts\m3e blue-green acceptance")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot "test-m3d-runtime.ps1") `
    -ApplicationRoot $ApplicationRoot `
    -TestRoot $TestRoot `
    -AcceptanceLabel "M3e"

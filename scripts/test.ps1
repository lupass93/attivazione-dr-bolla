[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($test in @('multisubscription.ps1', 'direct-disk-copy.ps1', 'session-submission.ps1', 'session-worker.ps1', 'session-status.ps1', 'preflight.ps1')) {
    & pwsh -NoLogo -NoProfile -File (Join-Path $root "tests/$test")
    if ($LASTEXITCODE -ne 0) { throw "Test failed: $test" }
}
terraform "-chdir=$(Join-Path $root 'terraform')" test -no-color
if ($LASTEXITCODE -ne 0) { throw 'Terraform tests failed.' }
Write-Host 'PASS: all local DR regression and session tests.'

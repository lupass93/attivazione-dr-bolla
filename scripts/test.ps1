[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($source in Get-ChildItem (Join-Path $root 'tests') -File -Filter '*.ps1') {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors.Message -join '; ') }
}
foreach ($test in @('multisubscription.ps1', 'direct-disk-copy.ps1', 'session-submission.ps1', 'session-worker.ps1',
        'session-status.ps1', 'preflight.ps1', 'csv-priority.ps1', 'customer-status.ps1')) {
    & pwsh -NoLogo -NoProfile -File (Join-Path $root "tests/$test")
    if ($LASTEXITCODE -ne 0) { throw "Test failed: $test" }
}
terraform "-chdir=$(Join-Path $root 'terraform')" test -no-color
if ($LASTEXITCODE -ne 0) { throw 'Terraform tests failed.' }
Write-Host 'PASS: all local DR regression and session tests.'

[CmdletBinding()]
param(
    [guid]$SourceA,
    [guid]$TargetA,
    [guid]$SourceB,
    [guid]$TargetB,
    [ValidateSet('TwoPairs', 'SinglePair')] [string]$Mode = 'TwoPairs',
    [string]$Suffix = '-DR'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ((git -C $root branch --show-current) -ne 'feature/multisubscription-dr') {
    throw 'Lab preflight must run from the isolated feature branch.'
}
$subscriptions = @(az account list --refresh --all -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Azure subscription inventory failed.' }
$enabled = @($subscriptions | Where-Object state -eq 'Enabled')
$requiredCount = if ($Mode -eq 'TwoPairs') { 4 } else { 2 }
if ($enabled.Count -lt $requiredCount) {
    throw "Live $Mode lab requires $requiredCount accessible enabled subscriptions; found $($enabled.Count). No Azure writes performed."
}
$ids = if ($Mode -eq 'TwoPairs') { @($SourceA, $TargetA, $SourceB, $TargetB) } else { @($SourceA, $TargetA) }
if (@($ids | Where-Object { $_ -eq [guid]::Empty }).Count -or @($ids | Select-Object -Unique).Count -ne $requiredCount) {
    throw "Provide $requiredCount distinct explicit source/target subscription IDs."
}
$selected = @($enabled | Where-Object { $_.id -in @($ids | ForEach-Object ToString) })
if ($selected.Count -ne $requiredCount -or @($selected.tenantId | Select-Object -Unique).Count -ne 1) {
    throw 'All approved lab subscriptions must be accessible and belong to one tenant.'
}
Import-Module (Join-Path $root 'function-app/Modules/DRCore/DRCore.psm1') -Force
$catalog = @($enabled | ForEach-Object {
    [pscustomobject]@{ Id = $_.id; Name = $_.name; TenantId = $_.tenantId; State = $_.state }
})
$pairs = @([pscustomobject]@{ Source = $SourceA; Target = $TargetA })
if ($Mode -eq 'TwoPairs') { $pairs += [pscustomobject]@{ Source = $SourceB; Target = $TargetB } }
foreach ($pair in $pairs) {
    $source = $catalog | Where-Object Id -eq $pair.Source.ToString()
    $resolved = Resolve-DRSubscription -SourceSubscription $source -Subscriptions $catalog -Suffix $Suffix
    if ($resolved.Id -ne $pair.Target.ToString()) {
        throw 'Resolved DR does not match the explicitly approved target ID.'
    }
}
Write-Host "PASS: $Mode mode, $requiredCount distinct subscription IDs and naming/tenant pairs validated. No Azure writes performed."
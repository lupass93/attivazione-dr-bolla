. (Join-Path $PSScriptRoot 'SessionTestSupport.ps1')
$labels = @(
    @('SISTEMICO (RTO 2 ore)', 'sistemico', 1),
    @('Sistemico (RTO 2 ore)', 'sistemico', 1),
    @('Sistemico (2h)', 'sistemico', 1),
    @('Altamente critico (RTO <= 48 ore)', 'altamente-critico', 2),
    @('Altamente critico (4h  adatto a RTO 4  8  24 o 48h)', 'altamente-critico', 2),
    @('Critico (RTO da 72 a 360 ore)', 'critico', 3),
    @('Critico (72h  adatto a RTO 72  120 o 360h)', 'critico', 3),
    @('Non critico (best effort  adatto a RTO oltre le 360h)', 'non-critico', 4),
    @('Non critico (RTO oltre le 360 ore)', 'non-critico', 4)
)
foreach ($label in $labels) {
    $actual = Resolve-DRCriticality $label[0]
    Assert-Test ($actual.Class -eq $label[1] -and $actual.Priority -eq $label[2]) "Unsupported customer label: $($label[0])"
}
$normalized = Resolve-DRCriticality "  ALtamente   critico (4h   adatto a RTO 4  8  24 o 48h)  "
Assert-Test ($normalized.Priority -eq 2) 'Case and repeated spaces must not change the priority.'
$id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$header = 'Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName'
foreach ($invalid in @(
    "$header`nIgnoto,APP01,source,rg,vm",
    "$header`n,APP01,source,rg,vm",
    "$header`nSistemico (2h),,source,rg,vm",
    "SourceSubscription,SourceResourceGroup,SourceVmName`nsource,rg,vm",
    "Acronimo,Criticita,SourceSubscription,SourceResourceGroup,SourceVmName`nAPP01,Sistemico (2h),source,rg,vm"
)) {
    Set-TestCsv $invalid
    $response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' }
    Assert-Test ([int]$response.StatusCode -eq 400) 'Invalid metadata or layout must reject the entire request.'
}
Assert-Test ($global:QueueMessages.Count -eq 0) 'No invalid CSV may enqueue work.'
Set-TestCsv "'Criticita','Acronimo',SourceSubscription,SourceResourceGroup,SourceVmName`nSistemico (2h),APP01,source,rg,vm"
$csv = Read-DRCsvRequest $global:TestClient 'vms.csv'
Assert-Test ($csv.rows[0].Acronimo -eq 'APP01') 'The customer single-quoted header names must be supported.'
$unordered = @(
    $header,
    'Non critico (RTO oltre le 360 ore),APP04,source,rg,vm-non-1',
    'Critico (RTO da 72 a 360 ore),APP03,source,rg,vm-crit-1',
    'Altamente critico (RTO <= 48 ore),APP02,source,rg,vm-high-1',
    'Sistemico (2h),APP01,source,rg,vm-sys-1',
    'Non critico (RTO oltre le 360 ore),APP04,source,rg,vm-non-2',
    'Sistemico (2h),APP01,source,rg,vm-sys-2',
    'Altamente critico (RTO <= 48 ore),APP02,source,rg,vm-high-2',
    'Critico (RTO da 72 a 360 ore),APP03,source,rg,vm-crit-2'
) -join "`n"
Set-TestCsv $unordered
$response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' }
Assert-Test ([int]$response.StatusCode -eq 202) 'A valid mixed-priority request must be accepted.'
$expected = 'vm-sys-1,vm-sys-2,vm-high-1,vm-high-2,vm-crit-1,vm-crit-2,vm-non-1,vm-non-2'
$manifest = (Read-DRDocument $global:TestClient "sessions/$id/request.json").Value
Assert-Test (($manifest.rows.SourceVmName -join ',') -eq $expected) 'The immutable plan must be sorted, with CSV order retained for ties.'
Assert-Test (($manifest.rows.CsvRow -join ',') -eq '4,6,3,7,2,8,1,5') 'The original CSV positions must remain traceable.'
$planned = (Get-DRSessionState $global:TestClient $id).Value
Assert-Test (($planned.results.activationOrder -join ',') -eq '1,2,3,4,5,6,7,8') 'The published execution positions must be deterministic.'
Set-TestCsv "$header`nSistemico (2h),OTHER,source,rg,changed"
Invoke-TestWorker $id -NativePayload
$calls = @($global:CoreCalls)
Assert-Test ($calls.Count -eq 16 -and @($calls[0..7] | Where-Object preflight -eq $false).Count -eq 0) 'All eight preflights must precede every activation.'
$activations = @($calls | Where-Object preflight -eq $false)
Assert-Test (($activations.vm -join ',') -eq $expected) 'The actual core invocations must follow all four priority classes, not the input order.'
Assert-Test ($activations[0].acronimo -eq 'APP01' -and $activations[-1].acronimo -eq 'APP04') 'Metadata must reach the real replication entry point.'
$state = (Get-DRSessionState $global:TestClient $id).Value
Assert-Test ($state.results[0].startedAt -and $state.results[-1].completedAt) 'Activation timestamps must be persisted.'
Assert-Test ($state.running -eq 'false' -and $state.sistemico.resource_completed_count -ceq '2') 'The persisted JSON log must contain the compatible completed report.'
$failedId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
Set-TestCsv $unordered
Invoke-TestSubmission @{ sessionId = $failedId; csvBlobPath = 'vms.csv' } | Out-Null
$global:ReplicationFailures = @('vm-high-1')
$before = $global:CoreCalls.Count
try { Invoke-TestWorker $failedId; throw 'Expected replication failure.' }
catch { if ($_.Exception.Message -notlike '*DR replication failed*') { throw } }
$failedCalls = @($global:CoreCalls | Select-Object -Skip $before | Where-Object preflight -eq $false)
Assert-Test (($failedCalls.vm -join ',') -eq $expected) 'A failed activation must not change ordering or skip unrelated lower-priority attempts.'
$failedState = (Get-DRSessionState $global:TestClient $failedId).Value
Assert-Test ($failedState.status -eq 'FAILED' -and $failedState.'altamente-critico'.resource_error_count -ceq '1') 'A priority-class failure must be reflected in the persistent customer report.'
Write-Host "PASS: $global:TestCount CSV validation and actual priority-order checks; no Azure calls."

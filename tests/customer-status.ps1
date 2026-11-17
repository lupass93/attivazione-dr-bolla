. (Join-Path $PSScriptRoot 'SessionTestSupport.ps1')
$id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
Set-TestCsv (@(
    'Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName',
    'Sistemico (2h),APP01,source-a,rg,vm-same',
    'Sistemico (2h),APP02,source-b,rg,vm-same',
    'Altamente critico (RTO <= 48 ore),APP03,source-a,rg,vm-fail',
    'Critico (RTO da 72 a 360 ore),APP04,source-a,rg,vm-wait',
    'Non critico (RTO oltre le 360 ore),APP05,source-a,rg,vm-later'
) -join "`n")
Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' } | Out-Null
$state = (Get-DRSessionState $global:TestClient $id).Value
$state.status = 'RUNNING'
$state.results[0].status = 'SUCCEEDED'
$state.results[1].status = 'SUCCEEDED'
$state.results[2].status = 'FAILED'
$state.results[2].error = 'Azure disk creation failed.'
$state.results[3].status = 'RUNNING'
$state.results[4].status = 'NOT_STARTED'
Update-DRSessionState $global:TestClient $id -Changes @{ status = $state.status; results = $state.results } | Out-Null
$response = Get-DRSessionResponse (Get-DRSessionState $global:TestClient $id).Value
$wire = $response | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
$rootFields = @('sessionId', 'status', 'phase', 'createdAt', 'acceptedAt', 'startedAt', 'updatedAt', 'completedAt',
    'queueConfirmed', 'requiresReview', 'error', 'csvBlobPath', 'csvSha256', 'vmCount', 'results', 'summary',
    'schemaVersion', 'platform', 'id', 'activity', 'running', 'sistemico', 'altamente-critico', 'critico', 'non-critico')
Assert-Test ((($wire.Keys | Sort-Object) -join ',') -ceq (($rootFields | Sort-Object) -join ',')) 'Technical audit changes must not add, remove or rename status response fields.'
$rowFields = @('sourceSubscription', 'sourceResourceGroup', 'vmName', 'sourceSubscriptionId', 'targetSubscriptionId',
    'status', 'error', 'criticita', 'acronimo', 'priorityClass', 'priority', 'csvRow', 'activationOrder', 'resourceKey',
    'startedAt', 'completedAt')
Assert-Test ((($wire.results[0].Keys | Sort-Object) -join ',') -ceq (($rowFields | Sort-Object) -join ',')) 'Per-VM response fields must preserve the existing Azure/customer contract.'
Assert-Test ($wire.id -eq $id -and $wire.sessionId -eq $id -and $wire.activity -eq 'dr-activation') 'Client ID and Azure activity must remain unambiguous.'
Assert-Test ($wire.running -is [string] -and $wire.running -ceq 'true') 'The legacy running field must retain its string type.'
foreach ($class in @('sistemico', 'altamente-critico', 'critico', 'non-critico')) {
    $group = $wire[$class]
    foreach ($count in @('resource_completed_count', 'resource_pending_count', 'resource_error_count', 'resource_total')) {
        Assert-Test ($group[$count] -is [string]) "Counter $class/$count must be a string as in the customer example."
    }
    Assert-Test ($group.resource_completed -is [array] -and $group.resource_pending -is [array]) 'Resource lists must remain arrays even when empty.'
    Assert-Test (([int]$group.resource_completed_count + [int]$group.resource_pending_count + [int]$group.resource_error_count) -eq [int]$group.resource_total) 'Each VM must belong to exactly one progress category.'
}
Assert-Test ($wire.sistemico.resource_completed_count -ceq '2' -and $wire.sistemico.resource_completed[0] -ne $wire.sistemico.resource_completed[1]) 'Azure VM homonyms must not collide.'
Assert-Test ($wire.'altamente-critico'.resource_error['source-a/rg/vm-fail'] -eq 'Azure disk creation failed.') 'Error maps must retain the Azure workload key and error string.'
Assert-Test ($wire.'non-critico'.resource_pending_count -ceq '1') 'A terminally unstarted VM is pending, never completed.'
$persisted = (Get-DRSessionState $global:TestClient $id).Value
Assert-Test (($persisted.sistemico | ConvertTo-Json -Compress) -eq ($wire.sistemico | ConvertTo-Json -Compress)) 'Stored JSON log and API projection must have the same customer counters.'
Update-DRSessionState $global:TestClient $id -Changes @{ status = 'FAILED' } | Out-Null
Assert-Test ((Get-DRSessionResponse (Get-DRSessionState $global:TestClient $id).Value).running -ceq 'false') 'A stopped session must report false even with pending resources.'
$legacy = @{
    schemaVersion = 1; sessionId = $id; status = 'SUCCEEDED'; phase = 'Completed'; results = @()
    createdAt = ''; acceptedAt = ''; startedAt = ''; updatedAt = ''; completedAt = ''
    queueConfirmed = $true; requiresReview = $false; error = $null; csvBlobPath = ''; csvSha256 = ''
}
$old = Get-DRSessionResponse $legacy
Assert-Test ($old.sessionId -eq $id -and -not $old.Contains('sistemico')) 'Old session history must retain its Azure shape without inventing missing criticality.'
$invalidState = (Get-DRSessionState $global:TestClient $id).Value
$invalidState.results[0].priorityClass = 'unknown'
$rejected = $false
try { Get-DRSessionResponse $invalidState | Out-Null }
catch { $rejected = $_.Exception.Message -like '*invalid priority metadata*' }
Assert-Test $rejected 'Corrupted metadata must not silently disappear from the four customer buckets.'
& (Get-Module DRCore) {
    $script:LogMetadata = @{ SessionId = 'test-session'; Criticita = 'Sistemico (2h)'; Acronimo = 'APP01' }
    $script:LogBuffer = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    Write-Log 'Azure stage probe.' -VmName 'vm-test'
    $line = @($script:LogBuffer)[0]
    if ($line -notlike '*sessionId=test-session*Criticita=Sistemico (2h)*Acronimo=APP01*Azure stage probe*') {
        throw 'Azure stage logs must carry the session, criticality and application acronym.'
    }
}
Write-Host "PASS: $global:TestCount customer JSON contract and Azure metadata checks; no Azure calls."

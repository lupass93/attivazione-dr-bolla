[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CsvBlobPath,
    [Parameter(Mandatory = $true)][string]$TargetSubscriptionId,
    [Parameter(Mandatory = $true)][string]$TargetResourceGroup
)

. (Join-Path $PSScriptRoot 'LiveTestSupport.ps1')
Initialize-LiveDRTest
$id = [guid]::NewGuid().ToString('D')
try {
    $before = @(Get-LiveDRWorkloadIds $TargetSubscriptionId $TargetResourceGroup)
    $response = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$id" -Unauthenticated
    Assert-LiveDR ($response.Code -eq 401) 'The preflight test requires authenticated status access.'
    $accepted = Invoke-LiveDRRequest Invoke-DRReplication -Method POST `
        -Body (@{ sessionId = $id; csvBlobPath = $CsvBlobPath } | ConvertTo-Json)
    Assert-LiveDR ($accepted.Code -eq 202 -and $accepted.Json.queueConfirmed) 'The private queue must confirm acceptance before 202.'
    $completed = Wait-LiveDRSession $id
    Assert-LiveDR ($completed.State.status -eq 'FAILED' -and $completed.State.phase -eq 'Preflight') 'A missing prerequisite must fail before replication.'
    Assert-LiveDR (@($completed.State.results | Where-Object { $_.error -like '*ASG*' }).Count -gt 0) 'The missing ASG must be reported explicitly.'
    $after = @(Get-LiveDRWorkloadIds $TargetSubscriptionId $TargetResourceGroup)
    Assert-LiveDR (($before -join "`n") -eq ($after -join "`n")) 'Failed preflight must not create disks, NICs, VMs or snapshots.'
    $persisted = Read-LiveDRBlob $script:LiveOutputs.session_container_name.value "sessions/$id/state.json"
    Assert-LiveDR ($persisted.sessionId -eq $id -and $persisted.status -eq 'FAILED') 'The failed session must be persisted, not inferred from logs.'
    Save-LiveDREvidence 'preflight' @{
        sessionId = $id; acceptedSeconds = $accepted.DurationSeconds; state = $completed.State
        observedStates = $completed.Observed; before = $before; after = $after
    }
}
finally { $script:LiveHeaders.Clear() }

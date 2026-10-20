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
    $response = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$id" -Unauthenticated
    Assert-LiveDR ($response.Code -eq 401) 'Missing credentials must not expose session state.'
    $body = @{ sessionId = $id; csvBlobPath = $CsvBlobPath } | ConvertTo-Json
    $accepted = Invoke-LiveDRRequest Invoke-DRReplication -Method POST -Body $body
    Assert-LiveDR ($accepted.Code -eq 202 -and $accepted.Json.sessionId -eq $id -and $accepted.Json.queueConfirmed) 'Invoke must confirm the client-generated session.'
    Assert-LiveDR ($accepted.Json.status -notin @('SUCCEEDED', 'FAILED')) 'The initial HTTP response must not wait for this fresh replication.'
    $manifest = Read-LiveDRBlob $script:LiveOutputs.session_container_name.value "sessions/$id/request.json"
    Assert-LiveDR ($manifest.sessionId -eq $id -and $manifest.rows.Count -gt 0) 'The original request must be durable before processing.'
    $repeated = Invoke-LiveDRRequest Invoke-DRReplication -Method POST -Body $body
    Assert-LiveDR ($repeated.Code -in @(200, 202) -and $repeated.Json.sessionId -eq $id) 'An uncertain request must be safely repeatable with the same ID.'
    $completed = Wait-LiveDRSession $id
    Assert-LiveDR ($completed.State.status -eq 'SUCCEEDED') "Replication failed: $($completed.State.error)"
    Assert-LiveDR ([datetime]$completed.State.completedAt -gt [datetime]$accepted.ReceivedAtUtc) 'Replication must complete after HTTP acceptance in this fresh-create test.'
    $persisted = Read-LiveDRBlob $script:LiveOutputs.session_container_name.value "sessions/$id/state.json"
    Assert-LiveDR ($persisted.status -eq 'SUCCEEDED' -and $persisted.sessionId -eq $id) 'The terminal result must be persisted under the same session.'
    $resourceChecks = @(Test-LiveDRResources $TargetSubscriptionId $TargetResourceGroup $completed.State.results)
    $unknown = [guid]::NewGuid().ToString('D')
    $response = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$unknown"
    Assert-LiveDR ($response.Code -eq 404) 'An unknown session must not inherit this successful result.'
    Save-LiveDREvidence 'session' @{
        sessionId = $id; acceptedSeconds = $accepted.DurationSeconds; processingSeconds = $completed.DurationSeconds
        observedStates = $completed.Observed; state = $completed.State; resourceChecks = @($resourceChecks)
    }
}
finally { $script:LiveHeaders.Clear() }

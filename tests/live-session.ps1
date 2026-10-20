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
    $resourceChecks = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $completed.State.results) {
        $text = az vm get-instance-view --subscription $TargetSubscriptionId --resource-group $TargetResourceGroup `
            --name $row.vmName --query '{states:instanceView.statuses[].code,agent:instanceView.vmAgent.statuses[].displayStatus}' -o json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Direct VM status verification failed.' }
        $vm = ($text -join "`n") | ConvertFrom-Json -AsHashtable
        Assert-LiveDR ('PowerState/running' -in $vm.states -and 'ProvisioningState/succeeded' -in $vm.states -and 'Ready' -in $vm.agent) 'The target VM and guest agent must be operational.'
        $text = az vm show --subscription $TargetSubscriptionId --resource-group $TargetResourceGroup --name $row.vmName `
            --query '{os:storageProfile.osDisk.name,data:storageProfile.dataDisks[].name,nics:networkProfile.networkInterfaces[].id}' -o json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Target VM attachment verification failed.' }
        $attachments = ($text -join "`n") | ConvertFrom-Json -AsHashtable
        foreach ($diskName in @((@($attachments.os) + @($attachments.data)) | Where-Object { $_ })) {
            $text = az disk show --subscription $TargetSubscriptionId --resource-group $TargetResourceGroup --name $diskName `
                --query '{name:name,source:creationData.sourceResourceId,state:provisioningState,des:encryption.diskEncryptionSetId,attached:diskState}' -o json --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'Direct disk verification failed.' }
            $disk = ($text -join "`n") | ConvertFrom-Json -AsHashtable
            Assert-LiveDR ($disk.source -like "/subscriptions/$($row.sourceSubscriptionId)/*/providers/Microsoft.Compute/disks/*" -and
                $disk.state -eq 'Succeeded' -and $disk.attached -eq 'Attached' -and
                $disk.des -like "/subscriptions/$TargetSubscriptionId/*") 'The attached target disk must originate directly from the primary disk and use target encryption.'
            $resourceChecks.Add($disk)
        }
        foreach ($nicId in $attachments.nics) {
            $text = az network nic show --ids $nicId `
                --query '{ip:ipConfigurations[0].privateIPAddress,method:ipConfigurations[0].privateIPAllocationMethod,asgs:ipConfigurations[0].applicationSecurityGroups[].id,pools:ipConfigurations[0].loadBalancerBackendAddressPools[].id}' -o json --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'Direct NIC verification failed.' }
            $nic = ($text -join "`n") | ConvertFrom-Json -AsHashtable
            Assert-LiveDR ($nic.method -eq 'Static' -and $nic.asgs.Count -gt 0 -and $nic.pools.Count -gt 0) 'The target NIC must retain its static IP, ASG and backend association.'
            $resourceChecks.Add($nic)
        }
    }
    $snapshots = az snapshot list --subscription $TargetSubscriptionId --resource-group $TargetResourceGroup --query 'length(@)' -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Snapshot absence verification failed.' }
    Assert-LiveDR ([int]$snapshots -eq 0) 'The direct-copy path must not create snapshots.'
    $unknown = [guid]::NewGuid().ToString('D')
    $response = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$unknown"
    Assert-LiveDR ($response.Code -eq 404) 'An unknown session must not inherit this successful result.'
    Save-LiveDREvidence 'session' @{
        sessionId = $id; acceptedSeconds = $accepted.DurationSeconds; processingSeconds = $completed.DurationSeconds
        observedStates = $completed.Observed; state = $completed.State; resourceChecks = @($resourceChecks)
    }
}
finally { $script:LiveHeaders.Clear() }

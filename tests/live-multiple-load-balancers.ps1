[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][ValidateSet('QueueFailure', 'MissingPool', 'Success', 'Reuse')][string]$Scenario
)

. (Join-Path $PSScriptRoot 'LiveTestSupport.ps1')
$configuration = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json -AsHashtable
$lab = $configuration.lab
$accountText = az account show --output json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Azure user authentication is unavailable.' }
$account = ($accountText -join "`n") | ConvertFrom-Json -AsHashtable
if ($account.tenantId -ne $lab.tenantId -or $account.user.name -ne $lab.operatorUser -or $account.user.type -ne 'user') {
    throw 'The live test must use the explicitly approved lab tenant and user.'
}
foreach ($subscription in @($lab.sourceSubscriptionId, $lab.targetSubscriptionId, $configuration.hosting_subscription_id.value) | Sort-Object -Unique) {
    $text = az account show --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'An approved test subscription is not accessible.' }
    $selected = ($text -join "`n") | ConvertFrom-Json -AsHashtable
    if ($selected.tenantId -ne $lab.tenantId -or $selected.user.name -ne $lab.operatorUser -or $selected.user.type -ne 'user') {
        throw 'Cross-tenant or other-user live tests are forbidden.'
    }
}
Initialize-LiveDRTest -ConfigurationPath $ConfigurationPath
if (-not $script:LiveOutputs.function_app_name.value.StartsWith('func-dr-mlb-')) { throw 'This test is restricted to the isolated multiple-LB lab.' }
foreach ($group in @(
        @{ subscription = $script:LiveSubscription; name = $script:LiveOutputs.resource_group_name.value },
        @{ subscription = $lab.sourceSubscriptionId; name = $lab.sourceResourceGroup },
        @{ subscription = $lab.sourceSubscriptionId; name = $lab.sourceNicResourceGroup },
        @{ subscription = $lab.targetSubscriptionId; name = $lab.targetResourceGroup },
        @{ subscription = $lab.targetSubscriptionId; name = $lab.targetNicResourceGroup },
        @{ subscription = $lab.targetSubscriptionId; name = $lab.targetInternalLbResourceGroup })) {
    $text = az group show --subscription $group.subscription --name $group.name --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'A required lab group is not accessible.' }
    $resource = ($text -join "`n") | ConvertFrom-Json -AsHashtable
    if ($resource.tags.purpose -ne 'multiple-lb-validation') { throw 'Refusing to mutate a group not tagged for this test.' }
}
$id = [guid]::NewGuid().ToString('D')
$csvPath = "dr-tests/multiple-lb-$($Scenario.ToLowerInvariant())-$id.csv"
$vmName = if ($Scenario -eq 'QueueFailure') { 'vm-mlb-deliberately-missing' } else { $lab.sourceVmName }
$csv = "Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName`nSistemico (2h),APP-MLB,$($lab.sourceSubscriptionId),$($lab.sourceResourceGroup),$vmName"
$body = @{ sessionId = $id; csvBlobPath = $csvPath } | ConvertTo-Json -Compress
$changedQueue = $false
$removedPool = $false
$state = $null
$evidence = $null
$classes = @('sistemico', 'altamente-critico', 'critico', 'non-critico')

function Assert-LiveCustomerContract {
    param([System.Collections.IDictionary]$State)
    Assert-LiveDR ($State.sessionId -eq $id -and $State.id -eq $id -and $State.schemaVersion -eq 2) 'The existing customer/Azure session identifiers and schema must be preserved.'
    Assert-LiveDR ($State.running -is [string] -and $State.activity -ceq 'dr-activation') 'The legacy root fields must preserve their types and Azure meaning.'
    foreach ($class in $classes) {
        $bucket = $State[$class]
        foreach ($name in @('resource_completed_count', 'resource_pending_count', 'resource_error_count', 'resource_total')) {
            Assert-LiveDR ($bucket[$name] -is [string]) "Customer counter $class/$name must remain a string."
        }
        Assert-LiveDR ($bucket.resource_completed -is [array] -and $bucket.resource_pending -is [array] -and
            $bucket.resource_error -is [System.Collections.IDictionary]) 'Customer arrays and error maps must retain their JSON types.'
        Assert-LiveDR (([int]$bucket.resource_completed_count + [int]$bucket.resource_pending_count + [int]$bucket.resource_error_count) -eq
            [int]$bucket.resource_total) 'Customer counters must partition every VM.'
    }
}

function Read-LiveOperationAudit {
    param([string]$FunctionName)
    $deadline = [datetime]::UtcNow.AddMinutes(2)
    do {
        $namesText = az storage blob list --subscription $script:LiveSubscription --account-name $script:LiveStorage `
            --container-name $script:LiveOutputs.log_container_name.value --prefix "sessions/$id/$FunctionName-" `
            --auth-mode login --query '[].name' --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Operation audit discovery failed.' }
        $names = @(($namesText -join "`n") | ConvertFrom-Json)
        if ($names.Count -gt 0) { break }
        Start-Sleep -Seconds 3
    } while ([datetime]::UtcNow -lt $deadline)
    Assert-LiveDR ($names.Count -gt 0) "A durable $FunctionName audit must exist."
    $text = ($names | ForEach-Object { Read-LiveDRTextBlob $script:LiveOutputs.log_container_name.value $_ }) -join "`n"
    Assert-LiveDR ($text.Contains("sessionId=$id")) 'Operation audits must retain the session metadata prefix.'
    $events = @($text -split "`n" | Where-Object { $_ -match ' AUDIT ' } |
        ForEach-Object { ($_ -split ' AUDIT ', 2)[1] | ConvertFrom-Json -AsHashtable })
    foreach ($event in $events) {
        Assert-LiveDR ($event.sessionId -eq $id -and $event.timestamp -and $event.status -and $event.operation) 'Audit records must be attributable and readable.'
        if ($event.plane -eq 'Control' -and $event.operation -notin @('Get-AzSubscription')) {
            Assert-LiveDR ($event.identityClientId -and $event.resourceId) 'Every code-issued control operation needs an identity and resource scope.'
        }
        if ($event.plane -eq 'Data' -and $event.operation -like 'Storage *') {
            Assert-LiveDR ($event.resourceGroup -eq $script:LiveOutputs.resource_group_name.value -and $event.identityClientId) 'Storage action audits must include the real storage group and managed identity.'
        }
    }
    Assert-LiveDR ($text -notmatch 'Bearer\s+eyJ|AccountKey=(?!\[REDACTED\])|[?&]sig=(?!\[REDACTED\])') 'Audits must not contain credentials.'
    return @{ blobs = $names; events = $events }
}

try {
    $unauthorized = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$id" -Unauthenticated
    Assert-LiveDR ($unauthorized.Code -eq 401) 'The new diagnostic history must not weaken HTTP authentication.'
    $before = @((Get-LiveDRWorkloadIds $lab.targetSubscriptionId $lab.targetResourceGroup) +
        (Get-LiveDRWorkloadIds $lab.targetSubscriptionId $lab.targetNicResourceGroup) | Sort-Object)
    if ($Scenario -ne 'Reuse') { Assert-LiveDR ($before.Count -eq 0) 'Creation and negative cases require an empty target workload.' }
    else { Assert-LiveDR ($before.Count -gt 0) 'Reuse requires the preceding successful fixture.' }
    Write-LiveDRCsv -Content $csv -Path $csvPath
    if ($Scenario -eq 'QueueFailure') {
        az functionapp config appsettings set --subscription $script:LiveSubscription --resource-group $script:LiveOutputs.resource_group_name.value `
            --name $script:LiveOutputs.function_app_name.value --settings DR_QUEUE_NAME=dr-tests-deliberately-missing --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'The lab-only queue fault could not be configured.' }
        $changedQueue = $true
        Start-Sleep -Seconds 20
        $failed = Invoke-LiveDRRequest Invoke-DRReplication -Method POST -Body $body
        Assert-LiveDR ($failed.Code -eq 503 -and $failed.Json.Keys.Count -eq 1 -and $failed.Json.error -like 'Queue acceptance could not be confirmed.*') 'Queue failures must retain the exact existing client error shape.'
        $pending = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$id"
        Assert-LiveDR ($pending.Code -eq 200 -and $pending.Json.status -eq 'PENDING' -and -not $pending.Json.queueConfirmed) 'An unconfirmed queue request must remain PENDING.'
        Assert-LiveCustomerContract $pending.Json
        $audit = Read-LiveOperationAudit Invoke-DRReplication
        Assert-LiveDR (@($audit.events | Where-Object { $_.operation -eq 'Queue acknowledgement' -and $_.status -eq 'Failed' -and $_.error }).Count -gt 0) 'The original queue failure must be durable before any worker runs.'
        az functionapp config appsettings set --subscription $script:LiveSubscription --resource-group $script:LiveOutputs.resource_group_name.value `
            --name $script:LiveOutputs.function_app_name.value --settings DR_QUEUE_NAME=dr-activation --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Queue settings restoration failed.' }
        $changedQueue = $false
        Start-Sleep -Seconds 20
    }
    if ($Scenario -eq 'MissingPool') {
        az network lb address-pool delete --subscription $lab.targetSubscriptionId --resource-group $lab.targetInternalLbResourceGroup `
            --lb-name $lab.targetInternalLbName --name api --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'The test-owned missing-pool fixture could not be prepared.' }
        $removedPool = $true
    }
    $accepted = Invoke-LiveDRRequest Invoke-DRReplication -Method POST -Body $body
    Assert-LiveDR ($accepted.Code -eq 202 -and $accepted.Json.queueConfirmed -and $accepted.Json.sessionId -eq $id) 'Every accepted request must confirm its actual queue write.'
    Assert-LiveCustomerContract $accepted.Json
    $finished = Wait-LiveDRSession $id
    $state = $finished.State
    Assert-LiveCustomerContract $state
    $expected = if ($Scenario -in @('MissingPool', 'QueueFailure')) { 'FAILED' } else { 'SUCCEEDED' }
    Assert-LiveDR ($state.status -eq $expected) "Unexpected terminal state: $($state.status), $($state.error)"
    $audit = Read-LiveOperationAudit Process-DRSession
    if ($expected -eq 'FAILED') {
        Assert-LiveDR ($state.phase -eq 'Preflight') 'The negative fixture must fail before replication.'
        if ($Scenario -eq 'MissingPool') {
            Assert-LiveDR ($state.results[0].error.Contains($lab.targetInternalLbResourceGroup) -and
                $state.results[0].error.Contains("Required backend pool 'api' is missing")) 'The negative case must fail specifically because the second Load Balancer pool is missing.'
        } else {
            Assert-LiveDR ($state.results[0].error.Contains('vm-mlb-deliberately-missing') -and
                $state.results[0].error.Contains('ResourceNotFound')) 'The recovered queue must fail only on its deliberately absent test VM.'
        }
        $after = @((Get-LiveDRWorkloadIds $lab.targetSubscriptionId $lab.targetResourceGroup) +
            (Get-LiveDRWorkloadIds $lab.targetSubscriptionId $lab.targetNicResourceGroup) | Sort-Object)
        Assert-LiveDR ($after.Count -eq 0) 'Failed global preflight must not create disks, NICs or VMs.'
        Assert-LiveDR (@($audit.events | Where-Object { $_.operation -in @('New-AzDisk', 'New-AzNetworkInterface', 'New-AzVM') }).Count -eq 0) 'No workload CREATE operation is allowed during preflight.'
    } else {
        $resources = @(Test-LiveDRResources $lab.targetSubscriptionId $lab.targetResourceGroup $state.results)
        $nicId = "/subscriptions/$($lab.targetSubscriptionId)/resourceGroups/$($lab.targetNicResourceGroup)/providers/Microsoft.Network/networkInterfaces/$($lab.sourceVmName)-nic"
        $nicText = az network nic show --ids $nicId --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'The DR NIC must be located in its source-derived group.' }
        $nic = ($nicText -join "`n") | ConvertFrom-Json -AsHashtable
        Assert-LiveDR ($nic.ipConfigurations.Count -eq 2) 'Both IP configurations must be preserved.'
        $poolIds = @($nic.ipConfigurations | ForEach-Object { @($_.loadBalancerBackendAddressPools | ForEach-Object id) })
        Assert-LiveDR ($poolIds.Count -eq 3 -and @($poolIds | Where-Object { $_ -like "*/$($lab.targetInternalLbResourceGroup)/*" }).Count -eq 1) 'All three associations across two homonymous LBs must exist.'
        Assert-LiveDR ($nic.networkSecurityGroup.id -like "*/rg-mlb-nsg-DR/*") 'The NIC must reference the independently grouped DR NSG.'
        foreach ($ip in $nic.ipConfigurations) {
            Assert-LiveDR ($ip.applicationSecurityGroups[0].id -like "*/rg-mlb-asg-DR/*") 'Each IP configuration must retain its ASG in the correct group.'
        }
        $discovery = @($audit.events | Where-Object operation -eq 'Discover VM and networking configuration')
        Assert-LiveDR ($discovery.Count -ge 2 -and $discovery[0].details.sourceNic.resourceGroup -eq $lab.sourceNicResourceGroup) 'Both preflight and replication must record the discovered source configuration.'
        Assert-LiveDR (@($audit.events | Where-Object operation -eq 'Discover OS and data disks and select DR encryption').Count -ge 2) 'OS/data disk and DES selection history must be logged.'
        foreach ($action in @($audit.events | Where-Object { $_.plane -eq 'Control' -and $_.operation -in @('New-AzDisk', 'New-AzNetworkInterface', 'New-AzVM', 'Set-AzNetworkInterface') })) {
            Assert-LiveDR ($action.subscriptionId -eq $lab.targetSubscriptionId) 'Every workload write must target the approved DR subscription.'
        }
        $workloadPrefix = "$($lab.sourceSubscriptionId)/$($lab.sourceResourceGroup)/$($lab.sourceVmName)/".ToLowerInvariant()
        $prefix = "$workloadPrefix$id-stageCompleted"
        $namesText = az storage blob list --subscription $script:LiveSubscription --account-name $script:LiveStorage `
            --container-name $script:LiveOutputs.log_container_name.value --prefix $prefix `
            --auth-mode login --query '[].name' --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Existing stage-log compatibility could not be verified.' }
        $completionLogs = @(($namesText -join "`n") | ConvertFrom-Json)
        Assert-LiveDR ($completionLogs.Count -eq 1) 'The existing VM completion stage-log filename must still be produced.'
        $completion = Read-LiveDRTextBlob $script:LiveOutputs.log_container_name.value $completionLogs[0]
        Assert-LiveDR ($completion.Contains("sessionId=$id") -and $completion.Contains('Criticita=Sistemico (2h)') -and
            $completion.Contains('Acronimo=APP-MLB')) 'Existing stage logs must retain the customer metadata and text format.'
        if ($Scenario -eq 'Reuse') {
            $after = @((Get-LiveDRWorkloadIds $lab.targetSubscriptionId $lab.targetResourceGroup) +
                (Get-LiveDRWorkloadIds $lab.targetSubscriptionId $lab.targetNicResourceGroup) | Sort-Object)
            Assert-LiveDR (($before -join "`n") -eq ($after -join "`n")) 'Resource reuse must not create duplicates.'
            Assert-LiveDR (@($audit.events | Where-Object { $_.operation -in @('New-AzDisk', 'New-AzNetworkInterface', 'New-AzVM', 'Set-AzNetworkInterface') }).Count -eq 0) 'A complete reuse case must not rewrite the workload.'
        }
    }
    $stored = Read-LiveDRBlob $script:LiveOutputs.session_container_name.value "sessions/$id/state.json"
    foreach ($class in $classes) {
        Assert-LiveDR (($stored[$class] | ConvertTo-Json -Depth 10 -Compress) -eq
            ($state[$class] | ConvertTo-Json -Depth 10 -Compress)) 'Persisted customer counters must equal Get-DRStatus.'
    }
    $post = Invoke-LiveDRRequest Get-DRStatus -Method POST -Body (@{ sessionId = $id } | ConvertTo-Json)
    Assert-LiveDR ($post.Code -eq 200 -and $post.Json.status -eq $expected) 'The existing POST status endpoint must remain compatible.'
    $replay = Invoke-LiveDRRequest Invoke-DRReplication -Method POST -Body $body
    Assert-LiveDR ($replay.Code -eq 200 -and $replay.Json.status -eq $expected) 'Terminal-session replay must not enqueue new workload.'
    $evidence = @{
        sessionId = $id; scenario = $Scenario; state = $state; workerAuditBlobs = $audit.blobs; auditEventCount = $audit.events.Count
    }
}
finally {
    if ($changedQueue) {
        az functionapp config appsettings set --subscription $script:LiveSubscription --resource-group $script:LiveOutputs.resource_group_name.value `
            --name $script:LiveOutputs.function_app_name.value --settings DR_QUEUE_NAME=dr-activation --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Lab queue restoration failed; manual intervention is required.' }
    }
    if ($removedPool) {
        az network lb address-pool create --subscription $lab.targetSubscriptionId --resource-group $lab.targetInternalLbResourceGroup `
            --lb-name $lab.targetInternalLbName --name api --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Lab backend pool restoration failed; manual intervention is required.' }
    }
    $script:LiveHeaders.Clear()
}
Save-LiveDREvidence "multiple-lb-$($Scenario.ToLowerInvariant())" $evidence

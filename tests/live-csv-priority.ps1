[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CsvBlobPath,
    [Parameter(Mandatory = $true)][string]$TargetSubscriptionId,
    [Parameter(Mandatory = $true)][string]$TargetResourceGroup
)

. (Join-Path $PSScriptRoot 'LiveTestSupport.ps1')
Initialize-LiveDRTest
$id = [guid]::NewGuid().ToString('D')
$state = $null
$classes = @('sistemico', 'altamente-critico', 'critico', 'non-critico')
function Assert-PrioritySnapshot {
    param([System.Collections.IDictionary]$Snapshot)
    Assert-LiveDR ($Snapshot.id -eq $id -and $Snapshot.sessionId -eq $id) 'The customer and Azure session IDs must match the client.'
    Assert-LiveDR ($Snapshot.activity -eq 'dr-activation' -and $Snapshot.running -is [string]) 'The customer root fields must retain the agreed types and Azure activity.'
    foreach ($class in $classes) {
        $group = $Snapshot[$class]
        foreach ($key in @('resource_completed_count', 'resource_pending_count', 'resource_error_count', 'resource_total')) {
            Assert-LiveDR ($group[$key] -is [string]) 'Customer counters must be JSON strings.'
        }
        Assert-LiveDR ($group.resource_completed -is [array] -and $group.resource_pending -is [array]) 'Resource lists must remain JSON arrays.'
        Assert-LiveDR (([int]$group.resource_completed_count + [int]$group.resource_pending_count + [int]$group.resource_error_count) -eq [int]$group.resource_total) 'Customer progress must partition all VM rows.'
    }
    for ($index = 1; $index -lt $Snapshot.results.Count; $index++) {
        $row = $Snapshot.results[$index]
        if ($row.startedAt) {
            $previous = $Snapshot.results[$index - 1]
            Assert-LiveDR ($previous.completedAt -and [datetimeoffset]$row.startedAt -ge [datetimeoffset]$previous.completedAt) 'A lower priority must not start before the preceding attempt finishes.'
        }
    }
}

try {
    $unauthorized = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$id" -Unauthenticated
    Assert-LiveDR ($unauthorized.Code -eq 401) 'The priority report must require caller authentication.'
    $empty = @(Get-LiveDRWorkloadIds $TargetSubscriptionId $TargetResourceGroup)
    Assert-LiveDR ($empty.Count -eq 0) 'This real creation-order test requires an empty target workload.'
    $body = @{ sessionId = $id; csvBlobPath = $CsvBlobPath } | ConvertTo-Json
    $accepted = Invoke-LiveDRRequest Invoke-DRReplication -Method POST -Body $body
    Assert-LiveDR ($accepted.Code -eq 202 -and $accepted.Json.queueConfirmed) 'Priority work must be durably queued before acceptance.'
    Assert-PrioritySnapshot $accepted.Json
    $manifest = Read-LiveDRBlob $script:LiveOutputs.session_container_name.value "sessions/$id/request.json"
    Assert-LiveDR (($manifest.rows.PriorityClass -join ',') -eq ($classes -join ',')) 'The live fixture must contain exactly the four sorted classes.'
    Assert-LiveDR (($manifest.rows.CsvRow -join ',') -eq '4,3,2,1') 'The live fixture must prove reordering of reverse-priority CSV rows.'
    $snapshots = [System.Collections.Generic.List[object]]::new()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $response = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$id"
        Assert-LiveDR ($response.Code -eq 200) 'The current priority state must remain readable.'
        $state = $response.Json
        Assert-PrioritySnapshot $state
        $snapshots.Add(@{
            observedAtUtc = [datetime]::UtcNow.ToString('o')
            status = $state.status; phase = $state.phase; running = $state.running
            rows = @($state.results | ForEach-Object {
                @{ vmName = $_.vmName; priorityClass = $_.priorityClass; status = $_.status; startedAt = $_.startedAt; completedAt = $_.completedAt }
            })
        })
        if ($state.status -in @('SUCCEEDED', 'FAILED')) { break }
        Start-Sleep -Seconds 5
    } while ($watch.Elapsed.TotalSeconds -lt 1200)
    Assert-LiveDR ($state.status -eq 'SUCCEEDED') "Priority replication did not succeed: $($state.error)"
    Assert-LiveDR ($state.running -ceq 'false') 'The legacy running field must become false at completion.'
    foreach ($class in $classes) {
        Assert-LiveDR ($state[$class].resource_completed_count -ceq '1' -and
            $state[$class].resource_pending_count -ceq '0' -and $state[$class].resource_error_count -ceq '0') 'Every class must have its single completed Azure VM.'
    }
    $stored = Read-LiveDRBlob $script:LiveOutputs.session_container_name.value "sessions/$id/state.json"
    foreach ($class in $classes) {
        Assert-LiveDR (($stored[$class] | ConvertTo-Json -Depth 8 -Compress) -eq
            ($state[$class] | ConvertTo-Json -Depth 8 -Compress)) 'Stored JSON log and Get-DRStatus must expose identical class progress.'
    }
    $logChecks = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $state.results) {
        Assert-LiveDR (-not [string]::IsNullOrWhiteSpace($row.acronimo) -and $row.startedAt -and $row.completedAt) 'Application metadata and activation times must be durable.'
        $workloadPrefix = "$($row.sourceSubscriptionId)/$($row.sourceResourceGroup)/$($row.vmName)/".ToLowerInvariant()
        $prefix = "$workloadPrefix$id-stageCompleted"
        $namesText = az storage blob list --subscription $script:LiveSubscription --account-name $script:LiveStorage `
            --container-name $script:LiveOutputs.log_container_name.value --prefix $prefix `
            --auth-mode login --query '[].name' -o json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Stage log discovery failed.' }
        $names = @(($namesText -join "`n") | ConvertFrom-Json)
        Assert-LiveDR ($names.Count -eq 1) 'A successful Azure completion log must exist for every priority class.'
        $text = Read-LiveDRTextBlob $script:LiveOutputs.log_container_name.value $names[0]
        Assert-LiveDR ($text.Contains("Criticita=$($row.criticita)") -and $text.Contains("Acronimo=$($row.acronimo)") -and
            $text.Contains("sessionId=$id")) 'Azure stage logs must preserve customer metadata.'
        $logChecks.Add(@{ vmName = $row.vmName; blob = $names[0]; metadataVerified = $true })
    }
    $resources = @(Test-LiveDRResources $TargetSubscriptionId $TargetResourceGroup $state.results)
    $vms = @($resources | Where-Object { $_.kind -eq 'vm' })
    for ($index = 1; $index -lt $vms.Count; $index++) {
        Assert-LiveDR ([datetimeoffset]$vms[$index].createdAt -ge [datetimeoffset]$vms[$index - 1].createdAt) 'Actual Azure VM creation times must respect the priority plan.'
    }
    $replay = Invoke-LiveDRRequest Invoke-DRReplication -Method POST -Body $body
    Assert-LiveDR ($replay.Code -eq 200 -and $replay.Json.id -eq $id -and $replay.Json.status -eq 'SUCCEEDED') 'A completed priority session must be replay-safe.'
    Save-LiveDREvidence 'csv-priority' @{
        sessionId = $id; acceptedSeconds = $accepted.DurationSeconds; state = $state
        snapshots = @($snapshots); resourceChecks = $resources; logChecks = @($logChecks)
    }
}
catch {
    Write-Host "CSV priority live test failed for session ${id}: $($_.Exception)"
    if ($state) {
        New-Item -ItemType Directory -Path (Join-Path $script:LiveRoot 'out/live') -Force | Out-Null
        $state | ConvertTo-Json -Depth 25 | Set-Content (Join-Path $script:LiveRoot 'out/live/csv-priority-failed.json') -Encoding utf8
    }
    throw
}
finally { $script:LiveHeaders.Clear() }

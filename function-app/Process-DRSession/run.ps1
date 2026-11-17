param($QueueItem, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $appRoot 'Modules/DRSessions/DRSessions.psm1') -ErrorAction Stop
Import-Module (Join-Path $appRoot 'Modules/DRCore/DRCore.psm1') -ErrorAction Stop
Initialize-DRAudit -FunctionName 'Process-DRSession'
$client = $null
$claimed = $false
$sessionId = ''
try {
    $message = if ($QueueItem -is [string]) {
        $QueueItem | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    elseif ($QueueItem -is [System.Collections.IDictionary]) { $QueueItem }
    else { throw 'The DR queue payload must be a JSON object.' }
    $sessionId = ConvertTo-DRSessionId ([string]$message.sessionId)
    Set-DRAuditContext -SessionId $sessionId
    if ($message.schemaVersion -ne 1) { throw 'Unsupported DR queue message schema.' }
    $messageId = [string]$TriggerMetadata.Id
    if ([string]::IsNullOrWhiteSpace($messageId)) { throw 'The queue message ID is required for safe session ownership.' }
    $client = New-DRStorageClient
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $record = Get-DRSessionState $client $sessionId
        if ($null -eq $record) { throw "Session '$sessionId' is not registered." }
        $state = $record.Value
        if ($state.status -in @('SUCCEEDED', 'FAILED')) {
            Write-Host "Session $sessionId is already terminal; duplicate queue delivery ignored."
            return
        }
        if ($state.status -in @('PREFLIGHT', 'RUNNING')) {
            if ($state.messageId -ne $messageId) {
                Write-Host "Session $sessionId is owned by another message; duplicate submission ignored."
                return
            }
            $claimed = $true
            throw 'The worker was interrupted after claiming this session. Automatic replay is disabled; inspect partial resources before creating a new session.'
        }
        $state.status = 'PREFLIGHT'
        $state.phase = 'Preflight'
        $state.messageId = $messageId
        $state.queueConfirmed = $true
        if (-not $state.acceptedAt) { $state.acceptedAt = [datetime]::UtcNow.ToString('o') }
        $state.startedAt = [datetime]::UtcNow.ToString('o')
        $state.updatedAt = $state.startedAt
        if (Write-DRSessionState $client $sessionId $state -ETag $record.ETag) {
            $claimed = $true
            break
        }
        Write-Host "Session $sessionId was claimed concurrently; reading its state again."
    }
    if (-not $claimed) { throw 'Session ownership could not be acquired.' }

    $manifestRecord = Read-DRDocument $client "sessions/$sessionId/request.json"
    if ($null -eq $manifestRecord -or $manifestRecord.Value.sessionId -ne $sessionId) { throw 'The immutable session manifest is missing or invalid.' }
    $manifest = $manifestRecord.Value
    $results = @($state.results)
    if ($manifest.rows.Count -ne $results.Count) { throw 'The manifest and session VM counts do not match.' }
    $targets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $arguments = @{}
    foreach ($key in $manifest.replicationSettings.Keys) { $arguments[$key] = $manifest.replicationSettings[$key] }
    $arguments.LogStorageAccountName = $client.AccountName
    $arguments.SessionId = $sessionId

    for ($index = 0; $index -lt $manifest.rows.Count; $index++) {
        $row = $manifest.rows[$index]
        if ($manifest.schemaVersion -ge 2) {
            $arguments.Criticita = $row.Criticita
            $arguments.Acronimo = $row.Acronimo
        }
        $results[$index].status = 'PREFLIGHT'
        Update-DRSessionState $client $sessionId -OwnerMessageId $messageId -Changes @{ results = $results } | Out-Null
        $check = Invoke-VMReplication @arguments -SourceSubscription $row.SourceSubscription `
            -SourceResourceGroup $row.SourceResourceGroup -SourceVmName $row.SourceVmName -PreflightOnly
        $results[$index].sourceSubscriptionId = $check.SourceSubscriptionId
        $results[$index].targetSubscriptionId = $check.TargetSubscriptionId
        $results[$index].status = if ($check.Status -eq 'Succeeded') { 'PREFLIGHT_PASSED' } else { 'FAILED' }
        $results[$index].error = $check.Error
        if ($check.Status -eq 'Succeeded') {
            $targetKey = "$($check.TargetSubscriptionId)/$($row.SourceResourceGroup)$($arguments.TargetResourceGroupSuffix)/$($row.SourceVmName)"
            if (-not $targets.Add($targetKey)) {
                $results[$index].status = 'FAILED'
                $results[$index].error = 'Multiple CSV rows resolve to the same target VM.'
            }
        }
        Update-DRSessionState $client $sessionId -OwnerMessageId $messageId -Changes @{ results = $results } | Out-Null
    }
    if (@($results | Where-Object status -eq 'FAILED').Count -gt 0) {
        foreach ($result in $results) {
            if ($result.status -eq 'PREFLIGHT_PASSED') { $result.status = 'NOT_STARTED' }
        }
        Update-DRSessionState $client $sessionId -OwnerMessageId $messageId -Changes @{
            status = 'FAILED'; phase = 'Preflight'; results = $results
            error = 'DR prerequisites were not satisfied. No workload resources were created by this session.'
            completedAt = [datetime]::UtcNow.ToString('o')
        } | Out-Null
        throw 'DR preflight failed; inspect the session results and stage logs.'
    }

    Update-DRSessionState $client $sessionId -OwnerMessageId $messageId -Changes @{ status = 'RUNNING'; phase = 'Replication' } | Out-Null
    for ($index = 0; $index -lt $manifest.rows.Count; $index++) {
        $row = $manifest.rows[$index]
        if ($manifest.schemaVersion -ge 2) {
            $arguments.Criticita = $row.Criticita
            $arguments.Acronimo = $row.Acronimo
            $results[$index].startedAt = [datetime]::UtcNow.ToString('o')
        }
        $results[$index].status = 'RUNNING'
        Update-DRSessionState $client $sessionId -OwnerMessageId $messageId -Changes @{ results = $results } | Out-Null
        $result = Invoke-VMReplication @arguments -SourceSubscription $row.SourceSubscription `
            -SourceResourceGroup $row.SourceResourceGroup -SourceVmName $row.SourceVmName
        $results[$index].status = if ($result.Status -eq 'Succeeded') { 'SUCCEEDED' } else { 'FAILED' }
        $results[$index].error = $result.Error
        if ($manifest.schemaVersion -ge 2) { $results[$index].completedAt = [datetime]::UtcNow.ToString('o') }
        Update-DRSessionState $client $sessionId -OwnerMessageId $messageId -Changes @{ results = $results } | Out-Null
    }
    $failed = @($results | Where-Object status -eq 'FAILED').Count -gt 0
    Update-DRSessionState $client $sessionId -OwnerMessageId $messageId -Changes @{
        status = $(if ($failed) { 'FAILED' } else { 'SUCCEEDED' }); phase = 'Completed'
        completedAt = [datetime]::UtcNow.ToString('o'); requiresReview = $failed
        error = $(if ($failed) { 'One or more VM replications failed; inspect results and partial resources.' } else { $null })
    } | Out-Null
    if ($failed) { throw 'DR replication failed; its terminal failure is persisted.' }
    Write-Host "Session $sessionId completed successfully."
}
catch {
    Write-DRAuditEvent -Operation 'Process queued DR session' -Status Failed -ErrorMessage $_.Exception.Message
    if ($claimed) {
        $current = Get-DRSessionState $client $sessionId
        if ($current.Value.status -notin @('SUCCEEDED', 'FAILED')) {
            $remaining = @($current.Value.results)
            foreach ($result in $remaining) {
                if ($result.status -in @('QUEUED', 'PREFLIGHT_PASSED')) { $result.status = 'NOT_STARTED' }
                elseif ($result.status -in @('PREFLIGHT', 'RUNNING')) {
                    $result.status = 'FAILED'
                    $result.error = 'The worker stopped before confirming this VM result. Review the stage logs and Azure resources.'
                }
            }
            Update-DRSessionState $client $sessionId -OwnerMessageId $messageId -Changes @{
                status = 'FAILED'; results = $remaining; requiresReview = $true
                completedAt = [datetime]::UtcNow.ToString('o')
                error = 'The worker stopped without confirming completion. Review logs and resources before starting another session.'
            } | Out-Null
        }
    }
    throw
}
finally {
    if ($null -ne $client) { Save-DRSessionAudit $client }
}

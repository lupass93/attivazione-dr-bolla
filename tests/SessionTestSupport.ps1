$ErrorActionPreference = 'Stop'
$script:Root = Split-Path $PSScriptRoot -Parent
if (-not ('HttpResponseContext' -as [type])) {
    Add-Type 'public class HttpResponseContext { public object StatusCode; public object Body; public object Headers; }'
}
Import-Module (Join-Path $script:Root 'function-app/Modules/DRSessions/DRSessions.psm1') -Force
Import-Module (Join-Path $script:Root 'function-app/Modules/DRCore/DRCore.psm1') -Force

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $global:TestCount++
}

function Reset-SessionTest {
    $global:TestCount = 0
    $global:BlobStore = @{}
    $global:BlobVersions = @{}
    $global:QueueMessages = [System.Collections.Generic.List[string]]::new()
    $global:QueueFailure = $false
    $global:WriteConflict = $false
    $global:NextVersion = 0
    $global:PreflightFailures = @()
    $global:ReplicationFailures = @()
    $global:CoreCalls = [System.Collections.Generic.List[object]]::new()
    $global:CapturedResponse = $null
    $env:CSV_CONTAINER_NAME = 'dr-configs'
    $env:SESSION_CONTAINER_NAME = 'dr-sessions'
    $env:LOG_CONTAINER_NAME = 'dr-logs'
    $env:TARGET_RESOURCE_GROUP_SUFFIX = '-DR'
    $env:TARGET_SUBSCRIPTION_SUFFIX = '-DR'
    $global:TestClient = @{
        BlobEndpoint = 'https://mock.blob.core.windows.net'
        QueueEndpoint = 'https://mock.queue.core.windows.net'
        AccountName = 'mock'; Container = 'dr-sessions'; QueueName = 'dr-activation'; Profile = @{}
    }
}

& (Get-Module DRSessions) {
    function script:New-DRStorageClient { return $global:TestClient }
    function script:Invoke-DRStorageRequest {
        param($Client, $Method, $Uri, $Headers = @{}, $Body, $ContentType, $AllowedStatus = @(200))
        $code = 200
        $content = ''
        $responseHeaders = @{}
        if ($Uri -like '*/messages?*') {
            if ($global:QueueFailure) { throw 'Simulated queue outage.' }
            $document = [xml]$Body
            $global:QueueMessages.Add([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($document.QueueMessage.MessageText)))
            $code = 201
        }
        elseif ($Method -eq 'GET') {
            if ($global:BlobStore.ContainsKey($Uri)) {
                $content = $global:BlobStore[$Uri]
                $responseHeaders.ETag = $global:BlobVersions[$Uri]
            }
            else { $code = 404 }
        }
        elseif ($Method -eq 'PUT') {
            if (($Headers.ContainsKey('If-None-Match') -and $global:BlobStore.ContainsKey($Uri)) -or
                ($Headers.ContainsKey('If-Match') -and $Headers['If-Match'] -ne $global:BlobVersions[$Uri]) -or
                ($global:WriteConflict -and $Headers.ContainsKey('If-Match'))) {
                $code = 412
                $global:WriteConflict = $false
            }
            else {
                $global:NextVersion++
                $global:BlobStore[$Uri] = $Body
                $global:BlobVersions[$Uri] = "`"v$global:NextVersion`""
                $code = 201
            }
        }
        else { throw "Unexpected test storage request: $Method $Uri" }
        if ($code -notin $AllowedStatus) { throw "Test storage request returned HTTP $code." }
        return [pscustomobject]@{ StatusCode = $code; Content = $content; Headers = $responseHeaders }
    }
}

function global:Push-OutputBinding { param($Name, $Value); $global:CapturedResponse = $Value }
& (Get-Module DRCore) {
function script:Invoke-VMReplication {
    param($SourceSubscription, $SourceResourceGroup, $SourceVmName, $SessionId, [switch]$PreflightOnly,
        $BackendPoolNameOverride, $LogContainerName, $LogStorageAccountName, $TargetSubscriptionSuffix,
        $TargetResourceGroupSuffix, $TargetVnetNameSuffix, $TargetVnetRgSuffix, $TargetLbNameSuffix,
        $TargetLbRgSuffix, $TargetDesNameSuffix, $TargetDesRgSuffix, $TargetAsgNameSuffix)
    $global:CoreCalls.Add(@{ vm = $SourceVmName; preflight = [bool]$PreflightOnly; sessionId = $SessionId })
    $failure = if ($PreflightOnly) { $SourceVmName -in $global:PreflightFailures } else { $SourceVmName -in $global:ReplicationFailures }
    return [pscustomobject]@{
        SourceSubscriptionId = $SourceSubscription
        TargetSubscriptionId = "$SourceSubscription-dr"
        Status = $(if ($failure) { 'Failed' } else { 'Succeeded' })
        Error = $(if ($failure) { 'Required ASG is missing.' } else { $null })
    }
}
}

function Set-TestCsv {
    param([string]$Content, [string]$Path = 'vms.csv', [switch]$Binary)
    $uri = "$($global:TestClient.BlobEndpoint)/dr-configs/$Path"
    if ($Binary) { $global:BlobStore[$uri] = [System.Text.Encoding]::UTF8.GetBytes($Content) }
    else { $global:BlobStore[$uri] = $Content }
    $global:BlobVersions[$uri] = '"csv-v1"'
}

function Invoke-TestSubmission {
    param([object]$Body)
    & (Join-Path $script:Root 'function-app/Invoke-DRReplication/run.ps1') `
        -Request @{ Body = $Body } -TriggerMetadata @{}
    return $global:CapturedResponse
}

function Invoke-TestWorker {
    param([string]$SessionId, [string]$MessageId = 'queue-message-one', [switch]$NativePayload)
    $payload = @{ schemaVersion = 1; sessionId = $SessionId }
    if (-not $NativePayload) { $payload = $payload | ConvertTo-Json -Compress }
    & (Join-Path $script:Root 'function-app/Process-DRSession/run.ps1') `
        -QueueItem $payload `
        -TriggerMetadata @{ Id = $MessageId; DequeueCount = 1 }
}

Reset-SessionTest

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'function-app/Modules/DRAudit/DRAudit.psm1') -Force
Initialize-DRAudit -FunctionName 'AuditTest' -SessionId 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
Set-DRAuditContext -VmName 'vm-one' -Criticita 'Sistemico (2h)' -Acronimo 'APP01'
$profile = [pscustomobject]@{ Subscription = @{ Id = 'target' }; Account = @{ Id = 'identity-target' } }
$resource = '/subscriptions/target/resourceGroups/compute-DR/providers/Microsoft.Compute/disks/os'
$result = Invoke-DRAzureOperation -Operation 'New-AzDisk' -ResourceId $resource -Profile $profile -ScriptBlock {
    [pscustomobject]@{ Id = $resource }
}
if ($result.Id -ne $resource) { throw 'Audit must preserve the operation return value.' }
$events = @(Get-DRAuditEntries | ForEach-Object { ($_ -split ' AUDIT ', 2)[1] | ConvertFrom-Json -AsHashtable })
if ($events.Count -ne 2 -or $events[0].status -ne 'Started' -or $events[1].status -ne 'Succeeded' -or
    $events[1].identityClientId -ne 'identity-target' -or $events[1].resourceGroup -ne 'compute-DR' -or
    $events[1].subscriptionId -ne 'target' -or $events[1].vmName -ne 'vm-one' -or $events[1].durationMs -lt 0 -or
    $events[1].criticita -ne 'Sistemico (2h)' -or $events[1].acronimo -ne 'APP01') {
    throw 'Each action needs start/outcome, timing, complete scope, identity and customer context.'
}
$failure = $null
try {
    Invoke-DRAzureOperation -Operation 'Storage POST' -Plane Data -ResourceId 'https://storage.queue.core.windows.net/dr-activation/messages?sig=secret-signature' `
        -Profile $profile -ScriptBlock { throw 'Authorization: Bearer secret-bearer AccountKey=secret-account-key; sig=secret-signature' }
} catch { $failure = $_ }
if (-not $failure) { throw 'The original operation failure must propagate.' }
$text = (Get-DRAuditEntries) -join "`n"
foreach ($secret in @('secret-bearer', 'secret-account-key', 'secret-signature')) {
    if ($text.Contains($secret)) { throw "Audit leaked a credential: $secret" }
}
$last = (($text -split "`n")[-1] -split ' AUDIT ', 2)[1] | ConvertFrom-Json
if ($last.status -ne 'Failed' -or $last.plane -ne 'Data' -or -not $last.error) { throw 'Data-plane failures need a sanitized diagnostic.' }
$null = Invoke-DRAzureOperation -Operation 'Get-AzDisk' -ResourceId $resource -Profile $profile -AllowNotFound -ScriptBlock { $null }
$last = ((@(Get-DRAuditEntries)[-1]) -split ' AUDIT ', 2)[1] | ConvertFrom-Json
if ($last.status -ne 'NotFound') { throw 'An absent optional target is not a successful resource read.' }
Write-DRAuditEvent -Operation 'Sanitize quoted errors' -Status Failed -ErrorMessage 'password="two secret words" client_secret=''quoted secret value'''
$last = ((@(Get-DRAuditEntries)[-1]) -split ' AUDIT ', 2)[1] | ConvertFrom-Json
if ($last.error.Contains('two secret words') -or $last.error.Contains('quoted secret value')) { throw 'Quoted credentials must be redacted before JSON serialization.' }
$rejected = $false
try {
    Invoke-DRAzureOperation -Operation 'Get-AzDisk' -ResourceId $resource -Profile $profile -AllowNotFound `
        -ScriptBlock { throw "AuthorizationFailed for resource 'ResourceNotFound-disk404'; HTTP 403.`nErrorCode: AuthorizationFailed" } | Out-Null
} catch { $rejected = $true }
if (-not $rejected) { throw 'Authorization failures must never be treated as an absent resource.' }
Import-Module (Join-Path $root 'function-app/Modules/DRCore/DRCore.psm1') -Force
& (Get-Module DRCore) {
    $script:AuditAttempts = 0
    $value = Invoke-WithRetry -Operation 'Test-Retry' -MaxAttempts 2 -InitialDelaySeconds 0 -ScriptBlock {
        Invoke-DRAzureOperation -Operation 'Test-Retry' -ResourceId '/subscriptions/target/resourceGroups/compute-DR' `
            -IdentityClientId identity-target -ScriptBlock {
                $script:AuditAttempts++
                if ($script:AuditAttempts -eq 1) { throw '429 TooManyRequests' }
                'done'
            }
    }
    if ($value -ne 'done' -or $script:AuditAttempts -ne 2) { throw 'Tracing must preserve the bounded retry behavior.' }
}
$events = @(Get-DRAuditEntries | ForEach-Object { ($_ -split ' AUDIT ', 2)[1] | ConvertFrom-Json })
if (@($events | Where-Object { $_.operation -eq 'Test-Retry' -and $_.status -eq 'Started' }).Count -ne 2 -or
    @($events | Where-Object { $_.operation -eq 'Test-Retry' -and $_.status -eq 'Succeeded' -and $_.attempt -eq 2 }).Count -ne 1) {
    throw 'Each actual Azure retry needs its own timed, numbered audit outcome.'
}
Import-Module (Join-Path $root 'function-app/Modules/DRSessions/DRSessions.psm1') -Force
& (Get-Module DRSessions) {
    $env:SOURCE_IDENTITY_CLIENT_ID = 'identity-storage'
    $env:HOSTING_SUBSCRIPTION_ID = 'hosting'
    $script:CapturedHeaders = $null
    function Get-AzAccessToken {
        [CmdletBinding()]param($ResourceUrl, $DefaultProfile)
        @{ Token = (ConvertTo-SecureString 'never-log-this-access-token' -AsPlainText -Force) }
    }
    function Invoke-WebRequest {
        [CmdletBinding()]param($Method, $Uri, $Headers, $TimeoutSec, $SkipHttpErrorCheck)
        $script:CapturedHeaders = $Headers
        [pscustomobject]@{ StatusCode = 200; Content = '{}'; Headers = @{ 'x-ms-request-id' = 'request-evidence' } }
    }
    $client = @{
        Profile = @{}; ResourceId = '/subscriptions/hosting/resourceGroups/storage-rg/providers/Microsoft.Storage/storageAccounts/storage'
    }
    $null = Invoke-DRStorageRequest $client -Method GET -Uri 'https://storage.blob.core.windows.net/dr-sessions/test.json'
    if ($script:CapturedHeaders.ContainsKey('Authorization')) { throw 'Storage authorization must be removed after the request.' }
}
$text = (Get-DRAuditEntries) -join "`n"
if ($text.Contains('never-log-this-access-token')) { throw 'Obtaining a real-shaped SecureString token must never write the token to logs.' }
$events = @(Get-DRAuditEntries | ForEach-Object { ($_ -split ' AUDIT ', 2)[1] | ConvertFrom-Json })
$read = @($events | Where-Object { $_.operation -eq 'Storage GET' -and $_.status -eq 'Succeeded' })[-1]
if ($read.subscriptionId -ne 'hosting' -or $read.resourceGroup -ne 'storage-rg' -or $read.identityClientId -ne 'identity-storage' -or
    @($events | Where-Object { $_.details -and $_.details.requestId -eq 'request-evidence' }).Count -ne 1) {
    throw 'Real storage-request tracing must include its true scope, identity and Azure request ID.'
}
Write-Host 'PASS: Azure action start/outcome/context, return values, failure propagation, redaction and not-found audit checks; no Azure calls.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Entries = [System.Collections.Generic.List[string]]::new()
$script:Context = @{}

function Initialize-DRAudit {
    param([string]$FunctionName, [string]$SessionId = '')
    $script:Entries.Clear()
    $script:Context = @{
        functionName = $FunctionName; sessionId = $SessionId; vmName = ''
        criticita = ''; acronimo = ''; phase = ''; stage = ''; attempt = 1; runId = [guid]::NewGuid().ToString('D')
    }
}

function Set-DRAuditContext {
    param(
        [string]$SessionId, [string]$VmName, [string]$Criticita, [string]$Acronimo,
        [string]$Phase, [string]$Stage, [int]$Attempt = 1
    )
    foreach ($entry in $PSBoundParameters.GetEnumerator()) { $script:Context[$entry.Key] = $entry.Value }
}

function Get-DRAuditContext { return $script:Context.Clone() }
function Get-DRAuditEntries { return $script:Entries.ToArray() }

function Protect-DRAuditText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $safe = $Text -replace '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [REDACTED]'
    $safe = $safe -replace '(?i)(AccountKey|SharedAccessSignature|access_token|client_secret|password|x-functions-key|sig|token)\s*[:=]\s*(?:"[^"]*"|''[^'']*''|[^;\s,"''<>}]+)', '$1=[REDACTED]'
    return ($safe -replace '(https?://[^\s?"<>]+)\?[^\s"<>]*', '$1?[REDACTED]')
}

function Get-DRAuditProperty {
    param([AllowNull()][object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Write-DRAuditEvent {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [ValidateSet('Control', 'Data', 'Identity', 'Workflow')][string]$Plane = 'Workflow',
        [ValidateSet('Started', 'Succeeded', 'Failed', 'NotFound', 'Retry', 'Observed')][string]$Status = 'Observed',
        [string]$ResourceId = '', [string]$SubscriptionId = '', [string]$ResourceGroup = '',
        [string]$IdentityClientId = '', [double]$DurationMs = 0, [int]$Attempt = 0,
        [string]$ErrorMessage = '', [AllowNull()][object]$Details
    )
    if ($ResourceId -match '^/subscriptions/([^/]+)(?:/resourceGroups/([^/]+))?') {
        if (-not $SubscriptionId) { $SubscriptionId = $Matches[1] }
        if (-not $ResourceGroup -and $Matches.ContainsKey(2)) { $ResourceGroup = $Matches[2] }
    }
    if ($Attempt -eq 0) { $Attempt = if ($script:Context.ContainsKey('attempt')) { [int]$script:Context.attempt } else { 1 } }
    $event = [ordered]@{
        timestamp = [datetime]::UtcNow.ToString('o'); operation = $Operation; plane = $Plane; status = $Status
        sessionId = [string]$script:Context['sessionId']; vmName = [string]$script:Context['vmName']
        criticita = [string]$script:Context['criticita']; acronimo = [string]$script:Context['acronimo']
        functionName = [string]$script:Context['functionName']; runId = [string]$script:Context['runId']
        phase = [string]$script:Context['phase']; stage = [string]$script:Context['stage']
        subscriptionId = $SubscriptionId; resourceGroup = $ResourceGroup; resourceId = (Protect-DRAuditText $ResourceId)
        identityClientId = $IdentityClientId; durationMs = [math]::Round($DurationMs, 2)
        attempt = $Attempt; error = $(if ($ErrorMessage) { Protect-DRAuditText $ErrorMessage } else { $null }); details = $Details
    }
    $json = Protect-DRAuditText ($event | ConvertTo-Json -Depth 25 -Compress)
    $prefix = "$($event.timestamp) [$(if ($Status -eq 'Failed') { 'ERROR' } elseif ($Status -eq 'Retry') { 'WARN' } else { 'INFO' })]"
    $prefix += " [$($event.vmName)] [sessionId=$($event.sessionId)] [Criticita=$($event.criticita)] [Acronimo=$($event.acronimo)]"
    $line = "$(Protect-DRAuditText $prefix) AUDIT $json"
    $script:Entries.Add($line)
    if ($Status -in @('Failed', 'Retry')) { Write-Warning $line -WarningAction Continue }
    else { Write-Host $line }
}

function Invoke-DRAzureOperation {
    param(
        [Parameter(Mandatory)][string]$Operation, [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$ResourceId = '', [AllowNull()][object]$Profile,
        [ValidateSet('Control', 'Data', 'Identity')][string]$Plane = 'Control',
        [string]$IdentityClientId = '', [string]$SubscriptionId = '', [string]$ResourceGroup = '',
        [switch]$AllowNotFound
    )
    if (-not $SubscriptionId) { $SubscriptionId = [string](Get-DRAuditProperty (Get-DRAuditProperty $Profile 'Subscription') 'Id') }
    if (-not $IdentityClientId) { $IdentityClientId = [string](Get-DRAuditProperty (Get-DRAuditProperty $Profile 'Account') 'Id') }
    $metadata = @{
        Operation = $Operation; Plane = $Plane; ResourceId = $ResourceId
        SubscriptionId = $SubscriptionId; ResourceGroup = $ResourceGroup; IdentityClientId = $IdentityClientId
    }
    Write-DRAuditEvent @metadata -Status Started
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $ScriptBlock
        $status = if ($AllowNotFound -and $null -eq $result) { 'NotFound' } else { 'Succeeded' }
        Write-DRAuditEvent @metadata -Status $status -DurationMs $watch.Elapsed.TotalMilliseconds
        return $result
    }
    catch {
        $exception = $_.Exception
        $response = Get-DRAuditProperty $exception 'Response'
        $statusCode = Get-DRAuditProperty $response 'StatusCode'
        if ($AllowNotFound -and ($statusCode -eq 404 -or
                ($null -eq $statusCode -and $exception.Message -match '(?im)^\s*ErrorCode\s*:\s*(ResourceNotFound|ResourceGroupNotFound)\s*$'))) {
            Write-DRAuditEvent @metadata -Status NotFound -DurationMs $watch.Elapsed.TotalMilliseconds -ErrorMessage $exception.Message
            return $null
        }
        Write-DRAuditEvent @metadata -Status Failed -DurationMs $watch.Elapsed.TotalMilliseconds -ErrorMessage $exception.Message
        throw
    }
    finally { $watch.Stop() }
}

Export-ModuleMember -Function Initialize-DRAudit, Set-DRAuditContext, Get-DRAuditContext, Get-DRAuditEntries, `
    Protect-DRAuditText, Write-DRAuditEvent, Invoke-DRAzureOperation

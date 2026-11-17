# DRCore.psm1
# Core DR replication logic, adapted from Cluster-Bolla_v1.ps1 for use as an
# Azure Functions PowerShell module.
#
# Key differences from the original script:
#   - SourceVmName is consumed directly from CSV (no lowest-suffix auto-discovery).
#   - All target resource names are derived by appending $TargetNameSuffix (default: '-DR')
#     to source names discovered at runtime (VNet, DES, LB RG, resource group, subscription).
#   - Returns a structured result object instead of writing to a local JSON file.
#   - Called sequentially by the session queue worker.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot '../DRAudit/DRAudit.psm1') -Global -ErrorAction Stop

# ---------------------------------------------------------------------------
# Helper functions (inlined so they are available inside parallel runspaces)
# ---------------------------------------------------------------------------

$script:LogBuffer = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:SourceContext = $null
$script:TargetContext = $null
$script:LogStorageContext = $null
$script:LogMetadata = $null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Level = 'INFO',
        [string]$VmName = ''
    )
    $ts     = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK'
    $prefix = if ($VmName) { "[$VmName] " } else { '' }
    if ($null -ne $script:LogMetadata) {
        $prefix += "[sessionId=$($script:LogMetadata.SessionId)] "
        if ($script:LogMetadata.Criticita) { $prefix += "[Criticita=$($script:LogMetadata.Criticita)] " }
        if ($script:LogMetadata.Acronimo) { $prefix += "[Acronimo=$($script:LogMetadata.Acronimo)] " }
    }
    $line   = Protect-DRAuditText "$ts [$Level] ${prefix}$Message"
    Write-Host $line
    [void]$script:LogBuffer.Enqueue($line)
}

function Get-RbacHint {
    param([System.Exception]$Exception)
    if ($Exception.Message -match 'AuthorizationFailed|Forbidden|does not have authorization|insufficient privileges|Access denied') {
        return ('RBAC hint: Ensure the managed identity has Reader on source subscription/RG, ' +
            'Contributor on target disk/VM RGs, Network Contributor on target VNet RG, ' +
                'and Reader on target DES RG.')
    }
    return $null
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)] [scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)] [string]$Operation,
        [int]$MaxAttempts        = 5,
        [int]$InitialDelaySeconds = 2
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Set-DRAuditContext -Attempt $attempt
            return & $ScriptBlock
        }
        catch {
            $retryable = $_.Exception.Message -match '429|TooManyRequests|temporar|timeout|throttl|InternalServerError|Conflict|Gateway|BadRequest|subscription|context|authorization'
            if ($attempt -ge $MaxAttempts -or -not $retryable) {
                throw "Operation '$Operation' failed after $attempt attempt(s). Error: $($_.Exception.Message)"
            }
            $delay = [Math]::Min(30, [int]($InitialDelaySeconds * [Math]::Pow(2, ($attempt - 1))))
            Write-DRAuditEvent -Operation $Operation -Status Retry -Attempt $attempt -ErrorMessage $_.Exception.Message `
                -Details @{ nextAttempt = $attempt + 1; delaySeconds = $delay }
            Write-Log "Transient failure in '$Operation'. Retrying in $delay s (attempt $attempt/$MaxAttempts)." 'WARN'
            Start-Sleep -Seconds $delay
        }
        finally { Set-DRAuditContext -Attempt 1 }
    }
}

function Resolve-Subscription {
    param([string]$SubscriptionIdentifier, [Parameter(Mandatory = $true)] [object]$DefaultProfile, [string]$TenantId)
    $subs = Invoke-WithRetry -Operation 'Get-AzSubscription' -ScriptBlock {
        Invoke-DRControlOperation 'Get-AzSubscription' @{ TenantId = $TenantId; DefaultProfile = $DefaultProfile }
    }
    $matches = @($subs | Where-Object { $_.Id -eq $SubscriptionIdentifier -or $_.Name -eq $SubscriptionIdentifier })
    if ($matches.Count -ne 1) {
        throw "Source subscription '$SubscriptionIdentifier' must resolve to exactly one accessible subscription; found $($matches.Count)."
    }
    if ($matches[0].State -ne 'Enabled' -or $matches[0].TenantId -ne $TenantId) {
        throw "Source subscription '$SubscriptionIdentifier' is disabled or belongs to a different tenant."
    }
    return $matches[0]
}

function Resolve-DRSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object] $SourceSubscription,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Subscriptions,
        [string] $Suffix = '-DR'
    )

    if ([string]::IsNullOrWhiteSpace($SourceSubscription.Name) -or
        [string]::IsNullOrWhiteSpace($SourceSubscription.Id) -or
        [string]::IsNullOrWhiteSpace($SourceSubscription.TenantId) -or
        [string]::IsNullOrWhiteSpace($Suffix)) {
        throw 'Source subscription ID, name, tenant and a nonempty DR suffix are required.'
    }
    $expectedName = "$($SourceSubscription.Name)$Suffix"
    $matches = @($Subscriptions | Where-Object { $_.Name -eq $expectedName })
    if ($matches.Count -ne 1) {
        throw "DR subscription '$expectedName' must resolve to exactly one accessible subscription; found $($matches.Count)."
    }
    $target = $matches[0]
    if ($target.TenantId -ne $SourceSubscription.TenantId) {
        throw "DR subscription '$expectedName' belongs to a different tenant."
    }
    if ($target.State -ne 'Enabled') {
        throw "DR subscription '$expectedName' is not enabled."
    }
    if ([string]::IsNullOrWhiteSpace($target.Id) -or $target.Id -eq $SourceSubscription.Id) {
        throw "DR subscription '$expectedName' must have a valid ID distinct from the source."
    }
    return $target
}

function Get-DRLogPrefix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [guid] $SourceSubscriptionId,
        [Parameter(Mandatory = $true)] [string] $SourceResourceGroup,
        [Parameter(Mandatory = $true)] [string] $SourceVmName
    )
    foreach ($value in @($SourceResourceGroup, $SourceVmName)) {
        if ([string]::IsNullOrWhiteSpace($value) -or $value.Contains('/') -or $value.Contains([string][char]92)) {
            throw 'Source Resource Group and VM names must be nonempty and contain no path separators.'
        }
    }
    return "$($SourceSubscriptionId.ToString().ToLowerInvariant())/$($SourceResourceGroup.ToLowerInvariant())/$($SourceVmName.ToLowerInvariant())/"
}

function Set-SubscriptionContext {
    param([string]$SubscriptionId, [string]$FriendlyName, [switch]$Source)
    Invoke-WithRetry -Operation "Set-AzContext $FriendlyName" -ScriptBlock {
        $context = if ($Source) { $script:SourceContext } else { $script:TargetContext }
        if ($null -eq $context -or $context.Subscription.Id -ne $SubscriptionId) {
            throw "The selected identity context does not match subscription '$SubscriptionId'."
        }
        Set-AzContext -Context $context -Scope Process -ErrorAction Stop | Out-Null
    } | Out-Null
}

function Get-IdSegmentValue {
    param([Parameter(Mandatory = $true)] [string]$ResourceId, [Parameter(Mandatory = $true)] [string]$SegmentName)
    $parts = $ResourceId.Trim('/') -split '/'
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        if ($parts[$i].Equals($SegmentName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $parts[$i + 1]
        }
    }
    return $null
}

function Get-LastNameFromId {
    param([Parameter(Mandatory = $true)] [string]$ResourceId)
    return ($ResourceId.TrimEnd('/') -split '/')[-1]
}

function Resolve-DRResourceReference {
    param(
        [Parameter(Mandatory)][string]$ResourceId, [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][string]$TargetSubscriptionId, [string]$NameSuffix = '',
        [string]$ResourceGroupSuffix = ''
    )
    $pattern = '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/' + [regex]::Escape($ResourceType) + '/([^/]+)$'
    if ($ResourceId -notmatch $pattern) { throw "Invalid $ResourceType resource ID: '$ResourceId'." }
    $subscription = $Matches[1]; $group = $Matches[2]; $name = $Matches[3]
    return @{
        SourceId = $ResourceId; SourceSubscriptionId = $subscription; SourceResourceGroup = $group; SourceName = $name
        Name = "$name$NameSuffix"; ResourceGroup = "$group$ResourceGroupSuffix"
        Id = "/subscriptions/$TargetSubscriptionId/resourceGroups/$group$ResourceGroupSuffix/providers/$ResourceType/$name$NameSuffix"
    }
}

function Get-DRLoadBalancerReferences {
    param(
        [object[]]$IpConfigurations, [string]$TargetSubscriptionId,
        [string]$NameSuffix = '', [string]$ResourceGroupSuffix = ''
    )
    $balancers = [ordered]@{}
    foreach ($ip in $IpConfigurations) {
        foreach ($pool in @(Get-OptionalProp $ip 'LoadBalancerBackendAddressPools')) {
            if ($null -eq $pool -or [string]::IsNullOrWhiteSpace([string]$pool.Id)) { continue }
            if ($pool.Id -notmatch '^(.+)/backendAddressPools/([^/]+)$') { throw "Invalid backend pool resource ID: '$($pool.Id)'." }
            $sourceId = [string]$Matches[1]
            $poolName = [string]$Matches[2]
            $key = $sourceId.ToLowerInvariant()
            if (-not $balancers.Contains($key)) {
                $reference = Resolve-DRResourceReference $sourceId 'Microsoft.Network/loadBalancers' `
                    $TargetSubscriptionId $NameSuffix $ResourceGroupSuffix
                $reference.PoolReferences = [System.Collections.Generic.List[object]]::new()
                $balancers[$key] = $reference
            }
            $balancers[$key].PoolReferences.Add(@{
                SourceId = [string]$pool.Id; SourceName = $poolName; IpConfigurationName = [string]$ip.Name
            })
        }
    }
    return @($balancers.Values)
}

function Invoke-DRControlOperation {
    param(
        [Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][hashtable]$Parameters,
        [string]$ResourceId = '', [string]$IdentityClientId = '', [switch]$AllowNotFound
    )
    $profile = $Parameters['DefaultProfile']
    $subscription = if ($profile -and $profile.Subscription) { [string]$profile.Subscription.Id } else { [string]$Parameters['Subscription'] }
    $group = [string]$Parameters['ResourceGroupName']
    $name = [string]$Parameters['Name']
    if ($Parameters.ContainsKey('DiskName')) { $name = [string]$Parameters.DiskName }
    if ($Command -eq 'New-AzVM') { $name = [string]$Parameters.VM.Name }
    if ($Command -eq 'Get-AzResourceGroup') { $group = $name }
    if ($Command -eq 'Set-AzNetworkInterface') { $ResourceId = [string]$Parameters.NetworkInterface.Id }
    $types = @{
        'Get-AzVM' = 'Microsoft.Compute/virtualMachines'; 'New-AzVM' = 'Microsoft.Compute/virtualMachines'
        'Get-AzDisk' = 'Microsoft.Compute/disks'; 'New-AzDisk' = 'Microsoft.Compute/disks'
        'Get-AzNetworkInterface' = 'Microsoft.Network/networkInterfaces'; 'New-AzNetworkInterface' = 'Microsoft.Network/networkInterfaces'
        'Get-AzVirtualNetwork' = 'Microsoft.Network/virtualNetworks'
        'Get-AzApplicationSecurityGroup' = 'Microsoft.Network/applicationSecurityGroups'
        'Get-AzNetworkSecurityGroup' = 'Microsoft.Network/networkSecurityGroups'
        'Get-AzLoadBalancer' = 'Microsoft.Network/loadBalancers'
        'Get-AzDiskEncryptionSet' = 'Microsoft.Compute/diskEncryptionSets'
    }
    if (-not $ResourceId) {
        $ResourceId = "/subscriptions/$subscription"
        if ($group) { $ResourceId += "/resourceGroups/$group" }
        if ($types.ContainsKey($Command)) { $ResourceId += "/providers/$($types[$Command])/$name" }
    }
    if ($Command -eq 'Get-AzSubscription') { $ResourceId = "/tenants/$($Parameters.TenantId)/subscriptions"; $subscription = '' }
    if ($Command -eq 'Connect-AzAccount' -and -not $subscription) { $ResourceId = "/tenants/$($Parameters.Tenant)" }
    $plane = if ($Command -eq 'Connect-AzAccount') { 'Identity' } else { 'Control' }
    $parametersForCall = $Parameters.Clone()
    $parametersForCall['ErrorAction'] = 'Stop'
    return Invoke-DRAzureOperation -Operation $Command -Plane $plane -ResourceId $ResourceId -Profile $profile `
        -IdentityClientId $IdentityClientId -SubscriptionId $subscription -ResourceGroup $group -AllowNotFound:$AllowNotFound `
        -ScriptBlock { & $Command @parametersForCall }
}

function Get-OptionalProp {
    param([AllowNull()][object]$Object, [string]$PropertyName)
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $PropertyName) { return $Object.$PropertyName }
    return $null
}

function Normalize {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return $Value.Trim().ToLowerInvariant()
}

function Compare-StringArrays {
    param([AllowNull()][string[]]$A, [AllowNull()][string[]]$B)
    $aN = @($A | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
    $bN = @($B | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
    if ($aN.Count -ne $bN.Count) { return $false }
    for ($i = 0; $i -lt $aN.Count; $i++) { if ($aN[$i] -ne $bN[$i]) { return $false } }
    return $true
}

function Compare-Hashtables {
    param([AllowNull()][hashtable]$A, [AllowNull()][hashtable]$B)
    if ($null -eq $A) { $A = @{} }
    if ($null -eq $B) { $B = @{} }
    if ($A.Count -ne $B.Count) { return $false }
    foreach ($k in $A.Keys) {
        if (-not $B.ContainsKey($k)) { return $false }
        if ([string]$A[$k] -ne [string]$B[$k]) { return $false }
    }
    return $true
}

function Build-TargetTags {
    param([AllowNull()][hashtable]$SourceTags, [string]$Prefix, [AllowNull()][hashtable]$ExtraTags)
    $out = @{}
    if ($SourceTags) {
        foreach ($k in $SourceTags.Keys) {
            $newKey = if ([string]::IsNullOrEmpty($Prefix)) { $k } else { "$Prefix$k" }
            $out[$newKey] = [string]$SourceTags[$k]
        }
    }
    if ($ExtraTags) { foreach ($k in $ExtraTags.Keys) { $out[$k] = [string]$ExtraTags[$k] } }
    return $out
}

function Upload-StageLog {
    param(
        [string]$VmName,
        [string]$StageId,
        [string]$StageDescription,
        [bool]$Failed,
        [string]$LogStorageAccountName,
        [string]$LogContainerName,
        [string]$SessionId
    )
    if ([string]::IsNullOrWhiteSpace($LogStorageAccountName) -or [string]::IsNullOrWhiteSpace($LogContainerName) -or
        [string]::IsNullOrWhiteSpace($script:LogPrefix)) {
        Write-Log "Skipping stage log upload (storage not configured)." 'WARN' -VmName $VmName
        return
    }
    try {
        $logEntries = @($script:LogBuffer)
        if ($logEntries.Count -eq 0) {
            Write-Log "No log entries to upload for stage $StageId." -VmName $VmName
            return
        }
        $logContent = $logEntries -join "`n"
        $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
        $failSuffix = if ($Failed) { '-failed' } else { '' }
        $logBlobName = "$($script:LogPrefix)$SessionId-stage$StageId-$StageDescription-$timestamp$failSuffix.log"
        $tmpLog = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($tmpLog, $logContent, [System.Text.Encoding]::UTF8)
            $storageGroup = ''
            $storageSubscription = [string]$env:HOSTING_SUBSCRIPTION_ID
            if ($env:DR_STORAGE_RESOURCE_ID -match '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft.Storage/storageAccounts/[^/]+$') {
                $storageSubscription = $Matches[1]; $storageGroup = $Matches[2]
            }
            Invoke-DRAzureOperation -Operation 'Set-AzStorageBlobContent (stage log)' -Plane Data `
                -ResourceId "https://$LogStorageAccountName.blob.core.windows.net/$LogContainerName/$logBlobName" `
                -Profile $script:SourceContext -IdentityClientId $env:SOURCE_IDENTITY_CLIENT_ID `
                -SubscriptionId $storageSubscription -ResourceGroup $storageGroup -ScriptBlock {
                    Set-AzStorageBlobContent -Context $script:LogStorageContext -Container $LogContainerName `
                        -File $tmpLog -Blob $logBlobName -Force -ErrorAction Stop | Out-Null
                } | Out-Null
            Write-Log "Stage $StageId log uploaded: $logBlobName" -VmName $VmName
        }
        finally {
            Remove-Item $tmpLog -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "Failed to upload stage $StageId log: $($_.Exception.Message)" 'WARN' -VmName $VmName
    }
}

function Select-BackendPool {
    param(
        [Parameter(Mandatory = $true)]  [object]   $LoadBalancer,
        [Parameter(Mandatory = $false)] [string[]] $SourcePoolNames,
        [Parameter(Mandatory = $false)] [string]   $PoolNameOverride
    )
    $pools = @($LoadBalancer.BackendAddressPools)
    if ($pools.Count -eq 0) { throw "Load balancer '$($LoadBalancer.Name)' has no backend pools." }

    if (-not [string]::IsNullOrWhiteSpace($PoolNameOverride)) {
        $match = $pools | Where-Object { $_.Name -eq $PoolNameOverride } | Select-Object -First 1
        if (-not $match) { throw "BackendPoolNameOverride '$PoolNameOverride' not found. Available: $($pools.Name -join ', ')." }
        return $match
    }

    if ($SourcePoolNames -and $SourcePoolNames.Count -gt 0) {
        $hits = @($SourcePoolNames | ForEach-Object { $n = $_; $pools | Where-Object { $_.Name -eq $n } } | Where-Object { $_ })
        if ($hits.Count -eq 1) { return $hits[0] }
        if ($hits.Count -gt 1) { throw "Ambiguous backend pool selection by source name. Matches: $($hits.Name -join ', ')." }
    }

    if ($pools.Count -eq 1) { return $pools[0] }

    $strict = @($pools | Where-Object { $_.Name -match '^(?i)(bepool|backendpool)$' })
    if ($strict.Count -eq 1) { return $strict[0] }
    if ($strict.Count -gt 1) { throw "Ambiguous backend pool (strict name match). Matches: $($strict.Name -join ', ')." }

    $contains = @($pools | Where-Object { $_.Name -match '(?i)(bepool|backendpool)' })
    if ($contains.Count -eq 1) { return $contains[0] }
    if ($contains.Count -gt 1) { throw "Ambiguous backend pool (substring match). Matches: $($contains.Name -join ', ')." }

    throw "Cannot auto-select a backend pool from '$($LoadBalancer.Name)'. Available: $($pools.Name -join ', '). Set BACKEND_POOL_NAME_OVERRIDE env var."
}

function Get-DRPrerequisites {
    param(
        [string]$VmName, [string]$VmResourceGroup, [string]$VnetResourceGroup,
        [string]$VnetName, [string]$SubnetName, [string[]]$AsgNames,
        [string]$DesResourceGroup, [string]$LoadBalancerName, [string]$LoadBalancerResourceGroup,
        [string[]]$SourcePoolNames, [string]$PoolNameOverride, [object]$DefaultProfile,
        [object[]]$AsgReferences = @(), [object[]]$NsgReferences = @(),
        [object[]]$LoadBalancerReferences = @(), [string]$NicResourceGroup = ''
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $groups = @($VmResourceGroup, $VnetResourceGroup, $DesResourceGroup)
    if ($NicResourceGroup) { $groups += $NicResourceGroup }
    foreach ($reference in @($AsgReferences) + @($NsgReferences) + @($LoadBalancerReferences)) { $groups += $reference.ResourceGroup }
    if ($LoadBalancerName) { $groups += $LoadBalancerResourceGroup }
    foreach ($group in @($groups | Where-Object { $_ } | Sort-Object -Unique)) {
        try {
            $resourceGroup = Invoke-DRControlOperation 'Get-AzResourceGroup' @{ Name = $group; DefaultProfile = $DefaultProfile }
            if ($null -eq $resourceGroup) { throw "Resource Group '$group' was not returned." }
        }
        catch { $errors.Add("Resource Group '$group': $($_.Exception.Message)") }
    }
    $subnet = $null
    try {
        $vnet = Invoke-DRControlOperation 'Get-AzVirtualNetwork' @{ ResourceGroupName = $VnetResourceGroup; Name = $VnetName; DefaultProfile = $DefaultProfile }
        if ($null -eq $vnet) { throw "VNet '$VnetName' was not returned." }
        $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName | Select-Object -First 1
        if ($null -eq $subnet) { throw "Subnet '$SubnetName' is missing." }
    }
    catch { $errors.Add("VNet '$VnetName' / subnet '$SubnetName': $($_.Exception.Message)") }
    $asgIds = [System.Collections.Generic.List[string]]::new()
    $asgsBySourceId = @{}
    $nsgsBySourceId = @{}
    $poolsBySourceId = @{}
    foreach ($reference in $AsgReferences) {
        try {
            $asg = Invoke-DRControlOperation 'Get-AzApplicationSecurityGroup' @{
                ResourceGroupName = $reference.ResourceGroup; Name = $reference.Name; DefaultProfile = $DefaultProfile
            }
            if ($null -eq $asg) { throw "ASG '$($reference.Id)' was not returned." }
            $asgIds.Add([string]$asg.Id)
            $asgsBySourceId[$reference.SourceId] = [string]$asg.Id
        }
        catch { $errors.Add("ASG '$($reference.Id)': $($_.Exception.Message)") }
    }
    foreach ($name in $AsgNames) {
        try {
            $asg = Invoke-DRControlOperation 'Get-AzApplicationSecurityGroup' @{ ResourceGroupName = $VnetResourceGroup; Name = $name; DefaultProfile = $DefaultProfile }
            if ($null -eq $asg) { throw "ASG '$name' was not returned." }
            $asgIds.Add([string]$asg.Id)
        }
        catch { $errors.Add("ASG '$name': $($_.Exception.Message)") }
    }
    foreach ($reference in $NsgReferences) {
        try {
            $nsg = Invoke-DRControlOperation 'Get-AzNetworkSecurityGroup' @{
                ResourceGroupName = $reference.ResourceGroup; Name = $reference.Name; DefaultProfile = $DefaultProfile
            }
            if ($null -eq $nsg) { throw "NSG '$($reference.Id)' was not returned." }
            $nsgsBySourceId[$reference.SourceId] = [string]$nsg.Id
        }
        catch { $errors.Add("NSG '$($reference.Id)': $($_.Exception.Message)") }
    }
    foreach ($reference in $LoadBalancerReferences) {
        try {
            $lb = Invoke-DRControlOperation 'Get-AzLoadBalancer' @{
                ResourceGroupName = $reference.ResourceGroup; Name = $reference.Name; DefaultProfile = $DefaultProfile
            }
            if ($null -eq $lb) { throw "Load Balancer '$($reference.Id)' was not returned." }
            $sourceNames = @($reference.PoolReferences.SourceName | Sort-Object -Unique)
            if ($sourceNames.Count -gt 1 -and $PoolNameOverride) {
                throw 'A single backend-pool override cannot replace multiple distinct source pools.'
            }
            foreach ($poolReference in $reference.PoolReferences) {
                $expectedPoolName = if ($PoolNameOverride) { $PoolNameOverride } else { $poolReference.SourceName }
                $matches = @($lb.BackendAddressPools | Where-Object Name -eq $expectedPoolName)
                if ($matches.Count -ne 1) { throw "Required backend pool '$expectedPoolName' is missing or ambiguous." }
                $pool = $matches[0]
                $poolsBySourceId[$poolReference.SourceId] = $pool
                Write-Log "Resolved backend pool '$($poolReference.SourceId)' to '$($pool.Id)'." -VmName $VmName
            }
        }
        catch { $errors.Add("Load Balancer '$($reference.Id)' / backend pools: $($_.Exception.Message)") }
    }
    if ($LoadBalancerName) {
        try {
            $loadBalancer = Invoke-DRControlOperation 'Get-AzLoadBalancer' @{ ResourceGroupName = $LoadBalancerResourceGroup; Name = $LoadBalancerName; DefaultProfile = $DefaultProfile }
            if ($null -eq $loadBalancer) { throw "Load Balancer '$LoadBalancerName' was not returned." }
            Select-BackendPool -LoadBalancer $loadBalancer -SourcePoolNames $SourcePoolNames -PoolNameOverride $PoolNameOverride | Out-Null
        }
        catch { $errors.Add("Load Balancer '$LoadBalancerName' / backend pool: $($_.Exception.Message)") }
    }
    if ($errors.Count -gt 0) {
        foreach ($errorMessage in $errors) { Write-Log $errorMessage 'ERROR' -VmName $VmName }
        throw "DR prerequisites are missing or inaccessible: $($errors -join ' | ')"
    }
    Write-Log 'DR prerequisite existence checks passed; network rules and external configuration are not reconciled.' -VmName $VmName
    return @{
        Subnet = $subnet; AsgIds = @($asgIds); AsgsBySourceId = $asgsBySourceId
        NsgsBySourceId = $nsgsBySourceId; PoolsBySourceId = $poolsBySourceId
    }
}

function Invoke-VMReplication {
    <#
    .SYNOPSIS
        Replicates a single VM (disks, NIC, VM, LB backend) from a source subscription
        to a DR subscription.  All target names are derived by appending '-DR' to the
        source names discovered at runtime.
    .PARAMETER SourceSubscription
        Source subscription name or ID (as it appears in Get-AzSubscription).
    .PARAMETER SourceResourceGroup
        Resource group that contains the source VM.
    .PARAMETER SourceVmName
        Exact name of the source VM to replicate.
    .PARAMETER SnapshotNamePrefix
        Retained for compatibility; snapshots are no longer created.
    .PARAMETER DiskParallelThrottle
        Retained for compatibility; managed disk copies run sequentially.
    .PARAMETER AdditionalTags
        Extra tags to add to the target VM.
    .PARAMETER BackendPoolNameOverride
        Force a specific backend pool name on the target LB. Empty = auto-select.
    .PARAMETER TargetSubscriptionSuffix
        Suffix for the target subscription. Empty = no suffix.
    .PARAMETER TargetResourceGroupSuffix
        Suffix for the target resource group. Empty = no suffix.
    .PARAMETER TargetVnetNameSuffix
        Suffix for the target VNet name. Empty = no suffix.
    .PARAMETER TargetVnetRgSuffix
        Suffix for the target VNet resource group name. Empty = no suffix.
    .PARAMETER TargetLbNameSuffix
        Suffix for the target Load Balancer name. Empty = no suffix.
    .PARAMETER TargetLbRgSuffix
        Suffix for the target Load Balancer resource group name. Empty = no suffix.
    .PARAMETER TargetDesNameSuffix
        Suffix for the target Disk Encryption Set name. Empty = no suffix.
    .PARAMETER TargetDesRgSuffix
        Suffix for the target Disk Encryption Set resource group name. Empty = no suffix.
    .PARAMETER TargetAsgNameSuffix
        Suffix for target Application Security Group names. Empty = no suffix.
        ASG Resource Groups are derived from the source ASG IDs and must be pre-created.
        Missing required ASGs fail the preflight before workload creation.
    .OUTPUTS
        PSCustomObject with SourceVmName, TargetVmName, Status ('Succeeded'|'Failed'),
        Error, LogEntries, and Summary hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [string]   $SourceSubscription,
        [Parameter(Mandatory = $true)]  [string]   $SourceResourceGroup,
        [Parameter(Mandatory = $true)]  [string]   $SourceVmName,
        [Parameter(Mandatory = $false)] [string]   $SnapshotNamePrefix       = 'snap-',
        [Parameter(Mandatory = $false)] [ValidateRange(1, 64)] [int] $DiskParallelThrottle = 6,
        [Parameter(Mandatory = $false)] [hashtable]$AdditionalTags           = @{},
        [Parameter(Mandatory = $false)] [string]   $BackendPoolNameOverride         = '',
        [Parameter(Mandatory = $false)] [string]   $TargetSubscriptionSuffix        = '',
        [Parameter(Mandatory = $false)] [string]   $TargetResourceGroupSuffix       = '',
        [Parameter(Mandatory = $false)] [string]   $TargetVnetNameSuffix            = '',
        [Parameter(Mandatory = $false)] [string]   $TargetVnetRgSuffix              = '',
        [Parameter(Mandatory = $false)] [string]   $TargetLbNameSuffix              = '',
        [Parameter(Mandatory = $false)] [string]   $TargetLbRgSuffix                = '',
        [Parameter(Mandatory = $false)] [string]   $TargetDesNameSuffix             = '',
        [Parameter(Mandatory = $false)] [string]   $TargetDesRgSuffix               = '',
        [Parameter(Mandatory = $false)] [string]   $TargetAsgNameSuffix             = '',
        [Parameter(Mandatory = $false)] [string]   $LogStorageAccountName           = '',
        [Parameter(Mandatory = $false)] [string]   $LogContainerName                = '',
        [Parameter(Mandatory = $true)]  [guid]     $SessionId,
        [string]$Criticita = '',
        [string]$Acronimo = '',
        [switch]$PreflightOnly
    )

    # Use suffix parameters directly (no fallback logic)
    $effSubSuffix      = $TargetSubscriptionSuffix
    $effRgSuffix       = $TargetResourceGroupSuffix
    $effVnetNameSuffix = $TargetVnetNameSuffix
    $effVnetRgSuffix   = $TargetVnetRgSuffix
    $effLbNameSuffix   = $TargetLbNameSuffix
    $effLbRgSuffix     = $TargetLbRgSuffix
    $effDesNameSuffix  = $TargetDesNameSuffix
    $effDesRgSuffix    = $TargetDesRgSuffix
    $effAsgNameSuffix  = $TargetAsgNameSuffix

    $script:LogBuffer = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $script:LogMetadata = @{ SessionId = $SessionId.ToString('D'); Criticita = $Criticita; Acronimo = $Acronimo }
    Set-DRAuditContext -SessionId $SessionId.ToString('D') -VmName $SourceVmName -Criticita $Criticita -Acronimo $Acronimo `
        -Phase $(if ($PreflightOnly) { 'Preflight' } else { 'Replication' }) -Stage Initialization
    $summary = [ordered]@{
        SnapshotsCreated         = [System.Collections.Generic.List[string]]::new()
        SnapshotsReused          = [System.Collections.Generic.List[string]]::new()
        DisksCreated             = [System.Collections.Generic.List[string]]::new()
        DisksReused              = [System.Collections.Generic.List[string]]::new()
        NicsCreated              = [System.Collections.Generic.List[string]]::new()
        NicsReused               = [System.Collections.Generic.List[string]]::new()
        VmsCreated               = [System.Collections.Generic.List[string]]::new()
        VmsReused                = [System.Collections.Generic.List[string]]::new()
        BackendPoolAttached      = [System.Collections.Generic.List[string]]::new()
        BackendPoolAlreadyMember = [System.Collections.Generic.List[string]]::new()
    }

    $result = [ordered]@{
        SessionId = $SessionId.ToString('D')
        SourceVmName = $SourceVmName
        SourceSubscriptionId = $null
        SourceResourceGroup = $SourceResourceGroup
        TargetSubscriptionId = $null
        TargetVmName = $null
        Status       = 'Running'
        Error        = $null
        Summary      = $null
        LogEntries   = $null
    }

    try {
        # Track current stage for error reporting
        $currentStage = 'Initialization'

        # ── Resolve subscriptions ───────────────────────────────────────────────
        Write-Log "Resolving subscriptions." -VmName $SourceVmName

        $script:LogPrefix = $null
        if ([string]::IsNullOrWhiteSpace($env:SOURCE_IDENTITY_CLIENT_ID) -or
            [string]::IsNullOrWhiteSpace($env:TARGET_IDENTITY_CLIENT_ID) -or
            [string]::IsNullOrWhiteSpace($env:HOSTING_SUBSCRIPTION_ID)) {
            throw 'SOURCE_IDENTITY_CLIENT_ID, TARGET_IDENTITY_CLIENT_ID and HOSTING_SUBSCRIPTION_ID must be configured.'
        }
        Disable-AzContextAutosave -Scope Process | Out-Null
        $sourceLogin = (Invoke-DRControlOperation 'Connect-AzAccount' @{
            Identity = $true; AccountId = $env:SOURCE_IDENTITY_CLIENT_ID; Subscription = $env:HOSTING_SUBSCRIPTION_ID
            SkipContextPopulation = $true; Scope = 'Process'
        } -IdentityClientId $env:SOURCE_IDENTITY_CLIENT_ID).Context
        $sourceSub = Resolve-Subscription -SubscriptionIdentifier $SourceSubscription `
            -DefaultProfile $sourceLogin -TenantId $sourceLogin.Tenant.Id
        $script:SourceContext = (Invoke-DRControlOperation 'Connect-AzAccount' @{
            Identity = $true; AccountId = $env:SOURCE_IDENTITY_CLIENT_ID; Tenant = $sourceSub.TenantId
            Subscription = $sourceSub.Id; SkipContextPopulation = $true; Scope = 'Process'
        } -IdentityClientId $env:SOURCE_IDENTITY_CLIENT_ID).Context
        $result.SourceSubscriptionId = [string]$sourceSub.Id
        $script:LogPrefix = Get-DRLogPrefix -SourceSubscriptionId $sourceSub.Id `
            -SourceResourceGroup $SourceResourceGroup -SourceVmName $SourceVmName
        if (-not [string]::IsNullOrWhiteSpace($LogStorageAccountName)) {
            $script:LogStorageContext = New-AzStorageContext -StorageAccountName $LogStorageAccountName `
                -UseConnectedAccount -ErrorAction Stop
        }
        $targetLogin = (Invoke-DRControlOperation 'Connect-AzAccount' @{
            Identity = $true; AccountId = $env:TARGET_IDENTITY_CLIENT_ID; Tenant = $sourceSub.TenantId
            SkipContextPopulation = $true; Scope = 'Process'
        } -IdentityClientId $env:TARGET_IDENTITY_CLIENT_ID).Context
        $targetSubscriptions = @(Invoke-DRControlOperation 'Get-AzSubscription' @{ TenantId = $sourceSub.TenantId; DefaultProfile = $targetLogin })
        $targetSub = Resolve-DRSubscription -SourceSubscription $sourceSub -Subscriptions $targetSubscriptions -Suffix $effSubSuffix
        $script:TargetContext = (Invoke-DRControlOperation 'Connect-AzAccount' @{
            Identity = $true; AccountId = $env:TARGET_IDENTITY_CLIENT_ID; Tenant = $targetSub.TenantId
            Subscription = $targetSub.Id; SkipContextPopulation = $true; Scope = 'Process'
        } -IdentityClientId $env:TARGET_IDENTITY_CLIENT_ID).Context
        $result.TargetSubscriptionId = [string]$targetSub.Id

        Write-Log "Source sub: '$($sourceSub.Name)' | Target sub: '$($targetSub.Name)'" -VmName $SourceVmName
        Write-DRAuditEvent -Operation 'Resolve source and DR subscriptions' -ResourceId "/subscriptions/$($sourceSub.Id)" `
            -Details @{ source = @{ id = $sourceSub.Id; name = $sourceSub.Name }; target = @{ id = $targetSub.Id; name = $targetSub.Name } }

        # Derived target resource groups
        $targetVmRg = "${SourceResourceGroup}${effRgSuffix}"
        $targetDiskRg = $targetVmRg

        # ── Stage A: Discover source VM configuration ───────────────────────────
        $currentStage = 'A'
        Set-DRAuditContext -Stage $currentStage
        Write-Log 'Stage A: Discovering source VM configuration.' -VmName $SourceVmName
        Set-SubscriptionContext -SubscriptionId $sourceSub.Id -FriendlyName $sourceSub.Name -Source

        $sourceVm = Invoke-WithRetry -Operation "Get-AzVM $SourceVmName" -ScriptBlock {
            Invoke-DRControlOperation 'Get-AzVM' @{ ResourceGroupName = $SourceResourceGroup; Name = $SourceVmName; DefaultProfile = $script:SourceContext }
        }
        $result.TargetVmName = $sourceVm.Name

        # Primary NIC
        $nicRef = $sourceVm.NetworkProfile.NetworkInterfaces |
                  Where-Object { $_.Primary } | Select-Object -First 1
        if ($null -eq $nicRef) {
            $nicRef = $sourceVm.NetworkProfile.NetworkInterfaces | Select-Object -First 1
        }
        if ($null -eq $nicRef) { throw "Source VM '$SourceVmName' has no network interfaces." }

        $sourceNicRg   = Get-IdSegmentValue -ResourceId $nicRef.Id -SegmentName 'resourceGroups'
        $sourceNicName = Get-LastNameFromId  -ResourceId $nicRef.Id

        $sourceNic = Invoke-WithRetry -Operation "Get-AzNetworkInterface $sourceNicName" -ScriptBlock {
            Invoke-DRControlOperation 'Get-AzNetworkInterface' @{ ResourceGroupName = $sourceNicRg; Name = $sourceNicName; DefaultProfile = $script:SourceContext }
        }
        $targetNicRg = "$sourceNicRg$effRgSuffix"

        $sourceIpConfig = $sourceNic.IpConfigurations | Where-Object { $_.Primary } | Select-Object -First 1
        if ($null -eq $sourceIpConfig) {
            $sourceIpConfig = $sourceNic.IpConfigurations | Select-Object -First 1
        }
        if ($null -eq $sourceIpConfig) { throw "Source NIC '$sourceNicName' has no IP configurations." }

        # Discover Application Security Groups on source NIC (all IP configs)
        $srcAsgIds = @()
        foreach ($ipCfg in $sourceNic.IpConfigurations) {
            if ($ipCfg.ApplicationSecurityGroups) {
                foreach ($asg in $ipCfg.ApplicationSecurityGroups) {
                    if (-not [string]::IsNullOrWhiteSpace($asg.Id)) {
                        $srcAsgIds += [string]$asg.Id
                    }
                }
            }
        }
        $srcAsgIds = @($srcAsgIds | Sort-Object -Unique)
        if ($srcAsgIds.Count -gt 0) {
            $asgNames = ($srcAsgIds | ForEach-Object { Get-LastNameFromId -ResourceId $_ }) -join ', '
            Write-Log "Source NIC '$sourceNicName' has $($srcAsgIds.Count) ASG(s): $asgNames." -VmName $SourceVmName
        } else {
            Write-Log "Source NIC '$sourceNicName' has no Application Security Groups." -VmName $SourceVmName
        }

        # Discover VNet and derive target VNet/RG
        $sourceSubnetId   = $sourceIpConfig.Subnet.Id
        $targetSubnetName = Get-IdSegmentValue -ResourceId $sourceSubnetId -SegmentName 'subnets'
        $srcVnetName      = Get-IdSegmentValue -ResourceId $sourceSubnetId -SegmentName 'virtualNetworks'
        $srcVnetRg        = Get-IdSegmentValue -ResourceId $sourceSubnetId -SegmentName 'resourceGroups'
        $targetVnetName   = "${srcVnetName}${effVnetNameSuffix}"
        $targetVnetRg     = "${srcVnetRg}${effVnetRgSuffix}"

        if ([string]::IsNullOrWhiteSpace($targetSubnetName)) {
            throw "Could not determine subnet name from source NIC IP configuration."
        }

        $sourceVnet = Invoke-DRControlOperation 'Get-AzVirtualNetwork' @{
            ResourceGroupName = $srcVnetRg; Name = $srcVnetName; DefaultProfile = $script:SourceContext
        }
        $sourceSubnet = @($sourceVnet.Subnets | Where-Object Name -eq $targetSubnetName)
        if ($sourceSubnet.Count -ne 1) { throw "Source subnet '$sourceSubnetId' is missing or ambiguous." }
        foreach ($ip in $sourceNic.IpConfigurations) {
            if ((Normalize $ip.Subnet.Id) -ne (Normalize $sourceSubnetId)) {
                throw 'All IP configurations of the replicated NIC must use the discovered subnet.'
            }
        }
        $asgReferences = @($srcAsgIds | ForEach-Object {
            Resolve-DRResourceReference $_ 'Microsoft.Network/applicationSecurityGroups' $targetSub.Id $effAsgNameSuffix $effVnetRgSuffix
        })
        $sourceNicNsg = Get-OptionalProp $sourceNic 'NetworkSecurityGroup'
        $sourceSubnetNsg = Get-OptionalProp $sourceSubnet[0] 'NetworkSecurityGroup'
        $sourceNsgIds = @(@($sourceNicNsg, $sourceSubnetNsg) | Where-Object { $_ -and $_.Id } |
            ForEach-Object { [string]$_.Id } | Sort-Object -Unique)
        $nsgReferences = @($sourceNsgIds | ForEach-Object {
            Resolve-DRResourceReference $_ 'Microsoft.Network/networkSecurityGroups' $targetSub.Id $effVnetNameSuffix $effVnetRgSuffix
        })
        $loadBalancerReferences = @(Get-DRLoadBalancerReferences -IpConfigurations @($sourceNic.IpConfigurations) `
            -TargetSubscriptionId $targetSub.Id -NameSuffix $effLbNameSuffix -ResourceGroupSuffix $effLbRgSuffix)
        $sourceIpDetails = @($sourceNic.IpConfigurations | ForEach-Object {
            @{
                name = $_.Name; primary = $_.Primary; privateIp = $_.PrivateIpAddress; allocation = $_.PrivateIpAllocationMethod
                subnetId = $_.Subnet.Id
                asgIds = @(@(Get-OptionalProp $_ 'ApplicationSecurityGroups') | Where-Object { $_ } | ForEach-Object { $_.Id })
                backendPoolIds = @(@(Get-OptionalProp $_ 'LoadBalancerBackendAddressPools') | Where-Object { $_ } | ForEach-Object { $_.Id })
            }
        })
        Write-DRAuditEvent -Operation 'Discover VM and networking configuration' -ResourceId $sourceVm.Id `
            -Details @{
                sourceVm = @{ id = $sourceVm.Id; name = $sourceVm.Name; resourceGroup = $SourceResourceGroup; size = $sourceVm.HardwareProfile.VmSize
                    networkInterfaceIds = @($sourceVm.NetworkProfile.NetworkInterfaces.Id) }
                sourceNic = @{ id = $sourceNic.Id; resourceGroup = $sourceNicRg; ipConfigurations = $sourceIpDetails
                    networkSecurityGroupId = $(if ($sourceNicNsg) { $sourceNicNsg.Id } else { $null }) }
                sourceVnetId = $sourceVnet.Id
                sourceSubnetNetworkSecurityGroupId = $(if ($sourceSubnetNsg) { $sourceSubnetNsg.Id } else { $null })
                targetVmResourceGroup = $targetVmRg; targetNicResourceGroup = $targetNicRg
                targetVnet = @{ name = $targetVnetName; resourceGroup = $targetVnetRg; subnet = $targetSubnetName }
                asgs = $asgReferences; nsgs = $nsgReferences; loadBalancers = $loadBalancerReferences
            }
        Write-Log "Resolved $($loadBalancerReferences.Count) Load Balancer(s) from complete source IDs; NIC target RG='$targetNicRg', VNet target RG='$targetVnetRg'." -VmName $SourceVmName

        # Upload Stage A log
        Upload-StageLog -VmName $SourceVmName -StageId 'A' -StageDescription 'Discover' -Failed $false `
            -LogStorageAccountName $LogStorageAccountName -LogContainerName $LogContainerName -SessionId $SessionId
        $script:LogBuffer = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        # Disks
        $vmDiskControllerType = Get-OptionalProp -Object $sourceVm.StorageProfile -PropertyName 'DiskControllerType'
        $diskList = [System.Collections.Generic.List[object]]::new()

        $osAttach = $sourceVm.StorageProfile.OsDisk
        if ($null -eq $osAttach.ManagedDisk -or [string]::IsNullOrWhiteSpace($osAttach.ManagedDisk.Id)) {
            throw "Source VM OS disk is not a managed disk."
        }

        $osDiskId   = $osAttach.ManagedDisk.Id
        $osDiskRg   = Get-IdSegmentValue -ResourceId $osDiskId -SegmentName 'resourceGroups'
        $osDiskName = Get-LastNameFromId  -ResourceId $osDiskId
        $osDisk     = Invoke-WithRetry -Operation "Get-AzDisk $osDiskName" -ScriptBlock {
            Invoke-DRControlOperation 'Get-AzDisk' @{ ResourceGroupName = $osDiskRg; DiskName = $osDiskName; DefaultProfile = $script:SourceContext }
        }

        # Discover Disk Encryption Set from OS disk and derive target DES/RG
        $desSourceId = [string](Get-OptionalProp -Object $osDisk.Encryption -PropertyName 'DiskEncryptionSetId')
        if ([string]::IsNullOrWhiteSpace($desSourceId)) {
            throw "OS disk '$osDiskName' has no Disk Encryption Set. DES is required for encrypted DR replication."
        }
        $srcDesName    = Get-LastNameFromId  -ResourceId $desSourceId
        $srcDesRg      = Get-IdSegmentValue  -ResourceId $desSourceId -SegmentName 'resourceGroups'
        $targetDesName = "${srcDesName}${effDesNameSuffix}"
        $targetDesRg   = "${srcDesRg}${effDesRgSuffix}"

        $osSP = Get-OptionalProp -Object $osDisk -PropertyName 'SharingProfile'
        [void]$diskList.Add([pscustomobject]@{
            Name                       = $osDisk.Name
            SourceDiskId               = $osDisk.Id
            SourceLocation             = [string]$osDisk.Location
            SizeGB                     = Get-OptionalProp $osDisk 'DiskSizeGB'
            Role                       = 'OS'
            Lun                        = $null
            Caching                    = [string]$osAttach.Caching
            SkuName                    = [string]$osDisk.Sku.Name
            Tier                       = [string](Get-OptionalProp -Object $osDisk -PropertyName 'Tier')
            Zones                      = @($osDisk.Zones)
            MaxShares                  = [int](Get-OptionalProp -Object $osDisk -PropertyName 'MaxShares')
            SharingProfile             = $osSP
            OptimizedForFrequentAttach = (Get-OptionalProp -Object $osSP -PropertyName 'OptimizedForFrequentAttach')
            EncryptionType             = [string](Get-OptionalProp -Object $osDisk.Encryption -PropertyName 'Type')
            DiskControllerType         = $vmDiskControllerType
            OsType                     = [string]$osAttach.OsType
            HyperVGeneration           = [string](Get-OptionalProp -Object $osDisk -PropertyName 'HyperVGeneration')
        })

        foreach ($dAttach in @($sourceVm.StorageProfile.DataDisks | Sort-Object LUN)) {
            if ($null -eq $dAttach.ManagedDisk -or [string]::IsNullOrWhiteSpace($dAttach.ManagedDisk.Id)) {
                throw "Data disk '$($dAttach.Name)' is not a managed disk."
            }
            $dId   = $dAttach.ManagedDisk.Id
            $dRg   = Get-IdSegmentValue -ResourceId $dId -SegmentName 'resourceGroups'
            $dName = Get-LastNameFromId  -ResourceId $dId
            $dDisk = Invoke-WithRetry -Operation "Get-AzDisk $dName" -ScriptBlock {
                Invoke-DRControlOperation 'Get-AzDisk' @{ ResourceGroupName = $dRg; DiskName = $dName; DefaultProfile = $script:SourceContext }
            }
            $dSP = Get-OptionalProp -Object $dDisk -PropertyName 'SharingProfile'
            [void]$diskList.Add([pscustomobject]@{
                Name                       = $dDisk.Name
                SourceDiskId               = $dDisk.Id
                SourceLocation             = [string]$dDisk.Location
                SizeGB                     = Get-OptionalProp $dDisk 'DiskSizeGB'
                Role                       = 'Data'
                Lun                        = [int]$dAttach.Lun
                Caching                    = [string]$dAttach.Caching
                SkuName                    = [string]$dDisk.Sku.Name
                Tier                       = [string](Get-OptionalProp -Object $dDisk -PropertyName 'Tier')
                Zones                      = @($dDisk.Zones)
                MaxShares                  = [int](Get-OptionalProp -Object $dDisk -PropertyName 'MaxShares')
                SharingProfile             = $dSP
                OptimizedForFrequentAttach = (Get-OptionalProp -Object $dSP -PropertyName 'OptimizedForFrequentAttach')
                EncryptionType             = [string](Get-OptionalProp -Object $dDisk.Encryption -PropertyName 'Type')
                DiskControllerType         = $vmDiskControllerType
                OsType                     = $null
                HyperVGeneration           = [string](Get-OptionalProp -Object $dDisk -PropertyName 'HyperVGeneration')
            })
        }

        $diskInfos    = @($diskList)
        $targetVmTags = Build-TargetTags -SourceTags $sourceVm.Tags -Prefix '' -ExtraTags $AdditionalTags
        Write-DRAuditEvent -Operation 'Discover OS and data disks and select DR encryption' -ResourceId $sourceVm.Id `
            -Details @{ disks = $diskInfos; sourceDesId = $desSourceId; targetDesName = $targetDesName; targetDesResourceGroup = $targetDesRg
                targetDiskResourceGroup = $targetDiskRg; diskControllerType = $vmDiskControllerType }

        Write-Log ("Stage A complete. VM='$($sourceVm.Name)' Size='$($sourceVm.HardwareProfile.VmSize)' | " +
                   "Disks=$($diskInfos.Count) | ASGs=$($srcAsgIds.Count) | " +
                   "TargetSub='$($targetSub.Name)' | TargetRG='$targetVmRg' | " +
                   "TargetVNet='$targetVnetName' | TargetDES='$targetDesName'") -VmName $SourceVmName

        # Stage B: Validate direct managed disk copy before creating target resources
        $currentStage = 'B'
        Set-DRAuditContext -Stage $currentStage
        Write-Log 'Stage B: Validating direct managed disk copy.' -VmName $SourceVmName
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name

        # Get DES first (must exist) to determine target location
        $des = Invoke-WithRetry -Operation "Get-AzDiskEncryptionSet $targetDesName" -ScriptBlock {
            Invoke-DRControlOperation 'Get-AzDiskEncryptionSet' @{ ResourceGroupName = $targetDesRg; Name = $targetDesName; DefaultProfile = $script:TargetContext }
        }
        if ($null -eq $des) { throw "Target DES '$targetDesName' not found in RG '$targetDesRg'." }

        $targetLocation = $des.Location
        $targetEncryptionType = [string](Get-OptionalProp -Object $des -PropertyName 'EncryptionType')
        if ($targetEncryptionType -notin @('EncryptionAtRestWithCustomerKey', 'EncryptionAtRestWithPlatformAndCustomerKeys')) {
            throw "Target DES '$targetDesName' must specify a supported customer-managed encryption type."
        }
        Write-Log "Target location: $targetLocation (from DES). Target RG: '$targetDiskRg' (must pre-exist)." -VmName $SourceVmName
        $sourceTenantId = [string]$script:SourceContext.Tenant.Id
        $targetTenantId = [string]$script:TargetContext.Tenant.Id
        if ([string]::IsNullOrWhiteSpace($sourceTenantId) -or [string]::IsNullOrWhiteSpace($targetTenantId) -or
            (Normalize $sourceTenantId) -ne (Normalize $targetTenantId)) {
            throw 'Direct managed disk copy requires source and target subscriptions in the same Microsoft Entra tenant.'
        }
        foreach ($disk in $diskInfos) {
            if ([string]::IsNullOrWhiteSpace($disk.SourceLocation) -or
                (Normalize $disk.SourceLocation) -ne (Normalize $targetLocation)) {
                throw "Direct managed disk copy requires the same region. Source disk '$($disk.Name)' is in '$($disk.SourceLocation)'; target DES is in '$targetLocation'. Cross-region copy is not supported by this workflow."
            }
        }
        Write-Log 'Stage B complete. Direct copy validated; no snapshots are created or reused.' -VmName $SourceVmName
        $prerequisites = Get-DRPrerequisites -VmName $SourceVmName -VmResourceGroup $targetVmRg `
            -VnetResourceGroup $targetVnetRg -VnetName $targetVnetName -SubnetName $targetSubnetName `
            -AsgReferences $asgReferences -NsgReferences $nsgReferences -DesResourceGroup $targetDesRg `
            -LoadBalancerReferences $loadBalancerReferences -NicResourceGroup $targetNicRg -PoolNameOverride $BackendPoolNameOverride `
            -DefaultProfile $script:TargetContext

        # Upload Stage B log
        Upload-StageLog -VmName $SourceVmName -StageId 'B' -StageDescription 'DiskCopyValidation' -Failed $false `
            -LogStorageAccountName $LogStorageAccountName -LogContainerName $LogContainerName -SessionId $SessionId
        $script:LogBuffer = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        if ($PreflightOnly) {
            $result.Status = 'Succeeded'
            $result.LogEntries = @($script:LogBuffer)
            return [pscustomobject]$result
        }

        # Stage C: Create managed disks directly from source managed disks
        $currentStage = 'C'
        Set-DRAuditContext -Stage $currentStage
        Write-Log 'Stage C: Creating/reusing managed disks directly from source managed disks.' -VmName $SourceVmName
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name

        # Verify and log current context
        $currentCtx = Get-AzContext
        Write-Log "Stage C context verified: $($currentCtx.Subscription.Name) ($($currentCtx.Subscription.Id))" -VmName $SourceVmName
        if ($currentCtx.Subscription.Id -ne $targetSub.Id) {
            throw "Stage C context mismatch! Expected: $($targetSub.Id), Current: $($currentCtx.Subscription.Id)"
        }

        $supportsTier                       = (Get-Command New-AzDiskConfig).Parameters.ContainsKey('Tier')
        $supportsMaxShares                  = (Get-Command New-AzDiskConfig).Parameters.ContainsKey('MaxSharesCount')
        $supportsOptimizedForFrequentAttach = (Get-Command New-AzDiskConfig).Parameters.ContainsKey('OptimizedForFrequentAttach')
        $supportsZone                       = (Get-Command New-AzDiskConfig).Parameters.ContainsKey('Zone')

        $targetDisksByName = @{}
        foreach ($disk in $diskInfos) {
            $existingDisk = Invoke-DRControlOperation 'Get-AzDisk' @{ ResourceGroupName = $targetDiskRg; DiskName = $disk.Name; DefaultProfile = $script:TargetContext } -AllowNotFound
            if ($existingDisk) {
                $ok = (Normalize $existingDisk.CreationData.SourceResourceId) -eq (Normalize $disk.SourceDiskId) -and
                      (Normalize $existingDisk.Location) -eq (Normalize $targetLocation) -and
                      (Normalize $existingDisk.ProvisioningState) -eq 'succeeded' -and
                      (Normalize $existingDisk.Sku.Name)  -eq (Normalize $disk.SkuName) -and
                      (Normalize (Get-OptionalProp -Object $existingDisk.Encryption -PropertyName 'DiskEncryptionSetId')) -eq (Normalize $des.Id) -and
                      (Normalize $existingDisk.Encryption.Type) -eq (Normalize $targetEncryptionType) -and
                      (Compare-StringArrays -A @($existingDisk.Zones) -B @($disk.Zones)) -and
                      ([int](Get-OptionalProp -Object $existingDisk -PropertyName 'MaxShares')) -eq ([int]$disk.MaxShares)
                if (-not $ok) {
                    throw "Disk '$($disk.Name)' exists but configuration does not match (source disk/location/provisioning/SKU/DES/encryption/zones/shares). Disks created from snapshots cannot be resumed in direct-copy mode; no existing disk is overwritten or deleted."
                }
                $targetDisksByName[$disk.Name] = $existingDisk
                [void]$summary.DisksReused.Add($disk.Name)
                Write-Log "  Disk reused: '$($disk.Name)'. Contents are not refreshed from the source." -VmName $SourceVmName
                continue
            }

            $cfgArgs = @{
                Location            = $targetLocation
                CreateOption        = 'Copy'
                SourceResourceId    = $disk.SourceDiskId
                SkuName             = $disk.SkuName
                DiskEncryptionSetId = $des.Id
                EncryptionType      = $targetEncryptionType
            }
            if ($supportsTier -and -not [string]::IsNullOrWhiteSpace($disk.Tier)) { $cfgArgs['Tier'] = $disk.Tier }
            if ($supportsZone -and $disk.Zones -and $disk.Zones.Count -gt 0)      { $cfgArgs['Zone'] = @($disk.Zones) }
            if ($supportsMaxShares -and [int]$disk.MaxShares -gt 1)               { $cfgArgs['MaxSharesCount'] = [int]$disk.MaxShares }
            if ($supportsOptimizedForFrequentAttach -and $null -ne $disk.OptimizedForFrequentAttach) {
                $cfgArgs['OptimizedForFrequentAttach'] = [bool]$disk.OptimizedForFrequentAttach
            }

            $diskConfig = Invoke-WithRetry -Operation "New-AzDiskConfig $($disk.Name)" -ScriptBlock { New-AzDiskConfig @cfgArgs -ErrorAction Stop }
            $newDisk    = Invoke-WithRetry -Operation "New-AzDisk $($disk.Name)" -ScriptBlock {
                Invoke-DRControlOperation 'New-AzDisk' @{ ResourceGroupName = $targetDiskRg; DiskName = $disk.Name; Disk = $diskConfig; DefaultProfile = $script:TargetContext }
            }
            $targetDisksByName[$disk.Name] = $newDisk
            [void]$summary.DisksCreated.Add($disk.Name)
            Write-Log "  Disk created: '$($disk.Name)' directly from '$($disk.SourceDiskId)'." -VmName $SourceVmName
        }
        Write-Log "Stage C complete. Disks=$($diskInfos.Count)" -VmName $SourceVmName

        # Upload Stage C log
        Upload-StageLog -VmName $SourceVmName -StageId 'C' -StageDescription 'Disks' -Failed $false `
            -LogStorageAccountName $LogStorageAccountName -LogContainerName $LogContainerName -SessionId $SessionId
        $script:LogBuffer = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        # ── Stage D: Create target NIC + VM ─────────────────────────────────────
        $currentStage = 'D'
        Set-DRAuditContext -Stage $currentStage
        Write-Log 'Stage D: Creating/reusing NIC and VM.' -VmName $SourceVmName
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name

        # Verify and log current context
        $currentCtx = Get-AzContext
        Write-Log "Stage D context verified: $($currentCtx.Subscription.Name) ($($currentCtx.Subscription.Id))" -VmName $SourceVmName
        if ($currentCtx.Subscription.Id -ne $targetSub.Id) {
            throw "Stage D context mismatch! Expected: $($targetSub.Id), Current: $($currentCtx.Subscription.Id)"
        }

        # Target VM resource group must pre-exist (operations will fail if it doesn't)
        Write-Log "Target VM RG: '$targetVmRg' (must pre-exist in subscription '$($targetSub.Name)')." -VmName $SourceVmName

        # Re-establish target subscription context before VNet lookup
        Write-Log "Re-establishing target subscription context before VNet lookup." -VmName $SourceVmName
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
        $currentCtx = Get-AzContext
        Write-Log "Context before VNet lookup verified: $($currentCtx.Subscription.Name) ($($currentCtx.Subscription.Id))" -VmName $SourceVmName
        if ($currentCtx.Subscription.Id -ne $targetSub.Id) {
            throw "Context mismatch before VNet lookup! Expected: $($targetSub.Id), Current: $($currentCtx.Subscription.Id)"
        }

        $targetSubnet = $prerequisites.Subnet

        # Log the subnet ID to verify it contains correct subscription
        Write-Log "Target subnet ID: $($targetSubnet.Id)" -VmName $SourceVmName

        $targetVmName  = [string]$sourceVm.Name
        $targetNicName = "$targetVmName-nic"

        # Re-establish target subscription context before ASG lookup
        Write-Log "Re-establishing target subscription context before ASG and NIC operations." -VmName $SourceVmName
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
        $currentCtx = Get-AzContext
        Write-Log "Context before ASG/NIC operations verified: $($currentCtx.Subscription.Name) ($($currentCtx.Subscription.Id))" -VmName $SourceVmName
        if ($currentCtx.Subscription.Id -ne $targetSub.Id) {
            throw "Context mismatch before ASG/NIC operations! Expected: $($targetSub.Id), Current: $($currentCtx.Subscription.Id)"
        }

        # NIC - re-verify context before Get to prevent context drift
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
        $targetNic = Invoke-DRControlOperation 'Get-AzNetworkInterface' @{
            ResourceGroupName = $targetNicRg; Name = $targetNicName; DefaultProfile = $script:TargetContext
        } -AllowNotFound
        if ($null -eq $targetNic) {
            $ipConfigurations = @(
                foreach ($sourceIp in $sourceNic.IpConfigurations) {
                    if ([string]::IsNullOrWhiteSpace([string]$sourceIp.PrivateIpAddress)) {
                        throw "Source IP configuration '$($sourceIp.Name)' has no private address to preserve."
                    }
                    $ipCfgArgs = @{
                        Name = [string]$sourceIp.Name; SubnetId = $targetSubnet.Id
                        Primary = $sourceIp.Name -eq $sourceIpConfig.Name; PrivateIpAddress = [string]$sourceIp.PrivateIpAddress
                    }
                    $asgIds = @(@(Get-OptionalProp $sourceIp 'ApplicationSecurityGroups') | Where-Object { $_ } |
                        ForEach-Object { $prerequisites.AsgsBySourceId[[string]$_.Id] })
                    if ($asgIds.Count -gt 0) { $ipCfgArgs['ApplicationSecurityGroupId'] = $asgIds }
                    New-AzNetworkInterfaceIpConfig @ipCfgArgs -ErrorAction Stop
                    Write-Log "Target IP configuration '$($sourceIp.Name)' will use '$($sourceIp.PrivateIpAddress)' statically on '$($targetSubnet.Id)'." -VmName $SourceVmName
                }
            )
            $nicArguments = @{
                ResourceGroupName = $targetNicRg; Location = $targetLocation
                Name = $targetNicName; IpConfiguration = $ipConfigurations
                Tag = $targetVmTags; DefaultProfile = $script:TargetContext
            }
            if ($sourceNicNsg) { $nicArguments['NetworkSecurityGroupId'] = $prerequisites.NsgsBySourceId[[string]$sourceNicNsg.Id] }
            # Re-verify context immediately before New-AzNetworkInterface
            Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
            $targetNic = Invoke-WithRetry -Operation "New-AzNetworkInterface $targetNicName" -ScriptBlock {
                Invoke-DRControlOperation 'New-AzNetworkInterface' $nicArguments
            }
            [void]$summary.NicsCreated.Add($targetNicName)
            Write-Log "Created NIC '$targetNicName' in RG '$targetNicRg' with $($ipConfigurations.Count) IP configuration(s)." -VmName $SourceVmName
        }
        else {
            foreach ($sourceIp in $sourceNic.IpConfigurations) {
                $matching = @($targetNic.IpConfigurations | Where-Object Name -eq $sourceIp.Name)
                if ($matching.Count -ne 1) { throw "Existing NIC '$targetNicName' is missing IP configuration '$($sourceIp.Name)'." }
                $existingIp = $matching[0]
                if ((Normalize $existingIp.Subnet.Id) -ne (Normalize $targetSubnet.Id) -or
                    (Normalize $existingIp.PrivateIpAllocationMethod) -ne 'static' -or
                    (Normalize $existingIp.PrivateIpAddress) -ne (Normalize $sourceIp.PrivateIpAddress)) {
                    throw "Existing NIC '$targetNicName' IP configuration '$($sourceIp.Name)' has a different subnet, allocation or private address."
                }
                $expectedAsgs = @(@(Get-OptionalProp $sourceIp 'ApplicationSecurityGroups') | Where-Object { $_ } |
                    ForEach-Object { $prerequisites.AsgsBySourceId[[string]$_.Id] })
                $existingAsgs = @(@(Get-OptionalProp $existingIp 'ApplicationSecurityGroups') | Where-Object { $_ } | ForEach-Object { $_.Id })
                if (-not (Compare-StringArrays $existingAsgs $expectedAsgs)) {
                    Write-Log "Reused NIC '$targetNicName' IP '$($sourceIp.Name)' has different ASG memberships. External security configuration is not reconciled; manual review is required." 'WARN' -VmName $SourceVmName
                }
            }
            [void]$summary.NicsReused.Add($targetNicName)
            Write-Log "Reused NIC '$targetNicName' in RG '$targetNicRg'; existing external settings were retained." -VmName $SourceVmName
        }
        Write-DRAuditEvent -Operation 'Select target NIC configuration' -ResourceId $targetNic.Id -Details @{
            sourceNicId = $sourceNic.Id; targetNicId = $targetNic.Id
            sourceIpConfigurations = $sourceIpDetails; created = $summary.NicsCreated.Contains($targetNicName)
            expectedNicNetworkSecurityGroupId = $(if ($sourceNicNsg) { $prerequisites.NsgsBySourceId[[string]$sourceNicNsg.Id] } else { $null })
        }

        $osDiskInfo   = $diskInfos | Where-Object { $_.Role -eq 'OS' } | Select-Object -First 1
        if ($null -eq $osDiskInfo)   { throw "OS disk not found in captured disk list." }
        $targetOsDisk = $targetDisksByName[$osDiskInfo.Name]
        if ($null -eq $targetOsDisk) { throw "Target OS disk '$($osDiskInfo.Name)' not found in target disk map." }

        # Re-verify context before Get-AzVM to prevent context drift
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
        $existingVm = Invoke-DRControlOperation 'Get-AzVM' @{
            ResourceGroupName = $targetVmRg; Name = $targetVmName; DefaultProfile = $script:TargetContext
        } -AllowNotFound
        if ($existingVm) {
            if ((Normalize $existingVm.HardwareProfile.VmSize) -ne (Normalize $sourceVm.HardwareProfile.VmSize)) {
                throw "Existing VM '$targetVmName' size mismatch (existing='$($existingVm.HardwareProfile.VmSize)' expected='$($sourceVm.HardwareProfile.VmSize)')."
            }
            if ((Normalize $existingVm.StorageProfile.OsDisk.ManagedDisk.Id) -ne (Normalize $targetOsDisk.Id)) {
                throw "Existing VM '$targetVmName' OS disk ID mismatch."
            }
            if (@($existingVm.NetworkProfile.NetworkInterfaces.Id) -notcontains $targetNic.Id) {
                throw "Existing VM '$targetVmName' is attached to a different NIC. Review the existing topology before retrying; no VM attachment is overwritten."
            }
            [void]$summary.VmsReused.Add($targetVmName)
            Write-Log "Reused VM '$targetVmName'." -VmName $SourceVmName
        }
        else {
            # Re-establish target subscription context before VM creation
            Write-Log "Re-establishing target subscription context before VM creation." -VmName $SourceVmName
            Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
            $currentCtx = Get-AzContext
            Write-Log "Context before VM creation verified: $($currentCtx.Subscription.Name) ($($currentCtx.Subscription.Id))" -VmName $SourceVmName
            if ($currentCtx.Subscription.Id -ne $targetSub.Id) {
                throw "Context mismatch before VM creation! Expected: $($targetSub.Id), Current: $($currentCtx.Subscription.Id)"
            }

            $vmArguments = @{ VMName = $targetVmName; VMSize = $sourceVm.HardwareProfile.VmSize; ErrorAction = 'Stop' }
            if ($vmDiskControllerType) { $vmArguments['DiskControllerType'] = $vmDiskControllerType }
            $vmConfig = New-AzVMConfig @vmArguments
            $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $targetNic.Id -Primary -ErrorAction Stop

            switch (Normalize $osDiskInfo.OsType) {
                'windows' { $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name $targetOsDisk.Name -ManagedDiskId $targetOsDisk.Id -CreateOption Attach -Windows -Caching $osDiskInfo.Caching -ErrorAction Stop }
                'linux'   { $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name $targetOsDisk.Name -ManagedDiskId $targetOsDisk.Id -CreateOption Attach -Linux   -Caching $osDiskInfo.Caching -ErrorAction Stop }
                default   { throw "Unsupported OS type '$($osDiskInfo.OsType)'." }
            }

            foreach ($d in @($diskInfos | Where-Object { $_.Role -eq 'Data' } | Sort-Object Lun)) {
                $mDisk = $targetDisksByName[$d.Name]
                if ($null -eq $mDisk) { throw "Target data disk '$($d.Name)' not found." }
                $vmConfig = Add-AzVMDataDisk -VM $vmConfig -Name $mDisk.Name -ManagedDiskId $mDisk.Id `
                    -Lun ([int]$d.Lun) -Caching $d.Caching -CreateOption Attach -ErrorAction Stop
            }

            $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Enable -ResourceGroupName $targetVmRg -ErrorAction Stop

            # Re-verify context immediately before New-AzVM
            Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
            Invoke-WithRetry -Operation "New-AzVM $targetVmName" -ScriptBlock {
                Invoke-DRControlOperation 'New-AzVM' @{
                    ResourceGroupName = $targetVmRg; Location = $targetLocation
                    VM = $vmConfig; Tag = $targetVmTags; DefaultProfile = $script:TargetContext
                } | Out-Null
            } | Out-Null

            [void]$summary.VmsCreated.Add($targetVmName)
            Write-Log "Created VM '$targetVmName'." -VmName $SourceVmName
        }

        # Upload Stage D log
        Upload-StageLog -VmName $SourceVmName -StageId 'D' -StageDescription 'NIC-VM' -Failed $false `
            -LogStorageAccountName $LogStorageAccountName -LogContainerName $LogContainerName -SessionId $SessionId
        $script:LogBuffer = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        # Stage E preserves every association without removing existing pools.
        if ($loadBalancerReferences.Count -gt 0) {
            $currentStage = 'E'
            Set-DRAuditContext -Stage $currentStage
            Write-Log 'Stage E: Attaching all source NIC IP configurations to their DR backend pools.' -VmName $SourceVmName
            Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name

            # Verify and log current context
            $currentCtx = Get-AzContext
            Write-Log "Stage E context verified: $($currentCtx.Subscription.Name) ($($currentCtx.Subscription.Id))" -VmName $SourceVmName
            if ($currentCtx.Subscription.Id -ne $targetSub.Id) {
                throw "Stage E context mismatch! Expected: $($targetSub.Id), Current: $($currentCtx.Subscription.Id)"
            }

            # Refresh NIC after VM creation
            $targetNic = Invoke-WithRetry -Operation "Refresh NIC $targetNicName" -ScriptBlock {
                Invoke-DRControlOperation 'Get-AzNetworkInterface' @{
                    ResourceGroupName = $targetNicRg; Name = $targetNicName; DefaultProfile = $script:TargetContext
                }
            }
            $attachments = [System.Collections.Generic.List[object]]::new()
            foreach ($reference in $loadBalancerReferences) {
                foreach ($poolReference in $reference.PoolReferences) {
                    $matching = @($targetNic.IpConfigurations | Where-Object Name -eq $poolReference.IpConfigurationName)
                    if ($matching.Count -ne 1) { throw "Target NIC IP '$($poolReference.IpConfigurationName)' is missing or ambiguous." }
                    $ip = $matching[0]
                    $pool = $prerequisites.PoolsBySourceId[$poolReference.SourceId]
                    $currentIds = @(@(Get-OptionalProp $ip 'LoadBalancerBackendAddressPools') | Where-Object { $_ } | ForEach-Object { $_.Id })
                    $description = "$targetNicName/$($ip.Name)->$($pool.Name)"
                    if ($currentIds -contains $pool.Id) {
                        [void]$summary.BackendPoolAlreadyMember.Add($description)
                        Write-Log "NIC '$($targetNic.Id)' IP '$($ip.Name)' is already in pool '$($pool.Id)'." -VmName $SourceVmName
                    } else {
                        $existingPools = @(@(Get-OptionalProp $ip 'LoadBalancerBackendAddressPools') | Where-Object { $_ })
                        $ip.LoadBalancerBackendAddressPools = $existingPools + @($pool)
                        $attachments.Add(@{ ipName = $ip.Name; poolId = $pool.Id; description = $description })
                        Write-Log "Planned association from source pool '$($poolReference.SourceId)' to '$($pool.Id)' on NIC IP '$($ip.Name)'." -VmName $SourceVmName
                    }
                }
            }
            if ($attachments.Count -gt 0) {
                Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
                Invoke-WithRetry -Operation 'Set-AzNetworkInterface (all LB pool attachments)' -ScriptBlock {
                    Invoke-DRControlOperation 'Set-AzNetworkInterface' @{
                        NetworkInterface = $targetNic; DefaultProfile = $script:TargetContext
                    } | Out-Null
                } | Out-Null
                $verifyNic = Invoke-DRControlOperation 'Get-AzNetworkInterface' @{
                    ResourceGroupName = $targetNicRg; Name = $targetNicName; DefaultProfile = $script:TargetContext
                }
                foreach ($attachment in $attachments) {
                    $verifiedIp = @($verifyNic.IpConfigurations | Where-Object Name -eq $attachment.ipName)[0]
                    $verifiedIds = @($verifiedIp.LoadBalancerBackendAddressPools | ForEach-Object { $_.Id })
                    if ($verifiedIds -notcontains $attachment.poolId) { throw "NIC '$($verifyNic.Id)' did not retain pool '$($attachment.poolId)'." }
                    [void]$summary.BackendPoolAttached.Add($attachment.description)
                    Write-Log "Verified backend association '$($verifyNic.Id)/ipConfigurations/$($attachment.ipName)' -> '$($attachment.poolId)'." -VmName $SourceVmName
                }
            }
        } else {
            Write-Log 'Stage E: Skipped (source VM has no load balancer).' -VmName $SourceVmName
        }

        # Upload Stage E log
        Upload-StageLog -VmName $SourceVmName -StageId 'E' -StageDescription 'LB-Attach' -Failed $false `
            -LogStorageAccountName $LogStorageAccountName -LogContainerName $LogContainerName -SessionId $SessionId
        $script:LogBuffer = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        # ── Completed ────────────────────────────────────────────────────────────
        Write-Log 'Replication completed successfully.' -VmName $SourceVmName

        # Upload completion marker log
        Upload-StageLog -VmName $SourceVmName -StageId 'Completed' -StageDescription 'Success' -Failed $false `
            -LogStorageAccountName $LogStorageAccountName -LogContainerName $LogContainerName -SessionId $SessionId

        $result.Status  = 'Succeeded'
        $result.Summary = [ordered]@{
            SnapshotsCreated         = @($summary.SnapshotsCreated)
            SnapshotsReused          = @($summary.SnapshotsReused)
            DisksCreated             = @($summary.DisksCreated)
            DisksReused              = @($summary.DisksReused)
            NicsCreated              = @($summary.NicsCreated)
            NicsReused               = @($summary.NicsReused)
            VmsCreated               = @($summary.VmsCreated)
            VmsReused                = @($summary.VmsReused)
            BackendPoolAttached      = @($summary.BackendPoolAttached)
            BackendPoolAlreadyMember = @($summary.BackendPoolAlreadyMember)
        }
        $result.LogEntries = @($script:LogBuffer)
    }
    catch {
        $hint = Get-RbacHint -Exception $_.Exception
        if ($hint) { Write-Log $hint 'WARN' -VmName $SourceVmName }
        Write-Log "Replication FAILED: $($_.Exception.Message)" 'ERROR' -VmName $SourceVmName
        $result.Status     = 'Failed'
        $result.Error      = Protect-DRAuditText $_.Exception.Message
        $result.LogEntries = @($script:LogBuffer)

        # Upload failed stage log
        Upload-StageLog -VmName $SourceVmName -StageId $currentStage -StageDescription 'Failed' -Failed $true `
            -LogStorageAccountName $LogStorageAccountName -LogContainerName $LogContainerName -SessionId $SessionId
    }

    return [pscustomobject]$result
}

Export-ModuleMember -Function Invoke-VMReplication, Resolve-DRSubscription, Resolve-Subscription, Get-DRLogPrefix

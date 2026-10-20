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
    $line   = "$ts [$Level] ${prefix}$Message"
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
            return & $ScriptBlock
        }
        catch {
            $retryable = $_.Exception.Message -match '429|TooManyRequests|temporar|timeout|throttl|InternalServerError|Conflict|Gateway|BadRequest|subscription|context|authorization'
            if ($attempt -ge $MaxAttempts -or -not $retryable) {
                throw "Operation '$Operation' failed after $attempt attempt(s). Error: $($_.Exception.Message)"
            }
            $delay = [Math]::Min(30, [int]($InitialDelaySeconds * [Math]::Pow(2, ($attempt - 1))))
            Write-Log "Transient failure in '$Operation'. Retrying in $delay s (attempt $attempt/$MaxAttempts)." 'WARN'
            Start-Sleep -Seconds $delay
        }
    }
}

function Resolve-Subscription {
    param([string]$SubscriptionIdentifier, [Parameter(Mandatory = $true)] [object]$DefaultProfile, [string]$TenantId)
    $subs = Invoke-WithRetry -Operation 'Get-AzSubscription' -ScriptBlock {
        Get-AzSubscription -TenantId $TenantId -DefaultProfile $DefaultProfile -ErrorAction Stop
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
            Set-AzStorageBlobContent -Context $script:LogStorageContext -Container $LogContainerName `
                -File $tmpLog -Blob $logBlobName -Force -ErrorAction Stop | Out-Null
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
        [string[]]$SourcePoolNames, [string]$PoolNameOverride, [object]$DefaultProfile
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $groups = @($VmResourceGroup, $VnetResourceGroup, $DesResourceGroup)
    if ($LoadBalancerName) { $groups += $LoadBalancerResourceGroup }
    foreach ($group in @($groups | Sort-Object -Unique)) {
        try {
            $resourceGroup = Get-AzResourceGroup -Name $group -DefaultProfile $DefaultProfile -ErrorAction Stop
            if ($null -eq $resourceGroup) { throw "Resource Group '$group' was not returned." }
        }
        catch { $errors.Add("Resource Group '$group': $($_.Exception.Message)") }
    }
    $subnet = $null
    try {
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $VnetResourceGroup -Name $VnetName -DefaultProfile $DefaultProfile -ErrorAction Stop
        if ($null -eq $vnet) { throw "VNet '$VnetName' was not returned." }
        $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName | Select-Object -First 1
        if ($null -eq $subnet) { throw "Subnet '$SubnetName' is missing." }
    }
    catch { $errors.Add("VNet '$VnetName' / subnet '$SubnetName': $($_.Exception.Message)") }
    $asgIds = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $AsgNames) {
        try {
            $asg = Get-AzApplicationSecurityGroup -ResourceGroupName $VnetResourceGroup -Name $name -DefaultProfile $DefaultProfile -ErrorAction Stop
            if ($null -eq $asg) { throw "ASG '$name' was not returned." }
            $asgIds.Add([string]$asg.Id)
        }
        catch { $errors.Add("ASG '$name': $($_.Exception.Message)") }
    }
    if ($LoadBalancerName) {
        try {
            $loadBalancer = Get-AzLoadBalancer -ResourceGroupName $LoadBalancerResourceGroup -Name $LoadBalancerName -DefaultProfile $DefaultProfile -ErrorAction Stop
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
    return @{ Subnet = $subnet; AsgIds = @($asgIds) }
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
        ASGs are resolved in the target VNet resource group and must be pre-created.
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
        $sourceLogin = (Connect-AzAccount -Identity -AccountId $env:SOURCE_IDENTITY_CLIENT_ID `
            -Subscription $env:HOSTING_SUBSCRIPTION_ID -SkipContextPopulation -Scope Process -ErrorAction Stop).Context
        $sourceSub = Resolve-Subscription -SubscriptionIdentifier $SourceSubscription `
            -DefaultProfile $sourceLogin -TenantId $sourceLogin.Tenant.Id
        $script:SourceContext = (Connect-AzAccount -Identity -AccountId $env:SOURCE_IDENTITY_CLIENT_ID `
            -Tenant $sourceSub.TenantId -Subscription $sourceSub.Id -SkipContextPopulation -Scope Process -ErrorAction Stop).Context
        $result.SourceSubscriptionId = [string]$sourceSub.Id
        $script:LogPrefix = Get-DRLogPrefix -SourceSubscriptionId $sourceSub.Id `
            -SourceResourceGroup $SourceResourceGroup -SourceVmName $SourceVmName
        if (-not [string]::IsNullOrWhiteSpace($LogStorageAccountName)) {
            $script:LogStorageContext = New-AzStorageContext -StorageAccountName $LogStorageAccountName `
                -UseConnectedAccount -ErrorAction Stop
        }
        $targetLogin = (Connect-AzAccount -Identity -AccountId $env:TARGET_IDENTITY_CLIENT_ID `
            -Tenant $sourceSub.TenantId -SkipContextPopulation -Scope Process -ErrorAction Stop).Context
        $targetSubscriptions = @(Get-AzSubscription -TenantId $sourceSub.TenantId -DefaultProfile $targetLogin -ErrorAction Stop)
        $targetSub = Resolve-DRSubscription -SourceSubscription $sourceSub -Subscriptions $targetSubscriptions -Suffix $effSubSuffix
        $script:TargetContext = (Connect-AzAccount -Identity -AccountId $env:TARGET_IDENTITY_CLIENT_ID `
            -Tenant $targetSub.TenantId -Subscription $targetSub.Id -SkipContextPopulation -Scope Process -ErrorAction Stop).Context
        $result.TargetSubscriptionId = [string]$targetSub.Id

        Write-Log "Source sub: '$($sourceSub.Name)' | Target sub: '$($targetSub.Name)'" -VmName $SourceVmName

        # Derived target resource groups
        $targetVmRg = "${SourceResourceGroup}${effRgSuffix}"
        $targetDiskRg = $targetVmRg

        # ── Stage A: Discover source VM configuration ───────────────────────────
        $currentStage = 'A'
        Write-Log 'Stage A: Discovering source VM configuration.' -VmName $SourceVmName
        Set-SubscriptionContext -SubscriptionId $sourceSub.Id -FriendlyName $sourceSub.Name -Source

        $sourceVm = Invoke-WithRetry -Operation "Get-AzVM $SourceVmName" -ScriptBlock {
            Get-AzVM -ResourceGroupName $SourceResourceGroup -Name $SourceVmName -DefaultProfile $script:SourceContext -ErrorAction Stop
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
            Get-AzNetworkInterface -ResourceGroupName $sourceNicRg -Name $sourceNicName -DefaultProfile $script:SourceContext -ErrorAction Stop
        }

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

        # Discover Load Balancer and derive target LB RG
        $srcBackendPoolIds   = @()
        $srcBackendPoolNames = @()
        $srcLbName           = $null
        $targetLbName        = $null
        $targetLbRg          = $targetVmRg   # default

        if ($sourceIpConfig.LoadBalancerBackendAddressPools) {
            $srcBackendPoolIds = @(
                $sourceIpConfig.LoadBalancerBackendAddressPools |
                ForEach-Object { [string]$_.Id } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            $srcBackendPoolNames = @(
                $srcBackendPoolIds |
                ForEach-Object { Get-LastNameFromId -ResourceId $_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            $srcLbNames = @(
                $srcBackendPoolIds |
                ForEach-Object { Get-IdSegmentValue -ResourceId $_ -SegmentName 'loadBalancers' } |
                Where-Object   { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
            )
            if ($srcLbNames.Count -gt 1) {
                throw "Source NIC is attached to backend pools from multiple load balancers: $($srcLbNames -join ', ')."
            }
            if ($srcLbNames.Count -eq 1) { $srcLbName = [string]$srcLbNames[0] }

            # Derive target LB RG from the source backend pool RG
            if ($srcBackendPoolIds.Count -gt 0) {
                $srcLbPoolRg = Get-IdSegmentValue -ResourceId $srcBackendPoolIds[0] -SegmentName 'resourceGroups'
                if (-not [string]::IsNullOrWhiteSpace($srcLbPoolRg)) {
                    $targetLbRg = "${srcLbPoolRg}${effLbRgSuffix}"
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($srcLbName)) {
            Write-Log "Source VM has no load balancer. Skipping LB discovery and attachment." -VmName $SourceVmName
        } else {
            $targetLbName = "${srcLbName}${effLbNameSuffix}"
            Write-Log "Source LB: '$srcLbName' | Target LB: '$targetLbName' in RG '$targetLbRg'." -VmName $SourceVmName
        }

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
            Get-AzDisk -ResourceGroupName $osDiskRg -DiskName $osDiskName -DefaultProfile $script:SourceContext -ErrorAction Stop
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
                Get-AzDisk -ResourceGroupName $dRg -DiskName $dName -DefaultProfile $script:SourceContext -ErrorAction Stop
            }
            $dSP = Get-OptionalProp -Object $dDisk -PropertyName 'SharingProfile'
            [void]$diskList.Add([pscustomobject]@{
                Name                       = $dDisk.Name
                SourceDiskId               = $dDisk.Id
                SourceLocation             = [string]$dDisk.Location
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

        Write-Log ("Stage A complete. VM='$($sourceVm.Name)' Size='$($sourceVm.HardwareProfile.VmSize)' | " +
                   "Disks=$($diskInfos.Count) | ASGs=$($srcAsgIds.Count) | " +
                   "TargetSub='$($targetSub.Name)' | TargetRG='$targetVmRg' | " +
                   "TargetVNet='$targetVnetName' | TargetDES='$targetDesName'") -VmName $SourceVmName

        # Stage B: Validate direct managed disk copy before creating target resources
        $currentStage = 'B'
        Write-Log 'Stage B: Validating direct managed disk copy.' -VmName $SourceVmName
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name

        # Get DES first (must exist) to determine target location
        $des = Invoke-WithRetry -Operation "Get-AzDiskEncryptionSet $targetDesName" -ScriptBlock {
            Get-AzDiskEncryptionSet -ResourceGroupName $targetDesRg -Name $targetDesName -DefaultProfile $script:TargetContext -ErrorAction Stop
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
        $requiredAsgNames = @($srcAsgIds | ForEach-Object {
            "$(Get-LastNameFromId -ResourceId $_)$effAsgNameSuffix"
        })
        $prerequisites = Get-DRPrerequisites -VmName $SourceVmName -VmResourceGroup $targetVmRg `
            -VnetResourceGroup $targetVnetRg -VnetName $targetVnetName -SubnetName $targetSubnetName `
            -AsgNames $requiredAsgNames -DesResourceGroup $targetDesRg `
            -LoadBalancerName $targetLbName -LoadBalancerResourceGroup $targetLbRg `
            -SourcePoolNames $srcBackendPoolNames -PoolNameOverride $BackendPoolNameOverride `
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
            $existingDisk = Get-AzDisk -ResourceGroupName $targetDiskRg -DiskName $disk.Name -DefaultProfile $script:TargetContext -ErrorAction SilentlyContinue
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
                New-AzDisk -ResourceGroupName $targetDiskRg -DiskName $disk.Name -Disk $diskConfig -DefaultProfile $script:TargetContext -ErrorAction Stop
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
        $srcIpMethod   = [string]$sourceIpConfig.PrivateIpAllocationMethod
        $srcPrivateIp  = [string]$sourceIpConfig.PrivateIpAddress
        $srcIpCfgName  = [string]$sourceIpConfig.Name

        # Re-establish target subscription context before ASG lookup
        Write-Log "Re-establishing target subscription context before ASG and NIC operations." -VmName $SourceVmName
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
        $currentCtx = Get-AzContext
        Write-Log "Context before ASG/NIC operations verified: $($currentCtx.Subscription.Name) ($($currentCtx.Subscription.Id))" -VmName $SourceVmName
        if ($currentCtx.Subscription.Id -ne $targetSub.Id) {
            throw "Context mismatch before ASG/NIC operations! Expected: $($targetSub.Id), Current: $($currentCtx.Subscription.Id)"
        }

        $targetAsgIds = @($prerequisites.AsgIds)

        # NIC - re-verify context before Get to prevent context drift
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
        $targetNic = Get-AzNetworkInterface -ResourceGroupName $targetVmRg -Name $targetNicName -DefaultProfile $script:TargetContext -ErrorAction SilentlyContinue
        if ($null -eq $targetNic) {
            $ipCfgArgs = @{
                Name     = $srcIpCfgName
                SubnetId = $targetSubnet.Id
                Primary  = $true
            }
            # Always preserve source private IP with static allocation
            if ([string]::IsNullOrWhiteSpace($srcPrivateIp)) {
                throw "Source NIC private IP is empty — cannot preserve IP address."
            }
            $ipCfgArgs['PrivateIpAddress'] = $srcPrivateIp
            Write-Log "Target NIC will use source private IP: $srcPrivateIp (static allocation)." -VmName $SourceVmName
            if ($targetAsgIds.Count -gt 0) { $ipCfgArgs['ApplicationSecurityGroupId'] = $targetAsgIds }
            $ipCfg = New-AzNetworkInterfaceIpConfig @ipCfgArgs -ErrorAction Stop
            # Re-verify context immediately before New-AzNetworkInterface
            Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
            $targetNic = Invoke-WithRetry -Operation "New-AzNetworkInterface $targetNicName" -ScriptBlock {
                New-AzNetworkInterface -ResourceGroupName $targetVmRg -Location $targetLocation `
                    -Name $targetNicName -IpConfiguration $ipCfg -Tag $targetVmTags -DefaultProfile $script:TargetContext -ErrorAction Stop
            }
            [void]$summary.NicsCreated.Add($targetNicName)
            $asgNote = if ($targetAsgIds.Count -gt 0) { " with $($targetAsgIds.Count) ASG(s)" } else { '' }
            Write-Log "Created NIC '$targetNicName'$asgNote." -VmName $SourceVmName
        }
        else {
            $existIpCfg = $targetNic.IpConfigurations | Where-Object { $_.Name -eq $srcIpCfgName } | Select-Object -First 1
            if ($null -eq $existIpCfg) { $existIpCfg = $targetNic.IpConfigurations | Select-Object -First 1 }
            if ((Normalize $existIpCfg.Subnet.Id) -ne (Normalize $targetSubnet.Id)) {
                throw "Existing NIC '$targetNicName' is on wrong subnet ('$($existIpCfg.Subnet.Id)' vs expected '$($targetSubnet.Id)')."
            }
            # Validate existing NIC has the expected static IP
            if ((Normalize $existIpCfg.PrivateIpAllocationMethod) -ne 'static') {
                throw "Existing NIC '$targetNicName' allocation method is not static (expected static with IP $srcPrivateIp)."
            }
            if ((Normalize $existIpCfg.PrivateIpAddress) -ne (Normalize $srcPrivateIp)) {
                throw "Existing NIC '$targetNicName' private IP mismatch (has '$($existIpCfg.PrivateIpAddress)', expected '$srcPrivateIp')."
            }
            if ($targetAsgIds.Count -gt 0) {
                $existAsgIds = @($existIpCfg.ApplicationSecurityGroups | Where-Object { $_ } | ForEach-Object { Normalize $_.Id })
                $expAsgIds   = @($targetAsgIds | ForEach-Object { Normalize $_ })
                if (-not (Compare-StringArrays -A $existAsgIds -B $expAsgIds)) {
                    Write-Log "Reused NIC '$targetNicName' — ASG mismatch (existing=$($existAsgIds.Count) expected=$($expAsgIds.Count)). Manual review recommended." 'WARN' -VmName $SourceVmName
                }
            }
            [void]$summary.NicsReused.Add($targetNicName)
            Write-Log "Reused NIC '$targetNicName'." -VmName $SourceVmName
        }

        $osDiskInfo   = $diskInfos | Where-Object { $_.Role -eq 'OS' } | Select-Object -First 1
        if ($null -eq $osDiskInfo)   { throw "OS disk not found in captured disk list." }
        $targetOsDisk = $targetDisksByName[$osDiskInfo.Name]
        if ($null -eq $targetOsDisk) { throw "Target OS disk '$($osDiskInfo.Name)' not found in target disk map." }

        # Re-verify context before Get-AzVM to prevent context drift
        Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
        $existingVm = Get-AzVM -ResourceGroupName $targetVmRg -Name $targetVmName -DefaultProfile $script:TargetContext -ErrorAction SilentlyContinue
        if ($existingVm) {
            if ((Normalize $existingVm.HardwareProfile.VmSize) -ne (Normalize $sourceVm.HardwareProfile.VmSize)) {
                throw "Existing VM '$targetVmName' size mismatch (existing='$($existingVm.HardwareProfile.VmSize)' expected='$($sourceVm.HardwareProfile.VmSize)')."
            }
            if ((Normalize $existingVm.StorageProfile.OsDisk.ManagedDisk.Id) -ne (Normalize $targetOsDisk.Id)) {
                throw "Existing VM '$targetVmName' OS disk ID mismatch."
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

            $vmConfig = New-AzVMConfig -VMName $targetVmName -VMSize $sourceVm.HardwareProfile.VmSize -ErrorAction Stop
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
                New-AzVM -ResourceGroupName $targetVmRg -Location $targetLocation `
                    -VM $vmConfig -Tag $targetVmTags -DefaultProfile $script:TargetContext -ErrorAction Stop | Out-Null
            } | Out-Null

            [void]$summary.VmsCreated.Add($targetVmName)
            Write-Log "Created VM '$targetVmName'." -VmName $SourceVmName
        }

        # Upload Stage D log
        Upload-StageLog -VmName $SourceVmName -StageId 'D' -StageDescription 'NIC-VM' -Failed $false `
            -LogStorageAccountName $LogStorageAccountName -LogContainerName $LogContainerName -SessionId $SessionId
        $script:LogBuffer = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        # ── Stage E: Attach NIC to LB backend pool (skip if source has no LB) ───
        if (-not [string]::IsNullOrWhiteSpace($srcLbName)) {
            $currentStage = 'E'
            Write-Log 'Stage E: Attaching NIC to load balancer backend pool.' -VmName $SourceVmName
            Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name

            # Verify and log current context
            $currentCtx = Get-AzContext
            Write-Log "Stage E context verified: $($currentCtx.Subscription.Name) ($($currentCtx.Subscription.Id))" -VmName $SourceVmName
            if ($currentCtx.Subscription.Id -ne $targetSub.Id) {
                throw "Stage E context mismatch! Expected: $($targetSub.Id), Current: $($currentCtx.Subscription.Id)"
            }

            $lb = Invoke-WithRetry -Operation "Get-AzLoadBalancer $targetLbName" -ScriptBlock {
                Get-AzLoadBalancer -ResourceGroupName $targetLbRg -Name $targetLbName -DefaultProfile $script:TargetContext -ErrorAction Stop
            }
            $pool = Select-BackendPool -LoadBalancer $lb -SourcePoolNames $srcBackendPoolNames -PoolNameOverride $BackendPoolNameOverride
            Write-Log "Selected backend pool '$($pool.Name)'." -VmName $SourceVmName

            # Refresh NIC after VM creation
            $targetNic = Invoke-WithRetry -Operation "Refresh NIC $targetNicName" -ScriptBlock {
                Get-AzNetworkInterface -ResourceGroupName $targetVmRg -Name $targetNicName -DefaultProfile $script:TargetContext -ErrorAction Stop
            }
            $nicIpCfgForLb = $targetNic.IpConfigurations | Where-Object { $_.Name -eq $srcIpCfgName } | Select-Object -First 1
            if ($null -eq $nicIpCfgForLb) { $nicIpCfgForLb = $targetNic.IpConfigurations | Select-Object -First 1 }

            $currentPoolIds = @($nicIpCfgForLb.LoadBalancerBackendAddressPools | ForEach-Object { Normalize $_.Id })

            if ($currentPoolIds -contains (Normalize $pool.Id)) {
                [void]$summary.BackendPoolAlreadyMember.Add("$targetNicName/$($nicIpCfgForLb.Name)->$($pool.Name)")
                Write-Log "NIC already member of backend pool '$($pool.Name)'." -VmName $SourceVmName
            }
            else {
                if ($null -eq $nicIpCfgForLb.LoadBalancerBackendAddressPools) {
                    $nicIpCfgForLb.LoadBalancerBackendAddressPools = @()
                }
                $nicIpCfgForLb.LoadBalancerBackendAddressPools += $pool

                # Re-verify context immediately before Set-AzNetworkInterface
                Set-SubscriptionContext -SubscriptionId $targetSub.Id -FriendlyName $targetSub.Name
                Invoke-WithRetry -Operation 'Set-AzNetworkInterface (LB pool attach)' -ScriptBlock {
                    Set-AzNetworkInterface -NetworkInterface $targetNic -DefaultProfile $script:TargetContext -ErrorAction Stop | Out-Null
                } | Out-Null

                # Verify
                $verifyNic    = Get-AzNetworkInterface -ResourceGroupName $targetVmRg -Name $targetNicName -DefaultProfile $script:TargetContext -ErrorAction Stop
                $verifyIpCfg  = $verifyNic.IpConfigurations | Where-Object { $_.Name -eq $nicIpCfgForLb.Name } | Select-Object -First 1
                $verifyPoolIds = @($verifyIpCfg.LoadBalancerBackendAddressPools | ForEach-Object { Normalize $_.Id })
                if (-not ($verifyPoolIds -contains (Normalize $pool.Id))) {
                    throw "Backend pool association verification failed for NIC '$targetNicName' and pool '$($pool.Name)'."
                }
                [void]$summary.BackendPoolAttached.Add("$targetNicName/$($verifyIpCfg.Name)->$($pool.Name)")
                Write-Log "Attached NIC '$targetNicName' to backend pool '$($pool.Name)'." -VmName $SourceVmName
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
        $result.Error      = $_.Exception.Message
        $result.LogEntries = @($script:LogBuffer)

        # Upload failed stage log
        Upload-StageLog -VmName $SourceVmName -StageId $currentStage -StageDescription 'Failed' -Failed $true `
            -LogStorageAccountName $LogStorageAccountName -LogContainerName $LogContainerName -SessionId $SessionId
    }

    return [pscustomobject]$result
}

Export-ModuleMember -Function Invoke-VMReplication, Resolve-DRSubscription, Resolve-Subscription, Get-DRLogPrefix

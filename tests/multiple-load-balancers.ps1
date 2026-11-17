$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'function-app/Modules/DRCore/DRCore.psm1') -Force
$module = Get-Module DRCore
$tokens = $null; $parseErrors = $null
$syntax = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'function-app/Modules/DRCore/DRCore.psm1'), [ref]$tokens, [ref]$parseErrors)
$stage = $syntax.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.StartsWith('if ($loadBalancerReferences.Count -gt 0)')
}, $true)
if ($null -eq $stage) { throw 'The real multiple-LB attachment stage was not found.' }
$attachmentCode = [scriptblock]::Create($stage.Extent.Text)
$checks = & $module {
    param($AttachmentCode)
    $count = 0
    $sourcePrefix = '/subscriptions/source/resourceGroups'
    $ips = @(
        [pscustomobject]@{
            Name = 'primary'
            LoadBalancerBackendAddressPools = @(
                [pscustomobject]@{ Id = "$sourcePrefix/lb-public/providers/Microsoft.Network/loadBalancers/shared-name/backendAddressPools/web" },
                [pscustomobject]@{ Id = "$sourcePrefix/lb-internal/providers/Microsoft.Network/loadBalancers/shared-name/backendAddressPools/api" }
            )
        },
        [pscustomobject]@{
            Name = 'secondary'
            LoadBalancerBackendAddressPools = @(
                [pscustomobject]@{ Id = "$sourcePrefix/lb-public/providers/Microsoft.Network/loadBalancers/shared-name/backendAddressPools/admin" }
            )
        }
    )
    $plan = @(Get-DRLoadBalancerReferences -IpConfigurations $ips -TargetSubscriptionId target `
        -NameSuffix '-DR' -ResourceGroupSuffix '-DR')
    if ($plan.Count -ne 2) { throw 'Homonymous Load Balancers in distinct groups must remain distinct.' }
    $public = @($plan | Where-Object ResourceGroup -eq 'lb-public-DR')[0]
    $internal = @($plan | Where-Object ResourceGroup -eq 'lb-internal-DR')[0]
    if ($public.Name -ne 'shared-name-DR' -or $public.PoolReferences.Count -ne 2 -or
        $internal.PoolReferences.Count -ne 1 -or $public.Id -eq $internal.Id) {
        throw 'Every source pool and IP-configuration association must survive discovery.'
    }
    if ($public.PoolReferences[1].IpConfigurationName -ne 'secondary') { throw 'The source IP configuration must remain attached to its own pools.' }
    $count += 3
    if (@(Get-DRLoadBalancerReferences -IpConfigurations @([pscustomobject]@{ Name = 'primary' }) `
            -TargetSubscriptionId target -NameSuffix '-DR' -ResourceGroupSuffix '-DR').Count -ne 0) {
        throw 'A NIC without pools must remain supported.'
    }
    $count++
    $asg = Resolve-DRResourceReference -ResourceId "$sourcePrefix/asg-security/providers/Microsoft.Network/applicationSecurityGroups/app" `
        -ResourceType 'Microsoft.Network/applicationSecurityGroups' -TargetSubscriptionId target -NameSuffix '-DR' -ResourceGroupSuffix '-DR'
    if ($asg.ResourceGroup -ne 'asg-security-DR' -or $asg.SourceResourceGroup -ne 'asg-security' -or
        $asg.Id -ne '/subscriptions/target/resourceGroups/asg-security-DR/providers/Microsoft.Network/applicationSecurityGroups/app-DR') {
        throw 'ASG mapping must use its own resource ID, not the VM or VNet group.'
    }
    $count++
    $nsg = Resolve-DRResourceReference -ResourceId "$sourcePrefix/nsg-security/providers/Microsoft.Network/networkSecurityGroups/filter" `
        -ResourceType 'Microsoft.Network/networkSecurityGroups' -TargetSubscriptionId target -NameSuffix '-DR' -ResourceGroupSuffix '-DR'
    if ($nsg.ResourceGroup -ne 'nsg-security-DR') { throw 'NSG mapping must preserve its independent source group.' }
    $count++

    $script:Reads = [System.Collections.Generic.List[string]]::new()
    $script:MissingPool = $false
    $script:MissingLoadBalancer = $false
    $profile = [pscustomobject]@{ Subscription = @{ Id = 'target'; Name = 'target-DR' }; Account = @{ Id = 'identity-target' } }
    function Get-AzResourceGroup {
        [CmdletBinding()]param($Name, $DefaultProfile)
        $script:Reads.Add("group:$Name")
        [pscustomobject]@{ Name = $Name }
    }
    function Get-AzVirtualNetwork {
        [CmdletBinding()]param($ResourceGroupName, $Name, $DefaultProfile)
        $script:Reads.Add("vnet:$ResourceGroupName")
        [pscustomobject]@{ Subnets = @([pscustomobject]@{ Name = 'workload'; Id = 'target-subnet' }) }
    }
    function Get-AzApplicationSecurityGroup {
        [CmdletBinding()]param($ResourceGroupName, $Name, $DefaultProfile)
        $script:Reads.Add("asg:$ResourceGroupName/$Name")
        [pscustomobject]@{ Id = "/subscriptions/target/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/applicationSecurityGroups/$Name" }
    }
    function Get-AzNetworkSecurityGroup {
        [CmdletBinding()]param($ResourceGroupName, $Name, $DefaultProfile)
        $script:Reads.Add("nsg:$ResourceGroupName/$Name")
        [pscustomobject]@{ Id = "/subscriptions/target/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/networkSecurityGroups/$Name" }
    }
    function Get-AzLoadBalancer {
        [CmdletBinding()]param($ResourceGroupName, $Name, $DefaultProfile)
        $script:Reads.Add("lb:$ResourceGroupName/$Name")
        if ($script:MissingLoadBalancer -and $ResourceGroupName -eq 'lb-internal-DR') { throw 'Required second Load Balancer does not exist.' }
        $names = if ($ResourceGroupName -eq 'lb-public-DR') { @('web', 'admin') } else { @('api') }
        if ($script:MissingPool) { $names = @($names | Where-Object { $_ -ne 'admin' }) }
        $id = "/subscriptions/target/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/loadBalancers/$Name"
        [pscustomobject]@{
            Id = $id; Name = $Name
            BackendAddressPools = @($names | ForEach-Object { [pscustomobject]@{ Name = $_; Id = "$id/backendAddressPools/$_" } })
        }
    }
    $arguments = @{
        VmName = 'vm-one'; VmResourceGroup = 'compute-DR'; NicResourceGroup = 'nic-DR'
        VnetResourceGroup = 'vnet-DR'; VnetName = 'network-DR'; SubnetName = 'workload'
        DesResourceGroup = 'keys-DR'; AsgReferences = @($asg); NsgReferences = @($nsg)
        LoadBalancerReferences = $plan; DefaultProfile = $profile
    }
    $prerequisites = Get-DRPrerequisites @arguments
    if ($prerequisites.PoolsBySourceId.Count -ne 3) { throw 'Preflight must resolve all three source pools.' }
    if ("asg:asg-security-DR/app-DR" -notin $script:Reads -or "nsg:nsg-security-DR/filter-DR" -notin $script:Reads -or
        'lb:lb-public-DR/shared-name-DR' -notin $script:Reads -or 'lb:lb-internal-DR/shared-name-DR' -notin $script:Reads -or
        'group:nic-DR' -notin $script:Reads) { throw 'Every real target group and network resource must be checked independently.' }
    $count += 2
    foreach ($case in @('MissingPool', 'MissingLoadBalancer')) {
        $script:MissingPool = $case -eq 'MissingPool'
        $script:MissingLoadBalancer = $case -eq 'MissingLoadBalancer'
        $rejected = $false
        try { Get-DRPrerequisites @arguments | Out-Null }
        catch { $rejected = $_.Exception.Message -like '*prerequisites are missing or inaccessible*' }
        if (-not $rejected) { throw "$case must block before workload creation." }
        $count++
    }
    $script:MissingPool = $false
    $script:MissingLoadBalancer = $false
    $prerequisites = Get-DRPrerequisites @arguments
    $script:TargetContext = $profile
    $script:TestNic = [pscustomobject]@{
        Id = '/subscriptions/target/resourceGroups/nic-DR/providers/Microsoft.Network/networkInterfaces/vm-one-nic'
        IpConfigurations = @(
            [pscustomobject]@{ Name = 'primary'; LoadBalancerBackendAddressPools = @([pscustomobject]@{ Id = 'unrelated-existing-pool' }) },
            [pscustomobject]@{ Name = 'secondary'; LoadBalancerBackendAddressPools = @() }
        )
    }
    $script:Updates = 0
    function Set-SubscriptionContext { param($SubscriptionId, $FriendlyName) }
    function Get-AzContext { $script:TargetContext }
    function Get-AzNetworkInterface {
        [CmdletBinding()]param($ResourceGroupName, $Name, $DefaultProfile)
        if ($ResourceGroupName -ne 'nic-DR' -or $DefaultProfile -ne $script:TargetContext) { throw 'NIC reads must use its actual DR group and identity.' }
        $script:TestNic
    }
    function Set-AzNetworkInterface {
        [CmdletBinding()]param($NetworkInterface, $DefaultProfile)
        if ($DefaultProfile -ne $script:TargetContext) { throw 'NIC writes must use the DR identity.' }
        $script:Updates++
        $script:TestNic = $NetworkInterface
        $NetworkInterface
    }
    $loadBalancerReferences = $plan
    $targetSub = [pscustomobject]@{ Id = 'target'; Name = 'target-DR' }
    $targetNicRg = 'nic-DR'; $targetNicName = 'vm-one-nic'; $SourceVmName = 'vm-one'
    $summary = @{
        BackendPoolAttached = [System.Collections.Generic.List[string]]::new()
        BackendPoolAlreadyMember = [System.Collections.Generic.List[string]]::new()
    }
    . $AttachmentCode
    if ($script:Updates -ne 1 -or $summary.BackendPoolAttached.Count -ne 3) { throw 'All three associations must be persisted in one target NIC update.' }
    $primaryIds = @($script:TestNic.IpConfigurations[0].LoadBalancerBackendAddressPools.Id)
    $secondaryIds = @($script:TestNic.IpConfigurations[1].LoadBalancerBackendAddressPools.Id)
    if ($primaryIds.Count -ne 3 -or 'unrelated-existing-pool' -notin $primaryIds -or $secondaryIds.Count -ne 1 -or
        $secondaryIds[0] -notlike '*/lb-public-DR/*/admin') { throw 'Associations must remain on the correct IP configuration without removing existing pools.' }
    $count += 2
    . $AttachmentCode
    if ($script:Updates -ne 1 -or $summary.BackendPoolAlreadyMember.Count -ne 3) { throw 'Replaying the stage must not rewrite or duplicate existing associations.' }
    $count++
    $count
} $attachmentCode
Write-Host "PASS: $checks multiple-LB and independent Resource Group checks; no Azure calls."

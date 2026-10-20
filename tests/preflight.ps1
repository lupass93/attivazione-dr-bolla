$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'function-app/Modules/DRCore/DRCore.psm1') -Force
$module = Get-Module DRCore
$passed = 0
foreach ($case in @('Ready', 'ResourceGroup', 'VNet', 'Subnet', 'ASG', 'LoadBalancer', 'BackendPool', 'NoLoadBalancer')) {
    $result = & $module {
        param($Case)
        $script:TestCase = $Case
        $script:ExpectedProfile = [pscustomobject]@{ Subscription = @{ Id = 'target' } }
        $script:WriteCount = 0
        function Get-AzResourceGroup {
            [CmdletBinding()]
            param($Name, $DefaultProfile)
            if ($DefaultProfile -ne $script:ExpectedProfile) { throw 'Incorrect identity profile.' }
            if ($script:TestCase -eq 'ResourceGroup') { throw 'Resource group is missing.' }
            [pscustomobject]@{ Name = $Name }
        }
        function Get-AzVirtualNetwork {
            [CmdletBinding()]
            param($ResourceGroupName, $Name, $DefaultProfile)
            if ($script:TestCase -eq 'VNet') { throw 'VNet is missing.' }
            $subnets = if ($script:TestCase -eq 'Subnet') { @() } else { @([pscustomobject]@{ Name = 'workload'; Id = 'subnet-id' }) }
            [pscustomobject]@{ Subnets = $subnets }
        }
        function Get-AzApplicationSecurityGroup {
            [CmdletBinding()]
            param($ResourceGroupName, $Name, $DefaultProfile)
            if ($script:TestCase -eq 'ASG') { throw 'ASG is missing.' }
            [pscustomobject]@{ Id = "asg/$Name"; Name = $Name; Tags = @{ externalConfiguration = 'not-reconciled' } }
        }
        function Get-AzLoadBalancer {
            [CmdletBinding()]
            param($ResourceGroupName, $Name, $DefaultProfile)
            if ($script:TestCase -eq 'LoadBalancer') { throw 'Load Balancer is missing.' }
            $pools = if ($script:TestCase -eq 'BackendPool') { @() } else { @([pscustomobject]@{ Name = 'backend'; Id = 'pool-id' }) }
            [pscustomobject]@{ Name = $Name; BackendAddressPools = $pools }
        }
        function New-AzDisk { $script:WriteCount++; throw 'Preflight must never write a disk.' }
        function New-AzNetworkInterface { $script:WriteCount++; throw 'Preflight must never write a NIC.' }
        function New-AzVM { $script:WriteCount++; throw 'Preflight must never write a VM.' }
        $errorMessage = $null
        $prerequisites = $null
        try {
            $prerequisites = Get-DRPrerequisites -VmName 'vm-one' -VmResourceGroup 'workload-DR' `
                -VnetResourceGroup 'network-DR' -VnetName 'vnet-DR' -SubnetName 'workload' `
                -AsgNames @('app-DR', 'management-DR') -DesResourceGroup 'security-DR' `
                -LoadBalancerName $(if ($Case -eq 'NoLoadBalancer') { '' } else { 'lb-DR' }) `
                -LoadBalancerResourceGroup 'workload-DR' -SourcePoolNames @('backend') `
                -PoolNameOverride '' -DefaultProfile $script:ExpectedProfile
        }
        catch { $errorMessage = $_.Exception.Message }
        @{ Error = $errorMessage; Prerequisites = $prerequisites; Writes = $script:WriteCount }
    } $case
    if ($result.Writes -ne 0) { throw "$case performed a workload write." }
    if ($case -in @('Ready', 'NoLoadBalancer')) {
        if ($result.Error -or $result.Prerequisites.Subnet.Id -ne 'subnet-id' -or $result.Prerequisites.AsgIds.Count -ne 2) {
            throw "$case failed: $($result.Error)"
        }
    }
    elseif ($result.Error -notlike '*prerequisites are missing or inaccessible*') { throw "$case must block activation." }
    $passed++
}
Import-Module (Join-Path $root 'function-app/Modules/DRSessions/DRSessions.psm1') -Force
& (Get-Module DRSessions) {
    Assert-DRPrivateEndpoint ([uri]'https://10.80.0.38')
    foreach ($uri in @('http://10.80.0.38', 'https://127.0.0.1', 'https://8.8.8.8')) {
        $rejected = $false
        try { Assert-DRPrivateEndpoint ([uri]$uri) }
        catch { $rejected = $true }
        if (-not $rejected) { throw "Nonprivate or non-HTTPS endpoint was accepted: $uri" }
    }
}
Write-Host "PASS: $passed prerequisite scenarios and private-only endpoint guards; no Azure calls."

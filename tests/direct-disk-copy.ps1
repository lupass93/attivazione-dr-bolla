[CmdletBinding()]
param(
    [string]$ModulePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'function-app/Modules/DRCore/DRCore.psm1')
)

$ErrorActionPreference = 'Stop'
$ModulePath = (Resolve-Path -LiteralPath $ModulePath).Path
$tokens = $null
$parseErrors = $null
$syntax = [System.Management.Automation.Language.Parser]::ParseFile(
    $ModulePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors.Message -join '; ') }
$replication = $syntax.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-VMReplication'
}, $true)
if ($null -eq $replication) { throw 'Invoke-VMReplication not found.' }
$snapshotCommands = $replication.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '-AzSnapshot'
}, $true)
if ($snapshotCommands.Count -ne 0) { throw 'Replication must not read, create or reuse snapshots.' }

$body = $replication.Body.EndBlock.Statements |
    Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] } | Select-Object -First 1
$copyStatements = [System.Collections.Generic.List[string]]::new()
$collect = $false
foreach ($statement in $body.Body.Statements) {
    if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $statement.Left.Extent.Text -eq '$currentStage') {
        if ($statement.Right.Extent.Text -eq "'D'") { break }
        if ($statement.Right.Extent.Text -eq "'B'") { $collect = $true }
    }
    if ($collect) { $copyStatements.Add($statement.Extent.Text) }
}
if ($copyStatements.Count -eq 0) { throw 'Disk-copy stages not found.' }
$copyCode = [scriptblock]::Create($copyStatements -join "`n")
Import-Module $ModulePath -Force
$module = Get-Module DRCore

function Invoke-CopyCase {
    param([string]$Case)
    & $module {
        param($CopyCode, $Case)
        function Write-Log { param($Message, $Level, $VmName) }
        function Upload-StageLog {
            param($VmName, $StageId, $StageDescription, $Failed, $LogStorageAccountName, $LogContainerName, $SessionId)
        }
        function Get-DRPrerequisites {
            param($VmName, $VmResourceGroup, $VnetResourceGroup, $VnetName, $SubnetName, $AsgNames,
                $DesResourceGroup, $LoadBalancerName, $LoadBalancerResourceGroup, $SourcePoolNames, $PoolNameOverride, $DefaultProfile)
            @{ Subnet = $null; AsgIds = @() }
        }
        function Set-SubscriptionContext { param($SubscriptionId, $FriendlyName) }
        function Get-AzContext { $script:TargetContext }
        function Invoke-WithRetry { param($Operation, $ScriptBlock); & $ScriptBlock }
        function Get-AzDiskEncryptionSet {
            [CmdletBinding()]
            param($ResourceGroupName, $Name, $DefaultProfile)
            $script:TestDes
        }
        function Get-AzDisk {
            [CmdletBinding()]
            param($ResourceGroupName, $DiskName, $DefaultProfile)
            if ($DefaultProfile -ne $script:TargetContext) { throw 'Target reads require the explicit target profile.' }
            $script:ExistingDisks[$DiskName]
        }
        function New-AzDiskConfig {
            [CmdletBinding()]
            param($Location, $CreateOption, $SourceResourceId, $SkuName, $DiskEncryptionSetId,
                $EncryptionType, $Tier, $Zone, $MaxSharesCount, $OptimizedForFrequentAttach)
            [pscustomobject]$PSBoundParameters
        }
        function New-AzDisk {
            [CmdletBinding()]
            param($ResourceGroupName, $DiskName, $Disk, $DefaultProfile)
            if ($DefaultProfile -ne $script:TargetContext) { throw 'Target creation requires the explicit target profile.' }
            [void]$script:CreatedDisks.Add([pscustomobject]@{ Name = $DiskName; Config = $Disk })
            [pscustomobject]@{ Name = $DiskName; Id = "/subscriptions/target/resourceGroups/rg-dr/providers/Microsoft.Compute/disks/$DiskName" }
        }

        $script:SourceContext = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant' } }
        $script:TargetContext = [pscustomobject]@{
            Tenant = [pscustomobject]@{ Id = 'tenant' }
            Subscription = [pscustomobject]@{ Id = 'target'; Name = 'target-DR' }
        }
        if ($Case -eq 'DifferentTenant') { $script:TargetContext.Tenant.Id = 'another-tenant' }
        $targetSub = $script:TargetContext.Subscription
        $sourceSub = [pscustomobject]@{ Id = 'source'; TenantId = 'tenant' }
        $script:TestDes = [pscustomobject]@{
            Id = '/subscriptions/target/resourceGroups/rg-security-DR/providers/Microsoft.Compute/diskEncryptionSets/des-DR'
            Location = 'italynorth'
            EncryptionType = 'EncryptionAtRestWithCustomerKey'
        }
        if ($Case -eq 'MissingDesEncryptionType') { $script:TestDes.EncryptionType = '' }
        $diskInfos = @(
            foreach ($name in @('os', 'data')) {
                [pscustomobject]@{
                    Name = $name
                    SourceDiskId = "/subscriptions/source/resourceGroups/rg-source/providers/Microsoft.Compute/disks/$name"
                    SourceLocation = 'ITALYNORTH'
                    SkuName = 'Premium_LRS'
                    EncryptionType = 'EncryptionAtRestWithCustomerKey'
                    Tier = 'P10'
                    Zones = @('1')
                    MaxShares = 1
                    OptimizedForFrequentAttach = $false
                }
            }
        )
        if ($Case -eq 'DifferentRegion') { $diskInfos[1].SourceLocation = 'westeurope' }
        if ($Case -eq 'SourcePlatformKey') { $diskInfos[1].EncryptionType = 'EncryptionAtRestWithPlatformKey' }
        $script:CreatedDisks = [System.Collections.Generic.List[object]]::new()
        $script:ExistingDisks = @{}
        if ($Case -in @('Reuse', 'LegacySnapshot', 'WrongSource', 'WrongDes', 'WrongEncryption', 'WrongSku', 'WrongZone', 'WrongShares', 'WrongLocation', 'FailedDisk', 'Mixed')) {
            foreach ($disk in $diskInfos) {
                $script:ExistingDisks[$disk.Name] = [pscustomobject]@{
                    Name = $disk.Name
                    Id = "/subscriptions/target/resourceGroups/rg-dr/providers/Microsoft.Compute/disks/$($disk.Name)"
                    Location = 'italynorth'
                    ProvisioningState = 'Succeeded'
                    CreationData = [pscustomobject]@{ CreateOption = 'Copy'; SourceResourceId = $disk.SourceDiskId }
                    Sku = [pscustomobject]@{ Name = $disk.SkuName }
                    Encryption = [pscustomobject]@{ DiskEncryptionSetId = $script:TestDes.Id; Type = $disk.EncryptionType }
                    Zones = @($disk.Zones)
                    MaxShares = $disk.MaxShares
                }
            }
            switch ($Case) {
                'LegacySnapshot' { $script:ExistingDisks['os'].CreationData.SourceResourceId = '/subscriptions/target/resourceGroups/rg-dr/providers/Microsoft.Compute/snapshots/snap-os' }
                'WrongSource' { $script:ExistingDisks['os'].CreationData.SourceResourceId = '/subscriptions/source/resourceGroups/rg-source/providers/Microsoft.Compute/disks/other' }
                'WrongDes' { $script:ExistingDisks['os'].Encryption.DiskEncryptionSetId = 'another-des' }
                'WrongEncryption' { $script:ExistingDisks['os'].Encryption.Type = 'EncryptionAtRestWithPlatformKey' }
                'WrongSku' { $script:ExistingDisks['os'].Sku.Name = 'Standard_LRS' }
                'WrongZone' { $script:ExistingDisks['os'].Zones = @('2') }
                'WrongShares' { $script:ExistingDisks['os'].MaxShares = 2 }
                'WrongLocation' { $script:ExistingDisks['os'].Location = 'westeurope' }
                'FailedDisk' { $script:ExistingDisks['os'].ProvisioningState = 'Failed' }
                'Mixed' { $script:ExistingDisks.Remove('data') }
            }
        }
        $SourceVmName = 'vm-test'
        $targetDesName = 'des-DR'
        $targetDesRg = 'rg-security-DR'
        $targetDiskRg = 'rg-dr'
        $targetSnapDiskRg = $targetDiskRg
        $summary = @{
            DisksCreated = [System.Collections.Generic.List[string]]::new()
            DisksReused = [System.Collections.Generic.List[string]]::new()
        }
        $LogStorageAccountName = ''
        $LogContainerName = ''
        $SessionId = '00000000-0000-0000-0000-000000000099'
        $PreflightOnly = $false
        $srcAsgIds = @()
        $srcBackendPoolNames = @()
        $targetVmRg = 'rg-dr'
        $targetVnetRg = 'rg-network-dr'
        $targetVnetName = 'vnet-dr'
        $targetSubnetName = 'workload'
        $targetLbName = $null
        $targetLbRg = 'rg-dr'
        $BackendPoolNameOverride = ''
        $targetDisksByName = @{}
        $failure = $null
        try { . $CopyCode }
        catch { $failure = $_.Exception.Message }
        [pscustomobject]@{
            Error = $failure
            Created = @($script:CreatedDisks)
            Reused = @($summary.DisksReused)
            CreatedSummary = @($summary.DisksCreated)
            TargetCount = if ($null -ne $targetDisksByName) { $targetDisksByName.Count } else { 0 }
        }
    } $copyCode $Case
}

foreach ($case in @('Create', 'Reuse', 'Mixed', 'SourcePlatformKey')) {
    $actual = Invoke-CopyCase $case
    if ($actual.Error) { throw "$case failed: $($actual.Error)" }
    $expectedCreated = switch ($case) { 'Reuse' { 0 }; 'Mixed' { 1 }; default { 2 } }
    if ($actual.Created.Count -ne $expectedCreated -or $actual.Reused.Count -ne (2 - $expectedCreated) -or
        $actual.CreatedSummary.Count -ne $expectedCreated -or $actual.TargetCount -ne 2) {
        throw "$case returned incorrect creation/reuse counts."
    }
    foreach ($created in $actual.Created) {
        if ($created.Config.SourceResourceId -ne "/subscriptions/source/resourceGroups/rg-source/providers/Microsoft.Compute/disks/$($created.Name)" -or
            $created.Config.CreateOption -ne 'Copy' -or $created.Config.EncryptionType -ne 'EncryptionAtRestWithCustomerKey' -or
            $created.Config.DiskEncryptionSetId -notlike '*/diskEncryptionSets/des-DR' -or
            $created.Config.SkuName -ne 'Premium_LRS' -or $created.Config.Tier -ne 'P10' -or
            $created.Config.Zone[0] -ne '1') {
            throw "$case did not preserve the direct source, encryption or disk settings."
        }
    }
}

foreach ($case in @('DifferentTenant', 'DifferentRegion', 'MissingDesEncryptionType', 'LegacySnapshot', 'WrongSource', 'WrongDes', 'WrongEncryption', 'WrongSku', 'WrongZone', 'WrongShares', 'WrongLocation', 'FailedDisk')) {
    $actual = Invoke-CopyCase $case
    $expectedMessage = switch ($case) {
        'DifferentTenant' { '*same Microsoft Entra tenant*' }
        'DifferentRegion' { '*same region*' }
        'MissingDesEncryptionType' { '*supported customer-managed encryption type*' }
        default { '*exists but*' }
    }
    if (-not $actual.Error -or $actual.Error -notlike $expectedMessage -or $actual.Created.Count -ne 0) {
        throw "$case must reject the unsupported copy before creating disks; observed: $($actual.Error)"
    }
}
Write-Host "PASS: 16 direct-disk-copy scenarios and no snapshot commands in $ModulePath; no Azure calls."
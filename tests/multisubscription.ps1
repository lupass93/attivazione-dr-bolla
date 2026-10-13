[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'function-app/Modules/DRCore/DRCore.psm1') -Force
$tenant = '00000000-0000-0000-0000-000000000001'
$sourceA = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000010'; Name = 'site-a'; TenantId = $tenant; State = 'Enabled' }
$sourceB = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000020'; Name = 'site-b'; TenantId = $tenant; State = 'Enabled' }
$targetA = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000011'; Name = 'site-a-DR'; TenantId = $tenant; State = 'Enabled' }
$targetB = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000021'; Name = 'site-b-DR'; TenantId = $tenant; State = 'Enabled' }
$passed = 0

function Assert-Rejected {
    param([scriptblock]$Action, [string]$ExpectedMessage)
    $rejected = $false
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Expected rejection: $ExpectedMessage" }
}

foreach ($source in @($sourceA, $sourceB)) {
    $actual = Resolve-DRSubscription -SourceSubscription $source -Subscriptions @($targetA, $targetB)
    $expectedId = if ($source.Id -eq $sourceA.Id) { $targetA.Id } else { $targetB.Id }
    if ($actual.Id -ne $expectedId) { throw "Incorrect destination for $($source.Name)." }
    $passed++
}

Assert-Rejected { Resolve-DRSubscription -SourceSubscription $sourceA -Subscriptions @($targetB) } 'found 0'
$passed++
Assert-Rejected { Resolve-DRSubscription -SourceSubscription $sourceA -Subscriptions @($targetA, $targetA) } 'found 2'
$passed++
$disabled = [pscustomobject]@{ Id = $targetA.Id; Name = $targetA.Name; TenantId = $tenant; State = 'Disabled' }
Assert-Rejected { Resolve-DRSubscription -SourceSubscription $sourceA -Subscriptions @($disabled) } 'not enabled'
$passed++
$foreign = [pscustomobject]@{ Id = $targetA.Id; Name = $targetA.Name; TenantId = '00000000-0000-0000-0000-000000000002'; State = 'Enabled' }
Assert-Rejected { Resolve-DRSubscription -SourceSubscription $sourceA -Subscriptions @($foreign) } 'different tenant'
$passed++
$sameId = [pscustomobject]@{ Id = $sourceA.Id; Name = $targetA.Name; TenantId = $tenant; State = 'Enabled' }
Assert-Rejected { Resolve-DRSubscription -SourceSubscription $sourceA -Subscriptions @($sameId) } 'distinct from the source'
$passed++
Assert-Rejected { Resolve-DRSubscription -SourceSubscription $sourceA -Subscriptions @($targetA) -Suffix '' } 'nonempty DR suffix'
$passed++

$prefixA = Get-DRLogPrefix -SourceSubscriptionId $sourceA.Id -SourceResourceGroup 'rg-web' -SourceVmName 'vm-web'
$prefixB = Get-DRLogPrefix -SourceSubscriptionId $sourceB.Id -SourceResourceGroup 'rg-web' -SourceVmName 'vm-web'
if ($prefixA -eq $prefixB) { throw 'Homonymous VMs in different subscriptions must have distinct log prefixes.' }
$passed++
if ($prefixA -ne (Get-DRLogPrefix -SourceSubscriptionId $sourceA.Id -SourceResourceGroup 'RG-WEB' -SourceVmName 'VM-WEB')) {
    throw 'Case variations must resolve to the same workload log identity.'
}
$passed++
Assert-Rejected { Get-DRLogPrefix -SourceSubscriptionId $sourceA.Id -SourceResourceGroup '../rg' -SourceVmName 'vm-web' } 'path separators'
$passed++

Write-Host "PASS: $passed DR routing and log-identity checks; no Azure calls."

foreach ($file in Get-ChildItem (Join-Path $root 'function-app') -Recurse -File -Include *.ps1, *.psm1) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors.Message -join '; ') }
}
Write-Host 'PASS: application PowerShell files parse.'

Add-Type 'public class HttpResponseContext { public object StatusCode; public object Body; public object Headers; }'
function global:Disable-AzContextAutosave { param($Scope) }
function global:Connect-AzAccount {
    param([switch]$Identity, $AccountId, $Subscription, [switch]$SkipContextPopulation, $Scope, $Tenant)
    $selected = @($sourceA, $sourceB, $targetA, $targetB) | Where-Object Id -eq $Subscription | Select-Object -First 1
    [pscustomobject]@{ Context = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $sourceA.TenantId }; Subscription = $selected; Account = [pscustomobject]@{ Id = $AccountId } } }
}
function global:Get-AzSubscription {
    param($TenantId, $DefaultProfile)
    if ($DefaultProfile.Account.Id -eq 'identity-target') { @($targetA, $targetB) } else { @($sourceA, $sourceB) }
}
function global:New-AzStorageContext { param($StorageAccountName, [switch]$UseConnectedAccount); [pscustomobject]@{ Name = $StorageAccountName } }
function global:Get-AzStorageBlobContent {
    param($Container, $Blob, $Destination, $Context, [switch]$Force)
    @(
        'SourceSubscription,SourceResourceGroup,SourceVmName'
        "$($sourceA.Id),rg-web,vm-web"
        "$($sourceB.Id),rg-web,vm-web"
    ) | Set-Content -LiteralPath $Destination
}
function global:Get-AzStorageBlob {
    param($Container, $Prefix, $Context)
    $marker = if ($Prefix.StartsWith($sourceA.Id)) { 'stageCompleted-Success' } else { 'stageB-Failed' }
    $failed = if ($Prefix.StartsWith($sourceA.Id)) { '' } else { '-failed' }
    [pscustomobject]@{
        Name = "${Prefix}00000000-0000-0000-0000-000000000099-$marker-20261012-0000$failed.log"
        LastModified = [datetimeoffset]'2026-10-12T00:00:00Z'
    }
}
function global:Push-OutputBinding { param($Name, $Value); $global:CapturedResponse = $Value }

$environmentNames = @('SOURCE_IDENTITY_CLIENT_ID', 'TARGET_IDENTITY_CLIENT_ID', 'HOSTING_SUBSCRIPTION_ID', 'CSV_STORAGE_CONNECTION__blobServiceUri')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:SOURCE_IDENTITY_CLIENT_ID = '00000000-0000-0000-0000-000000000001'
    $env:HOSTING_SUBSCRIPTION_ID = $sourceA.Id
    $env:CSV_STORAGE_CONNECTION__blobServiceUri = 'https://mockstorage.blob.core.windows.net/'
    & (Join-Path $root 'function-app/Get-DRStatus/run.ps1') `
        -Request ([pscustomobject]@{ Method = 'GET'; Query = @{ csvBlobPath = 'fake.csv' } }) `
        -TriggerMetadata ([pscustomobject]@{ InvocationId = '00000000-0000-0000-0000-000000000099' })
    if ([int]$global:CapturedResponse.StatusCode -ne 200) { throw 'Status handler did not return 200.' }
    $status = $global:CapturedResponse.Body | ConvertFrom-Json
    if ($status.results.Count -ne 2 -or $status.summary.succeeded -ne 1 -or $status.summary.failed -ne 1) {
        throw 'Homonymous source VMs must retain independent API results.'
    }
    if (($status.results | Where-Object sourceSubscriptionId -eq $sourceA.Id).status -ne 'SUCCEEDED' -or
        ($status.results | Where-Object sourceSubscriptionId -eq $sourceB.Id).status -ne 'FAILED') {
        throw 'Per-subscription API status correlation failed.'
    }
    Write-Host 'PASS: real Get-DRStatus handler distinguishes homonymous VMs across two source subscriptions using mocked Azure reads.'

    $env:SOURCE_IDENTITY_CLIENT_ID = 'identity-source'
    $env:TARGET_IDENTITY_CLIENT_ID = 'identity-target'
    $tokens = $null
    $parseErrors = $null
    $coreSyntax = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'function-app/Modules/DRCore/DRCore.psm1'), [ref]$tokens, [ref]$parseErrors)
    $initialization = $coreSyntax.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text.Contains('$sourceLogin =')
    }, $true) | Select-Object -First 1
    $statements = [System.Collections.Generic.List[string]]::new()
    foreach ($statement in $initialization.Body.Statements) {
        $statements.Add($statement.Extent.Text)
        if ($statement.Extent.Text.Contains('Source sub:')) { break }
    }
    if (-not $statements[$statements.Count - 1].Contains('Source sub:')) { throw 'Initialization boundary not found.' }
    $module = Get-Module DRCore
    foreach ($source in @($sourceA, $sourceB)) {
        $resolved = & $module {
            param($SourceSubscription, $Statements)
            $SourceResourceGroup = 'rg-web'
            $SourceVmName = 'vm-web'
            $LogStorageAccountName = 'mockstorage'
            $effSubSuffix = '-DR'
            $result = [ordered]@{}
            foreach ($statement in $Statements) { Invoke-Expression $statement | Out-Null }
            [pscustomobject]@{
                SourceId = $script:SourceContext.Subscription.Id
                TargetId = $script:TargetContext.Subscription.Id
                SourceIdentity = $script:SourceContext.Account.Id
                TargetIdentity = $script:TargetContext.Account.Id
                Prefix = $script:LogPrefix
            }
        } $source.Id $statements
        $expectedTargetId = if ($source.Id -eq $sourceA.Id) { $targetA.Id } else { $targetB.Id }
        if ($resolved.SourceId -ne $source.Id -or $resolved.TargetId -ne $expectedTargetId -or
            $resolved.SourceIdentity -ne 'identity-source' -or $resolved.TargetIdentity -ne 'identity-target' -or
            -not $resolved.Prefix.StartsWith($source.Id)) {
            throw "Actual runtime initialization selected the wrong subscription/identity for $($source.Name)."
        }
    }
    Write-Host 'PASS: actual Invoke-VMReplication initialization selects separate UAMI contexts and the correct target for both source rows.'

    $global:FakeLabSubscriptions = @($sourceA, $sourceB, $targetA, $targetB) | ForEach-Object {
        [pscustomobject]@{ id = $_.Id; name = $_.Name; tenantId = $_.TenantId; state = $_.State }
    }
    function global:az {
        $global:FakeLabSubscriptions | ConvertTo-Json
        $global:LASTEXITCODE = 0
    }
    & (Join-Path $root 'scripts/preflight-multisubscription-lab.ps1') `
        -SourceA $sourceA.Id -TargetA $targetA.Id -SourceB $sourceB.Id -TargetB $targetB.Id
    Assert-Rejected {
        & (Join-Path $root 'scripts/preflight-multisubscription-lab.ps1') `
            -SourceA $sourceA.Id -TargetA $targetB.Id -SourceB $sourceB.Id -TargetB $targetA.Id
    } 'approved target ID'
    Write-Host 'PASS: lab gate accepts two approved pairs and rejects swapped targets with mocked inventory.'
    & (Join-Path $root 'scripts/preflight-multisubscription-lab.ps1') `
        -SourceA $sourceA.Id -TargetA $targetA.Id -Mode SinglePair
    Write-Host 'PASS: explicitly authorized single-pair lab mode keeps the same resolver.'
} finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
}
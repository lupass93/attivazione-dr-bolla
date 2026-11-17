# profile.ps1
# Runs once when the Azure Functions host starts.
# Authenticates using the configured source user-assigned managed identity.
# Supports both Windows (MSI_SECRET) and Linux (IDENTITY_ENDPOINT) MI semantics.

$accountsManifest = Join-Path $PSScriptRoot 'Modules/Az.Accounts/5.4.0/Az.Accounts.psd1'
Import-Module $accountsManifest -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Modules/DRAudit/DRAudit.psm1') -Global -ErrorAction Stop

if ($env:MSI_SECRET -or $env:IDENTITY_ENDPOINT) {
    try {
        Initialize-DRAudit -FunctionName 'profile'
        Disable-AzContextAutosave -Scope Process | Out-Null
        # AZURE_CLIENT_ID selects the user-assigned identity; without it the token endpoint uses the system-assigned one.
        $connectArgs = @{ Identity = $true; AccountId = $env:SOURCE_IDENTITY_CLIENT_ID; SkipContextPopulation = $true }
        Invoke-DRAzureOperation -Operation 'Connect-AzAccount (host startup)' -Plane Identity `
            -ResourceId "/subscriptions/$env:HOSTING_SUBSCRIPTION_ID" -IdentityClientId $env:SOURCE_IDENTITY_CLIENT_ID `
            -ScriptBlock { Connect-AzAccount @connectArgs | Out-Null } | Out-Null
    }
    catch {
        Write-DRAuditEvent -Operation 'Authenticate host startup' -Plane Identity -Status Failed `
            -IdentityClientId $env:SOURCE_IDENTITY_CLIENT_ID -ErrorMessage $_.Exception.Message
    }
}

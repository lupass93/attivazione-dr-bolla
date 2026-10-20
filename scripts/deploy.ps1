<#
.SYNOPSIS
Deploy an existing ZIP to an explicit Azure target or to the target recorded in Terraform outputs.
.PARAMETER SubscriptionId
Hosting subscription. Specify together with ResourceGroupName and FunctionAppName to avoid Terraform entirely.
.PARAMETER ResourceGroupName
Resource Group containing the existing Function App.
.PARAMETER FunctionAppName
Existing Function App to update. Its API hostname is read from Azure.
.PARAMETER TerraformDirectory
Alternative to the three explicit target parameters. Default: terraform in this repository.
.PARAMETER PackagePath
Existing deployment ZIP. Default: out/function-app.zip in this repository. Custom relative paths use the caller's directory.
#>
[CmdletBinding(DefaultParameterSetName = 'Terraform')]
param(
    [Parameter(ParameterSetName = 'Terraform', Position = 0)]
    [ValidateNotNullOrWhiteSpace()]
    [string]$TerraformDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform'),
    [Parameter(Position = 1)]
    [ValidateNotNullOrWhiteSpace()]
    [string]$PackagePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'out/function-app.zip'),
    [Parameter(Mandatory, ParameterSetName = 'Explicit')]
    [ValidateNotNullOrWhiteSpace()]
    [string]$SubscriptionId,
    [Parameter(Mandatory, ParameterSetName = 'Explicit')]
    [ValidateNotNullOrWhiteSpace()]
    [string]$ResourceGroupName,
    [Parameter(Mandatory, ParameterSetName = 'Explicit')]
    [ValidateNotNullOrWhiteSpace()]
    [string]$FunctionAppName
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) { throw 'Run scripts/build.ps1 before deploying, or provide an existing ZIP.' }
if ($PSCmdlet.ParameterSetName -eq 'Explicit') {
    $subscription = $SubscriptionId
    $resourceGroup = $ResourceGroupName
    $name = $FunctionAppName
    $hostname = az functionapp show --subscription $subscription --resource-group $resourceGroup --name $name `
        --query 'defaultHostName || properties.defaultHostName' --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the target Function App. Check its name, subscription and access.' }
    if ($hostname -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z0-9-]+$') { throw 'The target Function App has no valid default hostname.' }
    $api = "https://$hostname/api"
} else {
    $outputText = terraform "-chdir=$TerraformDirectory" output -json
    if ($LASTEXITCODE -ne 0) { throw 'Terraform outputs unavailable. Select an existing state, or use the three explicit target parameters.' }
    $outputs = ($outputText -join "`n") | ConvertFrom-Json
    $subscription = $outputs.hosting_subscription_id.value
    $resourceGroup = $outputs.resource_group_name.value
    $name = $outputs.function_app_name.value
    $api = $outputs.api_url.value
    foreach ($required in @{
            hosting_subscription_id = $subscription; resource_group_name = $resourceGroup
            function_app_name = $name; api_url = $api
        }.GetEnumerator()) {
        if ($required.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($required.Value)) {
            throw "Missing Terraform output: $($required.Key)."
        }
    }
}
Write-Host "Deploying $PackagePath to subscription $subscription, Resource Group $resourceGroup, Function App $name."

az functionapp config appsettings delete --subscription $subscription --resource-group $resourceGroup --name $name --setting-names AzureWebJobsStorage --output none --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Unable to select identity-based host storage. Deployment stopped.' }

az functionapp deployment source config-zip --subscription $subscription --resource-group $resourceGroup --name $name --src $PackagePath --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Deployment failed. Inspect the Azure error before retrying.' }

$functions = az functionapp function list --subscription $subscription --resource-group $resourceGroup --name $name --query '[].name' -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not ($functions -match '/Invoke-DRReplication$') -or
    -not ($functions -match '/Get-DRStatus$') -or -not ($functions -match '/Process-DRSession$')) {
    throw 'All three functions must be indexed. Check host startup, queue identity and private storage access.'
}
$key = az functionapp keys list --subscription $subscription --resource-group $resourceGroup --name $name --query functionKeys.default -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($key)) { throw 'Function key unavailable.' }
try {
    $headers = @{ 'x-functions-key' = $key }
    $invoke = Invoke-RestMethod -Method Post -Uri "$api/Invoke-DRReplication" -Headers $headers -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck -StatusCodeVariable invokeCode -TimeoutSec 60
    $status = Invoke-RestMethod -Method Get -Uri "$api/Get-DRStatus" -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable statusCode -TimeoutSec 60
    if ($invokeCode -ne 400 -or $statusCode -ne 400) { throw 'Expected HTTP 400 for missing sessionId on both endpoints.' }
    Write-Host "Deployment verified. Invoke and Get-DRStatus respond correctly; no replication was started."
} finally {
    Remove-Variable key, headers -ErrorAction SilentlyContinue
}
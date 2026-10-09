[CmdletBinding()]
param(
    [string]$TerraformDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform'),
    [string]$PackagePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'out/function-app.zip')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $PackagePath)) { throw 'Run scripts/build.ps1 before deploying.' }
$outputs = terraform "-chdir=$TerraformDirectory" output -json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Terraform outputs unavailable. Apply the infrastructure first.' }
$subscription = $outputs.hosting_subscription_id.value
$resourceGroup = $outputs.resource_group_name.value
$name = $outputs.function_app_name.value
$api = $outputs.api_url.value

az functionapp config appsettings delete --subscription $subscription --resource-group $resourceGroup --name $name --setting-names AzureWebJobsStorage --output none --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Unable to select identity-based host storage. Deployment stopped.' }

az functionapp deployment source config-zip --subscription $subscription --resource-group $resourceGroup --name $name --src $PackagePath --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Deployment failed. Inspect the Azure error before retrying.' }

$functions = az functionapp function list --subscription $subscription --resource-group $resourceGroup --name $name --query '[].name' -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not ($functions -match '/Invoke-DRReplication$') -or -not ($functions -match '/Get-DRStatus$')) {
    throw 'Both functions are not yet indexed. Check host startup and storage access.'
}
$key = az functionapp keys list --subscription $subscription --resource-group $resourceGroup --name $name --query functionKeys.default -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($key)) { throw 'Function key unavailable.' }
try {
    $headers = @{ 'x-functions-key' = $key }
    $invoke = Invoke-RestMethod -Method Post -Uri "$api/Invoke-DRReplication" -Headers $headers -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck -StatusCodeVariable invokeCode -TimeoutSec 60
    $status = Invoke-RestMethod -Method Get -Uri "$api/Get-DRStatus" -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable statusCode -TimeoutSec 60
    if ($invokeCode -ne 400 -or $statusCode -ne 400) { throw 'Expected HTTP 400 for missing CSV on both endpoints.' }
    Write-Host "Deployment verified. Invoke and Get-DRStatus respond correctly; no replication was started."
} finally {
    Remove-Variable key, headers -ErrorAction SilentlyContinue
}
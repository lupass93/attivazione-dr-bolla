$ErrorActionPreference = 'Stop'
$script:LiveRoot = Split-Path $PSScriptRoot -Parent
$script:LiveChecks = 0

function Initialize-LiveDRTest {
    $text = terraform "-chdir=$(Join-Path $script:LiveRoot 'terraform')" output -json
    if ($LASTEXITCODE -ne 0) { throw 'Terraform outputs are unavailable.' }
    $script:LiveOutputs = ($text -join "`n") | ConvertFrom-Json -AsHashtable
    $script:LiveApi = $script:LiveOutputs.api_url.value
    $script:LiveStorage = $script:LiveOutputs.storage_account_name.value
    $script:LiveSubscription = $script:LiveOutputs.hosting_subscription_id.value
    $key = az functionapp keys list --subscription $script:LiveSubscription `
        --resource-group $script:LiveOutputs.resource_group_name.value `
        --name $script:LiveOutputs.function_app_name.value --query functionKeys.default -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($key)) { throw 'Function key unavailable.' }
    $script:LiveHeaders = @{ 'x-functions-key' = $key }
    $key = $null
}

function Assert-LiveDR {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:LiveChecks++
}

function Invoke-LiveDRRequest {
    param([string]$Route, [string]$Method = 'GET', [AllowNull()][string]$Body, [switch]$Unauthenticated)
    $parameters = @{
        Uri = "$script:LiveApi/$Route"; Method = $Method; SkipHttpErrorCheck = $true
        TimeoutSec = 120; ErrorAction = 'Stop'
    }
    if (-not $Unauthenticated) { $parameters.Headers = $script:LiveHeaders }
    if ($PSBoundParameters.ContainsKey('Body')) { $parameters.Body = $Body; $parameters.ContentType = 'application/json' }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-WebRequest @parameters
    $watch.Stop()
    $json = $null
    if ($response.Headers['Content-Type'] -match 'application/json' -and $response.Content) {
        $json = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    return @{
        Code = [int]$response.StatusCode; Json = $json; Headers = $response.Headers
        DurationSeconds = $watch.Elapsed.TotalSeconds; ReceivedAtUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Write-LiveDRCsv {
    param([string]$Content, [string]$Path)
    $temporary = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($temporary, $Content, [System.Text.UTF8Encoding]::new($false))
        az storage blob upload --subscription $script:LiveSubscription --account-name $script:LiveStorage `
            --container-name $script:LiveOutputs.csv_container_name.value --name $Path --file $temporary `
            --auth-mode login --overwrite --content-type text/csv --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Test CSV upload failed.' }
    }
    finally { Remove-Item -LiteralPath $temporary -Force }
}

function Remove-LiveDRCsv {
    param([string]$Path)
    if (-not $Path.StartsWith('dr-tests/')) { throw 'Cleanup is restricted to test-owned CSV paths.' }
    az storage blob delete --subscription $script:LiveSubscription --account-name $script:LiveStorage `
        --container-name $script:LiveOutputs.csv_container_name.value --name $Path `
        --auth-mode login --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Test CSV cleanup failed.' }
}

function Read-LiveDRBlob {
    param([string]$Container, [string]$Path)
    $temporary = [System.IO.Path]::GetTempFileName()
    try {
        az storage blob download --subscription $script:LiveSubscription --account-name $script:LiveStorage `
            --container-name $Container --name $Path --file $temporary --auth-mode login `
            --overwrite --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Persistent session read-back failed.' }
        return Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    }
    finally { Remove-Item -LiteralPath $temporary -Force }
}

function Wait-LiveDRSession {
    param([string]$SessionId, [int]$TimeoutSeconds = 1200)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $observed = [System.Collections.Generic.List[string]]::new()
    do {
        $response = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$SessionId"
        if ($response.Code -ne 200) { throw "Status request failed with HTTP $($response.Code)." }
        Assert-LiveDR ($response.Json.sessionId -eq $SessionId) 'Status switched to a different session.'
        if ($response.Json.status -notin $observed) { $observed.Add($response.Json.status) }
        if ($response.Json.status -in @('SUCCEEDED', 'FAILED')) {
            return @{ State = $response.Json; Observed = @($observed); DurationSeconds = $watch.Elapsed.TotalSeconds }
        }
        Start-Sleep -Seconds 5
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Session $SessionId did not reach a terminal state within $TimeoutSeconds seconds; do not resubmit with a new ID."
}

function Get-LiveDRWorkloadIds {
    param([string]$SubscriptionId, [string]$ResourceGroup)
    $text = az resource list --subscription $SubscriptionId --resource-group $ResourceGroup `
        --query "[?type=='Microsoft.Compute/virtualMachines' || type=='Microsoft.Compute/disks' || type=='Microsoft.Compute/snapshots' || type=='Microsoft.Network/networkInterfaces'].id" `
        -o json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Target workload inventory failed.' }
    return @((($text -join "`n") | ConvertFrom-Json) | Sort-Object)
}

function Save-LiveDREvidence {
    param([string]$Name, [System.Collections.IDictionary]$Evidence)
    $directory = Join-Path $script:LiveRoot 'out/live'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $Evidence['verifiedAtUtc'] = [datetime]::UtcNow.ToString('o')
    $Evidence['checks'] = $script:LiveChecks
    $Evidence['result'] = 'PASS'
    $Evidence | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $directory "$Name.json") -Encoding utf8
    Write-Host "PASS: $Name, $script:LiveChecks checks."
}

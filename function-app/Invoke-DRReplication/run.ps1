using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules/DRSessions/DRSessions.psm1') -ErrorAction Stop

try {
    try {
        $body = if ($Request.Body -is [string]) { $Request.Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop } else { $Request.Body }
    }
    catch { Stop-DRRequest 400 'The request body must be a JSON object.' }
    if ($body -isnot [System.Collections.IDictionary]) { Stop-DRRequest 400 'The request body must be a JSON object.' }
    if (@($body.Keys | Where-Object { $_ -notin @('sessionId', 'csvBlobPath') }).Count -gt 0) {
        Stop-DRRequest 400 'Only sessionId and csvBlobPath are supported request parameters.'
    }
    $sessionId = ConvertTo-DRSessionId ([string]$body.sessionId)
    if ($body.csvBlobPath -isnot [string] -or [string]::IsNullOrWhiteSpace($body.csvBlobPath)) {
        Stop-DRRequest 400 'csvBlobPath is required and must be a string.'
    }
    $client = New-DRStorageClient
    $csv = Read-DRCsvRequest $client ([string]$body.csvBlobPath)
    $previous = Register-DRSession $client $sessionId ([string]$body.csvBlobPath) $csv
    $state = Submit-DRSession $client $sessionId
    $statusUrl = "/api/Get-DRStatus?sessionId=$sessionId"
    $code = if ($previous.status -in @('SUCCEEDED', 'FAILED')) { [HttpStatusCode]::OK } else { [HttpStatusCode]::Accepted }
    $response = Get-DRSessionResponse $state
    $response['statusUrl'] = $statusUrl
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $code
        Headers = @{ 'Content-Type' = 'application/json'; Location = $statusUrl; 'Retry-After' = '5' }
        Body = ($response | ConvertTo-Json -Depth 20)
    })
}
catch {
    Write-Host "DR submission failed: $($_.Exception)"
    $code = if ($_.Exception.Data.Contains('HttpStatusCode')) { [int]$_.Exception.Data['HttpStatusCode'] } else { 503 }
    $message = if ($_.Exception.Data.Contains('HttpStatusCode')) { $_.Exception.Message } else { 'DR submission is unavailable. Consult the Function logs and retry the same sessionId.' }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $code
        Headers = @{ 'Content-Type' = 'application/json' }
        Body = (@{ error = $message } | ConvertTo-Json)
    })
}

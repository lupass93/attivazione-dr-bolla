using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules/DRSessions/DRSessions.psm1') -ErrorAction Stop
Initialize-DRAudit -FunctionName 'Get-DRStatus'
$client = $null

try {
    $inputId = if ($Request.Method -eq 'GET') { $Request.Query.sessionId } else {
        try {
            $body = if ($Request.Body -is [string]) { $Request.Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop } else { $Request.Body }
        }
        catch { Stop-DRRequest 400 'The request body must be a JSON object.' }
        if ($body -isnot [System.Collections.IDictionary]) { Stop-DRRequest 400 'The request body must be a JSON object.' }
        $body.sessionId
    }
    $sessionId = ConvertTo-DRSessionId ([string]$inputId)
    Set-DRAuditContext -SessionId $sessionId
    $client = New-DRStorageClient
    $record = Get-DRSessionState $client $sessionId
    if ($null -eq $record) { Stop-DRRequest 404 'No session exists with the requested sessionId.' }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers = @{ 'Content-Type' = 'application/json'; 'Cache-Control' = 'no-store'; 'Retry-After' = '5' }
        Body = ((Get-DRSessionResponse $record.Value) | ConvertTo-Json -Depth 20)
    })
}
catch {
    Write-DRAuditEvent -Operation 'Read DR session status' -Status Failed -ErrorMessage $_.Exception.Message
    $code = if ($_.Exception.Data.Contains('HttpStatusCode')) { [int]$_.Exception.Data['HttpStatusCode'] } else { 503 }
    $message = if ($_.Exception.Data.Contains('HttpStatusCode')) { $_.Exception.Message } else { 'Session status is unavailable. Consult the Function logs.' }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $code
        Headers = @{ 'Content-Type' = 'application/json' }
        Body = (@{ error = $message } | ConvertTo-Json)
    })
}
finally {
    if ($null -ne $client) { Save-DRSessionAudit $client }
}

. (Join-Path $PSScriptRoot 'SessionTestSupport.ps1')
$id = '99999999-9999-4999-8999-999999999999'
Set-TestCsv "Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName`nSistemico (2h),APP01,source-a,rg-web,vm-one"
$global:QueueFailure = $true
$response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' }
Assert-Test ([int]$response.StatusCode -eq 503) 'Queue failure must preserve the existing 503 contract.'
$body = $response.Body | ConvertFrom-Json -AsHashtable
Assert-Test ($body.Keys.Count -eq 1 -and $body.ContainsKey('error') -and $body.error -like 'Queue acceptance could not be confirmed.*') 'Do not replace the client error response with a new diagnostic schema.'
$state = (Get-DRSessionState $global:TestClient $id).Value
Assert-Test ($state.status -eq 'PENDING' -and -not $state.queueConfirmed -and $state.results[0].acronimo -eq 'APP01') 'Submission diagnostics must not invent a successful queue confirmation or alter VM metadata.'
$logs = @($global:BlobStore.Keys | Where-Object { $_ -like "*/dr-logs/sessions/$id/*" })
Assert-Test ($logs.Count -gt 0) 'A queue failure must leave a durable diagnostic before the worker starts.'
$text = ($logs | ForEach-Object { [string]$global:BlobStore[$_] }) -join "`n"
Assert-Test ($text.Contains('Simulated queue outage.') -and $text.Contains($id) -and $text.Contains('APP01') -and
    $text.Contains('Sistemico (2h)')) 'Persist the original submission failure and the available customer metadata.'
$global:QueueFailure = $false
$retry = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' }
Assert-Test ([int]$retry.StatusCode -eq 202 -and $global:QueueMessages.Count -eq 1) 'The same session must remain safely retryable after permissions/connectivity recover.'
Write-Host "PASS: $global:TestCount early-submission logging and client-contract checks; no Azure calls."

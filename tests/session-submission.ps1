. (Join-Path $PSScriptRoot 'SessionTestSupport.ps1')
$id = '11111111-1111-4111-8111-111111111111'
$csv = "Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName`nSistemico (2h),APP01,source-a,rg-web,vm-one"
Set-TestCsv $csv
$binaryId = '88888888-8888-4888-8888-888888888888'
Set-TestCsv $csv -Path 'binary.csv' -Binary
$binaryResponse = Invoke-TestSubmission @{ sessionId = $binaryId; csvBlobPath = 'binary.csv' }
Assert-Test ([int]$binaryResponse.StatusCode -eq 202) 'Binary HTTP content must be decoded as UTF-8 CSV.'
$global:QueueMessages.Clear()
foreach ($body in @(@{}, @{ sessionId = 'invalid'; csvBlobPath = 'vms.csv' }, '{not-json',
        @{ sessionId = $id; csvBlobPath = 'vms.csv'; invocationId = 'old' })) {
    $response = Invoke-TestSubmission $body
    Assert-Test ([int]$response.StatusCode -eq 400) 'Invalid requests must fail with 400.'
}
Assert-Test ($global:QueueMessages.Count -eq 0) 'Validation failures must not enqueue work.'
$response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'missing.csv' }
Assert-Test ([int]$response.StatusCode -eq 404) 'Missing CSV must return 404.'
Set-TestCsv "$csv`nSistemico (2h),APP01,source-a,rg-web,vm-one"
$response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' }
Assert-Test ([int]$response.StatusCode -eq 400) 'Duplicate CSV rows must be rejected.'
Set-TestCsv "Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName`nSistemico (2h),APP01,source-a,,vm-one"
$response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' }
Assert-Test ([int]$response.StatusCode -eq 400) 'An incomplete CSV row must not be silently skipped.'
Set-TestCsv $csv
$global:QueueFailure = $true
$response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' }
Assert-Test ([int]$response.StatusCode -eq 503) 'No queue acknowledgement must mean no 202.'
Assert-Test (-not (Get-DRSessionState $global:TestClient $id).Value.queueConfirmed) 'An unconfirmed session must remain unconfirmed.'
$global:QueueFailure = $false
$response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' }
$body = $response.Body | ConvertFrom-Json
Assert-Test ([int]$response.StatusCode -eq 202 -and $body.sessionId -eq $id -and $body.queueConfirmed) 'The confirmed response must retain the client sessionId.'
Assert-Test ($global:QueueMessages.Count -eq 1 -and $global:CoreCalls.Count -eq 0) 'The HTTP starter must enqueue without running replication.'
Assert-Test ($response.Headers.Location -eq "/api/Get-DRStatus?sessionId=$id") 'The response must identify the session-specific status endpoint.'
$global:CreateConflictCode = 409
Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' } | Out-Null
Assert-Test ($global:QueueMessages.Count -eq 1) 'Replaying an accepted request must not enqueue it again.'
$global:CreateConflictError = 'LeaseAlreadyPresent'
$response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' }
Assert-Test ([int]$response.StatusCode -eq 503) 'Only BlobAlreadyExists may be treated as an existing session; unrelated storage conflicts must fail.'
$global:CreateConflictError = 'BlobAlreadyExists'
Set-TestCsv $csv -Path 'VMS.csv'
$response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'VMS.csv' }
Assert-Test ([int]$response.StatusCode -eq 409) 'Blob paths are case-sensitive even when CSV contents are identical.'
$stored = Read-DRDocument $global:TestClient "sessions/$id/request.json"
Set-TestCsv "Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName`nSistemico (2h),APP01,source-a,rg-web,vm-new"
$response = Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' }
Assert-Test ([int]$response.StatusCode -eq 409) 'A different CSV must not reuse a sessionId.'
Assert-Test ($stored.Value.rows[0].SourceVmName -eq 'vm-one') 'The original session manifest must remain immutable.'
$global:WriteConflict = $true
Update-DRSessionState $global:TestClient $id -QueueConfirmed | Out-Null
Assert-Test ((Get-DRSessionState $global:TestClient $id).Value.sessionId -eq $id) 'Conditional updates must survive an ETag conflict.'
Write-Host "PASS: $global:TestCount session submission checks; no Azure calls."

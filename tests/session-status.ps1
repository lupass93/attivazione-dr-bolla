. (Join-Path $PSScriptRoot 'SessionTestSupport.ps1')
$idA = '55555555-5555-4555-8555-555555555555'
$idB = '66666666-6666-4666-8666-666666666666'
Set-TestCsv "SourceSubscription,SourceResourceGroup,SourceVmName`nsource-a,rg-web,vm-same`nsource-b,rg-web,vm-same"
foreach ($id in @($idA, $idB)) { Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' } | Out-Null }
Update-DRSessionState $global:TestClient $idA -Changes @{ status = 'SUCCEEDED' } | Out-Null
$statusScript = Join-Path $script:Root 'function-app/Get-DRStatus/run.ps1'
& $statusScript -Request @{ Method = 'GET'; Query = @{ sessionId = $idB } } -TriggerMetadata @{}
$body = $global:CapturedResponse.Body | ConvertFrom-Json
Assert-Test ([int]$global:CapturedResponse.StatusCode -eq 200 -and $body.sessionId -eq $idB -and $body.status -eq 'QUEUED') 'Session B must never inherit session A success.'
Assert-Test ($body.results.Count -eq 2 -and $body.results[0].sourceSubscription -ne $body.results[1].sourceSubscription) 'Homonymous VMs must remain distinct in persisted status.'
Assert-Test ($global:CapturedResponse.Headers['Cache-Control'] -eq 'no-store') 'Session status must not be cached.'
Set-TestCsv "unrelated`nchanged"
& $statusScript -Request @{ Method = 'POST'; Body = @{ sessionId = $idB } } -TriggerMetadata @{}
$body = $global:CapturedResponse.Body | ConvertFrom-Json
Assert-Test ($body.vmCount -eq 2 -and $body.sessionId -eq $idB) 'Status must not reread or reinterpret a changed CSV.'
& $statusScript -Request @{ Method = 'GET'; Query = @{ sessionId = '77777777-7777-4777-8777-777777777777' } } -TriggerMetadata @{}
Assert-Test ([int]$global:CapturedResponse.StatusCode -eq 404) 'An unknown session must not return an older execution.'
& $statusScript -Request @{ Method = 'GET'; Query = @{} } -TriggerMetadata @{}
Assert-Test ([int]$global:CapturedResponse.StatusCode -eq 400) 'sessionId is required for status.'
& $statusScript -Request @{ Method = 'POST'; Body = '{invalid' } -TriggerMetadata @{}
Assert-Test ([int]$global:CapturedResponse.StatusCode -eq 400) 'Invalid status JSON must return 400.'
Write-Host "PASS: $global:TestCount session status checks; no Azure calls."

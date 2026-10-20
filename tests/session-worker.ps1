. (Join-Path $PSScriptRoot 'SessionTestSupport.ps1')
$id = '22222222-2222-4222-8222-222222222222'
Set-TestCsv "SourceSubscription,SourceResourceGroup,SourceVmName`nsource-a,rg-web,vm-one`nsource-b,rg-web,vm-two"
Invoke-TestSubmission @{ sessionId = $id; csvBlobPath = 'vms.csv' } | Out-Null
Set-TestCsv "SourceSubscription,SourceResourceGroup,SourceVmName`nsource-a,rg-web,vm-changed"
Invoke-TestWorker $id
$state = (Get-DRSessionState $global:TestClient $id).Value
Assert-Test ($state.status -eq 'SUCCEEDED' -and $state.results.Count -eq 2) 'The worker must execute the persisted CSV snapshot.'
Assert-Test ($global:CoreCalls.Count -eq 4) 'Both preflights must precede both replications.'
Assert-Test ($global:CoreCalls[0].preflight -and $global:CoreCalls[1].preflight -and -not $global:CoreCalls[2].preflight) 'No workload must be created before every preflight passes.'
Assert-Test (@($global:CoreCalls | Where-Object sessionId -ne $id).Count -eq 0) 'All core calls must preserve the client sessionId.'
Invoke-TestWorker $id 'duplicate-message'
Assert-Test ($global:CoreCalls.Count -eq 4) 'A terminal session must not execute twice.'

$nativeId = '99999999-9999-4999-8999-999999999999'
Invoke-TestSubmission @{ sessionId = $nativeId; csvBlobPath = 'vms.csv' } | Out-Null
Invoke-TestWorker $nativeId -NativePayload
Assert-Test ((Get-DRSessionState $global:TestClient $nativeId).Value.status -eq 'SUCCEEDED') 'The real PowerShell binding may provide an already deserialized hashtable, not JSON text.'

$id2 = '33333333-3333-4333-8333-333333333333'
Set-TestCsv "SourceSubscription,SourceResourceGroup,SourceVmName`nsource-a,rg-web,vm-one`nsource-b,rg-web,vm-two"
Invoke-TestSubmission @{ sessionId = $id2; csvBlobPath = 'vms.csv' } | Out-Null
$global:PreflightFailures = @('vm-two')
$before = $global:CoreCalls.Count
try { Invoke-TestWorker $id2; throw 'Expected preflight failure.' }
catch { if ($_.Exception.Message -notlike '*preflight failed*') { throw } }
$state = (Get-DRSessionState $global:TestClient $id2).Value
Assert-Test ($state.status -eq 'FAILED' -and $state.phase -eq 'Preflight') 'Preflight failure must be persisted.'
Assert-Test (@($global:CoreCalls | Select-Object -Skip $before | Where-Object preflight -eq $false).Count -eq 0) 'A failed preflight must cause zero workload writes.'
Assert-Test ($state.results[0].status -eq 'NOT_STARTED' -and $state.results[1].error -like '*ASG*') 'Missing prerequisites must identify the failing VM and keep others not started.'

$id3 = '44444444-4444-4444-8444-444444444444'
$global:PreflightFailures = @()
Invoke-TestSubmission @{ sessionId = $id3; csvBlobPath = 'vms.csv' } | Out-Null
Update-DRSessionState $global:TestClient $id3 -Changes @{ status = 'RUNNING'; messageId = 'lost-worker' } | Out-Null
$before = $global:CoreCalls.Count
Invoke-TestWorker $id3 'duplicate-other-message'
Assert-Test ($global:CoreCalls.Count -eq $before) 'A different message must not steal an active session.'
try { Invoke-TestWorker $id3 'lost-worker'; throw 'Expected interruption failure.' }
catch { if ($_.Exception.Message -notlike '*interrupted*') { throw } }
$state = (Get-DRSessionState $global:TestClient $id3).Value
Assert-Test ($state.status -eq 'FAILED' -and $state.requiresReview -and $global:CoreCalls.Count -eq $before) 'An interrupted session must fail closed, not silently replay partial operations.'
Write-Host "PASS: $global:TestCount session worker checks; no Azure calls."

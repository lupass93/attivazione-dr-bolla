[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'LiveTestSupport.ps1')
Initialize-LiveDRTest
$id = [guid]::NewGuid().ToString('D')
$path = "dr-tests/$id-invalid.csv"
$csvCreated = $false
try {
    $response = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$id" -Unauthenticated
    Assert-LiveDR ($response.Code -eq 401) 'Missing function key must be rejected.'
    foreach ($body in @('{}', '{"sessionId":"invalid","csvBlobPath":"test.csv"}', '{invalid')) {
        $response = Invoke-LiveDRRequest Invoke-DRReplication -Method POST -Body $body
        Assert-LiveDR ($response.Code -eq 400) "Malformed or incomplete request must return 400; received HTTP $($response.Code)."
    }
    $response = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$id"
    Assert-LiveDR ($response.Code -eq 404) 'Invalid submissions must not register a session.'
    $response = Invoke-LiveDRRequest Invoke-DRReplication -Method POST `
        -Body (@{ sessionId = $id; csvBlobPath = "dr-tests/$id-missing.csv" } | ConvertTo-Json)
    Assert-LiveDR ($response.Code -eq 404) 'A nonexistent CSV must return 404.'
    Write-LiveDRCsv "Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName`nSistemico (2h),APP01,source,,vm" $path
    $csvCreated = $true
    $response = Invoke-LiveDRRequest Invoke-DRReplication -Method POST `
        -Body (@{ sessionId = $id; csvBlobPath = $path } | ConvertTo-Json)
    Assert-LiveDR ($response.Code -eq 400) 'A missing column value must reject the complete request.'
    Write-LiveDRCsv "Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName`nSistemico (2h),APP01,source,rg,vm`nSistemico (2h),APP01,source,rg,vm" $path
    $response = Invoke-LiveDRRequest Invoke-DRReplication -Method POST `
        -Body (@{ sessionId = $id; csvBlobPath = $path } | ConvertTo-Json)
    Assert-LiveDR ($response.Code -eq 400) 'Duplicate rows must be rejected.'
    foreach ($csv in @(
        "Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName`nUnknown,APP01,source,rg,vm",
        "Criticita,Acronimo,SourceSubscription,SourceResourceGroup,SourceVmName`nSistemico (2h),,source,rg,vm",
        "SourceSubscription,SourceResourceGroup,SourceVmName`nsource,rg,vm"
    )) {
        Write-LiveDRCsv $csv $path
        $response = Invoke-LiveDRRequest Invoke-DRReplication -Method POST `
            -Body (@{ sessionId = $id; csvBlobPath = $path } | ConvertTo-Json)
        Assert-LiveDR ($response.Code -eq 400) 'Unknown RTO, missing acronym and old three-column CSV must be rejected.'
    }
    $response = Invoke-LiveDRRequest "Get-DRStatus?sessionId=$id"
    Assert-LiveDR ($response.Code -eq 404) 'Rejected CSVs must not leave an accepted session.'
    Save-LiveDREvidence 'request-validation' @{ rejectedSessionId = $id; persistedSession = $false }
}
catch {
    Write-Host "Live request validation failed: $($_.Exception)"
    throw
}
finally {
    if ($csvCreated) { Remove-LiveDRCsv $path }
    $script:LiveHeaders.Clear()
}

# Invoke-DRReplication/run.ps1
# HTTP trigger: POST /api/Invoke-DRReplication
#
# Request body (JSON):
#   {
#     "csvBlobPath": "configurations/production-config.csv",   // required
#     "vmParallelThrottle": 1                                   // optional; must be 1
#   }
#
# Environment variables consumed:
#   CSV_STORAGE_CONNECTION__blobServiceUri  – blob service endpoint (managed identity)
#   CSV_CONTAINER_NAME                      – container holding the CSV (default: dr-configs)
#   VM_PARALLEL_THROTTLE                    – default VM-level parallelism (default: 1)
#   PARALLEL_THROTTLE                       – disk-level parallelism per VM (default: 6)
#   TAG_PREFIX removed — tags are copied as-is
#   SNAPSHOT_NAME_PREFIX / BACKEND_POOL_NAME_OVERRIDE
#
# Response: HTTP 202 after processing, with invocationId; per-VM results are read from Get-DRStatus.

using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

function Write-FuncLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK'
    Write-Host "$ts [$Level] $Message"
}

$startedAt = (Get-Date).ToUniversalTime().ToString('o')
Write-FuncLog "DR Replication function invoked."

try {
    # ── Parse request body ──────────────────────────────────────────────────────
    $body = $Request.Body
    if ($body -is [string] -and -not [string]::IsNullOrWhiteSpace($body)) {
        $body = $body | ConvertFrom-Json -ErrorAction Stop
    }

    $csvBlobPath = [string]$body.csvBlobPath
    if ([string]::IsNullOrWhiteSpace($csvBlobPath)) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = '{"error":"csvBlobPath is required in the request body."}'
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # VM-level parallelism (body overrides env var; clamped 1-10)
    $envThrottle       = [int]($env:VM_PARALLEL_THROTTLE ?? '1')
    $vmParallelThrottle = if ($null -ne $body.vmParallelThrottle) { [int]$body.vmParallelThrottle } else { $envThrottle }
    $vmParallelThrottle = [Math]::Max(1, [Math]::Min(10, $vmParallelThrottle))
    if ($vmParallelThrottle -ne 1) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body = '{"error":"This two-identity configuration requires vmParallelThrottle=1."}'
        })
        return
    }

    # Disk-level parallelism (env var only; clamped 1-64)
    $diskThrottle = [int]($env:PARALLEL_THROTTLE ?? '6')
    $diskThrottle = [Math]::Max(1, [Math]::Min(64, $diskThrottle))

    # Per-VM settings
    $snapshotNamePrefix    = [string]($env:SNAPSHOT_NAME_PREFIX   ?? 'snap-')
    $backendPoolNameOverride = [string]($env:BACKEND_POOL_NAME_OVERRIDE ?? '')
    $logContainerName             = [string]($env:LOG_CONTAINER_NAME             ?? 'dr-logs')
    $targetSubscriptionSuffix     = [string]($env:TARGET_SUBSCRIPTION_SUFFIX     ?? '')
    $targetResourceGroupSuffix    = [string]($env:TARGET_RESOURCE_GROUP_SUFFIX   ?? '')
    $targetVnetNameSuffix         = [string]($env:TARGET_VNET_NAME_SUFFIX        ?? '')
    $targetVnetRgSuffix           = [string]($env:TARGET_VNET_RG_SUFFIX          ?? '')
    $targetLbNameSuffix           = [string]($env:TARGET_LB_NAME_SUFFIX          ?? '')
    $targetLbRgSuffix             = [string]($env:TARGET_LB_RG_SUFFIX            ?? '')
    $targetDesNameSuffix          = [string]($env:TARGET_DES_NAME_SUFFIX         ?? '')
    $targetDesRgSuffix            = [string]($env:TARGET_DES_RG_SUFFIX           ?? '')
    $targetAsgNameSuffix          = [string]($env:TARGET_ASG_NAME_SUFFIX         ?? '')

    Write-FuncLog "csvBlobPath='$csvBlobPath' vmParallelThrottle=$vmParallelThrottle diskThrottle=$diskThrottle"

    # ── Download CSV from Azure Blob Storage (managed identity) ─────────────────
    $blobServiceUri = [string]$env:CSV_STORAGE_CONNECTION__blobServiceUri
    if ([string]::IsNullOrWhiteSpace($blobServiceUri)) {
        throw "Environment variable 'CSV_STORAGE_CONNECTION__blobServiceUri' is not configured."
    }

    $containerName      = [string]($env:CSV_CONTAINER_NAME ?? 'dr-configs')
    $storageAccountName = ($blobServiceUri -replace 'https://', '' -replace '\.blob\.core\.windows\.net.*', '').Trim('/')

    Write-FuncLog "Downloading CSV '$csvBlobPath' from storage account '$storageAccountName', container '$containerName'."

    Disable-AzContextAutosave -Scope Process | Out-Null
    $sourceProfile = (Connect-AzAccount -Identity -AccountId $env:SOURCE_IDENTITY_CLIENT_ID `
        -Subscription $env:HOSTING_SUBSCRIPTION_ID -SkipContextPopulation -Scope Process -ErrorAction Stop).Context
    $storageCtx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount -ErrorAction Stop
    $tempFile   = [System.IO.Path]::GetTempFileName()
    try {
        try {
            Get-AzStorageBlobContent -Context $storageCtx -Container $containerName -Blob $csvBlobPath `
                -Destination $tempFile -Force -ErrorAction Stop | Out-Null
        }
        catch {
            if ($_.Exception.GetType().Name -eq 'ResourceNotFoundException' -or $_.Exception.Message -like 'Can not find blob*') {
                Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::NotFound
                    Body       = ([ordered]@{ error = "CSV blob '$csvBlobPath' not found in container '$containerName'." } | ConvertTo-Json)
                    Headers    = @{ 'Content-Type' = 'application/json' }
                })
                return
            }
            throw
        }
        $csvContent = Get-Content -Path $tempFile -Raw -Encoding utf8 -ErrorAction Stop
    }
    finally {
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    }

    # ── Parse and validate CSV rows ─────────────────────────────────────────────
    $rows       = $csvContent | ConvertFrom-Csv -ErrorAction Stop
    $validRows  = [System.Collections.Generic.List[pscustomobject]]::new()
    $skippedRows = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($row in $rows) {
        $srcSub = [string]$row.SourceSubscription
        $srcRg  = [string]$row.SourceResourceGroup
        $srcVm  = [string]$row.SourceVmName

        if ([string]::IsNullOrWhiteSpace($srcSub) -or
            [string]::IsNullOrWhiteSpace($srcRg)  -or
            [string]::IsNullOrWhiteSpace($srcVm)) {
            $skippedRows.Add([pscustomobject]@{
                SourceVmName = $srcVm
                Reason       = "Missing required column(s) — SourceSubscription='$srcSub' SourceResourceGroup='$srcRg' SourceVmName='$srcVm'"
            })
            Write-FuncLog "Skipping invalid row: Sub='$srcSub' RG='$srcRg' VM='$srcVm'" 'WARN'
            continue
        }

        $validRows.Add([pscustomobject]@{
            SourceSubscription  = $srcSub.Trim()
            SourceResourceGroup = $srcRg.Trim()
            SourceVmName        = $srcVm.Trim()
        })
    }

    Write-FuncLog "CSV parsed: $($validRows.Count) valid row(s), $($skippedRows.Count) skipped."

    if ($validRows.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = '{"error":"No valid rows found. Ensure columns SourceSubscription, SourceResourceGroup, SourceVmName are present."}'
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # ── Resolve module path for parallel runspaces ──────────────────────────────
    # FUNCTIONS_APPLICATION_DIRECTORY is set by the Azure Functions host to the function app root.
    $appRoot        = if ($env:FUNCTIONS_APPLICATION_DIRECTORY) {
                          $env:FUNCTIONS_APPLICATION_DIRECTORY
                      } else {
                          Split-Path $PSScriptRoot -Parent   # local dev fallback
                      }
    $drCoreModule   = Join-Path $appRoot 'Modules' 'DRCore' 'DRCore.psm1'

    if (-not (Test-Path $drCoreModule)) {
        throw "DRCore module not found at '$drCoreModule'. Ensure Modules/DRCore/DRCore.psm1 is deployed."
    }

    Write-FuncLog "Starting parallel VM replication. ThrottleLimit=$vmParallelThrottle."
    $invocationId = [string]$TriggerMetadata.InvocationId

    # ── Return 202 Accepted immediately ─────────────────────────────────────────────
    Write-FuncLog "Returning 202 Accepted. Processing will continue asynchronously."
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Accepted
        Body       = ([ordered]@{
            message       = 'DR replication job accepted and started. Check per-VM logs in blob storage for results.'
            invocationId  = $invocationId
            vmCount       = $validRows.Count
            startedAt     = $startedAt
        } | ConvertTo-Json -Depth 3)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })

    # ── Start parallel VM processing (HTTP response already sent) ───────────────────
    Write-FuncLog "Starting parallel VM replication (HTTP connection already closed)."

    $validRows | ForEach-Object -ThrottleLimit $vmParallelThrottle -Parallel {
        $row              = $_
        $modulePath       = $using:drCoreModule
        $diskThrottle     = $using:diskThrottle
        $snapshotPrefix   = $using:snapshotNamePrefix
        $poolOverride     = $using:backendPoolNameOverride
        $logStorageAcct   = $using:storageAccountName
        $logContainer     = $using:logContainerName
        $invocationId     = $using:invocationId
        $subSuffix        = $using:targetSubscriptionSuffix
        $rgSuffix         = $using:targetResourceGroupSuffix
        $vnetNameSuffix   = $using:targetVnetNameSuffix
        $vnetRgSuffix     = $using:targetVnetRgSuffix
        $lbNameSuffix     = $using:targetLbNameSuffix
        $lbRgSuffix       = $using:targetLbRgSuffix
        $desNameSuffix    = $using:targetDesNameSuffix
        $desRgSuffix      = $using:targetDesRgSuffix
        $asgNameSuffix    = $using:targetAsgNameSuffix

        try {
            Write-Host "[PARALLEL] Processing VM: $($row.SourceVmName)"
            Import-Module $modulePath -Force -ErrorAction Stop

                # Re-authenticate in each runspace (parallel runspaces don't inherit the Az context)
                if ($env:MSI_SECRET -or $env:IDENTITY_ENDPOINT) {
                    Disable-AzContextAutosave -Scope Process | Out-Null
                    $connectArgs = @{ Identity = $true; AccountId = $env:SOURCE_IDENTITY_CLIENT_ID; SkipContextPopulation = $true }
                    Connect-AzAccount @connectArgs -ErrorAction Stop | Out-Null
                }

                $vmResult = Invoke-VMReplication `
                    -SourceSubscription           $row.SourceSubscription  `
                    -SourceResourceGroup          $row.SourceResourceGroup  `
                    -SourceVmName                 $row.SourceVmName         `
                    -DiskParallelThrottle         $diskThrottle             `
                    -SnapshotNamePrefix           $snapshotPrefix           `
                    -BackendPoolNameOverride      $poolOverride             `
                    -TargetSubscriptionSuffix     $subSuffix                `
                    -TargetResourceGroupSuffix    $rgSuffix                 `
                    -TargetVnetNameSuffix         $vnetNameSuffix           `
                    -TargetVnetRgSuffix           $vnetRgSuffix             `
                    -TargetLbNameSuffix           $lbNameSuffix             `
                    -TargetLbRgSuffix             $lbRgSuffix               `
                    -TargetDesNameSuffix          $desNameSuffix            `
                    -TargetDesRgSuffix            $desRgSuffix              `
                    -TargetAsgNameSuffix          $asgNameSuffix            `
                    -LogStorageAccountName        $logStorageAcct           `
                    -LogContainerName             $logContainer             `
                    -InvocationId                 $invocationId

                $vmResult
            }
            catch {
                $errorMsg = "Unhandled exception in parallel block: $($_.Exception.Message)"
                Write-Host "[PARALLEL ERROR] $($row.SourceVmName): $errorMsg"
                [pscustomobject]@{
                    SourceVmName = $row.SourceVmName
                    TargetVmName = $null
                    Status       = 'Failed'
                    Error        = $errorMsg
                    Summary      = $null
                    LogEntries   = $null
                }
            }
        }

    Write-FuncLog "Parallel VM replication completed."
}
catch {
    Write-FuncLog "Fatal error: $($_.Exception.Message)" 'ERROR'
    Write-FuncLog $_.ScriptStackTrace 'ERROR'
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = ([ordered]@{
            error        = 'Internal error while starting DR replication.'
            invocationId = [string]$TriggerMetadata.InvocationId
        } | ConvertTo-Json -Depth 3)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}

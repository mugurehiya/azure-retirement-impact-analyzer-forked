# Sync-QueriesTxt.ps1 — Azure Automation Runbook
#
# Runs on a biweekly schedule. Queries Kusto for the latest ARG queries,
# validates each query against Azure Resource Graph, compares with the
# previous version, and uploads to blob storage on success.
# Notifications are handled by Azure Monitor alert rules on the job status:
#   - Job Completed → informational alert (queries.txt updated in storage)
#   - Job Failed    → urgent alert / ICM (validation failures)
#
# Prerequisites:
#   1. Azure Automation account with system-assigned managed identity
#   2. Managed identity granted:
#      - "Reader" role on the subscription (for ARG queries)
#      - "Database Viewer" on the Kusto database (ServiceRetirements)
#      - "Storage Blob Data Contributor" on the storage account
#   3. Azure Automation modules installed:
#      - Az.Accounts
#      - Az.Storage
#   4. Automation variables (set in Automation Account → Variables):
#      - StorageAccountName    — e.g. "fnstgsrworkbookdev"
#      - StorageContainerName  — e.g. "queries"
#      - KustoCluster          — e.g. "https://azsrcludev.eastus.kusto.windows.net"
#      - KustoDatabase         — e.g. "ServiceRetirements"
#   5. Azure Monitor alert rules on the Automation Account job status
#      linked to an Action Group for email/ICM notifications

#region ── Configuration ──────────────────────────────────────────────────────

$KustoCluster       = Get-AutomationVariable -Name 'KustoCluster'
$KustoDatabase      = Get-AutomationVariable -Name 'KustoDatabase'
$StorageAccountName = Get-AutomationVariable -Name 'StorageAccountName'
$ContainerName      = Get-AutomationVariable -Name 'StorageContainerName'
$BlobName           = "queries.txt"

#endregion

#region ── 1. Authenticate with Managed Identity ──────────────────────────────

Write-Output "Logging in with managed identity..."
Connect-AzAccount -Identity | Out-Null
$context = Get-AzContext
Write-Output "Logged in as: $($context.Account.Id) | Subscription: $($context.Subscription.Name)"

#endregion

#region ── 2. Query Kusto for latest queries ──────────────────────────────────

Write-Output "Querying Kusto cluster: $KustoCluster / $KustoDatabase"

$kustoToken = (Get-AzAccessToken -ResourceUrl $KustoCluster).Token

$kustoBody = @{
    db  = $KustoDatabase
    csl = "ARGQueries | project dataSourceQuery"
} | ConvertTo-Json

$kustoResponse = Invoke-RestMethod `
    -Uri "$KustoCluster/v1/rest/query" `
    -Method Post `
    -Headers @{ Authorization = "Bearer $kustoToken"; "Content-Type" = "application/json" } `
    -Body $kustoBody

$newQueries = $kustoResponse.Tables[0].Rows | ForEach-Object { $_[0] }

if (-not $newQueries -or $newQueries.Count -eq 0) {
    Write-Error "Kusto query returned 0 rows — aborting."
    throw "Empty Kusto response"
}

Write-Output "Retrieved $($newQueries.Count) queries from Kusto."
$newQueriesText = $newQueries -join "`n"

#endregion

#region ── 3. Validate each query against Azure Resource Graph ────────────────

Write-Output "Validating $($newQueries.Count) queries against ARG..."

$argToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
$subscriptionId = $context.Subscription.Id

$failedQueries = @()
$queryNumber = 0

foreach ($query in $newQueries) {
    if ([string]::IsNullOrWhiteSpace($query)) { continue }
    $query = $query.Trim()
    $queryNumber++

    $retiringFeature = "Unknown"
    if ($query -match 'RetiringFeature\s*=\s*"([^"]+)"') {
        $retiringFeature = $Matches[1]
    }

    Write-Output "[$queryNumber] Validating: $retiringFeature"

    $maxRetries = 3
    $success = $false

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $argBody = @{
                subscriptions = @($subscriptionId)
                query         = $query
                options       = @{ "`$top" = 1 }
            } | ConvertTo-Json -Depth 3

            $argResult = Invoke-RestMethod `
                -Uri "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01" `
                -Method Post `
                -Headers @{ Authorization = "Bearer $argToken" } `
                -ContentType "application/json" `
                -Body $argBody `
                -ErrorAction Stop

            Write-Output "  OK (rows: $($argResult.totalRecords))"
            $success = $true
            break
        }
        catch {
            if ($_.Exception.Message -match '429' -and $attempt -lt $maxRetries) {
                Write-Output "  Throttled — retrying in $($attempt * 5)s..."
                Start-Sleep -Seconds ($attempt * 5)
            }
            else {
                Write-Output "  FAILED: $($_.Exception.Message)"
                $failedQueries += @{
                    Number          = $queryNumber
                    RetiringFeature = $retiringFeature
                    Error           = $_.Exception.Message
                }
            }
        }
    }

    # Throttle: 1-second delay between queries to avoid 429s
    Start-Sleep -Seconds 1
}

Write-Output ""
if ($failedQueries.Count -gt 0) {
    Write-Output "VALIDATION FAILED: $($failedQueries.Count) of $queryNumber queries failed."
    Write-Output ""
    foreach ($fq in $failedQueries) {
        Write-Output "  [$($fq.Number)] $($fq.RetiringFeature): $($fq.Error)"
    }
    throw "Validation failed for $($failedQueries.Count) of $queryNumber queries. Check job output for details."
}

Write-Output "All $queryNumber queries validated successfully."

#endregion

#region ── 4. Upload new queries.txt to Blob Storage (only after validation passes) ──

$storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount

$tempNewFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $tempNewFile -Value $newQueriesText -NoNewline

Set-AzStorageBlobContent `
    -Container $ContainerName `
    -Blob $BlobName `
    -File $tempNewFile `
    -Context $storageContext `
    -Force | Out-Null

Remove-Item $tempNewFile -ErrorAction SilentlyContinue
Write-Output "Uploaded new queries.txt to blob storage."
Write-Output "Done. $queryNumber queries updated. Download from: $StorageAccountName/$ContainerName/$BlobName"

#endregion

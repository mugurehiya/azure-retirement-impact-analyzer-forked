# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Validates every query in queries.txt by executing it against Azure Resource Graph.
# Exits 0 if ALL queries execute without error; exits 1 if ANY query fails.
# Designed for CI use — errors are NOT suppressed.

param(
    [string]$QueriesFile
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $QueriesFile) { $QueriesFile = Join-Path $ScriptDir "queries.txt" }

if (-not (Test-Path $QueriesFile)) {
    Write-Error "Queries file not found: $QueriesFile"
    exit 1
}

# Pre-install resource-graph extension
az extension add -n resource-graph --only-show-errors 2>$null
az config set extension.dynamic_install_allow_preview=true --only-show-errors 2>$null

$Queries = Get-Content $QueriesFile
$TempDir = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
$TempFile = Join-Path $TempDir "arg-query-validate.kql"
$QueryNumber = 0
$FailedQueries = @()

foreach ($Query in $Queries) {
    if ([string]::IsNullOrWhiteSpace($Query)) { continue }
    $Query = $Query.Trim()
    $QueryNumber++

    # Extract RetiringFeature for logging
    $RetiringFeature = "Unknown"
    if ($Query -match 'RetiringFeature\s*=\s*"([^"]+)"') {
        $RetiringFeature = $Matches[1]
    }

    Write-Host "[$QueryNumber] Validating: $RetiringFeature"

    [System.IO.File]::WriteAllText($TempFile, $Query)

    $ErrorOutput = $null
    $Result = az graph query -q "@$TempFile" -o json 2>&1
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -ne 0) {
        Write-Host "  FAILED (exit code $ExitCode)" -ForegroundColor Red
        Write-Host "  Error: $Result" -ForegroundColor Red
        $FailedQueries += @{
            Number          = $QueryNumber
            RetiringFeature = $RetiringFeature
            Error           = ($Result | Out-String).Trim()
            Query           = $Query
        }
    }
    else {
        Write-Host "  OK" -ForegroundColor Green
    }
}

Remove-Item $TempFile -ErrorAction SilentlyContinue

if ($FailedQueries.Count -gt 0) {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Red
    Write-Host "VALIDATION FAILED: $($FailedQueries.Count) of $QueryNumber queries failed" -ForegroundColor Red
    Write-Host "======================================" -ForegroundColor Red

    # Write failure summary for CI consumption
    $SummaryFile = Join-Path $ScriptDir "validation-failures.json"
    $FailedQueries | ConvertTo-Json -Depth 3 | Set-Content $SummaryFile
    Write-Host "Failure details written to: $SummaryFile"

    exit 1
}
else {
    Write-Host ""
    Write-Host "All $QueryNumber queries validated successfully." -ForegroundColor Green
    exit 0
}

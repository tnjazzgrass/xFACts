<#
.SYNOPSIS
    xFACts - Backup Network Copy Processing

.DESCRIPTION
    Copies completed backup files from local storage to the network share.
    Queries Backup_FileTracking for PENDING network copies and processes each
    file, resetting eligible FAILED files to PENDING for automatic retry and
    firing a Teams alert when retries are exhausted. Without -Execute the script
    runs in preview mode and makes no changes.

.PARAMETER ServerInstance
    SQL Server instance name for the xFACts database (default: AVG-PROD-LSNR).

.PARAMETER Database
    Database name (default: xFACts).

.PARAMETER MaxFiles
    Maximum number of files to process per run (default: 100).

.PARAMETER Execute
    Perform copies. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID for completion callback. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID for completion callback. Default 0.

.COMPONENT
    ServerOps.Backup

.NOTES
    File Name : Process-BackupNetworkCopy.ps1
    Location  : E:\xFACts-PowerShell\Process-BackupNetworkCopy.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this script. Most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-19  Spec conformance and shared-helper adoption
#             Removed local Convert-ToUncPath, Get-PhysicalServerFromPath,
#             Write-ExecutionLog, Update-FileTrackingStatus (now in
#             xFACts-BackupFunctions.ps1 as Convert-bkp_ToUncPath,
#             Get-bkp_PhysicalServerFromPath, Write-bkp_ExecutionLog,
#             Set-bkp_NetworkCopyStatus); re-pointed all call sites
#             Replaced the raw Invoke-Sqlcmd listener resolve with Get-SqlData
#             using SERVERPROPERTY('ServerName') for the server-name lookup
#             Replaced the inline Step 1B retry-handling block with a call to the
#             shared Invoke-bkp_RetryFailedFiles; the network-root verify moves to
#             its own Step 1C and stays inline
#             Added section banners and IMPORTS for the Backup helper
# 2026-03-16  Retry logic for failed network copies
#             New Step 1B resets eligible FAILED files to PENDING for automatic retry
#             Max retries configurable via GlobalConfig (network_copy_max_retries)
#             Exhausted retries fire Teams alert via shared Send-TeamsAlert function
# 2026-03-10  Migrated to Initialize-XFActsScript shared infrastructure
#             Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
#             Updated header to component-level versioning format
# 2026-02-03  Orchestrator v2 integration
#             Added -Execute, TaskId/ProcessId, orchestrator callbacks
#             Added file logging, SQLPS/SqlServer compatibility
# 2026-01-23  Master switch and registry alignment
#             Server-level master switch, Backup_DatabaseConfig filtering
# 2026-01-22  Table references updated (Backup_Status, GlobalConfig)
# 2026-01-09  ExecutionLog cleanup
# 2026-01-07  ExecutionSummary support
# 2026-01-06  AG Listener support, batch claim
# 2026-01-05  Initial implementation

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Script-level parameters: the xFACts connection target, the per-run file cap,
   the preview/execute guard, and the orchestrator callback identifiers.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [int]$MaxFiles = 100,
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Shared platform helpers. The orchestrator library is dot-sourced first so its
   Write-Log, Get-SqlData, Invoke-SqlNonQuery, and Send-TeamsAlert resolve; the
   Backup helper library is dot-sourced second and depends on them.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
. "$PSScriptRoot\xFACts-BackupFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   Standardized script startup: SQL module loading, application identity, log
   path, default connection target, and the preview-mode execute guard.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Process-BackupNetworkCopy' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Checks the server-level master switch, loads configuration, retries eligible
   failed copies and alerts on exhausted ones, claims a batch of pending files,
   copies each to the network share, writes per-file execution-log detail, and
   reports the orchestrator callback.
   Prefix: (none)
   ============================================================================ #>

$scriptStart = Get-Date
$processName = "NETWORK_COPY"

Write-Log "========================================"
Write-Log "xFACts Backup Network Copy"
Write-Log "========================================"

if (-not $Execute) {
    Write-Log "*** PREVIEW MODE - No changes will be made. Use -Execute to run. ***" "WARN"
}

# -- Step 0: Master switch check --

Write-Log "Checking server-level Backup enable flag..."

$serverCheck = Get-SqlData -Query @"
SELECT COUNT(*) AS enabled_count
FROM dbo.ServerRegistry
WHERE is_active = 1
  AND serverops_backup_enabled = 1
"@

if (-not $serverCheck -or $serverCheck.enabled_count -eq 0) {
    Write-Log "Backup processing is not enabled on any server (serverops_backup_enabled = 0). Exiting." "WARN"
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs 0 -Output "Backup processing not enabled on any server"
    }
    exit 0
}

Write-Log "  Found $($serverCheck.enabled_count) server(s) with Backup enabled."

# -- Step 1: Configuration --

Write-Log "Loading configuration..."

$configResult = Get-SqlData -Query @"
SELECT setting_name, setting_value
FROM dbo.GlobalConfig
WHERE module_name = 'ServerOps' AND category = 'Backup'
  AND setting_name IN ('network_backup_root', 'network_copy_max_retries')
  AND is_active = 1
"@

if ($null -eq $configResult) {
    Write-Log "Failed to load configuration. Exiting." "ERROR"
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs 0 -Output "Failed to load configuration"
    }
    exit 1
}

$networkBackupRoot = ($configResult | Where-Object { $_.setting_name -eq 'network_backup_root' }).setting_value
# Default: 2 retries (3 total attempts)
$maxRetries = 2
$maxRetriesRow = $configResult | Where-Object { $_.setting_name -eq 'network_copy_max_retries' }
if ($maxRetriesRow) { $maxRetries = [int]$maxRetriesRow.setting_value }

if (-not $networkBackupRoot) {
    Write-Log "network_backup_root not found in GlobalConfig. Exiting." "ERROR"
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs 0 -Output "network_backup_root not configured"
    }
    exit 1
}

Write-Log "Network backup root: $networkBackupRoot"
Write-Log "Max retries: $maxRetries (total attempts: $($maxRetries + 1))"

# -- Step 1B: Retry failed files --

Invoke-bkp_RetryFailedFiles -Operation 'NETWORK_COPY' -MaxRetries $maxRetries -Execute:$Execute

# -- Step 1C: Verify network root --

# Verify network path is accessible
if ($Execute) {
    if (-not (Test-Path $networkBackupRoot -ErrorAction SilentlyContinue)) {
        # Try to create the root folder
        try {
            New-Item -ItemType Directory -Path $networkBackupRoot -Force | Out-Null
            Write-Log "Created network backup root folder"
        }
        catch {
            Write-Log "Cannot access or create network backup root: $networkBackupRoot" "ERROR"
            if ($TaskId -gt 0) {
                Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                    -TaskId $TaskId -ProcessId $ProcessId `
                    -Status "FAILED" -DurationMs 0 -Output "Cannot access network backup root: $networkBackupRoot"
            }
            exit 1
        }
    }
}

# -- Step 2: Pending files --

Write-Log "Querying pending network copies..."

$pendingFiles = Get-SqlData -Query @"
SELECT TOP ($MaxFiles)
    ft.tracking_id,
    ft.server_id,
    ft.server_name,
    ft.database_name,
    ft.backup_type,
    ft.file_name,
    ft.file_size_bytes,
    ft.local_path
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.DatabaseRegistry dr ON ft.server_id = dr.server_id AND ft.database_name = dr.database_name
JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
JOIN ServerOps.Backup_DatabaseConfig dc ON dr.database_id = dc.database_id
WHERE ft.network_copy_status = 'PENDING'
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
  AND dr.is_active = 1
  AND dc.backup_network_copy_enabled = 1
ORDER BY ft.backup_finish_dttm
"@

if ($null -eq $pendingFiles -or @($pendingFiles).Count -eq 0) {
    Write-Log "No pending network copies found."
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs 0 -Output "No pending network copies"
    }
    exit 0
}

$fileCount = @($pendingFiles).Count
Write-Log "Found $fileCount file(s) to process."

# -- Step 2B: Claim batch --

# This prevents race conditions if another execution starts while we're processing
$trackingIds = @($pendingFiles | ForEach-Object { $_.tracking_id })
$trackingIdList = $trackingIds -join ','

Write-Log "Claiming batch of $fileCount files (tracking_ids: $trackingIdList)..."

if ($Execute) {
    $claimQuery = @"
UPDATE ServerOps.Backup_FileTracking
SET network_copy_status = 'IN_PROGRESS'
WHERE tracking_id IN ($trackingIdList)
  AND network_copy_status = 'PENDING'
"@

    $claimedCount = Invoke-SqlNonQuery -Query $claimQuery
    Write-Log "Claimed $claimedCount file(s) for processing."

    if ($claimedCount -eq 0) {
        Write-Log "No files claimed - another process may have already claimed them." "WARN"
        if ($TaskId -gt 0) {
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs 0 -Output "No files claimed - already claimed by another process"
        }
        exit 0
    }

    if ($claimedCount -lt $fileCount) {
        Write-Log "Only claimed $claimedCount of $fileCount files - some may have been claimed by another process." "WARN"
    }
} else {
    Write-Log "[Preview] Would claim $fileCount files as IN_PROGRESS"
}

# -- Step 3: Process each file --

$successCount = 0
$failCount = 0
$totalBytesCopied = 0

foreach ($file in $pendingFiles) {
    $trackingId = $file.tracking_id
    $serverId = $file.server_id
    $serverName = $file.server_name
    $dbName = $file.database_name
    $backupType = $file.backup_type
    $fileName = $file.file_name
    $fileSize = if ($file.file_size_bytes -isnot [DBNull]) { $file.file_size_bytes } else { $null }
    $localPath = $file.local_path

    Write-Log "----------------------------------------"
    Write-Log "Processing: $serverName / $dbName / $fileName"

    $fileStart = Get-Date

    # Determine physical server for source UNC path
    # For AG databases (server_id = 0), parse from filename since admin shares don't work with listener
    if ($serverId -eq 0) {
        $physicalServer = Get-bkp_PhysicalServerFromPath -LocalPath $localPath

        if ($null -eq $physicalServer) {
            # Fallback: Query listener to resolve current primary
            Write-Log "  Could not parse server from filename, resolving via listener..." "WARN"
            $physicalServer = (Get-SqlData -Query "SELECT SERVERPROPERTY('ServerName') AS name" -Instance "AVG-PROD-LSNR").name
        }

        Write-Log "  AG database - physical server: $physicalServer"
        $sourcePath = Convert-bkp_ToUncPath -LocalPath $localPath -ServerName $physicalServer
    } else {
        # Non-AG database - server_name is already the physical server
        $sourcePath = Convert-bkp_ToUncPath -LocalPath $localPath -ServerName $serverName
    }

    # Build destination path: {root}\{server}\{database}\{type}\
    # Uses $serverName (listener for AG, physical for non-AG) for unified folder structure
    $destFolder = Join-Path $networkBackupRoot $serverName
    $destFolder = Join-Path $destFolder $dbName
    $destFolder = Join-Path $destFolder $backupType
    $destPath = Join-Path $destFolder $fileName

    Write-Log "  Source: $sourcePath"
    Write-Log "  Destination: $destPath"

    if (-not $Execute) {
        Write-Log "  [Preview] Would copy file ($([math]::Round($fileSize/1MB, 2)) MB)" "INFO"
        $successCount++
        continue
    }

    # File already marked IN_PROGRESS during batch claim (Step 2B)
    # Now set the actual start timestamp for accurate per-file timing
    $startTimestampQuery = @"
UPDATE ServerOps.Backup_FileTracking
SET network_copy_started_dttm = GETDATE()
WHERE tracking_id = $trackingId
"@
    Invoke-SqlNonQuery -Query $startTimestampQuery | Out-Null

    try {
        # Verify source file exists
        if (-not (Test-Path $sourcePath)) {
            throw "Source file not found: $sourcePath"
        }

        # Create destination folder if needed
        if (-not (Test-Path $destFolder)) {
            New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
            Write-Log "  Created folder: $destFolder"
        }

        # Copy the file
        Copy-Item -Path $sourcePath -Destination $destPath -Force

        $fileFinish = Get-Date
        $durationMs = [int]($fileFinish - $fileStart).TotalMilliseconds
        $durationSec = [math]::Round($durationMs / 1000, 1)

        # Verify copy succeeded
        if (Test-Path $destPath) {
            $destFileInfo = Get-Item $destPath
            $destSize = $destFileInfo.Length

            # Update status to COMPLETED
            Set-bkp_NetworkCopyStatus -TrackingId $trackingId -Status 'COMPLETED' `
                -NetworkPath $destPath -FinishDttm $fileFinish | Out-Null

            # Calculate throughput
            $sizeMB = [math]::Round($destSize / 1MB, 2)
            $mbPerSec = if ($durationSec -gt 0) { [math]::Round($sizeMB / $durationSec, 2) } else { 0 }

            Write-Log "  SUCCESS: Copied $sizeMB MB in $durationSec sec ($mbPerSec MB/s)"

            Write-bkp_ExecutionLog -Component 'NETWORK_COPY' -ServerName $serverName `
                -DatabaseName $dbName -FileName $fileName -TrackingId $trackingId `
                -Operation "Copy to network" -Status 'SUCCESS' `
                -DurationMs $durationMs -BytesProcessed $destSize `
                -StartedDttm $fileStart -CompletedDttm $fileFinish

            $successCount++
            $totalBytesCopied += $destSize
        }
        else {
            throw "Destination file not found after copy"
        }
    }
    catch {
        $fileFinish = Get-Date
        $durationMs = [int]($fileFinish - $fileStart).TotalMilliseconds
        $errorMsg = $_.Exception.Message

        Write-Log "  FAILED: $errorMsg" "ERROR"

        # Update status to FAILED
        Set-bkp_NetworkCopyStatus -TrackingId $trackingId -Status 'FAILED' -FinishDttm $fileFinish | Out-Null

        Write-bkp_ExecutionLog -Component 'NETWORK_COPY' -ServerName $serverName `
            -DatabaseName $dbName -FileName $fileName -TrackingId $trackingId `
            -Operation "Copy to network" -Status 'FAILED' `
            -DurationMs $durationMs -ErrorMessage $errorMsg `
            -StartedDttm $fileStart -CompletedDttm $fileFinish

        $failCount++
    }
}

# -- Step 4: Summary --

$scriptDuration = [int]((Get-Date) - $scriptStart).TotalMilliseconds
$finalStatus = if ($failCount -eq 0) { 'SUCCESS' } else { 'PARTIAL' }
$errorSummary = if ($failCount -gt 0) { "$failCount file(s) failed" } else { $null }

Write-Log "========================================"
Write-Log "  Network Copy Complete$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
Write-Log "  Files processed: $fileCount"
Write-Log "  Successful: $successCount"
Write-Log "  Failed: $failCount"
Write-Log "  Total copied: $([math]::Round($totalBytesCopied / 1GB, 2)) GB"
Write-Log "  Total duration: $($scriptDuration)ms"
Write-Log "========================================"

# Orchestrator callback
if ($TaskId -gt 0) {
    $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
    $callbackStatus = if ($failCount -eq 0) { 'SUCCESS' } else { 'FAILED' }
    $callbackOutput = "Copied $successCount of $fileCount files ($([math]::Round($totalBytesCopied / 1GB, 2)) GB). Duration: ${totalMs}ms"
    if ($failCount -gt 0) {
        $callbackOutput += " | $failCount file(s) failed"
    }
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $callbackStatus -DurationMs $totalMs -Output $callbackOutput
}

if ($failCount -gt 0) { exit 1 } else { exit 0 }
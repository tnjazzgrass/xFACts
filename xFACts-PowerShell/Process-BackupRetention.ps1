<#
.SYNOPSIS
    xFACts - Backup Retention Processing

.DESCRIPTION
    Deletes backup files past retention based on chain-based policies. Retention
    is driven by FULL backup counts per database: it keeps N full backup chains
    and deletes all files (FULL, DIFF, LOG) older than the Nth oldest FULL, for
    both local and network copies. Local deletes require the file to already be
    on the network. Scheduled by Orchestrator v2 as a once-daily FIRE_AND_FORGET
    process. Without -Execute the script runs in preview mode and makes no changes.

.PARAMETER ServerInstance
    SQL Server instance name for the xFACts database (default: AVG-PROD-LSNR).

.PARAMETER Database
    Database name (default: xFACts).

.PARAMETER Execute
    Perform deletes. Without this flag, runs in preview/dry-run mode.

.PARAMETER Force
    Force execution regardless of prior run status.

.PARAMETER TaskId
    Orchestrator TaskLog ID for completion callback. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID for completion callback. Default 0.

.COMPONENT
    ServerOps.Backup

.NOTES
    File Name : Process-BackupRetention.ps1
    Location  : E:\xFACts-PowerShell\Process-BackupRetention.ps1

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
#             Write-ExecutionLog (now in xFACts-BackupFunctions.ps1 as
#             Convert-bkp_ToUncPath, Get-bkp_PhysicalServerFromPath,
#             Write-bkp_ExecutionLog); re-pointed all call sites
#             Failure-path execution-log rows now write bytes_processed as NULL
#             rather than 0, matching the other Backup pipeline scripts
#             Replaced the file-scope ErrorActionPreference = Stop with explicit
#             -ErrorAction Stop on the delete-loop Test-Path and Remove-Item
#             calls (the only operations whose terminating behavior it governed;
#             the SQL wrappers self-handle errors and were never affected)
#             Added section banners and IMPORTS for the Backup helper
# 2026-03-10  Migrated to Initialize-XFActsScript shared infrastructure
#             Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
#             Updated header to component-level versioning format
# 2026-02-04  Orchestrator v2 migration
#             Added -Execute, -TaskId, -ProcessId, orchestrator callback
#             Removed internal daily scheduling check
# 2026-01-23  Master switch and registry alignment
#             Server-level master switch, ServerRegistry joins
# 2026-01-22  Table references updated (Backup_Status, GlobalConfig)
# 2026-01-19  Chain-based retention
#             Replaced date-based tier retention with chain-based per-database
#             Removed dependency on Backup_TierRetention table
# 2026-01-08  AG Listener support, initial implementation refinements
# 2026-01-07  Initial implementation
#             Local and network retention based on tier policies

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Script-level parameters: the xFACts connection target, the preview/execute
   guard, the force flag, and the orchestrator callback identifiers.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$Execute,
    [switch]$Force,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Shared platform helpers. The orchestrator library is dot-sourced first so its
   Write-Log, Get-SqlData, and Invoke-SqlNonQuery resolve; the Backup helper
   library is dot-sourced second and depends on them.
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

Initialize-XFActsScript -ScriptName 'Process-BackupRetention' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Checks the server-level master switch, queries chain-based local and network
   delete candidates, deletes each file from its admin-share or network path,
   marks the tracking row, writes per-file execution-log detail, and reports the
   orchestrator callback.
   Prefix: (none)
   ============================================================================ #>

# Process name used for execution-log component tagging.
$processName = "RETENTION"
# Capture start time for duration reporting.
$scriptStart = Get-Date
# Running totals for the local-delete pass.
$localFilesDeleted = 0
$localBytesDeleted = 0
# Running totals for the network-delete pass.
$networkFilesDeleted = 0
$networkBytesDeleted = 0
# Accumulated per-file error messages.
$errors = @()

Write-Log "========================================"
Write-Log "xFACts Backup Retention"
Write-Log "========================================"

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
    if ($TaskId -and $TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs ([int]((Get-Date) - $scriptStart).TotalMilliseconds) `
            -Output "Skipped - backup not enabled on any server"
    }
    exit 0
}

Write-Log "  Found $($serverCheck.enabled_count) server(s) with Backup enabled."

# Daily scheduling is handled by Orchestrator v2 - no internal run check needed

# -- Step 1: Retention candidates --

Write-Log "Querying for retention candidates (chain-based)..."

# Local delete candidates: files older than the Nth oldest FULL per database
# Safety check: only delete local files that have been copied to network
$localCandidatesQuery = @"
;WITH LocalFullRanked AS (
    -- Rank FULL backups per database (only those still on local disk)
    SELECT
        server_name,
        database_name,
        backup_finish_dttm,
        ROW_NUMBER() OVER (
            PARTITION BY server_name, database_name
            ORDER BY backup_finish_dttm DESC
        ) AS rn
    FROM ServerOps.Backup_FileTracking
    WHERE backup_type = 'FULL'
      AND local_deleted_dttm IS NULL
      AND local_path IS NOT NULL
), LocalCutoffs AS (
    -- Find cutoff timestamp per database (the Nth newest FULL)
    -- Only for databases on servers with backup enabled
    SELECT
        dc.server_name,
        dc.database_name,
        dc.full_retention_chain_local_count,
        lfr.backup_finish_dttm AS cutoff_dttm
    FROM ServerOps.Backup_DatabaseConfig dc
    JOIN dbo.ServerRegistry sr ON dc.server_name = sr.server_name
    LEFT JOIN LocalFullRanked lfr
         ON dc.server_name = lfr.server_name
         AND dc.database_name = lfr.database_name
        AND lfr.rn = dc.full_retention_chain_local_count
    WHERE dc.full_retention_chain_local_count > 0
      AND sr.is_active = 1
      AND sr.serverops_backup_enabled = 1
)
SELECT
    ft.tracking_id,
    ft.server_id,
    ft.server_name,
    ft.database_name,
    ft.backup_type,
    ft.file_name,
    COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes,
    ft.local_path,
    ft.backup_finish_dttm,
    ft.network_copy_status,
    lc.cutoff_dttm
FROM ServerOps.Backup_FileTracking ft
JOIN LocalCutoffs lc
     ON ft.server_name = lc.server_name
     AND ft.database_name = lc.database_name
WHERE ft.network_copy_status IN ('COMPLETED', 'HISTORICAL')  -- Safety: must be on network first
  AND ft.local_deleted_dttm IS NULL
  AND ft.local_path IS NOT NULL
  AND lc.cutoff_dttm IS NOT NULL  -- Must have enough FULLs to establish cutoff
  AND ft.backup_finish_dttm < lc.cutoff_dttm  -- Older than the Nth FULL
ORDER BY ft.server_name, ft.database_name, ft.backup_finish_dttm
"@

$localCandidates = @(Get-SqlData -Query $localCandidatesQuery)
Write-Log "Found $($localCandidates.Count) local delete candidate(s)"

# Network delete candidates: files older than the Nth oldest FULL per database
$networkCandidatesQuery = @"
;WITH NetworkFullRanked AS (
    -- Rank FULL backups per database (only those still on network)
    SELECT
        server_name,
        database_name,
        backup_finish_dttm,
        ROW_NUMBER() OVER (
            PARTITION BY server_name, database_name
            ORDER BY backup_finish_dttm DESC
        ) AS rn
    FROM ServerOps.Backup_FileTracking
    WHERE backup_type = 'FULL'
      AND network_deleted_dttm IS NULL
      AND network_path IS NOT NULL
), NetworkCutoffs AS (
    -- Find cutoff timestamp per database (the Nth newest FULL)
    -- Only for databases on servers with backup enabled
    SELECT
        dc.server_name,
        dc.database_name,
        dc.full_retention_chain_network_count,
        nfr.backup_finish_dttm AS cutoff_dttm
    FROM ServerOps.Backup_DatabaseConfig dc
    JOIN dbo.ServerRegistry sr ON dc.server_name = sr.server_name
    LEFT JOIN NetworkFullRanked nfr
         ON dc.server_name = nfr.server_name
         AND dc.database_name = nfr.database_name
        AND nfr.rn = dc.full_retention_chain_network_count
    WHERE dc.full_retention_chain_network_count > 0
      AND sr.is_active = 1
      AND sr.serverops_backup_enabled = 1
)
SELECT
    ft.tracking_id,
    ft.server_id,
    ft.server_name,
    ft.database_name,
    ft.backup_type,
    ft.file_name,
    COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes,
    ft.network_path,
    ft.backup_finish_dttm,
    ft.network_copy_status,
    nc.cutoff_dttm
FROM ServerOps.Backup_FileTracking ft
JOIN NetworkCutoffs nc
     ON ft.server_name = nc.server_name
     AND ft.database_name = nc.database_name
WHERE ft.network_deleted_dttm IS NULL
  AND ft.network_path IS NOT NULL
  AND nc.cutoff_dttm IS NOT NULL  -- Must have enough FULLs to establish cutoff
  AND ft.backup_finish_dttm < nc.cutoff_dttm  -- Older than the Nth FULL
ORDER BY ft.server_name, ft.database_name, ft.backup_finish_dttm
"@

$networkCandidates = @(Get-SqlData -Query $networkCandidatesQuery)
Write-Log "Found $($networkCandidates.Count) network delete candidate(s)"

# -- Step 2: Process local deletes --

if ($localCandidates.Count -gt 0) {
    Write-Log "----------------------------------------"
    Write-Log "Processing local deletes..."

    foreach ($file in $localCandidates) {
        $deleteStart = Get-Date
        $trackingId = $file.tracking_id
        $serverId = $file.server_id
        $serverName = $file.server_name
        $databaseName = $file.database_name
        $fileName = $file.file_name
        $localPath = $file.local_path
        $fileSize = $file.file_size_bytes
        $copyStatus = $file.network_copy_status

        # Build UNC path - handle AG databases
        if ($serverId -eq 0 -or $serverName -eq 'AVG-PROD-LSNR') {
            $physicalServer = Get-bkp_PhysicalServerFromPath -LocalPath $localPath
            if ($null -eq $physicalServer) {
                # Fallback for old (local) pattern - use server_id to determine physical server
                if ($localPath -match '\(local\)') {
                    $physicalServer = if ($serverId -eq 1) { 'DM-PROD-DB' } else { 'DM-PROD-REP' }
                }
                else {
                    Write-Log "  [$fileName] Failed to parse physical server from path" -Level "ERROR"
                    $errors += "Local: $fileName - Failed to parse physical server"
                    continue
                }
            }
            $uncPath = Convert-bkp_ToUncPath -LocalPath $localPath -ServerName $physicalServer
        }
        else {
            $uncPath = Convert-bkp_ToUncPath -LocalPath $localPath -ServerName $serverName
        }

        if ($null -eq $uncPath) {
            Write-Log "  [$fileName] Failed to convert to UNC path" -Level "ERROR"
            $errors += "Local: $fileName - Failed to convert path"
            continue
        }

        if (-not $Execute) {
            Write-Log "  [Preview] [$fileName] Would delete from local ($([math]::Round($fileSize/1MB, 1)) MB)"
            $localFilesDeleted++
            $localBytesDeleted += $fileSize
        }
        else {
            try {
                if (Test-Path $uncPath -ErrorAction Stop) {
                    Remove-Item -Path $uncPath -Force -ErrorAction Stop
                    $deleteFinish = Get-Date
                    $durationMs = [int]($deleteFinish - $deleteStart).TotalMilliseconds

                    # Update FileTracking
                    $updateQuery = "UPDATE ServerOps.Backup_FileTracking SET local_deleted_dttm = GETDATE() WHERE tracking_id = $trackingId"
                    Invoke-SqlNonQuery -Query $updateQuery | Out-Null

                    # Log success (skip logging for HISTORICAL to prevent flooding)
                    if ($copyStatus -ne 'HISTORICAL') {
                        Write-bkp_ExecutionLog -Component $processName -Operation 'LOCAL_DELETE' -Status 'SUCCESS' `
                            -ServerName $serverName -DatabaseName $databaseName -FileName $fileName `
                            -TrackingId $trackingId -BytesProcessed $fileSize -DurationMs $durationMs `
                            -StartedDttm $deleteStart -CompletedDttm $deleteFinish
                    }

                    Write-Log "  [$fileName] Deleted from local ($([math]::Round($fileSize/1MB, 1)) MB)"
                    $localFilesDeleted++
                    $localBytesDeleted += $fileSize
                }
                else {
                    # File already gone - update tracking anyway
                    $deleteFinish = Get-Date
                    $updateQuery = "UPDATE ServerOps.Backup_FileTracking SET local_deleted_dttm = GETDATE(), notes = 'Retention marked complete - file already deleted externally' WHERE tracking_id = $trackingId"
                    Invoke-SqlNonQuery -Query $updateQuery | Out-Null
                    Write-Log "  [$fileName] Already deleted from local (marking complete)"
                    $localFilesDeleted++
                }
            }
            catch {
                $deleteFinish = Get-Date
                $durationMs = [int]($deleteFinish - $deleteStart).TotalMilliseconds
                $errorMsg = $_.Exception.Message
                Write-Log "  [$fileName] Delete failed: $errorMsg" -Level "ERROR"

                # Always log failures
                Write-bkp_ExecutionLog -Component $processName -Operation 'LOCAL_DELETE' -Status 'FAILED' `
                    -ServerName $serverName -DatabaseName $databaseName -FileName $fileName `
                    -TrackingId $trackingId -DurationMs $durationMs -ErrorMessage $errorMsg `
                    -StartedDttm $deleteStart -CompletedDttm $deleteFinish

                $errors += "Local: $fileName - $errorMsg"
            }
        }
    }
}

# -- Step 3: Process network deletes --

if ($networkCandidates.Count -gt 0) {
    Write-Log "----------------------------------------"
    Write-Log "Processing network deletes..."

    foreach ($file in $networkCandidates) {
        $deleteStart = Get-Date
        $trackingId = $file.tracking_id
        $serverName = $file.server_name
        $databaseName = $file.database_name
        $fileName = $file.file_name
        $networkPath = $file.network_path
        $fileSize = $file.file_size_bytes
        $copyStatus = $file.network_copy_status

        if (-not $Execute) {
            Write-Log "  [Preview] [$fileName] Would delete from network ($([math]::Round($fileSize/1MB, 1)) MB)"
            $networkFilesDeleted++
            $networkBytesDeleted += $fileSize
        }
        else {
            try {
                if (Test-Path $networkPath -ErrorAction Stop) {
                    Remove-Item -Path $networkPath -Force -ErrorAction Stop
                    $deleteFinish = Get-Date
                    $durationMs = [int]($deleteFinish - $deleteStart).TotalMilliseconds

                    # Update FileTracking
                    $updateQuery = "UPDATE ServerOps.Backup_FileTracking SET network_deleted_dttm = GETDATE() WHERE tracking_id = $trackingId"
                    Invoke-SqlNonQuery -Query $updateQuery | Out-Null

                    # Log success (skip logging for HISTORICAL to prevent flooding)
                    if ($copyStatus -ne 'HISTORICAL') {
                        Write-bkp_ExecutionLog -Component $processName -Operation 'NETWORK_DELETE' -Status 'SUCCESS' `
                            -ServerName $serverName -DatabaseName $databaseName -FileName $fileName `
                            -TrackingId $trackingId -BytesProcessed $fileSize -DurationMs $durationMs `
                            -StartedDttm $deleteStart -CompletedDttm $deleteFinish
                    }

                    Write-Log "  [$fileName] Deleted from network ($([math]::Round($fileSize/1MB, 1)) MB)"
                    $networkFilesDeleted++
                    $networkBytesDeleted += $fileSize
                }
                else {
                    # File already gone - update tracking anyway
                    $deleteFinish = Get-Date
                    $updateQuery = "UPDATE ServerOps.Backup_FileTracking SET network_deleted_dttm = GETDATE(), notes = 'Retention marked complete - file already deleted externally' WHERE tracking_id = $trackingId"
                    Invoke-SqlNonQuery -Query $updateQuery | Out-Null
                    Write-Log "  [$fileName] Already deleted from network (marking complete)"
                    $networkFilesDeleted++
                }
            }
            catch {
                $deleteFinish = Get-Date
                $durationMs = [int]($deleteFinish - $deleteStart).TotalMilliseconds
                $errorMsg = $_.Exception.Message
                Write-Log "  [$fileName] Delete failed: $errorMsg" -Level "ERROR"

                # Always log failures
                Write-bkp_ExecutionLog -Component $processName -Operation 'NETWORK_DELETE' -Status 'FAILED' `
                    -ServerName $serverName -DatabaseName $databaseName -FileName $fileName `
                    -TrackingId $trackingId -DurationMs $durationMs -ErrorMessage $errorMsg `
                    -StartedDttm $deleteStart -CompletedDttm $deleteFinish

                $errors += "Network: $fileName - $errorMsg"
            }
        }
    }
}

# -- Step 4: Summary --

$scriptDuration = [int]((Get-Date) - $scriptStart).TotalMilliseconds
$finalStatus = if ($errors.Count -eq 0) { 'SUCCESS' } else { 'PARTIAL' }
$errorSummary = if ($errors.Count -gt 0) { "$($errors.Count) errors: $($errors[0])..." } else { $null }

Write-Log "========================================"
Write-Log "Retention Complete$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
Write-Log "  Local candidates: $($localCandidates.Count)"
Write-Log "  Local deleted: $localFilesDeleted ($([math]::Round($localBytesDeleted/1GB, 2)) GB)"
Write-Log "  Network candidates: $($networkCandidates.Count)"
Write-Log "  Network deleted: $networkFilesDeleted ($([math]::Round($networkBytesDeleted/1GB, 2)) GB)"
Write-Log "  Errors: $($errors.Count)"
Write-Log "  Duration: $scriptDuration ms"
Write-Log "========================================"

if ($errors.Count -gt 0) {
    Write-Log "Errors encountered:" -Level "WARN"
    foreach ($err in $errors) {
        Write-Log "  - $err" -Level "WARN"
    }
}

# Orchestrator callback
if ($TaskId -and $TaskId -gt 0) {
    $callbackStatus = if ($errors.Count -eq 0) { "SUCCESS" } else { "FAILED" }
    $callbackOutput = "Local: $localFilesDeleted deleted ($([math]::Round($localBytesDeleted/1GB, 2)) GB), Network: $networkFilesDeleted deleted ($([math]::Round($networkBytesDeleted/1GB, 2)) GB)"
    $callbackError = if ($errors.Count -gt 0) { "$($errors.Count) errors: $($errors[0])..." } else { "" }

    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $callbackStatus -DurationMs $scriptDuration `
        -Output $callbackOutput -ErrorMessage $callbackError
}
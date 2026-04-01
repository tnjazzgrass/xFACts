<#
.SYNOPSIS
    xFACts - Backup Retention Processing

.DESCRIPTION
    xFACts - ServerOps.Backup
    Script: Process-BackupRetention.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Backup)

    Deletes backup files past retention based on chain-based policies.
    Retention is driven by FULL backup counts per database - keeps N full backup
    chains and deletes all files (FULL, DIFF, LOG) older than the Nth oldest FULL.
    Scheduled by Orchestrator v2 as a once-daily FIRE_AND_FORGET process.

    CHANGELOG
    ---------
    2026-03-10  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
                Updated header to component-level versioning format
    2026-02-04  Orchestrator v2 migration
                Added -Execute, -TaskId, -ProcessId, orchestrator callback
                Removed internal daily scheduling check
    2026-01-23  Master switch and registry alignment
                Server-level master switch, ServerRegistry joins
    2026-01-22  Table references updated (Backup_Status, GlobalConfig)
    2026-01-19  Chain-based retention
                Replaced date-based tier retention with chain-based per-database
                Removed dependency on Backup_TierRetention table
    2026-01-08  AG Listener support, initial implementation refinements
    2026-01-07  Initial implementation
                Local and network retention based on tier policies

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER Execute
    Required flag to run the script (prevents accidental execution)

.PARAMETER Force
    Force execution regardless of prior run status

.PARAMETER TaskId
    Orchestrator v2 TaskLog ID (passed by engine for callback)

.PARAMETER ProcessId
    Orchestrator v2 ProcessRegistry ID (passed by engine for callback)

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
3. The service account must have delete access to local backup paths
   via admin shares and to the network share.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$Execute,
    [switch]$Force,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Process-BackupRetention' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ========================================
# CONFIGURATION
# ========================================

$ErrorActionPreference = "Stop"
$processName = "RETENTION"

# ========================================
# PATH HELPER FUNCTIONS
# ========================================

function Get-PhysicalServerFromPath {
    <#
    .SYNOPSIS
        Extracts physical server name from backup filename for AG databases
    .DESCRIPTION
        Filename pattern: <TYPE>_<SERVER>_<DATABASE>_<TIMESTAMP>.sqb
        Example: FULL_DM-PROD-DB_crs5_oltp_20260106_060000.sqb
    #>
    param([string]$LocalPath)
    
    $fileName = Split-Path $LocalPath -Leaf
    $parts = $fileName -split '_'
    
    if ($parts.Count -ge 3) {
        $potentialServer = $parts[1]
        if ($potentialServer -match '^[A-Za-z0-9\-]+$' -and $potentialServer -match '-') {
            return $potentialServer
        }
    }
    
    return $null
}

function Convert-ToUncPath {
    <#
    .SYNOPSIS
        Converts local path to UNC admin share path
    .EXAMPLE
        X:\BACKUP\db\file.sqb -> \\SERVER\X$\BACKUP\db\file.sqb
    #>
    param(
        [string]$LocalPath,
        [string]$ServerName
    )
    
    if ($LocalPath -match '^([A-Za-z]):\\(.+)$') {
        $driveLetter = $Matches[1]
        $remainingPath = $Matches[2]
        return "\\$ServerName\$driveLetter`$\$remainingPath"
    }
    
    return $null
}

# ========================================
# EXECUTION LOG FUNCTION
# ========================================

function Write-ExecutionLog {
    param(
        [string]$Component,
        [string]$Operation,
        [string]$Status,
        [string]$ServerName = $null,
        [string]$DatabaseName = $null,
        [string]$FileName = $null,
        [int]$TrackingId = 0,
        [long]$BytesProcessed = 0,
        [int]$DurationMs = 0,
        [string]$ErrorMessage = $null,
        [datetime]$StartedDttm = (Get-Date),
        [datetime]$CompletedDttm = [datetime]::MinValue
    )
    
    $serverNameSql = if ($ServerName) { "'$ServerName'" } else { "NULL" }
    $databaseNameSql = if ($DatabaseName) { "'$DatabaseName'" } else { "NULL" }
    $fileNameSql = if ($FileName) { "'$($FileName -replace "'", "''")'" } else { "NULL" }
    $trackingIdSql = if ($TrackingId -gt 0) { $TrackingId } else { "NULL" }
    $errorMessageSql = if ($ErrorMessage) { "'$($ErrorMessage -replace "'", "''")'" } else { "NULL" }
    $completedDttmSql = if ($CompletedDttm -ne [datetime]::MinValue) { "'$($CompletedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'" } else { "NULL" }
    
    $query = @"
INSERT INTO ServerOps.Backup_ExecutionLog 
    (component, operation, status, server_name, database_name, file_name, tracking_id, 
     bytes_processed, duration_ms, error_message, started_dttm, completed_dttm)
VALUES 
    ('$Component', '$Operation', '$Status', $serverNameSql, $databaseNameSql, $fileNameSql, $trackingIdSql, 
     $BytesProcessed, $DurationMs, $errorMessageSql, 
     '$($StartedDttm.ToString("yyyy-MM-dd HH:mm:ss"))', $completedDttmSql)
"@
    
    Invoke-SqlNonQuery -Query $query | Out-Null
}

# ========================================
# EXECUTION SUMMARY FUNCTIONS
# ========================================



# ========================================
# MAIN SCRIPT
# ========================================

$scriptStart = Get-Date
$localFilesDeleted = 0
$localBytesDeleted = 0
$networkFilesDeleted = 0
$networkBytesDeleted = 0
$errors = @()

Write-Log "========================================"
Write-Log "xFACts Backup Retention"
Write-Log "========================================"

# ----------------------------------------
# Step 0: Check master switch
# ----------------------------------------
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

# (Daily scheduling is handled by Orchestrator v2 - no internal run check needed)


# ----------------------------------------
# Step 1: Get retention candidates using chain-based logic
# ----------------------------------------

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
),
LocalCutoffs AS (
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
),
NetworkCutoffs AS (
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

# ----------------------------------------
# Step 2: Process local deletes
# ----------------------------------------

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
            $physicalServer = Get-PhysicalServerFromPath -LocalPath $localPath
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
            $uncPath = Convert-ToUncPath -LocalPath $localPath -ServerName $physicalServer
        }
        else {
            $uncPath = Convert-ToUncPath -LocalPath $localPath -ServerName $serverName
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
                if (Test-Path $uncPath) {
                    Remove-Item -Path $uncPath -Force
                    $deleteFinish = Get-Date
                    $durationMs = [int]($deleteFinish - $deleteStart).TotalMilliseconds
                    
                    # Update FileTracking
                    $updateQuery = "UPDATE ServerOps.Backup_FileTracking SET local_deleted_dttm = GETDATE() WHERE tracking_id = $trackingId"
                    Invoke-SqlNonQuery -Query $updateQuery | Out-Null
                    
                    # Log success (skip logging for HISTORICAL to prevent flooding)
                    if ($copyStatus -ne 'HISTORICAL') {
                        Write-ExecutionLog -Component $processName -Operation 'LOCAL_DELETE' -Status 'SUCCESS' `
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
                Write-ExecutionLog -Component $processName -Operation 'LOCAL_DELETE' -Status 'FAILED' `
                    -ServerName $serverName -DatabaseName $databaseName -FileName $fileName `
                    -TrackingId $trackingId -DurationMs $durationMs -ErrorMessage $errorMsg `
                    -StartedDttm $deleteStart -CompletedDttm $deleteFinish
                
                $errors += "Local: $fileName - $errorMsg"
            }
        }
    }
}

# ----------------------------------------
# Step 3: Process network deletes
# ----------------------------------------

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
                if (Test-Path $networkPath) {
                    Remove-Item -Path $networkPath -Force
                    $deleteFinish = Get-Date
                    $durationMs = [int]($deleteFinish - $deleteStart).TotalMilliseconds
                    
                    # Update FileTracking
                    $updateQuery = "UPDATE ServerOps.Backup_FileTracking SET network_deleted_dttm = GETDATE() WHERE tracking_id = $trackingId"
                    Invoke-SqlNonQuery -Query $updateQuery | Out-Null
                    
                    # Log success (skip logging for HISTORICAL to prevent flooding)
                    if ($copyStatus -ne 'HISTORICAL') {
                        Write-ExecutionLog -Component $processName -Operation 'NETWORK_DELETE' -Status 'SUCCESS' `
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
                Write-ExecutionLog -Component $processName -Operation 'NETWORK_DELETE' -Status 'FAILED' `
                    -ServerName $serverName -DatabaseName $databaseName -FileName $fileName `
                    -TrackingId $trackingId -DurationMs $durationMs -ErrorMessage $errorMsg `
                    -StartedDttm $deleteStart -CompletedDttm $deleteFinish
                
                $errors += "Network: $fileName - $errorMsg"
            }
        }
    }
}

# ----------------------------------------
# Step 4: Update execution summary
# ----------------------------------------

$scriptDuration = [int]((Get-Date) - $scriptStart).TotalMilliseconds
$finalStatus = if ($errors.Count -eq 0) { 'SUCCESS' } else { 'PARTIAL' }
$errorSummary = if ($errors.Count -gt 0) { "$($errors.Count) errors: $($errors[0])..." } else { $null }


# ----------------------------------------
# Summary
# ----------------------------------------

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

# ----------------------------------------
# Orchestrator v2 Callback
# ----------------------------------------

if ($TaskId -and $TaskId -gt 0) {
    $callbackStatus = if ($errors.Count -eq 0) { "SUCCESS" } else { "FAILED" }
    $callbackOutput = "Local: $localFilesDeleted deleted ($([math]::Round($localBytesDeleted/1GB, 2)) GB), Network: $networkFilesDeleted deleted ($([math]::Round($networkBytesDeleted/1GB, 2)) GB)"
    $callbackError = if ($errors.Count -gt 0) { "$($errors.Count) errors: $($errors[0])..." } else { "" }
    
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $callbackStatus -DurationMs $scriptDuration `
        -Output $callbackOutput -ErrorMessage $callbackError
}
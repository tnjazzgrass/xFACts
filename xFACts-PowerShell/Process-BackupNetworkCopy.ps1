<#
.SYNOPSIS
    xFACts - Backup Network Copy Processing

.DESCRIPTION
    xFACts - ServerOps.Backup
    Script: Process-BackupNetworkCopy.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Backup)

    Copies completed backup files from local storage to network share.
    Queries Backup_FileTracking for PENDING network copies and processes each file.

    CHANGELOG
    ---------
    2026-03-16  Retry logic for failed network copies
                New Step 1B resets eligible FAILED files to PENDING for automatic retry
                Max retries configurable via GlobalConfig (network_copy_max_retries)
                Exhausted retries fire Teams alert via shared Send-TeamsAlert function
    2026-03-10  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
                Updated header to component-level versioning format
    2026-02-03  Orchestrator v2 integration
                Added -Execute, TaskId/ProcessId, orchestrator callbacks
                Added file logging, SQLPS/SqlServer compatibility
    2026-01-23  Master switch and registry alignment
                Server-level master switch, Backup_DatabaseConfig filtering
    2026-01-22  Table references updated (Backup_Status, GlobalConfig)
    2026-01-09  ExecutionLog cleanup
    2026-01-07  ExecutionSummary support
    2026-01-06  AG Listener support, batch claim
    2026-01-05  Initial implementation

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER MaxFiles
    Maximum number of files to process per run (default: 100)

.PARAMETER Execute
    Perform copies. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID for completion callback. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID for completion callback. Default 0.

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
3. The service account must have write access to the network share.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [int]$MaxFiles = 100,
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Process-BackupNetworkCopy' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ========================================
# FUNCTIONS
# ========================================

function Update-FileTrackingStatus {
    param(
        [long]$TrackingId,
        [string]$Status,
        [string]$NetworkPath = $null,
        [datetime]$StartDttm = [datetime]::MinValue,
        [datetime]$FinishDttm = [datetime]::MinValue,
        [string]$ErrorMessage = $null
    )
    
    $setClauses = @("network_copy_status = '$Status'")
    
    if ($NetworkPath) {
        $networkPathSafe = $NetworkPath -replace "'", "''"
        $setClauses += "network_path = '$networkPathSafe'"
    }
    
    if ($StartDttm -ne [datetime]::MinValue) {
        $setClauses += "network_copy_started_dttm = '$($StartDttm.ToString("yyyy-MM-dd HH:mm:ss"))'"
    }
    
    if ($FinishDttm -ne [datetime]::MinValue) {
        $setClauses += "network_copy_completed_dttm = '$($FinishDttm.ToString("yyyy-MM-dd HH:mm:ss"))'"
    }
    
    # Note: No error_message column in FileTracking - errors logged to ExecutionLog
    
    $query = "UPDATE ServerOps.Backup_FileTracking SET $($setClauses -join ', ') WHERE tracking_id = $TrackingId"
    
    return Invoke-SqlNonQuery -Query $query
}

function Convert-ToUncPath {
    <#
    .SYNOPSIS
        Converts a local path to a UNC admin share path
    .EXAMPLE
        Convert-ToUncPath -LocalPath "Q:\BACKUP\file.sqb" -ServerName "FA-INT-DBP"
        Returns: \\FA-INT-DBP\Q$\BACKUP\file.sqb
    #>
    param(
        [string]$LocalPath,
        [string]$ServerName
    )
    
    # Check if already a UNC path
    if ($LocalPath -match '^\\\\') {
        return $LocalPath
    }
    
    # Convert drive letter to admin share
    # Q:\BACKUP\file.sqb -> \\ServerName\Q$\BACKUP\file.sqb
    if ($LocalPath -match '^([A-Za-z]):\\(.*)$') {
        $driveLetter = $Matches[1]
        $remainder = $Matches[2]
        return "\\$ServerName\$driveLetter`$\$remainder"
    }
    
    # Couldn't parse - return as-is
    return $LocalPath
}

function Get-PhysicalServerFromPath {
    <#
    .SYNOPSIS
        Extracts physical server name from a backup filename
        
    .DESCRIPTION
        When Redgate is configured with <SERVER> tag in filename, the physical server
        name is embedded in the filename:
        FULL_DM-PROD-DB_crs5_oltp_20260106_060000.sqb
             ^^^^^^^^^^
        
        Filename pattern: <TYPE>_<SERVER>_<DATABASE>_<TIMESTAMP>.sqb
        
        This function extracts the server name for building source UNC paths
        when the enrollment is under the AG Listener (server_id 0).
        
    .PARAMETER LocalPath
        Full local path to the backup file
        
    .EXAMPLE
        Get-PhysicalServerFromPath -LocalPath "X:\BACKUP\crs5_oltp\FULL\FULL_DM-PROD-DB_crs5_oltp_20260106_060000.sqb"
        Returns: "DM-PROD-DB"
    #>
    param(
        [string]$LocalPath
    )
    
    # Extract just the filename
    $fileName = Split-Path $LocalPath -Leaf
    
    # Expected filename pattern: <TYPE>_<SERVER>_<DATABASE>_<TIMESTAMP>.sqb
    # Examples:
    #   FULL_DM-PROD-DB_crs5_oltp_20260106_060000.sqb
    #   LOG_DM-PROD-REP_DBA_20260106_143000.sqb
    
    # Split by underscore
    $parts = $fileName -split '_'
    
    # parts[0] = TYPE (FULL, DIFF, LOG)
    # parts[1] = SERVER (what we want)
    # parts[2+] = DATABASE and timestamp parts
    
    if ($parts.Count -ge 3) {
        $potentialServer = $parts[1]
        
        # Validate it looks like a server name (contains hyphen, typical naming convention)
        if ($potentialServer -match '^[A-Za-z0-9\-]+$' -and $potentialServer -match '-') {
            return $potentialServer
        }
    }
    
    # Fallback: return $null to indicate we couldn't parse it
    return $null
}

function Write-ExecutionLog {
    param(
        [string]$Component = 'NETWORK_COPY',
        [string]$ServerName = $null,
        [string]$DatabaseName = $null,
        [string]$FileName = $null,
        [long]$TrackingId = 0,
        [string]$Operation,
        [string]$Status,
        [int]$DurationMs = $null,
        [long]$BytesProcessed = $null,
        [string]$ErrorMessage = $null,
        [datetime]$StartedDttm = (Get-Date),
        [datetime]$CompletedDttm = [datetime]::MinValue
    )
    
    $serverVal = if ($ServerName) { "'$($ServerName -replace "'", "''")'" } else { "NULL" }
    $dbVal = if ($DatabaseName) { "'$($DatabaseName -replace "'", "''")'" } else { "NULL" }
    $fileVal = if ($FileName) { "'$($FileName -replace "'", "''")'" } else { "NULL" }
    $trackingVal = if ($TrackingId -gt 0) { $TrackingId } else { "NULL" }
    $durationVal = if ($null -ne $DurationMs) { $DurationMs } else { "NULL" }
    $bytesVal = if ($null -ne $BytesProcessed) { $BytesProcessed } else { "NULL" }
    $errorVal = if ($ErrorMessage) { "'$($ErrorMessage -replace "'", "''")'" } else { "NULL" }
    $completedVal = if ($CompletedDttm -ne [datetime]::MinValue) { "'$($CompletedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'" } else { "NULL" }
    
    $query = @"
INSERT INTO ServerOps.Backup_ExecutionLog 
    (component, server_name, database_name, file_name, tracking_id, 
     operation, status, duration_ms, bytes_processed, 
     error_message, started_dttm, completed_dttm)
VALUES 
    ('$Component', $serverVal, $dbVal, $fileVal, $trackingVal,
     '$Operation', '$Status', $durationVal, $bytesVal,
     $errorVal, '$($StartedDttm.ToString("yyyy-MM-dd HH:mm:ss"))', $completedVal)
"@
    
    Invoke-SqlNonQuery -Query $query | Out-Null
}



# ========================================
# MAIN SCRIPT
# ========================================

$scriptStart = Get-Date
$processName = "NETWORK_COPY"

Write-Log "========================================"
Write-Log "xFACts Backup Network Copy"
Write-Log "========================================"

if (-not $Execute) {
    Write-Log "*** PREVIEW MODE - No changes will be made. Use -Execute to run. ***" "WARN"
}

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
if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs 0 -Output "Backup processing not enabled on any server"
    }
    exit 0
}

Write-Log "  Found $($serverCheck.enabled_count) server(s) with Backup enabled."

# ----------------------------------------
# Step 1: Get config settings
# ----------------------------------------
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
$maxRetries = 2  # Default: 2 retries (3 total attempts)
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

# ----------------------------------------
# Step 1B: Retry failed files
# ----------------------------------------
# Reset eligible FAILED files back to PENDING so the existing processing loop picks them up.
# Files that have exhausted retries are left FAILED and a Teams alert is fired.
Write-Log "Checking for failed files eligible for retry..."

$failedRetryable = Get-SqlData -Query @"
SELECT ft.tracking_id, ft.server_name, ft.database_name, ft.file_name,
       ft.network_copy_retry_count,
       COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.ServerRegistry sr ON ft.server_id = sr.server_id
WHERE ft.network_copy_status = 'FAILED'
  AND ft.network_copy_retry_count < $maxRetries
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
"@

$failedExhausted = Get-SqlData -Query @"
SELECT ft.tracking_id, ft.server_name, ft.database_name, ft.file_name,
       ft.network_copy_retry_count,
       COALESCE(ft.compressed_size_bytes, ft.file_size_bytes) AS file_size_bytes
FROM ServerOps.Backup_FileTracking ft
JOIN dbo.ServerRegistry sr ON ft.server_id = sr.server_id
WHERE ft.network_copy_status = 'FAILED'
  AND ft.network_copy_retry_count >= $maxRetries
  AND sr.is_active = 1
  AND sr.serverops_backup_enabled = 1
"@

# Reset retryable files to PENDING
if ($null -ne $failedRetryable -and @($failedRetryable).Count -gt 0) {
    $retryCount = @($failedRetryable).Count
    Write-Log "  Found $retryCount file(s) eligible for retry"
    
    foreach ($retryFile in $failedRetryable) {
        $retryId = $retryFile.tracking_id
        $retryAttempt = $retryFile.network_copy_retry_count + 1
        Write-Log "  Retry $retryAttempt/${maxRetries}: $($retryFile.server_name)/$($retryFile.database_name)/$($retryFile.file_name)"
        
        if ($Execute) {
            Invoke-SqlNonQuery -Query @"
UPDATE ServerOps.Backup_FileTracking
SET network_copy_status = 'PENDING',
    network_copy_started_dttm = NULL,
    network_copy_completed_dttm = NULL,
    network_copy_retry_count = network_copy_retry_count + 1
WHERE tracking_id = $retryId
  AND network_copy_status = 'FAILED'
"@ | Out-Null
        }
        else {
            Write-Log "  [Preview] Would reset tracking_id $retryId to PENDING (retry $retryAttempt)" "INFO"
        }
    }
}
else {
    Write-Log "  No files eligible for retry"
}

# Alert for exhausted files
if ($null -ne $failedExhausted -and @($failedExhausted).Count -gt 0) {
    $exhaustedCount = @($failedExhausted).Count
    Write-Log "  Found $exhaustedCount file(s) with retries exhausted - alerting" "WARN"
    
    foreach ($exhaustedFile in $failedExhausted) {
        $sizeGB = [math]::Round($exhaustedFile.file_size_bytes / 1GB, 2)
        
        Send-TeamsAlert -SourceModule 'ServerOps' -AlertCategory 'CRITICAL' `
            -Title "{{FIRE}} Backup Network Copy Failed - Retries Exhausted" `
            -Message @"
**Server:** $($exhaustedFile.server_name)
**Database:** $($exhaustedFile.database_name)
**File:** $($exhaustedFile.file_name)
**Size:** $sizeGB GB
**Attempts:** $($exhaustedFile.network_copy_retry_count + 1) (original + $($exhaustedFile.network_copy_retry_count) retries)

This file has failed all retry attempts and requires manual investigation.
"@ `
            -TriggerType 'BACKUP_NETWORK_COPY_EXHAUSTED' `
            -TriggerValue "$($exhaustedFile.tracking_id)"
    }
}

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

# ----------------------------------------
# Step 2: Get pending files
# ----------------------------------------
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

# ----------------------------------------
# Step 2B: Claim batch - mark all selected files as IN_PROGRESS
# ----------------------------------------
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


# ----------------------------------------
# Step 3: Process each file
# ----------------------------------------
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
        $physicalServer = Get-PhysicalServerFromPath -LocalPath $localPath
        
        if ($null -eq $physicalServer) {
            # Fallback: Query listener to resolve current primary
            Write-Log "  Could not parse server from filename, resolving via listener..." "WARN"
            $physicalServer = (Invoke-Sqlcmd -ServerInstance "AVG-PROD-LSNR" -Query "SELECT @@SERVERNAME AS name" -ApplicationName $script:XFActsAppName -TrustServerCertificate).name
        }
        
        Write-Log "  AG database - physical server: $physicalServer"
        $sourcePath = Convert-ToUncPath -LocalPath $localPath -ServerName $physicalServer
    } else {
        # Non-AG database - server_name is already the physical server
        $sourcePath = Convert-ToUncPath -LocalPath $localPath -ServerName $serverName
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
            Update-FileTrackingStatus -TrackingId $trackingId -Status 'COMPLETED' `
                -NetworkPath $destPath -FinishDttm $fileFinish | Out-Null
            
            # Calculate throughput
            $sizeMB = [math]::Round($destSize / 1MB, 2)
            $mbPerSec = if ($durationSec -gt 0) { [math]::Round($sizeMB / $durationSec, 2) } else { 0 }
            
            Write-Log "  SUCCESS: Copied $sizeMB MB in $durationSec sec ($mbPerSec MB/s)"
            
            Write-ExecutionLog -Component 'NETWORK_COPY' -ServerName $serverName `
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
        Update-FileTrackingStatus -TrackingId $trackingId -Status 'FAILED' -FinishDttm $fileFinish | Out-Null
        
        Write-ExecutionLog -Component 'NETWORK_COPY' -ServerName $serverName `
            -DatabaseName $dbName -FileName $fileName -TrackingId $trackingId `
            -Operation "Copy to network" -Status 'FAILED' `
            -DurationMs $durationMs -ErrorMessage $errorMsg `
            -StartedDttm $fileStart -CompletedDttm $fileFinish
        
        $failCount++
    }
}

# ----------------------------------------
# Step 4: Summary
# ----------------------------------------
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
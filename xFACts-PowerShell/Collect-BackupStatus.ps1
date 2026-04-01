<#
.SYNOPSIS
    xFACts - Backup Status Collection

.DESCRIPTION
    xFACts - ServerOps.Backup
    Script: Collect-BackupStatus.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Backup)

    Discovers backup completions from msdb.backupset across all registered servers
    and inserts tracking records into xFACts.ServerOps.Backup_FileTracking.

    Supports two modes:
    - Initial Load: Loads all historical backup data, marks as HISTORICAL
    - Ongoing: Loads only new backups since last collection

    CHANGELOG
    ---------
    2026-03-17  ExecutionLog detail rows and Backup_Status deprecation
                Replaced batch INSERT with individual INSERT + OUTPUT for tracking_id
                Write per-file detail rows to Backup_ExecutionLog (matches other pipeline scripts)
                Removed Start-ExecutionSummary / Complete-ExecutionSummary (Backup_Status dependency)
                Removed sp_Backup_Monitor call (retry logic + Send-TeamsAlert handles stale pipeline)
                Removed summary-level Write-ExecutionLog calls (replaced by per-file detail)
    2026-03-16  Backup filename filter fix
                Replaced GUID exclusion filter with extension whitelist (.sqb/.bak/.trn)
                Prevents Redgate temporary SQLBACKUP_ filenames from entering FileTracking
    2026-03-10  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
                Updated header to component-level versioning format
    2026-02-03  Orchestrator v2 integration
                Added -Execute safeguard (preview mode by default)
                Added TaskId/ProcessId parameters with orchestrator callbacks
                Added file logging, SQLPS/SqlServer module compatibility
                Relocation to E:\xFACts-PowerShell
    2026-01-23  Master switch and registry alignment
                Added server-level master switch check (serverops_backup_enabled)
                ServerOps.ServerRegistry -> dbo.ServerRegistry
                ServerOps.DatabaseRegistry -> dbo.DatabaseRegistry + Backup_DatabaseConfig
                Database flags now from ServerOps.Backup_DatabaseConfig
    2026-01-22  Table references updated:
                Backup_ExecutionSummary -> Backup_Status
                Backup_AlertDetection -> Backup_AlertHistory
    2026-01-19  Backup monitor integration
                Calls sp_Backup_Monitor at end of collection
                Logs detections to Backup_AlertHistory
    2026-01-09  ExecutionLog cleanup
                Renamed operations, removed redundant batch summary entry
    2026-01-08  Compressed size collection
                Added compressed_size_bytes via UNC path
    2026-01-07  GUID path filter, ExecutionSummary support
                Excludes VSS/virtual device GUID paths
                Added Start/Complete-ExecutionSummary functions
    2026-01-06  AG Listener support, backup_source detection
                Added AG_LISTENER to server_type filter
                REDGATE/NATIVE detection based on file extension
    2026-01-05  Initial implementation
                Cross-server msdb backup discovery
                Initial load and ongoing collection modes

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER InitialLoad
    Load all historical backup data (one-time operation)

.PARAMETER Force
    Bypass frequency check and run immediately

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for
    task completion callback. Default 0 (no callback when run manually).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. This is deployed in an Availability Group - ensure this script is placed
   on both servers in the appropriate folder.
2. The SQL Agent service account must have SQL access to msdb on all monitored
   SQL instances.
3. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$InitialLoad,
    [switch]$Force,
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Collect-BackupStatus' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ========================================
# FUNCTIONS
# ========================================

function Get-SqlInstanceName {
    <#
    .SYNOPSIS
        Builds the SQL Server instance connection string from server name and optional instance name
    #>
    param(
        [string]$ServerName,
        [string]$InstanceName
    )
    
    if ([string]::IsNullOrWhiteSpace($InstanceName)) {
        return $ServerName
    }
    else {
        return "$ServerName\$InstanceName"
    }
}

function ConvertTo-BackupType {
    <#
    .SYNOPSIS
        Converts msdb backup type code to xFACts backup type
    #>
    param([string]$MsdbType)
    
    switch ($MsdbType) {
        'D' { return 'FULL' }
        'I' { return 'DIFF' }
        'L' { return 'LOG' }
        default { return 'FULL' }  # Default to FULL for unknown types
    }
}

function Convert-ToUncPath {
    <#
    .SYNOPSIS
        Converts a local path to a UNC admin share path
    #>
    param(
        [string]$LocalPath,
        [string]$ServerName
    )
    
    if ([string]::IsNullOrWhiteSpace($LocalPath) -or [string]::IsNullOrWhiteSpace($ServerName)) {
        return $null
    }
    
    # Handle if it's already a UNC path
    if ($LocalPath.StartsWith('\\')) {
        return $LocalPath
    }
    
    # Convert drive letter to admin share (e.g., X: -> X$)
    if ($LocalPath -match '^([A-Za-z]):(.*)$') {
        $driveLetter = $Matches[1]
        $remainingPath = $Matches[2]
        return "\\$ServerName\$driveLetter`$$remainingPath"
    }
    
    return $null
}

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

function Get-CompressedFileSize {
    <#
    .SYNOPSIS
        Gets the actual on-disk file size via UNC path
    .DESCRIPTION
        For AG Listener databases, parses physical server from filename.
        Returns NULL if file cannot be accessed (historical, permissions, etc.)
    #>
    param(
        [string]$LocalPath,
        [string]$ServerName
    )
    
    try {
        # Determine physical server for UNC path
        $physicalServer = $ServerName
        if ($ServerName -eq 'AVG-PROD-LSNR') {
            $parsed = Get-PhysicalServerFromPath -LocalPath $LocalPath
            if ($parsed) {
                $physicalServer = $parsed
            } else {
                return $null
            }
        }
        
        # Convert to UNC and get size
        $uncPath = Convert-ToUncPath -LocalPath $LocalPath -ServerName $physicalServer
        if ($uncPath -and (Test-Path $uncPath -ErrorAction SilentlyContinue)) {
            return (Get-Item $uncPath -ErrorAction SilentlyContinue).Length
        }
    }
    catch {
        # Silently return null - file may be gone or inaccessible
    }
    
    return $null
}

function Get-BackupsFromServer {
    <#
    .SYNOPSIS
        Queries msdb on a remote server for backup information
    .PARAMETER SqlInstanceName
        Full SQL instance connection string
    .PARAMETER SinceDate
        Only return backups completed after this date (NULL for all)
    #>
    param(
        [string]$SqlInstanceName,
        [datetime]$SinceDate = [datetime]::MinValue
    )
    
    # Build date filter
    $dateFilter = ""
    if ($SinceDate -gt [datetime]::MinValue) {
        $dateFilter = "AND bs.backup_finish_date > '$($SinceDate.ToString("yyyy-MM-dd HH:mm:ss"))'"
    }
    
    $query = @"
SELECT 
    bs.backup_set_id,
    bs.database_name,
    bs.type AS backup_type,
    bs.backup_start_date,
    bs.backup_finish_date,
    bs.backup_size,
    bmf.physical_device_name AS file_path
FROM msdb.dbo.backupset bs
CROSS APPLY (
    SELECT TOP 1 physical_device_name
    FROM msdb.dbo.backupmediafamily bmf
    WHERE bmf.media_set_id = bs.media_set_id
      AND bmf.device_type IN (2, 7)  -- 2=Disk, 7=Virtual Device (Redgate)
    ORDER BY bmf.family_sequence_number
) bmf
WHERE bs.backup_finish_date IS NOT NULL
  AND (bmf.physical_device_name LIKE '%.sqb'
    OR bmf.physical_device_name LIKE '%.bak'
    OR bmf.physical_device_name LIKE '%.trn')
  $dateFilter
ORDER BY bs.backup_finish_date
"@
    
    return Get-SqlData -Query $query -Instance $SqlInstanceName -DatabaseName "msdb"
}

function Write-ExecutionLog {
    <#
    .SYNOPSIS
        Writes a detail entry to Backup_ExecutionLog for a collected backup file
    #>
    param(
        [string]$Component = 'COLLECTION',
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
        [datetime]$CompletedDttm = $null
    )
    
    # Build parameter values with NULL handling
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
$processName = "COLLECTION"

Write-Log "========================================"
Write-Log "xFACts Backup Status Collection"
Write-Log "========================================"

if ($InitialLoad) {
    Write-Log "*** INITIAL LOAD MODE - Loading all historical data ***" "WARN"
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
    Write-Log "Backup monitoring is not enabled on any server (serverops_backup_enabled = 0). Exiting." "WARN"
    exit 0
}

Write-Log "  Found $($serverCheck.enabled_count) server(s) with Backup enabled."

# ----------------------------------------
# Step 1: Get list of servers to monitor
# ----------------------------------------
Write-Log "Retrieving server list..."

$servers = Get-SqlData -Query @"
SELECT 
    sr.server_id, 
    sr.server_name, 
    sr.instance_name,
    sr.server_type
FROM dbo.ServerRegistry sr
WHERE sr.is_active = 1 
  AND sr.serverops_backup_enabled = 1
  AND sr.server_type IN ('SQL_SERVER', 'AG_LISTENER')
ORDER BY sr.server_id
"@

if ($null -eq $servers -or @($servers).Count -eq 0) {
    Write-Log "No active servers configured for backup monitoring. Exiting." "WARN"
    exit 0
}

$serverCount = @($servers).Count
Write-Log "Found $serverCount server(s) to monitor."

# ----------------------------------------
# Step 2: Get enrolled databases with their flags
# ----------------------------------------
Write-Log "Retrieving database enrollment..."

$enrolledDatabases = Get-SqlData -Query @"
SELECT 
    dr.database_id,
    sr.server_id,
    sr.server_name,
    dr.database_name,
    dr.is_active,
    ISNULL(dc.backup_network_copy_enabled, 0) AS backup_network_copy_enabled,
    ISNULL(dc.backup_aws_upload_enabled, 0) AS backup_aws_upload_enabled
FROM dbo.DatabaseRegistry dr
JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
LEFT JOIN ServerOps.Backup_DatabaseConfig dc ON dr.database_id = dc.database_id
WHERE sr.is_active = 1 
  AND sr.serverops_backup_enabled = 1
ORDER BY sr.server_id, dr.database_name
"@

# Build lookup hashtable for quick access
$dbLookup = @{}
foreach ($db in $enrolledDatabases) {
    $key = "$($db.server_id)|$($db.database_name)"
    $dbLookup[$key] = $db
}

Write-Log "Found $($enrolledDatabases.Count) enrolled database(s)."

# ----------------------------------------
# Step 3: Get last backup timestamp per server (for ongoing mode)
# ----------------------------------------
$lastBackupByServer = @{}

if (-not $InitialLoad) {
    Write-Log "Checking last collected backup times..."
    
    $lastBackups = Get-SqlData -Query @"
SELECT 
    server_id,
    MAX(backup_finish_dttm) AS last_backup_dttm
FROM ServerOps.Backup_FileTracking
GROUP BY server_id
"@
    
    if ($null -ne $lastBackups) {
        foreach ($lb in $lastBackups) {
            if ($lb.last_backup_dttm -isnot [DBNull]) {
                $lastBackupByServer[$lb.server_id] = $lb.last_backup_dttm
            }
        }
    }
    
    Write-Log "Found last backup times for $($lastBackupByServer.Count) server(s)."
}

# ----------------------------------------
# Step 4: Collect backup data from each server
# ----------------------------------------
$collectionTime = Get-Date
$totalBackupsDiscovered = 0
$totalBackupsInserted = 0
$totalBackupsSkipped = 0
$successServers = 0
$failedServers = @()

foreach ($server in $servers) {
    $serverName = $server.server_name
    $serverId = $server.server_id
    $instanceName = if ($server.instance_name -isnot [DBNull]) { $server.instance_name } else { $null }
    
    $sqlInstanceName = Get-SqlInstanceName -ServerName $serverName -InstanceName $instanceName
    
    Write-Log "----------------------------------------"
    Write-Log "Processing: $sqlInstanceName (ID: $serverId)"
    
    $serverStart = Get-Date
    
    try {
        # Determine date filter for this server
        $sinceDate = [datetime]::MinValue
        if (-not $InitialLoad -and $lastBackupByServer.ContainsKey($serverId)) {
            $sinceDate = $lastBackupByServer[$serverId]
            Write-Log "  Collecting backups after: $($sinceDate.ToString('yyyy-MM-dd HH:mm:ss'))"
        }
        
        # Query msdb for backups
        $backups = Get-BackupsFromServer -SqlInstanceName $sqlInstanceName -SinceDate $sinceDate
        
        if ($null -eq $backups) {
            # Could be error or just no new backups - check by running simple test query
            $testResult = Get-SqlData -Query "SELECT 1 AS test" -Instance $sqlInstanceName -DatabaseName "msdb"
            if ($null -eq $testResult) {
                Write-Log "  Failed to connect to msdb - skipping server" "ERROR"
                $failedServers += $serverName
                continue
            }
            else {
                # Connection works, just no new backups
                $backups = @()
            }
        }
        
        $backupCount = @($backups).Count
        Write-Log "  Found $backupCount backup record(s)"
        
        $serverInserted = 0
        $serverSkipped = 0
        
        foreach ($backup in $backups) {
            $dbName = $backup.database_name
            $backupSetId = $backup.backup_set_id
            $backupType = ConvertTo-BackupType -MsdbType $backup.backup_type
            $filePath = $backup.file_path
            $fileName = Split-Path $filePath -Leaf
            $backupSource = if ($fileName -like '*.sqb') { 'REDGATE' } else { 'NATIVE' }
            $fileSize = if ($backup.backup_size -isnot [DBNull]) { $backup.backup_size } else { $null }
            $backupStart = if ($backup.backup_start_date -isnot [DBNull]) { $backup.backup_start_date } else { $null }
            $backupFinish = $backup.backup_finish_date
            
            # Get actual compressed size from disk (only for ongoing collection, not historical)
            $compressedSize = $null
            if (-not $InitialLoad) {
                $compressedSize = Get-CompressedFileSize -LocalPath $filePath -ServerName $serverName
            }
            
            # Check if database is enrolled
            $lookupKey = "$serverId|$dbName"
            $dbConfig = $dbLookup[$lookupKey]
            
            if ($null -eq $dbConfig) {
                # Database not enrolled - skip silently
                $serverSkipped++
                continue
            }
            
            if ($dbConfig.is_active -eq 0) {
                # Database inactive - skip
                $serverSkipped++
                continue
            }
            
            # Determine statuses based on mode and flags
            if ($InitialLoad) {
                $networkStatus = 'HISTORICAL'
                $awsStatus = 'HISTORICAL'
            }
            else {
                # For ongoing collection, check if xFACts manages these operations
                # If not enabled, it means Redgate is still handling it or we don't care
                $networkStatus = if ($dbConfig.backup_network_copy_enabled -eq 1) { 'PENDING' } else { 'SKIPPED' }
                $awsStatus = if ($dbConfig.backup_aws_upload_enabled -eq 1) { 'PENDING' } else { 'SKIPPED' }
            }
            
            # Build INSERT with OUTPUT to capture tracking_id
            $fileNameSafe = $fileName -replace "'", "''"
            $filePathSafe = $filePath -replace "'", "''"
            $dbNameSafe = $dbName -replace "'", "''"
            $fileSizeVal = if ($null -ne $fileSize) { $fileSize } else { "NULL" }
            $compressedSizeVal = if ($null -ne $compressedSize) { $compressedSize } else { "NULL" }
            $backupStartVal = if ($null -ne $backupStart) { "'$($backupStart.ToString("yyyy-MM-dd HH:mm:ss"))'" } else { "NULL" }
            
            if (-not $Execute) {
                Write-Log "    [Preview] Would insert: $fileName ($backupType, $dbName)"
                $serverInserted++
                continue
            }
            
            $fileStart = Get-Date
            
            $insertQuery = @"
INSERT INTO ServerOps.Backup_FileTracking 
    (server_id, server_name, database_name, backup_type, file_name, file_size_bytes,
     backup_start_dttm, backup_finish_dttm, local_path, 
     network_copy_status, aws_upload_status, msdb_backup_set_id, backup_source, compressed_size_bytes)
OUTPUT INSERTED.tracking_id
VALUES 
    ($serverId, '$serverName', '$dbNameSafe', '$backupType', '$fileNameSafe', $fileSizeVal,
     $backupStartVal, '$($backupFinish.ToString("yyyy-MM-dd HH:mm:ss"))', '$filePathSafe',
     '$networkStatus', '$awsStatus', $backupSetId, '$backupSource', $compressedSizeVal)
"@
            
            $insertResult = Get-SqlData -Query $insertQuery
            $fileFinish = Get-Date
            $fileDurationMs = [int]($fileFinish - $fileStart).TotalMilliseconds
            
            if ($null -ne $insertResult) {
                $newTrackingId = $insertResult.tracking_id
                $serverInserted++
                
                $bytesVal = if ($null -ne $compressedSize) { $compressedSize } elseif ($null -ne $fileSize) { $fileSize } else { $null }
                
                Write-ExecutionLog -Component 'COLLECTION' -ServerName $serverName `
                    -DatabaseName $dbName -FileName $fileName -TrackingId $newTrackingId `
                    -Operation "Backup collected" -Status 'SUCCESS' `
                    -DurationMs $fileDurationMs -BytesProcessed $bytesVal `
                    -StartedDttm $fileStart -CompletedDttm $fileFinish
                
                Write-Log "    Collected: $fileName ($backupType, $dbName) [tracking_id: $newTrackingId]"
            }
            else {
                Write-Log "    FAILED to insert: $fileName ($backupType, $dbName)" "ERROR"
                
                Write-ExecutionLog -Component 'COLLECTION' -ServerName $serverName `
                    -DatabaseName $dbName -FileName $fileName `
                    -Operation "Backup collected" -Status 'FAILED' `
                    -DurationMs $fileDurationMs -ErrorMessage "INSERT returned no tracking_id" `
                    -StartedDttm $fileStart -CompletedDttm $fileFinish
            }
        }
        
        $totalBackupsDiscovered += $backupCount
        $totalBackupsInserted += $serverInserted
        $totalBackupsSkipped += $serverSkipped
        
        $serverDuration = [int]((Get-Date) - $serverStart).TotalMilliseconds
        Write-Log "  Inserted: $serverInserted, Skipped (not enrolled/inactive): $serverSkipped, Duration: $($serverDuration)ms"
        
        $successServers++
    }
    catch {
        Write-Log "  FAILED: $($_.Exception.Message)" "ERROR"
        $failedServers += $serverName
    }
}

# ----------------------------------------
# Step 5: Summary
# ----------------------------------------
$scriptDuration = [int]((Get-Date) - $scriptStart).TotalMilliseconds
$finalStatus = if ($failedServers.Count -eq 0) { 'SUCCESS' } else { 'PARTIAL' }
$errorSummary = if ($failedServers.Count -gt 0) { "Failed servers: $($failedServers -join ', ')" } else { $null }

Write-Log "========================================"
Write-Log "  Collection Complete$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
Write-Log "  Mode: $(if ($InitialLoad) { 'INITIAL LOAD' } else { 'ONGOING' })$(if (-not $Execute) { ' (PREVIEW)' })"
Write-Log "  Servers attempted: $serverCount"
Write-Log "  Servers successful: $successServers"
Write-Log "  Servers failed: $($failedServers.Count)"
Write-Log "  Backups discovered: $totalBackupsDiscovered"
Write-Log "  Backups inserted: $totalBackupsInserted"
Write-Log "  Backups skipped: $totalBackupsSkipped"
Write-Log "  Total duration: $($scriptDuration)ms"
Write-Log "========================================"

if ($failedServers.Count -gt 0) {
    Write-Log "Failed servers: $($failedServers -join ', ')" "WARN"
}

# Orchestrator callback
if ($TaskId -gt 0) {
    $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
    $callbackStatus = if ($failedServers.Count -eq 0) { 'SUCCESS' } else { 'FAILED' }
    $callbackOutput = "Collected $totalBackupsInserted backups from $successServers servers. Duration: ${totalMs}ms"
    if ($failedServers.Count -gt 0) {
        $callbackOutput += " | Failed: $($failedServers -join ', ')"
    }
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
    -TaskId $TaskId -ProcessId $ProcessId `
    -Status $callbackStatus -DurationMs $totalMs -Output $callbackOutput
}

if ($failedServers.Count -gt 0) { exit 1 } else { exit 0 }
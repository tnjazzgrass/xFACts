<#
.SYNOPSIS
    xFACts - Index Maintenance Execution

.DESCRIPTION
    xFACts - ServerOps.Index
    Script: Execute-IndexMaintenance.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Index)

    Executes index rebuild operations from the Index_Queue:
    - Respects per-database maintenance schedules (Exception → Holiday → Database)
    - Uses best-fit algorithm on weekdays to maximize throughput
    - Uses priority order on weekends/holidays (extended windows)
    - Marks oversized indexes as SCHEDULED for extended window processing
    - Logs execution details to Index_ExecutionLog
    - Updates Index_Registry after successful rebuilds
    - Tracks variance between estimated and actual duration for refinement

    CHANGELOG
    ---------
    2026-03-10  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
                Standardized param names ($ServerInstance, $Database)
                Updated header to component-level versioning format
    2026-02-14  Orchestrator v2 standardization
                Added -TaskId, -ProcessId, orchestrator callback
                Standardized initialization block, added file logging
                Relocated to E:\xFACts-PowerShell
    2026-01-22  xFACts Refactoring - Phase 3/8
                Table references updated to Index_* naming
                GlobalConfig-based settings, server-level master switch
    2026-01-13  Schedule integration, Maintenance component refactor
                Schedule awareness, best-fit algorithm, SCHEDULED status
    2026-01-11  Initial PowerShell implementation for Index Maintenance 2.0
                Processes queue by priority, logs variance for estimate refinement

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER DatabaseFilter
    Process only specific database(s). Comma-separated.

.PARAMETER ExcludeDatabase
    Exclude specific database(s). Comma-separated.

.PARAMETER MaxMinutes
    Maximum runtime in minutes. 0 = unlimited. (default: 0)

.PARAMETER Execute
    Perform rebuilds. Without this flag, runs in preview mode.

.PARAMETER Force
    Bypass schedule checks and process all databases.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for
    task completion callback. Default 0 (no callback when run manually).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
3. xFACts-IndexFunctions.ps1 must be in the same directory (hard dependency).
4. The service account running this script needs:
   - ALTER INDEX permission on all enrolled databases
   - Read/Write access to xFACts database
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [string]$DatabaseFilter = $null,
    [string]$ExcludeDatabase = $null,
    [int]$MaxMinutes = 0,
    [switch]$Execute,
    [switch]$Force,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Execute-IndexMaintenance' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# Dot-source shared index functions (hard dependency - must be after OrchestratorFunctions)
. "$PSScriptRoot\xFACts-IndexFunctions.ps1"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Get-AGPrimary {
    param(
        [string]$ListenerName
    )
    
    $query = @"
SELECT ar.replica_server_name
FROM sys.dm_hadr_availability_group_states ags
JOIN sys.availability_replicas ar ON ags.group_id = ar.group_id
WHERE ags.primary_replica = ar.replica_server_name
"@
    
    try {
        $result = Invoke-Sqlcmd -ServerInstance $ListenerName -Database "master" -Query $query -QueryTimeout 10 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
        if ($result) {
            return $result.replica_server_name
        }
    }
    catch {
        Write-Log "Could not detect AG primary for $ListenerName : $($_.Exception.Message)" "WARN"
    }
    return $null
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

$scriptStart = Get-Date

Write-Log ""
Write-Log "================================================================"
Write-Log "  Index Maintenance Execution"
Write-Log "================================================================"
Write-Log ""

# ----------------------------------------------------------------------------
# Step 0: Check server-level master switch
# ----------------------------------------------------------------------------

Write-Log "Checking server-level index maintenance enable flag..."

$serverCheck = Get-SqlData -Query "
    SELECT COUNT(*) AS enabled_count
    FROM dbo.ServerRegistry
    WHERE is_active = 1
      AND serverops_index_enabled = 1
"

if (-not $serverCheck -or $serverCheck.enabled_count -eq 0) {
    Write-Log "Index maintenance is not enabled on any server (serverops_index_enabled = 0). Exiting." "WARN"
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs 0 `
            -Output "No servers enabled for index maintenance"
    }
    exit 0
}

Write-Log "Found $($serverCheck.enabled_count) server(s) with index maintenance enabled" "SUCCESS"

# ----------------------------------------------------------------------------
# Load Configuration
# ----------------------------------------------------------------------------
Write-Log "Loading configuration settings..."

$configQuery = @"
    SELECT setting_name, setting_value, data_type 
    FROM dbo.GlobalConfig 
    WHERE module_name = 'ServerOps'
      AND category = 'Index'
      AND is_active = 1
"@
$configRows = Get-SqlData -Query $configQuery -Timeout 30

if (-not $configRows) {
    Write-Log "Failed to load configuration. Exiting." "ERROR"
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs 0 `
            -Output "Failed to load configuration"
    }
    exit 1
}

$config = @{}
foreach ($row in $configRows) {
    $value = switch ($row.data_type) {
        "INT"     { [int]$row.setting_value }
        "DECIMAL" { [decimal]$row.setting_value }
        "BIT"     { [int]$row.setting_value -eq 1 }
        default   { $row.setting_value }
    }
    $config[$row.setting_name] = $value
}

# Extract key settings
$lockTimeoutSeconds = if ($config.ContainsKey('index_lock_timeout_seconds')) { $config['index_lock_timeout_seconds'] } else { 60 }
$maxdop = if ($config.ContainsKey('index_default_maxdop')) { $config['index_default_maxdop'] } else { 0 }
$overrunToleranceMinutes = if ($config.ContainsKey('index_overrun_tolerance_minutes')) { $config['index_overrun_tolerance_minutes'] } else { 15 }
$scanTimeoutBase = if ($config.ContainsKey('index_scan_timeout_base_seconds')) { $config['index_scan_timeout_base_seconds'] } else { 60 }
$scanPagesPerSecond = if ($config.ContainsKey('index_scan_pages_per_second')) { $config['index_scan_pages_per_second'] } else { 200000 }

Write-Log "  Lock timeout: $lockTimeoutSeconds seconds"
Write-Log "  MAXDOP: $maxdop"
Write-Log "  Overrun tolerance: $overrunToleranceMinutes minutes"
if ($MaxMinutes -gt 0) {
    Write-Log "  Time limit: $MaxMinutes minutes"
} else {
    Write-Log "  Time limit: Unlimited"
}

# ----------------------------------------------------------------------------
# Check for Abort Flag at Startup
# ----------------------------------------------------------------------------
if ($Execute -and (Test-AbortRequested -ServerInstance $ServerInstance -Database $Database -SettingName 'index_execute_abort')) {
    Write-Log "Abort flag (index_execute_abort) is set to 1 - exiting without processing" "WARN"
    Write-Log "Reset the flag to 0 to allow execution" "WARN"
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "ABORTED" -DurationMs 0 `
            -Output "Abort flag set at startup"
    }
    exit 0
}

# ----------------------------------------------------------------------------
# Determine if Extended Window (Weekend/Holiday)
# ----------------------------------------------------------------------------
Write-Log "Checking window type..."

$windowCheck = Test-IsExtendedWindow -ServerInstance $ServerInstance -Database $Database
$isExtendedWindow = $windowCheck.IsExtended

if ($isExtendedWindow) {
    Write-Log "  Extended window: $($windowCheck.Reason)" "SCHEDULE"
} else {
    Write-Log "  Standard weekday window" "SCHEDULE"
}

# ----------------------------------------------------------------------------
# Reset Queue Statuses
# ----------------------------------------------------------------------------
if ($Execute) {
    Write-Log "Resetting queue statuses..."
    
    # Always reset DEFERRED and FAILED to PENDING
    $resetDeferredQuery = "UPDATE ServerOps.Index_Queue SET status = 'PENDING' WHERE status IN ('DEFERRED', 'FAILED')"
    Invoke-SqlNonQuery -Query $resetDeferredQuery | Out-Null
    Write-Log "  DEFERRED/FAILED → PENDING"
    
    # Reset SCHEDULED to PENDING only on extended windows
    if ($isExtendedWindow) {
        $resetScheduledQuery = "UPDATE ServerOps.Index_Queue SET status = 'PENDING' WHERE status = 'SCHEDULED'"
        Invoke-SqlNonQuery -Query $resetScheduledQuery | Out-Null
        Write-Log "  SCHEDULED → PENDING (extended window)"
    }
}

# ----------------------------------------------------------------------------
# Get Run ID
# ----------------------------------------------------------------------------
$runIdQuery = "SELECT ISNULL(MAX(run_id), 0) + 1 AS next_run_id FROM ServerOps.Index_ExecutionSummary WHERE process_name = 'EXECUTE'"
$runIdResult = Get-SqlData -Query $runIdQuery
$runId = $runIdResult.next_run_id
Write-Log "Run ID: $runId"

# ----------------------------------------------------------------------------
# Update Index_Status to IN_PROGRESS
# ----------------------------------------------------------------------------
if ($Execute) {
    $summaryUpdateQuery = @"
UPDATE ServerOps.Index_Status 
SET started_dttm = GETDATE(),
    completed_dttm = NULL,
    last_status = 'IN_PROGRESS',
    last_duration_seconds = NULL,
    items_processed = 0,
    items_added = 0,
    items_skipped = 0,
    items_failed = 0
WHERE process_name = 'EXECUTE'
"@
    Invoke-SqlNonQuery -Query $summaryUpdateQuery | Out-Null
}

# ----------------------------------------------------------------------------
# Get Databases with Queued Indexes
# ----------------------------------------------------------------------------
Write-Log "Identifying databases with queued indexes..."

$dbQuery = @"
SELECT DISTINCT
    d.database_id,
    d.database_name,
    d.server_id,
    dc.index_maintenance_priority,
    dc.index_allow_offline_rebuild,
    s.server_name,
    s.server_type,
    s.sql_edition
FROM ServerOps.Index_Queue q
JOIN dbo.DatabaseRegistry d ON q.database_id = d.database_id
JOIN dbo.ServerRegistry s ON d.server_id = s.server_id
LEFT JOIN ServerOps.Index_DatabaseConfig dc ON d.database_id = dc.database_id
WHERE q.status IN ('PENDING', 'DEFERRED', 'SCHEDULED', 'FAILED')
  AND s.serverops_index_enabled = 1
$(if ($DatabaseFilter) { "  AND d.database_name IN ($(($DatabaseFilter -split ',' | ForEach-Object { "'$($_.Trim())'" }) -join ','))" })
$(if ($ExcludeDatabase) { "  AND d.database_name NOT IN ($(($ExcludeDatabase -split ',' | ForEach-Object { "'$($_.Trim())'" }) -join ','))" })
ORDER BY dc.index_maintenance_priority ASC, d.database_name
"@

$databases = @(Get-SqlData -Query $dbQuery -Timeout 60)

if ($databases.Count -eq 0) {
    Write-Log "No databases with queued indexes to process." "WARN"
    
    if ($Execute) {
        $summaryCompleteQuery = @"
UPDATE ServerOps.Index_Status 
SET completed_dttm = GETDATE(),
    last_status = 'NO_WORK',
    last_duration_seconds = DATEDIFF(SECOND, started_dttm, GETDATE())
WHERE process_name = 'EXECUTE'
"@
        Invoke-SqlNonQuery -Query $summaryCompleteQuery | Out-Null
    }
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs 0 `
            -Output "No databases with queued indexes"
    }
    exit 0
}

Write-Log "Found $($databases.Count) database(s) with queued work"

# ----------------------------------------------------------------------------
# Build server connection map (handle AG listeners)
# ----------------------------------------------------------------------------
$serverConnections = @{}
$servers = $databases | Select-Object -Property server_name, server_type -Unique

foreach ($server in $servers) {
    $serverName = $server.server_name
    $serverType = $server.server_type
    
    if ($serverType -eq 'AG_LISTENER') {
        Write-Log "Detecting AG primary for listener: $serverName"
        $primary = Get-AGPrimary -ListenerName $serverName
        if ($primary) {
            Write-Log "  Primary replica: $primary" "SUCCESS"
            $serverConnections[$serverName] = $primary
        } else {
            Write-Log "  Could not detect primary, using listener directly" "WARN"
            $serverConnections[$serverName] = $serverName
        }
    } else {
        $serverConnections[$serverName] = $serverName
    }
}

# ----------------------------------------------------------------------------
# Initialize Statistics
# ----------------------------------------------------------------------------
$stats = @{
    Processed = 0
    Succeeded = 0
    Failed = 0
    Deferred = 0
    Scheduled = 0
    Skipped = 0
}

$dbStats = @{}
$abortRequested = $false

# ----------------------------------------------------------------------------
# Process Each Database
# ----------------------------------------------------------------------------
Write-Log "Beginning index maintenance..."

foreach ($db in $databases) {
    # Check if abort was requested in previous iteration
    if ($abortRequested) {
        Write-Log "Abort in effect - skipping remaining databases" "WARN"
        break
    }
    
    $dbName = $db.database_name
    $dbId = $db.database_id
    $serverId = $db.server_id
    $serverName = $db.server_name
    $connectionServer = $serverConnections[$serverName]
    $sqlEdition = $db.sql_edition
    $allowOffline = $db.index_allow_offline_rebuild
    
    # Determine if using online or offline estimates
    $useOnlineEstimate = ($sqlEdition -eq 'Enterprise')
    
    Write-Log ""
    Write-Log "  ══════════════════════════════════════════════════════════"
    Write-Log "  Database: $dbName ($serverName)"
    Write-Log "  ══════════════════════════════════════════════════════════"
    
    # Initialize database stats
    $dbStats[$dbName] = @{
        ServerName = $serverName
        DatabaseId = $dbId
        StartTime = Get-Date
        Processed = 0
        Succeeded = 0
        Failed = 0
        Deferred = 0
        Scheduled = 0
    }
    
    # --------------------------------------------------------------------------
    # Check Schedule (unless -Force)
    # --------------------------------------------------------------------------
    if (-not $Force) {
        $schedule = Get-EffectiveSchedule -ServerInstance $ServerInstance -Database $Database `
            -DatabaseId $dbId -ServerId $serverId
        
        if ($schedule.Source -eq 'NO_SCHEDULE') {
            Write-Log "    No schedule configured - skipping" "WARN"
            
            # Log SKIPPED entry
            if ($Execute) {
                $skipLogQuery = @"
INSERT INTO ServerOps.Index_ExecutionSummary (
    run_id, process_name, server_name, database_name,
    started_dttm, completed_dttm, duration_ms,
    items_processed, items_added, items_skipped, items_failed, status, error_message
)
VALUES (
    $runId, 'EXECUTE', '$serverName', '$dbName',
    GETDATE(), GETDATE(), 0,
    0, 0, 0, 0, 'SKIPPED', 'Database not configured for maintenance scheduling'
)
"@
                Invoke-SqlNonQuery -Query $skipLogQuery | Out-Null
            }
            
            $stats.Skipped++
            continue
        }
        
        if (-not $schedule.IsAllowed) {
            Write-Log "    Current hour blocked by $($schedule.Source) - skipping" "SCHEDULE"
            $stats.Skipped++
            continue
        }
        
        Write-Log "    Schedule: Allowed ($($schedule.Source))" "SCHEDULE"
    } else {
        Write-Log "    Schedule: Bypassed (-Force)" "WARN"
    }
    
    # --------------------------------------------------------------------------
    # Get Max Weekday Window for SCHEDULED determination
    # --------------------------------------------------------------------------
    $maxWeekdayMinutes = Get-MaxWeekdayWindow -ServerInstance $ServerInstance -Database $Database -DatabaseId $dbId
    Write-Log "    Max weekday window: $maxWeekdayMinutes minutes"
    
    # --------------------------------------------------------------------------
    # WHILE LOOP: Continue processing while time and work remain
    # --------------------------------------------------------------------------
    $continueProcessing = $true
    
    while ($continueProcessing) {
        # Check script-level time limit
        if ($MaxMinutes -gt 0) {
            $elapsed = ((Get-Date) - $scriptStart).TotalMinutes
            if ($elapsed -ge $MaxMinutes) {
                Write-Log "    Script time limit reached ($MaxMinutes minutes)" "WARN"
                $continueProcessing = $false
                break
            }
        }
        
        # Get available time in current window
        $availableMinutes = if ($Force) { 
            1440  # 24 hours if forcing
        } else {
            Get-AvailableMinutes -ServerInstance $ServerInstance -Database $Database `
                -DatabaseId $dbId -ServerId $serverId
        }
        
        if ($availableMinutes -le 0) {
            Write-Log "    No time remaining in maintenance window" "SCHEDULE"
            $continueProcessing = $false
            break
        }
        
        Write-Log "    Available window: $availableMinutes minutes"
        
        # Get indexes that fit in the window
        $windowResult = Get-IndexesForWindow -ServerInstance $ServerInstance -Database $Database `
            -DatabaseId $dbId -AvailableMinutes $availableMinutes -MaxWeekdayMinutes $maxWeekdayMinutes `
            -IsExtendedWindow $isExtendedWindow -UseOnlineEstimate $useOnlineEstimate
        
        # Handle empty result (function returns array on error)
        if ($windowResult -is [Array]) {
            Write-Log "    Failed to query index queue" "ERROR"
            $continueProcessing = $false
            break
        }
        
        $selectedIndexes = $windowResult.SelectedIndexes
        $scheduledIndexes = $windowResult.ScheduledIndexes
        $deferredScheduledIndexes = $windowResult.DeferredScheduledIndexes
        
        # Update SCHEDULED status for oversized indexes
        if ($Execute -and $scheduledIndexes -and $scheduledIndexes.Count -gt 0) {
            foreach ($idx in $scheduledIndexes) {
                $scheduleUpdateQuery = @"
UPDATE ServerOps.Index_Queue 
SET status = 'SCHEDULED', 
    last_evaluated_dttm = GETDATE()
WHERE queue_id = $($idx.queue_id)
"@
                Invoke-SqlNonQuery -Query $scheduleUpdateQuery | Out-Null
                Write-Log "    [$($idx.index_name)] → SCHEDULED (exceeds max weekday window)" "SCHEDULE"
                $stats.Scheduled++
                $dbStats[$dbName].Scheduled++
            }
        }
        
        # Increment deferral count for SCHEDULED indexes that didn't fit in extended window
        if ($Execute -and $deferredScheduledIndexes -and $deferredScheduledIndexes.Count -gt 0) {
            foreach ($idx in $deferredScheduledIndexes) {
                $deferralUpdateQuery = @"
UPDATE ServerOps.Index_Queue 
SET deferral_count = deferral_count + 1, 
    last_evaluated_dttm = GETDATE()
WHERE queue_id = $($idx.queue_id)
"@
                Invoke-SqlNonQuery -Query $deferralUpdateQuery | Out-Null
                Write-Log "    [$($idx.index_name)] SCHEDULED index didn't fit - deferral count incremented" "WARN"
            }
        }
        
        # Check if any indexes to process
        if (-not $selectedIndexes -or $selectedIndexes.Count -eq 0) {
            Write-Log "    No indexes fit in remaining window"
            $continueProcessing = $false
            break
        }
        
        Write-Log "    Selected $($selectedIndexes.Count) index(es) for this batch (~$([math]::Round($windowResult.TotalEstimatedSeconds / 60, 1)) min estimated)"
        
        # In preview mode, only do one pass (nothing gets removed from queue)
        if (-not $Execute) {
            $continueProcessing = $false
        }
        
        # ----------------------------------------------------------------------
        # Process Selected Indexes
        # ----------------------------------------------------------------------
        foreach ($item in $selectedIndexes) {
            # Re-check schedule before each index
            if (-not $Force) {
                $currentSchedule = Get-EffectiveSchedule -ServerInstance $ServerInstance -Database $Database `
                    -DatabaseId $dbId -ServerId $serverId
                
                if (-not $currentSchedule.IsAllowed) {
                    Write-Log "    Maintenance window closed - stopping gracefully" "SCHEDULE"
                    $continueProcessing = $false
                    break
                }
            }
            
            # Check script-level time limit
            if ($MaxMinutes -gt 0) {
                $elapsed = ((Get-Date) - $scriptStart).TotalMinutes
                if ($elapsed -ge $MaxMinutes) {
                    Write-Log "    Script time limit reached" "WARN"
                    $continueProcessing = $false
                    break
                }
            }
            
            $schemaName = $item.schema_name
            $tableName = $item.table_name
            $indexName = $item.index_name
            $queueId = $item.queue_id
            $registryId = $item.registry_id
            $pageCount = $item.page_count
            $fragBefore = $item.fragmentation_pct
            $priorityScore = $item.priority_score
            $deferralCount = $item.deferral_count
            $onlineOption = $item.online_option
            $estimatedSeconds = [int]$item.estimated_seconds
            
            # Override online_option for Standard Edition
            $editionOverride = $false
            if ($sqlEdition -ne 'Enterprise' -and $onlineOption -eq 1) {
                $onlineOption = 0
                $editionOverride = $true
            }
            
            # Determine rebuild mode
            $rebuildMode = if ($onlineOption -eq 1) { "ONLINE" } else { "OFFLINE" }
            
            $indexDisplay = "[$schemaName].[$tableName].[$indexName]"
            $modeDisplay = if ($editionOverride) { "OFFLINE*" } else { $rebuildMode }
            Write-Log "    Processing: $indexDisplay ($modeDisplay, ~$([math]::Round($estimatedSeconds/60, 1)) min est)" "STEP"
            
            if (-not $Execute) {
                Write-Log "      [PREVIEW] Would rebuild index" "WARN"
                $stats.Processed++
                $dbStats[$dbName].Processed++
                continue
            }
            
            $indexStart = Get-Date
            
            # Insert IN_PROGRESS row to Index_ExecutionLog
            $detailInsertQuery = @"
INSERT INTO ServerOps.Index_ExecutionLog (
    run_id, queue_id, registry_id, database_id,
    server_name, database_name, schema_name, table_name, index_name,
    page_count, fragmentation_pct_before, priority_score,
    operation_type, rebuild_mode, maxdop_used,
    estimated_seconds, started_dttm, status, deferral_count_at_execution
)
VALUES (
    $runId, $queueId, $registryId, $dbId,
    '$serverName', '$dbName', '$schemaName', '$tableName', '$indexName',
    $pageCount, $fragBefore, $priorityScore,
    'REBUILD', '$rebuildMode', $maxdop,
    $estimatedSeconds, GETDATE(), 'IN_PROGRESS', $deferralCount
);
SELECT SCOPE_IDENTITY() AS detail_id;
"@
            
            $detailResult = Get-SqlData -Query $detailInsertQuery
            $detailId = $detailResult.detail_id
            
            # Mark as IN_PROGRESS in queue
            $inProgressQuery = "UPDATE ServerOps.Index_Queue SET status = 'IN_PROGRESS' WHERE queue_id = $queueId"
            Invoke-SqlNonQuery -Query $inProgressQuery | Out-Null
            
            # Build ALTER INDEX command
            $onlineClause = if ($rebuildMode -eq "ONLINE") { "ONLINE = ON" } else { "ONLINE = OFF" }
            $maxdopClause = "MAXDOP = $maxdop"
            
            $rebuildCommand = @"
SET STATISTICS PROFILE ON;
SET LOCK_TIMEOUT $($lockTimeoutSeconds * 1000);
ALTER INDEX [$indexName] ON [$schemaName].[$tableName] REBUILD WITH ($onlineClause, $maxdopClause);
"@
            
            # Execute rebuild
            $rebuildSuccess = $false
            $errorMessage = $null
            
            try {
                # Use longer timeout for the rebuild itself - estimate + buffer
                $cmdTimeout = [math]::Max($estimatedSeconds * 2, 300)
                
                Invoke-Sqlcmd -ServerInstance $connectionServer -Database $dbName -Query $rebuildCommand -QueryTimeout $cmdTimeout -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
                $rebuildSuccess = $true
            }
            catch {
                $errorMessage = $_.Exception.Message -replace "'", "''"
                if ($errorMessage.Length -gt 4000) {
                    $errorMessage = $errorMessage.Substring(0, 4000)
                }
                Write-Log "      [FAILED] $($_.Exception.Message)" "ERROR"
            }
            
            $indexEnd = Get-Date
            $durationSeconds = [int](($indexEnd - $indexStart).TotalSeconds)
            
            if ($rebuildSuccess) {
                Write-Log "      [SUCCESS] Completed in $durationSeconds seconds" "SUCCESS"
                
                # Query post-rebuild fragmentation with scaled timeout
                $fragCheckTimeout = $scanTimeoutBase + [int]([long]$pageCount / $scanPagesPerSecond)
                $fragAfterQuery = @"
SELECT avg_fragmentation_in_percent
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('[$schemaName].[$tableName]'), NULL, NULL, 'LIMITED')
WHERE index_id = (SELECT index_id FROM sys.indexes WHERE object_id = OBJECT_ID('[$schemaName].[$tableName]') AND name = '$indexName')
"@
                
                $fragAfterResult = Get-SqlData -Instance $connectionServer -DatabaseName $dbName -Query $fragAfterQuery -Timeout $fragCheckTimeout
                $fragAfter = if ($fragAfterResult) { [math]::Round($fragAfterResult.avg_fragmentation_in_percent, 2) } else { 0 }
                
                # Calculate variance
                $variancePct = if ($estimatedSeconds -gt 0) { 
                    [math]::Round((($durationSeconds - $estimatedSeconds) / $estimatedSeconds) * 100, 2) 
                } else { 0 }
                
                # Update Index_ExecutionLog with success
                $detailUpdateQuery = @"
UPDATE ServerOps.Index_ExecutionLog
SET completed_dttm = GETDATE(),
    duration_seconds = $durationSeconds,
    fragmentation_pct_after = $fragAfter,
    variance_pct = $variancePct,
    status = 'SUCCESS'
WHERE detail_id = $detailId
"@
                Invoke-SqlNonQuery -Query $detailUpdateQuery | Out-Null
                
                # Update Index_Registry
                $registryUpdateQuery = @"
UPDATE ServerOps.Index_Registry
SET last_rebuild_dttm = GETDATE(),
    last_rebuild_duration_seconds = $durationSeconds,
    current_fragmentation_pct = $fragAfter,
    lifetime_rebuild_count = lifetime_rebuild_count + 1,
    modified_dttm = GETDATE()
WHERE registry_id = $registryId
"@
                Invoke-SqlNonQuery -Query $registryUpdateQuery | Out-Null
                
                # Delete from queue
                $queueDeleteQuery = "DELETE FROM ServerOps.Index_Queue WHERE queue_id = $queueId"
                Invoke-SqlNonQuery -Query $queueDeleteQuery | Out-Null
                
                # Update summary counters in real-time
                $summaryIncrementQuery = @"
UPDATE ServerOps.Index_Status 
SET items_added = items_added + 1
WHERE process_name = 'EXECUTE'
"@
                Invoke-SqlNonQuery -Query $summaryIncrementQuery | Out-Null
                
                $stats.Succeeded++
                $dbStats[$dbName].Succeeded++
            }
            else {
                # Update Index_ExecutionLog with failure
                $detailUpdateQuery = @"
UPDATE ServerOps.Index_ExecutionLog
SET completed_dttm = GETDATE(),
    duration_seconds = $durationSeconds,
    status = 'FAILED',
    error_message = '$errorMessage'
WHERE detail_id = $detailId
"@
                Invoke-SqlNonQuery -Query $detailUpdateQuery | Out-Null
                
                # Mark as FAILED in queue and increment deferral count
                $queueFailQuery = @"
UPDATE ServerOps.Index_Queue 
SET status = 'FAILED',
    deferral_count = deferral_count + 1,
    last_evaluated_dttm = GETDATE()
WHERE queue_id = $queueId
"@
                Invoke-SqlNonQuery -Query $queueFailQuery | Out-Null
                
                # Update summary counters in real-time
                $summaryIncrementQuery = @"
UPDATE ServerOps.Index_Status 
SET items_failed = items_failed + 1
WHERE process_name = 'EXECUTE'
"@
                Invoke-SqlNonQuery -Query $summaryIncrementQuery | Out-Null
                
                $stats.Failed++
                $dbStats[$dbName].Failed++
            }
            
            $stats.Processed++
            $dbStats[$dbName].Processed++
            
            # Check for abort flag after each index
            if ($Execute -and (Test-AbortRequested -ServerInstance $ServerInstance -Database $Database -SettingName 'index_execute_abort')) {
                Write-Log "Abort requested - stopping gracefully after current index" "WARN"
                $continueProcessing = $false
                $abortRequested = $true
            }
        }
        
        # If we broke out of the index loop early, stop processing this database
        if (-not $continueProcessing) {
            break
        }
        
        # Small pause before re-querying for more work
        Start-Sleep -Milliseconds 500
        
    }  # End WHILE loop
    
    # --------------------------------------------------------------------------
    # Write Index_ExecutionSummary entry for this database
    # --------------------------------------------------------------------------
    if ($Execute -and $dbStats[$dbName].Processed -gt 0) {
        $dbEndTime = Get-Date
        $dbDurationMs = [int](($dbEndTime - $dbStats[$dbName].StartTime).TotalMilliseconds)
        
        $dbStatus = if ($dbStats[$dbName].Failed -eq 0 -and $dbStats[$dbName].Succeeded -gt 0) { 'SUCCESS' }
                    elseif ($dbStats[$dbName].Succeeded -gt 0 -and $dbStats[$dbName].Failed -gt 0) { 'PARTIAL' }
                    elseif ($dbStats[$dbName].Failed -gt 0) { 'FAILED' }
                    else { 'NO_WORK' }
        
        $logInsertQuery = @"
INSERT INTO ServerOps.Index_ExecutionSummary (
    run_id, process_name, server_name, database_name,
    started_dttm, completed_dttm, duration_ms,
    items_processed, items_added, items_skipped, items_failed, status
)
VALUES (
    $runId, 'EXECUTE', '$serverName', '$dbName',
    '$($dbStats[$dbName].StartTime.ToString("yyyy-MM-dd HH:mm:ss"))', GETDATE(), $dbDurationMs,
    $($dbStats[$dbName].Processed), $($dbStats[$dbName].Succeeded), $($dbStats[$dbName].Scheduled), $($dbStats[$dbName].Failed), '$dbStatus'
)
"@
        Invoke-SqlNonQuery -Query $logInsertQuery | Out-Null
    }
    
    # Check if we should stop processing more databases
    if ($MaxMinutes -gt 0) {
        $elapsed = ((Get-Date) - $scriptStart).TotalMinutes
        if ($elapsed -ge $MaxMinutes) {
            Write-Log "Script time limit reached - skipping remaining databases" "WARN"
            break
        }
    }
    
}  # End database loop

# ----------------------------------------------------------------------------
# Update Index_Status with final results
# ----------------------------------------------------------------------------
$scriptEnd = Get-Date
$totalDuration = [int](($scriptEnd - $scriptStart).TotalSeconds)
$totalDurationMs = [int](($scriptEnd - $scriptStart).TotalMilliseconds)

$finalStatus = if (-not $Execute) { 'PREVIEW' }
               elseif ($abortRequested) { 'ABORTED' }
               elseif ($stats.Failed -eq 0 -and $stats.Succeeded -gt 0) { 'SUCCESS' }
               elseif ($stats.Succeeded -gt 0 -and $stats.Failed -gt 0) { 'PARTIAL' }
               elseif ($stats.Failed -gt 0 -and $stats.Succeeded -eq 0) { 'FAILED' }
               elseif ($MaxMinutes -gt 0 -and ((Get-Date) - $scriptStart).TotalMinutes -ge $MaxMinutes) { 'TIME_LIMIT' }
               else { 'NO_WORK' }

if ($Execute) {
    $summaryCompleteQuery = @"
UPDATE ServerOps.Index_Status 
SET completed_dttm = GETDATE(),
    last_status = '$finalStatus',
    last_duration_seconds = $totalDuration,
    items_processed = $($stats.Processed),
    items_added = $($stats.Succeeded),
    items_skipped = $($stats.Scheduled + $stats.Skipped),
    items_failed = $($stats.Failed)
WHERE process_name = 'EXECUTE'
"@
    Invoke-SqlNonQuery -Query $summaryCompleteQuery | Out-Null
}

# ----------------------------------------------------------------------------
# Summary Output
# ----------------------------------------------------------------------------
$durationHours = [math]::Floor($totalDuration / 3600)
$durationMinutes = [math]::Floor(($totalDuration % 3600) / 60)
$durationSec = $totalDuration % 60
$durationDisplay = if ($durationHours -gt 0) {
    "{0}:{1:D2}:{2:D2}" -f [int]$durationHours, $durationMinutes, $durationSec
} else {
    "{0:D2}:{1:D2}" -f $durationMinutes, $durationSec
}

Write-Log ""
Write-Log "================================================================"
Write-Log "  SUMMARY$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
Write-Log "================================================================"
Write-Log "  Window Type:          $(if ($isExtendedWindow) { $windowCheck.Reason } else { 'WEEKDAY' })"
Write-Log "  Indexes Processed:    $($stats.Processed)"
Write-Log "  Succeeded:            $($stats.Succeeded)"
Write-Log "  Failed:               $($stats.Failed)"
Write-Log "  Scheduled:            $($stats.Scheduled)"
Write-Log "  Databases Skipped:    $($stats.Skipped)"
Write-Log "  Duration:             $durationDisplay"

if ($abortRequested) {
    Write-Log "" "WARN"
    Write-Log "  *** EXECUTION ABORTED BY REQUEST ***" "WARN"
}

if ($Execute) {
    Write-Log "Index_Status updated: $finalStatus" "SUCCESS"
}

Write-Log ""
Write-Log "================================================================"
Write-Log "  Execution Complete"
Write-Log "================================================================"
Write-Log ""

# ----------------------------------------
# Orchestrator Callback
# ----------------------------------------
if ($TaskId -gt 0) {
    $outputSummary = "Processed:$($stats.Processed) Succeeded:$($stats.Succeeded) Failed:$($stats.Failed) Scheduled:$($stats.Scheduled) Skipped:$($stats.Skipped)"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalDurationMs `
        -Output $outputSummary
}

if ($finalStatus -eq "FAILED") { exit 1 } else { exit 0 }
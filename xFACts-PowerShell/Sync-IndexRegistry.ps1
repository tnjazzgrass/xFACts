<#
.SYNOPSIS
    xFACts - Index Registry Synchronization

.DESCRIPTION
    xFACts - ServerOps.Index
    Script: Sync-IndexRegistry.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Index)

    Performs the "cheap pass" reconciliation of index metadata:
    - Discovers new indexes and adds them to Index_Registry
    - Updates metadata (page count, fill factor) for existing indexes
    - Captures usage statistics (seeks, scans, lookups, updates)
    - Marks dropped indexes as is_dropped = 1

    This does NOT scan for fragmentation (expensive operation).
    Fragmentation scanning is handled by Scan-IndexFragmentation.ps1.

    CHANGELOG
    ---------
    2026-03-10  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery
                Standardized param names ($ServerInstance, $Database)
                Updated header to component-level versioning format
    2026-02-14  Orchestrator v2 standardization
                Added -Execute, -TaskId, -ProcessId, orchestrator callback
                Converted -Force/-AllDatabases to switches, added file logging
                Relocated to E:\xFACts-PowerShell
    2026-01-21  xFACts Refactoring - Phase 3/8
                Table references updated to Index_* naming
                GlobalConfig-based settings, server-level master switch
    2026-01-13  Maintenance component refactor
                Updated table references (Index_* to Maintenance_*)
    2026-01-10  Initial PowerShell implementation for Index Maintenance 2.0
                Inexpensive index metadata and usage statistics collection

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER AllDatabases
    Process ALL active databases regardless of index_sync_enabled flag

.PARAMETER ServerFilter
    Process only databases on specific server(s). Comma-separated.

.PARAMETER DatabaseFilter
    Process only specific database(s). Comma-separated.

.PARAMETER Force
    Override interval check and run even if SYNC completed recently

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
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
3. The service account running this script needs:
   - Read access to all enrolled databases on all monitored servers
   - Read/Write access to xFACts database
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$AllDatabases,
    [string]$ServerFilter = $null,
    [string]$DatabaseFilter = $null,
    [switch]$Force,
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Sync-IndexRegistry' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# MAIN
# ============================================================================

$scriptStart = Get-Date

Write-Log ""
Write-Log "================================================================"
Write-Log "  Index Registry Reconciliation (Metadata + Usage)"
Write-Log "================================================================"
Write-Log ""

# ----------------------------------------------------------------------------
# Step 0a: Check server-level master switch
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
# Step 0b: Check interval and update Index_Status
# ----------------------------------------------------------------------------

# Get sync interval from GlobalConfig
$intervalConfig = Get-SqlData -Query "
    SELECT CAST(setting_value AS INT) AS interval_minutes
    FROM dbo.GlobalConfig
    WHERE module_name = 'ServerOps'
      AND category = 'Index'
      AND setting_name = 'index_sync_interval_minutes'
      AND is_active = 1
"
$syncIntervalMinutes = if ($intervalConfig) { $intervalConfig.interval_minutes } else { 1440 }

# Check last SYNC completion
$lastSync = Get-SqlData -Query "
    SELECT completed_dttm, last_status
    FROM ServerOps.Index_Status
    WHERE process_name = 'SYNC'
"

if (-not $Force -and $lastSync -and $lastSync.completed_dttm -isnot [DBNull] -and $lastSync.last_status -ne 'FAILED') {
    $lastCompletedDttm = [DateTime]$lastSync.completed_dttm
    $minutesSinceSync = [math]::Round(((Get-Date) - $lastCompletedDttm).TotalMinutes)
    if ($minutesSinceSync -lt $syncIntervalMinutes) {
        Write-Log "SYNC completed $minutesSinceSync minutes ago (interval: $syncIntervalMinutes). Use -Force to override." "WARN"
        if ($TaskId -gt 0) {
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs 0 `
                -Output "Skipped - within interval ($minutesSinceSync min ago)"
        }
        exit 0
    }
}

# Mark SYNC as in progress
if ($Execute) {
    $startResult = Invoke-SqlNonQuery -Query "
        UPDATE ServerOps.Index_Status
        SET started_dttm = GETDATE(),
            completed_dttm = NULL,
            last_status = 'IN_PROGRESS',
            last_duration_seconds = NULL,
            items_processed = NULL,
            items_added = NULL,
            items_skipped = NULL,
            items_failed = NULL,
            last_error_message = NULL
        WHERE process_name = 'SYNC'
    "
}

# Get next run_id for Index_ExecutionSummary
$runIdResult = Get-SqlData -Query "
    SELECT ISNULL(MAX(run_id), 0) + 1 AS next_run_id FROM ServerOps.Index_ExecutionSummary
"
$runId = $runIdResult.next_run_id
Write-Log "Run ID: $runId"

# ----------------------------------------------------------------------------
# Step 1: Get target databases from DatabaseRegistry + Index_DatabaseConfig
# ----------------------------------------------------------------------------

Write-Log "Querying DatabaseRegistry for target databases..."

# Build filter clauses
$enabledFilter = if ($AllDatabases) { "" } else { "AND dc.index_sync_enabled = 1" }
$serverFilterClause = if ($ServerFilter) { "AND sr.server_name IN ('$($ServerFilter -replace ',', "','")')" } else { "" }
$dbFilterClause = if ($DatabaseFilter) { "AND dr.database_name IN ('$($DatabaseFilter -replace ',', "','")')" } else { "" }

$targetDatabases = Get-SqlData -Query "
    SELECT 
        dr.database_id,
        dr.database_name,
        sr.server_id,
        sr.server_name,
        sr.instance_name,
        sr.server_type,
        CASE 
            WHEN sr.instance_name IS NULL THEN sr.server_name 
            ELSE sr.server_name + '\\' + sr.instance_name 
        END AS sql_instance
    FROM dbo.DatabaseRegistry dr
    JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
    LEFT JOIN ServerOps.Index_DatabaseConfig dc ON dr.database_id = dc.database_id
    WHERE dr.is_active = 1
      AND sr.is_active = 1
      AND sr.serverops_index_enabled = 1
      $enabledFilter
      $serverFilterClause
      $dbFilterClause
    ORDER BY dr.database_id
"

if (-not $targetDatabases) {
    Write-Log "No target databases found" "WARN"
    if ($Execute) {
        Invoke-SqlNonQuery -Query "
            UPDATE ServerOps.Index_Status
            SET completed_dttm = GETDATE(),
                last_status = 'NO_WORK',
                last_duration_seconds = 0,
                items_processed = 0, items_added = 0, items_skipped = 0, items_failed = 0
            WHERE process_name = 'SYNC'
        " | Out-Null
    }
    if ($TaskId -gt 0) {
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs 0 `
            -Output "No target databases found"
    }
    exit 0
}

$totalDatabases = ($targetDatabases | Measure-Object).Count
Write-Log "Found $totalDatabases target databases"

if ($AllDatabases) {
    Write-Log "Mode: ALL databases (initial baseline)" "WARN"
} else {
    Write-Log "Mode: Only index_sync_enabled = 1"
}

Write-Log ""

# ----------------------------------------------------------------------------
# Step 2: Determine AG Primary Replicas
# ----------------------------------------------------------------------------

$agListeners = $targetDatabases | Where-Object { $_.server_type -eq 'AG_LISTENER' } | Select-Object -ExpandProperty server_name -Unique
$agPrimaryMap = @{}

foreach ($listener in $agListeners) {
    Write-Log "Detecting AG primary for listener: $listener"
    
    $primaryInfo = Get-SqlData -Instance $listener -DatabaseName "master" -Query "
        SELECT cs.replica_server_name AS primary_server
        FROM sys.dm_hadr_availability_group_states ags
        JOIN sys.availability_replicas ar ON ags.group_id = ar.group_id
        JOIN sys.dm_hadr_availability_replica_cluster_states cs ON ar.replica_id = cs.replica_id
        WHERE ags.primary_replica = cs.replica_server_name
    "
    
    if ($primaryInfo) {
        $agPrimaryMap[$listener] = $primaryInfo.primary_server
        Write-Log "  Primary replica: $($primaryInfo.primary_server)" "SUCCESS"
    }
    else {
        Write-Log "  Could not determine primary - will use listener directly" "WARN"
        $agPrimaryMap[$listener] = $listener
    }
}

Write-Log ""

# ----------------------------------------------------------------------------
# Step 3: Process each database
# ----------------------------------------------------------------------------

Write-Log "Starting reconciliation..."
Write-Log ""

$stats = @{
    DatabasesProcessed = 0
    DatabasesSkipped = 0
    IndexesDiscovered = 0
    IndexesUpdated = 0
    IndexesMarkedDropped = 0
    Errors = 0
}

$dbCount = 0
foreach ($db in $targetDatabases) {
    $dbCount++
    $dbName = $db.database_name
    $dbId = $db.database_id
    $dbStartTime = Get-Date
    
    # Determine which server to connect to
    if ($db.server_type -eq 'AG_LISTENER') {
        $connectServer = $agPrimaryMap[$db.server_name]
        $displayName = "$dbName [AG] (via $connectServer)"
    }
    else {
        $connectServer = $db.sql_instance
        $displayName = "$dbName (via $connectServer)"
    }
    
    Write-Log "[$dbCount/$totalDatabases] $displayName"
    
    # -------------------------------------------------------------------------
    # Step 3a: Get current index metadata and usage from source database
    # -------------------------------------------------------------------------
    
    $sourceIndexes = Get-SqlData -Instance $connectServer -DatabaseName $dbName -Query "
        SELECT 
            s.name AS schema_name,
            o.name AS table_name,
            i.name AS index_name,
            i.index_id,
            i.type_desc AS index_type,
            CAST(CASE WHEN pk.object_id IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS is_primary_key,
            i.is_unique,
            i.fill_factor AS current_fill_factor,
            ISNULL(ps.page_count, 0) AS current_page_count,
            us.user_seeks,
            us.user_scans,
            us.user_lookups,
            us.user_updates,
            us.last_user_seek,
            us.last_user_scan,
            STATS_DATE(i.object_id, i.index_id) AS stats_last_updated
        FROM sys.indexes i
        JOIN sys.objects o ON i.object_id = o.object_id
        JOIN sys.schemas s ON o.schema_id = s.schema_id
        LEFT JOIN sys.key_constraints pk ON i.object_id = pk.parent_object_id 
            AND i.index_id = pk.unique_index_id 
            AND pk.type = 'PK'
        LEFT JOIN (
            SELECT 
                object_id,
                index_id,
                SUM(in_row_data_page_count) AS page_count
            FROM sys.dm_db_partition_stats
            GROUP BY object_id, index_id
        ) ps ON i.object_id = ps.object_id AND i.index_id = ps.index_id
        LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id 
            AND i.index_id = us.index_id 
            AND us.database_id = DB_ID()
        WHERE i.type > 0
          AND i.name IS NOT NULL
          AND o.type IN ('U', 'V')           -- Tables and indexed views
          AND o.is_ms_shipped = 0
          -- Exclude replication system tables (specific names)
          AND NOT (s.name = 'dbo' AND o.name IN (
              'sysarticles', 'sysschemaarticles', 'sysarticleupdates',
              'syspublications', 'syssubscriptions', 'sysreplservers', 'systranschemas'
          ))
          AND NOT (s.name = 'dbo' AND o.name LIKE 'MSpeer[_]%')
          AND NOT (s.name = 'dbo' AND o.name LIKE 'MSpub[_]%')
        ORDER BY s.name, o.name, i.name
    " -Timeout 120
    
    if ($null -eq $sourceIndexes) {
        Write-Log "  ERROR - Failed to query source indexes" "ERROR"
        $stats.Errors++
        $stats.DatabasesSkipped++
        
        # Log to Index_ExecutionSummary
        if ($Execute) {
            $dbDuration = [int]((Get-Date) - $dbStartTime).TotalMilliseconds
            $logQuery = "
                INSERT INTO ServerOps.Index_ExecutionSummary 
                    (run_id, process_name, server_name, database_name, started_dttm, completed_dttm, duration_ms, status, error_message)
                VALUES 
                    ($runId, 'SYNC', '$($db.server_name)', '$($dbName -replace "'", "''")', '$($dbStartTime.ToString("yyyy-MM-dd HH:mm:ss"))', GETDATE(), $dbDuration, 'FAILED', 'Failed to query source indexes')
            "
            Invoke-SqlNonQuery -Query $logQuery | Out-Null
        }
        
        continue
    }
    
    $sourceCount = ($sourceIndexes | Measure-Object).Count
    
    if ($sourceCount -eq 0) {
        Write-Log "  No indexes found" "DEBUG"
        $stats.DatabasesProcessed++
        
        # Log to Index_ExecutionSummary
        if ($Execute) {
            $dbDuration = [int]((Get-Date) - $dbStartTime).TotalMilliseconds
            $logQuery = "
                INSERT INTO ServerOps.Index_ExecutionSummary 
                    (run_id, process_name, server_name, database_name, started_dttm, completed_dttm, duration_ms, items_processed, status)
                VALUES 
                    ($runId, 'SYNC', '$($db.server_name)', '$($dbName -replace "'", "''")', '$($dbStartTime.ToString("yyyy-MM-dd HH:mm:ss"))', GETDATE(), $dbDuration, 0, 'NO_WORK')
            "
            Invoke-SqlNonQuery -Query $logQuery | Out-Null
        }
        
        continue
    }
    
    # -------------------------------------------------------------------------
    # Step 3b: Get existing registry entries for this database
    # -------------------------------------------------------------------------
    
    $existingRegistry = Get-SqlData -Query "
        SELECT 
            registry_id,
            schema_name,
            table_name,
            index_name,
            index_id,
            is_dropped
        FROM ServerOps.Index_Registry
        WHERE database_id = $dbId
    "
    
    # Build lookup hashtable for existing entries
    $existingLookup = @{}
    $seenKeys = @{}  # Track which entries we've seen
    if ($existingRegistry) {
        foreach ($entry in $existingRegistry) {
            $key = "$($entry.schema_name).$($entry.table_name).$($entry.index_name)"
            $existingLookup[$key] = $entry
        }
    }
    
    # -------------------------------------------------------------------------
    # Step 3c: Process each source index - INSERT new, UPDATE existing
    # -------------------------------------------------------------------------
    
    $newCount = 0
    $updateCount = 0
    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    
    foreach ($idx in $sourceIndexes) {
        $key = "$($idx.schema_name).$($idx.table_name).$($idx.index_name)"
        
        # Escape single quotes in names
        $schemaEsc = $idx.schema_name -replace "'", "''"
        $tableEsc = $idx.table_name -replace "'", "''"
        $indexEsc = $idx.index_name -replace "'", "''"
        $indexTypeEsc = $idx.index_type -replace "'", "''"
        
        # Handle NULL values for usage stats
        $userSeeks = if ($null -eq $idx.user_seeks -or $idx.user_seeks -is [DBNull]) { "NULL" } else { $idx.user_seeks }
        $userScans = if ($null -eq $idx.user_scans -or $idx.user_scans -is [DBNull]) { "NULL" } else { $idx.user_scans }
        $userLookups = if ($null -eq $idx.user_lookups -or $idx.user_lookups -is [DBNull]) { "NULL" } else { $idx.user_lookups }
        $userUpdates = if ($null -eq $idx.user_updates -or $idx.user_updates -is [DBNull]) { "NULL" } else { $idx.user_updates }
        
        # Handle DateTime values carefully
        $lastSeek = "NULL"
        if ($null -ne $idx.last_user_seek -and $idx.last_user_seek -isnot [DBNull]) {
            try {
                $lastSeek = "'{0:yyyy-MM-dd HH:mm:ss}'" -f $idx.last_user_seek
            } catch { $lastSeek = "NULL" }
        }
        
        $lastScan = "NULL"
        if ($null -ne $idx.last_user_scan -and $idx.last_user_scan -isnot [DBNull]) {
            try {
                $lastScan = "'{0:yyyy-MM-dd HH:mm:ss}'" -f $idx.last_user_scan
            } catch { $lastScan = "NULL" }
        }
        
        $fillFactor = if ($null -eq $idx.current_fill_factor -or $idx.current_fill_factor -is [DBNull] -or $idx.current_fill_factor -eq 0) { "NULL" } else { $idx.current_fill_factor }
        
        # Handle stats last updated datetime
        $statsLastUpdated = "NULL"
        if ($null -ne $idx.stats_last_updated -and $idx.stats_last_updated -isnot [DBNull]) {
            try {
                $statsLastUpdated = "'{0:yyyy-MM-dd HH:mm:ss}'" -f $idx.stats_last_updated
            } catch { $statsLastUpdated = "NULL" }
        }
        
        if ($existingLookup.ContainsKey($key)) {
            # UPDATE existing entry
            $registryId = $existingLookup[$key].registry_id
            $wasDropped = $existingLookup[$key].is_dropped
            
            if ($Execute) {
                $updateQuery = "
                    UPDATE ServerOps.Index_Registry
                    SET index_id = $($idx.index_id),
                        index_type = '$indexTypeEsc',
                        is_primary_key = $([int]$idx.is_primary_key),
                        is_unique = $([int]$idx.is_unique),
                        current_fill_factor = $fillFactor,
                        current_page_count = $($idx.current_page_count),
                        user_seeks = $userSeeks,
                        user_scans = $userScans,
                        user_lookups = $userLookups,
                        user_updates = $userUpdates,
                        last_user_seek = $lastSeek,
                        last_user_scan = $lastScan,
                        stats_last_updated = $statsLastUpdated,
                        usage_captured_dttm = '$now',
                        is_dropped = 0,
                        dropped_detected_dttm = NULL,
                        modified_dttm = '$now'
                    WHERE registry_id = $registryId
                "
                
                $result = Invoke-SqlNonQuery -Query $updateQuery
                if ($result) { 
                    $updateCount++ 
                    $seenKeys[$key] = $true
                }
            }
            else {
                $updateCount++
                $seenKeys[$key] = $true
            }
        }
        else {
            # INSERT new entry
            if ($Execute) {
                $insertQuery = "
                    INSERT INTO ServerOps.Index_Registry (
                        database_id, schema_name, table_name, index_name, index_id,
                        index_type, is_primary_key, is_unique, current_fill_factor, current_page_count,
                        user_seeks, user_scans, user_lookups, user_updates,
                        last_user_seek, last_user_scan, stats_last_updated, usage_captured_dttm, created_dttm
                    )
                    VALUES (
                        $dbId, '$schemaEsc', '$tableEsc', '$indexEsc', $($idx.index_id),
                        '$indexTypeEsc', $([int]$idx.is_primary_key), $([int]$idx.is_unique), $fillFactor, $($idx.current_page_count),
                        $userSeeks, $userScans, $userLookups, $userUpdates,
                        $lastSeek, $lastScan, $statsLastUpdated, '$now', '$now'
                    )
                "
                
                $result = Invoke-SqlNonQuery -Query $insertQuery
                if ($result) { $newCount++ }
            }
            else {
                $newCount++
            }
        }
    }
    
    # -------------------------------------------------------------------------
    # Step 3d: Mark dropped indexes (in registry but not in source)
    # -------------------------------------------------------------------------
    
    $droppedCount = 0
    foreach ($key in $existingLookup.Keys) {
        $entry = $existingLookup[$key]
        if (-not $seenKeys.ContainsKey($key) -and -not $entry.is_dropped) {
            if ($Execute) {
                $markDroppedQuery = "
                    UPDATE ServerOps.Index_Registry
                    SET is_dropped = 1,
                        dropped_detected_dttm = '$now',
                        modified_dttm = '$now'
                    WHERE registry_id = $($entry.registry_id)
                "
                
                $result = Invoke-SqlNonQuery -Query $markDroppedQuery
                if ($result) { $droppedCount++ }
            }
            else {
                $droppedCount++
            }
        }
    }
    
    # Display results
    $resultParts = @()
    if ($newCount -gt 0) { $resultParts += "$newCount new" }
    if ($updateCount -gt 0) { $resultParts += "$updateCount updated" }
    if ($droppedCount -gt 0) { $resultParts += "$droppedCount dropped" }
    
    if ($resultParts.Count -eq 0) {
        Write-Log "  Results: No changes" "DEBUG"
    }
    else {
        Write-Log "  Results: $($resultParts -join ', ')" "SUCCESS"
    }
    
    $stats.DatabasesProcessed++
    $stats.IndexesDiscovered += $newCount
    $stats.IndexesUpdated += $updateCount
    $stats.IndexesMarkedDropped += $droppedCount
    
    # Log to Index_ExecutionSummary
    if ($Execute) {
        $dbDuration = [int]((Get-Date) - $dbStartTime).TotalMilliseconds
        $dbStatus = "SUCCESS"
        $logQuery = "
            INSERT INTO ServerOps.Index_ExecutionSummary 
                (run_id, process_name, server_name, database_name, started_dttm, completed_dttm, duration_ms, items_processed, items_added, items_skipped, status)
            VALUES 
                ($runId, 'SYNC', '$($db.server_name)', '$($dbName -replace "'", "''")', '$($dbStartTime.ToString("yyyy-MM-dd HH:mm:ss"))', GETDATE(), $dbDuration, $updateCount, $newCount, $droppedCount, '$dbStatus')
        "
        Invoke-SqlNonQuery -Query $logQuery | Out-Null
    }
}

# ----------------------------------------------------------------------------
# Step 4: Summary
# ----------------------------------------------------------------------------

$scriptEnd = Get-Date
$duration = $scriptEnd - $scriptStart
$totalDurationMs = [int]$duration.TotalMilliseconds

Write-Log ""
Write-Log "================================================================"
Write-Log "  SUMMARY$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
Write-Log "================================================================"
Write-Log ""
Write-Log "  Databases Processed:    $($stats.DatabasesProcessed)"
Write-Log "  Databases Skipped:      $($stats.DatabasesSkipped)"
Write-Log "  Indexes Discovered:     $($stats.IndexesDiscovered)"
Write-Log "  Indexes Updated:        $($stats.IndexesUpdated)"
Write-Log "  Indexes Marked Dropped: $($stats.IndexesMarkedDropped)"
Write-Log "  Errors:                 $($stats.Errors)"
Write-Log ""
Write-Log "  Duration:               $($duration.ToString('mm\:ss'))"
Write-Log ""

# Final registry count
$finalCount = Get-SqlData -Query "
    SELECT 
        COUNT(*) AS total_indexes,
        SUM(CASE WHEN is_dropped = 0 THEN 1 ELSE 0 END) AS active_indexes,
        COUNT(DISTINCT database_id) AS databases_represented
    FROM ServerOps.Index_Registry
"

Write-Log "  Index_Registry Now Contains:"
Write-Log "    Total Entries:        $($finalCount.total_indexes)"
Write-Log "    Active Indexes:       $($finalCount.active_indexes)"
Write-Log "    Databases:            $($finalCount.databases_represented)"
Write-Log ""

# ----------------------------------------------------------------------------
# Step 5: Update Index_Status with completion
# ----------------------------------------------------------------------------

$durationSeconds = [int]$duration.TotalSeconds
$finalStatus = if ($stats.Errors -gt 0 -and $stats.DatabasesProcessed -gt 0) { 
    "PARTIAL" 
} elseif ($stats.Errors -gt 0) { 
    "FAILED" 
} elseif ($stats.DatabasesProcessed -eq 0) {
    "NO_WORK"
} else { 
    "SUCCESS" 
}

if ($Execute) {
    $completionResult = Invoke-SqlNonQuery -Query "
        UPDATE ServerOps.Index_Status
        SET completed_dttm = GETDATE(),
            last_status = '$finalStatus',
            last_duration_seconds = $durationSeconds,
            items_processed = $($stats.IndexesUpdated),
            items_added = $($stats.IndexesDiscovered),
            items_skipped = $($stats.IndexesMarkedDropped),
            items_failed = $($stats.Errors)
        WHERE process_name = 'SYNC'
    "
}

Write-Log "================================================================"
Write-Log "  Reconciliation Complete"
Write-Log "================================================================"
Write-Log ""

# ----------------------------------------
# Orchestrator Callback
# ----------------------------------------
if ($TaskId -gt 0) {
    $outputSummary = "DBs:$($stats.DatabasesProcessed) New:$($stats.IndexesDiscovered) Updated:$($stats.IndexesUpdated) Dropped:$($stats.IndexesMarkedDropped) Errors:$($stats.Errors)"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalDurationMs `
        -Output $outputSummary
}

if ($finalStatus -eq "FAILED") { exit 1 } else { exit 0 }
<#
.SYNOPSIS
    xFACts - Statistics Maintenance Execution

.DESCRIPTION
    xFACts - ServerOps.Index
    Script: Update-IndexStatistics.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Index)

    Updates statistics on indexes based on modification thresholds and staleness:
    - Queries sys.dm_db_stats_properties for modification counters
    - Updates statistics exceeding modification threshold (logged individually)
    - Updates stale statistics exceeding age threshold (logged as cumulative row per database)
    - Logs execution details to Index_StatsExecutionLog
    - Updates Index_Registry with new stats_last_updated timestamps

    Works from Index_Registry - only index statistics are processed.
    Table-level statistics not tied to indexes are not included.

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
    2026-01-22  Initial implementation
                Processes index statistics from Index_Registry
                MODIFICATION (individual) and STALENESS (cumulative) logging

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER ServerFilter
    Process only databases on specific server(s). Comma-separated.

.PARAMETER DatabaseFilter
    Process only specific database(s). Comma-separated.

.PARAMETER Force
    Override interval check and run even if STATS completed recently

.PARAMETER Execute
    Perform updates. Without this flag, runs in preview mode.

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
   - ALTER on statistics for UPDATE STATISTICS execution
   - Read/Write access to xFACts database
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
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

Initialize-XFActsScript -ScriptName 'Update-IndexStatistics' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# FUNCTIONS
# ============================================================================

function Get-AGPrimary {
    param([string]$ListenerName)
    
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
# MAIN
# ============================================================================

$scriptStart = Get-Date

Write-Log ""
Write-Log "================================================================"
Write-Log "  Statistics Maintenance Execution"
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
# Step 1: Check interval
# ----------------------------------------------------------------------------

Write-Log "Checking stats interval..."

$intervalConfig = Get-SqlData -Query "
    SELECT CAST(setting_value AS INT) AS interval_minutes
    FROM dbo.GlobalConfig
    WHERE module_name = 'ServerOps'
      AND category = 'Index'
      AND setting_name = 'stats_update_interval_minutes'
      AND is_active = 1
"
$statsIntervalMinutes = if ($intervalConfig) { $intervalConfig.interval_minutes } else { 1440 }

$lastStats = Get-SqlData -Query "
    SELECT completed_dttm, last_status
    FROM ServerOps.Index_Status
    WHERE process_name = 'STATS'
"

if (-not $Force -and $lastStats -and $lastStats.completed_dttm -isnot [DBNull] -and $lastStats.last_status -notin @('FAILED')) {
    $lastCompletedDttm = [DateTime]$lastStats.completed_dttm
    $minutesSinceStats = [math]::Round(((Get-Date) - $lastCompletedDttm).TotalMinutes)
    if ($minutesSinceStats -lt $statsIntervalMinutes) {
        Write-Log "STATS completed $minutesSinceStats minutes ago (interval: $statsIntervalMinutes). Use -Force to override." "WARN"
        if ($TaskId -gt 0) {
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs 0 `
                -Output "Skipped - within interval ($minutesSinceStats min ago)"
        }
        exit 0
    }
}

# Mark STATS as in progress (only if executing)
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
        WHERE process_name = 'STATS'
    "
}

# Get next run_id
$runIdResult = Get-SqlData -Query "
    SELECT ISNULL(MAX(run_id), 0) + 1 AS next_run_id 
    FROM ServerOps.Index_StatsExecutionLog
"
$runId = $runIdResult.next_run_id
Write-Log "Run ID: $runId"

# ----------------------------------------------------------------------------
# Step 2: Load configuration
# ----------------------------------------------------------------------------

Write-Log "Loading configuration settings..."

$configQuery = @"
    SELECT setting_name, setting_value, data_type 
    FROM dbo.GlobalConfig 
    WHERE module_name = 'ServerOps'
      AND category = 'Index'
      AND is_active = 1
"@
$configRows = Get-SqlData -Query $configQuery

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

$modificationThreshold = if ($config.ContainsKey('stats_modification_pct_threshold')) { $config['stats_modification_pct_threshold'] } else { 10 }
$minRows = if ($config.ContainsKey('stats_min_rows')) { $config['stats_min_rows'] } else { 1000 }
$maxDaysStale = if ($config.ContainsKey('stats_max_days_stale')) { $config['stats_max_days_stale'] } else { 30 }
$globalSamplePct = if ($config.ContainsKey('stats_sample_pct')) { $config['stats_sample_pct'] } else { 0 }

Write-Log "  Modification threshold: $modificationThreshold%"
Write-Log "  Min rows: $minRows"
Write-Log "  Max days stale: $maxDaysStale"
Write-Log "  Global sample %: $(if ($globalSamplePct -eq 0) { 'FULLSCAN' } else { "$globalSamplePct%" })"

# ----------------------------------------------------------------------------
# Step 3: Get target databases
# ----------------------------------------------------------------------------

Write-Log "Querying DatabaseRegistry for target databases..."

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
        END AS sql_instance,
        dc.stats_sample_pct
    FROM dbo.DatabaseRegistry dr
    JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
    LEFT JOIN ServerOps.Index_DatabaseConfig dc ON dr.database_id = dc.database_id
    WHERE dr.is_active = 1
      AND sr.is_active = 1
      AND sr.serverops_index_enabled = 1
      AND dc.stats_maintenance_enabled = 1
      $serverFilterClause
      $dbFilterClause
    ORDER BY dr.database_id
"

if (-not $targetDatabases) {
    Write-Log "No target databases found" "WARN"
    if ($Execute) {
        Invoke-SqlNonQuery -Query "
            UPDATE ServerOps.Index_Status
            SET completed_dttm = GETDATE(), last_status = 'NO_WORK', last_duration_seconds = 0
            WHERE process_name = 'STATS'
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

# Build server connection map (for AG primary detection)
$serverConnections = @{}
foreach ($db in $targetDatabases) {
    $serverKey = $db.server_name
    if (-not $serverConnections.ContainsKey($serverKey)) {
        if ($db.server_type -eq 'AG_LISTENER') {
            Write-Log "Detecting AG primary for listener: $($db.server_name)"
            $primary = Get-AGPrimary -ListenerName $db.sql_instance
            if ($primary) {
                $serverConnections[$serverKey] = $primary
                Write-Log "  Primary replica: $primary" "SUCCESS"
            } else {
                $serverConnections[$serverKey] = $db.sql_instance
                Write-Log "  Using listener directly" "WARN"
            }
        } else {
            $serverConnections[$serverKey] = $db.sql_instance
        }
    }
}

# ----------------------------------------------------------------------------
# Step 4: Process each database
# ----------------------------------------------------------------------------

Write-Log ""
Write-Log "Starting statistics maintenance..."
Write-Log ""

$stats = @{
    DatabasesProcessed = 0
    DatabasesSkipped = 0
    StatsEvaluated = 0
    ModificationUpdates = 0
    StalenessUpdates = 0
    Errors = 0
}

$dbIndex = 0
foreach ($db in $targetDatabases) {
    $dbIndex++
    $dbId = $db.database_id
    $dbName = $db.database_name
    $serverName = $db.server_name
    $connectionServer = $serverConnections[$serverName]
    $dbStartTime = Get-Date
    
    # Determine sample rate (database override or global)
    $samplePct = if ($null -ne $db.stats_sample_pct -and $db.stats_sample_pct -isnot [DBNull]) { 
        $db.stats_sample_pct 
    } else { 
        $globalSamplePct 
    }
    $sampleClause = if ($samplePct -eq 0) { "WITH FULLSCAN" } else { "WITH SAMPLE $samplePct PERCENT" }
    $sampleDisplay = if ($samplePct -eq 0) { "FULLSCAN" } else { "$samplePct%" }
    
    $serverDisplay = if ($db.server_type -eq 'AG_LISTENER') { "[AG] (via $connectionServer)" } else { "(via $connectionServer)" }
    Write-Log "[$dbIndex/$totalDatabases] $dbName $serverDisplay [$sampleDisplay]"
    
    # -------------------------------------------------------------------------
    # Step 4a: Get stats needing updates from source database
    # -------------------------------------------------------------------------
    
    # Query 1: Get registry entries for this database from xFACts
    $registryQuery = @"
SELECT 
    ir.registry_id,
    ir.schema_name,
    ir.table_name,
    ir.index_name AS stat_name,
    ir.stats_last_updated,
    DATEDIFF(DAY, ir.stats_last_updated, GETDATE()) AS days_since_update
FROM ServerOps.Index_Registry ir
WHERE ir.database_id = $dbId
  AND ir.is_dropped = 0
  AND ir.is_excluded = 0
"@
    
    $registryData = Get-SqlData -Query $registryQuery -Timeout 120
    
    if (-not $registryData) {
        Write-Log "  No registry entries" "DEBUG"
        $stats.DatabasesSkipped++
        continue
    }
    
    # Query 2: Get stats properties from target database (must run in target DB context)
    $statsPropsQuery = @"
SELECT 
    sch.name AS schema_name,
    o.name AS table_name,
    s.name AS stat_name,
    ddsp.rows AS table_rows,
    ddsp.modification_counter,
    CASE 
        WHEN ddsp.rows > 0 THEN CAST(ddsp.modification_counter AS DECIMAL(18,2)) / ddsp.rows * 100 
        ELSE 0 
    END AS pct_modified
FROM sys.stats s
JOIN sys.objects o ON s.object_id = o.object_id
JOIN sys.schemas sch ON o.schema_id = sch.schema_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) ddsp
WHERE o.type IN ('U', 'V')
  AND ddsp.rows >= $minRows
"@
    
    $statsPropsData = Get-SqlData -Instance $connectionServer -DatabaseName $dbName -Query $statsPropsQuery -Timeout 120
    
    if (-not $statsPropsData) {
        Write-Log "  No qualifying stats" "DEBUG"
        $stats.DatabasesSkipped++
        continue
    }
    
    # Build lookup hashtable from stats properties
    $statsPropsLookup = @{}
    foreach ($sp in $statsPropsData) {
        $key = "$($sp.schema_name)|$($sp.table_name)|$($sp.stat_name)"
        $statsPropsLookup[$key] = $sp
    }
    
    # Join registry with stats properties
    $statsData = @()
    foreach ($reg in $registryData) {
        $key = "$($reg.schema_name)|$($reg.table_name)|$($reg.stat_name)"
        if ($statsPropsLookup.ContainsKey($key)) {
            $sp = $statsPropsLookup[$key]
            $statsData += [PSCustomObject]@{
                registry_id = $reg.registry_id
                schema_name = $reg.schema_name
                table_name = $reg.table_name
                stat_name = $reg.stat_name
                stats_last_updated = $reg.stats_last_updated
                days_since_update = $reg.days_since_update
                table_rows = $sp.table_rows
                modification_counter = $sp.modification_counter
                pct_modified = $sp.pct_modified
            }
        }
    }
    
    if (-not $statsData) {
        Write-Log "  No qualifying stats" "DEBUG"
        $stats.DatabasesSkipped++
        continue
    }
    
    $statsArray = @($statsData)
    $stats.StatsEvaluated += $statsArray.Count
    
    # -------------------------------------------------------------------------
    # Step 4b: Identify stats needing MODIFICATION updates
    # -------------------------------------------------------------------------
    
    $modificationStats = $statsArray | Where-Object { $_.pct_modified -ge $modificationThreshold }
    $modCount = ($modificationStats | Measure-Object).Count
    
    # -------------------------------------------------------------------------
    # Step 4c: Identify stats needing STALENESS updates
    # -------------------------------------------------------------------------
    
    $stalenessStats = $statsArray | Where-Object { 
        $_.pct_modified -lt $modificationThreshold -and 
        $null -ne $_.days_since_update -and 
        $_.days_since_update -ge $maxDaysStale 
    }
    $staleCount = ($stalenessStats | Measure-Object).Count
    
    # -------------------------------------------------------------------------
    # Step 4d: Process MODIFICATION updates (individual logging)
    # -------------------------------------------------------------------------
    
    $dbModUpdates = 0
    $dbModErrors = 0
    
    foreach ($stat in $modificationStats) {
        $registryId = $stat.registry_id
        $schemaName = $stat.schema_name
        $tableName = $stat.table_name
        $statName = $stat.stat_name
        $rowCount = $stat.table_rows
        $modCounter = $stat.modification_counter
        $pctMod = [math]::Round($stat.pct_modified, 2)
        $daysSince = $stat.days_since_update
        
        $statStart = Get-Date
        
        if ($Execute) {
            # Insert IN_PROGRESS detail row
            $schemaEsc = $schemaName -replace "'", "''"
            $tableEsc = $tableName -replace "'", "''"
            $statEsc = $statName -replace "'", "''"
            $serverEsc = $serverName -replace "'", "''"
            $dbNameEsc = $dbName -replace "'", "''"
            
            $insertDetailQuery = @"
INSERT INTO ServerOps.Index_StatsExecutionLog (
    run_id, database_id, registry_id, update_type,
    server_name, database_name, schema_name, table_name, stat_name,
    rows_at_update, modification_counter, pct_modified, days_since_update,
    sample_pct_used, started_dttm, status
)
VALUES (
    $runId, $dbId, $registryId, 'MODIFICATION',
    '$serverEsc', '$dbNameEsc', '$schemaEsc', '$tableEsc', '$statEsc',
    $rowCount, $modCounter, $pctMod, $(if ($null -eq $daysSince) { 'NULL' } else { $daysSince }),
    $samplePct, GETDATE(), 'IN_PROGRESS'
);
SELECT SCOPE_IDENTITY() AS detail_id;
"@
            $detailResult = Get-SqlData -Query $insertDetailQuery
            $detailId = $detailResult.detail_id
            
            # Execute UPDATE STATISTICS
            $updateCmd = "UPDATE STATISTICS [$schemaName].[$tableName] [$statName] $sampleClause"
            $success = $false
            $errorMsg = $null
            
            try {
                Invoke-Sqlcmd -ServerInstance $connectionServer -Database $dbName -Query $updateCmd -QueryTimeout 300 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
                $success = $true
            }
            catch {
                $errorMsg = $_.Exception.Message -replace "'", "''"
                if ($errorMsg.Length -gt 4000) { $errorMsg = $errorMsg.Substring(0, 4000) }
            }
            
            $statEnd = Get-Date
            $durationMs = [int](($statEnd - $statStart).TotalMilliseconds)
            
            # Update detail row
            if ($success) {
                $updateDetailQuery = @"
UPDATE ServerOps.Index_StatsExecutionLog
SET completed_dttm = GETDATE(), duration_ms = $durationMs, status = 'SUCCESS'
WHERE detail_id = $detailId
"@
                Invoke-SqlNonQuery -Query $updateDetailQuery | Out-Null
                
                # Update registry
                $updateRegistryQuery = @"
UPDATE ServerOps.Index_Registry
SET stats_last_updated = GETDATE(), modified_dttm = GETDATE()
WHERE registry_id = $registryId
"@
                Invoke-SqlNonQuery -Query $updateRegistryQuery | Out-Null
                
                $dbModUpdates++
                $stats.ModificationUpdates++
            }
            else {
                $updateDetailQuery = @"
UPDATE ServerOps.Index_StatsExecutionLog
SET completed_dttm = GETDATE(), duration_ms = $durationMs, status = 'FAILED', error_message = '$errorMsg'
WHERE detail_id = $detailId
"@
                Invoke-SqlNonQuery -Query $updateDetailQuery | Out-Null
                $dbModErrors++
                $stats.Errors++
            }
        }
        else {
            # Preview mode
            $dbModUpdates++
            $stats.ModificationUpdates++
        }
    }
    
    # -------------------------------------------------------------------------
    # Step 4e: Process STALENESS updates (cumulative logging)
    # -------------------------------------------------------------------------
    
    $dbStaleUpdates = 0
    $dbStaleErrors = 0
    
    if ($staleCount -gt 0) {
        $staleStart = Get-Date
        $minStale = ($stalenessStats | Measure-Object -Property days_since_update -Minimum).Minimum
        $maxStale = ($stalenessStats | Measure-Object -Property days_since_update -Maximum).Maximum
        
        if ($Execute) {
            # Insert cumulative IN_PROGRESS row
            $dbNameEsc = $dbName -replace "'", "''"
            $serverEsc = $serverName -replace "'", "''"
            
            $insertCumulativeQuery = @"
INSERT INTO ServerOps.Index_StatsExecutionLog (
    run_id, database_id, registry_id, update_type,
    server_name, database_name, schema_name, table_name, stat_name,
    stats_count, min_days_stale, max_days_stale,
    sample_pct_used, started_dttm, status
)
VALUES (
    $runId, $dbId, NULL, 'STALENESS',
    '$serverEsc', '$dbNameEsc', NULL, NULL, NULL,
    $staleCount, $minStale, $maxStale,
    $samplePct, GETDATE(), 'IN_PROGRESS'
);
SELECT SCOPE_IDENTITY() AS detail_id;
"@
            $cumulativeResult = Get-SqlData -Query $insertCumulativeQuery
            $cumulativeDetailId = $cumulativeResult.detail_id
            
            # Process each stale stat
            $staleSuccessCount = 0
            $staleFailCount = 0
            
            foreach ($stat in $stalenessStats) {
                $schemaName = $stat.schema_name
                $tableName = $stat.table_name
                $statName = $stat.stat_name
                $registryId = $stat.registry_id
                
                $updateCmd = "UPDATE STATISTICS [$schemaName].[$tableName] [$statName] $sampleClause"
                
                try {
                    Invoke-Sqlcmd -ServerInstance $connectionServer -Database $dbName -Query $updateCmd -QueryTimeout 300 -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
                    
                    # Update registry
                    $updateRegistryQuery = @"
UPDATE ServerOps.Index_Registry
SET stats_last_updated = GETDATE(), modified_dttm = GETDATE()
WHERE registry_id = $registryId
"@
                    Invoke-SqlNonQuery -Query $updateRegistryQuery | Out-Null
                    
                    $staleSuccessCount++
                }
                catch {
                    $staleFailCount++
                }
            }
            
            $staleEnd = Get-Date
            $staleDurationMs = [int](($staleEnd - $staleStart).TotalMilliseconds)
            
            # Update cumulative row
            $cumulativeStatus = if ($staleFailCount -eq 0) { 'SUCCESS' } 
                                elseif ($staleSuccessCount -gt 0) { 'PARTIAL' } 
                                else { 'FAILED' }
            
            $updateCumulativeQuery = @"
UPDATE ServerOps.Index_StatsExecutionLog
SET completed_dttm = GETDATE(), 
    duration_ms = $staleDurationMs, 
    status = '$cumulativeStatus',
    stats_count = $staleSuccessCount
WHERE detail_id = $cumulativeDetailId
"@
            Invoke-SqlNonQuery -Query $updateCumulativeQuery | Out-Null
            
            $dbStaleUpdates = $staleSuccessCount
            $stats.StalenessUpdates += $staleSuccessCount
            if ($staleFailCount -gt 0) {
                $stats.Errors += $staleFailCount
            }
        }
        else {
            # Preview mode
            $dbStaleUpdates = $staleCount
            $stats.StalenessUpdates += $staleCount
        }
    }
    
    # -------------------------------------------------------------------------
    # Step 4f: Display per-database summary
    # -------------------------------------------------------------------------
    
    $totalUpdates = $dbModUpdates + $dbStaleUpdates
    $resultParts = @()
    if ($modCount -gt 0) { $resultParts += "$dbModUpdates mod" }
    if ($staleCount -gt 0) { $resultParts += "$dbStaleUpdates stale" }
    if ($dbModErrors -gt 0 -or $dbStaleErrors -gt 0) { $resultParts += "$($dbModErrors + $dbStaleErrors) errors" }
    
    if ($resultParts.Count -eq 0) {
        Write-Log "  No updates needed" "DEBUG"
    }
    else {
        Write-Log "  Results: $($resultParts -join ', ')" $(if ($totalUpdates -gt 0) { "SUCCESS" } else { "WARN" })
    }
    
    $stats.DatabasesProcessed++
    
    # -------------------------------------------------------------------------
    # Step 4g: Log to Index_ExecutionSummary
    # -------------------------------------------------------------------------
    
    if ($Execute) {
        $dbDuration = [int]((Get-Date) - $dbStartTime).TotalMilliseconds
        $dbStatus = if ($dbModErrors -gt 0 -or $dbStaleErrors -gt 0) { 
            if ($totalUpdates -gt 0) { "PARTIAL" } else { "FAILED" }
        } else { 
            "SUCCESS" 
        }
        
        $logQuery = @"
INSERT INTO ServerOps.Index_ExecutionSummary 
    (run_id, process_name, server_name, database_name, started_dttm, completed_dttm, duration_ms, 
     items_processed, items_added, items_skipped, items_failed, status)
VALUES 
    ($runId, 'STATS', '$serverName', '$($dbName -replace "'", "''")', 
     '$($dbStartTime.ToString("yyyy-MM-dd HH:mm:ss"))', GETDATE(), $dbDuration, 
     $($statsArray.Count), $totalUpdates, 0, $($dbModErrors + $dbStaleErrors), '$dbStatus')
"@
        Invoke-SqlNonQuery -Query $logQuery | Out-Null
    }
}

# ----------------------------------------------------------------------------
# Step 5: Final Summary
# ----------------------------------------------------------------------------

$scriptEnd = Get-Date
$duration = $scriptEnd - $scriptStart
$totalDurationMs = [int]$duration.TotalMilliseconds

$durationDisplay = if ($duration.TotalHours -ge 1) {
    "{0}:{1:D2}:{2:D2}" -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds
} else {
    "{0:D2}:{1:D2}" -f $duration.Minutes, $duration.Seconds
}

Write-Log ""
Write-Log "================================================================"
Write-Log "  SUMMARY$(if (-not $Execute) { ' [PREVIEW - No changes made]' })"
Write-Log "================================================================"
Write-Log ""
Write-Log "  Databases Processed:    $($stats.DatabasesProcessed)"
Write-Log "  Databases Skipped:      $($stats.DatabasesSkipped)"
Write-Log ""
Write-Log "  Stats Evaluated:        $($stats.StatsEvaluated)"
Write-Log "  Modification Updates:   $($stats.ModificationUpdates)"
Write-Log "  Staleness Updates:      $($stats.StalenessUpdates)"
Write-Log ""
Write-Log "  Errors:                 $($stats.Errors)"
Write-Log ""
Write-Log "  Duration:               $durationDisplay"
Write-Log ""

# ----------------------------------------------------------------------------
# Step 6: Update Index_Status
# ----------------------------------------------------------------------------

$durationSeconds = [int]$duration.TotalSeconds
$totalUpdates = $stats.ModificationUpdates + $stats.StalenessUpdates

$finalStatus = if ($stats.Errors -gt 0 -and $totalUpdates -gt 0) { 
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
            items_processed = $($stats.StatsEvaluated),
            items_added = $totalUpdates,
            items_skipped = 0,
            items_failed = $($stats.Errors)
        WHERE process_name = 'STATS'
    "
    
    Write-Log "Index_Status updated: $finalStatus" "SUCCESS"
}

Write-Log ""
Write-Log "================================================================"
Write-Log "  Statistics Maintenance Complete"
Write-Log "================================================================"
Write-Log ""

# ----------------------------------------
# Orchestrator Callback
# ----------------------------------------
if ($TaskId -gt 0) {
    $outputSummary = "Evaluated:$($stats.StatsEvaluated) Mod:$($stats.ModificationUpdates) Stale:$($stats.StalenessUpdates) Errors:$($stats.Errors)"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalDurationMs `
        -Output $outputSummary
}

if ($finalStatus -eq "FAILED") { exit 1 } else { exit 0 }
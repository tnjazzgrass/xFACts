<#
.SYNOPSIS
    xFACts - Index Fragmentation Scan & Queue Population

.DESCRIPTION
    xFACts - ServerOps.Index
    Script: Scan-IndexFragmentation.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.Index)

    Performs the "expensive pass" of index maintenance:
    - Queries sys.dm_db_index_physical_stats for fragmentation data
    - Updates Index_Registry with current fragmentation percentages
    - Adds qualifying indexes to Index_Queue with priority scores
    - Updates existing queue entries with refreshed data
    - Removes queue entries that no longer qualify

    Combines scanning and queue population into a single "living queue" approach.

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
    2026-01-21  xFACts Refactoring - Phase 3/8
                Table references updated to Index_* naming
                GlobalConfig-based settings, server-level master switch
    2026-01-15  Fixed queue lookup to include ALL statuses
                Prevents duplicate queue entries for same index
    2026-01-14  Integrated with xFACts-IndexFunctions.ps1
                Added startup abort check
    2026-01-13  Maintenance component refactor
                Updated table references (Index_* to Maintenance_*)
    2026-01-10  Initial PowerShell implementation for Index Maintenance 2.0
                Scans dm_db_index_physical_stats with scaled timeouts
                Maintains living queue with priority scoring

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER ServerFilter
    Process only databases on specific server(s). Comma-separated.

.PARAMETER DatabaseFilter
    Process only specific database(s). Comma-separated.

.PARAMETER Force
    Override interval check and run even if SCAN completed recently

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
3. xFACts-IndexFunctions.ps1 must be in the same directory (hard dependency).
4. The service account running this script needs:
   - Read access to all enrolled databases on all monitored servers
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

Initialize-XFActsScript -ScriptName 'Scan-IndexFragmentation' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# Dot-source shared index functions (hard dependency - must be after OrchestratorFunctions)
. "$PSScriptRoot\xFACts-IndexFunctions.ps1"

# ============================================================================
# FUNCTIONS
# ============================================================================

function Calculate-PriorityScore {
    param(
        [int]$DatabasePriority,
        [decimal]$FragmentationPct,
        [bigint]$PageCount,
        [int]$DeferralCount,
        [hashtable]$Config
    )
    
    $score = 0
    
    # Component 1: Database Priority (40/25/15)
    switch ($DatabasePriority) {
        1 { $score += [int]$Config['index_maintenance_priority_1_score'] }
        2 { $score += [int]$Config['index_maintenance_priority_2_score'] }
        3 { $score += [int]$Config['index_maintenance_priority_3_score'] }
        default { $score += [int]$Config['index_maintenance_priority_3_score'] }
    }
    
    # Component 2: Fragmentation Score (10/15/20)
    $fragLowMax = [int]$Config['index_frag_low_max']
    $fragMedMax = [int]$Config['index_frag_med_max']
    
    if ($FragmentationPct -ge $fragMedMax) {
        $score += [int]$Config['index_frag_high_score']
    }
    elseif ($FragmentationPct -ge $fragLowMax) {
        $score += [int]$Config['index_frag_med_score']
    }
    else {
        $score += [int]$Config['index_frag_low_score']
    }
    
    # Component 3: Page Count Score (10/20/30)
    $pageSmallMax = [int]$Config['index_page_small_max']
    $pageMedMax = [int]$Config['index_page_medium_max']
    
    if ($PageCount -ge $pageMedMax) {
        $score += [int]$Config['index_page_large_score']
    }
    elseif ($PageCount -ge $pageSmallMax) {
        $score += [int]$Config['index_page_medium_score']
    }
    else {
        $score += [int]$Config['index_page_small_score']
    }
    
    # Component 4: Deferral Score (5 base, 10 if >= threshold)
    $deferralThreshold = [int]$Config['index_deferral_threshold']
    
    if ($DeferralCount -ge $deferralThreshold) {
        $score += [int]$Config['index_deferral_max_score']
    }
    elseif ($DeferralCount -gt 0) {
        $score += [int]$Config['index_deferral_base_score']
    }
    
    return $score
}

# ============================================================================
# MAIN
# ============================================================================

$scriptStart = Get-Date

Write-Log ""
Write-Log "================================================================"
Write-Log "  Index Fragmentation Scan & Queue Population"
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
# Step 1: Check interval and update Index_Status
# ----------------------------------------------------------------------------

Write-Log "Checking scan interval..."

# Get scan interval from GlobalConfig
$intervalConfig = Get-SqlData -Query "
    SELECT CAST(setting_value AS INT) AS interval_minutes
    FROM dbo.GlobalConfig
    WHERE module_name = 'ServerOps'
      AND category = 'Index'
      AND setting_name = 'index_scan_interval_minutes'
      AND is_active = 1
"
$scanIntervalMinutes = if ($intervalConfig) { $intervalConfig.interval_minutes } else { 10080 }

# Check last SCAN completion
$lastScan = Get-SqlData -Query "
    SELECT completed_dttm, last_status
    FROM ServerOps.Index_Status
    WHERE process_name = 'SCAN'
"

if (-not $Force -and $lastScan -and $lastScan.completed_dttm -isnot [DBNull] -and $lastScan.last_status -notin @('FAILED', 'ABORTED')) {
    $lastCompletedDttm = [DateTime]$lastScan.completed_dttm
    $minutesSinceScan = [math]::Round(((Get-Date) - $lastCompletedDttm).TotalMinutes)
    if ($minutesSinceScan -lt $scanIntervalMinutes) {
        Write-Log "SCAN completed $minutesSinceScan minutes ago (interval: $scanIntervalMinutes). Use -Force to override." "WARN"
        if ($TaskId -gt 0) {
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs 0 `
                -Output "Skipped - within interval ($minutesSinceScan min ago)"
        }
        exit 0
    }
}

# Mark SCAN as in progress (only if executing)
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
        WHERE process_name = 'SCAN'
    "
}

# Get next run_id for Index_ExecutionSummary
$runIdResult = Get-SqlData -Query "
    SELECT ISNULL(MAX(run_id), 0) + 1 AS next_run_id 
    FROM ServerOps.Index_ExecutionSummary
    WHERE process_name = 'SCAN'
"
$runId = $runIdResult.next_run_id
Write-Log "Run ID: $runId"

# ----------------------------------------------------------------------------
# Step 2: Cache configuration settings
# ----------------------------------------------------------------------------

Write-Log "Loading configuration settings..."

$configQuery = @"
    SELECT setting_name, setting_value
    FROM dbo.GlobalConfig
    WHERE module_name = 'ServerOps'
      AND category = 'Index'
      AND is_active = 1
      AND (setting_name LIKE 'index_%' OR setting_name LIKE 'stats_%')
"@

$configRows = Get-SqlData -Query $configQuery

$config = @{}
foreach ($row in $configRows) {
    $config[$row.setting_name] = $row.setting_value
}

# Extract commonly used values with defaults
$skipRebuiltDays = if ($config['index_scan_skip_rebuilt_days']) { [int]$config['index_scan_skip_rebuilt_days'] } else { 3 }
$rescanIntervalDays = if ($config['index_rescan_interval_days']) { [int]$config['index_rescan_interval_days'] } else { 7 }
$fragThreshold = if ($config['index_fragmentation_threshold']) { [decimal]$config['index_fragmentation_threshold'] } else { 15.00 }
$minPageCount = if ($config['index_min_page_count']) { [int]$config['index_min_page_count'] } else { 1000 }
$timeLimitMinutes = if ($config['index_scan_time_limit_minutes']) { [int]$config['index_scan_time_limit_minutes'] } else { 0 }
$batchCheckSize = if ($config['index_scan_batch_check_size']) { [int]$config['index_scan_batch_check_size'] } else { 50 }
$secondsPerPageOnline = if ($config['index_seconds_per_page_online']) { [decimal]$config['index_seconds_per_page_online'] } else { 0.0005 }
$secondsPerPageOffline = if ($config['index_seconds_per_page_offline']) { [decimal]$config['index_seconds_per_page_offline'] } else { 0.00025 }

# Scaled timeout settings
$scanTimeoutBase = if ($config['index_scan_timeout_base_seconds']) { [int]$config['index_scan_timeout_base_seconds'] } else { 60 }
$scanPagesPerSecond = if ($config['index_scan_pages_per_second']) { [int]$config['index_scan_pages_per_second'] } else { 200000 }

Write-Log "  Skip rebuilt days: $skipRebuiltDays"
Write-Log "  Rescan interval days: $rescanIntervalDays"
Write-Log "  Fragmentation threshold: $fragThreshold%"
Write-Log "  Min page count: $minPageCount"
Write-Log "  Time limit: $(if ($timeLimitMinutes -eq 0) { 'Unlimited' } else { "$timeLimitMinutes minutes" })"
Write-Log "  Batch check size: $batchCheckSize"
Write-Log "  Scan timeout: ${scanTimeoutBase}s base + pages/$scanPagesPerSecond"

# ----------------------------------------------------------------------------
# Check for Abort Flag at Startup
# ----------------------------------------------------------------------------
if ($Execute -and (Test-AbortRequested -ServerInstance $ServerInstance -Database $Database -SettingName 'index_scan_abort')) {
    Write-Log "Abort flag (index_scan_abort) is set to 1 - exiting without processing" "WARN"
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
# Step 3: Get target databases from DatabaseRegistry + Index_DatabaseConfig
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
        dc.index_maintenance_priority,
        dc.index_fragmentation_threshold,
        dc.index_min_page_count,
        dc.index_allow_offline_rebuild
    FROM dbo.DatabaseRegistry dr
    JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
    LEFT JOIN ServerOps.Index_DatabaseConfig dc ON dr.database_id = dc.database_id
    WHERE dr.is_active = 1
      AND sr.is_active = 1
      AND sr.serverops_index_enabled = 1
      AND dc.index_maintenance_enabled = 1
      $serverFilterClause
      $dbFilterClause
    ORDER BY dr.database_id
"

if (-not $targetDatabases) {
    Write-Log "No target databases found. Check DatabaseRegistry enrollment." "WARN"
    if ($Execute) {
        Invoke-SqlNonQuery -Query "
            UPDATE ServerOps.Index_Status
            SET completed_dttm = GETDATE(),
                last_status = 'NO_WORK',
                last_duration_seconds = 0,
                items_processed = 0, items_added = 0, items_skipped = 0, items_failed = 0
            WHERE process_name = 'SCAN'
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
Write-Log "Found $totalDatabases database(s) to process"

# ----------------------------------------------------------------------------
# Step 4: Determine AG Primary Replicas
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
# Step 5: Initialize tracking variables
# ----------------------------------------------------------------------------

$stats = @{
    DatabasesProcessed = 0
    DatabasesSkipped = 0
    IndexesScanned = 0
    IndexesAddedToQueue = 0
    IndexesUpdatedInQueue = 0
    IndexesRemovedFromQueue = 0
    IndexesSkippedInProgress = 0
    Errors = 0
}

$abortRequested = $false
$timeLimitReached = $false
$batchCounter = 0

# ----------------------------------------------------------------------------
# Step 6: Database processing loop
# ----------------------------------------------------------------------------

Write-Log "Beginning fragmentation scan..."
Write-Log ""

$dbCount = 0
foreach ($db in $targetDatabases) {
    $dbCount++
    $dbId = $db.database_id
    $dbName = $db.database_name
    $serverName = $db.server_name
    $dbPriority = if ($db.index_maintenance_priority) { $db.index_maintenance_priority } else { 3 }
    $dbFragThreshold = if ($db.index_fragmentation_threshold -and $db.index_fragmentation_threshold -isnot [DBNull]) { 
        [decimal]$db.index_fragmentation_threshold 
    } else { 
        $fragThreshold 
    }
    $dbMinPageCount = if ($db.index_min_page_count -and $db.index_min_page_count -isnot [DBNull]) { 
        [int]$db.index_min_page_count 
    } else { 
        $minPageCount 
    }
    $allowOffline = if ($db.index_allow_offline_rebuild) { $db.index_allow_offline_rebuild } else { $false }
    
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
    # Step 6a: Check abort flag and time limit
    # -------------------------------------------------------------------------
    
    if ($batchCounter -ge $batchCheckSize) {
        $batchCounter = 0
        
        # Check abort flag
        if (Test-AbortRequested -ServerInstance $ServerInstance -Database $Database -SettingName 'index_scan_abort') {
            Write-Log "Abort flag detected - stopping scan" "WARN"
            $abortRequested = $true
            break
        }
        
        # Check time limit
        if ($timeLimitMinutes -gt 0) {
            $elapsedMinutes = ((Get-Date) - $scriptStart).TotalMinutes
            if ($elapsedMinutes -ge $timeLimitMinutes) {
                Write-Log "Time limit reached ($timeLimitMinutes minutes) - stopping scan" "WARN"
                $timeLimitReached = $true
                break
            }
        }
    }
    
    # -------------------------------------------------------------------------
    # Step 6b: Get scan candidates from Index_Registry
    # -------------------------------------------------------------------------
    
    $candidateQuery = @"
        SELECT 
            registry_id,
            schema_name,
            table_name,
            index_name,
            index_id,
            current_page_count,
            current_fragmentation_pct
        FROM ServerOps.Index_Registry
        WHERE database_id = $dbId
          AND is_dropped = 0
          AND is_excluded = 0
          AND (current_page_count >= $dbMinPageCount OR current_page_count IS NULL)
          AND (last_scanned_dttm IS NULL 
               OR last_scanned_dttm < DATEADD(DAY, -$rescanIntervalDays, GETDATE()))
          AND (last_rebuild_dttm IS NULL 
               OR last_rebuild_dttm < DATEADD(DAY, -$skipRebuiltDays, GETDATE()))
        ORDER BY schema_name, table_name, index_name
"@
    
    $candidates = Get-SqlData -Query $candidateQuery
    
    if (-not $candidates -or ($candidates -is [Array] -and $candidates.Count -eq 0)) {
        Write-Log "  No candidates" "DEBUG"
        
        # Still log to Index_ExecutionSummary
        if ($Execute) {
            $dbDuration = [int]((Get-Date) - $dbStartTime).TotalMilliseconds
            $logQuery = "
                INSERT INTO ServerOps.Index_ExecutionSummary 
                    (run_id, process_name, server_name, database_name, started_dttm, completed_dttm, duration_ms, 
                     items_processed, items_added, items_skipped, items_failed, status)
                VALUES 
                    ($runId, 'SCAN', '$serverName', '$($dbName -replace "'", "''")', 
                     '$($dbStartTime.ToString("yyyy-MM-dd HH:mm:ss"))', GETDATE(), $dbDuration, 
                     0, 0, 0, 0, 'NO_WORK')
            "
            Invoke-SqlNonQuery -Query $logQuery | Out-Null
        }
        
        $stats.DatabasesProcessed++
        continue
    }
    
    $candidateCount = if ($candidates -is [Array]) { $candidates.Count } else { 1 }
    if ($candidates -isnot [Array]) { $candidates = @($candidates) }
    
    # -------------------------------------------------------------------------
    # Step 6c: Get existing queue entries for this database (ALL statuses)
    # -------------------------------------------------------------------------
    
    $queueQuery = @"
        SELECT 
            queue_id,
            registry_id,
            status,
            deferral_count
        FROM ServerOps.Index_Queue
        WHERE database_id = $dbId
"@
    
    $existingQueue = Get-SqlData -Query $queueQuery
    
    $queueLookup = @{}
    if ($existingQueue) {
        if ($existingQueue -isnot [Array]) { $existingQueue = @($existingQueue) }
        foreach ($q in $existingQueue) {
            $queueLookup[$q.registry_id] = @{
                queue_id = $q.queue_id
                status = $q.status
                deferral_count = $q.deferral_count
            }
        }
    }
    
    # -------------------------------------------------------------------------
    # Step 6d: Initialize per-database counters
    # -------------------------------------------------------------------------
    
    $dbScanned = 0
    $dbAddedToQueue = 0
    $dbUpdatedInQueue = 0
    $dbRemovedFromQueue = 0
    $dbSkippedInProgress = 0
    $dbErrors = 0
    $scannedRegistryIds = @{}
    
    # -------------------------------------------------------------------------
    # Step 6e: Scan each candidate
    # -------------------------------------------------------------------------
    
    foreach ($candidate in $candidates) {
        
        $registryId = $candidate.registry_id
        $schemaName = $candidate.schema_name
        $tableName = $candidate.table_name
        $indexName = $candidate.index_name
        $indexId = $candidate.index_id
        $pageCount = if ($candidate.current_page_count -and $candidate.current_page_count -isnot [DBNull]) { 
            [bigint]$candidate.current_page_count 
        } else { 
            0 
        }
        
        $scannedRegistryIds[$registryId] = $true
        
        # Check abort flag periodically
        $batchCounter++
        if ($batchCounter -ge $batchCheckSize) {
            $batchCounter = 0
            
            if (Test-AbortRequested -ServerInstance $ServerInstance -Database $Database -SettingName 'index_scan_abort') {
                Write-Log "Abort flag detected - stopping scan" "WARN"
                $abortRequested = $true
                break
            }
            
            if ($timeLimitMinutes -gt 0) {
                $elapsedMinutes = ((Get-Date) - $scriptStart).TotalMinutes
                if ($elapsedMinutes -ge $timeLimitMinutes) {
                    Write-Log "Time limit reached ($timeLimitMinutes minutes) - stopping scan" "WARN"
                    $timeLimitReached = $true
                    break
                }
            }
        }
        
        # Calculate scaled timeout based on page count
        $indexTimeout = $scanTimeoutBase + [int]([long]$pageCount / $scanPagesPerSecond)
        
        # Query fragmentation
        $fragQuery = @"
            SELECT TOP 1 avg_fragmentation_in_percent
            FROM sys.dm_db_index_physical_stats(
                DB_ID('$dbName'), 
                OBJECT_ID('$dbName.$schemaName.$tableName'),
                $indexId, 
                NULL, 
                'LIMITED'
            )
            WHERE index_level = 0
"@
        
        $fragResult = Get-SqlData -Instance $connectServer -DatabaseName $dbName -Query $fragQuery -Timeout $indexTimeout
        
        if (-not $fragResult) {
            $dbErrors++
            continue
        }
        
        $fragPct = if ($fragResult.avg_fragmentation_in_percent -isnot [DBNull]) {
            [math]::Round([decimal]$fragResult.avg_fragmentation_in_percent, 2)
        } else {
            0
        }
        
        $dbScanned++
        $stats.IndexesScanned++
        
        # Update Index_Registry with fragmentation
        if ($Execute) {
            $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $updateRegQuery = "
                UPDATE ServerOps.Index_Registry
                SET current_fragmentation_pct = $fragPct,
                    last_scanned_dttm = '$now',
                    modified_dttm = '$now'
                WHERE registry_id = $registryId
            "
            Invoke-SqlNonQuery -Query $updateRegQuery | Out-Null
        }
        
        # Evaluate queue action
        $inQueue = $queueLookup.ContainsKey($registryId)
        $currentStatus = if ($inQueue) { $queueLookup[$registryId].status } else { $null }
        $deferralCount = if ($inQueue) { $queueLookup[$registryId].deferral_count } else { 0 }
        
        # Skip IN_PROGRESS entries entirely - don't touch mid-rebuild
        if ($currentStatus -eq 'IN_PROGRESS') {
            $dbSkippedInProgress++
            $stats.IndexesSkippedInProgress++
            continue
        }
        
        if ($fragPct -ge $dbFragThreshold -and $pageCount -ge $dbMinPageCount) {
            # Qualifies for queue
            $priorityScore = Calculate-PriorityScore -DatabasePriority $dbPriority `
                -FragmentationPct $fragPct -PageCount $pageCount `
                -DeferralCount $deferralCount -Config $config
            
            # Fix: Cast to [long] before multiplying to avoid BigInteger × Decimal = 0 issue
            $estSecondsOnline = [bigint]([long]$pageCount * $secondsPerPageOnline)
            $estSecondsOffline = [bigint]([long]$pageCount * $secondsPerPageOffline)
            $onlineOption = if ($allowOffline) { 0 } else { 1 }
            
            if ($inQueue) {
                # UPDATE existing queue entry
                # For FAILED status, reset to PENDING; others keep their status
                $newStatus = if ($currentStatus -eq 'FAILED') { 'PENDING' } else { $currentStatus }
                
                if ($Execute) {
                    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    $updateQueueQuery = "
                        UPDATE ServerOps.Index_Queue
                        SET fragmentation_pct = $fragPct,
                            page_count = $pageCount,
                            estimated_seconds_online = $estSecondsOnline,
                            estimated_seconds_offline = $estSecondsOffline,
                            priority_score = $priorityScore,
                            status = '$newStatus',
                            last_evaluated_dttm = '$now'
                        WHERE registry_id = $registryId
                    "
                    Invoke-SqlNonQuery -Query $updateQueueQuery | Out-Null
                }
                $dbUpdatedInQueue++
                $stats.IndexesUpdatedInQueue++
            }
            else {
                # INSERT new queue entry
                if ($Execute) {
                    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    $schemaEsc = $schemaName -replace "'", "''"
                    $tableEsc = $tableName -replace "'", "''"
                    $indexEsc = $indexName -replace "'", "''"
                    
                    $insertQueueQuery = "
                        INSERT INTO ServerOps.Index_Queue (
                            registry_id, database_id, schema_name, table_name, index_name,
                            fragmentation_pct, page_count, 
                            estimated_seconds_online, estimated_seconds_offline,
                            operation_type, online_option, status, deferral_count, priority_score,
                            queued_dttm
                        )
                        VALUES (
                            $registryId, $dbId, '$schemaEsc', '$tableEsc', '$indexEsc',
                            $fragPct, $pageCount,
                            $estSecondsOnline, $estSecondsOffline,
                            'REBUILD', $onlineOption, 'PENDING', 0, $priorityScore,
                            '$now'
                        )
                    "
                    Invoke-SqlNonQuery -Query $insertQueueQuery | Out-Null
                }
                $dbAddedToQueue++
                $stats.IndexesAddedToQueue++
            }
        }
        else {
            # Below threshold - remove from queue if present (IN_PROGRESS already skipped above)
            if ($inQueue) {
                if ($Execute) {
                    $deleteQueueQuery = "
                        DELETE FROM ServerOps.Index_Queue
                        WHERE registry_id = $registryId
                    "
                    Invoke-SqlNonQuery -Query $deleteQueueQuery | Out-Null
                }
                $dbRemovedFromQueue++
                $stats.IndexesRemovedFromQueue++
            }
        }
    }
    
    # Check if we broke out of inner loop due to abort/time limit
    if ($abortRequested -or $timeLimitReached) {
        break
    }
    
    # -------------------------------------------------------------------------
    # Step 6f: Display per-database summary
    # -------------------------------------------------------------------------
    
    $resultParts = @()
    $resultParts += "$dbScanned scanned"
    if ($dbAddedToQueue -gt 0) { $resultParts += "$dbAddedToQueue queued" }
    if ($dbUpdatedInQueue -gt 0) { $resultParts += "$dbUpdatedInQueue updated" }
    if ($dbRemovedFromQueue -gt 0) { $resultParts += "$dbRemovedFromQueue removed" }
    if ($dbSkippedInProgress -gt 0) { $resultParts += "$dbSkippedInProgress in-progress" }
    if ($dbErrors -gt 0) { $resultParts += "$dbErrors errors" }
    
    Write-Log "  Results: $($resultParts -join ', ')" $(if ($dbErrors -gt 0) { "WARN" } else { "SUCCESS" })
    
    $stats.DatabasesProcessed++
    $stats.Errors += $dbErrors
    
    # -------------------------------------------------------------------------
    # Step 6g: Log to Index_ExecutionSummary
    # -------------------------------------------------------------------------
    
    if ($Execute) {
        $dbDuration = [int]((Get-Date) - $dbStartTime).TotalMilliseconds
        $dbStatus = if ($dbErrors -gt 0 -and $dbScanned -gt 0) { 
            "PARTIAL" 
        } elseif ($dbErrors -gt 0) { 
            "FAILED" 
        } else { 
            "SUCCESS" 
        }
        
        $logQuery = "
            INSERT INTO ServerOps.Index_ExecutionSummary 
                (run_id, process_name, server_name, database_name, started_dttm, completed_dttm, duration_ms, 
                 items_processed, items_added, items_skipped, items_failed, status)
            VALUES 
                ($runId, 'SCAN', '$serverName', '$($dbName -replace "'", "''")', 
                 '$($dbStartTime.ToString("yyyy-MM-dd HH:mm:ss"))', GETDATE(), $dbDuration, 
                 $dbScanned, $dbAddedToQueue, $dbRemovedFromQueue, $dbErrors, '$dbStatus')
        "
        Invoke-SqlNonQuery -Query $logQuery | Out-Null
    }
}

# ----------------------------------------------------------------------------
# Step 7: Final Summary
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
Write-Log "  Indexes Scanned:        $($stats.IndexesScanned)"
Write-Log "  Added to Queue:         $($stats.IndexesAddedToQueue)"
Write-Log "  Updated in Queue:       $($stats.IndexesUpdatedInQueue)"
Write-Log "  Removed from Queue:     $($stats.IndexesRemovedFromQueue)"
Write-Log "  Skipped (In-Progress):  $($stats.IndexesSkippedInProgress)"
Write-Log ""
Write-Log "  Errors:                 $($stats.Errors)"
Write-Log ""
Write-Log "  Duration:               $durationDisplay"

if ($abortRequested) {
    Write-Log "" "WARN"
    Write-Log "  *** SCAN ABORTED BY REQUEST ***" "WARN"
}
if ($timeLimitReached) {
    Write-Log "" "WARN"
    Write-Log "  *** SCAN STOPPED - TIME LIMIT REACHED ***" "WARN"
}

Write-Log ""

# Query current queue depth
$queueDepth = Get-SqlData -Query "
    SELECT 
        COUNT(*) AS total_queued,
        SUM(CASE WHEN status = 'PENDING' THEN 1 ELSE 0 END) AS pending,
        SUM(CASE WHEN status = 'DEFERRED' THEN 1 ELSE 0 END) AS deferred,
        SUM(CASE WHEN status = 'SCHEDULED' THEN 1 ELSE 0 END) AS scheduled,
        SUM(page_count) AS total_pages,
        SUM(estimated_seconds_offline) / 60 AS est_minutes_offline
    FROM ServerOps.Index_Queue
"

Write-Log "  Current Queue Status:"
Write-Log "    Total Queued:         $($queueDepth.total_queued)"
Write-Log "    Pending:              $($queueDepth.pending)"
Write-Log "    Deferred:             $($queueDepth.deferred)"
Write-Log "    Scheduled:            $($queueDepth.scheduled)"
Write-Log "    Total Pages:          $("{0:N0}" -f $queueDepth.total_pages)"
Write-Log "    Est. Duration (Offline): $($queueDepth.est_minutes_offline) minutes"

Write-Log ""

# ----------------------------------------------------------------------------
# Step 8: Update Index_Status
# ----------------------------------------------------------------------------

$durationSeconds = [int]$duration.TotalSeconds
$finalStatus = if ($abortRequested) { 
    "ABORTED" 
} elseif ($timeLimitReached) {
    "TIME_LIMIT"
} elseif ($stats.Errors -gt 0 -and $stats.DatabasesProcessed -gt 0) { 
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
            items_processed = $($stats.IndexesScanned),
            items_added = $($stats.IndexesAddedToQueue),
            items_skipped = $($stats.IndexesRemovedFromQueue),
            items_failed = $($stats.Errors)
        WHERE process_name = 'SCAN'
    "
    
    Write-Log "Index_Status updated: $finalStatus" "SUCCESS"
}

Write-Log "================================================================"
Write-Log "  Scan Complete"
Write-Log "================================================================"
Write-Log ""

# ----------------------------------------
# Orchestrator Callback
# ----------------------------------------
if ($TaskId -gt 0) {
    $outputSummary = "Scanned:$($stats.IndexesScanned) Queued:$($stats.IndexesAddedToQueue) Updated:$($stats.IndexesUpdatedInQueue) Removed:$($stats.IndexesRemovedFromQueue) Errors:$($stats.Errors)"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalDurationMs `
        -Output $outputSummary
}

if ($finalStatus -eq "FAILED") { exit 1 } else { exit 0 }
<#
.SYNOPSIS
    Provides the Index Maintenance dashboard's JSON API endpoints.

.DESCRIPTION
    API routes backing the Control Center Index Maintenance dashboard. Exposes
    read endpoints for live activity, process status, active rebuild execution,
    the index queue and its details, database health, and per-process run
    details, plus a per-database maintenance-schedule reader and writer and an
    admin-gated manual process launch. Read endpoints query the xFActs AG
    listener through the shared data-access helpers; the active-execution
    endpoint additionally reads live rebuild progress from each maintenance
    server's own session DMVs. Every endpoint runs the action-permission hook
    and returns JSON.

.COMPONENT
    ServerOps.Index

.NOTES
    File Name : IndexMaintenance-API.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\IndexMaintenance-API.ps1

    FILE ORGANIZATION
    -----------------
    ROUTE: API ENDPOINTS
#>

<# ============================================================================
   ROUTE: API ENDPOINTS
   ----------------------------------------------------------------------------
   Registers the GET and POST endpoints under /api/index, each gated by
   ADLogin authentication and the Test-ActionEndpoint permission hook and
   returning a JSON response. Read endpoints use Invoke-XFActsQuery against
   the AG listener; schedule writes use Invoke-XFActsNonQuery; active-execution
   reads per-server rebuild progress via Invoke-Sqlcmd against each server.
   Prefix: (none)
   ============================================================================ #>

# GET /api/index/live-activity
# Returns current running process info, or the last completed activity if idle.
Add-PodeRoute -Method Get -Path '/api/index/live-activity' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $running = Invoke-XFActsQuery -Query @"
            SELECT
                process_name,
                started_dttm,
                DATEDIFF(SECOND, started_dttm, GETDATE()) AS elapsed_seconds,
                items_processed,
                items_added
            FROM ServerOps.Index_Status
            WHERE last_status = 'IN_PROGRESS'
              AND started_dttm IS NOT NULL
            ORDER BY started_dttm ASC
"@

        $runningProcesses = @()
        foreach ($row in $running) {
            $processName = $row['process_name']
            $startedDttm = $row['started_dttm']
            $elapsedSeconds = [int]$row['elapsed_seconds']

            $completedCount = 0
            if ($processName -eq 'EXECUTE') {
                # EXECUTE updates items_added in real time; use it directly.
                $completedCount = if ($row['items_added'] -is [DBNull]) { 0 } else { [int]$row['items_added'] }
            }
            else {
                # SYNC/SCAN/STATS derive a live count from Index_Registry using
                # the column that the process advances as it runs.
                $countColumn = switch ($processName) {
                    'SYNC'  { 'usage_captured_dttm' }
                    'SCAN'  { 'last_scanned_dttm' }
                    'STATS' { 'stats_last_updated' }
                    default { $null }
                }
                if ($countColumn) {
                    $countQuery = @"
                        SELECT COUNT(*) AS cnt
                        FROM ServerOps.Index_Registry
                        WHERE $countColumn >= @since
"@
                    $countResult = Invoke-XFActsQuery -Query $countQuery -Parameters @{ since = $startedDttm }
                    if ($countResult.Count -gt 0) {
                        $cntVal = $countResult[0]['cnt']
                        $completedCount = if ($cntVal -is [DBNull]) { 0 } else { [int]$cntVal }
                    }
                }
            }

            $runningProcesses += [PSCustomObject]@{
                ProcessName = $processName
                StartedDttm = $startedDttm.ToString("yyyy-MM-dd HH:mm:ss")
                ElapsedSeconds = $elapsedSeconds
                CompletedCount = $completedCount
            }
        }

        $lastActivity = $null
        if ($runningProcesses.Count -eq 0) {
            $last = Invoke-XFActsQuery -Query @"
                SELECT TOP 1
                    process_name,
                    completed_dttm,
                    last_status,
                    items_processed,
                    items_added,
                    last_duration_seconds,
                    DATEDIFF(SECOND, completed_dttm, GETDATE()) AS seconds_ago
                FROM ServerOps.Index_Status
                WHERE completed_dttm IS NOT NULL
                ORDER BY completed_dttm DESC
"@
            if ($last.Count -gt 0) {
                $lastRow = $last[0]
                $lastActivity = [PSCustomObject]@{
                    ProcessName = $lastRow['process_name']
                    CompletedDttm = if ($lastRow['completed_dttm'] -is [DBNull]) { $null } else { $lastRow['completed_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                    LastStatus = $lastRow['last_status']
                    ItemsProcessed = if ($lastRow['items_processed'] -is [DBNull]) { 0 } else { [int]$lastRow['items_processed'] }
                    ItemsAdded = if ($lastRow['items_added'] -is [DBNull]) { 0 } else { [int]$lastRow['items_added'] }
                    DurationSeconds = if ($lastRow['last_duration_seconds'] -is [DBNull]) { 0 } else { [int]$lastRow['last_duration_seconds'] }
                    SecondsAgo = if ($lastRow['seconds_ago'] -is [DBNull]) { 0 } else { [int]$lastRow['seconds_ago'] }
                }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            IsRunning = ($runningProcesses.Count -gt 0)
            RunningProcesses = $runningProcesses
            LastActivity = $lastActivity
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/index/process-status
# Returns the status of all four index processes, with a per-process CanLaunch
# flag indicating whether the current user may manually launch it.
Add-PodeRoute -Method Get -Path '/api/index/process-status' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $ctx = Get-UserContext -WebEvent $WebEvent
        $canLaunch = [bool]$ctx.IsAdmin

        $rows = Invoke-XFActsQuery -Query @"
            SELECT
                process_name,
                started_dttm,
                completed_dttm,
                last_status,
                last_duration_seconds,
                items_processed,
                items_added,
                items_skipped,
                items_failed,
                last_error_message
            FROM ServerOps.Index_Status
            ORDER BY
                CASE process_name
                    WHEN 'SYNC' THEN 1
                    WHEN 'SCAN' THEN 2
                    WHEN 'EXECUTE' THEN 3
                    WHEN 'STATS' THEN 4
                END
"@

        $processes = @()
        foreach ($row in $rows) {
            $processes += [PSCustomObject]@{
                ProcessName = $row['process_name']
                StartedDttm = if ($row['started_dttm'] -is [DBNull]) { $null } else { $row['started_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                CompletedDttm = if ($row['completed_dttm'] -is [DBNull]) { $null } else { $row['completed_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                LastStatus = if ($row['last_status'] -is [DBNull]) { $null } else { $row['last_status'] }
                DurationSeconds = if ($row['last_duration_seconds'] -is [DBNull]) { $null } else { [int]$row['last_duration_seconds'] }
                ItemsProcessed = if ($row['items_processed'] -is [DBNull]) { 0 } else { [int]$row['items_processed'] }
                ItemsAdded = if ($row['items_added'] -is [DBNull]) { 0 } else { [int]$row['items_added'] }
                ItemsSkipped = if ($row['items_skipped'] -is [DBNull]) { 0 } else { [int]$row['items_skipped'] }
                ItemsFailed = if ($row['items_failed'] -is [DBNull]) { 0 } else { [int]$row['items_failed'] }
                LastErrorMessage = if ($row['last_error_message'] -is [DBNull]) { $null } else { $row['last_error_message'] }
                CanLaunch = $canLaunch
            }
        }

        Write-PodeJsonResponse -Value $processes
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/index/active-execution
# Returns real-time progress of any currently executing index rebuild by
# reading live session DMVs from each maintenance-enabled server.
Add-PodeRoute -Method Get -Path '/api/index/active-execution' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $statusRows = Invoke-XFActsQuery -Query @"
            SELECT last_status
            FROM ServerOps.Index_Status
            WHERE process_name = 'EXECUTE'
"@
        $executeStatus = if ($statusRows.Count -gt 0) { $statusRows[0]['last_status'] } else { $null }

        if ($executeStatus -ne 'IN_PROGRESS') {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{
                IsExecuting = $false
                ActiveRebuilds = @()
            })
            return
        }

        $servers = Invoke-XFActsQuery -Query @"
            SELECT DISTINCT sr.server_name
            FROM dbo.ServerRegistry sr
            WHERE sr.is_active = 1
              AND sr.serverops_index_enabled = 1
"@

        $activeRebuilds = @()

        foreach ($serverRow in $servers) {
            $serverName = $serverRow['server_name']

            try {
                # Per-server live rebuild progress comes from that server's own
                # session DMVs, so this targets each server directly rather than
                # the AG listener. Invoke-Sqlcmd carries -TrustServerCertificate
                # and -ApplicationName per the SQL connectivity rules.
                $progressQuery = @"
                    WITH agg AS
                    (
                        SELECT qp.session_id,
                               SUM(qp.[row_count]) AS [RowsProcessed],
                               SUM(qp.[estimate_row_count]) AS [TotalRows],
                               MAX(qp.last_active_time) - MIN(qp.first_active_time) AS [ElapsedMS],
                               MAX(IIF(qp.[close_time] = 0 AND qp.[first_row_time] > 0,
                                       [physical_operator_name],
                                       N'<Transition>')) AS [CurrentStep]
                        FROM sys.dm_exec_query_profiles qp
                        WHERE qp.[physical_operator_name] IN (N'Table Scan', N'Clustered Index Scan',
                                                              N'Index Scan', N'Sort')
                        AND qp.[session_id] IN (SELECT session_id FROM sys.dm_exec_requests
                                                WHERE command IN ('CREATE INDEX','ALTER INDEX','ALTER TABLE'))
                        GROUP BY qp.session_id
                    ), comp AS
                    (
                        SELECT *,
                               ([TotalRows] - [RowsProcessed]) AS [RowsLeft],
                               ([ElapsedMS] / 1000.0) AS [ElapsedSeconds]
                        FROM agg
                        WHERE [TotalRows] > 0
                    )
                    SELECT c.session_id,
                           LTRIM(RTRIM(SUBSTRING(t.text,
                               CHARINDEX('[', t.text) + 1,
                               CHARINDEX(']', t.text) - CHARINDEX('[', t.text) - 1))) AS [IndexName],
                           DB_NAME(r.database_id) AS [DatabaseName],
                           c.[CurrentStep],
                           c.[TotalRows],
                           c.[RowsProcessed],
                           c.[RowsLeft],
                           CONVERT(DECIMAL(5, 2),
                                   ((c.[RowsProcessed] * 1.0) / c.[TotalRows]) * 100) AS [PercentComplete],
                           c.[ElapsedSeconds],
                           CASE WHEN c.[RowsProcessed] > 0
                                THEN ((c.[ElapsedSeconds] / c.[RowsProcessed]) * c.[RowsLeft])
                                ELSE 0 END AS [EstimatedSecondsLeft],
                           CASE WHEN c.[RowsProcessed] > 0
                                THEN DATEADD(SECOND,
                                       ((c.[ElapsedSeconds] / c.[RowsProcessed]) * c.[RowsLeft]),
                                       GETDATE())
                                ELSE NULL END AS [EstimatedCompletionTime]
                    FROM comp c
                    JOIN sys.dm_exec_requests r ON c.session_id = r.session_id
                    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
"@

                $progressRows = Invoke-Sqlcmd -ServerInstance $serverName -Database 'master' `
                    -Query $progressQuery -QueryTimeout 10 `
                    -ApplicationName 'xFACts Control Center' -TrustServerCertificate -ErrorAction Stop

                foreach ($row in $progressRows) {
                    $activeRebuilds += [PSCustomObject]@{
                        ServerName = $serverName
                        DatabaseName = if ($row.DatabaseName -is [DBNull]) { 'Unknown' } else { $row.DatabaseName }
                        IndexName = if ($row.IndexName -is [DBNull]) { 'Unknown' } else { $row.IndexName }
                        CurrentStep = if ($row.CurrentStep -is [DBNull]) { 'Unknown' } else { $row.CurrentStep }
                        TotalRows = if ($row.TotalRows -is [DBNull]) { 0 } else { [long]$row.TotalRows }
                        RowsProcessed = if ($row.RowsProcessed -is [DBNull]) { 0 } else { [long]$row.RowsProcessed }
                        RowsLeft = if ($row.RowsLeft -is [DBNull]) { 0 } else { [long]$row.RowsLeft }
                        PercentComplete = if ($row.PercentComplete -is [DBNull]) { 0 } else { [decimal]$row.PercentComplete }
                        ElapsedSeconds = if ($row.ElapsedSeconds -is [DBNull]) { 0 } else { [decimal]$row.ElapsedSeconds }
                        EstimatedSecondsLeft = if ($row.EstimatedSecondsLeft -is [DBNull]) { 0 } else { [decimal]$row.EstimatedSecondsLeft }
                        EstimatedCompletionTime = if ($row.EstimatedCompletionTime -is [DBNull]) { $null } else { $row.EstimatedCompletionTime.ToString("yyyy-MM-dd HH:mm:ss") }
                    }
                }
            }
            catch {
                # Server unavailable - skip it.
            }
        }

        # Deduplicate the same rebuild seen via multiple connections.
        $uniqueRebuilds = @()
        if ($activeRebuilds.Count -gt 0) {
            $seen = @{}
            foreach ($rebuild in $activeRebuilds) {
                $key = "$($rebuild.DatabaseName)|$($rebuild.IndexName)|$($rebuild.TotalRows)"
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    $uniqueRebuilds += $rebuild
                }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            IsExecuting = $true
            ActiveRebuilds = $uniqueRebuilds
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/index/queue-summary
# Returns per-status counts and totals for the index queue.
Add-PodeRoute -Method Get -Path '/api/index/queue-summary' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
            WITH QueueSummary AS (
                SELECT
                    status,
                    COUNT(*) AS item_count,
                    SUM(page_count) AS total_pages,
                    SUM(estimated_seconds_online) AS total_seconds_online,
                    SUM(estimated_seconds_offline) AS total_seconds_offline,
                    MAX(deferral_count) AS max_deferrals
                FROM ServerOps.Index_Queue
                GROUP BY status

                UNION ALL

                SELECT
                    'TOTAL' AS status,
                    COUNT(*) AS item_count,
                    SUM(page_count) AS total_pages,
                    SUM(estimated_seconds_online) AS total_seconds_online,
                    SUM(estimated_seconds_offline) AS total_seconds_offline,
                    MAX(deferral_count) AS max_deferrals
                FROM ServerOps.Index_Queue
            )
            SELECT * FROM QueueSummary
            ORDER BY
                CASE status
                    WHEN 'PENDING' THEN 1
                    WHEN 'IN_PROGRESS' THEN 2
                    WHEN 'SCHEDULED' THEN 3
                    WHEN 'DEFERRED' THEN 4
                    WHEN 'FAILED' THEN 5
                    WHEN 'TOTAL' THEN 99
                END
"@

        $summary = @()
        foreach ($row in $rows) {
            $summary += [PSCustomObject]@{
                Status = $row['status']
                ItemCount = if ($row['item_count'] -is [DBNull]) { 0 } else { [int]$row['item_count'] }
                TotalPages = if ($row['total_pages'] -is [DBNull]) { 0 } else { [long]$row['total_pages'] }
                TotalSecondsOnline = if ($row['total_seconds_online'] -is [DBNull]) { 0 } else { [long]$row['total_seconds_online'] }
                TotalSecondsOffline = if ($row['total_seconds_offline'] -is [DBNull]) { 0 } else { [long]$row['total_seconds_offline'] }
                MaxDeferrals = if ($row['max_deferrals'] -is [DBNull]) { 0 } else { [int]$row['max_deferrals'] }
            }
        }

        Write-PodeJsonResponse -Value $summary
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/index/queue-details
# Returns all items in the index queue with server/database context.
Add-PodeRoute -Method Get -Path '/api/index/queue-details' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
            SELECT
                q.queue_id,
                sr.server_name,
                dr.database_name,
                q.schema_name,
                q.table_name,
                q.index_name,
                q.fragmentation_pct,
                q.page_count,
                q.estimated_seconds_online,
                q.estimated_seconds_offline,
                q.operation_type,
                q.online_option,
                q.status,
                q.deferral_count,
                q.priority_score,
                q.queued_dttm
            FROM ServerOps.Index_Queue q
            JOIN dbo.DatabaseRegistry dr ON q.database_id = dr.database_id
            JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
            ORDER BY q.priority_score DESC, q.page_count DESC
"@

        $items = @()
        foreach ($row in $rows) {
            $items += [PSCustomObject]@{
                QueueId = [int]$row['queue_id']
                ServerName = $row['server_name']
                DatabaseName = $row['database_name']
                SchemaName = $row['schema_name']
                TableName = $row['table_name']
                IndexName = $row['index_name']
                FragmentationPct = if ($row['fragmentation_pct'] -is [DBNull]) { 0 } else { [decimal]$row['fragmentation_pct'] }
                PageCount = if ($row['page_count'] -is [DBNull]) { 0 } else { [long]$row['page_count'] }
                EstimatedSecondsOnline = if ($row['estimated_seconds_online'] -is [DBNull]) { 0 } else { [long]$row['estimated_seconds_online'] }
                EstimatedSecondsOffline = if ($row['estimated_seconds_offline'] -is [DBNull]) { 0 } else { [long]$row['estimated_seconds_offline'] }
                OperationType = $row['operation_type']
                OnlineOption = [bool]$row['online_option']
                Status = $row['status']
                DeferralCount = if ($row['deferral_count'] -is [DBNull]) { 0 } else { [int]$row['deferral_count'] }
                PriorityScore = if ($row['priority_score'] -is [DBNull]) { 0 } else { [int]$row['priority_score'] }
                QueuedDttm = if ($row['queued_dttm'] -is [DBNull]) { $null } else { $row['queued_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
            }
        }

        Write-PodeJsonResponse -Value $items
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/index/database-health
# Returns aggregated index-health metrics by server/database, including the
# maintenance-mode flags used for grouping on the dashboard.
Add-PodeRoute -Method Get -Path '/api/index/database-health' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $thresholdRows = Invoke-XFActsQuery -Query @"
            SELECT CAST(setting_value AS DECIMAL(5,2)) AS frag_threshold
            FROM dbo.GlobalConfig
            WHERE module_name = 'ServerOps'
              AND category = 'Index'
              AND setting_name = 'index_frag_threshold'
              AND is_active = 1
"@
        $fragThreshold = 15.0
        if ($thresholdRows.Count -gt 0 -and $thresholdRows[0]['frag_threshold'] -isnot [DBNull] -and $null -ne $thresholdRows[0]['frag_threshold']) {
            $fragThreshold = [decimal]$thresholdRows[0]['frag_threshold']
        }

        $rows = Invoke-XFActsQuery -Query @"
            SELECT
                sr.server_id,
                sr.server_name,
                dr.database_id,
                dr.database_name,
                dc.index_maintenance_enabled,
                dc.stats_maintenance_enabled,
                COUNT(ir.index_id) AS total_indexes,
                SUM(CASE WHEN ir.current_fragmentation_pct >= @fragThreshold AND ir.is_dropped = 0 THEN 1 ELSE 0 END) AS fragmented_count,
                SUM(CASE WHEN ir.current_fragmentation_pct IS NULL AND ir.is_dropped = 0 THEN 1 ELSE 0 END) AS never_scanned,
                AVG(CASE WHEN ir.is_dropped = 0 AND ir.current_fragmentation_pct IS NOT NULL
                         THEN ir.current_fragmentation_pct ELSE NULL END) AS avg_fragmentation,
                MAX(ir.last_scanned_dttm) AS last_scan_date,
                MAX(ir.last_rebuild_dttm) AS last_rebuild_date,
                (SELECT COUNT(*) FROM ServerOps.Index_Queue q WHERE q.database_id = dr.database_id) AS in_queue
            FROM ServerOps.Index_DatabaseConfig dc
            JOIN dbo.DatabaseRegistry dr ON dc.database_id = dr.database_id
            JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
            LEFT JOIN ServerOps.Index_Registry ir ON ir.database_id = dr.database_id AND ir.is_dropped = 0
            WHERE (dc.index_maintenance_enabled = 1 OR dc.stats_maintenance_enabled = 1)
              AND dr.is_active = 1
            GROUP BY sr.server_id, sr.server_name, dr.database_id, dr.database_name,
                     dc.index_maintenance_enabled, dc.stats_maintenance_enabled
            ORDER BY sr.server_id, dr.database_id
"@ -Parameters @{ fragThreshold = $fragThreshold }

        $databases = @()
        foreach ($row in $rows) {
            $databases += [PSCustomObject]@{
                ServerId = [int]$row['server_id']
                ServerName = $row['server_name']
                DatabaseId = [int]$row['database_id']
                DatabaseName = $row['database_name']
                IndexMaintenanceEnabled = [bool]$row['index_maintenance_enabled']
                StatsMaintenanceEnabled = [bool]$row['stats_maintenance_enabled']
                TotalIndexes = if ($row['total_indexes'] -is [DBNull]) { 0 } else { [int]$row['total_indexes'] }
                FragmentedCount = if ($row['fragmented_count'] -is [DBNull]) { 0 } else { [int]$row['fragmented_count'] }
                NeverScanned = if ($row['never_scanned'] -is [DBNull]) { 0 } else { [int]$row['never_scanned'] }
                AvgFragmentation = if ($row['avg_fragmentation'] -is [DBNull]) { $null } else { [math]::Round([decimal]$row['avg_fragmentation'], 1) }
                LastScanDate = if ($row['last_scan_date'] -is [DBNull]) { $null } else { $row['last_scan_date'].ToString("yyyy-MM-dd HH:mm:ss") }
                LastRebuildDate = if ($row['last_rebuild_date'] -is [DBNull]) { $null } else { $row['last_rebuild_date'].ToString("yyyy-MM-dd HH:mm:ss") }
                InQueue = if ($row['in_queue'] -is [DBNull]) { 0 } else { [int]$row['in_queue'] }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            FragmentationThreshold = $fragThreshold
            Databases = $databases
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/index/sync-details
# Returns details from the last registry-sync run.
Add-PodeRoute -Method Get -Path '/api/index/sync-details' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $statusRows = Invoke-XFActsQuery -Query @"
            SELECT started_dttm, completed_dttm, last_duration_seconds,
                   items_processed, items_added, items_skipped
            FROM ServerOps.Index_Status
            WHERE process_name = 'SYNC'
"@

        $summary = $null
        $startedDttm = $null
        if ($statusRows.Count -gt 0) {
            $row = $statusRows[0]
            $startedDttm = if ($row['started_dttm'] -is [DBNull]) { $null } else { $row['started_dttm'] }
            $summary = [PSCustomObject]@{
                StartedDttm = if ($startedDttm) { $startedDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                CompletedDttm = if ($row['completed_dttm'] -is [DBNull]) { $null } else { $row['completed_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                DurationSeconds = if ($row['last_duration_seconds'] -is [DBNull]) { 0 } else { [int]$row['last_duration_seconds'] }
                TotalUpdated = if ($row['items_processed'] -is [DBNull]) { 0 } else { [int]$row['items_processed'] }
                TotalAdded = if ($row['items_added'] -is [DBNull]) { 0 } else { [int]$row['items_added'] }
                TotalDropped = if ($row['items_skipped'] -is [DBNull]) { 0 } else { [int]$row['items_skipped'] }
            }
        }

        $byDatabase = @()
        if ($startedDttm) {
            $dbRows = Invoke-XFActsQuery -Query @"
                SELECT TOP 50
                    es.server_name AS ServerName,
                    es.database_name AS DatabaseName,
                    es.items_processed AS ItemsProcessed,
                    es.items_added AS ItemsAdded,
                    es.items_skipped AS ItemsSkipped
                FROM ServerOps.Index_ExecutionSummary es
                JOIN dbo.DatabaseRegistry dr ON es.database_name = dr.database_name
                JOIN dbo.ServerRegistry sr ON es.server_name = sr.server_name
                WHERE es.process_name = 'SYNC'
                  AND es.started_dttm >= @since
                ORDER BY sr.server_id, dr.database_id
"@ -Parameters @{ since = $startedDttm }
            foreach ($row in $dbRows) {
                $byDatabase += [PSCustomObject]@{
                    ServerName = $row['ServerName']
                    DatabaseName = $row['DatabaseName']
                    ItemsProcessed = if ($row['ItemsProcessed'] -is [DBNull]) { 0 } else { [int]$row['ItemsProcessed'] }
                    ItemsAdded = if ($row['ItemsAdded'] -is [DBNull]) { 0 } else { [int]$row['ItemsAdded'] }
                    ItemsSkipped = if ($row['ItemsSkipped'] -is [DBNull]) { 0 } else { [int]$row['ItemsSkipped'] }
                }
            }
        }

        $addedIndexes = @()
        if ($startedDttm) {
            $addedRows = Invoke-XFActsQuery -Query @"
                SELECT TOP 100
                    dr.database_name AS DatabaseName,
                    ir.table_name AS TableName,
                    ir.index_name AS IndexName
                FROM ServerOps.Index_Registry ir
                JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
                WHERE ir.created_dttm >= @since
                ORDER BY dr.database_name, ir.table_name, ir.index_name
"@ -Parameters @{ since = $startedDttm }
            foreach ($row in $addedRows) {
                $addedIndexes += [PSCustomObject]@{
                    DatabaseName = $row['DatabaseName']
                    TableName = $row['TableName']
                    IndexName = $row['IndexName']
                }
            }
        }

        $droppedIndexes = @()
        if ($startedDttm) {
            $droppedRows = Invoke-XFActsQuery -Query @"
                SELECT TOP 100
                    dr.database_name AS DatabaseName,
                    ir.table_name AS TableName,
                    ir.index_name AS IndexName
                FROM ServerOps.Index_Registry ir
                JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
                WHERE ir.is_dropped = 1
                  AND ir.dropped_detected_dttm >= @since
                ORDER BY dr.database_name, ir.table_name, ir.index_name
"@ -Parameters @{ since = $startedDttm }
            foreach ($row in $droppedRows) {
                $droppedIndexes += [PSCustomObject]@{
                    DatabaseName = $row['DatabaseName']
                    TableName = $row['TableName']
                    IndexName = $row['IndexName']
                }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Summary = $summary
            ByDatabase = $byDatabase
            AddedIndexes = $addedIndexes
            DroppedIndexes = $droppedIndexes
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/index/scan-details
# Returns details from the last fragmentation-scan run.
Add-PodeRoute -Method Get -Path '/api/index/scan-details' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $statusRows = Invoke-XFActsQuery -Query @"
            SELECT started_dttm, completed_dttm, last_duration_seconds,
                   items_processed, items_added, items_skipped
            FROM ServerOps.Index_Status
            WHERE process_name = 'SCAN'
"@

        $summary = $null
        $startedDttm = $null
        $completedDttm = $null
        if ($statusRows.Count -gt 0) {
            $row = $statusRows[0]
            $startedDttm = if ($row['started_dttm'] -is [DBNull]) { $null } else { $row['started_dttm'] }
            $completedDttm = if ($row['completed_dttm'] -is [DBNull]) { $null } else { $row['completed_dttm'] }
            $summary = [PSCustomObject]@{
                StartedDttm = if ($startedDttm) { $startedDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                CompletedDttm = if ($completedDttm) { $completedDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                DurationSeconds = if ($row['last_duration_seconds'] -is [DBNull]) { 0 } else { [int]$row['last_duration_seconds'] }
                TotalScanned = if ($row['items_processed'] -is [DBNull]) { 0 } else { [int]$row['items_processed'] }
                TotalQueued = if ($row['items_added'] -is [DBNull]) { 0 } else { [int]$row['items_added'] }
                TotalRemoved = if ($row['items_skipped'] -is [DBNull]) { 0 } else { [int]$row['items_skipped'] }
            }
        }

        $scannedIndexes = @()
        if ($startedDttm -and $completedDttm) {
            $scannedRows = Invoke-XFActsQuery -Query @"
                SELECT
                    sr.server_name AS ServerName,
                    dr.database_name AS DatabaseName,
                    ir.schema_name AS SchemaName,
                    ir.table_name AS TableName,
                    ir.index_name AS IndexName,
                    CASE
                        WHEN ir.last_rebuild_dttm IS NULL OR ir.last_rebuild_dttm < ir.last_scanned_dttm
                        THEN ir.current_fragmentation_pct
                        ELSE COALESCE(el.fragmentation_pct_before, ir.current_fragmentation_pct)
                    END AS FragmentationPct,
                    ir.current_page_count AS PageCount,
                    CASE
                        WHEN iq.registry_id IS NOT NULL THEN 1
                        WHEN el.registry_id IS NOT NULL AND el.started_dttm >= @since THEN 1
                        ELSE 0
                    END AS WasQueued,
                    sr.server_id,
                    dr.database_id
                FROM ServerOps.Index_Registry ir
                JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
                JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
                LEFT JOIN ServerOps.Index_ExecutionLog el
                    ON el.registry_id = ir.registry_id
                    AND CAST(el.started_dttm AS DATE) = CAST(ir.last_rebuild_dttm AS DATE)
                    AND el.status = 'SUCCESS'
                LEFT JOIN ServerOps.Index_Queue iq
                    ON iq.registry_id = ir.registry_id
                WHERE ir.last_scanned_dttm >= @since
                  AND ir.last_scanned_dttm <= @until
                  AND ir.is_dropped = 0
                ORDER BY sr.server_id, dr.database_id,
                    CASE
                        WHEN ir.last_rebuild_dttm IS NULL OR ir.last_rebuild_dttm < ir.last_scanned_dttm
                        THEN ir.current_fragmentation_pct
                        ELSE COALESCE(el.fragmentation_pct_before, ir.current_fragmentation_pct)
                    END DESC
"@ -Parameters @{ since = $startedDttm; until = $completedDttm }
            foreach ($row in $scannedRows) {
                $scannedIndexes += [PSCustomObject]@{
                    ServerName = $row['ServerName']
                    DatabaseName = $row['DatabaseName']
                    SchemaName = $row['SchemaName']
                    TableName = $row['TableName']
                    IndexName = $row['IndexName']
                    FragmentationPct = if ($row['FragmentationPct'] -is [DBNull]) { 0 } else { [decimal]$row['FragmentationPct'] }
                    PageCount = if ($row['PageCount'] -is [DBNull]) { 0 } else { [long]$row['PageCount'] }
                    WasQueued = if ($row['WasQueued'] -is [DBNull]) { $false } else { [int]$row['WasQueued'] -eq 1 }
                }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Summary = $summary
            ScannedIndexes = $scannedIndexes
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/index/execute-details
# Returns details from the last index-maintenance (rebuild) run.
Add-PodeRoute -Method Get -Path '/api/index/execute-details' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $statusRows = Invoke-XFActsQuery -Query @"
            SELECT started_dttm, completed_dttm, last_duration_seconds,
                   items_processed, items_added, items_skipped, items_failed
            FROM ServerOps.Index_Status
            WHERE process_name = 'EXECUTE'
"@

        $summary = $null
        $startedDttm = $null
        if ($statusRows.Count -gt 0) {
            $row = $statusRows[0]
            $startedDttm = if ($row['started_dttm'] -is [DBNull]) { $null } else { $row['started_dttm'] }
            $summary = [PSCustomObject]@{
                StartedDttm = if ($startedDttm) { $startedDttm.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                CompletedDttm = if ($row['completed_dttm'] -is [DBNull]) { $null } else { $row['completed_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                DurationSeconds = if ($row['last_duration_seconds'] -is [DBNull]) { 0 } else { [int]$row['last_duration_seconds'] }
                TotalRebuilt = if ($row['items_added'] -is [DBNull]) { 0 } else { [int]$row['items_added'] }
                TotalFailed = if ($row['items_failed'] -is [DBNull]) { 0 } else { [int]$row['items_failed'] }
                TotalDeferred = if ($row['items_skipped'] -is [DBNull]) { 0 } else { [int]$row['items_skipped'] }
            }
        }

        $rebuiltIndexes = @()
        if ($startedDttm) {
            $rebuildRows = Invoke-XFActsQuery -Query @"
                SELECT
                    sr.server_name AS ServerName,
                    dr.database_name AS DatabaseName,
                    el.schema_name AS SchemaName,
                    el.table_name AS TableName,
                    el.index_name AS IndexName,
                    el.fragmentation_pct_before AS FragmentationBefore,
                    el.fragmentation_pct_after AS FragmentationAfter,
                    el.duration_seconds AS DurationSeconds,
                    el.status AS ResultStatus
                FROM ServerOps.Index_ExecutionLog el
                JOIN dbo.DatabaseRegistry dr ON el.database_id = dr.database_id
                JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
                WHERE el.started_dttm >= @since
                  AND el.status IN ('SUCCESS', 'PARTIAL')
                ORDER BY sr.server_id, dr.database_id, el.started_dttm
"@ -Parameters @{ since = $startedDttm }
            foreach ($row in $rebuildRows) {
                $rebuiltIndexes += [PSCustomObject]@{
                    ServerName = $row['ServerName']
                    DatabaseName = $row['DatabaseName']
                    SchemaName = $row['SchemaName']
                    TableName = $row['TableName']
                    IndexName = $row['IndexName']
                    FragmentationBefore = if ($row['FragmentationBefore'] -is [DBNull]) { 0 } else { [decimal]$row['FragmentationBefore'] }
                    FragmentationAfter = if ($row['FragmentationAfter'] -is [DBNull]) { $null } else { [decimal]$row['FragmentationAfter'] }
                    DurationSeconds = if ($row['DurationSeconds'] -is [DBNull]) { 0 } else { [int]$row['DurationSeconds'] }
                    ResultStatus = $row['ResultStatus']
                }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Summary = $summary
            RebuiltIndexes = $rebuiltIndexes
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/index/stats-details
# Returns details from the last statistics-update run: summary by database
# plus any failures.
Add-PodeRoute -Method Get -Path '/api/index/stats-details' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $statusRows = Invoke-XFActsQuery -Query @"
            SELECT started_dttm, completed_dttm, last_duration_seconds,
                   items_processed, items_added, items_skipped, items_failed
            FROM ServerOps.Index_Status
            WHERE process_name = 'STATS'
"@

        $summary = $null
        if ($statusRows.Count -gt 0) {
            $row = $statusRows[0]
            $summary = [PSCustomObject]@{
                StartedDttm = if ($row['started_dttm'] -is [DBNull]) { $null } else { $row['started_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                CompletedDttm = if ($row['completed_dttm'] -is [DBNull]) { $null } else { $row['completed_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                DurationSeconds = if ($row['last_duration_seconds'] -is [DBNull]) { 0 } else { [int]$row['last_duration_seconds'] }
                TotalEvaluated = if ($row['items_processed'] -is [DBNull]) { 0 } else { [int]$row['items_processed'] }
                TotalUpdated = if ($row['items_added'] -is [DBNull]) { 0 } else { [int]$row['items_added'] }
                TotalSkipped = if ($row['items_skipped'] -is [DBNull]) { 0 } else { [int]$row['items_skipped'] }
                TotalFailed = if ($row['items_failed'] -is [DBNull]) { 0 } else { [int]$row['items_failed'] }
            }
        }

        $runIdRows = Invoke-XFActsQuery -Query @"
            SELECT MAX(run_id) AS LastRunId FROM ServerOps.Index_StatsExecutionLog
"@
        $lastRunId = if ($runIdRows.Count -gt 0) { $runIdRows[0]['LastRunId'] } else { $null }
        $hasRun = ($null -ne $lastRunId -and $lastRunId -isnot [DBNull])

        $byDatabase = @()
        if ($hasRun) {
            $dbRows = Invoke-XFActsQuery -Query @"
                SELECT
                    sr.server_name AS ServerName,
                    sel.database_name,
                    SUM(CASE WHEN sel.update_type = 'MODIFICATION' THEN 1 ELSE 0 END) AS ModificationCount,
                    SUM(CASE WHEN sel.update_type = 'STALENESS' THEN sel.stats_count ELSE 0 END) AS StalenessCount,
                    SUM(sel.duration_ms) AS TotalDurationMs
                FROM ServerOps.Index_StatsExecutionLog sel
                JOIN dbo.DatabaseRegistry dr ON sel.database_id = dr.database_id
                JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
                WHERE sel.run_id = @runId
                  AND sel.status IN ('SUCCESS', 'SKIPPED')
                GROUP BY sr.server_name, sel.database_name, sr.server_id, dr.database_id
                ORDER BY sr.server_id, dr.database_id
"@ -Parameters @{ runId = $lastRunId }
            foreach ($row in $dbRows) {
                $byDatabase += [PSCustomObject]@{
                    ServerName = $row['ServerName']
                    DatabaseName = $row['database_name']
                    ModificationCount = if ($row['ModificationCount'] -is [DBNull]) { 0 } else { [int]$row['ModificationCount'] }
                    StalenessCount = if ($row['StalenessCount'] -is [DBNull]) { 0 } else { [int]$row['StalenessCount'] }
                    DurationMs = if ($row['TotalDurationMs'] -is [DBNull]) { 0 } else { [int]$row['TotalDurationMs'] }
                }
            }
        }

        $totalModifications = 0
        $totalStaleness = 0
        if ($hasRun) {
            $totalsRows = Invoke-XFActsQuery -Query @"
                SELECT
                    SUM(CASE WHEN update_type = 'MODIFICATION' AND status = 'SUCCESS' THEN 1 ELSE 0 END) AS TotalModifications,
                    SUM(CASE WHEN update_type = 'STALENESS' AND status = 'SUCCESS' THEN stats_count ELSE 0 END) AS TotalStaleness
                FROM ServerOps.Index_StatsExecutionLog
                WHERE run_id = @runId
"@ -Parameters @{ runId = $lastRunId }
            if ($totalsRows.Count -gt 0) {
                $totRow = $totalsRows[0]
                $totalModifications = if ($totRow['TotalModifications'] -is [DBNull]) { 0 } else { [int]$totRow['TotalModifications'] }
                $totalStaleness = if ($totRow['TotalStaleness'] -is [DBNull]) { 0 } else { [int]$totRow['TotalStaleness'] }
            }
        }

        $failures = @()
        if ($hasRun) {
            $failRows = Invoke-XFActsQuery -Query @"
                SELECT
                    database_name,
                    stat_name,
                    error_message
                FROM ServerOps.Index_StatsExecutionLog
                WHERE run_id = @runId
                  AND status = 'FAILED'
                ORDER BY database_name, stat_name
"@ -Parameters @{ runId = $lastRunId }
            foreach ($row in $failRows) {
                $failures += [PSCustomObject]@{
                    DatabaseName = $row['database_name']
                    StatName = if ($row['stat_name'] -is [DBNull]) { $null } else { $row['stat_name'] }
                    ErrorMessage = if ($row['error_message'] -is [DBNull]) { $null } else { $row['error_message'] }
                }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Summary = $summary
            TotalModifications = $totalModifications
            TotalStaleness = $totalStaleness
            ByDatabase = $byDatabase
            Failures = $failures
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/index/schedule/:databaseId
# Returns the weekly maintenance schedule (7 days x 24 hours) and the holiday
# schedule (single row x 24 hours) for a database.
Add-PodeRoute -Method Get -Path '/api/index/schedule/:databaseId' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $databaseId = [int]$WebEvent.Parameters['databaseId']

        $scheduleRows = Invoke-XFActsQuery -Query @"
            SELECT
                day_of_week,
                hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07,
                hr08, hr09, hr10, hr11, hr12, hr13, hr14, hr15,
                hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23
            FROM ServerOps.Index_DatabaseSchedule
            WHERE database_id = @DatabaseId
            ORDER BY day_of_week
"@ -Parameters @{ DatabaseId = $databaseId }

        $schedule = @()
        foreach ($row in $scheduleRows) {
            $schedule += [PSCustomObject]@{
                DayOfWeek = [int]$row['day_of_week']
                Hr00 = [bool]$row['hr00']; Hr01 = [bool]$row['hr01']; Hr02 = [bool]$row['hr02']; Hr03 = [bool]$row['hr03']
                Hr04 = [bool]$row['hr04']; Hr05 = [bool]$row['hr05']; Hr06 = [bool]$row['hr06']; Hr07 = [bool]$row['hr07']
                Hr08 = [bool]$row['hr08']; Hr09 = [bool]$row['hr09']; Hr10 = [bool]$row['hr10']; Hr11 = [bool]$row['hr11']
                Hr12 = [bool]$row['hr12']; Hr13 = [bool]$row['hr13']; Hr14 = [bool]$row['hr14']; Hr15 = [bool]$row['hr15']
                Hr16 = [bool]$row['hr16']; Hr17 = [bool]$row['hr17']; Hr18 = [bool]$row['hr18']; Hr19 = [bool]$row['hr19']
                Hr20 = [bool]$row['hr20']; Hr21 = [bool]$row['hr21']; Hr22 = [bool]$row['hr22']; Hr23 = [bool]$row['hr23']
            }
        }

        $holidayRows = Invoke-XFActsQuery -Query @"
            SELECT
                hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07,
                hr08, hr09, hr10, hr11, hr12, hr13, hr14, hr15,
                hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23
            FROM ServerOps.Index_HolidaySchedule
            WHERE database_id = @DatabaseId
"@ -Parameters @{ DatabaseId = $databaseId }

        $holidaySchedule = $null
        if ($holidayRows.Count -gt 0) {
            $row = $holidayRows[0]
            $holidaySchedule = [PSCustomObject]@{
                Hr00 = [bool]$row['hr00']; Hr01 = [bool]$row['hr01']; Hr02 = [bool]$row['hr02']; Hr03 = [bool]$row['hr03']
                Hr04 = [bool]$row['hr04']; Hr05 = [bool]$row['hr05']; Hr06 = [bool]$row['hr06']; Hr07 = [bool]$row['hr07']
                Hr08 = [bool]$row['hr08']; Hr09 = [bool]$row['hr09']; Hr10 = [bool]$row['hr10']; Hr11 = [bool]$row['hr11']
                Hr12 = [bool]$row['hr12']; Hr13 = [bool]$row['hr13']; Hr14 = [bool]$row['hr14']; Hr15 = [bool]$row['hr15']
                Hr16 = [bool]$row['hr16']; Hr17 = [bool]$row['hr17']; Hr18 = [bool]$row['hr18']; Hr19 = [bool]$row['hr19']
                Hr20 = [bool]$row['hr20']; Hr21 = [bool]$row['hr21']; Hr22 = [bool]$row['hr22']; Hr23 = [bool]$row['hr23']
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            DatabaseId = $databaseId
            Schedule = $schedule
            HolidaySchedule = $holidaySchedule
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# POST /api/index/schedule/update
# Toggles a single hour cell in the weekly maintenance schedule.
# Body: { DatabaseId, DayOfWeek, Hour, Allowed }
Add-PodeRoute -Method Post -Path '/api/index/schedule/update' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $databaseId = [int]$body.DatabaseId
        $dayOfWeek = [int]$body.DayOfWeek
        $hour = [int]$body.Hour
        $allowed = [bool]$body.Allowed

        if ($dayOfWeek -lt 0 -or $dayOfWeek -gt 6) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid day of week" }) -StatusCode 400
            return
        }
        if ($hour -lt 0 -or $hour -gt 23) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid hour" }) -StatusCode 400
            return
        }

        # Hour resolves to a fixed column name; validated 0-23 above so the
        # interpolation is a safe identifier, not user-supplied value text.
        $hourColumn = "hr" + $hour.ToString("00")

        $currentUser = $WebEvent.Auth.User.Name
        if ([string]::IsNullOrEmpty($currentUser)) {
            $currentUser = "Unknown"
        }

        $rowsAffected = Invoke-XFActsNonQuery -Query @"
            UPDATE ServerOps.Index_DatabaseSchedule
            SET $hourColumn = @Allowed,
                modified_dttm = GETDATE(),
                modified_by = @ModifiedBy
            WHERE database_id = @DatabaseId
              AND day_of_week = @DayOfWeek
"@ -Parameters @{
            Allowed = $allowed
            ModifiedBy = $currentUser
            DatabaseId = $databaseId
            DayOfWeek = $dayOfWeek
        }

        if ($rowsAffected -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Schedule record not found" }) -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            DatabaseId = $databaseId
            DayOfWeek = $dayOfWeek
            Hour = $hour
            Allowed = $allowed
            ModifiedBy = $currentUser
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# POST /api/index/schedule/update-batch
# Updates multiple weekly-schedule hour cells atomically in a single statement.
# Body: { DatabaseId, Updates: [{ DayOfWeek, Hour, Allowed }, ...] }
Add-PodeRoute -Method Post -Path '/api/index/schedule/update-batch' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $databaseId = [int]$body.DatabaseId
        $updates = $body.Updates

        if (-not $updates -or $updates.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "No updates provided" }) -StatusCode 400
            return
        }

        $currentUser = $WebEvent.Auth.User.Name
        if ([string]::IsNullOrEmpty($currentUser)) {
            $currentUser = "Unknown"
        }

        # Build one transactional batch that applies every cell update in a
        # single round trip. Each update contributes its own parameterized
        # statement; the surrounding transaction preserves all-or-nothing
        # semantics. Hour and day are validated before use; the hour column
        # name is a validated identifier.
        $statements = [System.Collections.ArrayList]::new()
        $parameters = @{
            DatabaseId = $databaseId
            ModifiedBy = $currentUser
        }

        $i = 0
        foreach ($update in $updates) {
            $dayOfWeek = [int]$update.DayOfWeek
            $hour = [int]$update.Hour
            $allowed = [bool]$update.Allowed

            if ($dayOfWeek -lt 1 -or $dayOfWeek -gt 7) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid day of week: $dayOfWeek" }) -StatusCode 400
                return
            }
            if ($hour -lt 0 -or $hour -gt 23) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid hour: $hour" }) -StatusCode 400
                return
            }

            $hourColumn = "hr" + $hour.ToString("00")
            $allowedParam = "Allowed$i"
            $dayParam = "Day$i"

            [void]$statements.Add(@"
    UPDATE ServerOps.Index_DatabaseSchedule
    SET $hourColumn = @$allowedParam,
        modified_dttm = GETDATE(),
        modified_by = @ModifiedBy
    WHERE database_id = @DatabaseId
      AND day_of_week = @$dayParam;
"@)
            $parameters[$allowedParam] = $allowed
            $parameters[$dayParam] = $dayOfWeek
            $i++
        }

        $batchBody = $statements -join "`n"
        $query = @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;
$batchBody
COMMIT TRANSACTION;
"@

        $rowsAffected = Invoke-XFActsNonQuery -Query $query -Parameters $parameters

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            DatabaseId = $databaseId
            UpdateCount = $updates.Count
            RowsAffected = $rowsAffected
            ModifiedBy = $currentUser
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# POST /api/index/schedule/holiday/update-batch
# Updates multiple holiday-schedule hour cells in a single statement.
# Body: { DatabaseId, Updates: [{ Hour, Allowed }, ...] }
Add-PodeRoute -Method Post -Path '/api/index/schedule/holiday/update-batch' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $databaseId = [int]$body.DatabaseId
        $updates = $body.Updates

        if (-not $updates -or $updates.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "No updates provided" }) -StatusCode 400
            return
        }

        $currentUser = $WebEvent.Auth.User.Name
        if ([string]::IsNullOrEmpty($currentUser)) {
            $currentUser = "Unknown"
        }

        # Build the SET clause from validated hour columns. Each hour resolves
        # to a fixed column name and a parameterized allowed value.
        $setClauses = @()
        $parameters = @{
            DatabaseId = $databaseId
            ModifiedBy = $currentUser
        }

        $i = 0
        foreach ($update in $updates) {
            $hour = [int]$update.Hour
            $allowed = if ([bool]$update.Allowed) { 1 } else { 0 }

            if ($hour -lt 0 -or $hour -gt 23) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid hour: $hour" }) -StatusCode 400
                return
            }

            $hourColumn = "hr" + $hour.ToString("00")
            $allowedParam = "Allowed$i"
            $setClauses += "$hourColumn = @$allowedParam"
            $parameters[$allowedParam] = $allowed
            $i++
        }

        $setClause = $setClauses -join ", "
        $query = @"
            UPDATE ServerOps.Index_HolidaySchedule
            SET $setClause,
                modified_dttm = GETDATE(),
                modified_by = @ModifiedBy
            WHERE database_id = @DatabaseId
"@

        $rowsAffected = Invoke-XFActsNonQuery -Query $query -Parameters $parameters

        if ($rowsAffected -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Holiday schedule record not found" }) -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            DatabaseId = $databaseId
            UpdateCount = $updates.Count
            RowsAffected = $rowsAffected
            ModifiedBy = $currentUser
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# POST /api/index/launch-process
# Admin-gated manual launch of one of the four index maintenance scripts.
# Body: { Process }
Add-PodeRoute -Method Post -Path '/api/index/launch-process' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $processName = $body.Process

        $scriptMap = @{
            'SYNC'    = 'Sync-IndexRegistry.ps1'
            'SCAN'    = 'Scan-IndexFragmentation.ps1'
            'EXECUTE' = 'Execute-IndexMaintenance.ps1'
            'STATS'   = 'Update-IndexStatistics.ps1'
        }

        if (-not $scriptMap.ContainsKey($processName)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid process: $processName" }) -StatusCode 400
            return
        }

        $scriptPath = Join-Path 'E:\xFACts-PowerShell' $scriptMap[$processName]
        if (-not (Test-Path $scriptPath)) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Script not found: $($scriptMap[$processName])" }) -StatusCode 500
            return
        }

        $arguments = "-ExecutionPolicy Bypass -File `"$scriptPath`" -Execute"
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList $arguments `
            -WorkingDirectory 'E:\xFACts-PowerShell' `
            -WindowStyle Hidden `
            -PassThru | Out-Null

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            Process = $processName
            Script  = $scriptMap[$processName]
            Message = "$processName launched successfully"
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
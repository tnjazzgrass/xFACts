# ============================================================================
# xFACts Control Center - Index Maintenance API
# Location: E:\xFACts-ControlCenter\scripts\routes\IndexMaintenance-API.ps1
# 
# API endpoints for Index Maintenance monitoring data.
# Version: Tracked in dbo.System_Metadata (component: ServerOps.Index)
# ============================================================================

# ----------------------------------------------------------------------------
# GET /api/index/live-activity
# Returns current running process info or last activity if idle
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/live-activity' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Check for any IN_PROGRESS processes
        $query = @"
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
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $runningProcesses = @()
        
        foreach ($row in $dataset.Tables[0].Rows) {
            $processName = $row['process_name']
            $startedDttm = $row['started_dttm']
            $elapsedSeconds = [int]$row['elapsed_seconds']
            
            # Get live count from Index_Registry based on process type
            $countQuery = switch ($processName) {
                'SYNC' { 
                    "SELECT COUNT(*) AS cnt FROM ServerOps.Index_Registry WHERE usage_captured_dttm >= '$($startedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'" 
                }
                'SCAN' { 
                    "SELECT COUNT(*) AS cnt FROM ServerOps.Index_Registry WHERE last_scanned_dttm >= '$($startedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'" 
                }
                'EXECUTE' { 
                    # For EXECUTE, items_added is updated in real-time
                    $null
                }
                'STATS' { 
                    "SELECT COUNT(*) AS cnt FROM ServerOps.Index_Registry WHERE stats_last_updated >= '$($startedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'" 
                }
                default { $null }
            }
            
            $completedCount = 0
            if ($processName -eq 'EXECUTE') {
                # Use items_added from Index_Status directly
                $completedCount = if ($row['items_added'] -is [DBNull]) { 0 } else { [int]$row['items_added'] }
            }
            elseif ($countQuery) {
                $countCmd = $conn.CreateCommand()
                $countCmd.CommandText = $countQuery
                $countCmd.CommandTimeout = 10
                $countResult = $countCmd.ExecuteScalar()
                $completedCount = if ($countResult -is [DBNull]) { 0 } else { [int]$countResult }
            }
            
            $runningProcesses += [PSCustomObject]@{
                ProcessName = $processName
                StartedDttm = $startedDttm.ToString("yyyy-MM-dd HH:mm:ss")
                ElapsedSeconds = $elapsedSeconds
                CompletedCount = $completedCount
            }
        }
        
        # If nothing running, get last completed activity
        $lastActivity = $null
        if ($runningProcesses.Count -eq 0) {
            $lastQuery = @"
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
            $lastCmd = $conn.CreateCommand()
            $lastCmd.CommandText = $lastQuery
            $lastCmd.CommandTimeout = 10
            
            $lastAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($lastCmd)
            $lastDataset = New-Object System.Data.DataSet
            $lastAdapter.Fill($lastDataset) | Out-Null
            
            if ($lastDataset.Tables[0].Rows.Count -gt 0) {
                $lastRow = $lastDataset.Tables[0].Rows[0]
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
        
        $conn.Close()
        
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

# ----------------------------------------------------------------------------
# GET /api/index/process-status
# Returns status of all 4 index processes from Index_Status
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/process-status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
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
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $conn.Close()
        
        $processes = @()
        foreach ($row in $dataset.Tables[0].Rows) {
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
            }
        }
        
        Write-PodeJsonResponse -Value $processes
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/index/active-execution
# Returns real-time progress of currently executing index rebuild
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/active-execution' -Authentication 'ADLogin' -ScriptBlock {
    try {
        # First check if EXECUTE is running
        $xfactsConnString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $xfactsConn = New-Object System.Data.SqlClient.SqlConnection($xfactsConnString)
        $xfactsConn.Open()
        
        $statusQuery = "SELECT last_status FROM ServerOps.Index_Status WHERE process_name = 'EXECUTE'"
        $statusCmd = $xfactsConn.CreateCommand()
        $statusCmd.CommandText = $statusQuery
        $statusCmd.CommandTimeout = 5
        $executeStatus = $statusCmd.ExecuteScalar()
        
        if ($executeStatus -ne 'IN_PROGRESS') {
            $xfactsConn.Close()
            Write-PodeJsonResponse -Value ([PSCustomObject]@{
                IsExecuting = $false
                ActiveRebuilds = @()
            })
            return
        }
        
        # Get list of servers that have index maintenance enabled
        $serverQuery = @"
            SELECT DISTINCT sr.server_name
            FROM dbo.ServerRegistry sr
            WHERE sr.is_active = 1
              AND sr.serverops_index_enabled = 1
"@
        $serverCmd = $xfactsConn.CreateCommand()
        $serverCmd.CommandText = $serverQuery
        $serverCmd.CommandTimeout = 5
        
        $serverAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($serverCmd)
        $serverDataset = New-Object System.Data.DataSet
        $serverAdapter.Fill($serverDataset) | Out-Null
        
        $xfactsConn.Close()
        
        $activeRebuilds = @()
        
        # Query each server for active index operations
        foreach ($serverRow in $serverDataset.Tables[0].Rows) {
            $serverName = $serverRow['server_name']
            
            try {
                $serverConnString = "Server=$serverName;Database=master;Integrated Security=True;Connect Timeout=3;"
                $serverConn = New-Object System.Data.SqlClient.SqlConnection($serverConnString)
                $serverConn.Open()
                
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
                
                $progressCmd = $serverConn.CreateCommand()
                $progressCmd.CommandText = $progressQuery
                $progressCmd.CommandTimeout = 10
                
                $progressAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($progressCmd)
                $progressDataset = New-Object System.Data.DataSet
                $progressAdapter.Fill($progressDataset) | Out-Null
                
                $serverConn.Close()
                
                foreach ($row in $progressDataset.Tables[0].Rows) {
                    $activeRebuilds += [PSCustomObject]@{
                        ServerName = $serverName
                        DatabaseName = if ($row['DatabaseName'] -is [DBNull]) { 'Unknown' } else { $row['DatabaseName'] }
                        IndexName = if ($row['IndexName'] -is [DBNull]) { 'Unknown' } else { $row['IndexName'] }
                        CurrentStep = if ($row['CurrentStep'] -is [DBNull]) { 'Unknown' } else { $row['CurrentStep'] }
                        TotalRows = if ($row['TotalRows'] -is [DBNull]) { 0 } else { [long]$row['TotalRows'] }
                        RowsProcessed = if ($row['RowsProcessed'] -is [DBNull]) { 0 } else { [long]$row['RowsProcessed'] }
                        RowsLeft = if ($row['RowsLeft'] -is [DBNull]) { 0 } else { [long]$row['RowsLeft'] }
                        PercentComplete = if ($row['PercentComplete'] -is [DBNull]) { 0 } else { [decimal]$row['PercentComplete'] }
                        ElapsedSeconds = if ($row['ElapsedSeconds'] -is [DBNull]) { 0 } else { [decimal]$row['ElapsedSeconds'] }
                        EstimatedSecondsLeft = if ($row['EstimatedSecondsLeft'] -is [DBNull]) { 0 } else { [decimal]$row['EstimatedSecondsLeft'] }
                        EstimatedCompletionTime = if ($row['EstimatedCompletionTime'] -is [DBNull]) { $null } else { $row['EstimatedCompletionTime'].ToString("yyyy-MM-dd HH:mm:ss") }
                    }
                }
            }
            catch {
                # Server unavailable, skip it
            }
        }
        
        # Deduplicate by session characteristics (same index rebuild seen via listener and direct connection)
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

# ----------------------------------------------------------------------------
# GET /api/index/queue-summary
# Returns summary counts and totals for the Index_Queue
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/queue-summary' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
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
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $conn.Close()
        
        $summary = @()
        foreach ($row in $dataset.Tables[0].Rows) {
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

# ----------------------------------------------------------------------------
# GET /api/index/queue-details
# Returns all items in the Index_Queue with database info
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/queue-details' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $query = @"
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
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 30
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $conn.Close()
        
        $items = @()
        foreach ($row in $dataset.Tables[0].Rows) {
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

# ----------------------------------------------------------------------------
# GET /api/index/database-health
# Returns aggregated index health metrics by server/database
# Includes index_maintenance_enabled and stats_maintenance_enabled for grouping
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/database-health' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get fragmentation threshold from config
        $thresholdQuery = @"
            SELECT CAST(setting_value AS DECIMAL(5,2)) AS frag_threshold
            FROM dbo.GlobalConfig
            WHERE module_name = 'ServerOps'
              AND category = 'Index'
              AND setting_name = 'index_frag_threshold'
              AND is_active = 1
"@
        $thresholdCmd = $conn.CreateCommand()
        $thresholdCmd.CommandText = $thresholdQuery
        $thresholdCmd.CommandTimeout = 5
        $fragThreshold = $thresholdCmd.ExecuteScalar()
        if ($fragThreshold -is [DBNull] -or $null -eq $fragThreshold) { $fragThreshold = 15.0 }
        
        $query = @"
            SELECT 
                sr.server_id,
                sr.server_name,
                dr.database_id,
                dr.database_name,
                dc.index_maintenance_enabled,
                dc.stats_maintenance_enabled,
                COUNT(ir.index_id) AS total_indexes,
                SUM(CASE WHEN ir.current_fragmentation_pct >= $fragThreshold AND ir.is_dropped = 0 THEN 1 ELSE 0 END) AS fragmented_count,
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
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 30
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $conn.Close()
        
        $databases = @()
        foreach ($row in $dataset.Tables[0].Rows) {
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

# ----------------------------------------------------------------------------
# GET /api/index/sync-details
# Returns details from the last SYNC run
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/sync-details' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get last SYNC run info
        $statusQuery = @"
            SELECT started_dttm, completed_dttm, last_duration_seconds,
                   items_processed, items_added, items_skipped
            FROM ServerOps.Index_Status
            WHERE process_name = 'SYNC'
"@
        $statusCmd = $conn.CreateCommand()
        $statusCmd.CommandText = $statusQuery
        $statusCmd.CommandTimeout = 10
        
        $statusAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($statusCmd)
        $statusDataset = New-Object System.Data.DataSet
        $statusAdapter.Fill($statusDataset) | Out-Null
        
        $summary = $null
        $startedDttm = $null
        if ($statusDataset.Tables[0].Rows.Count -gt 0) {
            $row = $statusDataset.Tables[0].Rows[0]
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
        
        # Get by-database breakdown from last run
        $byDatabase = @()
        if ($startedDttm) {
            $dbQuery = @"
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
                  AND es.started_dttm >= '$($startedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'
                ORDER BY sr.server_id, dr.database_id
"@
            $dbCmd = $conn.CreateCommand()
            $dbCmd.CommandText = $dbQuery
            $dbCmd.CommandTimeout = 10
            
            $dbAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($dbCmd)
            $dbDataset = New-Object System.Data.DataSet
            $dbAdapter.Fill($dbDataset) | Out-Null
            
            foreach ($row in $dbDataset.Tables[0].Rows) {
                $byDatabase += [PSCustomObject]@{
                    ServerName = $row['ServerName']
                    DatabaseName = $row['DatabaseName']
                    ItemsProcessed = if ($row['ItemsProcessed'] -is [DBNull]) { 0 } else { [int]$row['ItemsProcessed'] }
                    ItemsAdded = if ($row['ItemsAdded'] -is [DBNull]) { 0 } else { [int]$row['ItemsAdded'] }
                    ItemsSkipped = if ($row['ItemsSkipped'] -is [DBNull]) { 0 } else { [int]$row['ItemsSkipped'] }
                }
            }
        }
        
        # Get newly added indexes (created since last SYNC started)
        $addedIndexes = @()
        if ($startedDttm) {
            $addedQuery = @"
                SELECT TOP 100
                    dr.database_name AS DatabaseName,
                    ir.table_name AS TableName,
                    ir.index_name AS IndexName
                FROM ServerOps.Index_Registry ir
                JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
                WHERE ir.created_dttm >= '$($startedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'
                ORDER BY dr.database_name, ir.table_name, ir.index_name
"@
            $addedCmd = $conn.CreateCommand()
            $addedCmd.CommandText = $addedQuery
            $addedCmd.CommandTimeout = 10
            
            $addedAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($addedCmd)
            $addedDataset = New-Object System.Data.DataSet
            $addedAdapter.Fill($addedDataset) | Out-Null
            
            foreach ($row in $addedDataset.Tables[0].Rows) {
                $addedIndexes += [PSCustomObject]@{
                    DatabaseName = $row['DatabaseName']
                    TableName = $row['TableName']
                    IndexName = $row['IndexName']
                }
            }
        }
        
        # Get dropped indexes detected
        $droppedIndexes = @()
        if ($startedDttm) {
            $droppedQuery = @"
                SELECT TOP 100
                    dr.database_name AS DatabaseName,
                    ir.table_name AS TableName,
                    ir.index_name AS IndexName
                FROM ServerOps.Index_Registry ir
                JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
                WHERE ir.is_dropped = 1
                  AND ir.dropped_detected_dttm >= '$($startedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'
                ORDER BY dr.database_name, ir.table_name, ir.index_name
"@
            $droppedCmd = $conn.CreateCommand()
            $droppedCmd.CommandText = $droppedQuery
            $droppedCmd.CommandTimeout = 10
            
            $droppedAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($droppedCmd)
            $droppedDataset = New-Object System.Data.DataSet
            $droppedAdapter.Fill($droppedDataset) | Out-Null
            
            foreach ($row in $droppedDataset.Tables[0].Rows) {
                $droppedIndexes += [PSCustomObject]@{
                    DatabaseName = $row['DatabaseName']
                    TableName = $row['TableName']
                    IndexName = $row['IndexName']
                }
            }
        }
        
        $conn.Close()
        
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

# ----------------------------------------------------------------------------
# GET /api/index/scan-details
# Returns details from the last SCAN run - what fragmentation was found
# Uses Index_Registry for indexes not yet rebuilt, Index_ExecutionLog for those already processed
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/scan-details' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get last SCAN run info
        $statusQuery = @"
            SELECT started_dttm, completed_dttm, last_duration_seconds,
                   items_processed, items_added, items_skipped
            FROM ServerOps.Index_Status
            WHERE process_name = 'SCAN'
"@
        $statusCmd = $conn.CreateCommand()
        $statusCmd.CommandText = $statusQuery
        $statusCmd.CommandTimeout = 10
        
        $statusAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($statusCmd)
        $statusDataset = New-Object System.Data.DataSet
        $statusAdapter.Fill($statusDataset) | Out-Null
        
        $summary = $null
        $startedDttm = $null
        $completedDttm = $null
        if ($statusDataset.Tables[0].Rows.Count -gt 0) {
            $row = $statusDataset.Tables[0].Rows[0]
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
        
        # Get indexes scanned during the scan window
        # If last_rebuild_dttm > last_scanned_dttm, use fragmentation_pct_before from Index_ExecutionLog
        # Otherwise use current_fragmentation_pct from Index_Registry
        # Check actual queue presence or execution log to determine if index was queued
        $scannedIndexes = @()
        if ($startedDttm -and $completedDttm) {
            $scannedQuery = @"
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
                        WHEN el.registry_id IS NOT NULL AND el.started_dttm >= '$($startedDttm.ToString("yyyy-MM-dd HH:mm:ss"))' THEN 1
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
                WHERE ir.last_scanned_dttm >= '$($startedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'
                  AND ir.last_scanned_dttm <= '$($completedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'
                  AND ir.is_dropped = 0
                ORDER BY sr.server_id, dr.database_id, 
                    CASE 
                        WHEN ir.last_rebuild_dttm IS NULL OR ir.last_rebuild_dttm < ir.last_scanned_dttm 
                        THEN ir.current_fragmentation_pct
                        ELSE COALESCE(el.fragmentation_pct_before, ir.current_fragmentation_pct)
                    END DESC
"@
            $scannedCmd = $conn.CreateCommand()
            $scannedCmd.CommandText = $scannedQuery
            $scannedCmd.CommandTimeout = 30
            
            $scannedAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($scannedCmd)
            $scannedDataset = New-Object System.Data.DataSet
            $scannedAdapter.Fill($scannedDataset) | Out-Null
            
            foreach ($row in $scannedDataset.Tables[0].Rows) {
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
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Summary = $summary
            ScannedIndexes = $scannedIndexes
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/index/execute-details
# Returns details from the last EXECUTE run
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/execute-details' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get last EXECUTE run info
        $statusQuery = @"
            SELECT started_dttm, completed_dttm, last_duration_seconds,
                   items_processed, items_added, items_skipped, items_failed
            FROM ServerOps.Index_Status
            WHERE process_name = 'EXECUTE'
"@
        $statusCmd = $conn.CreateCommand()
        $statusCmd.CommandText = $statusQuery
        $statusCmd.CommandTimeout = 10
        
        $statusAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($statusCmd)
        $statusDataset = New-Object System.Data.DataSet
        $statusAdapter.Fill($statusDataset) | Out-Null
        
        $summary = $null
        $startedDttm = $null
        if ($statusDataset.Tables[0].Rows.Count -gt 0) {
            $row = $statusDataset.Tables[0].Rows[0]
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
        
        # Get rebuilt indexes from last run
        $rebuiltIndexes = @()
        if ($startedDttm) {
            $rebuildQuery = @"
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
                WHERE el.started_dttm >= '$($startedDttm.ToString("yyyy-MM-dd HH:mm:ss"))'
                  AND el.status IN ('SUCCESS', 'PARTIAL')
                ORDER BY sr.server_id, dr.database_id, el.started_dttm
"@
            $rebuildCmd = $conn.CreateCommand()
            $rebuildCmd.CommandText = $rebuildQuery
            $rebuildCmd.CommandTimeout = 10
            
            $rebuildAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($rebuildCmd)
            $rebuildDataset = New-Object System.Data.DataSet
            $rebuildAdapter.Fill($rebuildDataset) | Out-Null
            
            foreach ($row in $rebuildDataset.Tables[0].Rows) {
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
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Summary = $summary
            RebuiltIndexes = $rebuiltIndexes
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# GET /api/index/stats-details
# Returns details from the last STATS run - summary by database plus failures
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/stats-details' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get last STATS run info
        $statusQuery = @"
            SELECT started_dttm, completed_dttm, last_duration_seconds,
                   items_processed, items_added, items_skipped, items_failed
            FROM ServerOps.Index_Status
            WHERE process_name = 'STATS'
"@
        $statusCmd = $conn.CreateCommand()
        $statusCmd.CommandText = $statusQuery
        $statusCmd.CommandTimeout = 10
        
        $statusAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($statusCmd)
        $statusDataset = New-Object System.Data.DataSet
        $statusAdapter.Fill($statusDataset) | Out-Null
        
        $summary = $null
        $lastRunId = $null
        if ($statusDataset.Tables[0].Rows.Count -gt 0) {
            $row = $statusDataset.Tables[0].Rows[0]
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
        
        # Get max run_id for last run
        $runIdQuery = "SELECT MAX(run_id) AS LastRunId FROM ServerOps.Index_StatsExecutionLog"
        $runIdCmd = $conn.CreateCommand()
        $runIdCmd.CommandText = $runIdQuery
        $runIdCmd.CommandTimeout = 10
        $lastRunId = $runIdCmd.ExecuteScalar()
        
        # Get summary by database for last run
        $byDatabase = @()
        if ($lastRunId -and $lastRunId -isnot [DBNull]) {
            $dbQuery = @"
                SELECT 
                    sr.server_name AS ServerName,
                    sel.database_name,
                    SUM(CASE WHEN sel.update_type = 'MODIFICATION' THEN 1 ELSE 0 END) AS ModificationCount,
                    SUM(CASE WHEN sel.update_type = 'STALENESS' THEN sel.stats_count ELSE 0 END) AS StalenessCount,
                    SUM(sel.duration_ms) AS TotalDurationMs
                FROM ServerOps.Index_StatsExecutionLog sel
                JOIN dbo.DatabaseRegistry dr ON sel.database_id = dr.database_id
                JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
                WHERE sel.run_id = $lastRunId
                  AND sel.status IN ('SUCCESS', 'SKIPPED')
                GROUP BY sr.server_name, sel.database_name, sr.server_id, dr.database_id
                ORDER BY sr.server_id, dr.database_id
"@
            $dbCmd = $conn.CreateCommand()
            $dbCmd.CommandText = $dbQuery
            $dbCmd.CommandTimeout = 10
            
            $dbAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($dbCmd)
            $dbDataset = New-Object System.Data.DataSet
            $dbAdapter.Fill($dbDataset) | Out-Null
            
            foreach ($row in $dbDataset.Tables[0].Rows) {
                $byDatabase += [PSCustomObject]@{
                    ServerName = $row['ServerName']
                    DatabaseName = $row['database_name']
                    ModificationCount = if ($row['ModificationCount'] -is [DBNull]) { 0 } else { [int]$row['ModificationCount'] }
                    StalenessCount = if ($row['StalenessCount'] -is [DBNull]) { 0 } else { [int]$row['StalenessCount'] }
                    DurationMs = if ($row['TotalDurationMs'] -is [DBNull]) { 0 } else { [int]$row['TotalDurationMs'] }
                }
            }
        }
        
        # Get totals for summary cards
        $totalModifications = 0
        $totalStaleness = 0
        if ($lastRunId -and $lastRunId -isnot [DBNull]) {
            $totalsQuery = @"
                SELECT 
                    SUM(CASE WHEN update_type = 'MODIFICATION' AND status = 'SUCCESS' THEN 1 ELSE 0 END) AS TotalModifications,
                    SUM(CASE WHEN update_type = 'STALENESS' AND status = 'SUCCESS' THEN stats_count ELSE 0 END) AS TotalStaleness
                FROM ServerOps.Index_StatsExecutionLog
                WHERE run_id = $lastRunId
"@
            $totalsCmd = $conn.CreateCommand()
            $totalsCmd.CommandText = $totalsQuery
            $totalsCmd.CommandTimeout = 10
            
            $totalsAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($totalsCmd)
            $totalsDataset = New-Object System.Data.DataSet
            $totalsAdapter.Fill($totalsDataset) | Out-Null
            
            if ($totalsDataset.Tables[0].Rows.Count -gt 0) {
                $totRow = $totalsDataset.Tables[0].Rows[0]
                $totalModifications = if ($totRow['TotalModifications'] -is [DBNull]) { 0 } else { [int]$totRow['TotalModifications'] }
                $totalStaleness = if ($totRow['TotalStaleness'] -is [DBNull]) { 0 } else { [int]$totRow['TotalStaleness'] }
            }
        }
        
        # Get failures from last run
        $failures = @()
        if ($lastRunId -and $lastRunId -isnot [DBNull]) {
            $failQuery = @"
                SELECT 
                    database_name,
                    stat_name,
                    error_message
                FROM ServerOps.Index_StatsExecutionLog
                WHERE run_id = $lastRunId
                  AND status = 'FAILED'
                ORDER BY database_name, stat_name
"@
            $failCmd = $conn.CreateCommand()
            $failCmd.CommandText = $failQuery
            $failCmd.CommandTimeout = 10
            
            $failAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($failCmd)
            $failDataset = New-Object System.Data.DataSet
            $failAdapter.Fill($failDataset) | Out-Null
            
            foreach ($row in $failDataset.Tables[0].Rows) {
                $failures += [PSCustomObject]@{
                    DatabaseName = $row['database_name']
                    StatName = if ($row['stat_name'] -is [DBNull]) { $null } else { $row['stat_name'] }
                    ErrorMessage = if ($row['error_message'] -is [DBNull]) { $null } else { $row['error_message'] }
                }
            }
        }
        
        $conn.Close()
        
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

# ----------------------------------------------------------------------------
# GET /api/index/schedule/:databaseId
# Returns the maintenance schedule for a specific database (7 days x 24 hours)
# Also returns the holiday schedule (single row x 24 hours)
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Get -Path '/api/index/schedule/:databaseId' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $databaseId = [int]$WebEvent.Parameters['databaseId']
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get standard weekly schedule
        $query = @"
            SELECT 
                day_of_week,
                hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07,
                hr08, hr09, hr10, hr11, hr12, hr13, hr14, hr15,
                hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23
            FROM ServerOps.Index_DatabaseSchedule
            WHERE database_id = @DatabaseId
            ORDER BY day_of_week
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $cmd.Parameters.AddWithValue("@DatabaseId", $databaseId) | Out-Null
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $schedule = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $daySchedule = [PSCustomObject]@{
                DayOfWeek = [int]$row['day_of_week']
                Hr00 = [bool]$row['hr00']
                Hr01 = [bool]$row['hr01']
                Hr02 = [bool]$row['hr02']
                Hr03 = [bool]$row['hr03']
                Hr04 = [bool]$row['hr04']
                Hr05 = [bool]$row['hr05']
                Hr06 = [bool]$row['hr06']
                Hr07 = [bool]$row['hr07']
                Hr08 = [bool]$row['hr08']
                Hr09 = [bool]$row['hr09']
                Hr10 = [bool]$row['hr10']
                Hr11 = [bool]$row['hr11']
                Hr12 = [bool]$row['hr12']
                Hr13 = [bool]$row['hr13']
                Hr14 = [bool]$row['hr14']
                Hr15 = [bool]$row['hr15']
                Hr16 = [bool]$row['hr16']
                Hr17 = [bool]$row['hr17']
                Hr18 = [bool]$row['hr18']
                Hr19 = [bool]$row['hr19']
                Hr20 = [bool]$row['hr20']
                Hr21 = [bool]$row['hr21']
                Hr22 = [bool]$row['hr22']
                Hr23 = [bool]$row['hr23']
            }
            $schedule += $daySchedule
        }
        
        # Get holiday schedule
        $holidayQuery = @"
            SELECT 
                hr00, hr01, hr02, hr03, hr04, hr05, hr06, hr07,
                hr08, hr09, hr10, hr11, hr12, hr13, hr14, hr15,
                hr16, hr17, hr18, hr19, hr20, hr21, hr22, hr23
            FROM ServerOps.Index_HolidaySchedule
            WHERE database_id = @DatabaseId
"@
        
        $holidayCmd = $conn.CreateCommand()
        $holidayCmd.CommandText = $holidayQuery
        $holidayCmd.CommandTimeout = 10
        $holidayCmd.Parameters.AddWithValue("@DatabaseId", $databaseId) | Out-Null
        
        $holidayAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($holidayCmd)
        $holidayDataset = New-Object System.Data.DataSet
        $holidayAdapter.Fill($holidayDataset) | Out-Null
        
        $holidaySchedule = $null
        if ($holidayDataset.Tables[0].Rows.Count -gt 0) {
            $row = $holidayDataset.Tables[0].Rows[0]
            $holidaySchedule = [PSCustomObject]@{
                Hr00 = [bool]$row['hr00']
                Hr01 = [bool]$row['hr01']
                Hr02 = [bool]$row['hr02']
                Hr03 = [bool]$row['hr03']
                Hr04 = [bool]$row['hr04']
                Hr05 = [bool]$row['hr05']
                Hr06 = [bool]$row['hr06']
                Hr07 = [bool]$row['hr07']
                Hr08 = [bool]$row['hr08']
                Hr09 = [bool]$row['hr09']
                Hr10 = [bool]$row['hr10']
                Hr11 = [bool]$row['hr11']
                Hr12 = [bool]$row['hr12']
                Hr13 = [bool]$row['hr13']
                Hr14 = [bool]$row['hr14']
                Hr15 = [bool]$row['hr15']
                Hr16 = [bool]$row['hr16']
                Hr17 = [bool]$row['hr17']
                Hr18 = [bool]$row['hr18']
                Hr19 = [bool]$row['hr19']
                Hr20 = [bool]$row['hr20']
                Hr21 = [bool]$row['hr21']
                Hr22 = [bool]$row['hr22']
                Hr23 = [bool]$row['hr23']
            }
        }
        
        $conn.Close()
        
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

# ----------------------------------------------------------------------------
# POST /api/index/schedule/update
# Toggles a single hour cell in the maintenance schedule
# Body: { DatabaseId, DayOfWeek, Hour, Allowed }
# ----------------------------------------------------------------------------
Add-PodeRoute -Method Post -Path '/api/index/schedule/update' -Authentication 'ADLogin' -ScriptBlock {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
        try {
        $body = $WebEvent.Data
        $databaseId = [int]$body.DatabaseId
        $dayOfWeek = [int]$body.DayOfWeek
        $hour = [int]$body.Hour
        $allowed = [bool]$body.Allowed
        
        # Validate inputs
        if ($dayOfWeek -lt 0 -or $dayOfWeek -gt 6) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid day of week" }) -StatusCode 400
            return
        }
        if ($hour -lt 0 -or $hour -gt 23) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid hour" }) -StatusCode 400
            return
        }
        
        # Build the column name
        $hourColumn = "hr" + $hour.ToString("00")
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get current user for audit
        $currentUser = $WebEvent.Auth.User.Name
        if ([string]::IsNullOrEmpty($currentUser)) {
            $currentUser = "Unknown"
        }
        
        $query = @"
            UPDATE ServerOps.Index_DatabaseSchedule
            SET $hourColumn = @Allowed,
                modified_dttm = GETDATE(),
                modified_by = @ModifiedBy
            WHERE database_id = @DatabaseId
              AND day_of_week = @DayOfWeek
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $cmd.Parameters.AddWithValue("@Allowed", $allowed) | Out-Null
        $cmd.Parameters.AddWithValue("@DatabaseId", $databaseId) | Out-Null
        $cmd.Parameters.AddWithValue("@DayOfWeek", $dayOfWeek) | Out-Null
        $cmd.Parameters.AddWithValue("@ModifiedBy", $currentUser) | Out-Null
        
        $rowsAffected = $cmd.ExecuteNonQuery()
        
        $conn.Close()
        
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

# ----------------------------------------------------------------------------
# POST /api/index/schedule/update-batch
# Updates multiple hour cells in the maintenance schedule in a single call
# Body: { DatabaseId, Updates: [{ DayOfWeek, Hour, Allowed }, ...] }
# ----------------------------------------------------------------------------
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
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get current user for audit
        $currentUser = $WebEvent.Auth.User.Name
        if ([string]::IsNullOrEmpty($currentUser)) {
            $currentUser = "Unknown"
        }
        
        # Begin transaction for atomic update
        $transaction = $conn.BeginTransaction()
        
        try {
            $totalRowsAffected = 0
            
            foreach ($update in $updates) {
                $dayOfWeek = [int]$update.DayOfWeek
                $hour = [int]$update.Hour
                $allowed = [bool]$update.Allowed
                
                # Validate inputs
                if ($dayOfWeek -lt 1 -or $dayOfWeek -gt 7) {
                    throw "Invalid day of week: $dayOfWeek"
                }
                if ($hour -lt 0 -or $hour -gt 23) {
                    throw "Invalid hour: $hour"
                }
                
                # Build the column name
                $hourColumn = "hr" + $hour.ToString("00")
                
                $query = @"
                    UPDATE ServerOps.Index_DatabaseSchedule
                    SET $hourColumn = @Allowed,
                        modified_dttm = GETDATE(),
                        modified_by = @ModifiedBy
                    WHERE database_id = @DatabaseId
                      AND day_of_week = @DayOfWeek
"@
                
                $cmd = $conn.CreateCommand()
                $cmd.Transaction = $transaction
                $cmd.CommandText = $query
                $cmd.CommandTimeout = 10
                $cmd.Parameters.AddWithValue("@Allowed", $allowed) | Out-Null
                $cmd.Parameters.AddWithValue("@DatabaseId", $databaseId) | Out-Null
                $cmd.Parameters.AddWithValue("@DayOfWeek", $dayOfWeek) | Out-Null
                $cmd.Parameters.AddWithValue("@ModifiedBy", $currentUser) | Out-Null
                
                $rowsAffected = $cmd.ExecuteNonQuery()
                $totalRowsAffected += $rowsAffected
            }
            
            # Commit transaction
            $transaction.Commit()
            
            $conn.Close()
            
            Write-PodeJsonResponse -Value ([PSCustomObject]@{
                Success = $true
                DatabaseId = $databaseId
                UpdateCount = $updates.Count
                RowsAffected = $totalRowsAffected
                ModifiedBy = $currentUser
            })
        }
        catch {
            # Rollback on error
            $transaction.Rollback()
            throw
        }
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ----------------------------------------------------------------------------
# POST /api/index/schedule/holiday/update-batch
# Updates multiple hour cells in the holiday schedule in a single call
# Body: { DatabaseId, Updates: [{ Hour, Allowed }, ...] }
# Note: No DayOfWeek needed since holiday schedule is a single row
# ----------------------------------------------------------------------------
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
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get current user for audit
        $currentUser = $WebEvent.Auth.User.Name
        if ([string]::IsNullOrEmpty($currentUser)) {
            $currentUser = "Unknown"
        }
        
        # Build SET clause dynamically for all hours being updated
        $setClauses = @()
        foreach ($update in $updates) {
            $hour = [int]$update.Hour
            $allowed = if ([bool]$update.Allowed) { 1 } else { 0 }
            
            if ($hour -lt 0 -or $hour -gt 23) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid hour: $hour" }) -StatusCode 400
                $conn.Close()
                return
            }
            
            $hourColumn = "hr" + $hour.ToString("00")
            $setClauses += "$hourColumn = $allowed"
        }
        
        $setClause = $setClauses -join ", "
        
        $query = @"
            UPDATE ServerOps.Index_HolidaySchedule
            SET $setClause,
                modified_dttm = GETDATE(),
                modified_by = @ModifiedBy
            WHERE database_id = @DatabaseId
"@
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $cmd.Parameters.AddWithValue("@DatabaseId", $databaseId) | Out-Null
        $cmd.Parameters.AddWithValue("@ModifiedBy", $currentUser) | Out-Null
        
        $rowsAffected = $cmd.ExecuteNonQuery()
        
        $conn.Close()
        
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







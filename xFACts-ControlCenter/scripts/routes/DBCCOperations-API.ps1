# ============================================================================
# xFACts Control Center - DBCC Operations API Endpoints
# Location: E:\xFACts-ControlCenter\scripts\routes\DBCCOperations-API.ps1
# 
# API endpoints for the DBCC Operations monitoring page.
# Provides data for live progress, recent results, execution history,
# and schedule overview.
#
# Version: Tracked in dbo.System_Metadata (component: ServerOps.DBCC)
# ============================================================================

# ============================================================================
# API: Live Progress
# Returns active DBCC operations with percent_complete from DMV,
# plus PENDING/IN_PROGRESS items from ExecutionLog.
# Cross-server queries use executed_on_server from IN_PROGRESS rows.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/dbcc/live-progress' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $xfactsConn = New-Object System.Data.SqlClient.SqlConnection("Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;")
        $xfactsConn.Open()

        # Get all PENDING and IN_PROGRESS rows from ExecutionLog
        $logQuery = @"
            SELECT
                el.log_id, el.run_id, el.server_name, el.executed_on_server,
                el.database_name, el.operation, el.check_mode, el.max_dop,
                el.queued_dttm, el.started_dttm, el.status,
                CASE
                    WHEN el.status = 'IN_PROGRESS' AND el.started_dttm IS NOT NULL
                    THEN DATEDIFF(SECOND, el.started_dttm, GETDATE())
                    ELSE NULL
                END AS elapsed_seconds,
                CASE
                    WHEN el.status = 'PENDING' AND el.queued_dttm IS NOT NULL
                    THEN DATEDIFF(SECOND, el.queued_dttm, GETDATE())
                    ELSE NULL
                END AS queue_wait_seconds
            FROM ServerOps.DBCC_ExecutionLog el
            WHERE el.status IN ('PENDING', 'IN_PROGRESS')
            ORDER BY
                CASE el.status WHEN 'IN_PROGRESS' THEN 1 WHEN 'PENDING' THEN 2 END,
                el.queued_dttm ASC
"@

        $logCmd = $xfactsConn.CreateCommand()
        $logCmd.CommandText = $logQuery
        $logCmd.CommandTimeout = 10
        $logAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($logCmd)
        $logDataset = New-Object System.Data.DataSet
        $logAdapter.Fill($logDataset) | Out-Null

        $activeOps = @()
        $dmvTargets = @{}

        foreach ($row in $logDataset.Tables[0].Rows) {
            $op = [PSCustomObject]@{
                LogId            = [int]$row['log_id']
                RunId            = if ($row['run_id'] -is [DBNull]) { $null } else { [int]$row['run_id'] }
                ServerName       = $row['server_name']
                ExecutedOnServer = $row['executed_on_server']
                DatabaseName     = $row['database_name']
                Operation        = $row['operation']
                CheckMode        = if ($row['check_mode'] -is [DBNull]) { $null } else { $row['check_mode'] }
                MaxDop           = if ($row['max_dop'] -is [DBNull]) { $null } else { [int]$row['max_dop'] }
                QueuedDttm       = if ($row['queued_dttm'] -is [DBNull]) { $null } else { $row['queued_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                StartedDttm      = if ($row['started_dttm'] -is [DBNull]) { $null } else { $row['started_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                Status           = $row['status']
                ElapsedSeconds   = if ($row['elapsed_seconds'] -is [DBNull]) { $null } else { [int]$row['elapsed_seconds'] }
                QueueWaitSeconds = if ($row['queue_wait_seconds'] -is [DBNull]) { $null } else { [int]$row['queue_wait_seconds'] }
                PercentComplete  = $null
                EtaSeconds       = $null
            }

            $activeOps += $op

            # Collect unique physical servers to query for DMV data
            if ($op.Status -eq 'IN_PROGRESS' -and $op.ExecutedOnServer) {
                $dmvTargets[$op.ExecutedOnServer] = $true
            }
        }

        # Query DMV on each physical server for percent_complete
        $dmvQuery = @"
SELECT
    DB_NAME(r.database_id) AS database_name,
    r.command,
    CONVERT(NUMERIC(6,2), r.percent_complete) AS percent_complete,
    CONVERT(NUMERIC(10,2), r.total_elapsed_time/1000.0) AS elapsed_seconds_dmv,
    CONVERT(NUMERIC(10,2), r.estimated_completion_time/1000.0) AS eta_seconds
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.command LIKE 'DBCC%'
  AND r.percent_complete > 0
"@

        $dmvResults = @{}

        foreach ($targetServer in $dmvTargets.Keys) {
            try {
                $serverConn = New-Object System.Data.SqlClient.SqlConnection("Server=$targetServer;Database=master;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;")
                $serverConn.Open()
                $dmvCmd = $serverConn.CreateCommand()
                $dmvCmd.CommandText = $dmvQuery
                $dmvCmd.CommandTimeout = 10
                $dmvAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($dmvCmd)
                $dmvDataset = New-Object System.Data.DataSet
                $dmvAdapter.Fill($dmvDataset) | Out-Null
                $serverConn.Close()

                foreach ($dmvRow in $dmvDataset.Tables[0].Rows) {
                    $dbName = $dmvRow['database_name']
                    $key = "$targetServer|$dbName"
                    $dmvResults[$key] = @{
                        PercentComplete = if ($dmvRow['percent_complete'] -is [DBNull]) { 0 } else { [decimal]$dmvRow['percent_complete'] }
                        EtaSeconds      = if ($dmvRow['eta_seconds'] -is [DBNull]) { $null } else { [int]$dmvRow['eta_seconds'] }
                    }
                }
            }
            catch {
                # Server unreachable — skip silently, progress will show as null
            }
        }

        # Merge DMV data into active ops
        foreach ($op in $activeOps) {
            if ($op.Status -eq 'IN_PROGRESS' -and $op.ExecutedOnServer) {
                $key = "$($op.ExecutedOnServer)|$($op.DatabaseName)"
                if ($dmvResults.ContainsKey($key)) {
                    $op.PercentComplete = $dmvResults[$key].PercentComplete
                    $op.EtaSeconds = $dmvResults[$key].EtaSeconds
                }
            }
        }

        $xfactsConn.Close()

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            IsActive     = ($activeOps.Count -gt 0)
            ActiveOps    = $activeOps
            Timestamp    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Today's Executions
# Returns all completed executions from today, individual rows.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/dbcc/todays-executions' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()

        $query = @"
            SELECT
                el.log_id, el.run_id, el.server_name, el.executed_on_server,
                el.database_name, el.operation, el.check_mode,
                el.started_dttm, el.completed_dttm,
                el.duration_seconds, el.status, el.error_count,
                LEFT(el.error_details, 500) AS error_details,
                CASE
                    WHEN el.status = 'IN_PROGRESS' AND el.started_dttm IS NOT NULL
                    THEN DATEDIFF(SECOND, el.started_dttm, GETDATE())
                    ELSE NULL
                END AS elapsed_seconds
            FROM ServerOps.DBCC_ExecutionLog el
            WHERE CAST(el.queued_dttm AS DATE) = CAST(GETDATE() AS DATE)
              AND el.status NOT IN ('PENDING')
            ORDER BY
                CASE el.status WHEN 'IN_PROGRESS' THEN 0 ELSE 1 END,
                COALESCE(el.completed_dttm, el.started_dttm) DESC
"@

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 15
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()

        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                log_id             = [int]$row['log_id']
                run_id             = if ($row['run_id'] -is [DBNull]) { $null } else { [int]$row['run_id'] }
                server_name        = $row['server_name']
                executed_on_server = $row['executed_on_server']
                database_name      = $row['database_name']
                operation          = $row['operation']
                check_mode         = if ($row['check_mode'] -is [DBNull]) { $null } else { $row['check_mode'] }
                started_dttm       = if ($row['started_dttm'] -is [DBNull]) { $null } else { $row['started_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                completed_dttm     = if ($row['completed_dttm'] -is [DBNull]) { $null } else { $row['completed_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                duration_seconds   = if ($row['duration_seconds'] -is [DBNull]) { $null } else { [int]$row['duration_seconds'] }
                status             = $row['status']
                error_count        = if ($row['error_count'] -is [DBNull]) { 0 } else { [int]$row['error_count'] }
                error_details      = if ($row['error_details'] -is [DBNull]) { $null } else { $row['error_details'] }
                elapsed_seconds    = if ($row['elapsed_seconds'] -is [DBNull]) { $null } else { [int]$row['elapsed_seconds'] }
            }
        }

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Execution History Summary
# Returns summary stats grouped by year and month for accordion display.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/dbcc/execution-history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()

        $query = @"
            SELECT
                YEAR(el.queued_dttm) AS run_year,
                MONTH(el.queued_dttm) AS run_month,
                CAST(el.queued_dttm AS DATE) AS run_date,
                DATENAME(dw, el.queued_dttm) AS day_of_week,
                COUNT(*) AS operation_count,
                SUM(CASE WHEN el.status = 'SUCCESS' THEN 1 ELSE 0 END) AS success_count,
                SUM(CASE WHEN el.status = 'FAILED' THEN 1 ELSE 0 END) AS failed_count,
                SUM(CASE WHEN el.status = 'ERRORS_FOUND' THEN 1 ELSE 0 END) AS errors_found_count,
                SUM(ISNULL(el.duration_seconds, 0)) AS total_duration_seconds,
                COUNT(DISTINCT el.run_id) AS run_count
            FROM ServerOps.DBCC_ExecutionLog el
            WHERE el.status NOT IN ('PENDING', 'IN_PROGRESS')
            GROUP BY YEAR(el.queued_dttm), MONTH(el.queued_dttm),
                     CAST(el.queued_dttm AS DATE), DATENAME(dw, el.queued_dttm)
            ORDER BY run_date DESC
"@

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 15
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()

        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                run_year               = [int]$row['run_year']
                run_month              = [int]$row['run_month']
                run_date               = $row['run_date'].ToString("yyyy-MM-dd")
                day_of_week            = $row['day_of_week']
                operation_count        = [int]$row['operation_count']
                success_count          = [int]$row['success_count']
                failed_count           = [int]$row['failed_count']
                errors_found_count     = [int]$row['errors_found_count']
                total_duration_seconds = [int]$row['total_duration_seconds']
                run_count              = [int]$row['run_count']
            }
        }

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Execution History Day Detail
# Returns individual execution rows for a specific date.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/dbcc/execution-history-day' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $date = $WebEvent.Query['date']
        if (-not $date) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = 'date parameter required' }) -StatusCode 400
            return
        }

        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()

        $dateSafe = $date -replace "'", "''"

        $query = @"
            SELECT
                el.log_id, el.run_id, el.server_name, el.executed_on_server,
                el.database_name, el.operation, el.check_mode,
                el.started_dttm, el.completed_dttm,
                el.duration_seconds, el.status, el.error_count,
                LEFT(el.error_details, 2000) AS error_details,
                el.dbcc_summary_output
            FROM ServerOps.DBCC_ExecutionLog el
            WHERE CAST(el.queued_dttm AS DATE) = '$dateSafe'
              AND el.status NOT IN ('PENDING', 'IN_PROGRESS')
            ORDER BY el.started_dttm DESC
"@

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 15
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()

        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                log_id             = [int]$row['log_id']
                run_id             = if ($row['run_id'] -is [DBNull]) { $null } else { [int]$row['run_id'] }
                server_name        = $row['server_name']
                executed_on_server = $row['executed_on_server']
                database_name      = $row['database_name']
                operation          = $row['operation']
                check_mode         = if ($row['check_mode'] -is [DBNull]) { $null } else { $row['check_mode'] }
                started_dttm       = if ($row['started_dttm'] -is [DBNull]) { $null } else { $row['started_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                completed_dttm     = if ($row['completed_dttm'] -is [DBNull]) { $null } else { $row['completed_dttm'].ToString("yyyy-MM-dd HH:mm:ss") }
                duration_seconds   = if ($row['duration_seconds'] -is [DBNull]) { $null } else { [int]$row['duration_seconds'] }
                status             = $row['status']
                error_count        = if ($row['error_count'] -is [DBNull]) { 0 } else { [int]$row['error_count'] }
                error_details      = if ($row['error_details'] -is [DBNull]) { $null } else { $row['error_details'] }
                dbcc_summary_output = if ($row['dbcc_summary_output'] -is [DBNull]) { $null } else { $row['dbcc_summary_output'] }
            }
        }

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Schedule Overview
# Returns all DBCC_ScheduleConfig rows with server enable status.
# Time values converted to strings via CONVERT for clean JSON.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/dbcc/schedule' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()

        $query = @"
            SELECT
                sc.schedule_id, sc.server_id, sc.server_name, sc.database_name,
                sc.is_enabled, sc.check_mode, sc.replica_override,
                sr.serverops_dbcc_enabled AS server_enabled,
                sr.server_type,
                sc.checkdb_enabled,
                sc.checkdb_run_day,
                CONVERT(VARCHAR(5), sc.checkdb_run_time, 108) AS checkdb_run_time,
                sc.checkalloc_enabled,
                sc.checkalloc_run_day,
                CONVERT(VARCHAR(5), sc.checkalloc_run_time, 108) AS checkalloc_run_time,
                sc.checkcatalog_enabled,
                sc.checkcatalog_run_day,
                CONVERT(VARCHAR(5), sc.checkcatalog_run_time, 108) AS checkcatalog_run_time,
                sc.checkconstraints_enabled,
                sc.checkconstraints_run_day,
                CONVERT(VARCHAR(5), sc.checkconstraints_run_time, 108) AS checkconstraints_run_time
            FROM ServerOps.DBCC_ScheduleConfig sc
            INNER JOIN dbo.ServerRegistry sr ON sr.server_id = sc.server_id
            WHERE sr.is_active = 1
              AND sc.is_enabled = 1
            ORDER BY sc.server_id, sc.database_name
"@

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()

        $results = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $results += [PSCustomObject]@{
                schedule_id               = [int]$row['schedule_id']
                server_id                 = [int]$row['server_id']
                server_name               = $row['server_name']
                database_name             = $row['database_name']
                is_enabled                = [bool]$row['is_enabled']
                server_enabled            = [bool]$row['server_enabled']
                server_type               = $row['server_type']
                check_mode                = $row['check_mode']
                replica_override          = if ($row['replica_override'] -is [DBNull]) { $null } else { $row['replica_override'] }
                checkdb_enabled           = [bool]$row['checkdb_enabled']
                checkdb_run_day           = if ($row['checkdb_run_day'] -is [DBNull]) { $null } else { [int]$row['checkdb_run_day'] }
                checkdb_run_time          = if ($row['checkdb_run_time'] -is [DBNull]) { $null } else { $row['checkdb_run_time'] }
                checkalloc_enabled        = [bool]$row['checkalloc_enabled']
                checkalloc_run_day        = if ($row['checkalloc_run_day'] -is [DBNull]) { $null } else { [int]$row['checkalloc_run_day'] }
                checkalloc_run_time       = if ($row['checkalloc_run_time'] -is [DBNull]) { $null } else { $row['checkalloc_run_time'] }
                checkcatalog_enabled      = [bool]$row['checkcatalog_enabled']
                checkcatalog_run_day      = if ($row['checkcatalog_run_day'] -is [DBNull]) { $null } else { [int]$row['checkcatalog_run_day'] }
                checkcatalog_run_time     = if ($row['checkcatalog_run_time'] -is [DBNull]) { $null } else { $row['checkcatalog_run_time'] }
                checkconstraints_enabled  = [bool]$row['checkconstraints_enabled']
                checkconstraints_run_day  = if ($row['checkconstraints_run_day'] -is [DBNull]) { $null } else { [int]$row['checkconstraints_run_day'] }
                checkconstraints_run_time = if ($row['checkconstraints_run_time'] -is [DBNull]) { $null } else { $row['checkconstraints_run_time'] }
            }
        }

        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Server List (for filter dropdown population)
# Returns distinct server names from ScheduleConfig.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/dbcc/servers' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT DISTINCT sc.server_name
            FROM ServerOps.DBCC_ScheduleConfig sc
            INNER JOIN dbo.ServerRegistry sr ON sr.server_id = sc.server_id
            WHERE sr.is_active = 1
            ORDER BY sc.server_name
"@
        Write-PodeJsonResponse -Value $results
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Schedule Detail (single database)
# Returns the full schedule row for a specific schedule_id.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/dbcc/schedule-detail' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $scheduleId = $WebEvent.Query['schedule_id']
        if (-not $scheduleId) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = 'schedule_id parameter required' }) -StatusCode 400
            return
        }

        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()

        $query = @"
            SELECT
                sc.schedule_id, sc.server_name, sc.database_name,
                sc.is_enabled, sc.check_mode, sc.replica_override,
                sr.server_type,
                sc.checkdb_enabled, sc.checkdb_run_day,
                CONVERT(VARCHAR(5), sc.checkdb_run_time, 108) AS checkdb_run_time,
                sc.checkalloc_enabled, sc.checkalloc_run_day,
                CONVERT(VARCHAR(5), sc.checkalloc_run_time, 108) AS checkalloc_run_time,
                sc.checkcatalog_enabled, sc.checkcatalog_run_day,
                CONVERT(VARCHAR(5), sc.checkcatalog_run_time, 108) AS checkcatalog_run_time,
                sc.checkconstraints_enabled, sc.checkconstraints_run_day,
                CONVERT(VARCHAR(5), sc.checkconstraints_run_time, 108) AS checkconstraints_run_time
            FROM ServerOps.DBCC_ScheduleConfig sc
            INNER JOIN dbo.ServerRegistry sr ON sr.server_id = sc.server_id
            WHERE sc.schedule_id = $scheduleId
"@

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()

        if ($dataset.Tables[0].Rows.Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = 'Schedule not found' }) -StatusCode 404
            return
        }

        $row = $dataset.Tables[0].Rows[0]
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            schedule_id               = [int]$row['schedule_id']
            server_name               = $row['server_name']
            database_name             = $row['database_name']
            is_enabled                = [bool]$row['is_enabled']
            server_type               = $row['server_type']
            check_mode                = $row['check_mode']
            replica_override          = if ($row['replica_override'] -is [DBNull]) { $null } else { $row['replica_override'] }
            checkdb_enabled           = [bool]$row['checkdb_enabled']
            checkdb_run_day           = if ($row['checkdb_run_day'] -is [DBNull]) { $null } else { [int]$row['checkdb_run_day'] }
            checkdb_run_time          = if ($row['checkdb_run_time'] -is [DBNull]) { $null } else { $row['checkdb_run_time'] }
            checkalloc_enabled        = [bool]$row['checkalloc_enabled']
            checkalloc_run_day        = if ($row['checkalloc_run_day'] -is [DBNull]) { $null } else { [int]$row['checkalloc_run_day'] }
            checkalloc_run_time       = if ($row['checkalloc_run_time'] -is [DBNull]) { $null } else { $row['checkalloc_run_time'] }
            checkcatalog_enabled      = [bool]$row['checkcatalog_enabled']
            checkcatalog_run_day      = if ($row['checkcatalog_run_day'] -is [DBNull]) { $null } else { [int]$row['checkcatalog_run_day'] }
            checkcatalog_run_time     = if ($row['checkcatalog_run_time'] -is [DBNull]) { $null } else { $row['checkcatalog_run_time'] }
            checkconstraints_enabled  = [bool]$row['checkconstraints_enabled']
            checkconstraints_run_day  = if ($row['checkconstraints_run_day'] -is [DBNull]) { $null } else { [int]$row['checkconstraints_run_day'] }
            checkconstraints_run_time = if ($row['checkconstraints_run_time'] -is [DBNull]) { $null } else { $row['checkconstraints_run_time'] }
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Schedule Update (single operation on a database)
# Updates enabled, run_day, and run_time for one operation type.
# Body: { schedule_id, operation, enabled, run_day, run_time }
# Admin-only via Test-ActionEndpoint.
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/dbcc/schedule/update' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $scheduleId = [int]$body.schedule_id
        $operation = $body.operation
        $enabled = [bool]$body.enabled
        $runDay = $body.run_day
        $runTime = $body.run_time

        # Validate operation
        $validOps = @('CHECKDB', 'CHECKALLOC', 'CHECKCATALOG', 'CHECKCONSTRAINTS')
        if ($operation -notin $validOps) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid operation: $operation" }) -StatusCode 400
            return
        }

        # Map operation to column prefix
        $prefix = switch ($operation) {
            'CHECKDB'          { 'checkdb' }
            'CHECKALLOC'       { 'checkalloc' }
            'CHECKCATALOG'     { 'checkcatalog' }
            'CHECKCONSTRAINTS' { 'checkconstraints' }
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()

        # For CHECKDB: validate check_mode is not NONE when enabling
        if ($operation -eq 'CHECKDB' -and $enabled) {
            $modeCheck = New-Object System.Data.SqlClient.SqlCommand("SELECT check_mode FROM ServerOps.DBCC_ScheduleConfig WHERE schedule_id = @sid", $conn)
            $modeCheck.Parameters.AddWithValue("@sid", $scheduleId) | Out-Null
            $currentMode = $modeCheck.ExecuteScalar()
            if ($currentMode -eq 'NONE') {
                $conn.Close()
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Cannot enable CHECKDB while check_mode is NONE. Set check mode to PHYSICAL_ONLY or FULL first." }) -StatusCode 400
                return
            }
        }

        # Build day/time values
        $dayVal = if ($enabled -and $null -ne $runDay) { [int]$runDay } else { $null }
        $timeVal = if ($enabled -and $runTime) { $runTime } else { $null }

        $daySql = if ($null -ne $dayVal) { $dayVal.ToString() } else { "NULL" }
        $timeSql = if ($timeVal) { "'$($timeVal -replace "'", "''")'" } else { "NULL" }

        $query = @"
            UPDATE ServerOps.DBCC_ScheduleConfig
            SET ${prefix}_enabled = @Enabled,
                ${prefix}_run_day = $daySql,
                ${prefix}_run_time = $timeSql,
                modified_dttm = GETDATE(),
                modified_by = @ModifiedBy
            WHERE schedule_id = @ScheduleId
"@

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $cmd.Parameters.AddWithValue("@Enabled", $enabled) | Out-Null
        $cmd.Parameters.AddWithValue("@ScheduleId", $scheduleId) | Out-Null
        $cmd.Parameters.AddWithValue("@ModifiedBy", $user) | Out-Null

        $rowsAffected = $cmd.ExecuteNonQuery()
        $conn.Close()

        if ($rowsAffected -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Schedule record not found" }) -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            ScheduleId = $scheduleId
            Operation = $operation
            Enabled = $enabled
            RunDay = $dayVal
            RunTime = $timeVal
            ModifiedBy = $user
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Check Mode Update
# Sets the check_mode for a database schedule row.
# Body: { schedule_id, check_mode }
# check_mode: "NONE", "PHYSICAL_ONLY", or "FULL"
# Admin-only via Test-ActionEndpoint.
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/dbcc/schedule/check-mode' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $scheduleId = [int]$body.schedule_id
        $checkMode = $body.check_mode

        # Validate
        $validModes = @('NONE', 'PHYSICAL_ONLY', 'FULL')
        if ($checkMode -notin $validModes) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid check_mode: $checkMode. Must be NONE, PHYSICAL_ONLY, or FULL." }) -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()

        # If setting to NONE and CHECKDB is currently enabled, reject
        if ($checkMode -eq 'NONE') {
            $enabledCheck = New-Object System.Data.SqlClient.SqlCommand("SELECT checkdb_enabled FROM ServerOps.DBCC_ScheduleConfig WHERE schedule_id = @sid", $conn)
            $enabledCheck.Parameters.AddWithValue("@sid", $scheduleId) | Out-Null
            $checkdbEnabled = $enabledCheck.ExecuteScalar()
            if ($checkdbEnabled -eq $true) {
                $conn.Close()
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Cannot set check_mode to NONE while CHECKDB is enabled. Disable CHECKDB first." }) -StatusCode 400
                return
            }
        }

        $query = @"
            UPDATE ServerOps.DBCC_ScheduleConfig
            SET check_mode = @CheckMode,
                modified_dttm = GETDATE(),
                modified_by = @ModifiedBy
            WHERE schedule_id = @ScheduleId;
            SELECT @@ROWCOUNT AS rows_affected;
"@

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 10
        $cmd.Parameters.AddWithValue("@CheckMode", $checkMode) | Out-Null
        $cmd.Parameters.AddWithValue("@ScheduleId", $scheduleId) | Out-Null
        $cmd.Parameters.AddWithValue("@ModifiedBy", $user) | Out-Null

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        $conn.Close()

        $rowsAffected = if ($dataset.Tables[0].Rows.Count -gt 0) { [int]$dataset.Tables[0].Rows[0]['rows_affected'] } else { 0 }

        if ($rowsAffected -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Schedule record not found" }) -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            ScheduleId = $scheduleId
            CheckMode = $checkMode
            ModifiedBy = $user
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# ============================================================================
# API: Replica Override Update
# Sets or clears the replica_override for a database schedule row.
# Body: { schedule_id, replica_override }
# replica_override: "PRIMARY", "SECONDARY", or null (clear override)
# Admin-only via Test-ActionEndpoint.
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/dbcc/schedule/replica-override' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $scheduleId = [int]$body.schedule_id
        $replicaOverride = $body.replica_override

        # Validate — null/empty clears, otherwise must be PRIMARY or SECONDARY
        if ($replicaOverride -and $replicaOverride -notin @('PRIMARY', 'SECONDARY')) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid replica_override value: $replicaOverride. Must be PRIMARY, SECONDARY, or null." }) -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        $overrideVal = if ($replicaOverride) { "'$replicaOverride'" } else { "NULL" }

        $result = Invoke-XFActsQuery -Query @"
            UPDATE ServerOps.DBCC_ScheduleConfig
            SET replica_override = $overrideVal,
                modified_dttm = GETDATE(),
                modified_by = @ModifiedBy
            WHERE schedule_id = @ScheduleId;
            SELECT @@ROWCOUNT AS rows_affected;
"@ -Parameters @{ ScheduleId = $scheduleId; ModifiedBy = $user }

        if (-not $result -or $result.rows_affected -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Schedule record not found" }) -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success = $true
            ScheduleId = $scheduleId
            ReplicaOverride = $replicaOverride
            ModifiedBy = $user
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
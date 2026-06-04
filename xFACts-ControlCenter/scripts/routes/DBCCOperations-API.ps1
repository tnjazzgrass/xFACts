<#
.SYNOPSIS
    Control Center API endpoints for the DBCC Operations monitoring page.

.DESCRIPTION
    Registers the read and schedule-edit endpoints backing the DBCC
    Operations dashboard: live progress (with cross-server DMV percent
    complete), today's executions, execution-history summary and day detail,
    schedule overview, server list, schedule detail, and the per-operation
    schedule / check-mode / replica-override updates. Read endpoints return
    row arrays or shaped objects; update endpoints are admin-gated via
    Test-ActionEndpoint.

.COMPONENT
    ServerOps.DBCC

.NOTES
    File Name : DBCCOperations-API.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\DBCCOperations-API.ps1

    FILE ORGANIZATION
    -----------------
    ROUTE: API ENDPOINTS
#>

<# ============================================================================
   ROUTE: API ENDPOINTS
   ----------------------------------------------------------------------------
   The DBCC Operations API surface. Each endpoint guards with
   Test-ActionEndpoint, queries via Invoke-XFActsQuery against the xFACts
   listener (the live-progress endpoint additionally reads per-server DMVs
   via direct Invoke-Sqlcmd), and returns through Write-PodeJsonResponse.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/api/dbcc/live-progress' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $logRows = Invoke-XFActsQuery -Query @"
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

        $activeOps = @()
        $dmvTargets = @{}

        foreach ($row in $logRows) {
            $op = [PSCustomObject]@{
                LogId            = [int]$row['log_id']
                RunId            = if ($row['run_id'] -is [System.DBNull]) { $null } else { [int]$row['run_id'] }
                ServerName       = $row['server_name']
                ExecutedOnServer = $row['executed_on_server']
                DatabaseName     = $row['database_name']
                Operation        = $row['operation']
                CheckMode        = if ($row['check_mode'] -is [System.DBNull]) { $null } else { $row['check_mode'] }
                MaxDop           = if ($row['max_dop'] -is [System.DBNull]) { $null } else { [int]$row['max_dop'] }
                QueuedDttm       = if ($row['queued_dttm'] -is [System.DBNull]) { $null } else { ([datetime]$row['queued_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                StartedDttm      = if ($row['started_dttm'] -is [System.DBNull]) { $null } else { ([datetime]$row['started_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                Status           = $row['status']
                ElapsedSeconds   = if ($row['elapsed_seconds'] -is [System.DBNull]) { $null } else { [int]$row['elapsed_seconds'] }
                QueueWaitSeconds = if ($row['queue_wait_seconds'] -is [System.DBNull]) { $null } else { [int]$row['queue_wait_seconds'] }
                PercentComplete  = $null
                EtaSeconds       = $null
            }

            $activeOps += $op

            if ($op.Status -eq 'IN_PROGRESS' -and $op.ExecutedOnServer) {
                $dmvTargets[$op.ExecutedOnServer] = $true
            }
        }

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
                $dmvRows = Invoke-Sqlcmd -ServerInstance $targetServer -Database 'master' `
                    -Query $dmvQuery -QueryTimeout 10 `
                    -ApplicationName 'xFACts Control Center' `
                    -TrustServerCertificate -ErrorAction Stop

                foreach ($dmvRow in $dmvRows) {
                    $dbName = $dmvRow['database_name']
                    $key = "$targetServer|$dbName"
                    $dmvResults[$key] = @{
                        PercentComplete = if ($null -eq $dmvRow['percent_complete']) { 0 } else { [decimal]$dmvRow['percent_complete'] }
                        EtaSeconds      = if ($null -eq $dmvRow['eta_seconds']) { $null } else { [int]$dmvRow['eta_seconds'] }
                    }
                }
            }
            catch {
                # Server unreachable - skip silently; progress will show as null.
            }
        }

        foreach ($op in $activeOps) {
            if ($op.Status -eq 'IN_PROGRESS' -and $op.ExecutedOnServer) {
                $key = "$($op.ExecutedOnServer)|$($op.DatabaseName)"
                if ($dmvResults.ContainsKey($key)) {
                    $op.PercentComplete = $dmvResults[$key].PercentComplete
                    $op.EtaSeconds = $dmvResults[$key].EtaSeconds
                }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            IsActive  = ($activeOps.Count -gt 0)
            ActiveOps = $activeOps
            Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/dbcc/todays-executions' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
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

        $results = @()
        foreach ($row in $rows) {
            $results += [PSCustomObject]@{
                log_id             = [int]$row['log_id']
                run_id             = if ($row['run_id'] -is [System.DBNull]) { $null } else { [int]$row['run_id'] }
                server_name        = $row['server_name']
                executed_on_server = $row['executed_on_server']
                database_name      = $row['database_name']
                operation          = $row['operation']
                check_mode         = if ($row['check_mode'] -is [System.DBNull]) { $null } else { $row['check_mode'] }
                started_dttm       = if ($row['started_dttm'] -is [System.DBNull]) { $null } else { ([datetime]$row['started_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                completed_dttm     = if ($row['completed_dttm'] -is [System.DBNull]) { $null } else { ([datetime]$row['completed_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                duration_seconds   = if ($row['duration_seconds'] -is [System.DBNull]) { $null } else { [int]$row['duration_seconds'] }
                status             = $row['status']
                error_count        = if ($row['error_count'] -is [System.DBNull]) { 0 } else { [int]$row['error_count'] }
                error_details      = if ($row['error_details'] -is [System.DBNull]) { $null } else { $row['error_details'] }
                elapsed_seconds    = if ($row['elapsed_seconds'] -is [System.DBNull]) { $null } else { [int]$row['elapsed_seconds'] }
            }
        }

        Write-PodeJsonResponse -Value @($results)
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/dbcc/execution-history' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $rows = Invoke-XFActsQuery -Query @"
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

        $results = @()
        foreach ($row in $rows) {
            $results += [PSCustomObject]@{
                run_year               = [int]$row['run_year']
                run_month              = [int]$row['run_month']
                run_date               = ([datetime]$row['run_date']).ToString("yyyy-MM-dd")
                day_of_week            = $row['day_of_week']
                operation_count        = [int]$row['operation_count']
                success_count          = [int]$row['success_count']
                failed_count           = [int]$row['failed_count']
                errors_found_count     = [int]$row['errors_found_count']
                total_duration_seconds = [int]$row['total_duration_seconds']
                run_count              = [int]$row['run_count']
            }
        }

        Write-PodeJsonResponse -Value @($results)
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/dbcc/execution-history-day' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $date = $WebEvent.Query['date']
        if (-not $date) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = 'date parameter required' }) -StatusCode 400
            return
        }

        $rows = Invoke-XFActsQuery -Query @"
            SELECT
                el.log_id, el.run_id, el.server_name, el.executed_on_server,
                el.database_name, el.operation, el.check_mode,
                el.started_dttm, el.completed_dttm,
                el.duration_seconds, el.status, el.error_count,
                LEFT(el.error_details, 2000) AS error_details,
                el.dbcc_summary_output
            FROM ServerOps.DBCC_ExecutionLog el
            WHERE CAST(el.queued_dttm AS DATE) = @run_date
              AND el.status NOT IN ('PENDING', 'IN_PROGRESS')
            ORDER BY el.started_dttm DESC
"@ -Parameters @{ run_date = $date }

        $results = @()
        foreach ($row in $rows) {
            $results += [PSCustomObject]@{
                log_id              = [int]$row['log_id']
                run_id              = if ($row['run_id'] -is [System.DBNull]) { $null } else { [int]$row['run_id'] }
                server_name         = $row['server_name']
                executed_on_server  = $row['executed_on_server']
                database_name       = $row['database_name']
                operation           = $row['operation']
                check_mode          = if ($row['check_mode'] -is [System.DBNull]) { $null } else { $row['check_mode'] }
                started_dttm        = if ($row['started_dttm'] -is [System.DBNull]) { $null } else { ([datetime]$row['started_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                completed_dttm      = if ($row['completed_dttm'] -is [System.DBNull]) { $null } else { ([datetime]$row['completed_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                duration_seconds    = if ($row['duration_seconds'] -is [System.DBNull]) { $null } else { [int]$row['duration_seconds'] }
                status              = $row['status']
                error_count         = if ($row['error_count'] -is [System.DBNull]) { 0 } else { [int]$row['error_count'] }
                error_details       = if ($row['error_details'] -is [System.DBNull]) { $null } else { $row['error_details'] }
                dbcc_summary_output = if ($row['dbcc_summary_output'] -is [System.DBNull]) { $null } else { $row['dbcc_summary_output'] }
            }
        }

        Write-PodeJsonResponse -Value @($results)
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/dbcc/schedule' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $ctx = Get-UserContext -WebEvent $WebEvent

        $rows = Invoke-XFActsQuery -Query @"
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

        $schedules = @()
        foreach ($row in $rows) {
            $schedules += [PSCustomObject]@{
                schedule_id               = [int]$row['schedule_id']
                server_id                 = [int]$row['server_id']
                server_name               = $row['server_name']
                database_name             = $row['database_name']
                is_enabled                = [bool]$row['is_enabled']
                server_enabled            = [bool]$row['server_enabled']
                server_type               = $row['server_type']
                check_mode                = $row['check_mode']
                replica_override          = if ($row['replica_override'] -is [System.DBNull]) { $null } else { $row['replica_override'] }
                checkdb_enabled           = [bool]$row['checkdb_enabled']
                checkdb_run_day           = if ($row['checkdb_run_day'] -is [System.DBNull]) { $null } else { [int]$row['checkdb_run_day'] }
                checkdb_run_time          = if ($row['checkdb_run_time'] -is [System.DBNull]) { $null } else { $row['checkdb_run_time'] }
                checkalloc_enabled        = [bool]$row['checkalloc_enabled']
                checkalloc_run_day        = if ($row['checkalloc_run_day'] -is [System.DBNull]) { $null } else { [int]$row['checkalloc_run_day'] }
                checkalloc_run_time       = if ($row['checkalloc_run_time'] -is [System.DBNull]) { $null } else { $row['checkalloc_run_time'] }
                checkcatalog_enabled      = [bool]$row['checkcatalog_enabled']
                checkcatalog_run_day      = if ($row['checkcatalog_run_day'] -is [System.DBNull]) { $null } else { [int]$row['checkcatalog_run_day'] }
                checkcatalog_run_time     = if ($row['checkcatalog_run_time'] -is [System.DBNull]) { $null } else { $row['checkcatalog_run_time'] }
                checkconstraints_enabled  = [bool]$row['checkconstraints_enabled']
                checkconstraints_run_day  = if ($row['checkconstraints_run_day'] -is [System.DBNull]) { $null } else { [int]$row['checkconstraints_run_day'] }
                checkconstraints_run_time = if ($row['checkconstraints_run_time'] -is [System.DBNull]) { $null } else { $row['checkconstraints_run_time'] }
            }
        }

        $schedules = @($schedules)

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            IsAdmin   = [bool]$ctx.IsAdmin
            Schedules = $schedules
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/dbcc/servers' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT DISTINCT sc.server_name
            FROM ServerOps.DBCC_ScheduleConfig sc
            INNER JOIN dbo.ServerRegistry sr ON sr.server_id = sc.server_id
            WHERE sr.is_active = 1
            ORDER BY sc.server_name
"@
        Write-PodeJsonResponse -Value @($results)
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/dbcc/schedule-detail' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $scheduleId = $WebEvent.Query['schedule_id']
        if (-not $scheduleId) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = 'schedule_id parameter required' }) -StatusCode 400
            return
        }

        $rows = Invoke-XFActsQuery -Query @"
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
            WHERE sc.schedule_id = @schedule_id
"@ -Parameters @{ schedule_id = [int]$scheduleId }

        if (-not $rows -or @($rows).Count -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = 'Schedule not found' }) -StatusCode 404
            return
        }

        $row = @($rows)[0]
        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            schedule_id               = [int]$row['schedule_id']
            server_name               = $row['server_name']
            database_name             = $row['database_name']
            is_enabled                = [bool]$row['is_enabled']
            server_type               = $row['server_type']
            check_mode                = $row['check_mode']
            replica_override          = if ($row['replica_override'] -is [System.DBNull]) { $null } else { $row['replica_override'] }
            checkdb_enabled           = [bool]$row['checkdb_enabled']
            checkdb_run_day           = if ($row['checkdb_run_day'] -is [System.DBNull]) { $null } else { [int]$row['checkdb_run_day'] }
            checkdb_run_time          = if ($row['checkdb_run_time'] -is [System.DBNull]) { $null } else { $row['checkdb_run_time'] }
            checkalloc_enabled        = [bool]$row['checkalloc_enabled']
            checkalloc_run_day        = if ($row['checkalloc_run_day'] -is [System.DBNull]) { $null } else { [int]$row['checkalloc_run_day'] }
            checkalloc_run_time       = if ($row['checkalloc_run_time'] -is [System.DBNull]) { $null } else { $row['checkalloc_run_time'] }
            checkcatalog_enabled      = [bool]$row['checkcatalog_enabled']
            checkcatalog_run_day      = if ($row['checkcatalog_run_day'] -is [System.DBNull]) { $null } else { [int]$row['checkcatalog_run_day'] }
            checkcatalog_run_time     = if ($row['checkcatalog_run_time'] -is [System.DBNull]) { $null } else { $row['checkcatalog_run_time'] }
            checkconstraints_enabled  = [bool]$row['checkconstraints_enabled']
            checkconstraints_run_day  = if ($row['checkconstraints_run_day'] -is [System.DBNull]) { $null } else { [int]$row['checkconstraints_run_day'] }
            checkconstraints_run_time = if ($row['checkconstraints_run_time'] -is [System.DBNull]) { $null } else { $row['checkconstraints_run_time'] }
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/dbcc/schedule/update' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $scheduleId = [int]$body.schedule_id
        $operation = $body.operation
        $enabled = [bool]$body.enabled
        $runDay = $body.run_day
        $runTime = $body.run_time

        $validOps = @('CHECKDB', 'CHECKALLOC', 'CHECKCATALOG', 'CHECKCONSTRAINTS')
        if ($operation -notin $validOps) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid operation: $operation" }) -StatusCode 400
            return
        }

        $columnMap = @{
            'CHECKDB'          = @{ Enabled = 'checkdb_enabled';          Day = 'checkdb_run_day';          Time = 'checkdb_run_time' }
            'CHECKALLOC'       = @{ Enabled = 'checkalloc_enabled';       Day = 'checkalloc_run_day';       Time = 'checkalloc_run_time' }
            'CHECKCATALOG'     = @{ Enabled = 'checkcatalog_enabled';     Day = 'checkcatalog_run_day';     Time = 'checkcatalog_run_time' }
            'CHECKCONSTRAINTS' = @{ Enabled = 'checkconstraints_enabled'; Day = 'checkconstraints_run_day'; Time = 'checkconstraints_run_time' }
        }
        $cols = $columnMap[$operation]

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        if ($operation -eq 'CHECKDB' -and $enabled) {
            $modeRows = Invoke-XFActsQuery -Query @"
                SELECT check_mode
                FROM ServerOps.DBCC_ScheduleConfig
                WHERE schedule_id = @schedule_id
"@ -Parameters @{ schedule_id = $scheduleId }
            $currentMode = if ($modeRows -and @($modeRows).Count -gt 0) { @($modeRows)[0]['check_mode'] } else { $null }
            if ($currentMode -eq 'NONE') {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Cannot enable CHECKDB while check_mode is NONE. Set check mode to PHYSICAL_ONLY or FULL first." }) -StatusCode 400
                return
            }
        }

        $dayVal  = if ($enabled -and $null -ne $runDay) { [int]$runDay } else { $null }
        $timeVal = if ($enabled -and $runTime) { $runTime } else { $null }

        $result = Invoke-XFActsQuery -Query @"
            UPDATE ServerOps.DBCC_ScheduleConfig
            SET $($cols.Enabled) = @Enabled,
                $($cols.Day) = @RunDay,
                $($cols.Time) = @RunTime,
                modified_dttm = GETDATE(),
                modified_by = @ModifiedBy
            WHERE schedule_id = @ScheduleId;
            SELECT @@ROWCOUNT AS rows_affected;
"@ -Parameters @{
            Enabled    = $enabled
            RunDay     = $dayVal
            RunTime    = $timeVal
            ScheduleId = $scheduleId
            ModifiedBy = $user
        }

        $rowsAffected = if ($result -and @($result).Count -gt 0) { [int]@($result)[0]['rows_affected'] } else { 0 }
        if ($rowsAffected -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Schedule record not found" }) -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success    = $true
            ScheduleId = $scheduleId
            Operation  = $operation
            Enabled    = $enabled
            RunDay     = $dayVal
            RunTime    = $timeVal
            ModifiedBy = $user
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/dbcc/schedule/check-mode' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $scheduleId = [int]$body.schedule_id
        $checkMode = $body.check_mode

        $validModes = @('NONE', 'PHYSICAL_ONLY', 'FULL')
        if ($checkMode -notin $validModes) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid check_mode: $checkMode. Must be NONE, PHYSICAL_ONLY, or FULL." }) -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"

        if ($checkMode -eq 'NONE') {
            $enabledRows = Invoke-XFActsQuery -Query @"
                SELECT checkdb_enabled
                FROM ServerOps.DBCC_ScheduleConfig
                WHERE schedule_id = @schedule_id
"@ -Parameters @{ schedule_id = $scheduleId }
            $checkdbEnabled = if ($enabledRows -and @($enabledRows).Count -gt 0) { [bool]@($enabledRows)[0]['checkdb_enabled'] } else { $false }
            if ($checkdbEnabled) {
                Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Cannot set check_mode to NONE while CHECKDB is enabled. Disable CHECKDB first." }) -StatusCode 400
                return
            }
        }

        $result = Invoke-XFActsQuery -Query @"
            UPDATE ServerOps.DBCC_ScheduleConfig
            SET check_mode = @CheckMode,
                modified_dttm = GETDATE(),
                modified_by = @ModifiedBy
            WHERE schedule_id = @ScheduleId;
            SELECT @@ROWCOUNT AS rows_affected;
"@ -Parameters @{
            CheckMode  = $checkMode
            ScheduleId = $scheduleId
            ModifiedBy = $user
        }

        $rowsAffected = if ($result -and @($result).Count -gt 0) { [int]@($result)[0]['rows_affected'] } else { 0 }
        if ($rowsAffected -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Schedule record not found" }) -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success    = $true
            ScheduleId = $scheduleId
            CheckMode  = $checkMode
            ModifiedBy = $user
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

Add-PodeRoute -Method Post -Path '/api/dbcc/schedule/replica-override' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $body = $WebEvent.Data
        $scheduleId = [int]$body.schedule_id
        $replicaOverride = $body.replica_override

        if ($replicaOverride -and $replicaOverride -notin @('PRIMARY', 'SECONDARY')) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Invalid replica_override value: $replicaOverride. Must be PRIMARY, SECONDARY, or null." }) -StatusCode 400
            return
        }

        $user = "FAC\$($WebEvent.Auth.User.Username)"
        $overrideVal = if ($replicaOverride) { $replicaOverride } else { $null }

        $result = Invoke-XFActsQuery -Query @"
            UPDATE ServerOps.DBCC_ScheduleConfig
            SET replica_override = @ReplicaOverride,
                modified_dttm = GETDATE(),
                modified_by = @ModifiedBy
            WHERE schedule_id = @ScheduleId;
            SELECT @@ROWCOUNT AS rows_affected;
"@ -Parameters @{
            ReplicaOverride = $overrideVal
            ScheduleId      = $scheduleId
            ModifiedBy      = $user
        }

        $rowsAffected = if ($result -and @($result).Count -gt 0) { [int]@($result)[0]['rows_affected'] } else { 0 }
        if ($rowsAffected -eq 0) {
            Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = "Schedule record not found" }) -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            Success         = $true
            ScheduleId      = $scheduleId
            ReplicaOverride = $replicaOverride
            ModifiedBy      = $user
        })
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}
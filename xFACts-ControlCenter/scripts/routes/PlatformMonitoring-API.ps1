# ============================================================================
# xFACts Control Center - Platform Monitoring API
# Location: E:\xFACts-ControlCenter\scripts\routes\PlatformMonitoring-API.ps1
#
# API endpoints for the Platform Monitoring page.
# All endpoints read from existing Activity tables - no live server queries.
#
# NOTE: Helper functions are defined inside each ScriptBlock because Pode
#       routes execute in isolated runspaces. File-scope functions are not
#       visible inside route scriptblocks.
#
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.Platform)
# ============================================================================

# GET /api/platform-monitoring/servers
Add-PodeRoute -Method Get -Path '/api/platform-monitoring/servers' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $servers = Invoke-XFActsQuery -Query @"
            SELECT server_id, server_name
            FROM dbo.ServerRegistry
            WHERE is_active = 1
              AND server_id > 0
              AND server_type IN ('SQL_SERVER', 'AG_LISTENER')
            ORDER BY server_id
"@
        Write-PodeJsonResponse -Value @($servers)
    }
    catch {
        Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500
    }
}

# GET /api/platform-monitoring/impact-summary
Add-PodeRoute -Method Get -Path '/api/platform-monitoring/impact-summary' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $server = $WebEvent.Query['server']
        $range = $WebEvent.Query['range']; $from = $WebEvent.Query['from']; $to = $WebEvent.Query['to']

        if ($from -and $to) {
            $xeDF = " AND event_timestamp >= '$from' AND event_timestamp < DATEADD(DAY, 1, CAST('$to' AS DATE))"
            $rangeMinutes = ([datetime]$to - [datetime]$from).TotalMinutes + 1440  # include end day
        } else {
            $hours = switch ($range) { '1h' { 1 } '12h' { 12 } '7d' { 168 } default { 24 } }
            $xeDF = " AND event_timestamp >= DATEADD(HOUR, -$hours, GETDATE())"
            $rangeMinutes = $hours * 60
        }
        $srvF = if ($server -and $server -ne 'all') { " AND server_name = '$($server -replace "'","''")'" } else { '' }

        $xfacts = Invoke-XFActsQuery -Query @"
            SELECT server_name, COUNT(*) AS query_count,
                ISNULL(SUM(duration_ms), 0) AS total_duration_ms,
                ISNULL(SUM(cpu_time_ms), 0) AS total_cpu_ms,
                ISNULL(SUM(logical_reads), 0) AS total_logical_reads,
                ISNULL(SUM(writes), 0) AS total_writes
            FROM ServerOps.Activity_XE_xFACts
            WHERE 1=1 $xeDF $srvF
            GROUP BY server_name
"@

        # Get per-server CPU core counts for capacity calculation
        $cpuCores = Invoke-XFActsQuery -Query @"
            SELECT server_name, cpu_count
            FROM dbo.ServerRegistry
            WHERE is_active = 1 AND server_id > 0 AND cpu_count IS NOT NULL
                AND server_type = 'SQL_SERVER'
"@
        $coreLookup = @{}
        if ($cpuCores) { foreach ($c in $cpuCores) { $coreLookup[$c.server_name] = $c.cpu_count } }

        $results = @()

        if ($xfacts) {
            foreach ($x in $xfacts) {
                $cpuPct = $null; $capacityMs = $null
                if ($coreLookup.ContainsKey($x.server_name)) {
                    # Capacity = range_minutes * 60 seconds * 1000 ms * core_count
                    $capacityMs = $rangeMinutes * 60 * 1000 * $coreLookup[$x.server_name]
                    if ($capacityMs -gt 0) { $cpuPct = [math]::Round(($x.total_cpu_ms / $capacityMs) * 100, 3) }
                }
                $results += [PSCustomObject]@{
                    server_name = $x.server_name; query_count = $x.query_count
                    total_cpu_ms = $x.total_cpu_ms; total_logical_reads = $x.total_logical_reads
                    total_writes = $x.total_writes; total_duration_ms = $x.total_duration_ms
                    capacity_cpu_ms = $capacityMs; cpu_pct = $cpuPct
                }
            }
        }

        $aggCpu = ($results | Measure-Object -Property total_cpu_ms -Sum).Sum
        $aggCapacity = ($results | Where-Object { $null -ne $_.capacity_cpu_ms } | Measure-Object -Property capacity_cpu_ms -Sum).Sum
        $aggPct = if ($aggCapacity -gt 0) { [math]::Round(($aggCpu / $aggCapacity) * 100, 3) } else { $null }

        # Sort results by server_id for consistent display order
        $serverOrder = @{}
        $srvReg = Invoke-XFActsQuery -Query "SELECT server_id, server_name FROM dbo.ServerRegistry WHERE is_active = 1 AND server_id > 0 ORDER BY server_id"
        if ($srvReg) { foreach ($sr in $srvReg) { $serverOrder[$sr.server_name] = $sr.server_id } }
        $results = @($results | Sort-Object { if ($serverOrder.ContainsKey($_.server_name)) { $serverOrder[$_.server_name] } else { 9999 } })

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            servers = @($results)
            aggregate = [PSCustomObject]@{
                total_cpu_ms = $aggCpu; capacity_cpu_ms = $aggCapacity; cpu_pct = $aggPct
                total_queries = ($results | Measure-Object -Property query_count -Sum).Sum
                total_logical_reads = ($results | Measure-Object -Property total_logical_reads -Sum).Sum
                total_writes = ($results | Measure-Object -Property total_writes -Sum).Sum
                total_duration_ms = ($results | Measure-Object -Property total_duration_ms -Sum).Sum
            }
        })
    }
    catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# GET /api/platform-monitoring/summary-cards
Add-PodeRoute -Method Get -Path '/api/platform-monitoring/summary-cards' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $server = $WebEvent.Query['server']
        $range = $WebEvent.Query['range']; $from = $WebEvent.Query['from']; $to = $WebEvent.Query['to']

        if ($from -and $to) {
            $xeDF = " AND event_timestamp >= '$from' AND event_timestamp < DATEADD(DAY, 1, CAST('$to' AS DATE))"
        } else {
            $hours = switch ($range) { '1h' { 1 } '12h' { 12 } '7d' { 168 } default { 24 } }
            $xeDF = " AND event_timestamp >= DATEADD(HOUR, -$hours, GETDATE())"
        }
        $srvF = if ($server -and $server -ne 'all') { " AND server_name = '$($server -replace "'","''")'" } else { '' }

        $sessions = Invoke-XFActsQuery -Query @"
            ;WITH latest AS (SELECT MAX(snapshot_dttm) AS max_dttm FROM ServerOps.Activity_DMV_xFACts)
            SELECT COUNT(*) AS session_count, MAX(d.snapshot_dttm) AS snapshot_time
            FROM ServerOps.Activity_DMV_xFACts d CROSS JOIN latest l
            WHERE d.snapshot_dttm = l.max_dttm $srvF
"@

        $blocking = Invoke-XFActsQuery -Query @"
            SELECT 
                SUM(CASE WHEN blocked_client_app LIKE 'xFACts%' THEN 1 ELSE 0 END) AS blocked_by_others,
                SUM(CASE WHEN blocked_by_client_app LIKE 'xFACts%' AND (blocked_client_app NOT LIKE 'xFACts%' OR blocked_client_app IS NULL) THEN 1 ELSE 0 END) AS caused_by_xfacts,
                COUNT(*) AS block_count,
                MAX(event_timestamp) AS last_event
            FROM ServerOps.Activity_XE_BlockedProcess
            WHERE (blocked_client_app LIKE 'xFACts%' OR blocked_by_client_app LIKE 'xFACts%')
            $xeDF $srvF
"@

        $lrq = Invoke-XFActsQuery -Query @"
            SELECT COUNT(*) AS lrq_count, MAX(event_timestamp) AS last_event, MAX(duration_ms) AS max_duration_ms
            FROM ServerOps.Activity_XE_LRQ
            WHERE client_app_name LIKE 'xFACts%' $xeDF $srvF
"@

        $avgDur = Invoke-XFActsQuery -Query @"
            SELECT AVG(CAST(duration_ms AS FLOAT)) AS avg_duration_ms, COUNT(*) AS total_queries
            FROM ServerOps.Activity_XE_xFACts WHERE 1=1 $xeDF $srvF
"@

        $openTx = Invoke-XFActsQuery -Query @"
            ;WITH latest AS (SELECT MAX(snapshot_dttm) AS max_dttm FROM ServerOps.Activity_DMV_xFACts)
            SELECT ISNULL(SUM(d.open_transaction_count), 0) AS open_tx
            FROM ServerOps.Activity_DMV_xFACts d CROSS JOIN latest l
            WHERE d.snapshot_dttm = l.max_dttm AND d.open_transaction_count > 0 $srvF
"@

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            active_sessions   = if ($sessions) { $sessions.session_count } else { 0 }
            snapshot_time     = if ($sessions -and $sessions.snapshot_time) { $sessions.snapshot_time } else { $null }
            blocking_events   = if ($blocking) { $blocking.block_count } else { 0 }
            blocked_by_others = if ($blocking) { $blocking.blocked_by_others } else { 0 }
            caused_by_xfacts  = if ($blocking) { $blocking.caused_by_xfacts } else { 0 }
            blocking_last     = if ($blocking -and $blocking.last_event) { $blocking.last_event } else { $null }
            lrq_crossovers    = if ($lrq) { $lrq.lrq_count } else { 0 }
            lrq_last          = if ($lrq -and $lrq.last_event) { $lrq.last_event } else { $null }
            lrq_max_ms        = if ($lrq -and $lrq.max_duration_ms) { $lrq.max_duration_ms } else { $null }
            avg_duration_ms   = if ($avgDur -and $avgDur.avg_duration_ms) { [math]::Round($avgDur.avg_duration_ms, 2) } else { 0 }
            total_queries     = if ($avgDur) { $avgDur.total_queries } else { 0 }
            open_transactions = if ($openTx) { $openTx.open_tx } else { 0 }
        })
    }
    catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# GET /api/platform-monitoring/process-breakdown
Add-PodeRoute -Method Get -Path '/api/platform-monitoring/process-breakdown' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $server = $WebEvent.Query['server']
        $range = $WebEvent.Query['range']; $from = $WebEvent.Query['from']; $to = $WebEvent.Query['to']

        if ($from -and $to) {
            $xeDF = " AND event_timestamp >= '$from' AND event_timestamp < DATEADD(DAY, 1, CAST('$to' AS DATE))"
        } else {
            $hours = switch ($range) { '1h' { 1 } '12h' { 12 } '7d' { 168 } default { 24 } }
            $xeDF = " AND event_timestamp >= DATEADD(HOUR, -$hours, GETDATE())"
        }
        $srvF = if ($server -and $server -ne 'all') { " AND server_name = '$($server -replace "'","''")'" } else { '' }

        $results = Invoke-XFActsQuery -Query @"
            SELECT 
                client_app_name AS process_name,
                COUNT(*) AS query_count,
                ISNULL(SUM(duration_ms), 0) AS total_duration_ms,
                ISNULL(AVG(CAST(duration_ms AS FLOAT)), 0) AS avg_duration_ms,
                ISNULL(MAX(duration_ms), 0) AS max_duration_ms,
                ISNULL(SUM(cpu_time_ms), 0) AS total_cpu_ms,
                ISNULL(SUM(logical_reads), 0) AS total_logical_reads,
                ISNULL(SUM(physical_reads), 0) AS total_physical_reads,
                ISNULL(SUM(writes), 0) AS total_writes,
                ISNULL(SUM(row_count), 0) AS total_rows
            FROM ServerOps.Activity_XE_xFACts
            WHERE 1=1 $xeDF $srvF
            GROUP BY client_app_name
            ORDER BY total_cpu_ms DESC
"@
        Write-PodeJsonResponse -Value @($(if ($results) { $results } else { @() }))
    }
    catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# GET /api/platform-monitoring/trend
Add-PodeRoute -Method Get -Path '/api/platform-monitoring/trend' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $server = $WebEvent.Query['server']
        $range = $WebEvent.Query['range']; $from = $WebEvent.Query['from']; $to = $WebEvent.Query['to']

        # Bucket size
        $bucketMinutes = switch ($range) { '1h' { 5 } '12h' { 30 } '7d' { 360 }
            default {
                if ($from -and $to) {
                    $span = ([datetime]$to - [datetime]$from).TotalDays
                    if ($span -le 1) { 30 } elseif ($span -le 7) { 360 } else { 1440 }
                } else { 60 }
            }
        }

        if ($from -and $to) {
            $xeDF = " AND event_timestamp >= '$from' AND event_timestamp < DATEADD(DAY, 1, CAST('$to' AS DATE))"
        } else {
            $hours = switch ($range) { '1h' { 1 } '12h' { 12 } '7d' { 168 } default { 24 } }
            $xeDF = " AND event_timestamp >= DATEADD(HOUR, -$hours, GETDATE())"
        }
        $srvF = if ($server -and $server -ne 'all') { " AND server_name = '$($server -replace "'","''")'" } else { '' }

        # Get total CPU core count for capacity calculation
        # When filtering to a single server, use that server's cores; otherwise sum all monitored SQL servers
        $cpuData = Invoke-XFActsQuery -Query @"
            SELECT ISNULL(SUM(cpu_count), 0) AS total_cores
            FROM dbo.ServerRegistry
            WHERE is_active = 1 AND server_id > 0 AND cpu_count IS NOT NULL
                AND server_type = 'SQL_SERVER' $srvF
"@
        $totalCores = if ($cpuData -and $cpuData.total_cores -gt 0) { $cpuData.total_cores } else { $null }

        # Capacity per bucket = bucket_minutes * 60 seconds * 1000 ms * core_count
        # This is the total CPU milliseconds available in each time bucket (Task Manager model)
        $capacityPerBucket = if ($totalCores) { $bucketMinutes * 60 * 1000 * $totalCores } else { $null }

        $xfactsData = Invoke-XFActsQuery -Query @"
            SELECT 
                DATEADD(MINUTE, (DATEDIFF(MINUTE, '2000-01-01', event_timestamp) / $bucketMinutes) * $bucketMinutes, '2000-01-01') AS bucket,
                COUNT(*) AS query_count,
                ISNULL(SUM(cpu_time_ms), 0) AS cpu_ms,
                ISNULL(SUM(logical_reads), 0) AS logical_reads,
                ISNULL(SUM(duration_ms), 0) AS duration_ms
            FROM ServerOps.Activity_XE_xFACts
            WHERE 1=1 $xeDF $srvF
            GROUP BY DATEADD(MINUTE, (DATEDIFF(MINUTE, '2000-01-01', event_timestamp) / $bucketMinutes) * $bucketMinutes, '2000-01-01')
            ORDER BY bucket
"@

        $trendPoints = @()
        if ($xfactsData) {
            foreach ($x in $xfactsData) {
                $key = $x.bucket.ToString('yyyy-MM-dd HH:mm')
                $pct = if ($capacityPerBucket) { [math]::Round(($x.cpu_ms / $capacityPerBucket) * 100, 3) } else { $null }
                
                # Format label: include date for 7d+ ranges
                $label = if ($bucketMinutes -ge 360) { $x.bucket.ToString('MM/dd HH:mm') } else { $key }
                
                $trendPoints += [PSCustomObject]@{
                    bucket = $label; query_count = $x.query_count; xfacts_cpu_ms = $x.cpu_ms
                    capacity_cpu_ms = $capacityPerBucket; cpu_pct = $pct; logical_reads = $x.logical_reads; duration_ms = $x.duration_ms
                }
            }
        }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{ bucket_minutes = $bucketMinutes; points = @($trendPoints) })
    }
    catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# GET /api/platform-monitoring/api-performance
Add-PodeRoute -Method Get -Path '/api/platform-monitoring/api-performance' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $range = $WebEvent.Query['range']; $from = $WebEvent.Query['from']; $to = $WebEvent.Query['to']

        if ($from -and $to) {
            $dtF = " AND request_dttm >= '$from' AND request_dttm < DATEADD(DAY, 1, CAST('$to' AS DATE))"
        } else {
            $hours = switch ($range) { '1h' { 1 } '12h' { 12 } '7d' { 168 } default { 24 } }
            $dtF = " AND request_dttm >= DATEADD(HOUR, -$hours, GETDATE())"
        }

        $overall = Invoke-XFActsQuery -Query @"
            SELECT COUNT(*) AS total_requests, AVG(CAST(duration_ms AS FLOAT)) AS avg_duration_ms,
                COUNT(DISTINCT user_name) AS unique_users, MIN(request_dttm) AS first_request, MAX(request_dttm) AS last_request,
                SUM(CASE WHEN status_code >= 400 AND status_code <> 408 THEN 1 ELSE 0 END) AS error_count,
                SUM(CASE WHEN status_code = 408 THEN 1 ELSE 0 END) AS timeout_count
            FROM dbo.API_RequestLog WHERE source_application = 'ControlCenter' $dtF
"@

        $p95 = Invoke-XFActsQuery -Query @"
            SELECT DISTINCT PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms) OVER () AS p95_ms
            FROM dbo.API_RequestLog WHERE source_application = 'ControlCenter' AND duration_ms IS NOT NULL $dtF
"@

        $rpm = $null
        if ($overall -and $overall.first_request -and $overall.last_request -and $overall.total_requests -gt 0) {
            $spanMinutes = ([datetime]$overall.last_request - [datetime]$overall.first_request).TotalMinutes
            if ($spanMinutes -gt 0) { $rpm = [math]::Round($overall.total_requests / $spanMinutes, 1) }
        }

        $topEndpoints = Invoke-XFActsQuery -Query @"
            SELECT TOP 15 endpoint, COUNT(*) AS call_count, CAST(AVG(CAST(duration_ms AS FLOAT)) AS INT) AS avg_ms,
                MAX(duration_ms) AS max_ms, SUM(duration_ms) AS total_ms
            FROM dbo.API_RequestLog WHERE source_application = 'ControlCenter' AND duration_ms IS NOT NULL $dtF
            GROUP BY endpoint ORDER BY SUM(duration_ms) DESC
"@

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            total_requests = if ($overall) { $overall.total_requests } else { 0 }
            avg_duration_ms = if ($overall -and $overall.avg_duration_ms) { [math]::Round($overall.avg_duration_ms, 1) } else { 0 }
            p95_ms = if ($p95 -and $p95.p95_ms) { [math]::Round($p95.p95_ms, 1) } else { 0 }
            requests_per_min = $rpm; unique_users = if ($overall) { $overall.unique_users } else { 0 }
            error_count = if ($overall) { $overall.error_count } else { 0 }
            timeout_count = if ($overall) { $overall.timeout_count } else { 0 }
            top_endpoints = @($(if ($topEndpoints) { $topEndpoints } else { @() }))
        })
    }
    catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# ============================================================================
# GET /api/platform-monitoring/blocking-detail
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/platform-monitoring/blocking-detail' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $server = $WebEvent.Query['server']
        $range = $WebEvent.Query['range']; $from = $WebEvent.Query['from']; $to = $WebEvent.Query['to']

        if ($from -and $to) {
            $dtF = " AND event_timestamp >= '$from' AND event_timestamp < DATEADD(DAY, 1, CAST('$to' AS DATE))"
        } else {
            $hours = switch ($range) { '1h' { 1 } '12h' { 12 } '7d' { 168 } default { 24 } }
            $dtF = " AND event_timestamp >= DATEADD(HOUR, -$hours, GETDATE())"
        }
        $srvF = if ($server -and $server -ne 'all') { " AND server_name = '$($server -replace "'","''")'" } else { '' }

        $events = Invoke-XFActsQuery -Query @"
            SELECT TOP 50
                server_name,
                event_timestamp,
                CASE 
                    WHEN blocked_client_app LIKE 'xFACts%' AND (blocked_by_client_app NOT LIKE 'xFACts%' OR blocked_by_client_app IS NULL) THEN 'Blocked by Others'
                    WHEN blocked_by_client_app LIKE 'xFACts%' AND (blocked_client_app NOT LIKE 'xFACts%' OR blocked_client_app IS NULL) THEN 'Caused by xFACts'
                    ELSE 'xFACts on Both Sides'
                END AS direction,
                blocked_client_app,
                blocked_wait_time_ms,
                blocked_wait_type,
                LEFT(blocked_query_text, 300) AS blocked_query,
                blocked_by_client_app,
                blocked_by_status,
                LEFT(blocked_by_query_text, 300) AS blocker_query
            FROM ServerOps.Activity_XE_BlockedProcess
            WHERE (blocked_client_app LIKE 'xFACts%' OR blocked_by_client_app LIKE 'xFACts%')
            $dtF $srvF
            ORDER BY event_timestamp DESC
"@

        Write-PodeJsonResponse -Value @($(if ($events) { $events } else { @() }))
    }
    catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# ============================================================================
# GET /api/platform-monitoring/lrq-detail
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/platform-monitoring/lrq-detail' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $server = $WebEvent.Query['server']
        $range = $WebEvent.Query['range']; $from = $WebEvent.Query['from']; $to = $WebEvent.Query['to']

        if ($from -and $to) {
            $dtF = " AND event_timestamp >= '$from' AND event_timestamp < DATEADD(DAY, 1, CAST('$to' AS DATE))"
        } else {
            $hours = switch ($range) { '1h' { 1 } '12h' { 12 } '7d' { 168 } default { 24 } }
            $dtF = " AND event_timestamp >= DATEADD(HOUR, -$hours, GETDATE())"
        }
        $srvF = if ($server -and $server -ne 'all') { " AND server_name = '$($server -replace "'","''")'" } else { '' }

        $events = Invoke-XFActsQuery -Query @"
            SELECT TOP 50
                server_name,
                event_timestamp,
                client_app_name,
                database_name,
                duration_ms,
                cpu_time_ms,
                logical_reads,
                LEFT(sql_text, 500) AS sql_preview
            FROM ServerOps.Activity_XE_LRQ
            WHERE client_app_name LIKE 'xFACts%'
            $dtF $srvF
            ORDER BY event_timestamp DESC
"@

        Write-PodeJsonResponse -Value @($(if ($events) { $events } else { @() }))
    }
    catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# ============================================================================
# GET /api/platform-monitoring/api-errors
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/platform-monitoring/api-errors' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $range = $WebEvent.Query['range']; $from = $WebEvent.Query['from']; $to = $WebEvent.Query['to']

        if ($from -and $to) {
            $dtF = " AND request_dttm >= '$from' AND request_dttm < DATEADD(DAY, 1, CAST('$to' AS DATE))"
        } else {
            $hours = switch ($range) { '1h' { 1 } '12h' { 12 } '7d' { 168 } default { 24 } }
            $dtF = " AND request_dttm >= DATEADD(HOUR, -$hours, GETDATE())"
        }

        $errors = Invoke-XFActsQuery -Query @"
            SELECT TOP 50
                request_dttm,
                endpoint,
                http_method,
                status_code,
                user_name,
                duration_ms,
                client_ip
            FROM dbo.API_RequestLog
            WHERE source_application = 'ControlCenter'
                AND status_code >= 400 AND status_code <> 408
            $dtF
            ORDER BY request_dttm DESC
"@

        $timeouts = Invoke-XFActsQuery -Query @"
            SELECT 
                endpoint,
                COUNT(*) AS timeout_count,
                MAX(request_dttm) AS last_timeout
            FROM dbo.API_RequestLog
            WHERE source_application = 'ControlCenter'
                AND status_code = 408
            $dtF
            GROUP BY endpoint
            ORDER BY timeout_count DESC
"@

        $totalTimeouts = 0
        if ($timeouts) { $timeouts | ForEach-Object { $totalTimeouts += $_.timeout_count } }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            errors = @($(if ($errors) { $errors } else { @() }))
            timeouts = @($(if ($timeouts) { $timeouts } else { @() }))
            total_timeouts = $totalTimeouts
        })
    }
    catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}

# ============================================================================
# GET /api/platform-monitoring/api-users
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/platform-monitoring/api-users' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $range = $WebEvent.Query['range']; $from = $WebEvent.Query['from']; $to = $WebEvent.Query['to']

        if ($from -and $to) {
            $dtF = " AND request_dttm >= '$from' AND request_dttm < DATEADD(DAY, 1, CAST('$to' AS DATE))"
        } else {
            $hours = switch ($range) { '1h' { 1 } '12h' { 12 } '7d' { 168 } default { 24 } }
            $dtF = " AND request_dttm >= DATEADD(HOUR, -$hours, GETDATE())"
        }

        $users = Invoke-XFActsQuery -Query @"
            SELECT 
                user_name,
                COUNT(*) AS request_count,
                COUNT(DISTINCT endpoint) AS pages_used,
                MAX(request_dttm) AS last_active
            FROM dbo.API_RequestLog
            WHERE source_application = 'ControlCenter'
                AND user_name IS NOT NULL
            $dtF
            GROUP BY user_name
            ORDER BY request_count DESC
"@

        $unauthCount = Invoke-XFActsQuery -Query @"
            SELECT COUNT(*) AS unauth_count
            FROM dbo.API_RequestLog
            WHERE source_application = 'ControlCenter'
                AND user_name IS NULL
            $dtF
"@

        $totalAuth = 0
        if ($users) { $users | ForEach-Object { $totalAuth += $_.request_count } }

        Write-PodeJsonResponse -Value ([PSCustomObject]@{
            users = @($(if ($users) { $users } else { @() }))
            unauthenticated_requests = if ($unauthCount) { $unauthCount.unauth_count } else { 0 }
            total_authenticated = $totalAuth
        })
    }
    catch { Write-PodeJsonResponse -Value ([PSCustomObject]@{ Error = $_.Exception.Message }) -StatusCode 500 }
}
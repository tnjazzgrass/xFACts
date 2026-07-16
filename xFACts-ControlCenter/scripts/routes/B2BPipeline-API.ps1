<#
.SYNOPSIS
    Registers the B2B Pipeline API endpoints.

.DESCRIPTION
    Read-only API surface backing the B2B Pipeline dashboard. Exposes today's
    pulse counts, the true real-time live view read directly from the
    Integration source, the per-day history summary rollup, the filtered paged
    run query behind the runs modal, the single-run detail read, and the full
    captured Sterling status report for a failed run. All endpoints require
    ADLogin authentication and return JSON.

.COMPONENT
    B2B

.NOTES
    File Name : B2BPipeline-API.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\B2BPipeline-API.ps1

    FILE ORGANIZATION
    -----------------
    ROUTE: API ENDPOINTS
#>

<# ============================================================================
   ROUTE: API ENDPOINTS
   ----------------------------------------------------------------------------
   The B2B Pipeline API endpoints. Summary reads today's classification
   counts plus the current in-motion populations; live reads the in-motion
   runs directly from the Integration source for true real-time visibility;
   history-summary reads the per-day outcome rollups behind the summary tree;
   history runs the filtered paged run query behind the runs modal; run reads
   one tracking row in full; fault-report reads the full captured Sterling
   status report for one failed run.
   Prefix: b2b
   ============================================================================ #>

# Pulse Summary - today's run counts by outcome group plus the current in-motion populations.
Add-PodeRoute -Method Get -Path '/api/b2b-pipeline/summary' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT
                SUM(CASE WHEN source_insert_dttm >= CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END) AS runs_today,
                SUM(CASE WHEN source_insert_dttm >= CAST(GETDATE() AS DATE)
                          AND sterling_status = 'SUCCESS' THEN 1 ELSE 0 END) AS completed,
                SUM(CASE WHEN source_insert_dttm >= CAST(GETDATE() AS DATE)
                          AND sterling_status = 'FAILED' THEN 1 ELSE 0 END) AS failures,
                SUM(CASE WHEN source_insert_dttm >= CAST(GETDATE() AS DATE)
                          AND sterling_status = 'NO_ACTION' THEN 1 ELSE 0 END) AS no_files
            FROM B2B.INT_PipelineTracking
            WHERE source_insert_dttm >= DATEADD(DAY, -3, GETDATE())
               OR is_complete = 0
"@

        Write-PodeJsonResponse -Value @{ summary = ($results | Select-Object -First 1) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# Live Activity - true real-time in-motion runs read directly from the Integration
# source (rows appear the moment the pipeline writes them, ahead of collection).
# NOLOCK mirrors the Integration reconciliation job's own read pattern; dispatcher
# names enrich from the mirror where the run has already been collected. Scheduler
# dispatcher rows (status 2 with NULL SEQ_ID) are complete by definition and excluded.
Add-PodeRoute -Method Get -Path '/api/b2b-pipeline/live' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT
                bs.RUN_ID AS run_id,
                bs.CLIENT_ID AS client_id,
                mn.CLIENT_NAME AS client_name,
                f.PROCESS_TYPE AS process_type,
                f.COMM_METHOD AS comm_method,
                t.dispatcher_name,
                CASE WHEN bs.BATCH_STATUS = 0 THEN 'IN_FLIGHT' ELSE 'AWAITING_DM' END AS status_classification,
                bs.INSERT_DATE AS source_insert_dttm,
                DATEDIFF(MINUTE, bs.INSERT_DATE, GETDATE()) AS age_minutes
            FROM Integration.etl.tbl_B2B_CLIENTS_BATCH_STATUS bs WITH (NOLOCK)
            LEFT JOIN Integration.etl.tbl_B2B_CLIENTS_FILES f WITH (NOLOCK)
                ON f.CLIENT_ID = bs.CLIENT_ID
               AND f.SEQ_ID = bs.SEQ_ID
            LEFT JOIN Integration.etl.tbl_B2B_CLIENTS_MN mn WITH (NOLOCK)
                ON mn.CLIENT_ID = bs.CLIENT_ID
            LEFT JOIN B2B.INT_PipelineTracking t
                ON t.run_id = bs.RUN_ID
            WHERE bs.BATCH_STATUS IN (0, 2)
              AND NOT (bs.BATCH_STATUS = 2 AND bs.SEQ_ID IS NULL)
              AND bs.INSERT_DATE >= DATEADD(DAY, -3, GETDATE())
            ORDER BY bs.INSERT_DATE DESC
"@

        Write-PodeJsonResponse -Value @{ runs = @($results) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# History Summary - per-day outcome rollups across all mirrored history, newest first.
Add-PodeRoute -Method Get -Path '/api/b2b-pipeline/history-summary' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT
                CAST(source_insert_dttm AS DATE) AS run_date,
                COUNT(*) AS total,
                SUM(CASE WHEN sterling_status = 'SUCCESS' THEN 1 ELSE 0 END) AS success,
                SUM(CASE WHEN sterling_status = 'FAILED' THEN 1 ELSE 0 END) AS failed,
                SUM(CASE WHEN sterling_status = 'NO_ACTION' THEN 1 ELSE 0 END) AS no_action,
                SUM(CASE WHEN sterling_status = 'IN_PROGRESS' THEN 1 ELSE 0 END) AS in_progress,
                SUM(CASE WHEN sterling_status = 'UNDEFINED' THEN 1 ELSE 0 END) AS undefined_count,
                ISNULL(AVG(CASE WHEN completed_dttm IS NOT NULL THEN DATEDIFF(MINUTE, source_insert_dttm, completed_dttm) END), 0) AS avg_duration_min
            FROM B2B.INT_PipelineTracking
            GROUP BY CAST(source_insert_dttm AS DATE)
            ORDER BY run_date DESC
"@

        Write-PodeJsonResponse -Value @{ days = @($results) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# Process Types - the distinct process_type values present in the tracked data,
# for the history type filter. A NULL process_type is a parent/dispatcher run
# and is returned as the token DISPATCHER.
Add-PodeRoute -Method Get -Path '/api/b2b-pipeline/process-types' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT DISTINCT ISNULL(process_type, 'DISPATCHER') AS process_type
            FROM B2B.INT_PipelineTracking
            ORDER BY process_type
"@

        Write-PodeJsonResponse -Value @{ types = @($results | ForEach-Object { $_.process_type }) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# Run History - filtered paged run query. Query parameters: ?client=&sterlingStatus=&type=&from=&to=&incomplete=&page=&pageSize=.
# sterlingStatus accepts a single value or a comma-separated list (matched as IN).
# incomplete=1 restricts to in-motion runs (is_complete = 0).
Add-PodeRoute -Method Get -Path '/api/b2b-pipeline/history' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $client         = $WebEvent.Query['client']
        $sterlingStatus = $WebEvent.Query['sterlingStatus']
        $typeFilter     = $WebEvent.Query['type']
        $fromDate       = $WebEvent.Query['from']
        $toDate         = $WebEvent.Query['to']
        $incomplete     = $WebEvent.Query['incomplete']

        $page = 0
        if ($WebEvent.Query['page'] -match '^\d+$') { $page = [int]$WebEvent.Query['page'] }

        $pageSize = 50
        if ($WebEvent.Query['pageSize'] -match '^\d+$') { $pageSize = [Math]::Min([int]$WebEvent.Query['pageSize'], 200) }

        # Build the WHERE clause from the supplied filters; every value is parameterized.
        $whereClauses = New-Object System.Collections.Generic.List[string]
        $parameters = @{}

        if ($client) {
            [void]$whereClauses.Add("client_name LIKE '%' + @client + '%'")
            $parameters['client'] = $client
        }
        if ($sterlingStatus -and $sterlingStatus -ne 'ALL') {
            $statusValues = @($sterlingStatus.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($statusValues.Count -gt 0) {
                $statusParams = New-Object System.Collections.Generic.List[string]
                for ($i = 0; $i -lt $statusValues.Count; $i++) {
                    $pName = "status$i"
                    [void]$statusParams.Add("@$pName")
                    $parameters[$pName] = $statusValues[$i]
                }
                [void]$whereClauses.Add("sterling_status IN ($($statusParams -join ', '))")
            }
        }
        if ($typeFilter -and $typeFilter -ne 'ALL') {
            if ($typeFilter -eq 'DISPATCHER') {
                [void]$whereClauses.Add("process_type IS NULL")
            }
            else {
                [void]$whereClauses.Add("process_type = @ptype")
                $parameters['ptype'] = $typeFilter
            }
        }
        if ($fromDate -match '^\d{4}-\d{2}-\d{2}$') {
            [void]$whereClauses.Add("source_insert_dttm >= @fromDate")
            $parameters['fromDate'] = $fromDate
        }
        if ($toDate -match '^\d{4}-\d{2}-\d{2}$') {
            [void]$whereClauses.Add("source_insert_dttm < DATEADD(DAY, 1, CAST(@toDate AS DATE))")
            $parameters['toDate'] = $toDate
        }
        if ($incomplete -eq '1') {
            [void]$whereClauses.Add("is_complete = 0")
        }

        $whereSql = ''
        if ($whereClauses.Count -gt 0) {
            $whereSql = 'WHERE ' + ($whereClauses -join ' AND ')
        }

        $parameters['offsetRows'] = $page * $pageSize
        $parameters['pageSize'] = $pageSize

        $countResult = Invoke-XFActsQuery -Query @"
            SELECT COUNT(*) AS total_rows
            FROM B2B.INT_PipelineTracking
            $whereSql
"@ -Parameters $parameters

        $rows = Invoke-XFActsQuery -Query @"
            SELECT
                run_id,
                client_id,
                client_name,
                process_type,
                dispatcher_name,
                sterling_status,
                source_insert_dttm,
                DATEDIFF(MINUTE, source_insert_dttm, completed_dttm) AS duration_minutes
            FROM B2B.INT_PipelineTracking
            $whereSql
            ORDER BY source_insert_dttm DESC
            OFFSET @offsetRows ROWS FETCH NEXT @pageSize ROWS ONLY
"@ -Parameters $parameters

        Write-PodeJsonResponse -Value @{ runs = @($rows); total = ($countResult | Select-Object -First 1).total_rows }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# Run Detail - one tracking row in full. Query parameter: ?runId=.
Add-PodeRoute -Method Get -Path '/api/b2b-pipeline/run' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $runId = $WebEvent.Query['runId']
        if ($runId -notmatch '^\d+$') {
            Write-PodeJsonResponse -Value @{ error = 'Invalid runId' } -StatusCode 400
            return
        }

        $result = Invoke-XFActsQuery -Query @"
            SELECT
                tracking_id,
                run_id,
                parent_id,
                client_id,
                seq_id,
                batch_id,
                batch_status,
                source_insert_dttm,
                source_finish_dttm,
                process_type,
                comm_method,
                client_name,
                dispatcher_name,
                sterling_status,
                status_classification,
                dm_batch_status_code,
                sterling_check_result,
                is_complete,
                completed_dttm,
                DATEDIFF(MINUTE, source_insert_dttm, completed_dttm) AS duration_minutes,
                alert_count,
                collected_dttm,
                last_polled_dttm,
                fault_report_type,
                fault_report_code,
                fault_report_summary,
                fault_report_captured_dttm,
                CAST(CASE WHEN EXISTS (
                    SELECT 1 FROM B2B.SI_FaultReport fr WHERE fr.run_id = t.run_id
                ) THEN 1 ELSE 0 END AS BIT) AS has_fault_report
            FROM B2B.INT_PipelineTracking t
            WHERE t.run_id = @runId
"@ -Parameters @{ runId = [long]$runId }

        Write-PodeJsonResponse -Value @{ run = ($result | Select-Object -First 1) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# Fault Report - the full captured Sterling status report for one failed run.
# Query parameter: ?runId=. Returns the single SI_FaultReport row (1:1 with the
# run) carrying the parsed report JSON and the decompressed raw-text fallback,
# or a null report when the run carried no extractable report.
Add-PodeRoute -Method Get -Path '/api/b2b-pipeline/fault-report' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $runId = $WebEvent.Query['runId']
        if ($runId -notmatch '^\d+$') {
            Write-PodeJsonResponse -Value @{ error = 'Invalid runId' } -StatusCode 400
            return
        }

        $result = Invoke-XFActsQuery -Query @"
            SELECT
                fault_report_id,
                run_id,
                fault_report_type,
                source_name,
                report_json,
                raw_report_text,
                captured_dttm
            FROM B2B.SI_FaultReport
            WHERE run_id = @runId
"@ -Parameters @{ runId = [long]$runId }

        Write-PodeJsonResponse -Value @{ report = ($result | Select-Object -First 1) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}
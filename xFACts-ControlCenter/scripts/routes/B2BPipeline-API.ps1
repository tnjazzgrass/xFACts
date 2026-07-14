<#
.SYNOPSIS
    Registers the B2B Pipeline API endpoints.

.DESCRIPTION
    Read-only API surface backing the B2B Pipeline dashboard. Exposes today's
    pulse counts, the true real-time live view read directly from the
    Integration source, the workflow version census change list, the per-day
    history summary rollup, the filtered paged run query behind the runs
    modal, and the single-run detail read. All endpoints require ADLogin
    authentication and return JSON.

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
   census reads the workflow registry change list and totals; history-summary
   reads the per-day outcome rollups behind the summary tree; history runs
   the filtered paged run query behind the runs modal; run reads one tracking
   row in full.
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
                          AND status_classification = 'COMPLETE' THEN 1 ELSE 0 END) AS completed,
                SUM(CASE WHEN source_insert_dttm >= CAST(GETDATE() AS DATE)
                          AND status_classification IN ('STERLING_FAULT', 'DM_REJECTED', 'FAULT_POST_HANDOFF', 'DIED_UNHANDLED')
                          THEN 1 ELSE 0 END) AS failures,
                SUM(CASE WHEN source_insert_dttm >= CAST(GETDATE() AS DATE)
                          AND status_classification = 'NO_FILES' THEN 1 ELSE 0 END) AS no_files,
                SUM(CASE WHEN is_complete = 0 AND status_classification = 'IN_FLIGHT' THEN 1 ELSE 0 END) AS in_flight,
                SUM(CASE WHEN is_complete = 0 AND status_classification = 'AWAITING_DM'
                          AND source_insert_dttm >= DATEADD(DAY, -3, GETDATE()) THEN 1 ELSE 0 END) AS awaiting_dm
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
                SUM(CASE WHEN status_classification = 'COMPLETE' THEN 1 ELSE 0 END) AS completed,
                SUM(CASE WHEN status_classification IN ('STERLING_FAULT', 'DM_REJECTED', 'FAULT_POST_HANDOFF', 'DIED_UNHANDLED') THEN 1 ELSE 0 END) AS failures,
                SUM(CASE WHEN status_classification = 'NO_FILES' THEN 1 ELSE 0 END) AS no_files,
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

# Workflow Census - the most recent version changes plus catalog totals.
Add-PodeRoute -Method Get -Path '/api/b2b-pipeline/census' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $changes = Invoke-XFActsQuery -Query @"
            SELECT TOP 10
                wfd_id,
                workflow_name,
                previous_version,
                current_version,
                edited_by,
                last_version_change_dttm
            FROM B2B.SI_WorkflowRegistry
            WHERE last_version_change_dttm IS NOT NULL
            ORDER BY last_version_change_dttm DESC
"@

        $totals = Invoke-XFActsQuery -Query @"
            SELECT
                COUNT(*) AS definition_count,
                SUM(CASE WHEN last_version_change_dttm >= DATEADD(DAY, -30, GETDATE()) THEN 1 ELSE 0 END) AS changed_30d
            FROM B2B.SI_WorkflowRegistry
"@

        Write-PodeJsonResponse -Value @{ changes = @($changes); totals = ($totals | Select-Object -First 1) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# Run History - filtered paged run query. Query parameters: ?client=&classification=&type=&from=&to=&incomplete=&page=&pageSize=.
# classification accepts a single value or a comma-separated list (matched as IN).
# incomplete=1 restricts to in-motion runs (is_complete = 0).
Add-PodeRoute -Method Get -Path '/api/b2b-pipeline/history' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }

    try {
        $client         = $WebEvent.Query['client']
        $classification = $WebEvent.Query['classification']
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
        if ($classification -and $classification -ne 'ALL') {
            $classValues = @($classification.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($classValues.Count -gt 0) {
                $classParams = New-Object System.Collections.Generic.List[string]
                for ($i = 0; $i -lt $classValues.Count; $i++) {
                    $pName = "class$i"
                    [void]$classParams.Add("@$pName")
                    $parameters[$pName] = $classValues[$i]
                }
                [void]$whereClauses.Add("status_classification IN ($($classParams -join ', '))")
            }
        }
        if ($typeFilter -and $typeFilter -ne 'ALL') {
            [void]$whereClauses.Add("process_type = @ptype")
            $parameters['ptype'] = $typeFilter
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
                status_classification,
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
                status_classification,
                dm_batch_status_code,
                sterling_check_result,
                is_complete,
                completed_dttm,
                DATEDIFF(MINUTE, source_insert_dttm, completed_dttm) AS duration_minutes,
                alert_count,
                collected_dttm,
                last_polled_dttm
            FROM B2B.INT_PipelineTracking
            WHERE run_id = @runId
"@ -Parameters @{ runId = [long]$runId }

        Write-PodeJsonResponse -Value @{ run = ($result | Select-Object -First 1) }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}
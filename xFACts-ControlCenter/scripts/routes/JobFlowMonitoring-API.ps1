# ============================================================================
# xFACts Control Center - JobFlow Monitoring API Endpoints
# Location: E:\xFACts-ControlCenter\scripts\routes\JobFlowMonitoring-API.ps1
# Version: Tracked in dbo.System_Metadata (component: JobFlow)
#
# API endpoints for the JobFlow Monitoring page.
# Provides live activity from Debt Manager, process status, summaries, and history.
# ============================================================================

# ============================================================================
# API: Live Activity
# Returns currently executing jobs and pending queue from Debt Manager
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/live-activity' -Authentication 'ADLogin' -ScriptBlock {
    try {
        # Use AVG-PROD-LSNR for AG-aware connection to crs5_oltp
        $connString = "Server=AVG-PROD-LSNR;Database=crs5_oltp;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Currently Executing Jobs with progress
        $execCmd = $conn.CreateCommand()
        $execCmd.CommandText = @"
SELECT 
    j.job_shrt_nm AS job_name,
    j.job_nm AS job_full_name,
    jl.job_log_id,
    js.job_sqnc_shrt_nm AS flow_code,
    js.job_sqnc_nm AS flow_name,
    jse.job_exctn_ordr_nmbr AS flow_order,
    jl.job_exec_dttm AS job_init_dttm,
    jl.job_entty_ttl_nmbr AS total_records,
    COUNT(jel.job_entty_log_id) AS completed_records,
    COUNT(CASE WHEN jel.job_entty_log_err_rsn_txt IS NULL THEN jel.job_entty_log_id END) AS success_count,
    COUNT(CASE WHEN jel.job_entty_log_err_rsn_txt IS NOT NULL THEN jel.job_entty_log_id END) AS failure_count,
    MIN(jel.upsrt_dttm) AS first_record_dttm,
    MAX(jel.upsrt_dttm) AS last_record_dttm,
    CASE 
        WHEN jl.job_entty_ttl_nmbr IS NULL OR MIN(jel.upsrt_dttm) IS NULL OR COUNT(jel.job_entty_log_id) = 0 THEN NULL
        WHEN COUNT(jel.job_entty_log_id) > 0 AND COUNT(jel.job_entty_log_id) <> jl.job_entty_ttl_nmbr
            THEN COUNT(jel.job_entty_log_id) / NULLIF(DATEDIFF(ss, MIN(jel.upsrt_dttm), GETDATE()), 0)
        ELSE COUNT(jel.job_entty_log_id) / NULLIF(DATEDIFF(ss, MIN(jel.upsrt_dttm), DATEADD(ss, 1, MAX(jel.upsrt_dttm))), 0)
    END AS records_per_second,
    CASE 
        WHEN jl.job_entty_ttl_nmbr IS NULL OR MIN(jel.upsrt_dttm) IS NULL OR COUNT(jel.job_entty_log_id) = 0 THEN NULL
        WHEN COUNT(jel.job_entty_log_id) > 0 AND COUNT(jel.job_entty_log_id) <> jl.job_entty_ttl_nmbr
            THEN CAST(DATEADD(ss, 1, GETDATE()) - MIN(jel.upsrt_dttm) AS TIME(0))
        ELSE CAST(DATEADD(ss, 1, MAX(jel.upsrt_dttm)) - MIN(jel.upsrt_dttm) AS TIME(0))
    END AS elapsed_time,
    CASE 
        WHEN jl.job_entty_ttl_nmbr IS NULL OR MIN(jel.upsrt_dttm) IS NULL OR COUNT(jel.job_entty_log_id) = 0 THEN NULL
        WHEN COUNT(jel.job_entty_log_id) > 0 AND COUNT(jel.job_entty_log_id) <> jl.job_entty_ttl_nmbr
            THEN CAST(DATEADD(ss, 
                (jl.job_entty_ttl_nmbr - COUNT(jel.job_entty_log_id)) / 
                NULLIF(CAST(COUNT(jel.job_entty_log_id) / NULLIF(DATEDIFF(ss, MIN(jel.upsrt_dttm), DATEADD(ss, 1, GETDATE())), 0) + 1 AS NUMERIC), 0),
                GETDATE()) - GETDATE() AS TIME(0))
        ELSE NULL
    END AS time_remaining
FROM dbo.job_log jl WITH (NOLOCK)
INNER JOIN dbo.job j WITH (NOLOCK) ON j.job_id = jl.job_id
LEFT JOIN dbo.job_sqnc_exctn jse WITH (NOLOCK) ON jse.job_sqnc_exctn_id = jl.job_sqnc_exctn_id
LEFT JOIN dbo.job_sqnc js WITH (NOLOCK) ON js.job_sqnc_id = jse.job_sqnc_id
LEFT JOIN dbo.job_entty_log jel WITH (NOLOCK) ON jel.job_log_id = jl.job_log_id
WHERE CAST(jl.job_exec_dttm AS DATE) >= CAST(DATEADD(DAY, -3, GETDATE()) AS DATE)
  AND jl.job_stts_cd = 1  -- EXECUTING
GROUP BY
    js.job_sqnc_shrt_nm, js.job_sqnc_nm, jse.job_exctn_ordr_nmbr,
    jl.job_exec_dttm, j.job_shrt_nm, j.job_nm, jl.job_log_id, jl.job_entty_ttl_nmbr
ORDER BY jl.job_exec_dttm
"@
        $execCmd.CommandTimeout = 30
        $execAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($execCmd)
        $execDataset = New-Object System.Data.DataSet
        $execAdapter.Fill($execDataset) | Out-Null
        
        $executing = @()
        foreach ($row in $execDataset.Tables[0].Rows) {
            $executing += @{
                job_name = $row['job_name']
                job_full_name = if ($row['job_full_name'] -is [DBNull]) { $null } else { $row['job_full_name'] }
                job_log_id = $row['job_log_id']
                flow_code = if ($row['flow_code'] -is [DBNull]) { $null } else { $row['flow_code'] }
                flow_name = if ($row['flow_name'] -is [DBNull]) { $null } else { $row['flow_name'] }
                total_records = if ($row['total_records'] -is [DBNull]) { $null } else { [int]$row['total_records'] }
                completed_records = [int]$row['completed_records']
                success_count = [int]$row['success_count']
                failure_count = [int]$row['failure_count']
                records_per_second = if ($row['records_per_second'] -is [DBNull]) { $null } else { [int]$row['records_per_second'] }
                elapsed_time = if ($row['elapsed_time'] -is [DBNull]) { $null } else { $row['elapsed_time'].ToString() }
                time_remaining = if ($row['time_remaining'] -is [DBNull]) { $null } else { $row['time_remaining'].ToString() }
            }
        }
        
        # Pending Jobs
        $pendCmd = $conn.CreateCommand()
        $pendCmd.CommandText = @"
SELECT 
    js.job_sqnc_shrt_nm AS flow_code,
    j.job_shrt_nm AS job_name,
    jl.job_log_id,
    jl.job_exec_dttm AS queued_dttm
FROM dbo.job_log jl WITH (NOLOCK)
INNER JOIN dbo.job j WITH (NOLOCK) ON j.job_id = jl.job_id
LEFT JOIN dbo.job_sqnc_exctn jse WITH (NOLOCK) ON jse.job_sqnc_exctn_id = jl.job_sqnc_exctn_id
LEFT JOIN dbo.job_sqnc js WITH (NOLOCK) ON js.job_sqnc_id = jse.job_sqnc_id
WHERE CAST(jl.job_exec_dttm AS DATE) >= CAST(DATEADD(DAY, -3, GETDATE()) AS DATE)
  AND jl.job_stts_cd = 6  -- PENDING
ORDER BY jl.job_exec_dttm
"@
        $pendCmd.CommandTimeout = 15
        $pendAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($pendCmd)
        $pendDataset = New-Object System.Data.DataSet
        $pendAdapter.Fill($pendDataset) | Out-Null
        
        $pending = @()
        foreach ($row in $pendDataset.Tables[0].Rows) {
            $pending += @{
                job_name = $row['job_name']
                job_log_id = $row['job_log_id']
                flow_code = if ($row['flow_code'] -is [DBNull]) { $null } else { $row['flow_code'] }
                queued_time = if ($row['queued_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['queued_dttm']).ToString("HH:mm:ss") }
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            executing = $executing
            pending = $pending
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Process Status
# Returns status of all 7 Monitor-JobFlow.ps1 steps + stall indicator
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    process_name,
    last_status,
    last_result_count,
    completed_dttm,
    DATEDIFF(MINUTE, completed_dttm, GETDATE()) AS minutes_ago,
    stall_no_progress_count
FROM JobFlow.Status
ORDER BY status_id
"@
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        # Get stall threshold from GlobalConfig
        $threshCmd = $conn.CreateCommand()
        $threshCmd.CommandText = "SELECT CAST(setting_value AS INT) FROM dbo.GlobalConfig WHERE module_name = 'JobFlow' AND setting_name = 'StallThreshold' AND is_active = 1"
        $threshCmd.CommandTimeout = 5
        $stallThreshold = $threshCmd.ExecuteScalar()
        if ($null -eq $stallThreshold -or $stallThreshold -is [DBNull]) { $stallThreshold = 6 }
        
        $processes = @()
        $stallCount = 0
        
        # Display names for process cards
        $shortNames = @{
            'ConfigSync' = 'Flow Config Sync'
            'DetectFlows' = 'Flow Detection'
            'CaptureJobs' = 'Completed Jobs Capture'
            'UpdateProgress' = 'Flow Progress'
            'TransitionStates' = 'Flow State Transitions'
            'DetectStalls' = 'Stall Detection'
            'ValidateFlows' = 'Flow Validation'
            'DetectMissing' = 'Missing Flows'
        }
        
        foreach ($row in $dataset.Tables[0].Rows) {
            $minutesAgo = if ($row['minutes_ago'] -is [DBNull]) { $null } else { [int]$row['minutes_ago'] }
            $statusClass = 'healthy'
            if ($null -eq $minutesAgo -or $minutesAgo -gt 10) { $statusClass = 'warning' }
            if ($null -eq $minutesAgo -or $minutesAgo -gt 30) { $statusClass = 'error' }
            
            $timeAgo = if ($null -eq $minutesAgo) { '-' } elseif ($minutesAgo -lt 1) { 'just now' } elseif ($minutesAgo -eq 1) { '1 min ago' } else { "$minutesAgo min ago" }
            
            $processes += @{
                process_name = $row['process_name']
                short_name = $shortNames[$row['process_name']]
                last_status = if ($row['last_status'] -is [DBNull]) { $null } else { $row['last_status'] }
                last_result_count = if ($row['last_result_count'] -is [DBNull]) { $null } else { $row['last_result_count'] }
                time_ago = $timeAgo
                status_class = $statusClass
            }
            
            # Get stall count from DetectStalls row
            if ($row['process_name'] -eq 'DetectStalls' -and -not ($row['stall_no_progress_count'] -is [DBNull])) {
                $stallCount = [int]$row['stall_no_progress_count']
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            processes = $processes
            stall_count = $stallCount
            stall_threshold = [int]$stallThreshold
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Today's Summary
# Returns flow/job counts for today with list of flows
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/todays-summary' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Flow summary from FlowExecutionTracking joined with FlowConfig for flow_name
        # Groups multiple daily executions of the same flow into one summary
        $flowCmd = $conn.CreateCommand()
        $flowCmd.CommandText = @"
SELECT 
    t.job_sqnc_id,
    t.job_sqnc_shrt_nm AS flow_code,
    fc.job_sqnc_nm AS flow_name,
    COUNT(*) AS execution_count,
    STRING_AGG(CAST(t.tracking_id AS VARCHAR), ',') WITHIN GROUP (ORDER BY t.execution_window_start) AS tracking_ids,
    SUM(t.expected_job_count) AS total_expected_jobs,
    SUM(t.completed_job_count) AS total_completed_jobs,
    SUM(t.failed_job_count) AS total_failed_jobs,
    SUM(ISNULL(t.aggregate_completed_records, 0)) AS total_records,
    MIN(t.execution_window_start) AS first_start,
    MAX(ISNULL(t.completion_dttm, t.last_activity_dttm)) AS last_end,
    SUM(CASE 
        WHEN t.completion_dttm IS NOT NULL THEN DATEDIFF(SECOND, t.execution_window_start, t.completion_dttm)
        WHEN t.execution_window_start IS NOT NULL THEN DATEDIFF(SECOND, t.execution_window_start, ISNULL(t.last_activity_dttm, GETDATE()))
        ELSE 0
    END) AS total_duration_seconds,
    SUM(CASE WHEN t.execution_state IN ('COMPLETE', 'VALIDATED') THEN 1 ELSE 0 END) AS completed_executions,
    SUM(CASE WHEN t.execution_state = 'FAILED' THEN 1 ELSE 0 END) AS failed_executions,
    SUM(CASE WHEN t.execution_state IN ('DETECTED', 'EXECUTING') THEN 1 ELSE 0 END) AS active_executions
FROM JobFlow.FlowExecutionTracking t
LEFT JOIN JobFlow.FlowConfig fc ON t.job_sqnc_id = fc.job_sqnc_id
WHERE t.execution_date = CAST(GETDATE() AS DATE)
    AND t.job_sqnc_id > 0
GROUP BY t.job_sqnc_id, t.job_sqnc_shrt_nm, fc.job_sqnc_nm
ORDER BY MIN(t.execution_window_start) DESC
"@
        $flowCmd.CommandTimeout = 15
        $flowAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($flowCmd)
        $flowDataset = New-Object System.Data.DataSet
        $flowAdapter.Fill($flowDataset) | Out-Null
        
        # Content-based job counts from JobExecutionLog (per tracking_id)
        # These reflect actual outcome quality, not execution-progress status
        $contentCmd = $conn.CreateCommand()
        $contentCmd.CommandText = @"
SELECT 
    tracking_id,
    COUNT(*) AS total_jobs,
    SUM(CASE 
        WHEN error_message IS NOT NULL THEN 1
        WHEN ISNULL(total_records, 0) > 0 
             AND (succeeded_count IS NULL OR succeeded_count = 0) THEN 1
        ELSE 0
    END) AS failed_jobs,
    SUM(CASE 
        WHEN error_message IS NULL
             AND NOT (ISNULL(total_records, 0) > 0 
                      AND (succeeded_count IS NULL OR succeeded_count = 0))
        THEN 1 ELSE 0
    END) AS succeeded_jobs
FROM JobFlow.JobExecutionLog
WHERE execution_date = CAST(GETDATE() AS DATE)
  AND tracking_id IS NOT NULL
GROUP BY tracking_id
"@
        $contentCmd.CommandTimeout = 10
        $contentAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($contentCmd)
        $contentDataset = New-Object System.Data.DataSet
        $contentAdapter.Fill($contentDataset) | Out-Null
        
        # Build lookup: tracking_id -> { failed_jobs, succeeded_jobs }
        $contentLookup = @{}
        foreach ($cRow in $contentDataset.Tables[0].Rows) {
            $contentLookup[[int]$cRow['tracking_id']] = @{
                failed_jobs = [int]$cRow['failed_jobs']
                succeeded_jobs = [int]$cRow['succeeded_jobs']
            }
        }
        
        $flows = @()
        $totalFlows = 0
        $completedFlows = 0
        $executingFlows = 0
        $failedFlows = 0
        
        foreach ($row in $flowDataset.Tables[0].Rows) {
            $totalFlows++
            $completedExec = if ($row['completed_executions'] -is [DBNull]) { 0 } else { [int]$row['completed_executions'] }
            $failedExec = if ($row['failed_executions'] -is [DBNull]) { 0 } else { [int]$row['failed_executions'] }
            $activeExec = if ($row['active_executions'] -is [DBNull]) { 0 } else { [int]$row['active_executions'] }
            $execCount = if ($row['execution_count'] -is [DBNull]) { 0 } else { [int]$row['execution_count'] }
            
            # Determine overall state for the flow group
            $groupState = 'COMPLETE'
            if ($activeExec -gt 0) { 
                $groupState = 'EXECUTING'
                $executingFlows++ 
            }
            elseif ($failedExec -gt 0) { 
                $groupState = 'FAILED'
                $failedFlows++ 
            }
            else { 
                $completedFlows++ 
            }
            
            # Calculate total duration (sum of individual execution durations)
            $totalDurationSec = if ($row['total_duration_seconds'] -is [DBNull]) { $null } else { [int]$row['total_duration_seconds'] }
            $durationStr = '-'
            if ($null -ne $totalDurationSec) {
                if ($totalDurationSec -ge 3600) {
                    $hrs = [math]::Floor($totalDurationSec / 3600)
                    $mins = [math]::Floor(($totalDurationSec % 3600) / 60)
                    $durationStr = "{0}h {1}m" -f $hrs, $mins
                }
                elseif ($totalDurationSec -ge 60) {
                    $mins = [math]::Floor($totalDurationSec / 60)
                    $secs = $totalDurationSec % 60
                    $durationStr = "{0}m {1}s" -f $mins, $secs
                }
                else {
                    $durationStr = "{0}s" -f $totalDurationSec
                }
            }
            
            # Aggregate content-based counts across tracking_ids for this flow group
            $trackingIdStr = if ($row['tracking_ids'] -is [DBNull]) { $null } else { $row['tracking_ids'] }
            $contentSucceeded = 0
            $contentFailed = 0
            if ($trackingIdStr) {
                foreach ($tid in $trackingIdStr.Split(',')) {
                    $tidInt = [int]$tid.Trim()
                    if ($contentLookup.ContainsKey($tidInt)) {
                        $contentSucceeded += $contentLookup[$tidInt].succeeded_jobs
                        $contentFailed += $contentLookup[$tidInt].failed_jobs
                    }
                }
            }
            
            $flows += @{
                job_sqnc_id = $row['job_sqnc_id']
                flow_code = $row['flow_code']
                flow_name = if ($row['flow_name'] -is [DBNull]) { $null } else { $row['flow_name'] }
                execution_count = $execCount
                tracking_ids = $trackingIdStr
                execution_state = $groupState
                expected_jobs = if ($row['total_expected_jobs'] -is [DBNull]) { $null } else { [int]$row['total_expected_jobs'] }
                completed_jobs = $contentSucceeded
                failed_jobs = $contentFailed
                total_records = if ($row['total_records'] -is [DBNull]) { $null } else { [int]$row['total_records'] }
                duration = $durationStr
                completed_executions = $completedExec
                failed_executions = $failedExec
                active_executions = $activeExec
            }
        }
        
        # Ad-hoc jobs for today (job_sqnc_id IS NULL in JobExecutionLog)
        $adhocCmd = $conn.CreateCommand()
        $adhocCmd.CommandText = @"
SELECT 
    execution_detail_id,
    job_log_id,
    job_shrt_nm AS job_name,
    job_nm AS job_full_name,
    job_status,
    executed_by,
    total_records,
    succeeded_count,
    failed_count,
    execution_time_seconds,
    records_per_second,
    job_start_dttm,
    job_end_dttm,
    error_message
FROM JobFlow.JobExecutionLog
WHERE execution_date = CAST(GETDATE() AS DATE)
  AND job_sqnc_id IS NULL
ORDER BY job_exec_dttm DESC
"@
        $adhocCmd.CommandTimeout = 15
        $adhocAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($adhocCmd)
        $adhocDataset = New-Object System.Data.DataSet
        $adhocAdapter.Fill($adhocDataset) | Out-Null
        
        $adhocJobs = @()
        foreach ($row in $adhocDataset.Tables[0].Rows) {
            $totalRec = if ($row['total_records'] -is [DBNull]) { $null } else { [int]$row['total_records'] }
            $succeededCnt = if ($row['succeeded_count'] -is [DBNull]) { $null } else { [int]$row['succeeded_count'] }
            $hasError = -not ($row['error_message'] -is [DBNull])
            $isFailed = ($null -ne $totalRec -and $totalRec -gt 0 -and ($null -eq $succeededCnt -or $succeededCnt -eq 0)) -or $hasError
            
            $execSeconds = if ($row['execution_time_seconds'] -is [DBNull]) { $null } else { [int]$row['execution_time_seconds'] }
            $jobDuration = if ($null -eq $execSeconds) { '-' } else {
                $m = [math]::Floor($execSeconds / 60)
                $s = $execSeconds % 60
                if ($m -gt 0) { "{0}m {1}s" -f $m, $s } else { "{0}s" -f $s }
            }
            
            $adhocJobs += @{
                execution_detail_id = $row['execution_detail_id']
                job_log_id = if ($row['job_log_id'] -is [DBNull]) { $null } else { $row['job_log_id'] }
                job_name = $row['job_name']
                job_full_name = if ($row['job_full_name'] -is [DBNull]) { $null } else { $row['job_full_name'] }
                job_status = $row['job_status']
                is_failed = $isFailed
                executed_by = if ($row['executed_by'] -is [DBNull]) { $null } else { $row['executed_by'] }
                total_records = $totalRec
                succeeded_count = $succeededCnt
                failed_count = if ($row['failed_count'] -is [DBNull]) { 0 } else { [int]$row['failed_count'] }
                duration = $jobDuration
                records_per_second = if ($row['records_per_second'] -is [DBNull]) { $null } else { [decimal]$row['records_per_second'] }
                start_time = if ($row['job_start_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['job_start_dttm']).ToString("HH:mm:ss") }
                end_time = if ($row['job_end_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['job_end_dttm']).ToString("HH:mm:ss") }
                error_message = if ($row['error_message'] -is [DBNull]) { $null } else { $row['error_message'] }
            }
        }
        
        # Total job count for today
        $jobCmd = $conn.CreateCommand()
        $jobCmd.CommandText = @"
SELECT COUNT(*) AS total_jobs
FROM JobFlow.JobExecutionLog
WHERE execution_date = CAST(GETDATE() AS DATE)
"@
        $jobCmd.CommandTimeout = 10
        $totalJobs = [int]$jobCmd.ExecuteScalar()
        
        # Stall events for today from StallDetectionLog
        $stallCmd = $conn.CreateCommand()
        $stallCmd.CommandText = @"
SELECT 
    log_id,
    poll_dttm,
    counter_before,
    counter_after,
    event_type,
    stall_threshold,
    threshold_reached
FROM JobFlow.StallDetectionLog
WHERE CAST(poll_dttm AS DATE) = CAST(GETDATE() AS DATE)
ORDER BY poll_dttm
"@
        $stallCmd.CommandTimeout = 10
        $stallAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($stallCmd)
        $stallDataset = New-Object System.Data.DataSet
        $stallAdapter.Fill($stallDataset) | Out-Null
        
        # Group into episodes: each run of INCREMENTs (possibly reaching ALERT/STALLED) until RESET
        $stallEpisodes = @()
        $currentEpisode = $null
        
        foreach ($row in $stallDataset.Tables[0].Rows) {
            $eventType = $row['event_type'].ToString()
            $pollDttm = [DateTime]$row['poll_dttm']
            $counterAfter = [int]$row['counter_after']
            
            if ($eventType -eq 'INCREMENT' -or $eventType -eq 'ALERT' -or $eventType -eq 'STALLED') {
                if ($null -eq $currentEpisode) {
                    $currentEpisode = @{
                        start_time = $pollDttm.ToString("HH:mm")
                        end_time = $null
                        polls = 1
                        peak_counter = $counterAfter
                        threshold_reached = ($row['threshold_reached'] -eq $true -or $row['threshold_reached'] -eq 1)
                        resolved = $false
                        alert_sent = ($eventType -eq 'ALERT')
                    }
                }
                else {
                    $currentEpisode.polls++
                    if ($counterAfter -gt $currentEpisode.peak_counter) { $currentEpisode.peak_counter = $counterAfter }
                    if ($row['threshold_reached'] -eq $true -or $row['threshold_reached'] -eq 1) { $currentEpisode.threshold_reached = $true }
                    if ($eventType -eq 'ALERT') { $currentEpisode.alert_sent = $true }
                }
            }
            elseif ($eventType -eq 'RESET') {
                if ($null -ne $currentEpisode) {
                    $currentEpisode.end_time = $pollDttm.ToString("HH:mm")
                    $currentEpisode.resolved = $true
                    $stallEpisodes += $currentEpisode
                    $currentEpisode = $null
                }
            }
        }
        
        # If there's an open episode (no RESET yet), add it as ongoing
        if ($null -ne $currentEpisode) {
            $stallEpisodes += $currentEpisode
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            total_flows = $totalFlows
            completed_flows = $completedFlows
            executing_flows = $executingFlows
            failed_flows = $failedFlows
            total_jobs = $totalJobs
            flows = $flows
            adhoc_jobs = $adhocJobs
            stall_episodes = $stallEpisodes
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Flow Details
# Returns job details for a specific flow execution (slideout)
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/flow-details' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $trackingId = $WebEvent.Query['tracking_id']
        if ([string]::IsNullOrEmpty($trackingId)) {
            Write-PodeJsonResponse -Value @{ error = "tracking_id is required" } -StatusCode 400
            return
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Flow summary
        $flowCmd = $conn.CreateCommand()
        $flowCmd.CommandText = @"
SELECT 
    tracking_id,
    job_sqnc_shrt_nm AS flow_code,
    execution_state,
    expected_job_count,
    completed_job_count,
    failed_job_count,
    aggregate_completed_records,
    execution_window_start,
    completion_dttm,
    CASE 
        WHEN completion_dttm IS NOT NULL THEN DATEDIFF(MINUTE, execution_window_start, completion_dttm)
        WHEN execution_window_start IS NOT NULL THEN DATEDIFF(MINUTE, execution_window_start, GETDATE())
        ELSE NULL
    END AS duration_minutes
FROM JobFlow.FlowExecutionTracking
WHERE tracking_id = @tracking_id
"@
        $flowCmd.Parameters.AddWithValue("@tracking_id", [long]$trackingId) | Out-Null
        $flowCmd.CommandTimeout = 10
        $flowAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($flowCmd)
        $flowDataset = New-Object System.Data.DataSet
        $flowAdapter.Fill($flowDataset) | Out-Null
        
        if ($flowDataset.Tables[0].Rows.Count -eq 0) {
            $conn.Close()
            Write-PodeJsonResponse -Value @{ error = "Flow not found" } -StatusCode 404
            return
        }
        
        $flowRow = $flowDataset.Tables[0].Rows[0]
        $durationMin = if ($flowRow['duration_minutes'] -is [DBNull]) { $null } else { [int]$flowRow['duration_minutes'] }
        $durationStr = if ($null -eq $durationMin) { '-' } else {
            $hrs = [math]::Floor($durationMin / 60)
            $mins = $durationMin % 60
            if ($hrs -gt 0) { "{0}h {1}m" -f $hrs, $mins } else { "{0}m" -f $mins }
        }
        
        # Job details from JobExecutionLog
        $jobCmd = $conn.CreateCommand()
        $jobCmd.CommandText = @"
SELECT 
    execution_detail_id,
    job_log_id,
    job_shrt_nm AS job_name,
    job_nm AS job_full_name,
    job_status,
    total_records,
    succeeded_count,
    failed_count,
    execution_time_seconds,
    records_per_second,
    job_exec_dttm,
    job_start_dttm,
    job_end_dttm,
    error_message,
    executed_by,
    execution_order_nmbr
FROM JobFlow.JobExecutionLog
WHERE tracking_id = @tracking_id
ORDER BY execution_order_nmbr, job_exec_dttm
"@
        $jobCmd.Parameters.AddWithValue("@tracking_id", [long]$trackingId) | Out-Null
        $jobCmd.CommandTimeout = 15
        $jobAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($jobCmd)
        $jobDataset = New-Object System.Data.DataSet
        $jobAdapter.Fill($jobDataset) | Out-Null
        
        # Content-based counters for this execution
        $contentSucceeded = 0
        $contentFailed = 0
        
        $jobs = @()
        foreach ($row in $jobDataset.Tables[0].Rows) {
            $execSeconds = if ($row['execution_time_seconds'] -is [DBNull]) { $null } else { [int]$row['execution_time_seconds'] }
            $jobDuration = if ($null -eq $execSeconds) { '-' } else {
                $m = [math]::Floor($execSeconds / 60)
                $s = $execSeconds % 60
                if ($m -gt 0) { "{0}m {1}s" -f $m, $s } else { "{0}s" -f $s }
            }
            
            # Determine if job is failed using the specified logic
            $totalRec = if ($row['total_records'] -is [DBNull]) { $null } else { [int]$row['total_records'] }
            $succeededCnt = if ($row['succeeded_count'] -is [DBNull]) { $null } else { [int]$row['succeeded_count'] }
            $hasError = -not ($row['error_message'] -is [DBNull])
            $isFailed = ($null -ne $totalRec -and $totalRec -gt 0 -and ($null -eq $succeededCnt -or $succeededCnt -eq 0)) -or $hasError
            
            if ($isFailed) { $contentFailed++ } else { $contentSucceeded++ }
            
            $jobs += @{
                execution_detail_id = $row['execution_detail_id']
                job_log_id = if ($row['job_log_id'] -is [DBNull]) { $null } else { $row['job_log_id'] }
                job_name = $row['job_name']
                job_full_name = if ($row['job_full_name'] -is [DBNull]) { $null } else { $row['job_full_name'] }
                job_status = $row['job_status']
                is_failed = $isFailed
                total_records = $totalRec
                succeeded_count = $succeededCnt
                failed_count = if ($row['failed_count'] -is [DBNull]) { 0 } else { [int]$row['failed_count'] }
                duration = $jobDuration
                records_per_second = if ($row['records_per_second'] -is [DBNull]) { $null } else { [decimal]$row['records_per_second'] }
                error_message = if ($row['error_message'] -is [DBNull]) { $null } else { $row['error_message'] }
                executed_by = if ($row['executed_by'] -is [DBNull]) { $null } else { $row['executed_by'] }
                execution_order = if ($row['execution_order_nmbr'] -is [DBNull]) { $null } else { [int]$row['execution_order_nmbr'] }
                start_time = if ($row['job_start_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['job_start_dttm']).ToString("HH:mm:ss") }
                end_time = if ($row['job_end_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['job_end_dttm']).ToString("HH:mm:ss") }
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            tracking_id = $flowRow['tracking_id']
            flow_code = $flowRow['flow_code']
            execution_state = $flowRow['execution_state']
            expected_jobs = if ($flowRow['expected_job_count'] -is [DBNull]) { $null } else { $flowRow['expected_job_count'] }
            completed_jobs = $contentSucceeded
            failed_jobs = $contentFailed
            total_records = if ($flowRow['aggregate_completed_records'] -is [DBNull]) { $null } else { $flowRow['aggregate_completed_records'] }
            start_time = if ($flowRow['execution_window_start'] -is [DBNull]) { $null } else { ([DateTime]$flowRow['execution_window_start']).ToString("HH:mm:ss") }
            duration = $durationStr
            jobs = $jobs
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Flow Day Details
# Returns all executions for a flow on a specific date (for grouped Daily Summary)
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/flow-day-details' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $jobSqncId = $WebEvent.Query['job_sqnc_id']
        $date = $WebEvent.Query['date']
        
        if ([string]::IsNullOrEmpty($jobSqncId)) {
            Write-PodeJsonResponse -Value @{ error = "job_sqnc_id is required" } -StatusCode 400
            return
        }
        
        # Default to today if no date provided
        if ([string]::IsNullOrEmpty($date)) {
            $date = (Get-Date).ToString("yyyy-MM-dd")
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get all executions for this flow on this date
        $execCmd = $conn.CreateCommand()
        $execCmd.CommandText = @"
SELECT 
    tracking_id,
    job_sqnc_shrt_nm AS flow_code,
    execution_state,
    expected_job_count,
    completed_job_count,
    failed_job_count,
    aggregate_completed_records,
    execution_window_start,
    completion_dttm,
    CASE 
        WHEN completion_dttm IS NOT NULL THEN DATEDIFF(SECOND, execution_window_start, completion_dttm)
        WHEN execution_window_start IS NOT NULL THEN DATEDIFF(SECOND, execution_window_start, GETDATE())
        ELSE NULL
    END AS duration_seconds
FROM JobFlow.FlowExecutionTracking
WHERE job_sqnc_id = @job_sqnc_id
  AND execution_date = @date
ORDER BY execution_window_start
"@
        $execCmd.Parameters.AddWithValue("@job_sqnc_id", [int]$jobSqncId) | Out-Null
        $execCmd.Parameters.AddWithValue("@date", $date) | Out-Null
        $execCmd.CommandTimeout = 15
        $execAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($execCmd)
        $execDataset = New-Object System.Data.DataSet
        $execAdapter.Fill($execDataset) | Out-Null
        
        $executions = @()
        $flowCode = $null
        $totalJobs = 0
        $totalFailed = 0
        $totalRecords = 0
        
        foreach ($execRow in $execDataset.Tables[0].Rows) {
            $trackingId = $execRow['tracking_id']
            $flowCode = $execRow['flow_code']
            
            $durationSec = if ($execRow['duration_seconds'] -is [DBNull]) { $null } else { [int]$execRow['duration_seconds'] }
            $durationStr = '-'
            if ($null -ne $durationSec) {
                $m = [math]::Floor($durationSec / 60)
                $s = $durationSec % 60
                if ($m -gt 0) { $durationStr = "{0}m {1}s" -f $m, $s } else { $durationStr = "{0}s" -f $s }
            }
            
            $completedJobs = if ($execRow['completed_job_count'] -is [DBNull]) { 0 } else { [int]$execRow['completed_job_count'] }
            $failedJobs = if ($execRow['failed_job_count'] -is [DBNull]) { 0 } else { [int]$execRow['failed_job_count'] }
            $aggRecords = if ($execRow['aggregate_completed_records'] -is [DBNull]) { 0 } else { [int]$execRow['aggregate_completed_records'] }
            
            $expectedJobs = if ($execRow['expected_job_count'] -is [DBNull]) { 0 } else { [int]$execRow['expected_job_count'] }
            $totalJobs += $expectedJobs
            $totalRecords += $aggRecords
            
            # Get jobs for this execution
            $jobCmd = $conn.CreateCommand()
            $jobCmd.CommandText = @"
SELECT 
    execution_detail_id,
    job_log_id,
    job_shrt_nm AS job_name,
    job_nm AS job_full_name,
    job_status,
    total_records,
    succeeded_count,
    failed_count,
    execution_time_seconds,
    records_per_second,
    job_start_dttm,
    job_end_dttm,
    error_message,
    execution_order_nmbr
FROM JobFlow.JobExecutionLog
WHERE tracking_id = @tracking_id
ORDER BY execution_order_nmbr, job_exec_dttm
"@
            $jobCmd.Parameters.AddWithValue("@tracking_id", $trackingId) | Out-Null
            $jobCmd.CommandTimeout = 15
            $jobAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($jobCmd)
            $jobDataset = New-Object System.Data.DataSet
            $jobAdapter.Fill($jobDataset) | Out-Null
            
            # Content-based counters for this execution
            $contentSucceeded = 0
            $contentFailed = 0
            
            $jobs = @()
            foreach ($jobRow in $jobDataset.Tables[0].Rows) {
                $totalRec = if ($jobRow['total_records'] -is [DBNull]) { $null } else { [int]$jobRow['total_records'] }
                $succeededCnt = if ($jobRow['succeeded_count'] -is [DBNull]) { $null } else { [int]$jobRow['succeeded_count'] }
                $hasError = -not ($jobRow['error_message'] -is [DBNull])
                $isFailed = ($null -ne $totalRec -and $totalRec -gt 0 -and ($null -eq $succeededCnt -or $succeededCnt -eq 0)) -or $hasError
                
                if ($isFailed) { $contentFailed++ } else { $contentSucceeded++ }
                
                $execSeconds = if ($jobRow['execution_time_seconds'] -is [DBNull]) { $null } else { [int]$jobRow['execution_time_seconds'] }
                $jobDuration = if ($null -eq $execSeconds) { '-' } else {
                    $jm = [math]::Floor($execSeconds / 60)
                    $js = $execSeconds % 60
                    if ($jm -gt 0) { "{0}m {1}s" -f $jm, $js } else { "{0}s" -f $js }
                }
                
                $jobs += @{
                    execution_detail_id = $jobRow['execution_detail_id']
                    job_log_id = if ($jobRow['job_log_id'] -is [DBNull]) { $null } else { $jobRow['job_log_id'] }
                    job_name = $jobRow['job_name']
                    job_full_name = if ($jobRow['job_full_name'] -is [DBNull]) { $null } else { $jobRow['job_full_name'] }
                    job_status = $jobRow['job_status']
                    is_failed = $isFailed
                    total_records = $totalRec
                    succeeded_count = $succeededCnt
                    failed_count = if ($jobRow['failed_count'] -is [DBNull]) { 0 } else { [int]$jobRow['failed_count'] }
                    duration = $jobDuration
                    records_per_second = if ($jobRow['records_per_second'] -is [DBNull]) { $null } else { [decimal]$jobRow['records_per_second'] }
                    start_time = if ($jobRow['job_start_dttm'] -is [DBNull]) { $null } else { ([DateTime]$jobRow['job_start_dttm']).ToString("HH:mm:ss") }
                    end_time = if ($jobRow['job_end_dttm'] -is [DBNull]) { $null } else { ([DateTime]$jobRow['job_end_dttm']).ToString("HH:mm:ss") }
                    error_message = if ($jobRow['error_message'] -is [DBNull]) { $null } else { $jobRow['error_message'] }
                    execution_order = if ($jobRow['execution_order_nmbr'] -is [DBNull]) { $null } else { [int]$jobRow['execution_order_nmbr'] }
                }
            }
            
            $totalFailed += $contentFailed
            
            $executions += @{
                tracking_id = $trackingId
                execution_state = $execRow['execution_state']
                start_time = if ($execRow['execution_window_start'] -is [DBNull]) { $null } else { ([DateTime]$execRow['execution_window_start']).ToString("HH:mm:ss") }
                expected_jobs = if ($execRow['expected_job_count'] -is [DBNull]) { $null } else { [int]$execRow['expected_job_count'] }
                completed_jobs = $contentSucceeded
                failed_jobs = $contentFailed
                total_records = $aggRecords
                duration = $durationStr
                duration_seconds = $durationSec
                jobs = $jobs
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            job_sqnc_id = [int]$jobSqncId
            flow_code = $flowCode
            date = $date
            execution_count = $executions.Count
            total_jobs = $totalJobs
            total_failed = $totalFailed
            total_records = $totalRecords
            executions = $executions
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Execution History
# Returns year/month grouped history from JobExecutionLog
# Year level: distinct flows, jobs in flows, ad-hoc jobs
# Month level: distinct flows, successful jobs, failed jobs
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get total job count for header
        $totalCmd = $conn.CreateCommand()
        $totalCmd.CommandText = "SELECT COUNT(*) FROM JobFlow.JobExecutionLog"
        $totalCmd.CommandTimeout = 30
        $totalJobCount = [long]$totalCmd.ExecuteScalar()
        
        # Get year/month summary from JobExecutionLog
        # Flows: job_sqnc_id IS NOT NULL, Ad-hoc: job_sqnc_id IS NULL
        # Failed: (total_records > 0 AND succeeded_count = 0) OR error_message IS NOT NULL
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    YEAR(execution_date) AS year,
    MONTH(execution_date) AS month,
    COUNT(DISTINCT CASE WHEN job_sqnc_id IS NOT NULL THEN job_sqnc_id END) AS distinct_flows,
    SUM(CASE WHEN job_sqnc_id IS NOT NULL THEN 1 ELSE 0 END) AS jobs_in_flows,
    SUM(CASE WHEN job_sqnc_id IS NULL THEN 1 ELSE 0 END) AS adhoc_jobs,
    COUNT(*) AS total_jobs,
    SUM(CASE 
        WHEN (total_records > 0 AND (succeeded_count IS NULL OR succeeded_count = 0)) 
          OR error_message IS NOT NULL 
        THEN 1 ELSE 0 
    END) AS failed_jobs,
    SUM(CASE 
        WHEN NOT ((total_records > 0 AND (succeeded_count IS NULL OR succeeded_count = 0)) 
                   OR error_message IS NOT NULL)
        THEN 1 ELSE 0 
    END) AS successful_jobs
FROM JobFlow.JobExecutionLog
GROUP BY YEAR(execution_date), MONTH(execution_date)
ORDER BY YEAR(execution_date) DESC, MONTH(execution_date) DESC
"@
        $cmd.CommandTimeout = 60
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        # Group by year
        $yearData = @{}
        
        foreach ($row in $dataset.Tables[0].Rows) {
            $year = [int]$row['year']
            $month = [int]$row['month']
            $distinctFlows = if ($row['distinct_flows'] -is [DBNull]) { 0 } else { [int]$row['distinct_flows'] }
            $jobsInFlows = if ($row['jobs_in_flows'] -is [DBNull]) { 0 } else { [int]$row['jobs_in_flows'] }
            $adhoc = if ($row['adhoc_jobs'] -is [DBNull]) { 0 } else { [int]$row['adhoc_jobs'] }
            $totalJobs = if ($row['total_jobs'] -is [DBNull]) { 0 } else { [int]$row['total_jobs'] }
            $failedJobs = if ($row['failed_jobs'] -is [DBNull]) { 0 } else { [int]$row['failed_jobs'] }
            $successfulJobs = if ($row['successful_jobs'] -is [DBNull]) { 0 } else { [int]$row['successful_jobs'] }
            
            if (-not $yearData.ContainsKey($year)) {
                $yearData[$year] = @{
                    year = $year
                    total_flows = 0
                    total_jobs_in_flows = 0
                    total_adhoc = 0
                    total_jobs = 0
                    months = @()
                }
            }
            
            $yearData[$year].total_flows += $distinctFlows
            $yearData[$year].total_jobs_in_flows += $jobsInFlows
            $yearData[$year].total_adhoc += $adhoc
            $yearData[$year].total_jobs += $totalJobs
            
            $yearData[$year].months += @{
                month = $month
                distinct_flows = $distinctFlows
                successful_jobs = $successfulJobs
                failed_jobs = $failedJobs
                total_jobs = $totalJobs
            }
        }
        
        # Convert to sorted array
        $years = @()
        foreach ($year in ($yearData.Keys | Sort-Object -Descending)) {
            $years += $yearData[$year]
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            years = $years
            total_job_count = $totalJobCount
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: History Month Details
# Returns day-level details for a specific month
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/history-month' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $year = $WebEvent.Query['year']
        $month = $WebEvent.Query['month']
        
        if ([string]::IsNullOrEmpty($year) -or [string]::IsNullOrEmpty($month)) {
            Write-PodeJsonResponse -Value @{ error = "year and month are required" } -StatusCode 400
            return
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Day-level summary with failure logic
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    execution_date,
    DATENAME(WEEKDAY, execution_date) AS day_of_week,
    COUNT(DISTINCT CASE WHEN job_sqnc_id IS NOT NULL THEN job_sqnc_id END) AS flow_count,
    SUM(CASE 
        WHEN (total_records > 0 AND (succeeded_count IS NULL OR succeeded_count = 0)) 
          OR error_message IS NOT NULL 
        THEN 1 ELSE 0 
    END) AS failed_jobs,
    SUM(CASE 
        WHEN NOT ((total_records > 0 AND (succeeded_count IS NULL OR succeeded_count = 0)) 
                   OR error_message IS NOT NULL)
        THEN 1 ELSE 0 
    END) AS successful_jobs,
    COUNT(*) AS total_jobs
FROM JobFlow.JobExecutionLog
WHERE YEAR(execution_date) = @year
  AND MONTH(execution_date) = @month
GROUP BY execution_date
ORDER BY execution_date DESC
"@
        $cmd.Parameters.AddWithValue("@year", [int]$year) | Out-Null
        $cmd.Parameters.AddWithValue("@month", [int]$month) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $days = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $failedJobs = if ($row['failed_jobs'] -is [DBNull]) { 0 } else { [int]$row['failed_jobs'] }
            $successfulJobs = if ($row['successful_jobs'] -is [DBNull]) { 0 } else { [int]$row['successful_jobs'] }
            $totalJobs = if ($row['total_jobs'] -is [DBNull]) { 0 } else { [int]$row['total_jobs'] }
            
            # Status: green if no failures, yellow if any failures, red if ALL failed
            $status = 'success'
            if ($failedJobs -gt 0 -and $failedJobs -lt $totalJobs) { $status = 'warning' }
            elseif ($failedJobs -gt 0 -and $failedJobs -eq $totalJobs) { $status = 'error' }
            
            $days += @{
                date = ([DateTime]$row['execution_date']).ToString("yyyy-MM-dd")
                day_of_week = $row['day_of_week'].ToString().Substring(0, 3)
                flow_count = if ($row['flow_count'] -is [DBNull]) { 0 } else { [int]$row['flow_count'] }
                successful_jobs = $successfulJobs
                failed_jobs = $failedJobs
                total_jobs = $totalJobs
                status = $status
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            year = [int]$year
            month = [int]$month
            days = $days
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: History Day Details
# Returns job executions for a specific date (slideout)
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/history-detail' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $date = $WebEvent.Query['date']
        
        if ([string]::IsNullOrEmpty($date)) {
            Write-PodeJsonResponse -Value @{ error = "date is required" } -StatusCode 400
            return
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get all jobs for this date from JobExecutionLog
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    execution_detail_id,
    tracking_id,
    job_log_id,
    job_shrt_nm AS job_name,
    job_nm AS job_full_name,
    job_sqnc_id,
    job_sqnc_shrt_nm AS flow_code,
    execution_order_nmbr,
    job_status,
    total_records,
    succeeded_count,
    failed_count,
    execution_time_seconds,
    records_per_second,
    job_exec_dttm,
    job_start_dttm,
    job_end_dttm,
    error_message,
    executed_by,
    execution_type
FROM JobFlow.JobExecutionLog
WHERE execution_date = @date
ORDER BY job_sqnc_shrt_nm, execution_order_nmbr, job_exec_dttm
"@
        $cmd.Parameters.AddWithValue("@date", $date) | Out-Null
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        # Get validation results for this date
        $valCmd = $conn.CreateCommand()
        $valCmd.CommandText = @"
SELECT 
    tracking_id,
    job_sqnc_shrt_nm,
    validation_status,
    expected_job_count,
    actual_job_count,
    missing_job_count,
    failed_job_count
FROM JobFlow.ValidationLog
WHERE execution_date = @date
"@
        $valCmd.Parameters.AddWithValue("@date", $date) | Out-Null
        $valCmd.CommandTimeout = 10
        $valAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($valCmd)
        $valDataset = New-Object System.Data.DataSet
        $valAdapter.Fill($valDataset) | Out-Null
        
        # Index validation results by tracking_id and by flow_code
        $validationByTracking = @{}
        $validationByFlow = @{}
        foreach ($vRow in $valDataset.Tables[0].Rows) {
            $vTrackingId = if ($vRow['tracking_id'] -is [DBNull]) { $null } else { [int64]$vRow['tracking_id'] }
            $vFlowCode = $vRow['job_sqnc_shrt_nm'].ToString()
            $vData = @{
                validation_status = $vRow['validation_status'].ToString()
                expected_job_count = [int]$vRow['expected_job_count']
                actual_job_count = [int]$vRow['actual_job_count']
                missing_job_count = [int]$vRow['missing_job_count']
                failed_job_count = [int]$vRow['failed_job_count']
            }
            if ($null -ne $vTrackingId) { $validationByTracking[$vTrackingId] = $vData }
            $validationByFlow[$vFlowCode] = $vData
        }
        
        # Group into flows and ad-hoc - group by tracking_id for per-execution separation
        $flowGroups = [ordered]@{}
        $adhocJobs = @()
        $totalJobs = 0
        
        foreach ($row in $dataset.Tables[0].Rows) {
            $totalJobs++
            
            # Determine if job is failed using the specified logic
            $totalRec = if ($row['total_records'] -is [DBNull]) { $null } else { [int]$row['total_records'] }
            $succeededCnt = if ($row['succeeded_count'] -is [DBNull]) { $null } else { [int]$row['succeeded_count'] }
            $hasError = -not ($row['error_message'] -is [DBNull])
            $isFailed = ($null -ne $totalRec -and $totalRec -gt 0 -and ($null -eq $succeededCnt -or $succeededCnt -eq 0)) -or $hasError
            
            $execSeconds = if ($row['execution_time_seconds'] -is [DBNull]) { $null } else { [int]$row['execution_time_seconds'] }
            $jobDuration = if ($null -eq $execSeconds) { '-' } else {
                $m = [math]::Floor($execSeconds / 60)
                $s = $execSeconds % 60
                if ($m -gt 0) { "{0}m {1}s" -f $m, $s } else { "{0}s" -f $s }
            }
            
            $jobData = @{
                execution_detail_id = $row['execution_detail_id']
                job_log_id = if ($row['job_log_id'] -is [DBNull]) { $null } else { $row['job_log_id'] }
                job_name = $row['job_name']
                job_full_name = if ($row['job_full_name'] -is [DBNull]) { $null } else { $row['job_full_name'] }
                job_status = $row['job_status']
                is_failed = $isFailed
                total_records = $totalRec
                succeeded_count = $succeededCnt
                failed_count = if ($row['failed_count'] -is [DBNull]) { 0 } else { [int]$row['failed_count'] }
                duration = $jobDuration
                records_per_second = if ($row['records_per_second'] -is [DBNull]) { $null } else { [decimal]$row['records_per_second'] }
                error_message = if ($row['error_message'] -is [DBNull]) { $null } else { $row['error_message'] }
                executed_by = if ($row['executed_by'] -is [DBNull]) { $null } else { $row['executed_by'] }
                execution_order = if ($row['execution_order_nmbr'] -is [DBNull]) { $null } else { [int]$row['execution_order_nmbr'] }
                start_time = if ($row['job_start_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['job_start_dttm']).ToString("HH:mm:ss") }
                end_time = if ($row['job_end_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['job_end_dttm']).ToString("HH:mm:ss") }
            }
            
            $flowCode = if ($row['flow_code'] -is [DBNull]) { $null } else { $row['flow_code'] }
            $jobSqncId = if ($row['job_sqnc_id'] -is [DBNull]) { $null } else { $row['job_sqnc_id'] }
            $trackingId = if ($row['tracking_id'] -is [DBNull] -or [int]$row['tracking_id'] -eq 0) { $null } else { [int]$row['tracking_id'] }
            
            if ($null -eq $jobSqncId) {
                # Ad-hoc job
                $adhocJobs += $jobData
            }
            else {
                # Flow job - group by tracking_id (or flow_code for historical pre-tracking data)
                $groupKey = if ($null -ne $trackingId) { "t_$trackingId" } else { "f_$flowCode" }
                
                if (-not $flowGroups.Contains($groupKey)) {
                    # Derive rounded hour from first job's exec time for display label
                    $execHourLabel = $null
                    if (-not ($row['job_exec_dttm'] -is [DBNull])) {
                        $execDttm = [DateTime]$row['job_exec_dttm']
                        $roundedHour = $execDttm.Hour
                        if ($execDttm.Minute -ge 30) { $roundedHour++ }
                        if ($roundedHour -ge 24) { $roundedHour = 0 }
                        $hourDt = (Get-Date -Hour $roundedHour -Minute 0 -Second 0)
                        $execHourLabel = $hourDt.ToString("h tt").ToLower().TrimStart('0')
                    }
                    
                    $flowGroups[$groupKey] = @{
                        flow_code = $flowCode
                        tracking_id = $trackingId
                        exec_hour_label = $execHourLabel
                        jobs = @()
                        total_jobs = 0
                        failed_jobs = 0
                        total_duration_seconds = 0
                        first_start = $null
                        last_end = $null
                    }
                }
                
                $flowGroups[$groupKey].jobs += $jobData
                $flowGroups[$groupKey].total_jobs++
                if ($isFailed) { $flowGroups[$groupKey].failed_jobs++ }
                if ($null -ne $execSeconds) { $flowGroups[$groupKey].total_duration_seconds += $execSeconds }
                
                # Track timing
                if ($null -ne $jobData.start_time) {
                    if ($null -eq $flowGroups[$groupKey].first_start -or $jobData.start_time -lt $flowGroups[$groupKey].first_start) {
                        $flowGroups[$groupKey].first_start = $jobData.start_time
                    }
                }
                if ($null -ne $jobData.end_time) {
                    if ($null -eq $flowGroups[$groupKey].last_end -or $jobData.end_time -gt $flowGroups[$groupKey].last_end) {
                        $flowGroups[$groupKey].last_end = $jobData.end_time
                    }
                }
            }
        }
        
        # Suppress hour labels on single-run flows (only show for multi-execution flows)
        $flowCodeCounts = @{}
        foreach ($groupKey in $flowGroups.Keys) {
            $fc = $flowGroups[$groupKey].flow_code
            if ($flowCodeCounts.ContainsKey($fc)) { $flowCodeCounts[$fc]++ } else { $flowCodeCounts[$fc] = 1 }
        }
        foreach ($groupKey in $flowGroups.Keys) {
            if ($flowCodeCounts[$flowGroups[$groupKey].flow_code] -le 1) {
                $flowGroups[$groupKey].exec_hour_label = $null
            }
        }
        
        # Convert flow groups to array, sorted by flow_code then start time
        $flows = @()
        foreach ($groupKey in $flowGroups.Keys) {
            $fg = $flowGroups[$groupKey]
            # Look up validation: first by tracking_id, then by flow_code
            $valResult = $null
            if ($null -ne $fg.tracking_id -and $validationByTracking.ContainsKey([int64]$fg.tracking_id)) {
                $valResult = $validationByTracking[[int64]$fg.tracking_id]
            }
            elseif ($validationByFlow.ContainsKey($fg.flow_code)) {
                $valResult = $validationByFlow[$fg.flow_code]
            }
            # Calculate flow duration string
            $fgDurSec = $fg.total_duration_seconds
            $fgDurStr = '-'
            if ($fgDurSec -ge 3600) {
                $fgH = [math]::Floor($fgDurSec / 3600)
                $fgM = [math]::Floor(($fgDurSec % 3600) / 60)
                $fgDurStr = "{0}h {1}m" -f $fgH, $fgM
            }
            elseif ($fgDurSec -ge 60) {
                $fgM = [math]::Floor($fgDurSec / 60)
                $fgS = $fgDurSec % 60
                $fgDurStr = "{0}m {1}s" -f $fgM, $fgS
            }
            elseif ($fgDurSec -ge 0) {
                $fgDurStr = "{0}s" -f $fgDurSec
            }
            $flows += @{
                flow_code = $fg.flow_code
                tracking_id = $fg.tracking_id
                exec_hour_label = $fg.exec_hour_label
                total_jobs = $fg.total_jobs
                failed_jobs = $fg.failed_jobs
                start_time = $fg.first_start
                duration = $fgDurStr
                jobs = $fg.jobs
                is_historical = ($null -eq $fg.tracking_id)
                validation_status = if ($null -ne $valResult) { $valResult.validation_status } else { $null }
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            date = $date
            flows = $flows
            adhoc_jobs = $adhocJobs
            total_jobs = $totalJobs
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: App Server Tasks
# Returns scheduled task status across application servers
# Validates against active flows in DM and includes flow names
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/app-tasks' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $servers = @('DM-PROD-APP', 'DM-PROD-APP2', 'DM-PROD-APP3')
        $taskPrefix = "DM Night Job - "
        
        $allTasks = @{}
        $errors = @()
        
        # Query all servers in parallel
        $jobs = @()
        foreach ($server in $servers) {
            $jobs += Invoke-Command -ComputerName $server -ScriptBlock {
                param($prefix)
                Get-ScheduledTask | Where-Object { $_.TaskName -like "$prefix*" } | 
                    Select-Object TaskName, State
            } -ArgumentList $taskPrefix -AsJob
        }
        
        # Wait for all jobs and collect results
        $jobs | Wait-Job -Timeout 30 | Out-Null
        
        for ($i = 0; $i -lt $servers.Count; $i++) {
            $server = $servers[$i]
            $job = $jobs[$i]
            
            if ($job.State -eq 'Completed') {
                try {
                    $tasks = Receive-Job -Job $job -ErrorAction Stop
                    foreach ($task in $tasks) {
                        $flowCode = $task.TaskName -replace [regex]::Escape($taskPrefix), ''
                        
                        if (-not $allTasks.ContainsKey($flowCode)) {
                            $allTasks[$flowCode] = @{
                                flow_code = $flowCode
                                states = @{}
                            }
                        }
                        
                        $allTasks[$flowCode].states[$server] = $task.State.ToString()
                    }
                }
                catch {
                    $errors += "$server`: $($_.Exception.Message)"
                }
            }
            else {
                $errors += "$server`: Job timed out or failed"
            }
        }
        
        # Cleanup jobs
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        
        # Get active flows from DM for validation and flow names
        $connString = "Server=AVG-PROD-LSNR;Database=crs5_oltp;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $flowCmd = $conn.CreateCommand()
        $flowCmd.CommandText = @"
SELECT job_sqnc_shrt_nm AS flow_code, job_sqnc_nm AS flow_name, job_sqnc_actv_flg
FROM dbo.job_sqnc
WHERE job_sqnc_shrt_nm LIKE 'JF%'
"@
        $flowCmd.CommandTimeout = 15
        $flowAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($flowCmd)
        $flowDataset = New-Object System.Data.DataSet
        $flowAdapter.Fill($flowDataset) | Out-Null
        $conn.Close()
        
        # Build lookup of active flows
        $activeFlows = @{}
        $flowNames = @{}
        foreach ($row in $flowDataset.Tables[0].Rows) {
            $flowNames[$row['flow_code']] = $row['flow_name']
            if ($row['job_sqnc_actv_flg'] -eq 'Y') {
                $activeFlows[$row['flow_code']] = $true
            }
        }
        
        # Build final task list - only include flows that have tasks AND are active in DM
        $taskList = @()
        foreach ($flowCode in ($allTasks.Keys | Sort-Object)) {
            # Skip if flow is not active in DM
            if (-not $activeFlows.ContainsKey($flowCode)) {
                continue
            }
            
            $taskInfo = $allTasks[$flowCode]
            $taskInfo.flow_name = $flowNames[$flowCode]
            
            # Check if any server has this task enabled
            $hasEnabled = $false
            foreach ($state in $taskInfo.states.Values) {
                if ($state -eq 'Ready') {
                    $hasEnabled = $true
                    break
                }
            }
            $taskInfo.has_enabled = $hasEnabled
            
            $taskList += $taskInfo
        }
        
        $response = @{
            servers = $servers
            tasks = $taskList
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        
        if ($errors.Count -gt 0) {
            $response.warnings = $errors
        }
        
        Write-PodeJsonResponse -Value $response
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Toggle App Server Task
# Enables or disables a scheduled task on a specific server
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/jobflow/app-tasks/toggle' -Authentication 'ADLogin' -ScriptBlock {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
        try {
        $body = $WebEvent.Data
        $server = $body.server
        $flowCode = $body.flow_code
        $enable = $body.enable
        
        if ([string]::IsNullOrEmpty($server) -or [string]::IsNullOrEmpty($flowCode)) {
            Write-PodeJsonResponse -Value @{ error = "server and flow_code are required" } -StatusCode 400
            return
        }
        
        $taskName = "DM Night Job - $flowCode"
        
        $result = Invoke-Command -ComputerName $server -ScriptBlock {
            param($taskName, $enable)
            
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($null -eq $task) {
                return @{ success = $false; error = "Task not found: $taskName" }
            }
            
            if ($enable) {
                Enable-ScheduledTask -TaskName $taskName | Out-Null
            } else {
                Disable-ScheduledTask -TaskName $taskName | Out-Null
            }
            
            # Verify the change
            $task = Get-ScheduledTask -TaskName $taskName
            return @{ 
                success = $true
                new_state = $task.State.ToString()
            }
        } -ArgumentList $taskName, $enable -ErrorAction Stop
        
        if ($result.success) {
            Write-PodeJsonResponse -Value @{
                success = $true
                server = $server
                flow_code = $flowCode
                new_state = $result.new_state
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
        } else {
            Write-PodeJsonResponse -Value @{ error = $result.error } -StatusCode 400
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Batch Update App Server Tasks
# Applies multiple task changes in parallel
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/jobflow/app-tasks/batch' -Authentication 'ADLogin' -ScriptBlock {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
        try {
        $body = $WebEvent.Data
        $changes = $body.changes
        
        if (-not $changes -or $changes.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = "No changes provided" } -StatusCode 400
            return
        }
        
        $results = @()
        $jobs = @()
        $jobMap = @()
        
        # Launch all changes in parallel
        foreach ($change in $changes) {
            $server = $change.server
            $flowCode = $change.flow_code
            $enable = $change.enable
            $taskName = "DM Night Job - $flowCode"
            
            $job = Invoke-Command -ComputerName $server -ScriptBlock {
                param($taskName, $enable)
                
                try {
                    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                    if ($null -eq $task) {
                        return @{ success = $false; error = "Task not found: $taskName" }
                    }
                    
                    if ($enable) {
                        Enable-ScheduledTask -TaskName $taskName | Out-Null
                    } else {
                        Disable-ScheduledTask -TaskName $taskName | Out-Null
                    }
                    
                    # Verify the change
                    $task = Get-ScheduledTask -TaskName $taskName
                    return @{ 
                        success = $true
                        new_state = $task.State.ToString()
                    }
                }
                catch {
                    return @{ success = $false; error = $_.Exception.Message }
                }
            } -ArgumentList $taskName, $enable -AsJob
            
            $jobs += $job
            $jobMap += @{
                server = $server
                flow_code = $flowCode
                enable = $enable
            }
        }
        
        # Wait for all jobs
        $jobs | Wait-Job -Timeout 30 | Out-Null
        
        $allSuccess = $true
        $failedChanges = @()
        
        for ($i = 0; $i -lt $jobs.Count; $i++) {
            $job = $jobs[$i]
            $changeInfo = $jobMap[$i]
            
            $result = @{
                server = $changeInfo.server
                flow_code = $changeInfo.flow_code
                action = if ($changeInfo.enable) { 'enable' } else { 'disable' }
            }
            
            if ($job.State -eq 'Completed') {
                try {
                    $jobResult = Receive-Job -Job $job -ErrorAction Stop
                    $result.success = $jobResult.success
                    if ($jobResult.success) {
                        $result.new_state = $jobResult.new_state
                    } else {
                        $result.error = $jobResult.error
                        $allSuccess = $false
                        $failedChanges += $changeInfo
                    }
                }
                catch {
                    $result.success = $false
                    $result.error = $_.Exception.Message
                    $allSuccess = $false
                    $failedChanges += $changeInfo
                }
            }
            else {
                $result.success = $false
                $result.error = "Job timed out"
                $allSuccess = $false
                $failedChanges += $changeInfo
            }
            
            $results += $result
        }
        
        # Cleanup jobs
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        
        # If any failed, attempt to rollback the successful changes
        $rollbackResults = @()
        if (-not $allSuccess -and $failedChanges.Count -lt $changes.Count) {
            # Some succeeded, some failed - attempt rollback of successful ones
            $successfulChanges = $results | Where-Object { $_.success -eq $true }
            
            foreach ($change in $successfulChanges) {
                $rollbackEnable = $change.action -eq 'disable'  # Reverse the action
                $taskName = "DM Night Job - $($change.flow_code)"
                
                try {
                    $rollbackResult = Invoke-Command -ComputerName $change.server -ScriptBlock {
                        param($taskName, $enable)
                        if ($enable) {
                            Enable-ScheduledTask -TaskName $taskName | Out-Null
                        } else {
                            Disable-ScheduledTask -TaskName $taskName | Out-Null
                        }
                        return @{ success = $true }
                    } -ArgumentList $taskName, $rollbackEnable -ErrorAction Stop
                    
                    $rollbackResults += @{
                        server = $change.server
                        flow_code = $change.flow_code
                        rolled_back = $true
                    }
                }
                catch {
                    $rollbackResults += @{
                        server = $change.server
                        flow_code = $change.flow_code
                        rolled_back = $false
                        error = $_.Exception.Message
                    }
                }
            }
        }
        
        $response = @{
            success = $allSuccess
            results = $results
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        
        if ($rollbackResults.Count -gt 0) {
            $response.rollback_attempted = $true
            $response.rollback_results = $rollbackResults
        }
        
        Write-PodeJsonResponse -Value $response
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Stall History
# Returns stall detection episodes grouped by date
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/stall-history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $days = $WebEvent.Query['days']
        if ([string]::IsNullOrEmpty($days)) { $days = 30 }
        $days = [math]::Min([int]$days, 365)
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    log_id,
    poll_dttm,
    counter_before,
    counter_after,
    event_type,
    stall_threshold,
    threshold_reached,
    jira_queued,
    teams_queued
FROM JobFlow.StallDetectionLog
WHERE poll_dttm >= DATEADD(DAY, -@days, CAST(GETDATE() AS DATE))
ORDER BY poll_dttm
"@
        $cmd.Parameters.AddWithValue("@days", [int]$days) | Out-Null
        $cmd.CommandTimeout = 15
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        # Group into episodes - episodes span across date boundaries
        $dateGroups = [ordered]@{}
        $currentEpisode = $null
        
        foreach ($row in $dataset.Tables[0].Rows) {
            $eventType = $row['event_type'].ToString()
            $pollDttm = [DateTime]$row['poll_dttm']
            $rowDate = $pollDttm.ToString("yyyy-MM-dd")
            $counterAfter = [int]$row['counter_after']
            
            if ($eventType -eq 'INCREMENT' -or $eventType -eq 'ALERT' -or $eventType -eq 'STALLED') {
                if ($null -eq $currentEpisode) {
                    $currentEpisode = @{
                        start_date = $rowDate
                        start_time = $pollDttm.ToString("HH:mm")
                        end_time = $null
                        polls = 1
                        peak_counter = $counterAfter
                        threshold_reached = ($row['threshold_reached'] -eq $true -or $row['threshold_reached'] -eq 1)
                        resolved = $false
                        alert_sent = ($eventType -eq 'ALERT')
                        crosses_midnight = $false
                    }
                }
                else {
                    $currentEpisode.polls++
                    if ($counterAfter -gt $currentEpisode.peak_counter) { $currentEpisode.peak_counter = $counterAfter }
                    if ($row['threshold_reached'] -eq $true -or $row['threshold_reached'] -eq 1) { $currentEpisode.threshold_reached = $true }
                    if ($eventType -eq 'ALERT') { $currentEpisode.alert_sent = $true }
                    # Track if episode spans multiple dates
                    if ($rowDate -ne $currentEpisode.start_date) { $currentEpisode.crosses_midnight = $true }
                }
            }
            elseif ($eventType -eq 'RESET') {
                if ($null -ne $currentEpisode) {
                    $currentEpisode.end_time = $pollDttm.ToString("HH:mm")
                    $currentEpisode.resolved = $true
                    if ($rowDate -ne $currentEpisode.start_date) { $currentEpisode.crosses_midnight = $true }
                    # File under the date the episode started
                    $fileDate = $currentEpisode.start_date
                    if (-not $dateGroups.Contains($fileDate)) { $dateGroups[$fileDate] = @() }
                    $dateGroups[$fileDate] += $currentEpisode
                    $currentEpisode = $null
                }
            }
        }
        
        # Close any open episode (file under its start date)
        if ($null -ne $currentEpisode) {
            $fileDate = $currentEpisode.start_date
            if (-not $dateGroups.Contains($fileDate)) { $dateGroups[$fileDate] = @() }
            $dateGroups[$fileDate] += $currentEpisode
        }
        
        # Convert to response array (newest first)
        $historyDates = @()
        foreach ($dateKey in ($dateGroups.Keys | Sort-Object -Descending)) {
            $episodes = @($dateGroups[$dateKey])
            $alertCount = @($episodes | Where-Object { $_.alert_sent }).Count
            
            # Sum total stall time across all episodes
            $totalStallMin = 0
            foreach ($ep in $episodes) {
                if ($ep.start_time -and $ep.end_time -and $ep.resolved) {
                    $sParts = $ep.start_time -split ':'
                    $eParts = $ep.end_time -split ':'
                    $diff = ([int]$eParts[0] * 60 + [int]$eParts[1]) - ([int]$sParts[0] * 60 + [int]$sParts[1])
                    if ($diff -lt 0) { $diff += 1440 }
                    $totalStallMin += $diff
                }
            }
            
            $historyDates += @{
                date = $dateKey
                day_of_week = ([DateTime]$dateKey).ToString("ddd")
                episode_count = $episodes.Count
                alert_count = $alertCount
                total_stall_minutes = $totalStallMin
                episodes = $episodes
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            days_queried = [int]$days
            dates_with_events = $historyDates.Count
            dates = $historyDates
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: ConfigSync - Flow Configuration Data
# Returns all FlowConfig entries with misalignment status and schedule data
# Used by the ConfigSync modal for both viewing and resolving drift
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/configsync' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get all FlowConfig entries with schedule data and misalignment detection
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    fc.config_id,
    fc.job_sqnc_id,
    fc.job_sqnc_shrt_nm,
    fc.job_sqnc_nm,
    fc.dm_is_active,
    fc.dm_last_sync_dttm,
    fc.is_monitored,
    fc.expected_schedule,
    fc.expected_max_duration_hours,
    fc.alert_on_missing,
    fc.alert_on_critical_failure,
    fc.effective_start_date,
    fc.effective_end_date,
    fc.notes,
    fc.modified_dttm,
    fc.modified_by,
    s.schedule_id,
    s.schedule_type,
    s.schedule_frequency,
    s.schedule_day_of_week,
    s.schedule_day_of_month,
    s.schedule_week_of_month,
    s.expected_start_time,
    s.start_time_tolerance_minutes,
    s.is_active AS schedule_is_active,
    s.alert_on_missing AS schedule_alert_on_missing,
    s.effective_start_date AS schedule_effective_start_date,
    s.effective_end_date AS schedule_effective_end_date,
    s.notes AS schedule_notes,
    -- Misalignment detection
    CASE
        WHEN fc.expected_schedule = 'UNCONFIGURED' THEN 'NEW'
        WHEN fc.dm_is_active = 0 AND fc.is_monitored = 1 THEN 'DEACTIVATED'
        WHEN fc.dm_is_active = 1 AND fc.is_monitored = 0 
             AND EXISTS (SELECT 1 FROM JobFlow.Schedule sx 
                         WHERE sx.job_sqnc_id = fc.job_sqnc_id) THEN 'REACTIVATED'
        ELSE NULL
    END AS misalignment_type
FROM JobFlow.FlowConfig fc
LEFT JOIN JobFlow.Schedule s ON fc.job_sqnc_id = s.job_sqnc_id
WHERE fc.job_sqnc_id > 0
ORDER BY 
    CASE 
        WHEN fc.expected_schedule = 'UNCONFIGURED' THEN 0
        WHEN fc.dm_is_active = 0 AND fc.is_monitored = 1 THEN 1
        WHEN fc.dm_is_active = 1 AND fc.is_monitored = 0 
             AND EXISTS (SELECT 1 FROM JobFlow.Schedule sx 
                         WHERE sx.job_sqnc_id = fc.job_sqnc_id) THEN 2
        ELSE 3
    END,
    fc.job_sqnc_shrt_nm
"@
        $cmd.CommandTimeout = 15
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $conn.Close()
        
        $flows = @()
        $misalignedCount = 0
        
        foreach ($row in $dataset.Tables[0].Rows) {
            $misalignment = if ($row['misalignment_type'] -is [DBNull]) { $null } else { $row['misalignment_type'] }
            if ($null -ne $misalignment) { $misalignedCount++ }
            
            $flow = @{
                config_id = $row['config_id']
                job_sqnc_id = $row['job_sqnc_id']
                flow_code = $row['job_sqnc_shrt_nm']
                flow_name = if ($row['job_sqnc_nm'] -is [DBNull]) { $null } else { $row['job_sqnc_nm'] }
                dm_is_active = if ($row['dm_is_active'] -is [DBNull]) { $null } else { [bool]$row['dm_is_active'] }
                dm_last_sync_dttm = if ($row['dm_last_sync_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['dm_last_sync_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                is_monitored = [bool]$row['is_monitored']
                expected_schedule = $row['expected_schedule']
                expected_max_duration_hours = if ($row['expected_max_duration_hours'] -is [DBNull]) { $null } else { $row['expected_max_duration_hours'] }
                alert_on_missing = [bool]$row['alert_on_missing']
                alert_on_critical_failure = [bool]$row['alert_on_critical_failure']
                effective_start_date = if ($row['effective_start_date'] -is [DBNull]) { $null } else { ([DateTime]$row['effective_start_date']).ToString("yyyy-MM-dd") }
                effective_end_date = if ($row['effective_end_date'] -is [DBNull]) { $null } else { ([DateTime]$row['effective_end_date']).ToString("yyyy-MM-dd") }
                notes = if ($row['notes'] -is [DBNull]) { $null } else { $row['notes'] }
                modified_dttm = if ($row['modified_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['modified_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                modified_by = if ($row['modified_by'] -is [DBNull]) { $null } else { $row['modified_by'] }
                misalignment_type = $misalignment
                schedule = $null
            }
            
            # Attach schedule data if present
            if (-not ($row['schedule_id'] -is [DBNull])) {
                $startTime = if ($row['expected_start_time'] -is [DBNull]) { $null } else { ([TimeSpan]$row['expected_start_time']).ToString("hh\:mm") }
                
                $flow.schedule = @{
                    schedule_id = $row['schedule_id']
                    schedule_type = $row['schedule_type']
                    schedule_frequency = if ($row['schedule_frequency'] -is [DBNull]) { $null } else { $row['schedule_frequency'] }
                    schedule_day_of_week = if ($row['schedule_day_of_week'] -is [DBNull]) { $null } else { $row['schedule_day_of_week'] }
                    schedule_day_of_month = if ($row['schedule_day_of_month'] -is [DBNull]) { $null } else { $row['schedule_day_of_month'] }
                    schedule_week_of_month = if ($row['schedule_week_of_month'] -is [DBNull]) { $null } else { $row['schedule_week_of_month'] }
                    expected_start_time = $startTime
                    start_time_tolerance_minutes = $row['start_time_tolerance_minutes']
                    is_active = [bool]$row['schedule_is_active']
                    alert_on_missing = [bool]$row['schedule_alert_on_missing']
                    effective_start_date = if ($row['schedule_effective_start_date'] -is [DBNull]) { $null } else { ([DateTime]$row['schedule_effective_start_date']).ToString("yyyy-MM-dd") }
                    effective_end_date = if ($row['schedule_effective_end_date'] -is [DBNull]) { $null } else { ([DateTime]$row['schedule_effective_end_date']).ToString("yyyy-MM-dd") }
                    notes = if ($row['schedule_notes'] -is [DBNull]) { $null } else { $row['schedule_notes'] }
                }
            }
            
            $flows += $flow
        }
        
        Write-PodeJsonResponse -Value @{
            flows = $flows
            misaligned_count = $misalignedCount
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: ConfigSync - Task Scheduler Query
# Queries Windows Task Scheduler on app servers to get trigger data for a flow
# Used to auto-populate schedule fields when configuring new flows
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/jobflow/configsync/task-schedule' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $flowCode = $WebEvent.Query['flow_code']
        if ([string]::IsNullOrWhiteSpace($flowCode)) {
            Write-PodeJsonResponse -Value @{ error = "flow_code parameter required" } -StatusCode 400
            return
        }
        
        $taskName = "DM Night Job - $flowCode"
        # Query first available server - all 3 have identical task definitions
        $servers = @('DM-PROD-APP', 'DM-PROD-APP2', 'DM-PROD-APP3')
        
        $taskData = $null
        $queryError = $null
        
        foreach ($server in $servers) {
            try {
                $taskData = Invoke-Command -ComputerName $server -ScriptBlock {
                    param($name)
                    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                    if ($null -eq $task) { return $null }
                    
                    $triggers = @()
                    foreach ($trigger in $task.Triggers) {
                        $triggerInfo = @{
                            type = $trigger.CimClass.CimClassName
                            enabled = $trigger.Enabled
                            start_boundary = $trigger.StartBoundary
                        }
                        
                        # Daily trigger
                        if ($trigger.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger') {
                            $triggerInfo.days_interval = $trigger.DaysInterval
                        }
                        
                        # Weekly trigger
                        if ($trigger.CimClass.CimClassName -eq 'MSFT_TaskWeeklyTrigger') {
                            $triggerInfo.days_of_week = $trigger.DaysOfWeek
                            $triggerInfo.weeks_interval = $trigger.WeeksInterval
                        }
                        
                        # Monthly trigger (by day of month)
                        if ($trigger.CimClass.CimClassName -eq 'MSFT_TaskMonthlyTrigger') {
                            $triggerInfo.days_of_month = $trigger.DaysOfMonth
                            $triggerInfo.months_of_year = $trigger.MonthsOfYear
                        }
                        
                        # Monthly DOW trigger (e.g., 3rd Tuesday)
                        if ($trigger.CimClass.CimClassName -eq 'MSFT_TaskMonthlyDOWTrigger') {
                            $triggerInfo.days_of_week = $trigger.DaysOfWeek
                            $triggerInfo.weeks_of_month = $trigger.WeeksOfMonth
                            $triggerInfo.months_of_year = $trigger.MonthsOfYear
                        }
                        
                        # Repetition interval (every N hours)
                        if ($null -ne $trigger.Repetition -and $null -ne $trigger.Repetition.Interval) {
                            $triggerInfo.repetition_interval = $trigger.Repetition.Interval
                            $triggerInfo.repetition_duration = $trigger.Repetition.Duration
                        }
                        
                        $triggers += $triggerInfo
                    }
                    
                    return @{
                        task_name = $task.TaskName
                        state = $task.State.ToString()
                        triggers = $triggers
                    }
                } -ArgumentList $taskName -ErrorAction Stop
                
                # Got a result (even if null = task not found), stop trying servers
                break
            }
            catch {
                $queryError = "$server`: $($_.Exception.Message)"
                # Try next server
            }
        }
        
        # No task found on any server
        if ($null -eq $taskData) {
            $response = @{
                flow_code = $flowCode
                task_found = $false
                parsed_schedule = $null
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
            if ($null -ne $queryError) { $response.warning = $queryError }
            Write-PodeJsonResponse -Value $response
            return
        }
        
        # Parse triggers into schedule recommendation
        $parsed = @{
            schedule_type = $null
            expected_start_time = $null
            schedule_frequency = $null
            schedule_day_of_week = $null
            schedule_day_of_month = $null
            schedule_week_of_month = $null
        }
        
        if ($taskData.triggers.Count -gt 0) {
            $trigger = $taskData.triggers[0]
            
            # Extract start time from StartBoundary (ISO format like 2024-01-01T22:00:00)
            if ($trigger.start_boundary) {
                try {
                    $dt = [DateTime]::Parse($trigger.start_boundary)
                    $parsed.expected_start_time = $dt.ToString("HH:mm")
                } catch { }
            }
            
            # Check for repetition interval (EVERY_N_HOURS)
            if ($trigger.repetition_interval) {
                $parsed.schedule_type = 'EVERY_N_HOURS'
                # Parse PT4H format to hours
                if ($trigger.repetition_interval -match 'PT(\d+)H') {
                    $parsed.schedule_frequency = [int]$Matches[1]
                }
            }
            # Monthly DOW (e.g., 3rd Tuesday)
            elseif ($trigger.type -eq 'MSFT_TaskMonthlyDOWTrigger') {
                $parsed.schedule_type = 'MONTHLY'
                # DaysOfWeek is a bitmask: Sunday=1, Monday=2, Tuesday=4, Wednesday=8, etc.
                $dowBits = @{ 1 = 1; 2 = 2; 4 = 3; 8 = 4; 16 = 5; 32 = 6; 64 = 7 }
                if ($dowBits.ContainsKey([int]$trigger.days_of_week)) {
                    $parsed.schedule_day_of_week = $dowBits[[int]$trigger.days_of_week]
                }
                # WeeksOfMonth is a bitmask: 1st=1, 2nd=2, 3rd=4, 4th=8
                $weekBits = @{ 1 = 1; 2 = 2; 4 = 3; 8 = 4; 16 = 5 }
                if ($weekBits.ContainsKey([int]$trigger.weeks_of_month)) {
                    $parsed.schedule_week_of_month = $weekBits[[int]$trigger.weeks_of_month]
                }
            }
            # Monthly by date
            elseif ($trigger.type -eq 'MSFT_TaskMonthlyTrigger') {
                $parsed.schedule_type = 'MONTHLY'
                if ($trigger.days_of_month -and $trigger.days_of_month.Count -gt 0) {
                    $parsed.schedule_day_of_month = $trigger.days_of_month[0]
                }
            }
            # Weekly
            elseif ($trigger.type -eq 'MSFT_TaskWeeklyTrigger') {
                $parsed.schedule_type = 'WEEKLY'
                $dowBits = @{ 1 = 1; 2 = 2; 4 = 3; 8 = 4; 16 = 5; 32 = 6; 64 = 7 }
                if ($dowBits.ContainsKey([int]$trigger.days_of_week)) {
                    $parsed.schedule_day_of_week = $dowBits[[int]$trigger.days_of_week]
                }
            }
            # Daily
            elseif ($trigger.type -eq 'MSFT_TaskDailyTrigger') {
                $parsed.schedule_type = 'DAILY'
            }
        }
        
        Write-PodeJsonResponse -Value @{
            flow_code = $flowCode
            task_found = $true
            task_state = $taskData.state
            raw_triggers = $taskData.triggers
            parsed_schedule = $parsed
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: ConfigSync - Save Configuration
# Applies configuration changes for a flow (FlowConfig + Schedule updates)
# Handles NEW, DEACTIVATED, and REACTIVATED flow scenarios
# ============================================================================
Add-PodeRoute -Method Post -Path '/api/jobflow/configsync/save' -Authentication 'ADLogin' -ScriptBlock {
        if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
        try {
        $body = $WebEvent.Data
        $action = $body.action  # 'configure_new', 'deactivate', 'reactivate'
        $configId = $body.config_id
        $jobSqncId = $body.job_sqnc_id
        $flowCode = $body.flow_code
        
        if (-not $action -or -not $configId) {
            Write-PodeJsonResponse -Value @{ error = "action and config_id are required" } -StatusCode 400
            return
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        $transaction = $conn.BeginTransaction()
        
        try {
            switch ($action) {
                'configure_new' {
                    # Update FlowConfig
                    $updateCmd = $conn.CreateCommand()
                    $updateCmd.Transaction = $transaction
                    $updateCmd.CommandText = @"
UPDATE JobFlow.FlowConfig
SET expected_schedule = @expected_schedule,
    is_monitored = @is_monitored,
    alert_on_missing = @alert_on_missing,
    alert_on_critical_failure = @alert_on_critical_failure,
    modified_dttm = GETDATE(),
    modified_by = @modified_by,
    notes = @notes
WHERE config_id = @config_id
"@
                    $updateCmd.Parameters.AddWithValue('@config_id', $configId) | Out-Null
                    $updateCmd.Parameters.AddWithValue('@expected_schedule', $body.expected_schedule) | Out-Null
                    $updateCmd.Parameters.AddWithValue('@is_monitored', [bool]$body.is_monitored) | Out-Null
                    $updateCmd.Parameters.AddWithValue('@alert_on_missing', [bool]$body.alert_on_missing) | Out-Null
                    $updateCmd.Parameters.AddWithValue('@alert_on_critical_failure', [bool]$body.alert_on_critical_failure) | Out-Null
                    $updateCmd.Parameters.AddWithValue('@modified_by', 'Control Center') | Out-Null
                    $updateCmd.Parameters.AddWithValue('@notes', $(if ($body.notes) { $body.notes } else { [DBNull]::Value })) | Out-Null
                    $updateCmd.CommandTimeout = 10
                    $updateCmd.ExecuteNonQuery() | Out-Null
                    
                    # Insert Schedule row if scheduled type
                    if ($body.schedule -and $body.expected_schedule -notin @('VARIABLE', 'ON-DEMAND')) {
                        $sched = $body.schedule
                        $insertCmd = $conn.CreateCommand()
                        $insertCmd.Transaction = $transaction
                        $insertCmd.CommandText = @"
INSERT INTO JobFlow.Schedule
    (job_sqnc_id, job_sqnc_shrt_nm, schedule_type, schedule_frequency,
     schedule_day_of_week, schedule_day_of_month, schedule_week_of_month,
     expected_start_time, start_time_tolerance_minutes, is_active,
     alert_on_missing, notes, created_by)
VALUES
    (@job_sqnc_id, @flow_code, @schedule_type, @schedule_frequency,
     @schedule_day_of_week, @schedule_day_of_month, @schedule_week_of_month,
     @expected_start_time, @tolerance, 1,
     1, @notes, 'Control Center')
"@
                        $insertCmd.Parameters.AddWithValue('@job_sqnc_id', $jobSqncId) | Out-Null
                        $insertCmd.Parameters.AddWithValue('@flow_code', $flowCode) | Out-Null
                        $insertCmd.Parameters.AddWithValue('@schedule_type', $sched.schedule_type) | Out-Null
                        $insertCmd.Parameters.AddWithValue('@schedule_frequency', $(if ($null -ne $sched.schedule_frequency) { $sched.schedule_frequency } else { [DBNull]::Value })) | Out-Null
                        $insertCmd.Parameters.AddWithValue('@schedule_day_of_week', $(if ($null -ne $sched.schedule_day_of_week) { $sched.schedule_day_of_week } else { [DBNull]::Value })) | Out-Null
                        $insertCmd.Parameters.AddWithValue('@schedule_day_of_month', $(if ($null -ne $sched.schedule_day_of_month) { $sched.schedule_day_of_month } else { [DBNull]::Value })) | Out-Null
                        $insertCmd.Parameters.AddWithValue('@schedule_week_of_month', $(if ($null -ne $sched.schedule_week_of_month) { $sched.schedule_week_of_month } else { [DBNull]::Value })) | Out-Null
                        $insertCmd.Parameters.AddWithValue('@expected_start_time', $sched.expected_start_time) | Out-Null
                        $insertCmd.Parameters.AddWithValue('@tolerance', $(if ($null -ne $sched.start_time_tolerance_minutes) { $sched.start_time_tolerance_minutes } else { 30 })) | Out-Null
                        $insertCmd.Parameters.AddWithValue('@notes', $(if ($sched.notes) { $sched.notes } else { [DBNull]::Value })) | Out-Null
                        $insertCmd.CommandTimeout = 10
                        $insertCmd.ExecuteNonQuery() | Out-Null
                    }
                }
                
                'deactivate' {
                    # Update FlowConfig: disable monitoring, set end date
                    $updateCmd = $conn.CreateCommand()
                    $updateCmd.Transaction = $transaction
                    $updateCmd.CommandText = @"
UPDATE JobFlow.FlowConfig
SET is_monitored = 0,
    effective_end_date = CAST(GETDATE() AS DATE),
    modified_dttm = GETDATE(),
    modified_by = 'Control Center',
    notes = @notes
WHERE config_id = @config_id
"@
                    $updateCmd.Parameters.AddWithValue('@config_id', $configId) | Out-Null
                    $updateCmd.Parameters.AddWithValue('@notes', $(if ($body.notes) { $body.notes } else { [DBNull]::Value })) | Out-Null
                    $updateCmd.CommandTimeout = 10
                    $updateCmd.ExecuteNonQuery() | Out-Null
                    
                    # Deactivate any Schedule rows
                    $schedCmd = $conn.CreateCommand()
                    $schedCmd.Transaction = $transaction
                    $schedCmd.CommandText = @"
UPDATE JobFlow.Schedule
SET is_active = 0,
    effective_end_date = CAST(GETDATE() AS DATE),
    modified_dttm = GETDATE(),
    modified_by = 'Control Center'
WHERE job_sqnc_id = @job_sqnc_id
  AND is_active = 1
"@
                    $schedCmd.Parameters.AddWithValue('@job_sqnc_id', $jobSqncId) | Out-Null
                    $schedCmd.CommandTimeout = 10
                    $schedCmd.ExecuteNonQuery() | Out-Null
                }
                
                'reactivate' {
                    # Update FlowConfig: re-enable monitoring, clear end date
                    $updateCmd = $conn.CreateCommand()
                    $updateCmd.Transaction = $transaction
                    $updateCmd.CommandText = @"
UPDATE JobFlow.FlowConfig
SET is_monitored = @is_monitored,
    effective_end_date = NULL,
    modified_dttm = GETDATE(),
    modified_by = 'Control Center',
    notes = @notes
WHERE config_id = @config_id
"@
                    $updateCmd.Parameters.AddWithValue('@config_id', $configId) | Out-Null
                    $updateCmd.Parameters.AddWithValue('@is_monitored', [bool]$body.is_monitored) | Out-Null
                    $updateCmd.Parameters.AddWithValue('@notes', $(if ($body.notes) { $body.notes } else { [DBNull]::Value })) | Out-Null
                    $updateCmd.CommandTimeout = 10
                    $updateCmd.ExecuteNonQuery() | Out-Null
                    
                    # Reactivate Schedule rows, clear end date
                    $schedCmd = $conn.CreateCommand()
                    $schedCmd.Transaction = $transaction
                    $schedCmd.CommandText = @"
UPDATE JobFlow.Schedule
SET is_active = 1,
    effective_end_date = NULL,
    modified_dttm = GETDATE(),
    modified_by = 'Control Center'
WHERE job_sqnc_id = @job_sqnc_id
  AND is_active = 0
"@
                    $schedCmd.Parameters.AddWithValue('@job_sqnc_id', $jobSqncId) | Out-Null
                    $schedCmd.CommandTimeout = 10
                    $schedCmd.ExecuteNonQuery() | Out-Null
                }
                
                default {
                    throw "Unknown action: $action"
                }
            }
            
            $transaction.Commit()
            $conn.Close()
            
            Write-PodeJsonResponse -Value @{
                success = $true
                action = $action
                flow_code = $flowCode
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
        catch {
            $transaction.Rollback()
            throw
        }
    }
    catch {
        if ($conn -and $conn.State -eq 'Open') { $conn.Close() }
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Engine Status
# Returns orchestrator process health for the JobFlow monitor
# Driven entirely by ProcessRegistry - no module-specific status table needed
# ============================================================================
# ============================================================================
# ENGINE STATUS -- REMOVED
# ============================================================================
# The /api/jobflow/engine-status endpoint (~60 lines) was removed.
# Engine indicator card (JobFlow) is now driven by the shared engine-events.js
# WebSocket module via real-time PROCESS_STARTED/COMPLETED events.
# See: RealTime_Engine_Events_Architecture.md
# ============================================================================
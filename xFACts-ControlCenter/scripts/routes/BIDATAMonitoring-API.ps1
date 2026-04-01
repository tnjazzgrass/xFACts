# ============================================================================
# xFACts Control Center - BIDATA Monitoring API Endpoints
# Location: E:\xFACts-ControlCenter\scripts\routes\BIDATAMonitoring-API.ps1
# Version: Tracked in dbo.System_Metadata (component: BIDATA)
#
# API endpoints for the BIDATA Monitoring page.
# Provides data for today's build status, step progress, and historical data.
# ============================================================================

# ============================================================================
# API: Today's Build Status
# Returns current build status for today, including in-progress builds
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/bidata/todays-build' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get today's build(s) - there may be multiple attempts
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    b.build_id,
    b.build_date,
    b.instance_id,
    b.start_dttm,
    b.end_dttm,
    b.total_duration_seconds,
    b.total_duration_formatted,
    b.step_count,
    b.status,
    b.failed_step_id,
    b.failed_step_name,
    b.notified_dttm,
    (SELECT COUNT(*) FROM BIDATA.StepExecution WHERE build_id = b.build_id) AS steps_completed
FROM BIDATA.BuildExecution b
WHERE b.build_date = CAST(GETDATE() AS DATE)
  AND b.status NOT IN ('SUPERSEDED')
ORDER BY b.build_id DESC
"@
        $cmd.CommandTimeout = 15
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $builds = @()
        foreach ($row in $dataset.Tables[0].Rows) {
            $builds += @{
                build_id = $row['build_id']
                build_date = ([DateTime]$row['build_date']).ToString("yyyy-MM-dd")
                instance_id = if ($row['instance_id'] -is [DBNull]) { $null } else { $row['instance_id'] }
                start_dttm = if ($row['start_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['start_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                end_dttm = if ($row['end_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['end_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                total_duration_seconds = if ($row['total_duration_seconds'] -is [DBNull]) { $null } else { $row['total_duration_seconds'] }
                total_duration_formatted = if ($row['total_duration_formatted'] -is [DBNull]) { $null } else { $row['total_duration_formatted'] }
                step_count = if ($row['step_count'] -is [DBNull]) { 0 } else { $row['step_count'] }
                status = $row['status']
                failed_step_id = if ($row['failed_step_id'] -is [DBNull]) { $null } else { $row['failed_step_id'] }
                failed_step_name = if ($row['failed_step_name'] -is [DBNull]) { $null } else { $row['failed_step_name'] }
                steps_completed = if ($row['steps_completed'] -is [DBNull]) { 0 } else { $row['steps_completed'] }
            }
        }
        
        # Get scheduled start time for reference
        $schedCmd = $conn.CreateCommand()
        $schedCmd.CommandText = "SELECT setting_value FROM dbo.GlobalConfig WHERE setting_name = 'bidata_build_job_name' AND is_active = 1"
        $schedCmd.CommandTimeout = 5
        $jobName = $schedCmd.ExecuteScalar()
        if ($null -eq $jobName) { $jobName = "BIDATA Daily Build" }
        
        # Get average duration from last 14 days for ETA calculation
        $avgCmd = $conn.CreateCommand()
        $avgCmd.CommandText = @"
SELECT AVG(total_duration_seconds) AS avg_duration_seconds
FROM BIDATA.BuildExecution
WHERE build_date >= DATEADD(DAY, -14, GETDATE())
  AND status = 'COMPLETED'
"@
        $avgCmd.CommandTimeout = 10
        $avgDuration = $avgCmd.ExecuteScalar()
        $avgDurationSeconds = if ($avgDuration -is [DBNull] -or $null -eq $avgDuration) { $null } else { [int]$avgDuration }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            builds = $builds
            job_name = $jobName
            avg_duration_seconds = $avgDurationSeconds
            total_expected_steps = 20
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Step Progress
# Returns step details for current build execution panel
# Enhanced: includes build status and current step elapsed time calculation
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/bidata/step-progress' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $buildId = $WebEvent.Query['build_id']
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # If no build_id specified, get latest for today
        if ([string]::IsNullOrEmpty($buildId)) {
            $latestCmd = $conn.CreateCommand()
            $latestCmd.CommandText = @"
SELECT TOP 1 build_id, status, start_dttm
FROM BIDATA.BuildExecution 
WHERE build_date = CAST(GETDATE() AS DATE)
  AND status NOT IN ('NOT_STARTED', 'SUPERSEDED')
ORDER BY build_id DESC
"@
            $latestCmd.CommandTimeout = 5
            $latestAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($latestCmd)
            $latestDataset = New-Object System.Data.DataSet
            $latestAdapter.Fill($latestDataset) | Out-Null
            
            if ($latestDataset.Tables[0].Rows.Count -eq 0) {
                $conn.Close()
                Write-PodeJsonResponse -Value @{
                    build_id = $null
                    build_status = $null
                    is_running = $false
                    steps = @()
                    avg_durations = @{}
                    current_step_elapsed_seconds = $null
                    message = "No build found for today"
                    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                }
                return
            }
            
            $buildId = $latestDataset.Tables[0].Rows[0]['build_id']
            $buildStatus = $latestDataset.Tables[0].Rows[0]['status']
            $buildStart = if ($latestDataset.Tables[0].Rows[0]['start_dttm'] -is [DBNull]) { $null } else { [DateTime]$latestDataset.Tables[0].Rows[0]['start_dttm'] }
        }
        else {
            # Get build status for specified build_id
            $statusCmd = $conn.CreateCommand()
            $statusCmd.CommandText = "SELECT status, start_dttm FROM BIDATA.BuildExecution WHERE build_id = @build_id"
            $statusCmd.Parameters.AddWithValue("@build_id", [int]$buildId) | Out-Null
            $statusCmd.CommandTimeout = 5
            $statusAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($statusCmd)
            $statusDataset = New-Object System.Data.DataSet
            $statusAdapter.Fill($statusDataset) | Out-Null
            
            if ($statusDataset.Tables[0].Rows.Count -eq 0) {
                $conn.Close()
                Write-PodeJsonResponse -Value @{ error = "Build not found" } -StatusCode 404
                return
            }
            $buildStatus = $statusDataset.Tables[0].Rows[0]['status']
            $buildStart = if ($statusDataset.Tables[0].Rows[0]['start_dttm'] -is [DBNull]) { $null } else { [DateTime]$statusDataset.Tables[0].Rows[0]['start_dttm'] }
        }
        
        $isRunning = $buildStatus -eq 'IN_PROGRESS'
        
        # Get steps for this build
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    s.step_id,
    s.step_name,
    s.run_status,
    s.run_time,
    s.duration_seconds,
    s.duration_formatted
FROM BIDATA.StepExecution s
WHERE s.build_id = @build_id
ORDER BY s.step_id
"@
        $cmd.Parameters.AddWithValue("@build_id", $buildId) | Out-Null
        $cmd.CommandTimeout = 10
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $steps = @()
        $totalCompletedSeconds = 0
        foreach ($row in $dataset.Tables[0].Rows) {
            $steps += @{
                step_id = $row['step_id']
                step_name = $row['step_name']
                run_status = $row['run_status']
                run_time = if ($row['run_time'] -is [DBNull]) { $null } else { $row['run_time'] }
                duration_seconds = $row['duration_seconds']
                duration_formatted = $row['duration_formatted']
            }
            if ($row['duration_seconds'] -isnot [DBNull]) {
                $totalCompletedSeconds += $row['duration_seconds']
            }
        }
        
        # Calculate current step elapsed time if build is running
        $currentStepElapsed = $null
        if ($isRunning -and $null -ne $buildStart) {
            $totalElapsed = [int]((Get-Date) - $buildStart).TotalSeconds
            $currentStepElapsed = $totalElapsed - $totalCompletedSeconds
            if ($currentStepElapsed -lt 0) { $currentStepElapsed = 0 }
        }
        
        # Get average step durations for comparison - use string keys for JSON
        $avgCmd = $conn.CreateCommand()
        $avgCmd.CommandText = @"
SELECT 
    s.step_id,
    s.step_name,
    AVG(s.duration_seconds) AS avg_seconds
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE b.build_date >= DATEADD(DAY, -14, GETDATE())
  AND b.status = 'COMPLETED'
  AND s.run_status = 1
GROUP BY s.step_id, s.step_name
"@
        $avgCmd.CommandTimeout = 10
        $avgAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($avgCmd)
        $avgDataset = New-Object System.Data.DataSet
        $avgAdapter.Fill($avgDataset) | Out-Null
        
        # Use string keys for JSON serialization compatibility
        $avgDurations = @{}
        foreach ($row in $avgDataset.Tables[0].Rows) {
            $avgDurations["$($row['step_id'])"] = [int]$row['avg_seconds']
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            build_id = [int]$buildId
            build_status = $buildStatus
            is_running = $isRunning
            steps = $steps
            avg_durations = $avgDurations
            current_step_elapsed_seconds = $currentStepElapsed
            next_step_number = $steps.Count + 1
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Build History
# Returns all builds grouped by year/month for the history panel
# Enhanced: includes spark bar widths and monthly summaries
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/bidata/build-history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get max duration for spark bar scaling
        $maxCmd = $conn.CreateCommand()
        $maxCmd.CommandText = "SELECT MAX(total_duration_seconds) FROM BIDATA.BuildExecution WHERE status = 'COMPLETED'"
        $maxCmd.CommandTimeout = 10
        $maxDuration = $maxCmd.ExecuteScalar()
        $maxDurationSeconds = if ($maxDuration -is [DBNull] -or $null -eq $maxDuration) { 18000 } else { [int]$maxDuration }
        
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT 
    b.build_id,
    b.build_date,
    b.job_name,
    b.instance_id,
    b.start_dttm,
    b.end_dttm,
    b.total_duration_seconds,
    b.total_duration_formatted,
    b.step_count,
    b.status,
    b.failed_step_name,
    YEAR(b.build_date) AS build_year,
    MONTH(b.build_date) AS build_month
FROM BIDATA.BuildExecution b
WHERE b.status IN ('COMPLETED', 'FAILED')
ORDER BY b.build_date DESC, b.build_id DESC
"@
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        # Group by year and month - use string keys, track stats
        $grouped = @{}
        $monthStats = @{}
        
        foreach ($row in $dataset.Tables[0].Rows) {
            $year = "$($row['build_year'])"
            $month = "$($row['build_month'])"
            $monthKey = "$year-$month"
            
            if (-not $grouped.ContainsKey($year)) {
                $grouped[$year] = @{}
            }
            if (-not $grouped[$year].ContainsKey($month)) {
                $grouped[$year][$month] = @()
                $monthStats[$monthKey] = @{ success = 0; failed = 0; durations = @() }
            }
            
            # Track month stats
            if ($row['status'] -eq 'COMPLETED') {
                $monthStats[$monthKey].success++
                if ($row['total_duration_seconds'] -isnot [DBNull]) {
                    $monthStats[$monthKey].durations += $row['total_duration_seconds']
                }
            } else {
                $monthStats[$monthKey].failed++
            }
            
            # Calculate spark bar width (percentage of max)
            $sparkWidth = 0
            if ($row['total_duration_seconds'] -isnot [DBNull] -and $maxDurationSeconds -gt 0) {
                $sparkWidth = [int]([math]::Round(($row['total_duration_seconds'] / $maxDurationSeconds) * 100))
            }
            
            $grouped[$year][$month] += @{
                build_id = $row['build_id']
                build_date = ([DateTime]$row['build_date']).ToString("yyyy-MM-dd")
                day_of_month = ([DateTime]$row['build_date']).Day
                day_name = ([DateTime]$row['build_date']).ToString("ddd")
                job_name = if ($row['job_name'] -is [DBNull]) { $null } else { $row['job_name'] }
                instance_id = if ($row['instance_id'] -is [DBNull]) { $null } else { $row['instance_id'] }
                start_dttm = if ($row['start_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['start_dttm']).ToString("HH:mm") }
                end_dttm = if ($row['end_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['end_dttm']).ToString("HH:mm") }
                total_duration_seconds = if ($row['total_duration_seconds'] -is [DBNull]) { $null } else { $row['total_duration_seconds'] }
                total_duration_formatted = if ($row['total_duration_formatted'] -is [DBNull]) { $null } else { $row['total_duration_formatted'] }
                status = $row['status']
                failed_step_name = if ($row['failed_step_name'] -is [DBNull]) { $null } else { $row['failed_step_name'] }
                spark_width = $sparkWidth
            }
        }
        
        # Calculate month summaries
        $monthSummaries = @{}
        foreach ($key in $monthStats.Keys) {
            $stats = $monthStats[$key]
            $avgDuration = $null
            if ($stats.durations.Count -gt 0) {
                $avgDuration = [int](($stats.durations | Measure-Object -Average).Average)
            }
            $monthSummaries[$key] = @{
                success_count = $stats.success
                failed_count = $stats.failed
                avg_duration_seconds = $avgDuration
                avg_duration_formatted = if ($avgDuration) { $h = [int][Math]::Floor($avgDuration / 3600); $m = [int][Math]::Floor(($avgDuration % 3600) / 60); "{0}:{1:D2}" -f $h, $m } else { $null }
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            grouped = $grouped
            month_summaries = $monthSummaries
            max_duration_seconds = $maxDurationSeconds
            total_count = $dataset.Tables[0].Rows.Count
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Duration Trend
# Returns daily build durations for charting with configurable range
# Supports: days parameter OR from/to date range parameters
# Enhanced: aggregates multiple attempts per day with segments for stacked bars
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/bidata/duration-trend' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $days = $WebEvent.Query['days']
        $fromDate = $WebEvent.Query['from']
        $toDate = $WebEvent.Query['to']
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        $cmd = $conn.CreateCommand()
        
        # Check if using custom date range or days-based range
        if (-not [string]::IsNullOrEmpty($fromDate) -and -not [string]::IsNullOrEmpty($toDate)) {
            # Custom date range
            $cmd.CommandText = @"
SELECT 
    build_date,
    start_dttm,
    end_dttm,
    total_duration_seconds,
    status
FROM BIDATA.BuildExecution
WHERE build_date >= @fromDate
  AND build_date <= @toDate
  AND status IN ('COMPLETED', 'FAILED')
  AND start_dttm IS NOT NULL
ORDER BY build_date, start_dttm
"@
            $cmd.Parameters.AddWithValue("@fromDate", $fromDate) | Out-Null
            $cmd.Parameters.AddWithValue("@toDate", $toDate) | Out-Null
        }
        else {
            # Days-based range (default)
            if ([string]::IsNullOrEmpty($days) -or $days -eq 'all') { 
                $days = 9999
            }
            $cmd.CommandText = @"
SELECT 
    build_date,
    start_dttm,
    end_dttm,
    total_duration_seconds,
    status
FROM BIDATA.BuildExecution
WHERE build_date >= DATEADD(DAY, -@days, GETDATE())
  AND status IN ('COMPLETED', 'FAILED')
  AND start_dttm IS NOT NULL
ORDER BY build_date, start_dttm
"@
            $cmd.Parameters.AddWithValue("@days", [int]$days) | Out-Null
        }
        
        $cmd.CommandTimeout = 15
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        # Aggregate by day
        $dayData = @{}
        foreach ($row in $dataset.Tables[0].Rows) {
            $dateKey = ([DateTime]$row['build_date']).ToString("yyyy-MM-dd")
            
            if (-not $dayData.ContainsKey($dateKey)) {
                $dayData[$dateKey] = @{
                    date = $dateKey
                    date_short = ([DateTime]$row['build_date']).ToString("M/d")
                    attempts = @()
                    first_start = $null
                    last_end = $null
                    has_success = $false
                }
            }
            
            $startDttm = if ($row['start_dttm'] -is [DBNull]) { $null } else { [DateTime]$row['start_dttm'] }
            $endDttm = if ($row['end_dttm'] -is [DBNull]) { $null } else { [DateTime]$row['end_dttm'] }
            $durationSec = if ($row['total_duration_seconds'] -is [DBNull]) { 0 } else { $row['total_duration_seconds'] }
            
            $dayData[$dateKey].attempts += @{
                start_dttm = $startDttm
                end_dttm = $endDttm
                duration_seconds = $durationSec
                status = $row['status']
            }
            
            if ($row['status'] -eq 'COMPLETED') {
                $dayData[$dateKey].has_success = $true
            }
            
            # Track first start and last end
            if ($startDttm -and (-not $dayData[$dateKey].first_start -or $startDttm -lt $dayData[$dateKey].first_start)) {
                $dayData[$dateKey].first_start = $startDttm
            }
            if ($endDttm -and (-not $dayData[$dateKey].last_end -or $endDttm -gt $dayData[$dateKey].last_end)) {
                $dayData[$dateKey].last_end = $endDttm
            }
        }
        
        # Build data points with segments for stacked bars
        $dataPoints = @()
        foreach ($dateKey in ($dayData.Keys | Sort-Object)) {
            $day = $dayData[$dateKey]
            $segments = @()
            $totalExecutionSeconds = 0
            $totalGapSeconds = 0
            $totalWallClockSeconds = 0
            
            if ($day.first_start -and $day.last_end) {
                $totalWallClockSeconds = [int]($day.last_end - $day.first_start).TotalSeconds
            }
            
            # Build segments (execution time and gaps)
            $prevEnd = $null
            foreach ($attempt in $day.attempts) {
                # Add gap segment if there was a previous attempt
                if ($prevEnd -and $attempt.start_dttm) {
                    $gapSeconds = [int]($attempt.start_dttm - $prevEnd).TotalSeconds
                    if ($gapSeconds -gt 0) {
                        $segments += @{ type = 'gap'; seconds = $gapSeconds }
                        $totalGapSeconds += $gapSeconds
                    }
                }
                
                # Add execution segment
                $segments += @{
                    type = if ($attempt.status -eq 'COMPLETED') { 'success' } else { 'failed' }
                    seconds = $attempt.duration_seconds
                }
                $totalExecutionSeconds += $attempt.duration_seconds
                
                $prevEnd = $attempt.end_dttm
            }
            
            $dataPoints += @{
                date = $day.date
                date_short = $day.date_short
                segments = $segments
                total_execution_seconds = $totalExecutionSeconds
                total_gap_seconds = $totalGapSeconds
                total_wall_clock_seconds = $totalWallClockSeconds
                attempt_count = $day.attempts.Count
                has_success = $day.has_success
                final_status = if ($day.has_success) { 'COMPLETED' } else { 'FAILED' }
                # For backward compatibility, also include simple duration
                duration_seconds = if ($totalWallClockSeconds -gt 0) { $totalWallClockSeconds } else { $totalExecutionSeconds }
            }
        }
        
        # Calculate stats (using execution time only for meaningful averages)
        $completedDays = $dataPoints | Where-Object { $_.has_success }
        $executionDurations = $completedDays | ForEach-Object { $_.total_execution_seconds }
        $avgSeconds = if ($executionDurations.Count -gt 0) { [int]($executionDurations | Measure-Object -Average).Average } else { $null }
        $minSeconds = if ($executionDurations.Count -gt 0) { ($executionDurations | Measure-Object -Minimum).Minimum } else { $null }
        $maxSeconds = if ($executionDurations.Count -gt 0) { ($executionDurations | Measure-Object -Maximum).Maximum } else { $null }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            data_points = $dataPoints
            stats = @{
                avg_seconds = $avgSeconds
                min_seconds = $minSeconds
                max_seconds = $maxSeconds
                avg_formatted = if ($avgSeconds) { "{0}:{1:D2}:{2:D2}" -f [int]($avgSeconds/3600), [int](($avgSeconds%3600)/60), [int]($avgSeconds%60) } else { $null }
                count = $dataPoints.Count
            }
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Build Details
# Returns detailed step information for a specific build (for slideout)
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/bidata/build-details' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $buildId = $WebEvent.Query['build_id']
        
        if ([string]::IsNullOrEmpty($buildId)) {
            Write-PodeJsonResponse -Value @{ error = "build_id is required" } -StatusCode 400
            return
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get build header info
        $buildCmd = $conn.CreateCommand()
        $buildCmd.CommandText = @"
SELECT 
    build_id,
    build_date,
    job_name,
    instance_id,
    start_dttm,
    end_dttm,
    total_duration_seconds,
    total_duration_formatted,
    step_count,
    status,
    run_status,
    failed_step_id,
    failed_step_name,
    notified_dttm
FROM BIDATA.BuildExecution
WHERE build_id = @build_id
"@
        $buildCmd.Parameters.AddWithValue("@build_id", [int]$buildId) | Out-Null
        $buildCmd.CommandTimeout = 10
        $buildAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($buildCmd)
        $buildDataset = New-Object System.Data.DataSet
        $buildAdapter.Fill($buildDataset) | Out-Null
        
        if ($buildDataset.Tables[0].Rows.Count -eq 0) {
            $conn.Close()
            Write-PodeJsonResponse -Value @{ error = "Build not found" } -StatusCode 404
            return
        }
        
        $row = $buildDataset.Tables[0].Rows[0]
        $build = @{
            build_id = $row['build_id']
            build_date = ([DateTime]$row['build_date']).ToString("yyyy-MM-dd")
            job_name = if ($row['job_name'] -is [DBNull]) { $null } else { $row['job_name'] }
            instance_id = if ($row['instance_id'] -is [DBNull]) { $null } else { $row['instance_id'] }
            start_dttm = if ($row['start_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['start_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
            end_dttm = if ($row['end_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['end_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
            total_duration_seconds = if ($row['total_duration_seconds'] -is [DBNull]) { $null } else { $row['total_duration_seconds'] }
            total_duration_formatted = if ($row['total_duration_formatted'] -is [DBNull]) { $null } else { $row['total_duration_formatted'] }
            step_count = if ($row['step_count'] -is [DBNull]) { 0 } else { $row['step_count'] }
            status = $row['status']
            failed_step_id = if ($row['failed_step_id'] -is [DBNull]) { $null } else { $row['failed_step_id'] }
            failed_step_name = if ($row['failed_step_name'] -is [DBNull]) { $null } else { $row['failed_step_name'] }
            notified_dttm = if ($row['notified_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['notified_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
        }
        
        # Get all steps for this build
        $stepsCmd = $conn.CreateCommand()
        $stepsCmd.CommandText = @"
SELECT 
    step_id,
    step_name,
    run_status,
    duration_seconds,
    duration_formatted
FROM BIDATA.StepExecution
WHERE build_id = @build_id
ORDER BY step_id
"@
        $stepsCmd.Parameters.AddWithValue("@build_id", [int]$buildId) | Out-Null
        $stepsCmd.CommandTimeout = 10
        $stepsAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($stepsCmd)
        $stepsDataset = New-Object System.Data.DataSet
        $stepsAdapter.Fill($stepsDataset) | Out-Null
        
        $steps = @()
        foreach ($stepRow in $stepsDataset.Tables[0].Rows) {
            $steps += @{
                step_id = $stepRow['step_id']
                step_name = $stepRow['step_name']
                run_status = $stepRow['run_status']
                duration_seconds = $stepRow['duration_seconds']
                duration_formatted = $stepRow['duration_formatted']
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            build = $build
            steps = $steps
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# API: Builds for Date
# Returns all builds and their steps for a specific date (for slideout with multiple executions)
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/bidata/builds-for-date' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $dateStr = $WebEvent.Query['date']
        
        if ([string]::IsNullOrEmpty($dateStr)) {
            Write-PodeJsonResponse -Value @{ error = "date is required (YYYY-MM-DD)" } -StatusCode 400
            return
        }
        
        $connString = "Server=AVG-PROD-LSNR;Database=xFACts;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $conn.Open()
        
        # Get all builds for this date (ordered by build_id DESC so most recent first)
        $buildCmd = $conn.CreateCommand()
        $buildCmd.CommandText = @"
SELECT 
    build_id,
    build_date,
    job_name,
    instance_id,
    start_dttm,
    end_dttm,
    total_duration_seconds,
    total_duration_formatted,
    step_count,
    status,
    run_status,
    failed_step_id,
    failed_step_name,
    notified_dttm
FROM BIDATA.BuildExecution
WHERE build_date = @build_date
  AND status NOT IN ('NOT_STARTED', 'SUPERSEDED')
ORDER BY build_id DESC
"@
        $buildCmd.Parameters.AddWithValue("@build_date", $dateStr) | Out-Null
        $buildCmd.CommandTimeout = 10
        $buildAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($buildCmd)
        $buildDataset = New-Object System.Data.DataSet
        $buildAdapter.Fill($buildDataset) | Out-Null
        
        if ($buildDataset.Tables[0].Rows.Count -eq 0) {
            $conn.Close()
            Write-PodeJsonResponse -Value @{ error = "No builds found for date: $dateStr" } -StatusCode 404
            return
        }
        
        $builds = @()
        
        foreach ($row in $buildDataset.Tables[0].Rows) {
            $buildId = $row['build_id']
            
            $build = @{
                build_id = $buildId
                build_date = ([DateTime]$row['build_date']).ToString("yyyy-MM-dd")
                job_name = if ($row['job_name'] -is [DBNull]) { $null } else { $row['job_name'] }
                instance_id = if ($row['instance_id'] -is [DBNull]) { $null } else { $row['instance_id'] }
                start_dttm = if ($row['start_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['start_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                end_dttm = if ($row['end_dttm'] -is [DBNull]) { $null } else { ([DateTime]$row['end_dttm']).ToString("yyyy-MM-dd HH:mm:ss") }
                total_duration_seconds = if ($row['total_duration_seconds'] -is [DBNull]) { $null } else { $row['total_duration_seconds'] }
                total_duration_formatted = if ($row['total_duration_formatted'] -is [DBNull]) { $null } else { $row['total_duration_formatted'] }
                step_count = if ($row['step_count'] -is [DBNull]) { 0 } else { $row['step_count'] }
                status = $row['status']
                failed_step_id = if ($row['failed_step_id'] -is [DBNull]) { $null } else { $row['failed_step_id'] }
                failed_step_name = if ($row['failed_step_name'] -is [DBNull]) { $null } else { $row['failed_step_name'] }
            }
            
            # Get steps for this build
            $stepsCmd = $conn.CreateCommand()
            $stepsCmd.CommandText = @"
SELECT 
    step_id,
    step_name,
    run_status,
    duration_seconds,
    duration_formatted
FROM BIDATA.StepExecution
WHERE build_id = @build_id
ORDER BY step_id
"@
            $stepsCmd.Parameters.AddWithValue("@build_id", [int]$buildId) | Out-Null
            $stepsCmd.CommandTimeout = 10
            $stepsAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($stepsCmd)
            $stepsDataset = New-Object System.Data.DataSet
            $stepsAdapter.Fill($stepsDataset) | Out-Null
            
            $steps = @()
            foreach ($stepRow in $stepsDataset.Tables[0].Rows) {
                $steps += @{
                    step_id = $stepRow['step_id']
                    step_name = $stepRow['step_name']
                    run_status = $stepRow['run_status']
                    duration_seconds = $stepRow['duration_seconds']
                    duration_formatted = $stepRow['duration_formatted']
                }
            }
            
            $builds += @{
                build = $build
                steps = $steps
            }
        }
        
        $conn.Close()
        
        Write-PodeJsonResponse -Value @{
            date = $dateStr
            builds = $builds
            build_count = $builds.Count
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

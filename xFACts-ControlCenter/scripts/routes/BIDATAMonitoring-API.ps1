<#
.SYNOPSIS
    BIDATA Monitoring dashboard API endpoints.

.DESCRIPTION
    Backing API for the BIDATA Monitoring page. All xFACts reads (today's
    build status, step progress, duration trend, build history, and per-build
    or per-date detail) run against the xFACts AG listener through the shared
    Invoke-XFActsQuery helper. The today's-build endpoint resolves the job's
    total expected step count from msdb.dbo.sysjobsteps on the configured
    BIDATA source server, cached via Get-CachedResult; the step-progress
    endpoint resolves the next running step's name from the same source. Those
    msdb reads target the specific named server that hosts the BIDATA database
    and its SQL Agent job, so they use a direct SqlConnection rather than an
    AG-routed helper (no shared helper targets an arbitrary named server).
    Endpoints registered by this file:

      GET /api/bidata/todays-build      Today's build status cards
      GET /api/bidata/step-progress     Step execution detail for the current build
      GET /api/bidata/build-history     Year/month/day build history rollup
      GET /api/bidata/duration-trend    Daily build durations for the trend chart
      GET /api/bidata/build-details     Single build detail by build_id
      GET /api/bidata/builds-for-date   All builds and steps for one date

.COMPONENT
    BIDATA

.NOTES
    File Name : BIDATAMonitoring-API.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\BIDATAMonitoring-API.ps1

    FILE ORGANIZATION
    -----------------
    ROUTE: API ENDPOINTS
#>

<# ============================================================================
   ROUTE: API ENDPOINTS
   ----------------------------------------------------------------------------
   Registers the six GET endpoints that back the BIDATA Monitoring dashboard.
   Each endpoint guards access with Test-ActionEndpoint, runs its parameterized
   query through the shared xFACts data-access helpers, shapes the result, and
   returns JSON via Write-PodeJsonResponse. The today's-build and step-progress
   endpoints additionally read msdb on the configured BIDATA source server via
   a direct SqlConnection to resolve job step metadata.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/api/bidata/todays-build' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        # -- Resolve total expected step count first, so the response below is
        # assembled exactly once. The authoritative source is
        # msdb.dbo.sysjobsteps on the BIDATA source server, cached via
        # Get-CachedResult under 'bidata_step_count' (TTL from GlobalConfig
        # cache_ttl_bidata_step_count_seconds). The cache scriptblock throws on
        # any authoritative failure, which both keeps the failed lookup out of
        # the cache (Get-CachedResult only stores the returned value) and hands
        # control to the catch below, where MAX(step_id) from the most recent
        # completed build is used as an UNCACHED fallback. A null result means
        # neither source produced a count; the UI then shows a placeholder.
        $totalExpectedSteps = $null
        try {
            $totalExpectedSteps = Get-CachedResult -CacheKey 'bidata_step_count' -ScriptBlock {
                $cfgRows = Invoke-XFActsQuery -Query @"
SELECT
    MAX(CASE WHEN setting_name = 'bidata_build_source_server' THEN setting_value END) AS source_server,
    MAX(CASE WHEN setting_name = 'bidata_build_job_name'      THEN setting_value END) AS job_name
FROM dbo.GlobalConfig
WHERE setting_name IN ('bidata_build_source_server', 'bidata_build_job_name')
  AND is_active = 1
"@
                $sourceServer = $null
                $jobNameForSteps = $null
                if ($cfgRows -and $cfgRows.Count -gt 0) {
                    $sourceServer    = ConvertTo-SafeValue $cfgRows[0].source_server
                    $jobNameForSteps = ConvertTo-SafeValue $cfgRows[0].job_name
                }

                if ([string]::IsNullOrEmpty($sourceServer) -or [string]::IsNullOrEmpty($jobNameForSteps)) {
                    throw "BIDATA source server or job name not configured"
                }

                # Direct read of msdb on the named BIDATA source server. No CCShared
                # helper targets an arbitrary named server: Invoke-XFActsQuery is the
                # xFACts listener, and Invoke-AGReadQuery routes to whichever replica
                # is currently secondary -- but msdb is instance-local and the BIDATA
                # job lives on this specific box regardless of AG role, so the server
                # name from GlobalConfig is the only correct target.
                $count = $null
                $msdbConn = $null
                try {
                    $msdbConnString = "Server=$sourceServer;Database=msdb;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
                    $msdbConn = New-Object System.Data.SqlClient.SqlConnection($msdbConnString)
                    $msdbConn.Open()
                    $msdbCmd = $msdbConn.CreateCommand()
                    $msdbCmd.CommandText = @"
SELECT COUNT(*) AS step_count
FROM msdb.dbo.sysjobs j
INNER JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
WHERE j.name = @job_name
"@
                    $msdbCmd.Parameters.AddWithValue("@job_name", $jobNameForSteps) | Out-Null
                    $msdbCmd.CommandTimeout = 5
                    $stepResult = $msdbCmd.ExecuteScalar()
                    if ($stepResult -isnot [DBNull] -and $null -ne $stepResult -and [int]$stepResult -gt 0) {
                        $count = [int]$stepResult
                    }
                }
                finally {
                    if ($msdbConn -and $msdbConn.State -eq 'Open') { $msdbConn.Close() }
                }

                if ($null -eq $count) {
                    throw "BIDATA step count unavailable from msdb"
                }
                return $count
            }
        }
        catch {
            # Authoritative path failed -- fall back to MAX(step_id) from the most
            # recent completed build. This runs entirely outside Get-CachedResult,
            # so the fallback value is never cached and a transient source-server
            # hiccup cannot poison the cache for the full TTL.
            $fbRows = Invoke-XFActsQuery -Query @"
SELECT TOP 1 (SELECT MAX(s.step_id) FROM BIDATA.StepExecution s WHERE s.build_id = b.build_id) AS max_step_id
FROM BIDATA.BuildExecution b
WHERE b.status = 'COMPLETED'
ORDER BY b.build_id DESC
"@
            if ($fbRows -and $fbRows.Count -gt 0 -and -not ($fbRows[0].max_step_id -is [DBNull]) -and [int]$fbRows[0].max_step_id -gt 0) {
                $totalExpectedSteps = [int]$fbRows[0].max_step_id
            }
        }

        # -- Today's build(s): there may be multiple attempts for the day. --

        $buildRows = Invoke-XFActsQuery -Query @"
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

        $builds = @()
        foreach ($row in $buildRows) {
            $builds += @{
                build_id                 = $row.build_id
                build_date               = ([DateTime]$row.build_date).ToString("yyyy-MM-dd")
                instance_id              = ConvertTo-SafeValue $row.instance_id
                start_dttm               = ConvertTo-SafeDateTime $row.start_dttm
                end_dttm                 = ConvertTo-SafeDateTime $row.end_dttm
                total_duration_seconds   = ConvertTo-SafeValue $row.total_duration_seconds
                total_duration_formatted = ConvertTo-SafeValue $row.total_duration_formatted
                step_count               = if ($row.step_count -is [DBNull]) { 0 } else { $row.step_count }
                status                   = $row.status
                failed_step_id           = ConvertTo-SafeValue $row.failed_step_id
                failed_step_name         = ConvertTo-SafeValue $row.failed_step_name
                steps_completed          = if ($row.steps_completed -is [DBNull]) { 0 } else { $row.steps_completed }
            }
        }

        # Configured job name for reference (falls back to a default label).
        $jobNameRows = Invoke-XFActsQuery -Query @"
SELECT setting_value
FROM dbo.GlobalConfig
WHERE setting_name = 'bidata_build_job_name'
  AND is_active = 1
"@
        $jobName = if ($jobNameRows -and $jobNameRows.Count -gt 0 -and -not ($jobNameRows[0].setting_value -is [DBNull])) { $jobNameRows[0].setting_value } else { "BIDATA Daily Build" }

        # Average duration over the last 14 completed builds, for the ETA calculation.
        $avgRows = Invoke-XFActsQuery -Query @"
SELECT AVG(total_duration_seconds) AS avg_duration_seconds
FROM BIDATA.BuildExecution
WHERE build_date >= DATEADD(DAY, -14, GETDATE())
  AND status = 'COMPLETED'
"@
        $avgDurationSeconds = $null
        if ($avgRows -and $avgRows.Count -gt 0 -and -not ($avgRows[0].avg_duration_seconds -is [DBNull])) {
            $avgDurationSeconds = [int]$avgRows[0].avg_duration_seconds
        }

        Write-PodeJsonResponse -Value @{
            builds               = $builds
            job_name             = $jobName
            avg_duration_seconds = $avgDurationSeconds
            total_expected_steps = $totalExpectedSteps
            timestamp            = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/bidata/step-progress' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $buildId = $WebEvent.Query['build_id']

        # Resolve the target build: explicit build_id, or the latest for today.
        $buildStatus = $null
        $buildStart = $null
        if ([string]::IsNullOrEmpty($buildId)) {
            $latestRows = Invoke-XFActsQuery -Query @"
SELECT TOP 1 build_id, status, start_dttm
FROM BIDATA.BuildExecution
WHERE build_date = CAST(GETDATE() AS DATE)
  AND status NOT IN ('NOT_STARTED', 'SUPERSEDED')
ORDER BY build_id DESC
"@
            if (-not $latestRows -or $latestRows.Count -eq 0) {
                Write-PodeJsonResponse -Value @{
                    build_id                     = $null
                    build_status                 = $null
                    is_running                   = $false
                    steps                        = @()
                    avg_durations                = @{}
                    current_step_elapsed_seconds = $null
                    next_step_name               = $null
                    message                      = "No build found for today"
                    timestamp                    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                }
                return
            }
            $buildId     = $latestRows[0].build_id
            $buildStatus = $latestRows[0].status
            $buildStart  = if ($latestRows[0].start_dttm -is [DBNull]) { $null } else { [DateTime]$latestRows[0].start_dttm }
        }
        else {
            $statusRows = Invoke-XFActsQuery -Query @"
SELECT status, start_dttm
FROM BIDATA.BuildExecution
WHERE build_id = @build_id
"@ -Parameters @{ build_id = [int]$buildId }
            if (-not $statusRows -or $statusRows.Count -eq 0) {
                Write-PodeJsonResponse -Value @{ error = "Build not found" } -StatusCode 404
                return
            }
            $buildStatus = $statusRows[0].status
            $buildStart  = if ($statusRows[0].start_dttm -is [DBNull]) { $null } else { [DateTime]$statusRows[0].start_dttm }
        }

        $isRunning = $buildStatus -eq 'IN_PROGRESS'

        # Steps for this build.
        $stepRows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters @{ build_id = $buildId }

        $steps = @()
        $totalCompletedSeconds = 0
        $maxCapturedStepId = 0
        foreach ($row in $stepRows) {
            $steps += @{
                step_id            = $row.step_id
                step_name          = $row.step_name
                run_status         = $row.run_status
                run_time           = ConvertTo-SafeValue $row.run_time
                duration_seconds   = $row.duration_seconds
                duration_formatted = $row.duration_formatted
            }
            if ($row.duration_seconds -isnot [DBNull]) {
                $totalCompletedSeconds += $row.duration_seconds
            }
            if ([int]$row.step_id -gt $maxCapturedStepId) {
                $maxCapturedStepId = [int]$row.step_id
            }
        }

        # Current-step elapsed time, only meaningful while running.
        $currentStepElapsed = $null
        if ($isRunning -and $null -ne $buildStart) {
            $totalElapsed = [int]((Get-Date) - $buildStart).TotalSeconds
            $currentStepElapsed = $totalElapsed - $totalCompletedSeconds
            if ($currentStepElapsed -lt 0) { $currentStepElapsed = 0 }
        }

        # 14-day average step durations, keyed by step_id string for JSON.
        $avgRows = Invoke-XFActsQuery -Query @"
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
        $avgDurations = @{}
        foreach ($row in $avgRows) {
            $avgDurations["$($row.step_id)"] = [int]$row.avg_seconds
        }

        # Next running step's name from msdb.dbo.sysjobsteps on the BIDATA source
        # server. Best-effort: any failure leaves next_step_name null and the UI
        # falls back to its "Step N executing" label. The msdb read targets the
        # specific named server hosting the BIDATA job (instance-local; not an AG
        # database), so it uses a direct SqlConnection -- no shared helper targets
        # an arbitrary named server.
        $nextStepName = $null
        if ($isRunning -and $maxCapturedStepId -gt 0) {
            $cfgRows = Invoke-XFActsQuery -Query @"
SELECT
    MAX(CASE WHEN setting_name = 'bidata_build_source_server' THEN setting_value END) AS source_server,
    MAX(CASE WHEN setting_name = 'bidata_build_job_name'      THEN setting_value END) AS job_name
FROM dbo.GlobalConfig
WHERE setting_name IN ('bidata_build_source_server', 'bidata_build_job_name')
  AND is_active = 1
"@
            $sourceServer = $null
            $jobNameForLookup = $null
            if ($cfgRows -and $cfgRows.Count -gt 0) {
                $sourceServer     = ConvertTo-SafeValue $cfgRows[0].source_server
                $jobNameForLookup = ConvertTo-SafeValue $cfgRows[0].job_name
            }

            if (-not [string]::IsNullOrEmpty($sourceServer) -and -not [string]::IsNullOrEmpty($jobNameForLookup)) {
                $nextStepId = $maxCapturedStepId + 1
                $msdbConn = $null
                try {
                    $msdbConnString = "Server=$sourceServer;Database=msdb;Integrated Security=True;Application Name=xFACts Control Center;Connect Timeout=5;"
                    $msdbConn = New-Object System.Data.SqlClient.SqlConnection($msdbConnString)
                    $msdbConn.Open()
                    $msdbCmd = $msdbConn.CreateCommand()
                    $msdbCmd.CommandText = @"
SELECT js.step_name
FROM msdb.dbo.sysjobs j
INNER JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
WHERE j.name = @job_name
  AND js.step_id = @step_id
"@
                    $msdbCmd.Parameters.AddWithValue("@job_name", $jobNameForLookup) | Out-Null
                    $msdbCmd.Parameters.AddWithValue("@step_id", $nextStepId) | Out-Null
                    $msdbCmd.CommandTimeout = 5
                    $stepNameResult = $msdbCmd.ExecuteScalar()
                    if ($stepNameResult -isnot [DBNull] -and $null -ne $stepNameResult) {
                        $nextStepName = [string]$stepNameResult
                    }
                }
                catch {
                    $nextStepName = $null
                }
                finally {
                    if ($msdbConn -and $msdbConn.State -eq 'Open') { $msdbConn.Close() }
                }
            }
        }

        Write-PodeJsonResponse -Value @{
            build_id                     = [int]$buildId
            build_status                 = $buildStatus
            is_running                   = $isRunning
            steps                        = $steps
            avg_durations                = $avgDurations
            current_step_elapsed_seconds = $currentStepElapsed
            next_step_number             = $steps.Count + 1
            next_step_name               = $nextStepName
            timestamp                    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/bidata/build-history' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        # Max completed duration for spark-bar scaling (default when no data yet).
        $maxRows = Invoke-XFActsQuery -Query @"
SELECT MAX(total_duration_seconds) AS max_seconds
FROM BIDATA.BuildExecution
WHERE status = 'COMPLETED'
"@
        $maxDurationSeconds = if ($maxRows -and $maxRows.Count -gt 0 -and -not ($maxRows[0].max_seconds -is [DBNull])) { [int]$maxRows[0].max_seconds } else { 18000 }

        $rows = Invoke-XFActsQuery -Query @"
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

        $grouped = @{}
        $monthStats = @{}
        $totalCount = if ($rows) { $rows.Count } else { 0 }

        foreach ($row in $rows) {
            $year = "$($row.build_year)"
            $month = "$($row.build_month)"
            $monthKey = "$year-$month"

            if (-not $grouped.ContainsKey($year)) {
                $grouped[$year] = @{}
            }
            if (-not $grouped[$year].ContainsKey($month)) {
                $grouped[$year][$month] = @()
                $monthStats[$monthKey] = @{ success = 0; failed = 0; durations = @() }
            }

            if ($row.status -eq 'COMPLETED') {
                $monthStats[$monthKey].success++
                if ($row.total_duration_seconds -isnot [DBNull]) {
                    $monthStats[$monthKey].durations += $row.total_duration_seconds
                }
            }
            else {
                $monthStats[$monthKey].failed++
            }

            $sparkWidth = 0
            if ($row.total_duration_seconds -isnot [DBNull] -and $maxDurationSeconds -gt 0) {
                $sparkWidth = [int]([math]::Round(($row.total_duration_seconds / $maxDurationSeconds) * 100))
            }

            $grouped[$year][$month] += @{
                build_id                 = $row.build_id
                build_date               = ([DateTime]$row.build_date).ToString("yyyy-MM-dd")
                day_of_month             = ([DateTime]$row.build_date).Day
                day_name                 = ([DateTime]$row.build_date).ToString("ddd")
                job_name                 = ConvertTo-SafeValue $row.job_name
                instance_id              = ConvertTo-SafeValue $row.instance_id
                start_dttm               = if ($row.start_dttm -is [DBNull]) { $null } else { ([DateTime]$row.start_dttm).ToString("HH:mm") }
                end_dttm                 = if ($row.end_dttm -is [DBNull]) { $null } else { ([DateTime]$row.end_dttm).ToString("HH:mm") }
                total_duration_seconds   = ConvertTo-SafeValue $row.total_duration_seconds
                total_duration_formatted = ConvertTo-SafeValue $row.total_duration_formatted
                status                   = $row.status
                failed_step_name         = ConvertTo-SafeValue $row.failed_step_name
                spark_width              = $sparkWidth
            }
        }

        $monthSummaries = @{}
        foreach ($key in $monthStats.Keys) {
            $stats = $monthStats[$key]
            $avgDuration = $null
            if ($stats.durations.Count -gt 0) {
                $avgDuration = [int](($stats.durations | Measure-Object -Average).Average)
            }
            $monthSummaries[$key] = @{
                success_count          = $stats.success
                failed_count           = $stats.failed
                avg_duration_seconds   = $avgDuration
                avg_duration_formatted = if ($avgDuration) { $h = [int][Math]::Floor($avgDuration / 3600); $m = [int][Math]::Floor(($avgDuration % 3600) / 60); "{0}:{1:D2}" -f $h, $m } else { $null }
            }
        }

        Write-PodeJsonResponse -Value @{
            grouped              = $grouped
            month_summaries      = $monthSummaries
            max_duration_seconds = $maxDurationSeconds
            total_count          = $totalCount
            timestamp            = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/bidata/duration-trend' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $days = $WebEvent.Query['days']
        $fromDate = $WebEvent.Query['from']
        $toDate = $WebEvent.Query['to']

        # Custom date range when both from/to are supplied; otherwise a day count.
        if (-not [string]::IsNullOrEmpty($fromDate) -and -not [string]::IsNullOrEmpty($toDate)) {
            $rows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters @{ fromDate = $fromDate; toDate = $toDate }
        }
        else {
            if ([string]::IsNullOrEmpty($days) -or $days -eq 'all') {
                $days = 9999
            }
            $rows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters @{ days = [int]$days }
        }

        # Aggregate attempts by day.
        $dayData = @{}
        foreach ($row in $rows) {
            $dateKey = ([DateTime]$row.build_date).ToString("yyyy-MM-dd")

            if (-not $dayData.ContainsKey($dateKey)) {
                $dayData[$dateKey] = @{
                    date        = $dateKey
                    date_short  = ([DateTime]$row.build_date).ToString("M/d")
                    attempts    = @()
                    first_start = $null
                    last_end    = $null
                    has_success = $false
                }
            }

            $startDttm   = if ($row.start_dttm -is [DBNull]) { $null } else { [DateTime]$row.start_dttm }
            $endDttm     = if ($row.end_dttm -is [DBNull]) { $null } else { [DateTime]$row.end_dttm }
            $durationSec = if ($row.total_duration_seconds -is [DBNull]) { 0 } else { $row.total_duration_seconds }

            $dayData[$dateKey].attempts += @{
                start_dttm       = $startDttm
                end_dttm         = $endDttm
                duration_seconds = $durationSec
                status           = $row.status
            }

            if ($row.status -eq 'COMPLETED') {
                $dayData[$dateKey].has_success = $true
            }

            if ($startDttm -and (-not $dayData[$dateKey].first_start -or $startDttm -lt $dayData[$dateKey].first_start)) {
                $dayData[$dateKey].first_start = $startDttm
            }
            if ($endDttm -and (-not $dayData[$dateKey].last_end -or $endDttm -gt $dayData[$dateKey].last_end)) {
                $dayData[$dateKey].last_end = $endDttm
            }
        }

        # Build data points with execution/gap segments for stacked bars.
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

            $prevEnd = $null
            foreach ($attempt in $day.attempts) {
                if ($prevEnd -and $attempt.start_dttm) {
                    $gapSeconds = [int]($attempt.start_dttm - $prevEnd).TotalSeconds
                    if ($gapSeconds -gt 0) {
                        $segments += @{ type = 'gap'; seconds = $gapSeconds }
                        $totalGapSeconds += $gapSeconds
                    }
                }

                $segments += @{
                    type    = if ($attempt.status -eq 'COMPLETED') { 'success' } else { 'failed' }
                    seconds = $attempt.duration_seconds
                }
                $totalExecutionSeconds += $attempt.duration_seconds

                $prevEnd = $attempt.end_dttm
            }

            $dataPoints += @{
                date                     = $day.date
                date_short               = $day.date_short
                segments                 = $segments
                total_execution_seconds  = $totalExecutionSeconds
                total_gap_seconds        = $totalGapSeconds
                total_wall_clock_seconds = $totalWallClockSeconds
                attempt_count            = $day.attempts.Count
                has_success              = $day.has_success
                final_status             = if ($day.has_success) { 'COMPLETED' } else { 'FAILED' }
                duration_seconds         = if ($totalWallClockSeconds -gt 0) { $totalWallClockSeconds } else { $totalExecutionSeconds }
            }
        }

        # Stats from execution time on successful days.
        $completedDays = $dataPoints | Where-Object { $_.has_success }
        $executionDurations = $completedDays | ForEach-Object { $_.total_execution_seconds }
        $avgSeconds = if ($executionDurations.Count -gt 0) { [int]($executionDurations | Measure-Object -Average).Average } else { $null }
        $minSeconds = if ($executionDurations.Count -gt 0) { ($executionDurations | Measure-Object -Minimum).Minimum } else { $null }
        $maxSeconds = if ($executionDurations.Count -gt 0) { ($executionDurations | Measure-Object -Maximum).Maximum } else { $null }

        Write-PodeJsonResponse -Value @{
            data_points = $dataPoints
            stats       = @{
                avg_seconds   = $avgSeconds
                min_seconds   = $minSeconds
                max_seconds   = $maxSeconds
                avg_formatted = if ($avgSeconds) { "{0}:{1:D2}:{2:D2}" -f [int]($avgSeconds / 3600), [int](($avgSeconds % 3600) / 60), [int]($avgSeconds % 60) } else { $null }
                count         = $dataPoints.Count
            }
            timestamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/bidata/build-details' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $buildId = $WebEvent.Query['build_id']

        if ([string]::IsNullOrEmpty($buildId)) {
            Write-PodeJsonResponse -Value @{ error = "build_id is required" } -StatusCode 400
            return
        }

        $buildRows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters @{ build_id = [int]$buildId }

        if (-not $buildRows -or $buildRows.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = "Build not found" } -StatusCode 404
            return
        }

        $row = $buildRows[0]
        $build = @{
            build_id                 = $row.build_id
            build_date               = ([DateTime]$row.build_date).ToString("yyyy-MM-dd")
            job_name                 = ConvertTo-SafeValue $row.job_name
            instance_id              = ConvertTo-SafeValue $row.instance_id
            start_dttm               = ConvertTo-SafeDateTime $row.start_dttm
            end_dttm                 = ConvertTo-SafeDateTime $row.end_dttm
            total_duration_seconds   = ConvertTo-SafeValue $row.total_duration_seconds
            total_duration_formatted = ConvertTo-SafeValue $row.total_duration_formatted
            step_count               = if ($row.step_count -is [DBNull]) { 0 } else { $row.step_count }
            status                   = $row.status
            failed_step_id           = ConvertTo-SafeValue $row.failed_step_id
            failed_step_name         = ConvertTo-SafeValue $row.failed_step_name
            notified_dttm            = ConvertTo-SafeDateTime $row.notified_dttm
        }

        $stepRows = Invoke-XFActsQuery -Query @"
SELECT
    step_id,
    step_name,
    run_status,
    duration_seconds,
    duration_formatted
FROM BIDATA.StepExecution
WHERE build_id = @build_id
ORDER BY step_id
"@ -Parameters @{ build_id = [int]$buildId }

        $steps = @()
        foreach ($stepRow in $stepRows) {
            $steps += @{
                step_id            = $stepRow.step_id
                step_name          = $stepRow.step_name
                run_status         = $stepRow.run_status
                duration_seconds   = $stepRow.duration_seconds
                duration_formatted = $stepRow.duration_formatted
            }
        }

        Write-PodeJsonResponse -Value @{
            build     = $build
            steps     = $steps
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

Add-PodeRoute -Method Get -Path '/api/bidata/builds-for-date' -Authentication 'ADLogin' -ScriptBlock {
    if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }
    try {
        $dateStr = $WebEvent.Query['date']

        if ([string]::IsNullOrEmpty($dateStr)) {
            Write-PodeJsonResponse -Value @{ error = "date is required (YYYY-MM-DD)" } -StatusCode 400
            return
        }

        $buildRows = Invoke-XFActsQuery -Query @"
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
"@ -Parameters @{ build_date = $dateStr }

        if (-not $buildRows -or $buildRows.Count -eq 0) {
            Write-PodeJsonResponse -Value @{ error = "No builds found for date: $dateStr" } -StatusCode 404
            return
        }

        $builds = @()
        foreach ($row in $buildRows) {
            $buildId = $row.build_id

            $build = @{
                build_id                 = $buildId
                build_date               = ([DateTime]$row.build_date).ToString("yyyy-MM-dd")
                job_name                 = ConvertTo-SafeValue $row.job_name
                instance_id              = ConvertTo-SafeValue $row.instance_id
                start_dttm               = ConvertTo-SafeDateTime $row.start_dttm
                end_dttm                 = ConvertTo-SafeDateTime $row.end_dttm
                total_duration_seconds   = ConvertTo-SafeValue $row.total_duration_seconds
                total_duration_formatted = ConvertTo-SafeValue $row.total_duration_formatted
                step_count               = if ($row.step_count -is [DBNull]) { 0 } else { $row.step_count }
                status                   = $row.status
                failed_step_id           = ConvertTo-SafeValue $row.failed_step_id
                failed_step_name         = ConvertTo-SafeValue $row.failed_step_name
            }

            $stepRows = Invoke-XFActsQuery -Query @"
SELECT
    step_id,
    step_name,
    run_status,
    duration_seconds,
    duration_formatted
FROM BIDATA.StepExecution
WHERE build_id = @build_id
ORDER BY step_id
"@ -Parameters @{ build_id = [int]$buildId }

            $steps = @()
            foreach ($stepRow in $stepRows) {
                $steps += @{
                    step_id            = $stepRow.step_id
                    step_name          = $stepRow.step_name
                    run_status         = $stepRow.run_status
                    duration_seconds   = $stepRow.duration_seconds
                    duration_formatted = $stepRow.duration_formatted
                }
            }

            $builds += @{
                build = $build
                steps = $steps
            }
        }

        Write-PodeJsonResponse -Value @{
            date        = $dateStr
            builds      = $builds
            build_count = $builds.Count
            timestamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}
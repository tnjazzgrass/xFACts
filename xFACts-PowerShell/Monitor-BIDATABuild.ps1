<#
.SYNOPSIS
    xFACts - BIDATA Daily Build Monitor

.DESCRIPTION
    xFACts - BIDATA
    Script: Monitor-BIDATABuild.ps1
    Version: Tracked in dbo.System_Metadata (component: BIDATA)

    Monitors the BIDATA Daily Build SQL Agent job, capturing execution progress 
    in real-time and sending Teams notifications on completion, failure, or 
    when the build fails to start.
    
    Key behaviors:
    - Detects build start and creates BuildExecution record (IN_PROGRESS)
    - Captures step completions incrementally as they occur
    - Updates status to COMPLETED or FAILED when build finishes
    - Alerts if build hasn't started within grace period of scheduled time
    - Supports multiple execution attempts per day (each gets own record)
    - Uses instance_id for deduplication to prevent duplicate alerts
    - Configuration driven via GlobalConfig table

    CHANGELOG
    ---------
    2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-xFACtsData, Invoke-xFACtsNonQuery
                Renamed $xFACtsServer/$xFACtsDB to $ServerInstance/$Database
                Updated header to component-level versioning format
    2026-02-03  Orchestrator v2 integration
                Added -TaskId, -ProcessId parameters and callbacks
                Relocated to E:\xFACts-PowerShell on FA-SQLDBB
    2026-01-29  Fixed execution grouping logic
                Single execution per day using MIN instance_id
    2026-01-28  Initial implementation
                Real-time step capture, NOT_STARTED alerting
                Multi-attempt support, instance_id deduplication
                GlobalConfig-driven configuration
                Replaces BIDATA.sp_BuildMonitor

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER SourceServer
    SQL Server instance where BIDATA Daily Build runs (default: DM-PROD-REP)

.PARAMETER TestDate
    Override date for testing against historical data (format: yyyy-MM-dd)

.PARAMETER TestTime
    Override time for testing NOT_STARTED logic (format: HH:mm)

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. This is deployed in an Availability Group - ensure this script is placed 
   on both servers in the appropriate folder.
2. The SQL Agent service account must have read access to msdb on the source
   server (configured via GlobalConfig bidata_build_source_server).
3. This script replaces BIDATA.sp_BuildMonitor - disable the ProcessRegistry 
   entry after deployment.
4. Required GlobalConfig entries:
   - bidata_build_job_name (default: BIDATA Daily Build)
   - bidata_build_source_server (default: DM-PROD-REP)
   - bidata_build_start_grace_minutes (default: 15)
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [string]$SourceServer = "DM-PROD-REP",
    [string]$TestDate = $null,
    [string]$TestTime = $null,
    [switch]$Execute,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Monitor-BIDATABuild' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# CONFIGURATION DEFAULTS (overridden by GlobalConfig)
# ============================================================================

$ConfigDefaults = @{
    JobName = "BIDATA Daily Build"
    SourceServer = "DM-PROD-REP"
    StartGraceMinutes = 15
    
    # Steps to exclude from notification (infrastructure steps)
    ExcludedStepIds = @(1, 2, 17, 18, 19, 20)
}

# ============================================================================
# FUNCTIONS
# ============================================================================

function Get-SourceData {
    param(
        [string]$ServerInstance,
        [string]$Query,
        [int]$Timeout = 30
    )
    try {
        Invoke-Sqlcmd -ServerInstance $ServerInstance -Database "msdb" -Query $Query -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName -ErrorAction Stop -TrustServerCertificate
    }
    catch {
        Write-Log "Source server query failed: $($_.Exception.Message)" "ERROR"
        $Script:SourceQueryFailed = $true
        return $null
    }
}

function Get-GlobalConfig {
    <#
    .SYNOPSIS
        Retrieves configuration values from GlobalConfig table
    #>
    param([string[]]$Keys)
    
    $keyList = ($Keys | ForEach-Object { "'$_'" }) -join ","
    
    $query = @"
        SELECT setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE setting_name IN ($keyList)
          AND is_active = 1
"@
    
    $results = Get-SqlData -Query $query
    
    $config = @{}
    if ($results) {
        foreach ($row in $results) {
            $config[$row.setting_name] = $row.setting_value
        }
    }
    
    return $config
}

function ConvertFrom-AgentDuration {
    <#
    .SYNOPSIS
        Converts SQL Agent duration (HHMMSS integer) to seconds and formatted string
    #>
    param([int]$Duration)
    
    $hours = [int][math]::Floor($Duration / 10000)
    $minutes = [int][math]::Floor(($Duration % 10000) / 100)
    $seconds = [int]($Duration % 100)
    
    $totalSeconds = ($hours * 3600) + ($minutes * 60) + $seconds
    $formatted = "{0:D2}:{1:D2}:{2:D2}" -f $hours, $minutes, $seconds
    
    return @{
        TotalSeconds = $totalSeconds
        Formatted = $formatted
    }
}

function ConvertFrom-AgentDateTime {
    <#
    .SYNOPSIS
        Converts SQL Agent run_date (YYYYMMDD) and run_time (HHMMSS) to DateTime
    #>
    param(
        [int]$RunDate,
        [int]$RunTime
    )
    
    $dateStr = $RunDate.ToString()
    $timeStr = $RunTime.ToString().PadLeft(6, '0')
    
    $year = [int]$dateStr.Substring(0, 4)
    $month = [int]$dateStr.Substring(4, 2)
    $day = [int]$dateStr.Substring(6, 2)
    
    $hour = [int]$timeStr.Substring(0, 2)
    $minute = [int]$timeStr.Substring(2, 2)
    $second = [int]$timeStr.Substring(4, 2)
    
    return Get-Date -Year $year -Month $month -Day $day -Hour $hour -Minute $minute -Second $second
}

function ConvertFrom-AgentTime {
    <#
    .SYNOPSIS
        Converts SQL Agent active_start_time (HHMMSS integer) to TimeSpan
    #>
    param([int]$Time)
    
    $timeStr = $Time.ToString().PadLeft(6, '0')
    
    $hour = [int]$timeStr.Substring(0, 2)
    $minute = [int]$timeStr.Substring(2, 2)
    $second = [int]$timeStr.Substring(4, 2)
    
    return New-TimeSpan -Hours $hour -Minutes $minute -Seconds $second
}

function Get-JobScheduledTime {
    <#
    .SYNOPSIS
        Retrieves the scheduled start time for a SQL Agent job
    #>
    param(
        [string]$ServerInstance,
        [string]$JobName
    )
    
    $query = @"
        SELECT TOP 1 s.active_start_time
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
        INNER JOIN msdb.dbo.sysschedules s ON js.schedule_id = s.schedule_id
        WHERE j.name = '$JobName'
          AND s.enabled = 1
        ORDER BY s.active_start_time
"@
    
    $result = Get-SourceData -ServerInstance $ServerInstance -Query $query
    
    if ($result) {
        return ConvertFrom-AgentTime -Time $result.active_start_time
    }
    
    return $null
}

function Get-ExistingBuilds {
    <#
    .SYNOPSIS
        Retrieves all build records for a specific date (supports multiple attempts)
    #>
    param([DateTime]$BuildDate)
    
    $dateStr = $BuildDate.ToString("yyyy-MM-dd")
    
    $query = @"
        SELECT 
            build_id, build_date, instance_id, start_dttm, end_dttm,
            total_duration_seconds, total_duration_formatted,
            step_count, status, run_status, notified_dttm,
            failed_step_id, failed_step_name
        FROM BIDATA.BuildExecution
        WHERE build_date = '$dateStr'
        ORDER BY build_id
"@
    
    return Get-SqlData -Query $query
}

function Get-CapturedSteps {
    <#
    .SYNOPSIS
        Retrieves steps already captured for a build
    #>
    param([int]$BuildId)
    
    $query = @"
        SELECT step_id, step_name, run_status, duration_seconds
        FROM BIDATA.StepExecution
        WHERE build_id = $BuildId
        ORDER BY step_id
"@
    
    return Get-SqlData -Query $query
}

function Get-JobHistory {
    <#
    .SYNOPSIS
        Retrieves job history from source server for the specified date
    #>
    param(
        [string]$ServerInstance,
        [DateTime]$BuildDate,
        [string]$JobName
    )
    
    $runDateInt = [int]$BuildDate.ToString("yyyyMMdd")
    
    $query = @"
        SELECT 
            h.instance_id,
            h.step_id,
            h.step_name,
            h.run_status,
            h.run_date,
            h.run_time,
            h.run_duration
        FROM msdb.dbo.sysjobhistory h
        INNER JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
        WHERE j.name = '$JobName'
          AND h.run_date = $runDateInt
        ORDER BY h.instance_id, h.step_id
"@
    
    return Get-SourceData -ServerInstance $ServerInstance -Query $query
}

function Get-AverageStepDurations {
    <#
    .SYNOPSIS
        Retrieves average step durations from recent successful builds for ETA calculation
    #>
    param([int]$DaysBack = 14)
    
    $query = @"
        SELECT 
            s.step_id,
            s.step_name,
            AVG(s.duration_seconds) AS avg_seconds
        FROM BIDATA.StepExecution s
        INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
        WHERE b.build_date >= DATEADD(DAY, -$DaysBack, GETDATE())
          AND b.status = 'COMPLETED'
          AND s.run_status = 1
        GROUP BY s.step_id, s.step_name
"@
    
    return Get-SqlData -Query $query
}

function Send-BuildNotification {
    <#
    .SYNOPSIS
        Queues a Teams notification for build events
    #>
    param(
        [string]$Status,           # COMPLETED, FAILED, or NOT_STARTED
        [DateTime]$EventTime,
        [string]$Duration,
        [string]$StepDetails,
        [string]$FailedStepName,
        [DateTime]$BuildDate,
        [string]$TriggerValue      # For deduplication: STATUS-instance_id or NOT_STARTED-date
    )
    
    switch ($Status) {
        "COMPLETED" {
            $title = "BIDATA Daily Build Complete"
            $category = "INFO"
            $message = "Completed: " + $EventTime.ToString("h:mm tt") + "`n" +
                       "Total Duration: $Duration`n`n" +
                       $StepDetails
        }
        "FAILED" {
            $title = "BIDATA Daily Build FAILED"
            $category = "ERROR"
            $message = "Failed at: " + $EventTime.ToString("h:mm tt") + "`n" +
                       "Failed Step: $FailedStepName`n" +
                       "Duration before failure: $Duration"
        }
        "NOT_STARTED" {
            $title = "BIDATA Daily Build Has Not Started"
            $category = "ERROR"
            $message = "The BIDATA Daily Build has not started.`n" +
                       "Expected start time has passed.`n" +
                       "Please investigate immediately - this affects reporting availability."
        }
    }
    
    # Escape single quotes for SQL
    $titleSafe = $title -replace "'", "''"
    $messageSafe = $message -replace "'", "''"
    
    $query = @"
        EXEC Teams.sp_QueueAlert
            @SourceModule = 'BIDATA',
            @AlertCategory = '$category',
            @Title = '$titleSafe',
            @Message = '$messageSafe',
            @TriggerType = 'BuildStatus',
            @TriggerValue = '$TriggerValue'
"@
    
    return Invoke-SqlNonQuery -Query $query
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  xFACts BIDATA Build Monitor v1.2.0" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$scriptStart = Get-Date

# ----------------------------------------
# Step 1: Load configuration from GlobalConfig
# ----------------------------------------
Write-Log "Loading configuration..."

$globalConfig = Get-GlobalConfig -Keys @(
    'bidata_build_job_name',
    'bidata_build_source_server',
    'bidata_build_start_grace_minutes'
)

$Config = @{
    JobName = if ($globalConfig['bidata_build_job_name']) { $globalConfig['bidata_build_job_name'] } else { $ConfigDefaults.JobName }
    SourceServer = if ($globalConfig['bidata_build_source_server']) { $globalConfig['bidata_build_source_server'] } else { $ConfigDefaults.SourceServer }
    StartGraceMinutes = if ($globalConfig['bidata_build_start_grace_minutes']) { [int]$globalConfig['bidata_build_start_grace_minutes'] } else { $ConfigDefaults.StartGraceMinutes }
    ExcludedStepIds = $ConfigDefaults.ExcludedStepIds
}

# Allow command-line override of source server
if ($SourceServer -ne "DM-PROD-REP") {
    $Config.SourceServer = $SourceServer
}

Write-Log "  Job Name: $($Config.JobName)"
Write-Log "  Source Server: $($Config.SourceServer)"
Write-Log "  Start Grace Minutes: $($Config.StartGraceMinutes)"

# ----------------------------------------
# Step 2: Determine target date/time
# ----------------------------------------

if ($TestDate) {
    try {
        $targetDate = [DateTime]::ParseExact($TestDate, "yyyy-MM-dd", $null)
        Write-Log "TEST MODE: Monitoring for date $TestDate" "WARN"
    }
    catch {
        Write-Log "Invalid TestDate format. Use yyyy-MM-dd" "ERROR"
        exit 1
    }
}
else {
    $targetDate = (Get-Date).Date
    Write-Log "Monitoring for today: $($targetDate.ToString('yyyy-MM-dd'))"
}

if ($TestTime) {
    try {
        $timeParts = $TestTime.Split(':')
        $currentTime = Get-Date -Year $targetDate.Year -Month $targetDate.Month -Day $targetDate.Day -Hour $timeParts[0] -Minute $timeParts[1] -Second 0
        Write-Log "TEST MODE: Using time $TestTime" "WARN"
    }
    catch {
        Write-Log "Invalid TestTime format. Use HH:mm" "ERROR"
        exit 1
    }
}
else {
    $currentTime = Get-Date
}

# ----------------------------------------
# Step 3: Check existing build records for today
# ----------------------------------------
Write-Log "Checking existing build records..."

$existingBuilds = Get-ExistingBuilds -BuildDate $targetDate

# Build a hashtable of instance_ids we've already processed
$processedInstances = @{}
$notStartedRecord = $null

if ($existingBuilds) {
    foreach ($build in @($existingBuilds)) {
        if ($build.status -eq "NOT_STARTED") {
            $notStartedRecord = $build
        }
        elseif ($build.instance_id -isnot [DBNull]) {
            $processedInstances[[int]$build.instance_id] = $build
        }
    }
    
    Write-Log "  Found $(@($existingBuilds).Count) existing record(s)"
    Write-Log "  Processed instance_ids: $($processedInstances.Keys -join ', ')"
    
    # Early exit if today's build is already completed and notified
    $completedBuild = @($existingBuilds) | Where-Object { $_.status -eq 'COMPLETED' -and $_.notified_dttm -isnot [DBNull] } | Select-Object -First 1
    if ($completedBuild) {
        Write-Log "  Build already COMPLETED and notified (Build ID: $($completedBuild.build_id)). Nothing to do."
        if ($TaskId -gt 0) {
            $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs $totalMs `
                -Output "Build already COMPLETED - Date: $($targetDate.ToString('yyyy-MM-dd'))"
        }
        exit 0
    }
}
else {
    Write-Log "  No existing records for today"
}

# ----------------------------------------
# Step 4: Query source server for job history
# ----------------------------------------
Write-Log "Querying job history from $($Config.SourceServer)..."

$Script:SourceQueryFailed = $false
$jobHistory = Get-JobHistory -ServerInstance $Config.SourceServer -BuildDate $targetDate -JobName $Config.JobName

if ($Script:SourceQueryFailed) {
    Write-Log "  Source server query failed — cannot determine build state. Skipping cycle." "WARN"
    if ($TaskId -gt 0) {
        $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "WARN" -DurationMs $totalMs `
            -Output "Source query failed - Date: $($targetDate.ToString('yyyy-MM-dd'))"
    }
    exit 0
}

if ($null -eq $jobHistory -or @($jobHistory).Count -eq 0) {
    Write-Log "  No job history found for today" "WARN"
    
    # Check if we should alert about NOT_STARTED
    $scheduledTime = Get-JobScheduledTime -ServerInstance $Config.SourceServer -JobName $Config.JobName
    
    if ($scheduledTime) {
        $scheduledDateTime = $targetDate.Add($scheduledTime)
        $graceDeadline = $scheduledDateTime.AddMinutes($Config.StartGraceMinutes)
        
        Write-Log "  Scheduled start: $($scheduledDateTime.ToString('HH:mm'))"
        Write-Log "  Grace deadline: $($graceDeadline.ToString('HH:mm'))"
        Write-Log "  Current time: $($currentTime.ToString('HH:mm'))"
        
        if ($currentTime -gt $graceDeadline) {
            # Past grace period - need to alert
            Write-Log "  Build has not started and grace period has passed!" "ERROR"
            
            # Check if we already have a NOT_STARTED record with notification
            $alreadyNotified = $notStartedRecord -and $notStartedRecord.notified_dttm -isnot [DBNull]
            
            if (-not $alreadyNotified) {
                $triggerValue = "NOT_STARTED-$($targetDate.ToString('yyyy-MM-dd'))"
                
                if ($Execute) {
                    # Create NOT_STARTED record if it doesn't exist
                    if (-not $notStartedRecord) {
                        Write-Log "Creating NOT_STARTED record..."
                        
                        $insertQuery = @"
                            INSERT INTO BIDATA.BuildExecution (
                                build_date, job_name, status, is_backfill
                            )
                            VALUES (
                                '$($targetDate.ToString('yyyy-MM-dd'))',
                                '$($Config.JobName)',
                                'NOT_STARTED',
                                0
                            );
                            SELECT SCOPE_IDENTITY() AS build_id;
"@
                        
                        $result = Get-SqlData -Query $insertQuery
                        if ($result) {
                            $notStartedBuildId = $result.build_id
                            Write-Log "  Created Build ID: $notStartedBuildId" "SUCCESS"
                        }
                    }
                    else {
                        $notStartedBuildId = $notStartedRecord.build_id
                    }
                    
                    # Send notification
                    Write-Log "Sending NOT_STARTED notification..."
                    $notifyResult = Send-BuildNotification `
                        -Status "NOT_STARTED" `
                        -EventTime $currentTime `
                        -BuildDate $targetDate `
                        -TriggerValue $triggerValue
                    
                    if ($notifyResult) {
                        Write-Log "  Notification queued" "SUCCESS"
                        
                        # Mark as notified
                        $markNotifiedQuery = "UPDATE BIDATA.BuildExecution SET notified_dttm = GETDATE() WHERE build_id = $notStartedBuildId"
                        Invoke-SqlNonQuery -Query $markNotifiedQuery | Out-Null
                    }
                    else {
                        Write-Log "  Failed to queue notification" "ERROR"
                    }
                }
                else {
                    Write-Log "PREVIEW: Would create NOT_STARTED record and send alert" "WARN"
                }
            }
            else {
                Write-Log "  NOT_STARTED alert already sent"
            }
        }
        else {
            Write-Log "  Still within grace period - no alert needed"
        }
    }
        else {
                Write-Log "  Could not determine scheduled start time" "WARN"
            }
    
            Write-Host ""
            if ($TaskId -gt 0) {
                $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
                Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                    -TaskId $TaskId -ProcessId $ProcessId `
                    -Status "NOT_STARTED" -DurationMs $totalMs `
                    -Output "Build not started yet - Date: $($targetDate.ToString('yyyy-MM-dd'))"
            }
            exit 1
        }

$historyCount = @($jobHistory).Count
Write-Log "  Found $historyCount history record(s)"

# ----------------------------------------
# Step 5: Group history as single execution per day
# ----------------------------------------
Write-Log "Analyzing execution attempts..."

# Separate job outcome (step_id = 0) from individual steps
$jobOutcome = $jobHistory | Where-Object { $_.step_id -eq 0 } | Select-Object -First 1
$stepHistory = $jobHistory | Where-Object { $_.step_id -gt 0 }

# Always use MIN from steps (stable throughout build), fall back to job outcome only if no steps
$instanceId = if ($stepHistory -and @($stepHistory).Count -gt 0) { 
    [int]($stepHistory | Measure-Object -Property instance_id -Minimum).Minimum 
} elseif ($jobOutcome) {
    [int]$jobOutcome.instance_id 
} else {
    $null
}

Write-Log "  Using instance_id: $instanceId"

# Build single execution attempt (no loop needed for single-run-per-day)
$executionAttempts = @{ $instanceId = $jobHistory }

Write-Log "  Found 1 execution attempt"

# ----------------------------------------
# Step 6: Process each execution attempt
# ----------------------------------------

foreach ($instanceId in ($executionAttempts.Keys | Sort-Object)) {
    $attemptRecords = $executionAttempts[$instanceId]
    
    Write-Log "Processing instance_id $instanceId..."
    
    # Check if this instance is already fully processed and notified
    if ($processedInstances.ContainsKey($instanceId)) {
        $existingRecord = $processedInstances[$instanceId]
        if ($existingRecord.status -in @("COMPLETED", "FAILED") -and $existingRecord.notified_dttm -isnot [DBNull]) {
            Write-Log "  Already completed and notified. Skipping."
            continue
        }
    }
    
    # Separate job outcome (step_id = 0) from individual steps  
    $jobOutcome = $attemptRecords | Where-Object { $_.step_id -eq 0 } | Select-Object -First 1
    $stepHistory = $attemptRecords | Where-Object { $_.step_id -gt 0 }
    
    # Determine build state for this attempt
    $buildStarted = @($stepHistory).Count -gt 0
    $buildCompleted = $null -ne $jobOutcome -and $jobOutcome.run_status -eq 1
    $buildFailed = $null -ne $jobOutcome -and $jobOutcome.run_status -eq 0
    
    if (-not $buildStarted) {
        Write-Log "  No steps recorded yet for this instance"
        continue
    }
    
    $finalStatus = if ($buildCompleted) { "COMPLETED" } elseif ($buildFailed) { "FAILED" } else { "IN_PROGRESS" }
    Write-Log "  Status: $finalStatus"
    
    # Calculate timing
    $firstStep = $stepHistory | Sort-Object run_time | Select-Object -First 1
    $startDttm = ConvertFrom-AgentDateTime -RunDate $firstStep.run_date -RunTime $firstStep.run_time
    
    Write-Log "  Started: $($startDttm.ToString('yyyy-MM-dd HH:mm:ss'))"
    
    if ($jobOutcome) {
        $durationInfo = ConvertFrom-AgentDuration -Duration $jobOutcome.run_duration
        $endDttm = $startDttm.AddSeconds($durationInfo.TotalSeconds)
        $totalDurationSeconds = $durationInfo.TotalSeconds
        $totalDurationFormatted = $durationInfo.Formatted
        
        Write-Log "  Ended: $($endDttm.ToString('yyyy-MM-dd HH:mm:ss'))"
        Write-Log "  Duration: $totalDurationFormatted"
    }
    else {
        $endDttm = $null
        $elapsed = $currentTime - $startDttm
        $totalDurationSeconds = [int]$elapsed.TotalSeconds
        $totalDurationFormatted = "{0:D2}:{1:D2}:{2:D2}" -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
        
        Write-Log "  Elapsed: $totalDurationFormatted"
    }
    
    # Identify failed step if applicable
    $failedStepId = $null
    $failedStepName = $null
    
    if ($buildFailed) {
        $failedStep = $stepHistory | Where-Object { $_.run_status -eq 0 } | Select-Object -First 1
        if ($failedStep) {
            $failedStepId = $failedStep.step_id
            $failedStepName = $failedStep.step_name
            Write-Log "  Failed step: [$failedStepId] $failedStepName" "ERROR"
        }
    }
    
    # ----------------------------------------
    # Create or update BuildExecution record
    # ----------------------------------------
    
    $buildId = $null
    $existingRecord = if ($processedInstances.ContainsKey($instanceId)) { $processedInstances[$instanceId] } else { $null }
    
    if ($Execute) {
        if ($null -eq $existingRecord) {
            # Insert new record
            Write-Log "  Creating BuildExecution record..."
            
            $endDttmSql = if ($endDttm) { "'$($endDttm.ToString('yyyy-MM-dd HH:mm:ss'))'" } else { "NULL" }
            $failedStepIdSql = if ($failedStepId) { $failedStepId } else { "NULL" }
            $failedStepNameSql = if ($failedStepName) { "'$($failedStepName -replace "'", "''")'" } else { "NULL" }
            $runStatus = if ($buildCompleted) { 1 } elseif ($buildFailed) { 0 } else { "NULL" }
            
            $insertQuery = @"
                INSERT INTO BIDATA.BuildExecution (
                    build_date, job_name, instance_id, start_dttm, end_dttm,
                    total_duration_seconds, total_duration_formatted,
                    status, run_status, failed_step_id, failed_step_name, is_backfill
                )
                VALUES (
                    '$($targetDate.ToString('yyyy-MM-dd'))', 
                    '$($Config.JobName)', 
                    $instanceId,
                    '$($startDttm.ToString('yyyy-MM-dd HH:mm:ss'))',
                    $endDttmSql,
                    $totalDurationSeconds,
                    '$totalDurationFormatted',
                    '$finalStatus',
                    $runStatus,
                    $failedStepIdSql,
                    $failedStepNameSql,
                    0
                );
                SELECT SCOPE_IDENTITY() AS build_id;
"@
            
            $result = Get-SqlData -Query $insertQuery
            if ($result) {
                $buildId = $result.build_id
                Write-Log "    Created Build ID: $buildId" "SUCCESS"
            }
            else {
                Write-Log "    Failed to create BuildExecution record" "ERROR"
                continue
            }
        }
        else {
            # Update existing record
            $buildId = $existingRecord.build_id
            Write-Log "  Updating BuildExecution record (Build ID: $buildId)..."
            
            $endDttmSql = if ($endDttm) { "'$($endDttm.ToString('yyyy-MM-dd HH:mm:ss'))'" } else { "NULL" }
            $failedStepIdSql = if ($failedStepId) { $failedStepId } else { "NULL" }
            $failedStepNameSql = if ($failedStepName) { "'$($failedStepName -replace "'", "''")'" } else { "NULL" }
            $runStatus = if ($buildCompleted) { 1 } elseif ($buildFailed) { 0 } else { "NULL" }
            
            $updateQuery = @"
                UPDATE BIDATA.BuildExecution
                SET end_dttm = $endDttmSql,
                    total_duration_seconds = $totalDurationSeconds,
                    total_duration_formatted = '$totalDurationFormatted',
                    status = '$finalStatus',
                    run_status = $runStatus,
                    failed_step_id = $failedStepIdSql,
                    failed_step_name = $failedStepNameSql
                WHERE build_id = $buildId
"@
            
            $result = Invoke-SqlNonQuery -Query $updateQuery
            if ($result) {
                Write-Log "    Updated successfully" "SUCCESS"
            }
        }
        
        # If we had a NOT_STARTED record and build has now started, update it
        if ($notStartedRecord -and -not $processedInstances.ContainsKey($instanceId)) {
            Write-Log "  Updating NOT_STARTED record - build has started"
            $updateNotStartedQuery = @"
                UPDATE BIDATA.BuildExecution
                SET status = 'SUPERSEDED',
                    instance_id = $instanceId
                WHERE build_id = $($notStartedRecord.build_id)
                  AND status = 'NOT_STARTED'
"@
            Invoke-SqlNonQuery -Query $updateNotStartedQuery | Out-Null
        }
    }
    else {
        Write-Log "  PREVIEW: Would create/update BuildExecution with status '$finalStatus'" "WARN"
        $buildId = -1
    }
    
    # ----------------------------------------
    # Capture step execution details
    # ----------------------------------------
    Write-Log "  Processing step execution details..."
    
    # Get already captured steps (if any)
    $capturedSteps = @()
    if ($buildId -gt 0) {
        $captured = Get-CapturedSteps -BuildId $buildId
        if ($captured) {
            $capturedSteps = @($captured | ForEach-Object { $_.step_id })
        }
    }
    
    Write-Log "    Already captured: $($capturedSteps.Count) steps"
    
    # Process each step from history
    $newStepsAdded = 0
    $stepDetailsForNotification = @()
    
    foreach ($step in $stepHistory) {
        $stepId = $step.step_id
        $stepName = $step.step_name
        $stepRunStatus = $step.run_status
        $durationInfo = ConvertFrom-AgentDuration -Duration $step.run_duration
        
        # Skip if already captured
        if ($stepId -in $capturedSteps) {
            # Still add to notification details
            if ($stepId -notin $Config.ExcludedStepIds) {
                $stepDetailsForNotification += "$stepName`: $($durationInfo.Formatted)"
            }
            continue
        }
        
        # Build notification detail (exclude infrastructure steps)
        if ($stepId -notin $Config.ExcludedStepIds) {
            $stepDetailsForNotification += "$stepName`: $($durationInfo.Formatted)"
        }
        
        if ($Execute -and $buildId -gt 0) {
            $stepNameSafe = $stepName -replace "'", "''"
            
            $insertStepQuery = @"
                INSERT INTO BIDATA.StepExecution (
                    build_id, step_id, step_name, run_status, 
                    run_time, duration_seconds, duration_formatted
                )
                VALUES (
                    $buildId, $stepId, '$stepNameSafe', $stepRunStatus,
                    $($step.run_time), $($durationInfo.TotalSeconds), '$($durationInfo.Formatted)'
                )
"@
            
            $result = Invoke-SqlNonQuery -Query $insertStepQuery
            if ($result) {
                $newStepsAdded++
            }
        }
        else {
            $newStepsAdded++
        }
    }
    
    Write-Log "    New steps captured: $newStepsAdded"
    
    # Update step count
    if ($Execute -and $buildId -gt 0) {
        $updateCountQuery = @"
            UPDATE BIDATA.BuildExecution 
            SET step_count = (SELECT COUNT(*) FROM BIDATA.StepExecution WHERE build_id = $buildId)
            WHERE build_id = $buildId
"@
        Invoke-SqlNonQuery -Query $updateCountQuery | Out-Null
    }
    
    # ----------------------------------------
    # Send notification if build finished
    # ----------------------------------------
    
    if ($finalStatus -in @("COMPLETED", "FAILED")) {
        # Check if already notified for this specific instance
        $alreadyNotified = $existingRecord -and $existingRecord.notified_dttm -isnot [DBNull]
        
        if (-not $alreadyNotified) {
            Write-Log "  Sending Teams notification..."
            
            $stepDetailsText = $stepDetailsForNotification -join "`n"
            $triggerValue = "$finalStatus-$instanceId"
            
            if ($Execute) {
                $notifyResult = Send-BuildNotification `
                    -Status $finalStatus `
                    -EventTime $endDttm `
                    -Duration $totalDurationFormatted `
                    -StepDetails $stepDetailsText `
                    -FailedStepName $failedStepName `
                    -BuildDate $targetDate `
                    -TriggerValue $triggerValue
                
                if ($notifyResult) {
                    Write-Log "    Notification queued" "SUCCESS"
                    
                    # Mark as notified
                    $markNotifiedQuery = "UPDATE BIDATA.BuildExecution SET notified_dttm = GETDATE() WHERE build_id = $buildId"
                    Invoke-SqlNonQuery -Query $markNotifiedQuery | Out-Null
                }
                else {
                    Write-Log "    Failed to queue notification" "ERROR"
                }
            }
            else {
                Write-Log "  PREVIEW: Would send $finalStatus notification (trigger: $triggerValue)" "WARN"
            }
        }
        else {
            Write-Log "  Already notified for this instance"
        }
    }
}

# ----------------------------------------
# Summary
# ----------------------------------------

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Target Date:        $($targetDate.ToString('yyyy-MM-dd'))"
Write-Host "  Execution Attempts: $($executionAttempts.Count)"
Write-Host "  Script Duration:    $([int]$scriptDuration.TotalMilliseconds) ms"
Write-Host ""

if (-not $Execute) {
    Write-Host "  *** PREVIEW MODE - No changes were made ***" -ForegroundColor Yellow
    Write-Host "  Run with -Execute to perform actual updates" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Monitor Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------
# Orchestrator Callback
# ----------------------------------------
if ($TaskId -gt 0) {
    $totalMs = [int]$scriptDuration.TotalMilliseconds
    if ($finalStatus -eq "COMPLETED") {
        $taskStatus = "SUCCESS"
        $outputMsg = "Build COMPLETED - Date: $($targetDate.ToString('yyyy-MM-dd')), Attempts: $($executionAttempts.Count)"
    }
    else {
        $taskStatus = "POLLING"
        $outputMsg = "Build $finalStatus - Date: $($targetDate.ToString('yyyy-MM-dd')), Attempts: $($executionAttempts.Count)"
    }
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $taskStatus -DurationMs $totalMs `
        -Output $outputMsg
}

if ($finalStatus -eq "COMPLETED") {
    exit 0
}
else {
    exit 1
}
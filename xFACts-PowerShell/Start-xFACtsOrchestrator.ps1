<#
.SYNOPSIS
    xFACts Orchestrator Engine

.DESCRIPTION
    xFACts - Engine.Orchestrator
    Script: Start-xFACtsOrchestrator.ps1
    Version: Tracked in dbo.System_Metadata (component: Engine.Orchestrator)

    NSSM-hosted PowerShell service that manages execution of all xFACts 
    monitoring and processing scripts. Replaces the SQL Agent job and 
    sp_MasterOrchestrator with a dedicated engine providing per-process 
    scheduling, dependency group ordering, and comprehensive execution logging.

    Runs as a continuous service on FA-SQLDBB. Connects to the xFACts database
    on the AG listener for all configuration and logging operations.

    CHANGELOG
    ---------
    2026-03-11  Updated header to component-level versioning format
                Removed $scriptVersion variable and version from startup banner
    2026-02-27  Engine event scheduling metadata
                PROCESS_COMPLETED events now include interval_seconds,
                scheduled_time, and run_mode from ProcessRegistry
                Real-time engine event push via Send-EngineEvent
                Fire-and-forget POST to Control Center internal endpoint
    2026-02-10  Engine file logging
                Persistent file logging for ENGINE and ERROR level messages
                TASK level remains console-only (captured in TaskLog)
    2026-02-09  Drain mode startup alert
                Queues WARNING Teams alert if drain mode active on startup
    2026-02-07  WAIT mode timeout enforcement
                WaitForExit with timeout_seconds, process kill on expiry
                CRITICAL Teams alert on timeout via direct AlertQueue INSERT
                Bug fix: Queue-driven FIRE_AND_FORGET running_count reset
    2026-02-06  Bug fix: Excluded queue-driven processes from stale timeout check
    2026-02-05  Queue-driven processing support
                run_mode column replaces is_enabled (0/1/2)
                Secondary loop for queue-driven processes on running_count > 0
    2026-02-04  Concurrent execution support and drain mode
                running_count replaces is_running BIT flag
                Drain mode via GlobalConfig (orchestrator_drain_mode)
    2026-02-03  Initial implementation
                Heartbeat loop, ProcessRegistry scheduling, dependency groups
                WAIT and FIRE_AND_FORGET modes, overlap protection
                Graceful shutdown on NSSM stop signal

.PARAMETER ServerInstance
    SQL Server instance hosting the xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER ScriptRoot
    Root directory containing xFACts PowerShell scripts (default: E:\xFACts-Powershell)

.EXAMPLE
    # Run as NSSM service
    .\Start-xFACtsOrchestrator.ps1

.EXAMPLE
    # Run with custom connection
    .\Start-xFACtsOrchestrator.ps1 -ServerInstance "MYSERVER" -Database "xFACts"

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Install as NSSM service on FA-SQLDBB:
   nssm install xFACtsOrchestrator powershell.exe
   nssm set xFACtsOrchestrator AppParameters "-ExecutionPolicy Bypass -File E:\xFACts-PowerShell\Start-xFACtsOrchestrator.ps1"
   nssm set xFACtsOrchestrator AppDirectory E:\PowerShell
   nssm set xFACtsOrchestrator AppStopMethodSkip 6
   nssm set xFACtsOrchestrator AppStopMethodConsole 5000
   nssm set xFACtsOrchestrator AppStopMethodWindow 5000
   nssm set xFACtsOrchestrator AppStopMethodThreads 5000
2. Ensure the service account has SQL access to xFACts on AVG-PROD-LSNR
3. Ensure the service account can execute PowerShell scripts in E:\PowerShell
4. Add GlobalConfig entry for heartbeat interval before starting:
   INSERT INTO dbo.GlobalConfig (module_name, setting_name, setting_value, data_type, category, description)
   VALUES ('Orchestrator', 'heartbeat_interval_seconds', '60', 'INT', 'Engine', 
           'Seconds between orchestrator heartbeat cycles');
================================================================================
#>

param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [string]$ScriptRoot = "E:\xFACts-PowerShell"
)

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = "Continue"

# Shutdown flag - set by register-engineevent for graceful stop
$Script:ShutdownRequested = $false

# Default heartbeat interval (overridden by GlobalConfig)
$Script:HeartbeatSeconds = 60

# Drain mode - when true, engine skips new process launches
$Script:DrainMode = $false

# Ensure log directory exists
$logDir = "$PSScriptRoot\Logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Import-Module SQLPS -DisableNameChecking -ErrorAction Stop
} else {
    Import-Module SqlServer -ErrorAction Stop
}

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

# ============================================================================
# LOGGING
# ============================================================================

$EngineLogFile = "$PSScriptRoot\Logs\Orchestrator_Engine_$(Get-Date -Format 'yyyyMMdd').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","ENGINE","TASK","SUCCESS","DEBUG")]
        [string]$Level = "INFO",
        [switch]$Persist
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = switch ($Level) {
        "ENGINE"  { "[ENGINE]" }
        "TASK"    { "[TASK]  " }
        "WARN"    { "[WARN]  " }
        "ERROR"   { "[ERROR] " }
        "SUCCESS" { "[OK]    " }
        "DEBUG"   { "[DEBUG] " }
        default   { "[INFO]  " }
    }
    
    $line = "$timestamp $prefix $Message"
    Write-Host $line
    
    if ($Persist -or $Level -eq "ENGINE" -or $Level -eq "ERROR") {
        # Roll log file at midnight
        $currentLogFile = "$PSScriptRoot\Logs\Start-xFACtsOrchestrator_$(Get-Date -Format 'yyyyMMdd').log"
        Add-Content -Path $currentLogFile -Value $line -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# DATABASE CONNECTIVITY
# ============================================================================

function Invoke-xFACtsQuery {
    <#
    .SYNOPSIS
        Execute a SELECT query against xFACts and return results
    #>
    param([string]$Query)
    
    try {
        $results = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $Query -QueryTimeout 30 -ApplicationName "xFACts Start-Orchestrator" -ErrorAction Stop -TrustServerCertificate
        return $results
    }
    catch {
        Write-Log "SQL Query failed: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Invoke-xFACtsWrite {
    <#
    .SYNOPSIS
        Execute an INSERT/UPDATE/DELETE against xFACts
    #>
    param([string]$Query)
    
    try {
        Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $Query -QueryTimeout 30 -ApplicationName "xFACts Start-Orchestrator" -ErrorAction Stop -TrustServerCertificate
        return $true
    }
    catch {
        Write-Log "SQL Write failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# ============================================================================
# CONFIGURATION
# ============================================================================

function Get-EngineConfig {
    <#
    .SYNOPSIS
        Load engine configuration from GlobalConfig
    #>
    
    $configQuery = @"
        SELECT setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name = 'Orchestrator'
          AND is_active = 1
"@
    
    $results = Invoke-xFACtsQuery -Query $configQuery
    
    if ($results) {
        foreach ($row in $results) {
            switch ($row.setting_name) {
                "heartbeat_interval_seconds" { 
                    $Script:HeartbeatSeconds = [int]$row.setting_value 
                }
                "orchestrator_drain_mode" {
                    $Script:DrainMode = ([int]$row.setting_value -eq 1)
                }
            }
        }
    }
    
    $drainStatus = if ($Script:DrainMode) { " [DRAIN MODE]" } else { "" }
    Write-Log "Configuration loaded - Heartbeat: ${Script:HeartbeatSeconds}s$drainStatus" "ENGINE"
}

# ============================================================================
# CYCLE LOGGING
# ============================================================================

function Start-Cycle {
    <#
    .SYNOPSIS
        Create a new CycleLog entry and return the cycle_id
    #>
    
    $query = @"
        INSERT INTO Orchestrator.CycleLog (start_dttm, cycle_status)
        OUTPUT INSERTED.cycle_id
        VALUES (GETDATE(), 'RUNNING')
"@
    
    $result = Invoke-xFACtsQuery -Query $query
    
    if ($result) {
        return $result.cycle_id
    }
    return $null
}

function Complete-Cycle {
    <#
    .SYNOPSIS
        Update CycleLog with final metrics
    #>
    param(
        [long]$CycleId,
        [int]$TasksDue,
        [int]$TasksExecuted,
        [int]$TasksSucceeded,
        [int]$TasksFailed,
        [int]$TasksSkipped,
        [string]$ErrorMessage = $null
    )
    
    $status = if ($TasksFailed -eq 0) { "SUCCESS" }
              elseif ($TasksSucceeded -gt 0) { "PARTIAL" }
              else { "FAILED" }
    
    $errorClause = if ($ErrorMessage) { 
        ", error_message = '$($ErrorMessage -replace "'","''")'" 
    } else { "" }
    
    $query = @"
        UPDATE Orchestrator.CycleLog
        SET end_dttm = GETDATE(),
            duration_ms = DATEDIFF(MILLISECOND, start_dttm, GETDATE()),
            tasks_due = $TasksDue,
            tasks_executed = $TasksExecuted,
            tasks_succeeded = $TasksSucceeded,
            tasks_failed = $TasksFailed,
            tasks_skipped = $TasksSkipped,
            cycle_status = '$status'
            $errorClause
        WHERE cycle_id = $CycleId
"@
    
    Invoke-xFACtsWrite -Query $query | Out-Null
}

# ============================================================================
# TASK LOGGING
# ============================================================================

function Start-TaskLog {
    <#
    .SYNOPSIS
        Create a TaskLog entry when a process begins execution
    .RETURNS
        task_id for callback reference
    #>
    param(
        [long]$CycleId,
        [object]$Process
    )
    
    $executionTarget = if ($Process.script_path) { 
        $Process.script_path -replace "'","''" 
    } else { 
        $Process.procedure_name -replace "'","''" 
    }
    
    $query = @"
        INSERT INTO Orchestrator.TaskLog (
            cycle_id, process_id, module_name, process_name, 
            dependency_group, execution_mode, execution_target,
            start_dttm, task_status
        )
        OUTPUT INSERTED.task_id
        VALUES (
            $CycleId, $($Process.process_id), 
            '$($Process.module_name)', '$($Process.process_name)',
            $($Process.dependency_group), '$($Process.execution_mode)', 
            '$executionTarget',
            GETDATE(), 'RUNNING'
        )
"@
    
    $result = Invoke-xFACtsQuery -Query $query
    
    if ($result) {
        return $result.task_id
    }
    return $null
}

function Complete-TaskLog {
    <#
    .SYNOPSIS
        Update TaskLog with completion status (used for WAIT mode processes)
    #>
    param(
        [long]$TaskId,
        [string]$Status,
        [int]$ExitCode = 0,
        [string]$OutputSummary = $null,
        [string]$ErrorOutput = $null
    )
    
    $outputClause = if ($OutputSummary) { 
        ", output_summary = '$($OutputSummary -replace "'","''" | Select-Object -First 1)'" 
    } else { "" }
    
    $errorClause = if ($ErrorOutput) { 
        ", error_output = '$($ErrorOutput -replace "'","''" | Select-Object -First 1)'" 
    } else { "" }
    
    $query = @"
        UPDATE Orchestrator.TaskLog
        SET end_dttm = GETDATE(),
            duration_ms = DATEDIFF(MILLISECOND, start_dttm, GETDATE()),
            task_status = '$Status',
            exit_code = $ExitCode
            $outputClause
            $errorClause
        WHERE task_id = $TaskId
"@
    
    Invoke-xFACtsWrite -Query $query | Out-Null
}

# ============================================================================
# PROCESS REGISTRY MANAGEMENT
# ============================================================================

function Get-DueProcesses {
    <#
    .SYNOPSIS
        Query ProcessRegistry for processes that are due to execute
    .DESCRIPTION
        Returns enabled, non-running processes where:
        - Interval-based: elapsed seconds since last execution >= interval_seconds
        - Time-based once-daily: current time within 5-min window of scheduled_time, hasn't succeeded today
        - Time-based with polling: past scheduled_time, interval has elapsed, hasn't succeeded today
    #>
    
    $query = @"
        SELECT 
            process_id, module_name, process_name, description,
            script_path, procedure_name, execution_mode, run_mode,
            dependency_group, interval_seconds, scheduled_time,
            timeout_seconds, last_execution_dttm, last_successful_date
        FROM Orchestrator.ProcessRegistry
        WHERE run_mode = 1
          AND (running_count = 0 OR allow_concurrent = 1)
          AND (
                -- Pattern 1: Interval-only (scheduled_time is NULL)
                -- Runs every N seconds, all day
                (scheduled_time IS NULL 
                 AND (last_execution_dttm IS NULL 
                      OR DATEDIFF(SECOND, last_execution_dttm, GETDATE()) >= interval_seconds))

                -- Pattern 2: Time-based once-daily (scheduled_time set, no interval)
                -- Runs once per day within 5-minute window of scheduled_time
                OR (scheduled_time IS NOT NULL
                    AND (interval_seconds IS NULL OR interval_seconds = 0)
                    AND CAST(GETDATE() AS TIME) >= scheduled_time
                    AND CAST(GETDATE() AS TIME) < DATEADD(MINUTE, 5, scheduled_time)
                    AND (last_successful_date IS NULL 
                         OR last_successful_date < CAST(GETDATE() AS DATE)))

                -- Pattern 3: Time-based with polling (scheduled_time AND interval_seconds)
                -- Starts at scheduled_time, polls on interval, stops when successful today
                OR (scheduled_time IS NOT NULL
                    AND interval_seconds > 0
                    AND CAST(GETDATE() AS TIME) >= scheduled_time
                    AND (last_successful_date IS NULL 
                         OR last_successful_date < CAST(GETDATE() AS DATE))
                    AND (last_execution_dttm IS NULL
                         OR DATEDIFF(SECOND, last_execution_dttm, GETDATE()) >= interval_seconds))
              )
        ORDER BY dependency_group, process_id
"@
    
    return Invoke-xFACtsQuery -Query $query
}

function Get-QueueDrivenProcesses {
    <#
    .SYNOPSIS
        Query ProcessRegistry for queue-driven processes with pending work
    .DESCRIPTION
        Returns processes where run_mode = 2 (queue-driven) and running_count > 0.
        The running_count is incremented by triggers on the queue tables when items
        are inserted, signaling that there's work to process.
    #>
    
    $query = @"
        SELECT 
            process_id, module_name, process_name, description,
            script_path, procedure_name, execution_mode,
            dependency_group, interval_seconds, scheduled_time,
            timeout_seconds, last_execution_dttm, last_successful_date,
            running_count
        FROM Orchestrator.ProcessRegistry
        WHERE run_mode = 2
          AND running_count > 0
        ORDER BY dependency_group, process_id
"@
    
    return Invoke-xFACtsQuery -Query $query
}

function Set-ProcessRunning {
    <#
    .SYNOPSIS
        Increment running_count for overlap protection / concurrent tracking
    #>
    param([int]$ProcessId)
    
    $query = @"
        UPDATE Orchestrator.ProcessRegistry
        SET running_count = running_count + 1,
            last_execution_dttm = GETDATE(),
            modified_dttm = GETDATE(),
            modified_by = SUSER_SNAME()
        WHERE process_id = $ProcessId
"@
    
    Invoke-xFACtsWrite -Query $query | Out-Null
}

function Set-ProcessComplete {
    <#
    .SYNOPSIS
        Decrement running_count and record result
    #>
    param(
        [int]$ProcessId,
        [string]$Status,
        [int]$DurationMs
    )
    
    # Update last_successful_date for time-based processes on success
    $successDateClause = if ($Status -eq "SUCCESS") {
        ", last_successful_date = CAST(GETDATE() AS DATE)"
    } else { "" }
    
    $query = @"
        UPDATE Orchestrator.ProcessRegistry
        SET running_count = CASE WHEN running_count > 0 THEN running_count - 1 ELSE 0 END,
            last_execution_status = '$Status',
            last_duration_ms = $DurationMs,
            modified_dttm = GETDATE(),
            modified_by = SUSER_SNAME()
            $successDateClause
        WHERE process_id = $ProcessId
"@
    
    Invoke-xFACtsWrite -Query $query | Out-Null
}

# ============================================================================
# TIMEOUT MONITORING
# ============================================================================

function Test-StaleProcesses {
    <#
    .SYNOPSIS
        Check for processes marked as running that have exceeded their timeout
    .DESCRIPTION
        Finds processes where running_count > 0 and elapsed time exceeds timeout_seconds.
        Resets running_count to 0 and logs a TIMEOUT status. This handles cases
        where a process crashed without decrementing its running count.
    #>
    
    $query = @"
        SELECT process_id, process_name, module_name, timeout_seconds,
               running_count,
               DATEDIFF(SECOND, last_execution_dttm, GETDATE()) AS elapsed_seconds
        FROM Orchestrator.ProcessRegistry
        WHERE running_count > 0
          AND run_mode != 2
          AND timeout_seconds IS NOT NULL
          AND DATEDIFF(SECOND, last_execution_dttm, GETDATE()) > timeout_seconds
"@
    
    $stale = Invoke-xFACtsQuery -Query $query
    
    if ($stale) {
        foreach ($proc in $stale) {
            Write-Log "TIMEOUT: $($proc.process_name) exceeded $($proc.timeout_seconds)s (elapsed: $($proc.elapsed_seconds)s, running_count: $($proc.running_count))" "WARN"
            
            # Full reset to 0 rather than decrement - timeout is anomaly recovery
            $resetQuery = @"
                UPDATE Orchestrator.ProcessRegistry
                SET running_count = 0,
                    last_execution_status = 'TIMEOUT',
                    last_duration_ms = $($proc.elapsed_seconds * 1000),
                    modified_dttm = GETDATE(),
                    modified_by = SUSER_SNAME()
                WHERE process_id = $($proc.process_id)
"@
            Invoke-xFACtsWrite -Query $resetQuery | Out-Null
        }
    }
}

# ============================================================================
# PROCESS EXECUTION
# ============================================================================

function Invoke-Process {
    <#
    .SYNOPSIS
        Execute a registered process (PowerShell script or stored procedure)
    .PARAMETER Process
        Process row from Get-DueProcesses
    .PARAMETER TaskId
        TaskLog ID for callback reference
    .RETURNS
        Hashtable with Status, ExitCode, Output, Error
    #>
    param(
        [object]$Process,
        [long]$TaskId
    )
    
    $result = @{
        Status   = "FAILED"
        ExitCode = -1
        Output   = ""
        Error    = ""
    }
    
    try {
        if ($Process.script_path) {
            # ---- PowerShell Script Execution ----
            $scriptFullPath = Join-Path $ScriptRoot $Process.script_path
            
            if (-not (Test-Path $scriptFullPath)) {
                $result.Error = "Script not found: $scriptFullPath"
                Write-Log "  Script not found: $scriptFullPath" "ERROR"
                return $result
            }
            
            # Build argument list - pass TaskId and ProcessId for callback
            $arguments = "-ExecutionPolicy Bypass -File `"$scriptFullPath`" -Execute -TaskId $TaskId -ProcessId $($Process.process_id)"
            
            if ($Process.execution_mode -eq "WAIT") {
                # WAIT: Start process and capture output
                Write-Log "  Launching (WAIT): $($Process.script_path)" "TASK"
                
                $procInfo = New-Object System.Diagnostics.ProcessStartInfo
                $procInfo.FileName = "powershell.exe"
                $procInfo.Arguments = $arguments
                $procInfo.RedirectStandardOutput = $true
                $procInfo.RedirectStandardError = $true
                $procInfo.UseShellExecute = $false
                $procInfo.CreateNoWindow = $true
                $procInfo.WorkingDirectory = $ScriptRoot
                
$proc = [System.Diagnostics.Process]::Start($procInfo)

# Determine timeout (default 5 minutes if not configured)
$timeoutMs = if ($null -ne $Process.timeout_seconds -and $Process.timeout_seconds -isnot [DBNull]) { $Process.timeout_seconds * 1000 } else { 300000 }

# Read output streams
$stdout = $proc.StandardOutput.ReadToEnd()
$stdout = ($stdout -split "`n" | Where-Object { $_ -notmatch 'Failed to load the .+SQLAS.+ extension|^\s*namespace' }) -join "`n"
$stderr = $proc.StandardError.ReadToEnd()

if ($proc.WaitForExit($timeoutMs)) {
    # Process completed within timeout
    $result.ExitCode = $proc.ExitCode
    $result.Output = if ($stdout.Length -gt 4000) { $stdout.Substring(0, 4000) } else { $stdout }
    $result.Error = if ($stderr.Length -gt 4000) { $stderr.Substring(0, 4000) } else { $stderr }
    $result.Status = if ($proc.ExitCode -eq 0) { "SUCCESS" } else { "FAILED" }
} else {
    # Process exceeded timeout - kill it
    Write-Log "  TIMEOUT: $($Process.process_name) exceeded $($Process.timeout_seconds)s - killing process" "ERROR"
    try { $proc.Kill() } catch { }
    
    $result.Status = "TIMEOUT"
    $result.ExitCode = -1
    $result.Output = if ($stdout.Length -gt 4000) { $stdout.Substring(0, 4000) } else { $stdout }
    $result.Error = "Process killed after exceeding timeout of $($Process.timeout_seconds) seconds"
    
    # Queue Teams alert
    $timeoutAlert = @"
INSERT INTO Teams.AlertQueue (source_module, alert_category, title, message, color, trigger_type, trigger_value)
VALUES (
    'Orchestrator',
    'CRITICAL',
    'xFACts: Process Timeout - $($Process.process_name)',
    '{{WARN}} Process $($Process.process_name) exceeded its timeout of $($Process.timeout_seconds) seconds and was terminated by the orchestrator engine. Investigate the process for issues.',
    'attention',
    'Orchestrator_Timeout',
    '$($Process.process_name)'
);
"@
    try {
        Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $timeoutAlert -QueryTimeout 30 -ApplicationName "xFACts Start-Orchestrator" -ErrorAction Stop -TrustServerCertificate
        Write-Log "  Teams timeout alert queued for $($Process.process_name)" "WARN"
    } catch {
        Write-Log "  Failed to queue timeout alert: $($_.Exception.Message)" "ERROR"
    }
}

$proc.Dispose()
            }
            else {
                # FIRE_AND_FORGET: Start process and move on
                Write-Log "  Launching (FIRE_AND_FORGET): $($Process.script_path)" "TASK"
                
                Start-Process -FilePath "powershell.exe" `
                    -ArgumentList $arguments `
                    -WorkingDirectory $ScriptRoot `
                    -WindowStyle Hidden `
                    -PassThru | Out-Null
                
                $result.Status = "LAUNCHED"
                $result.ExitCode = 0
            }
        }
        elseif ($Process.procedure_name) {
            # ---- Stored Procedure Execution ----
            Write-Log "  Executing SP: $($Process.procedure_name)" "TASK"
            
            $spQuery = "EXEC $($Process.procedure_name) @preview_mode = 0;"
            
            $spResult = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database `
                -Query $spQuery -QueryTimeout 300 -ApplicationName "xFACts Start-Orchestrator" -ErrorAction Stop -TrustServerCertificate
            
            $result.Status = "SUCCESS"
            $result.ExitCode = 0
            $result.Output = if ($spResult) { ($spResult | Out-String).Trim() } else { "" }
            if ($result.Output.Length -gt 4000) { $result.Output = $result.Output.Substring(0, 4000) }
        }
    }
    catch {
        $result.Status = "FAILED"
        $result.Error = $_.Exception.Message
        if ($result.Error.Length -gt 4000) { $result.Error = $result.Error.Substring(0, 4000) }
        Write-Log "  Execution error: $($_.Exception.Message)" "ERROR"
    }
    
    return $result
}

# ============================================================================
# GRACEFUL SHUTDOWN
# ============================================================================

# Register handler for process termination (NSSM stop signal)
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $Script:ShutdownRequested = $true
} | Out-Null

# Also handle Ctrl+C for interactive testing
[Console]::TreatControlCAsInput = $false
$null = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action {
    $Script:ShutdownRequested = $true
    $Event.SourceEventArgs.Cancel = $true
} -ErrorAction SilentlyContinue

# ============================================================================
# MAIN ENGINE LOOP
# ============================================================================

function Start-Engine {
    Write-Log "============================================" "ENGINE"
    Write-Log "  xFACts Orchestrator Starting" "ENGINE"
    Write-Log "  Server:  $ServerInstance" "ENGINE"
    Write-Log "  Database: $Database" "ENGINE"
    Write-Log "  Scripts: $ScriptRoot" "ENGINE"
    Write-Log "============================================" "ENGINE"
    
    # Load initial configuration
    Get-EngineConfig
    
    # Verify database connectivity
    $connTest = Invoke-xFACtsQuery -Query "SELECT 1 AS connected"
    if (-not $connTest) {
        Write-Log "FATAL: Cannot connect to $ServerInstance/$Database" "ERROR"
        exit 1
    }
    Write-Log "Database connectivity verified" "ENGINE"
    
    # Track config refresh interval (reload every 5 minutes)
    $lastConfigRefresh = Get-Date
    $configRefreshMinutes = 5
    
    Write-Log "Entering heartbeat loop (${Script:HeartbeatSeconds}s interval)" "ENGINE"
# Alert if drain mode is active at startup
    if ($Script:DrainMode) {
        Write-Log "WARNING: Drain mode is active at startup!" "WARN"
        
        # Bypass AlertQueue processor - send directly to Teams since queue processor is also blocked by drain mode
        try {
            $webhookQuery = @"
SELECT DISTINCT w.webhook_url, w.webhook_name
FROM Teams.WebhookSubscription s
INNER JOIN Teams.WebhookConfig w ON s.config_id = w.config_id
WHERE s.source_module = 'Orchestrator'
  AND s.is_active = 1
  AND w.is_active = 1
  AND (s.alert_category IS NULL OR s.alert_category = 'WARNING')
  AND (s.trigger_type IS NULL OR s.trigger_type = 'Orchestrator_DrainMode')
"@
            $webhooks = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $webhookQuery -QueryTimeout 30 -ApplicationName "xFACts Start-Orchestrator" -TrustServerCertificate
            
            if ($webhooks) {
                $dateDisplay = Get-Date -Format "MMMM dd, yyyy - h:mm tt"
                $alertTitle = 'xFACts: Orchestrator Started in Drain Mode'
                $alertMessage = 'Orchestrator engine started with drain mode active. No processes will be launched until drain mode is disabled in GlobalConfig (orchestrator_drain_mode = 0).'
                $cardPayload = @"
{
    "type": "message",
    "attachments": [{
        "contentType": "application/vnd.microsoft.card.adaptive",
        "content": {
            "`$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "type": "AdaptiveCard",
            "version": "1.4",
            "body": [
                {
                    "type": "Container",
                    "style": "warning",
                    "bleed": true,
                    "items": [
                        { "type": "TextBlock", "text": "xFACts Orchestrator - Drain Mode Active", "weight": "bolder", "size": "medium", "wrap": true },
                        { "type": "TextBlock", "text": "$dateDisplay", "size": "small", "isSubtle": true, "spacing": "none" }
                    ]
                },
                {
                    "type": "TextBlock",
                    "text": "$([char]::ConvertFromUtf32(0x26A0))$([char]::ConvertFromUtf32(0xFE0F)) The xFACts Orchestrator engine has started and **drain mode is currently active**. No processes will be launched until drain mode is disabled in GlobalConfig (orchestrator_drain_mode = 0).",
                    "wrap": true,
                    "spacing": "medium"
                },
                {
                    "type": "TextBlock",
                    "text": "Source: xFACts Orchestrator Engine",
                    "size": "small",
                    "isSubtle": true,
                    "spacing": "medium"
                }
            ]
        }
    }]
}
"@
                # Insert completed AlertQueue row for audit trail
                $alertMessageSafe = $alertMessage -replace "'", "''"
                $alertTitleSafe = $alertTitle -replace "'", "''"
                $queueInsert = @"
INSERT INTO Teams.AlertQueue (source_module, alert_category, title, message, color, trigger_type, trigger_value, status, processed_dttm)
OUTPUT INSERTED.queue_id
VALUES ('Orchestrator', 'WARNING', '$alertTitleSafe', '$alertMessageSafe', 'warning', 'Orchestrator_DrainMode', 'startup', 'Success', GETDATE())
"@
                $queueResult = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $queueInsert -QueryTimeout 30 -ApplicationName "xFACts Start-Orchestrator" -TrustServerCertificate
                $drainQueueId = $queueResult.queue_id
                
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                foreach ($wh in @($webhooks)) {
                    try {
                        $utf8Body = [System.Text.Encoding]::UTF8.GetBytes($cardPayload)
                        Invoke-RestMethod -Uri $wh.webhook_url -Method Post -Body $utf8Body -ContentType 'application/json; charset=utf-8'
                        Write-Log "  Drain mode alert sent to $($wh.webhook_name)" "WARN"
                        
                        # Log to RequestLog
                        $logQuery = @"
INSERT INTO Teams.RequestLog (queue_id, source_module, alert_category, webhook_name, title, status_code, response_text, trigger_type, trigger_value)
VALUES ($drainQueueId, 'Orchestrator', 'WARNING', '$($wh.webhook_name)', '$alertTitleSafe', 200, 'OK - Direct send (drain mode bypass)', 'Orchestrator_DrainMode', 'startup')
"@
                        Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $logQuery -QueryTimeout 30 -ApplicationName "xFACts Start-Orchestrator" -TrustServerCertificate
                    }
                    catch {
                        Write-Log "  Failed to send drain mode alert to $($wh.webhook_name): $($_.Exception.Message)" "ERROR"
                        
                        # Log failure to RequestLog
                        $errorMsg = $_.Exception.Message -replace "'", "''"
                        $failLogQuery = @"
INSERT INTO Teams.RequestLog (queue_id, source_module, alert_category, webhook_name, title, status_code, response_text, trigger_type, trigger_value)
VALUES ($drainQueueId, 'Orchestrator', 'WARNING', '$($wh.webhook_name)', '$alertTitleSafe', 0, '$errorMsg', 'Orchestrator_DrainMode', 'startup')
"@
                        try { Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $failLogQuery -QueryTimeout 30 -ApplicationName "xFACts Start-Orchestrator" -TrustServerCertificate } catch { }
                    }
                }
            }
            else {
                Write-Log "  No active webhook subscription found for Orchestrator - drain mode alert not sent" "WARN"
            }
        }
        catch {
            Write-Log "  Failed to process drain mode alert: $($_.Exception.Message)" "ERROR"
        }
    }
    Write-Log "" "ENGINE"
    
    # ---- Main Loop ----
    while (-not $Script:ShutdownRequested) {
        
        $cycleStart = Get-Date
        
        # Refresh config periodically
        if (((Get-Date) - $lastConfigRefresh).TotalMinutes -ge $configRefreshMinutes) {
            Get-EngineConfig
            $lastConfigRefresh = Get-Date
        }
        
 # Check for stale/timed-out processes
        Test-StaleProcesses
        
        # Check drain mode - skip new work but allow in-flight processes to complete
        if ($Script:DrainMode) {
            # Force config refresh every cycle while draining so we detect when it's turned off
            Get-EngineConfig
            if ($Script:DrainMode) {
                $runningQuery = "SELECT COUNT(*) AS cnt FROM Orchestrator.ProcessRegistry WHERE running_count > 0"
                $runningResult = Invoke-xFACtsQuery -Query $runningQuery
                $runningCount = if ($runningResult) { $runningResult.cnt } else { 0 }
                Write-Log "Drain mode active - $runningCount process(es) still running" "ENGINE"
                
                # Skip to sleep - do not pick up new work
                $elapsed = ((Get-Date) - $cycleStart).TotalSeconds
                $sleepRemaining = [Math]::Max(0, $Script:HeartbeatSeconds - $elapsed)
                $sleepEnd = (Get-Date).AddSeconds($sleepRemaining)
                while ((Get-Date) -lt $sleepEnd -and -not $Script:ShutdownRequested) {
                    Start-Sleep -Milliseconds 500
                }
                continue
            }
        }
        
        # Find processes due to run
        $dueProcesses = Get-DueProcesses
        
        if ($dueProcesses) {
            $processList = @($dueProcesses)
            $tasksDue = $processList.Count
            Write-Log "Cycle: $tasksDue process(es) due" "ENGINE"
            
            # Start a cycle log
            $cycleId = Start-Cycle
            if (-not $cycleId) {
                Write-Log "Failed to create cycle log entry - skipping cycle" "ERROR"
                Start-Sleep -Seconds $Script:HeartbeatSeconds
                continue
            }
            
            # Group by dependency_group
            $groups = $processList | Group-Object -Property dependency_group | Sort-Object Name
            
            $tasksExecuted = 0
            $tasksSucceeded = 0
            $tasksFailed = 0
            $tasksSkipped = 0
            
            foreach ($group in $groups) {
                $groupNum = $group.Name
                
                if ($Script:ShutdownRequested) {
                    Write-Log "Shutdown requested - stopping execution" "ENGINE"
                    $tasksSkipped += ($processList.Count - $tasksExecuted)
                    break
                }
                
                foreach ($process in $group.Group) {
                    
                    if ($Script:ShutdownRequested) { break }
                    
                    Write-Log "  [$groupNum] $($process.module_name).$($process.process_name)" "TASK"
                    
                    # Mark as running (overlap protection)
                    Set-ProcessRunning -ProcessId $process.process_id
                    
                    # Create task log entry
                    $taskId = Start-TaskLog -CycleId $cycleId -Process $process
                    
                    # Push STARTED event to Control Center
                    Send-EngineEvent -EventType "PROCESS_STARTED" `
                        -ProcessId $process.process_id `
                        -ProcessName $process.process_name `
                        -ModuleName $process.module_name `
                        -TaskId $taskId

                    # Execute the process
                    $execResult = Invoke-Process -Process $process -TaskId $taskId
                    
                    $tasksExecuted++
                    
                    if ($process.execution_mode -eq "WAIT") {
                        # WAIT: Engine tracks completion
                        $durationMs = [int]((Get-Date) - $cycleStart).TotalMilliseconds
                        
                        # Update task log
                        if ($taskId) {
                            Complete-TaskLog -TaskId $taskId `
                                -Status $execResult.Status `
                                -ExitCode $execResult.ExitCode `
                                -OutputSummary $execResult.Output `
                                -ErrorOutput $execResult.Error
                        }
                        
                        # Update process registry
                        Set-ProcessComplete -ProcessId $process.process_id `
                            -Status $execResult.Status `
                            -DurationMs $durationMs
                        
                        # Push COMPLETED event to Control Center
                        $schedTime = if ($process.scheduled_time -and $process.scheduled_time -ne [DBNull]::Value) {
                            $process.scheduled_time.ToString("HH\:mm\:ss")
                        } else { "" }

                        Send-EngineEvent -EventType "PROCESS_COMPLETED" `
                            -ProcessId $process.process_id `
                            -ProcessName $process.process_name `
                            -ModuleName $process.module_name `
                            -TaskId $taskId `
                            -Status $execResult.Status `
                            -DurationMs $durationMs `
                            -ExitCode $execResult.ExitCode `
                            -OutputSummary $execResult.Output `
                            -IntervalSeconds $process.interval_seconds `
                            -ScheduledTime $schedTime `
                            -RunMode $process.run_mode

                        if ($execResult.Status -eq "SUCCESS") { $tasksSucceeded++ }
                        else { $tasksFailed++ }
                        
                        Write-Log "    Result: $($execResult.Status) ($($durationMs)ms)" "TASK"
                    }
                    else {
                        # FIRE_AND_FORGET: Process will call back on its own
                        if ($taskId) {
                            Complete-TaskLog -TaskId $taskId -Status "LAUNCHED" -ExitCode 0
                        }
                        $tasksSucceeded++
                        Write-Log "    Launched (fire-and-forget)" "TASK"
                    }
                }
            }
            
            # Complete the cycle log
            Complete-Cycle -CycleId $cycleId `
                -TasksDue $tasksDue `
                -TasksExecuted $tasksExecuted `
                -TasksSucceeded $tasksSucceeded `
                -TasksFailed $tasksFailed `
                -TasksSkipped $tasksSkipped
            
            Write-Log "Cycle complete: $tasksSucceeded ok, $tasksFailed failed, $tasksSkipped skipped" "ENGINE"
        }
        
        # ====================================================================
        # Queue-Driven Processes
        # ====================================================================
        # Check for queue-driven processes with pending items (running_count > 0)
        # These run independently of the scheduled cycle
        
        $queueProcesses = Get-QueueDrivenProcesses
        
        if ($queueProcesses) {
            $queueList = @($queueProcesses)
            Write-Log "Queue: $($queueList.Count) queue-driven process(es) have pending items" "ENGINE"
            
            foreach ($process in $queueList) {
                
                if ($Script:ShutdownRequested) {
                    Write-Log "Shutdown requested - skipping remaining queue processes" "ENGINE"
                    break
                }
                
                # Check drain mode
                if ((Get-DrainMode)) {
                    Write-Log "Drain mode active - skipping queue process $($process.process_name)" "ENGINE"
                    continue
                }
                
                $queueDepth = $process.running_count
                Write-Log "  [Queue] $($process.module_name).$($process.process_name) (depth: $queueDepth)" "TASK"
                
                # Start a mini-cycle for this queue process
                $cycleId = Start-Cycle
                if (-not $cycleId) {
                    Write-Log "Failed to create cycle log entry for queue process" "ERROR"
                    continue
                }
                
                # Create task log entry
                $taskId = Start-TaskLog -CycleId $cycleId -Process $process
                
                # Push STARTED event to Control Center
                Send-EngineEvent -EventType "PROCESS_STARTED" `
                    -ProcessId $process.process_id `
                    -ProcessName $process.process_name `
                    -ModuleName $process.module_name `
                    -TaskId $taskId

                # Execute the process
                # Note: The process is responsible for decrementing running_count by the number processed
                $execResult = Invoke-Process -Process $process -TaskId $taskId
                
                if ($process.execution_mode -eq "WAIT") {
                    # WAIT: Engine tracks completion
                    $durationMs = [int]((Get-Date) - $cycleStart).TotalMilliseconds
                    
                    # Update task log
                    if ($taskId) {
                        Complete-TaskLog -TaskId $taskId `
                            -Status $execResult.Status `
                            -ExitCode $execResult.ExitCode `
                            -OutputSummary $execResult.Output `
                            -ErrorOutput $execResult.Error
                    }
                    
                    # For queue-driven WAIT processes, we need to reset running_count
                    # The process has handled all items, so count goes to 0
                    $resetQuery = @"
                        UPDATE Orchestrator.ProcessRegistry
                        SET running_count = 0,
                            last_execution_dttm = GETDATE(),
                            last_execution_status = '$($execResult.Status)',
                            last_duration_ms = $durationMs,
                            modified_dttm = GETDATE(),
                            modified_by = SUSER_SNAME()
                        WHERE process_id = $($process.process_id)
"@
                    Invoke-xFACtsWrite -Query $resetQuery | Out-Null
                    
                    # Push COMPLETED event to Control Center
                    $schedTime = if ($process.scheduled_time -and $process.scheduled_time -ne [DBNull]::Value) {
                        $process.scheduled_time.ToString("HH\:mm\:ss")
                    } else { "" }

                    Send-EngineEvent -EventType "PROCESS_COMPLETED" `
                        -ProcessId $process.process_id `
                        -ProcessName $process.process_name `
                        -ModuleName $process.module_name `
                        -TaskId $taskId `
                        -Status $execResult.Status `
                        -DurationMs $durationMs `
                        -ExitCode $execResult.ExitCode `
                        -OutputSummary $execResult.Output `
                        -IntervalSeconds $process.interval_seconds `
                        -ScheduledTime $schedTime `
                        -RunMode $process.run_mode

                    Write-Log "    Result: $($execResult.Status) ($($durationMs)ms, processed queue)" "TASK"
                }
                else {
                    # FIRE_AND_FORGET: Launch and reset running_count immediately
                    # Queue processors drain the entire queue in one pass, so the
                    # trigger-set count is consumed by the launch decision itself.
                    # Reset to 0 now — any new INSERTs during processing will
                    # re-increment via the trigger and get picked up next heartbeat.
                    if ($taskId) {
                        Complete-TaskLog -TaskId $taskId -Status "LAUNCHED" -ExitCode 0
                    }
                    
                    $resetQuery = @"
                        UPDATE Orchestrator.ProcessRegistry
                        SET running_count = 0,
                            last_execution_dttm = GETDATE(),
                            modified_dttm = GETDATE(),
                            modified_by = SUSER_SNAME()
                        WHERE process_id = $($process.process_id)
"@
                    Invoke-xFACtsWrite -Query $resetQuery | Out-Null
                    
                    Write-Log "    Launched (fire-and-forget, count reset)" "TASK"
                }
                
                # Complete the mini-cycle
                Complete-Cycle -CycleId $cycleId `
                    -TasksDue 1 `
                    -TasksExecuted 1 `
                    -TasksSucceeded $(if ($execResult.Status -eq "SUCCESS") { 1 } else { 0 }) `
                    -TasksFailed $(if ($execResult.Status -ne "SUCCESS") { 1 } else { 0 }) `
                    -TasksSkipped 0
            }
        }

        # Sleep until next heartbeat
        # Use short sleep intervals to stay responsive to shutdown signals
        $elapsed = ((Get-Date) - $cycleStart).TotalSeconds
        $sleepRemaining = [Math]::Max(0, $Script:HeartbeatSeconds - $elapsed)
        
        $sleepEnd = (Get-Date).AddSeconds($sleepRemaining)
        while ((Get-Date) -lt $sleepEnd -and -not $Script:ShutdownRequested) {
            Start-Sleep -Milliseconds 500
        }
    }
    
    # ---- Shutdown ----
    Write-Log "" "ENGINE"
    Write-Log "============================================" "ENGINE"
    Write-Log "  xFACts Orchestrator Shutting Down" "ENGINE"
    Write-Log "============================================" "ENGINE"
    
    # Clean up any processes we have marked as running
    $cleanupQuery = @"
        UPDATE Orchestrator.ProcessRegistry
        SET running_count = 0,
            modified_dttm = GETDATE(),
            modified_by = SUSER_SNAME()
        WHERE running_count > 0
"@
    Invoke-xFACtsWrite -Query $cleanupQuery | Out-Null
    Write-Log "Cleared running counts" "ENGINE"
    Write-Log "Shutdown complete" "ENGINE"
}

# ============================================================================
# CALLBACK REFERENCE
# ============================================================================
# Fire-and-forget scripts dot-source xFACts-OrchestratorFunctions.ps1 and call
# Complete-OrchestratorTask at the end of execution. The engine passes -TaskId
# and -ProcessId as parameters when launching scripts.
#
# See xFACts-OrchestratorFunctions.ps1 for function signature and usage.
#

# ============================================================================
# ENTRY POINT
# ============================================================================

Start-Engine
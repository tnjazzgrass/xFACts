<#
.SYNOPSIS
    xFACts - DBCC Operations Execution

.DESCRIPTION
    xFACts - ServerOps.DBCC
    Script: Execute-DBCC.ps1
    Version: Tracked in dbo.System_Metadata (component: ServerOps.DBCC)

    Executes scheduled DBCC integrity operations against databases per
    DBCC_ScheduleConfig. Supports CHECKDB, CHECKALLOC, CHECKCATALOG,
    and CHECKCONSTRAINTS. Runs on a configurable interval via
    ProcessRegistry; exits NO_WORK when no operations are due.

    Two execution modes:
    - Scheduled: Queries DBCC_ScheduleConfig for operations due today
      (run_time hour <= current hour) that have not already been claimed
      or completed. All due items are batch-claimed as PENDING before
      execution begins, then processed sequentially from lightest to
      heaviest: CHECKCATALOG → CHECKALLOC → CHECKCONSTRAINTS → CHECKDB.
      Concurrent invocations safely claim different work items.
    - Manual override: -TargetServer + -Operation bypass the schedule
      table entirely. Optionally -TargetDatabase for a single database.
      Check mode is looked up from DBCC_ScheduleConfig unless -CheckMode
      is explicitly specified.

    For AG listener entries, dynamically resolves the current secondary
    replica and runs DBCC there via direct connection. CHECKCATALOG is
    always routed to the primary replica (read-only secondary limitation).
    The replica_override column on DBCC_ScheduleConfig allows per-database
    override to PRIMARY for all other operations. For non-AG servers,
    connects directly. Results are logged to ServerOps.DBCC_ExecutionLog.
    Alerting: Teams on any non-SUCCESS, Jira ticket on ERRORS_FOUND.

    CHANGELOG
    ---------
    2026-03-22  Per-database check_mode from DBCC_ScheduleConfig replaces
                GlobalConfig dbcc_checkdb_mode. Execute-DbccCheckDb receives
                CheckMode string directly. Manual mode looks up check_mode
                from schedule table with optional -CheckMode parameter override.
    2026-03-22  CHECKCATALOG always routes to PRIMARY on AG listeners
                replica_override support from DBCC_ScheduleConfig
                Connection cache keyed by server+replica for split routing
                Removed skippedServers mechanism (per-operation routing)
                Metric capture from SQL Server error log (replaces inline
                parsing suppressed by NO_INFOMSGS/PHYSICAL_ONLY)
    2026-03-21  Batch claim pattern with PENDING status
                queued_dttm captures claim time, started_dttm captures
                actual execution start. Enables queue visibility and
                time-in-queue metrics on the CC page.
    2026-03-20  Refactored for multi-operation support
                Added DBCC_ScheduleConfig-driven scheduling
                Added CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS operations
                Added -TargetServer, -TargetDatabase, -Operation parameters
                Replaced dbcc_run_day (ServerRegistry) with schedule table
                Replaced check_type with operation + check_mode (ExecutionLog)
                Changed from time-based to interval-based ProcessRegistry
    2026-03-20  Initial implementation (CHECKDB only)

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER Execute
    Perform DBCC operations. Without this flag, runs in preview mode.

.PARAMETER TargetServer
    Manual override: server name to target. Bypasses schedule table.
    Must be used with -Operation. Uses ServerRegistry for connection details.

.PARAMETER TargetDatabase
    Manual override: specific database name. Optional — if omitted with
    -TargetServer, runs against all active databases on that server.

.PARAMETER Operation
    Manual override: which DBCC operation to run. Required with -TargetServer.
    Valid values: CHECKDB, CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS.

.PARAMETER CheckMode
    Manual override: DBCC check mode. Optional — if omitted, looks up the
    database's check_mode from DBCC_ScheduleConfig. If no schedule row exists,
    defaults to PHYSICAL_ONLY. Only applies to CHECKDB operations.
    Valid values: PHYSICAL_ONLY, FULL.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the engine at launch. Used for task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the engine at launch. Used for
    task completion callback. Default 0 (no callback when run manually).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
3. The service account running this script needs:
   - DBCC permissions on all target databases (db_owner or sysadmin)
   - Read/Write access to xFACts database
   - Network access to all target servers
================================================================================
#>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$Execute,
    [string]$TargetServer,
    [string]$TargetDatabase,
    [ValidateSet('CHECKDB', 'CHECKALLOC', 'CHECKCATALOG', 'CHECKCONSTRAINTS')]
    [string]$Operation,
    [ValidateSet('PHYSICAL_ONLY', 'FULL')]
    [string]$CheckMode,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Execute-DBCC' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# PARAMETER VALIDATION
# ============================================================================

$manualMode = $false

if ($TargetServer -and -not $Operation) {
    Write-Log "-TargetServer requires -Operation to be specified" "ERROR"
    exit 1
}
if ($Operation -and -not $TargetServer) {
    Write-Log "-Operation requires -TargetServer to be specified" "ERROR"
    exit 1
}
if ($TargetDatabase -and -not $TargetServer) {
    Write-Log "-TargetDatabase requires -TargetServer to be specified" "ERROR"
    exit 1
}
if ($CheckMode -and -not $TargetServer) {
    Write-Log "-CheckMode requires -TargetServer to be specified (manual mode only)" "ERROR"
    exit 1
}
if ($TargetServer -and $Operation) {
    $manualMode = $true
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Get-AGReplicaRoles {
    param([string]$AGName)

    $query = @"
        SELECT
            ar.replica_server_name,
            ars.role_desc
        FROM sys.dm_hadr_availability_replica_states ars
        INNER JOIN sys.availability_replicas ar
            ON ars.replica_id = ar.replica_id
        INNER JOIN sys.availability_groups ag
            ON ar.group_id = ag.group_id
        WHERE ag.name = '$AGName'
"@

    $results = Get-SqlData -Query $query

    if (-not $results) {
        Write-Log "Failed to query AG replica states for $AGName" "ERROR"
        return $null
    }

    $roles = @{
        PRIMARY   = $null
        SECONDARY = $null
    }

    foreach ($row in $results) {
        if ($row.role_desc -eq 'PRIMARY') {
            $roles.PRIMARY = $row.replica_server_name
        }
        elseif ($row.role_desc -eq 'SECONDARY') {
            $roles.SECONDARY = $row.replica_server_name
        }
    }

    return $roles
}

function Resolve-ConnectionTarget {
    param(
        [object]$Server,
        [hashtable]$Config,
        [string]$ReplicaTarget = $null
    )

    if ($Server.server_type -eq 'AG_LISTENER' -and $Server.ag_cluster_name) {
        $replica = if ($ReplicaTarget) { $ReplicaTarget } else { $Config.SourceReplica }
        Write-Log "  AG listener detected — resolving $replica replica..."

        $roles = Get-AGReplicaRoles -AGName $Config.AGName

        if (-not $roles) {
            Write-Log "  FAILED to resolve AG topology" "ERROR"
            return $null
        }

        $target = $roles[$replica]

        if (-not $target) {
            Write-Log "  No $replica replica found" "ERROR"
            return $null
        }

        Write-Log "  Resolved $replica replica: $target" "SUCCESS"
        return $target
    }
    else {
        $target = if ($Server.instance_name -and $Server.instance_name -ne [DBNull]::Value) {
            "$($Server.server_name)\$($Server.instance_name)"
        } else {
            $Server.server_name
        }
        Write-Log "  Direct connection: $target"
        return $target
    }
}

function Format-Duration {
    param([int]$Seconds)

    $hours = [math]::Floor($Seconds / 3600)
    $minutes = [math]::Floor(($Seconds % 3600) / 60)
    $secs = $Seconds % 60

    if ($hours -gt 0) { return "${hours}h ${minutes}m ${secs}s" }
    elseif ($minutes -gt 0) { return "${minutes}m ${secs}s" }
    else { return "${secs}s" }
}

function Update-ExecutionLogComplete {
    param(
        [int]$LogId,
        [datetime]$EndTime,
        [int]$DurationSeconds,
        [string]$Status,
        [int]$ErrorCount,
        [string]$ErrorDetails,
        [hashtable]$Metrics = @{}
    )

    $errorDetailsSafe = if ($ErrorDetails) {
        if ($ErrorDetails.Length -gt 8000) {
            $ErrorDetails = $ErrorDetails.Substring(0, 7900) + "`n... [truncated]"
        }
        "'" + ($ErrorDetails -replace "'", "''") + "'"
    } else { "NULL" }

    # Build metric column assignments
    $allocErrors      = if ($null -ne $Metrics.AllocationErrors)      { $Metrics.AllocationErrors }      else { "NULL" }
    $consistErrors    = if ($null -ne $Metrics.ConsistencyErrors)     { $Metrics.ConsistencyErrors }     else { "NULL" }
    $repairedErrors   = if ($null -ne $Metrics.RepairedErrors)        { $Metrics.RepairedErrors }        else { "NULL" }
    $dbccElapsed      = if ($null -ne $Metrics.DbccElapsedSeconds)    { $Metrics.DbccElapsedSeconds }    else { "NULL" }
    $splitLsn         = if ($Metrics.SplitPointLsn)                   { "'" + ($Metrics.SplitPointLsn -replace "'", "''") + "'" } else { "NULL" }
    $firstLsn         = if ($Metrics.FirstLsn)                        { "'" + ($Metrics.FirstLsn -replace "'", "''") + "'" }      else { "NULL" }
    $bpScanSec        = if ($null -ne $Metrics.BufferPoolScanSeconds) { $Metrics.BufferPoolScanSeconds } else { "NULL" }
    $pagesScanned     = if ($null -ne $Metrics.PagesScanned)          { $Metrics.PagesScanned }          else { "NULL" }
    $pagesIterated    = if ($null -ne $Metrics.PagesIterated)         { $Metrics.PagesIterated }         else { "NULL" }
    $summaryOutput    = if ($Metrics.SummaryOutput) {
        $safeOutput = $Metrics.SummaryOutput -replace "'", "''"
        if ($safeOutput.Length -gt 2000) { $safeOutput = $safeOutput.Substring(0, 1950) + "`n... [truncated]" }
        "'" + $safeOutput + "'"
    } else { "NULL" }

    Invoke-SqlNonQuery -Query @"
        UPDATE ServerOps.DBCC_ExecutionLog
        SET completed_dttm = '$($EndTime.ToString("yyyy-MM-dd HH:mm:ss"))',
            duration_seconds = $DurationSeconds,
            status = '$Status',
            error_count = $ErrorCount,
            error_details = $errorDetailsSafe,
            dbcc_summary_output = $summaryOutput,
            allocation_errors = $allocErrors,
            consistency_errors = $consistErrors,
            repaired_errors = $repairedErrors,
            dbcc_elapsed_seconds = $dbccElapsed,
            split_point_lsn = $splitLsn,
            first_lsn = $firstLsn,
            buffer_pool_scan_seconds = $bpScanSec,
            pages_scanned = $pagesScanned,
            pages_iterated = $pagesIterated
        WHERE log_id = $LogId
"@
}

function Send-DbccAlert {
    param(
        [string]$OperationName,
        [string]$ServerName,
        [string]$ConnectServer,
        [string]$DatabaseName,
        [string]$Status,
        [int]$DurationSeconds,
        [int]$ErrorCount,
        [string]$ErrorDetails,
        [int]$ServerId,
        [int]$RunId
    )

    $durationDisplay = Format-Duration $DurationSeconds

    $alertCategory = if ($Status -eq 'ERRORS_FOUND') { 'CRITICAL' } else { 'WARNING' }
    $alertEmoji = if ($Status -eq 'ERRORS_FOUND') { '{{FIRE}}' } else { '{{WARNING}}' }

    $alertMessage = "**Server:** $ServerName (executed on $ConnectServer)`n"
    $alertMessage += "**Database:** $DatabaseName`n"
    $alertMessage += "**Operation:** $OperationName`n"
    $alertMessage += "**Duration:** $durationDisplay`n"
    $alertMessage += "**Status:** $Status`n"

    if ($Status -eq 'ERRORS_FOUND' -and $OperationName -eq 'CHECKDB') {
        $alertMessage += "**Errors:** $ErrorCount`n"
        $alertMessage += "`n**Immediate action required.** Run CHECKDB on the primary to determine if corruption exists on both replicas."
    }
    elseif ($Status -eq 'ERRORS_FOUND' -and $OperationName -eq 'CHECKCONSTRAINTS') {
        $alertMessage += "**Constraint violations:** $ErrorCount distinct constraint(s)`n"
        $alertMessage += "`nReview constraint violation details in the DBCC Operations page."
    }
    elseif ($Status -eq 'ERRORS_FOUND') {
        $alertMessage += "**Errors:** $ErrorCount`n"
    }
    elseif ($Status -eq 'FAILED') {
        $errorPreview = if ($ErrorDetails -and $ErrorDetails.Length -gt 200) { $ErrorDetails.Substring(0, 200) + "..." } else { $ErrorDetails }
        $alertMessage += "**Error:** $errorPreview"
    }

    Send-TeamsAlert -SourceModule 'ServerOps' -AlertCategory $alertCategory `
        -Title "$alertEmoji DBCC $OperationName`: $Status — $DatabaseName" `
        -Message $alertMessage `
        -TriggerType "DBCC_$Status" -TriggerValue "$ServerId-$DatabaseName-$OperationName-$RunId"

    # Jira ticket for CHECKDB ERRORS_FOUND only
    # NOTE: Cascading field values are placeholders mirroring JobFlow.
    # Backlog item: Create a DBCC-specific Jira category and update these values.
    if ($Status -eq 'ERRORS_FOUND' -and $OperationName -eq 'CHECKDB') {
        $jiraDescription = "DBCC CHECKDB detected corruption in database [$DatabaseName].`n`n"
        $jiraDescription += "Server: $ServerName (executed on $ConnectServer)`n"
        $jiraDescription += "Duration: $durationDisplay`n"
        $jiraDescription += "Error Count: $ErrorCount`n`n"
        $jiraDescription += "RECOMMENDED ACTIONS:`n"
        $jiraDescription += "1. Run CHECKDB on the PRIMARY replica to confirm corruption scope`n"
        $jiraDescription += "2. If primary is clean — reseed the secondary from primary`n"
        $jiraDescription += "3. If primary has corruption — evaluate restore from clean backup`n"
        $jiraDescription += "4. REPAIR_ALLOW_DATA_LOSS is last resort only`n`n"
        $jiraDescription += "Full DBCC output is available in ServerOps.DBCC_ExecutionLog (run_id: $RunId)."

        $jiraSummary = "DBCC CHECKDB: Corruption detected in $DatabaseName"
        $dueDate = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")

        try {
            $jiraQuery = @"
                EXEC Jira.sp_QueueTicket
                    @SourceModule = 'ServerOps',
                    @ProjectKey = 'SD',
                    @Summary = N'$($jiraSummary -replace "'", "''")' ,
                    @Description = N'$($jiraDescription -replace "'", "''")',
                    @IssueType = 'Issue',
                    @Priority = 'Highest',
                    @EmailRecipients = 'applications@frost-arnett.com',
                    @CascadingField_ID = 'customfield_18401',
                    @CascadingField_ParentValue = 'Database',
                    @CascadingField_ChildValue = 'None',
                    @CustomField_ID = 'customfield_10305',
                    @CustomField_Value = 'FAC INFORMATION TECHNOLOGY',
                    @CustomField2_ID = 'customfield_10009',
                    @CustomField2_Value = 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa',
                    @DueDate = '$dueDate',
                    @TriggerType = 'DBCC_ERRORS_FOUND',
                    @TriggerValue = '$ServerId-$DatabaseName-$RunId'
"@
            Invoke-SqlNonQuery -Query $jiraQuery | Out-Null
            Write-Log "    Jira ticket queued for ERRORS_FOUND" "SUCCESS"
        }
        catch {
            Write-Log "    Failed to queue Jira ticket: $($_.Exception.Message)" "ERROR"
        }
    }
}

# ============================================================================
# OPERATION EXECUTION FUNCTIONS
# ============================================================================

function Get-DbccMetricsFromErrorLog {
    param(
        [string]$ConnectServer,
        [string]$DatabaseName,
        [string]$Operation,
        [datetime]$StartTime,
        [datetime]$EndTime
    )

    $metrics = @{
        AllocationErrors      = $null
        ConsistencyErrors     = $null
        RepairedErrors        = $null
        DbccElapsedSeconds    = $null
        SplitPointLsn         = $null
        FirstLsn              = $null
        BufferPoolScanSeconds = $null
        PagesScanned          = $null
        PagesIterated         = $null
        SummaryOutput         = $null
    }

    # Add a small buffer to the time window to account for clock drift
    $searchStart = $StartTime.AddSeconds(-10).ToString("yyyy-MM-dd HH:mm:ss")
    $searchEnd = $EndTime.AddSeconds(30).ToString("yyyy-MM-dd HH:mm:ss")

    $allSummaryLines = @()

    try {
        # Query 1: DBCC summary line (contains errors, elapsed time, LSN)
        $summaryLines = Invoke-Sqlcmd -ServerInstance $ConnectServer -Database "master" `
            -Query @"
            CREATE TABLE #ErrLog (LogDate DATETIME, ProcessInfo VARCHAR(100), Text NVARCHAR(MAX))
            INSERT INTO #ErrLog EXEC xp_readerrorlog 0, 1, N'DBCC $Operation ($($DatabaseName -replace "'", "''"))', NULL, N'$searchStart', N'$searchEnd'
            SELECT Text FROM #ErrLog ORDER BY LogDate DESC
            DROP TABLE #ErrLog
"@ -QueryTimeout 300 -ApplicationName $script:XFActsAppName -ErrorAction Stop `
            -SuppressProviderContextWarning -TrustServerCertificate

        if ($summaryLines) {
            $summaryText = ($summaryLines | ForEach-Object { $_.Text }) -join "`n"
            $allSummaryLines += $summaryText

            # Parse error counts — two formats depending on check mode:
            # FULL:          "found X allocation errors and Y consistency errors"
            # PHYSICAL_ONLY: "found X errors and repaired Y errors"
            if ($summaryText -match 'found (\d+) allocation errors and (\d+) consistency errors') {
                $metrics.AllocationErrors = [int]$Matches[1]
                $metrics.ConsistencyErrors = [int]$Matches[2]
            }
            elseif ($summaryText -match 'found (\d+) errors and repaired (\d+) errors') {
                # PHYSICAL_ONLY combines all errors into one count
                $metrics.AllocationErrors = [int]$Matches[1]
                $metrics.ConsistencyErrors = 0
                $metrics.RepairedErrors = [int]$Matches[2]
            }

            # Parse repaired errors (FULL mode has separate line — skip if already set by PHYSICAL_ONLY)
            if ($null -eq $metrics.RepairedErrors -and $summaryText -match 'repaired (\d+) errors') {
                $metrics.RepairedErrors = [int]$Matches[1]
            }

            # Parse elapsed time: "Elapsed time: X hours Y minutes Z seconds"
            if ($summaryText -match 'Elapsed time:\s*(\d+)\s*hours?\s*(\d+)\s*minutes?\s*(\d+)\s*seconds?') {
                $metrics.DbccElapsedSeconds = ([int]$Matches[1] * 3600) + ([int]$Matches[2] * 60) + [int]$Matches[3]
            }
            elseif ($summaryText -match 'Elapsed time:\s*(\d+)\s*minutes?\s*(\d+)\s*seconds?') {
                $metrics.DbccElapsedSeconds = ([int]$Matches[1] * 60) + [int]$Matches[2]
            }
            elseif ($summaryText -match 'Elapsed time:\s*(\d+)\s*seconds?') {
                $metrics.DbccElapsedSeconds = [int]$Matches[1]
            }

            # Parse split point LSN
            if ($summaryText -match 'split point LSN\s*=\s*([0-9a-fA-F:]+)') {
                $metrics.SplitPointLsn = $Matches[1]
            }

            # Parse first LSN
            if ($summaryText -match 'first LSN\s*=\s*([0-9a-fA-F:]+)') {
                $metrics.FirstLsn = $Matches[1]
            }
        }

        # Query 2: Buffer pool scan line (contains database ID not name, so no DB name filter)
        # Use time window to correlate with the DBCC execution
        $bufferLines = Invoke-Sqlcmd -ServerInstance $ConnectServer -Database "master" `
            -Query @"
            CREATE TABLE #ErrLog2 (LogDate DATETIME, ProcessInfo VARCHAR(100), Text NVARCHAR(MAX))
            INSERT INTO #ErrLog2 EXEC xp_readerrorlog 0, 1, N'Buffer Pool scan', N'DBCC', N'$searchStart', N'$searchEnd'
            SELECT Text FROM #ErrLog2 ORDER BY LogDate DESC
            DROP TABLE #ErrLog2
"@ -QueryTimeout 300 -ApplicationName $script:XFActsAppName -ErrorAction Stop `
            -SuppressProviderContextWarning -TrustServerCertificate

        if ($bufferLines) {
            $bufferText = ($bufferLines | ForEach-Object { $_.Text }) -join "`n"
            $allSummaryLines += $bufferText

            if ($bufferText -match 'Buffer Pool scan took (\d+) seconds') {
                $metrics.BufferPoolScanSeconds = [int]$Matches[1]
            }

            if ($bufferText -match 'scanned buffers (\d+)') {
                $metrics.PagesScanned = [long]$Matches[1]
            }

            if ($bufferText -match 'total iterated buffers (\d+)') {
                $metrics.PagesIterated = [long]$Matches[1]
            }
        }
    }
    catch {
        Write-Log "    Warning: Could not read error log metrics from $ConnectServer — $($_.Exception.Message)" "WARN"
    }

    # Combine all captured lines into summary output
    if ($allSummaryLines.Count -gt 0) {
        $combined = ($allSummaryLines | Where-Object { $_ }) -join "`n"
        if ($combined.Length -gt 2000) {
            $combined = $combined.Substring(0, 1950) + "`n... [truncated]"
        }
        $metrics.SummaryOutput = $combined
    }

    return $metrics
}

function Execute-DbccCheckDb {
    param(
        [string]$ConnectServer,
        [string]$DatabaseName,
        [string]$CheckMode,
        [int]$MaxDop,
        [bool]$ExtendedLogicalChecks
    )

    $dbccOptions = @("ALL_ERRORMSGS", "NO_INFOMSGS")

    if ($CheckMode -eq 'PHYSICAL_ONLY') {
        $dbccOptions += "PHYSICAL_ONLY"
    }
    if ($ExtendedLogicalChecks -and $CheckMode -eq 'FULL') {
        $dbccOptions += "EXTENDED_LOGICAL_CHECKS"
    }
    if ($MaxDop -gt 0) {
        $dbccOptions += "MAXDOP = $MaxDop"
    }

    $dbccCommand = "DBCC CHECKDB ([$DatabaseName]) WITH $($dbccOptions -join ', ')"
    Write-Log "    Command: $dbccCommand"

    $result = @{
        Status       = 'FAILED'
        ErrorCount   = 0
        ErrorDetails = $null
    }

    try {
        $dbccOutput = Invoke-Sqlcmd -ServerInstance $ConnectServer -Database $DatabaseName `
            -Query $dbccCommand -QueryTimeout 0 `
            -ApplicationName $script:XFActsAppName -ErrorAction Stop `
            -SuppressProviderContextWarning -TrustServerCertificate -Verbose 4>&1

        $allOutput = ($dbccOutput | ForEach-Object { $_.ToString() }) -join "`n"

        # Parse error counts from command output (these come through even with NO_INFOMSGS)
        # FULL mode:          "CHECKDB found X allocation errors and Y consistency errors"
        # PHYSICAL_ONLY mode: "CHECKDB found X errors and repaired Y errors" (or may not appear at all)
        if ($allOutput -match 'CHECKDB found (\d+) allocation errors and (\d+) consistency errors') {
            $allocErrors = [int]$Matches[1]
            $consistErrors = [int]$Matches[2]
            $result.ErrorCount = $allocErrors + $consistErrors

            if ($result.ErrorCount -eq 0) {
                $result.Status = 'SUCCESS'
            }
            else {
                $result.Status = 'ERRORS_FOUND'
                $result.ErrorDetails = $allOutput
            }
        }
        elseif ($allOutput -match 'found (\d+) errors and repaired (\d+) errors') {
            $result.ErrorCount = [int]$Matches[1]

            if ($result.ErrorCount -eq 0) {
                $result.Status = 'SUCCESS'
            }
            else {
                $result.Status = 'ERRORS_FOUND'
                $result.ErrorDetails = $allOutput
            }
        }
        else {
            $result.Status = 'SUCCESS'
        }
    }
    catch {
        $result.ErrorDetails = $_.Exception.Message
        Write-Log "    DBCC FAILED: $($result.ErrorDetails)" "ERROR"
    }

    return $result
}

function Execute-DbccCheckAlloc {
    param(
        [string]$ConnectServer,
        [string]$DatabaseName
    )

    $dbccCommand = "DBCC CHECKALLOC ([$DatabaseName]) WITH NO_INFOMSGS, ALL_ERRORMSGS"
    Write-Log "    Command: $dbccCommand"

    $result = @{ Status = 'FAILED'; ErrorCount = 0; ErrorDetails = $null }

    try {
        $dbccOutput = Invoke-Sqlcmd -ServerInstance $ConnectServer -Database $DatabaseName `
            -Query $dbccCommand -QueryTimeout 0 `
            -ApplicationName $script:XFActsAppName -ErrorAction Stop `
            -SuppressProviderContextWarning -TrustServerCertificate -Verbose 4>&1

        $allOutput = ($dbccOutput | ForEach-Object { $_.ToString() }) -join "`n"

        if ($allOutput -match 'CHECKALLOC found (\d+) allocation errors and (\d+) consistency errors') {
            $allocErrors = [int]$Matches[1]
            $consistErrors = [int]$Matches[2]
            $result.ErrorCount = $allocErrors + $consistErrors

            if ($result.ErrorCount -eq 0) {
                $result.Status = 'SUCCESS'
            }
            else {
                $result.Status = 'ERRORS_FOUND'
                $result.ErrorDetails = $allOutput
            }
        }
        else {
            $result.Status = 'SUCCESS'
        }
    }
    catch {
        $result.ErrorDetails = $_.Exception.Message
        Write-Log "    DBCC FAILED: $($result.ErrorDetails)" "ERROR"
    }

    return $result
}

function Execute-DbccCheckCatalog {
    param(
        [string]$ConnectServer,
        [string]$DatabaseName
    )

    $dbccCommand = "DBCC CHECKCATALOG ([$DatabaseName]) WITH NO_INFOMSGS"
    Write-Log "    Command: $dbccCommand"

    $result = @{ Status = 'FAILED'; ErrorCount = 0; ErrorDetails = $null }

    try {
        $dbccOutput = Invoke-Sqlcmd -ServerInstance $ConnectServer -Database $DatabaseName `
            -Query $dbccCommand -QueryTimeout 0 `
            -ApplicationName $script:XFActsAppName -ErrorAction Stop `
            -SuppressProviderContextWarning -TrustServerCertificate -Verbose 4>&1

        $allOutput = ($dbccOutput | ForEach-Object { $_.ToString() }) -join "`n"

        if ($allOutput -and $allOutput.Trim().Length -gt 0) {
            $result.Status = 'ERRORS_FOUND'
            $result.ErrorCount = 1
            $result.ErrorDetails = $allOutput
        }
        else {
            $result.Status = 'SUCCESS'
        }
    }
    catch {
        $result.ErrorDetails = $_.Exception.Message
        Write-Log "    DBCC FAILED: $($result.ErrorDetails)" "ERROR"
    }

    return $result
}

function Execute-DbccCheckConstraints {
    param(
        [string]$ConnectServer,
        [string]$DatabaseName
    )

    $dbccCommand = "DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS, NO_INFOMSGS, ALL_ERRORMSGS"
    Write-Log "    Command: $dbccCommand"

    $result = @{ Status = 'FAILED'; ErrorCount = 0; ErrorDetails = $null }

    try {
        $dbccOutput = Invoke-Sqlcmd -ServerInstance $ConnectServer -Database $DatabaseName `
            -Query $dbccCommand -QueryTimeout 0 `
            -ApplicationName $script:XFActsAppName -ErrorAction Stop `
            -SuppressProviderContextWarning -TrustServerCertificate

        if ($null -eq $dbccOutput -or @($dbccOutput).Count -eq 0) {
            $result.Status = 'SUCCESS'
        }
        else {
            $violations = @($dbccOutput)
            $result.Status = 'ERRORS_FOUND'

            $grouped = $violations | Group-Object { "$($_.Table)|$($_.Constraint)" }
            $result.ErrorCount = $grouped.Count

            $summaryLines = @()
            foreach ($group in ($grouped | Sort-Object Count -Descending)) {
                $parts = $group.Name -split '\|'
                $tableName = $parts[0]
                $constraintName = if ($parts.Length -gt 1) { $parts[1] } else { 'Unknown' }
                $summaryLines += "$tableName / $constraintName`: $($group.Count) violation(s)"
            }

            $result.ErrorDetails = "Constraint violations found: $($result.ErrorCount) distinct constraint(s)`n`n" +
                                   ($summaryLines -join "`n")
        }
    }
    catch {
        $result.ErrorDetails = $_.Exception.Message
        Write-Log "    DBCC FAILED: $($result.ErrorDetails)" "ERROR"
    }

    return $result
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

$scriptStart = Get-Date

Write-Log ""
Write-Log "================================================================"
Write-Log "  DBCC Operations Execution"
Write-Log "================================================================"

if ($manualMode) {
    Write-Log "  Mode: MANUAL OVERRIDE"
    Write-Log "  Target server: $TargetServer"
    Write-Log "  Target database: $(if ($TargetDatabase) { $TargetDatabase } else { 'ALL' })"
    Write-Log "  Operation: $Operation"
    if ($CheckMode) {
        Write-Log "  Check mode override: $CheckMode"
    }
}
else {
    Write-Log "  Mode: SCHEDULED"
}
Write-Log ""

# ----------------------------------------------------------------------------
# Step 1: Load GlobalConfig settings
# ----------------------------------------------------------------------------

Write-Log "Loading configuration..."

$configQuery = @"
    SELECT setting_name, setting_value
    FROM dbo.GlobalConfig
    WHERE module_name IN ('ServerOps', 'Shared')
      AND (category = 'DBCC' OR category IS NULL OR setting_name IN ('AGName', 'SourceReplica'))
      AND is_active = 1
"@

$configResults = Get-SqlData -Query $configQuery

$Script:Config = @{
    AGName                  = "DMPRODAG"
    SourceReplica           = "SECONDARY"
    MaxDop                  = 4
    ExtendedLogicalChecks   = $false
    AlertingEnabled         = $true
}

if ($configResults) {
    foreach ($row in $configResults) {
        switch ($row.setting_name) {
            "AGName"                        { $Script:Config.AGName = $row.setting_value }
            "SourceReplica"                 { $Script:Config.SourceReplica = $row.setting_value }
            "dbcc_max_dop"                  { $Script:Config.MaxDop = [int]$row.setting_value }
            "dbcc_extended_logical_checks"  { $Script:Config.ExtendedLogicalChecks = [bool][int]$row.setting_value }
            "dbcc_alerting_enabled"         { $Script:Config.AlertingEnabled = [bool][int]$row.setting_value }
        }
    }
}

Write-Log "  MAXDOP: $($Script:Config.MaxDop)"
Write-Log "  Extended logical checks: $($Script:Config.ExtendedLogicalChecks)"
Write-Log "  Alerting: $(if ($Script:Config.AlertingEnabled) { 'Enabled' } else { 'Disabled' })"
Write-Log ""

# ----------------------------------------------------------------------------
# Step 2: Generate run_id
# ----------------------------------------------------------------------------

$runIdResult = Get-SqlData -Query "SELECT ISNULL(MAX(run_id), 0) + 1 AS next_run_id FROM ServerOps.DBCC_ExecutionLog"
$runId = $runIdResult.next_run_id
Write-Log "Run ID: $runId"
Write-Log ""

# ----------------------------------------------------------------------------
# Step 3: Build and claim the work list
# ----------------------------------------------------------------------------

$workItems = @()
$todayDow = [int](Get-Date).DayOfWeek + 1
$currentHour = [int](Get-Date).Hour
$todayStr = (Get-Date).ToString("yyyy-MM-dd")

Write-Log "Today is day $todayDow (1=Sun..7=Sat), current hour: $currentHour"
Write-Log ""

if ($manualMode) {
    # -----------------------------------------------------------------
    # Manual mode: look up server from ServerRegistry
    # -----------------------------------------------------------------

    $serverQuery = @"
        SELECT server_id, server_name, instance_name, server_type, ag_cluster_name
        FROM dbo.ServerRegistry
        WHERE server_name = '$($TargetServer -replace "'", "''")'
          AND is_active = 1
"@

    $serverInfo = Get-SqlData -Query $serverQuery

    if (-not $serverInfo) {
        Write-Log "Server '$TargetServer' not found in ServerRegistry or not active" "ERROR"
        exit 1
    }

    $dbFilter = if ($TargetDatabase) {
        "AND dr.database_name = '$($TargetDatabase -replace "'", "''")'`n"
    } else { "" }

    $dbQuery = @"
        SELECT dr.database_id, dr.database_name
        FROM dbo.DatabaseRegistry dr
        WHERE dr.server_id = $($serverInfo.server_id)
          AND dr.is_active = 1
          $dbFilter
        ORDER BY dr.database_id
"@

    $databases = Get-SqlData -Query $dbQuery

    if (-not $databases) {
        $target = if ($TargetDatabase) { "Database '$TargetDatabase' on server" } else { "No active databases for server" }
        Write-Log "$target '$TargetServer' not found in DatabaseRegistry" "ERROR"
        exit 1
    }

    # Look up check_mode from DBCC_ScheduleConfig for each database (unless -CheckMode parameter supplied)
    $scheduleCheckModes = @{}
    if (-not $CheckMode) {
        $modeQuery = @"
            SELECT database_name, check_mode
            FROM ServerOps.DBCC_ScheduleConfig
            WHERE server_id = $($serverInfo.server_id)
"@
        $modeRows = Get-SqlData -Query $modeQuery
        if ($modeRows) {
            foreach ($mr in @($modeRows)) {
                $scheduleCheckModes[$mr.database_name] = $mr.check_mode
            }
        }
    }

    foreach ($db in @($databases)) {
        # Resolve check mode: parameter override > schedule table > default PHYSICAL_ONLY
        $dbCheckMode = if ($CheckMode) {
            $CheckMode
        }
        elseif ($scheduleCheckModes.ContainsKey($db.database_name) -and $scheduleCheckModes[$db.database_name] -ne 'NONE') {
            $scheduleCheckModes[$db.database_name]
        }
        else {
            'PHYSICAL_ONLY'
        }

        $workItems += @{
            ServerId        = $serverInfo.server_id
            ServerName      = $serverInfo.server_name
            ServerType      = $serverInfo.server_type
            InstanceName    = $serverInfo.instance_name
            AGCluster       = $serverInfo.ag_cluster_name
            DatabaseName    = $db.database_name
            Operation       = $Operation
            CheckMode       = $dbCheckMode
            ReplicaOverride = $null
            LogId           = 0
        }
    }

    Write-Log "Manual mode: $($workItems.Count) work item(s) queued"
}
else {
    # -----------------------------------------------------------------
    # Scheduled mode: query DBCC_ScheduleConfig for operations due now
    # -----------------------------------------------------------------

    $scheduleQuery = @"
        SELECT
            sc.server_id, sc.server_name, sc.database_id, sc.database_name,
            sr.instance_name, sr.server_type, sr.ag_cluster_name,
            sc.checkcatalog_enabled, sc.checkcatalog_run_day, sc.checkcatalog_run_time,
            sc.checkalloc_enabled, sc.checkalloc_run_day, sc.checkalloc_run_time,
            sc.checkconstraints_enabled, sc.checkconstraints_run_day, sc.checkconstraints_run_time,
            sc.checkdb_enabled, sc.checkdb_run_day, sc.checkdb_run_time,
            sc.check_mode, sc.replica_override
        FROM ServerOps.DBCC_ScheduleConfig sc
        INNER JOIN dbo.ServerRegistry sr ON sr.server_id = sc.server_id
        WHERE sc.is_enabled = 1
          AND sr.is_active = 1
          AND sr.serverops_dbcc_enabled = 1
        ORDER BY sc.server_id, sc.database_name
"@

    $scheduleRows = Get-SqlData -Query $scheduleQuery

    if (-not $scheduleRows) {
        Write-Log "No enabled DBCC schedules found. Exiting." "INFO"

        if ($TaskId -gt 0) {
            $duration = [int]((Get-Date) - $scriptStart).TotalMilliseconds
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs $duration `
                -Output "No enabled DBCC schedules"
        }
        exit 0
    }

    # Operation definitions in execution priority order (lightest → heaviest)
    $operationDefs = @(
        @{ Name = 'CHECKCATALOG';     EnabledCol = 'checkcatalog_enabled';     DayCol = 'checkcatalog_run_day';     TimeCol = 'checkcatalog_run_time' },
        @{ Name = 'CHECKALLOC';       EnabledCol = 'checkalloc_enabled';       DayCol = 'checkalloc_run_day';       TimeCol = 'checkalloc_run_time' },
        @{ Name = 'CHECKCONSTRAINTS'; EnabledCol = 'checkconstraints_enabled'; DayCol = 'checkconstraints_run_day'; TimeCol = 'checkconstraints_run_time' },
        @{ Name = 'CHECKDB';          EnabledCol = 'checkdb_enabled';          DayCol = 'checkdb_run_day';          TimeCol = 'checkdb_run_time' }
    )

    foreach ($opDef in $operationDefs) {
        foreach ($row in @($scheduleRows)) {
            if (-not $row.($opDef.EnabledCol)) { continue }

            $runDay = $row.($opDef.DayCol)
            $runTime = $row.($opDef.TimeCol)

            if ($null -eq $runDay -or $null -eq $runTime) { continue }
            if ([int]$runDay -ne $todayDow) { continue }

            # Due if scheduled hour <= current hour
            $scheduleHour = ([TimeSpan]$runTime).Hours
            if ($scheduleHour -gt $currentHour) { continue }

            $workItems += @{
                ServerId        = $row.server_id
                ServerName      = $row.server_name
                ServerType      = $row.server_type
                InstanceName    = $row.instance_name
                AGCluster       = $row.ag_cluster_name
                DatabaseName    = $row.database_name
                Operation       = $opDef.Name
                CheckMode       = $row.check_mode
                ReplicaOverride = $row.replica_override
                LogId           = 0
            }
        }
    }

    if ($workItems.Count -eq 0) {
        Write-Log "No operations due. Exiting." "INFO"

        if ($TaskId -gt 0) {
            $duration = [int]((Get-Date) - $scriptStart).TotalMilliseconds
            Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
                -TaskId $TaskId -ProcessId $ProcessId `
                -Status "SUCCESS" -DurationMs $duration `
                -Output "No operations due (day $todayDow, hour $currentHour)"
        }
        exit 0
    }

    Write-Log "Found $($workItems.Count) candidate operation(s)"
}

Write-Log ""

# ----------------------------------------------------------------------------
# Step 4: Batch claim — INSERT PENDING rows for all unclaimed work items
# ----------------------------------------------------------------------------

Write-Log "Claiming work items..."

$claimedItems = @()
$claimTime = Get-Date

foreach ($work in $workItems) {
    $serverId = $work.ServerId
    $serverName = $work.ServerName
    $dbName = $work.DatabaseName
    $opName = $work.Operation

    # In scheduled mode, check if already claimed/completed today
    if (-not $manualMode) {
        $existing = Get-SqlData -Query @"
            SELECT TOP 1 log_id
            FROM ServerOps.DBCC_ExecutionLog
            WHERE operation = '$opName'
              AND server_id = $serverId
              AND database_name = '$($dbName -replace "'", "''")'
              AND CAST(queued_dttm AS DATE) = '$todayStr'
"@

        if ($existing) {
            Write-Log "  $opName on $dbName — already claimed today, skipping"
            continue
        }
    }

    # Claim: insert PENDING row
    # check_mode comes from the work item (per-database from DBCC_ScheduleConfig)
    $checkMode = if ($opName -eq 'CHECKDB') { $work.CheckMode } else { $null }
    $checkModeVal = if ($checkMode -and $checkMode -ne 'NONE') { "'$checkMode'" } else { "NULL" }

    if ($Execute) {
        $logResult = Invoke-SqlNonQuery -Query @"
            INSERT INTO ServerOps.DBCC_ExecutionLog
                (run_id, server_id, server_name, executed_on_server, database_name,
                 operation, check_mode, max_dop, extended_logical_checks,
                 queued_dttm, status, executed_by)
            VALUES
                ($runId, $serverId, '$serverName', '$serverName', '$($dbName -replace "'", "''")',
                 '$opName', $checkModeVal, $($Script:Config.MaxDop), $(if ($Script:Config.ExtendedLogicalChecks) { 1 } else { 0 }),
                 '$($claimTime.ToString("yyyy-MM-dd HH:mm:ss"))', 'PENDING', SUSER_SNAME());
            SELECT SCOPE_IDENTITY() AS log_id;
"@

        $logId = if ($logResult) { $logResult.log_id } else { 0 }
    }
    else {
        $logId = 0
    }

    $work.LogId = $logId

    $claimedItems += $work
    Write-Log "  $opName on $dbName — claimed as PENDING (log_id: $logId)"
}

Write-Log ""

if ($claimedItems.Count -eq 0) {
    Write-Log "No unclaimed operations to process. Exiting." "INFO"

    if ($TaskId -gt 0) {
        $duration = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "SUCCESS" -DurationMs $duration `
            -Output "No unclaimed operations (day $todayDow, hour $currentHour)"
    }
    exit 0
}

Write-Log "Claimed $($claimedItems.Count) operation(s)"
Write-Log ""

# ----------------------------------------------------------------------------
# Step 5: Initialize connection cache and stats
# Cache keys: serverId for non-AG, serverId-REPLICA for AG (supports split routing)
# ----------------------------------------------------------------------------

$connectionCache = @{}

$stats = @{
    OperationsAttempted   = 0
    OperationsSucceeded   = 0
    OperationsFailed      = 0
    OperationsErrorsFound = 0
    OperationsSkipped     = 0
}

# ----------------------------------------------------------------------------
# Step 6: Execute claimed work items
# ----------------------------------------------------------------------------

foreach ($work in $claimedItems) {
    $serverId    = $work.ServerId
    $serverName  = $work.ServerName
    $dbName      = $work.DatabaseName
    $opName      = $work.Operation
    $logId       = $work.LogId

    Write-Log "----------------------------------------------------------------"
    Write-Log "  ${opName}: $dbName on $serverName (log_id: $logId)"
    if ($opName -eq 'CHECKDB') {
        Write-Log "  Check mode: $($work.CheckMode)"
    }
    Write-Log "----------------------------------------------------------------"

    # Resolve connection — AG-aware routing
    # CHECKCATALOG always routes to PRIMARY on AG listeners (snapshot limitation).
    # replica_override on ScheduleConfig overrides the default for all other operations.
    # Non-AG servers always use direct connection regardless of these settings.

    $isAGListener = ($work.ServerType -eq 'AG_LISTENER' -and $work.AGCluster)

    # Determine which replica to target
    $targetReplica = $Script:Config.SourceReplica  # default: SECONDARY

    if ($isAGListener) {
        if ($opName -eq 'CHECKCATALOG') {
            $targetReplica = 'PRIMARY'
        }
        elseif ($work.ReplicaOverride) {
            $targetReplica = $work.ReplicaOverride
        }
    }

    $cacheKey = if ($isAGListener) { "$serverId-$targetReplica" } else { "$serverId" }

    if (-not $connectionCache.ContainsKey($cacheKey)) {
        $serverObj = [PSCustomObject]@{
            server_name     = $work.ServerName
            server_type     = $work.ServerType
            instance_name   = $work.InstanceName
            ag_cluster_name = $work.AGCluster
        }

        $connectServer = Resolve-ConnectionTarget -Server $serverObj -Config $Script:Config -ReplicaTarget $targetReplica

        if (-not $connectServer) {
            Write-Log "  FAILED to resolve $targetReplica connection — skipping" "ERROR"

            if ($logId -gt 0) {
                Update-ExecutionLogComplete -LogId $logId -EndTime (Get-Date) `
                    -DurationSeconds 0 -Status 'FAILED' -ErrorCount 0 `
                    -ErrorDetails "AG $targetReplica replica resolution failed"
            }

            if ($Script:Config.AlertingEnabled -and $Execute) {
                Send-TeamsAlert -SourceModule 'ServerOps' -AlertCategory 'WARNING' `
                    -Title "{{WARNING}} DBCC: Connection Resolution Failed" `
                    -Message "**Server:** $serverName`nCould not resolve $targetReplica replica. DBCC $opName skipped for $dbName." `
                    -TriggerType 'DBCC_RESOLUTION_FAILED' -TriggerValue "$serverId-$runId"
            }

            $stats.OperationsSkipped++
            continue
        }

        $connectionCache[$cacheKey] = $connectServer
    }

    $connectServer = $connectionCache[$cacheKey]

    # Log routing decision for AG listeners when not using default
    if ($isAGListener -and $targetReplica -ne $Script:Config.SourceReplica) {
        $reason = if ($opName -eq 'CHECKCATALOG') { 'CHECKCATALOG requires PRIMARY (read-only secondary limitation)' }
                  elseif ($work.ReplicaOverride) { "replica_override = $($work.ReplicaOverride)" }
                  else { '' }
        Write-Log "  Routed to $targetReplica replica: $connectServer ($reason)"
    }

    # Check database is online on the target server
    $dbStateResult = $null
    try {
        $dbStateResult = Invoke-Sqlcmd -ServerInstance $connectServer -Database "master" `
            -Query "SELECT state_desc FROM sys.databases WHERE name = '$($dbName -replace "'", "''")'" `
            -QueryTimeout 300 -ApplicationName $script:XFActsAppName `
            -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
    }
    catch {
        Write-Log "    Failed to check database state: $($_.Exception.Message)" "ERROR"
    }

    if (-not $dbStateResult -or $dbStateResult.state_desc -ne 'ONLINE') {
        $stateDesc = if ($dbStateResult) { $dbStateResult.state_desc } else { 'UNREACHABLE' }
        Write-Log "    Database is $stateDesc — skipping" "WARN"

        if ($logId -gt 0) {
            Update-ExecutionLogComplete -LogId $logId -EndTime (Get-Date) `
                -DurationSeconds 0 -Status 'FAILED' -ErrorCount 0 `
                -ErrorDetails "Database state: $stateDesc"
        }

        $stats.OperationsFailed++
        continue
    }

    if (-not $Execute) {
        Write-Log "    [Preview] Would execute $opName" "INFO"
        $stats.OperationsAttempted++
        $stats.OperationsSucceeded++
        Write-Log ""
        continue
    }

    # Transition PENDING → IN_PROGRESS with actual start time and resolved server
    $opStart = Get-Date

    Invoke-SqlNonQuery -Query @"
        UPDATE ServerOps.DBCC_ExecutionLog
        SET status = 'IN_PROGRESS',
            started_dttm = '$($opStart.ToString("yyyy-MM-dd HH:mm:ss"))',
            executed_on_server = '$connectServer'
        WHERE log_id = $logId
"@

    # Execute the operation
    $stats.OperationsAttempted++

    $opResult = switch ($opName) {
        'CHECKDB'          { Execute-DbccCheckDb -ConnectServer $connectServer -DatabaseName $dbName `
                                -CheckMode $work.CheckMode -MaxDop $Script:Config.MaxDop `
                                -ExtendedLogicalChecks $Script:Config.ExtendedLogicalChecks }
        'CHECKALLOC'       { Execute-DbccCheckAlloc -ConnectServer $connectServer -DatabaseName $dbName }
        'CHECKCATALOG'     { Execute-DbccCheckCatalog -ConnectServer $connectServer -DatabaseName $dbName }
        'CHECKCONSTRAINTS' { Execute-DbccCheckConstraints -ConnectServer $connectServer -DatabaseName $dbName }
    }

    $opEnd = Get-Date
    $durationSeconds = [int](($opEnd - $opStart).TotalSeconds)

    $status = $opResult.Status
    $errorCount = $opResult.ErrorCount
    $errorDetails = $opResult.ErrorDetails

    Write-Log "    $status$(if ($errorCount -gt 0) { " — $errorCount error(s)" } else { '' }) ($(Format-Duration $durationSeconds))" `
        $(if ($status -eq 'SUCCESS') { 'SUCCESS' } else { 'ERROR' })

    if ($logId -gt 0) {
        # Retrieve metrics and summary output from SQL Server error log
        $metrics = @{}

        if ($status -ne 'FAILED') {
            Write-Log "    Extracting metrics from error log..."
            $metrics = Get-DbccMetricsFromErrorLog -ConnectServer $connectServer `
                -DatabaseName $dbName -Operation $opName `
                -StartTime $opStart -EndTime $opEnd

            $metricCount = ($metrics.Keys | Where-Object { $_ -ne 'SummaryOutput' } | Where-Object { $null -ne $metrics[$_] }).Count
            Write-Log "    Captured $metricCount metric(s) from error log"
        }

        Update-ExecutionLogComplete -LogId $logId -EndTime $opEnd `
            -DurationSeconds $durationSeconds -Status $status `
            -ErrorCount $errorCount -ErrorDetails $errorDetails `
            -Metrics $metrics
    }

    switch ($status) {
        'SUCCESS'       { $stats.OperationsSucceeded++ }
        'FAILED'        { $stats.OperationsFailed++ }
        'ERRORS_FOUND'  { $stats.OperationsErrorsFound++ }
    }

    if ($Script:Config.AlertingEnabled -and $status -ne 'SUCCESS') {
        Send-DbccAlert -OperationName $opName -ServerName $serverName `
            -ConnectServer $connectServer -DatabaseName $dbName `
            -Status $status -DurationSeconds $durationSeconds `
            -ErrorCount $errorCount -ErrorDetails $errorDetails `
            -ServerId $serverId -RunId $runId
    }

    Write-Log ""
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

$scriptEnd = Get-Date
$totalDuration = [int](($scriptEnd - $scriptStart).TotalSeconds)
$totalDurationMs = [int](($scriptEnd - $scriptStart).TotalMilliseconds)
$durationDisplay = Format-Duration $totalDuration

Write-Log "================================================================"
Write-Log "  DBCC Execution Complete"
Write-Log "================================================================"
Write-Log "  Mode:              $(if ($manualMode) { 'MANUAL' } else { 'SCHEDULED' })"
Write-Log "  Duration:          $durationDisplay"
Write-Log "  Operations run:    $($stats.OperationsAttempted)"
Write-Log "  Succeeded:         $($stats.OperationsSucceeded)"
Write-Log "  Failed:            $($stats.OperationsFailed)"
Write-Log "  Errors found:      $($stats.OperationsErrorsFound)"
Write-Log "  Skipped:           $($stats.OperationsSkipped)"
Write-Log "================================================================"

$finalStatus = if (-not $Execute) { 'SUCCESS' }
               elseif ($stats.OperationsErrorsFound -gt 0) { 'FAILED' }
               elseif ($stats.OperationsFailed -gt 0) { 'FAILED' }
               elseif ($stats.OperationsAttempted -eq 0) { 'SUCCESS' }
               else { 'SUCCESS' }

$outputSummary = "$(if ($manualMode) { 'Manual' } else { 'Scheduled' }): " +
                 "$($stats.OperationsSucceeded) OK, $($stats.OperationsFailed) failed, " +
                 "$($stats.OperationsErrorsFound) errors, $($stats.OperationsSkipped) skipped. " +
                 "Duration: $durationDisplay"

if ($TaskId -gt 0) {
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalDurationMs `
        -Output $outputSummary
}
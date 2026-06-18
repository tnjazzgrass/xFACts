<#
.SYNOPSIS
    xFACts - DM Shell Consumer Purge

.DESCRIPTION
    Purges orphaned consumer records ("shells") from crs5_oltp. A shell is a
    consumer with no remaining cnsmr_accnt records, typically created by account
    archiving or consumer merge operations. Targets consumers in the WFAPURGE
    workgroup (populated nightly by a DM scheduled job). Pre-flight exclusions
    skip consumers that still have data in tables not safely deletable in
    isolation. The delete sequence is derived from sys.foreign_keys chain
    analysis against the cnsmr terminal table, with dynamic UDEF discovery and
    the shared DmOps chunked delete/update engine. Schedule-aware and
    preview/execute aware: without -Execute the script performs no writes.

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR).

.PARAMETER Database
    xFACts database name (default: xFACts).

.PARAMETER TargetInstance
    SQL Server instance hosting crs5_oltp to purge from. Default reads from
    GlobalConfig DmOps.ShellPurge.target_instance. Override for testing.

.PARAMETER BatchSize
    Number of consumers per batch. Default reads from GlobalConfig based on
    schedule mode. When specified, overrides schedule-driven batch sizing.

.PARAMETER ChunkSize
    Maximum rows per DELETE/UPDATE operation. Larger tables are processed in
    chunks of this size to prevent lock escalation and blocking. Default 5000.

.PARAMETER Execute
    Switch. Without it the script runs in PREVIEW mode: counts rows and emits
    console and log output but performs no writes. With -Execute, all
    operations run normally.

.PARAMETER SingleBatch
    Run one batch only, then exit. Bypasses the batch loop and schedule recheck.

.PARAMETER TaskId
    Orchestrator TaskLog ID. Default 0 (manual execution).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID. Default 0 (manual execution).

.COMPONENT
    DmOps

.NOTES
    File Name : Execute-DmShellPurge.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    CONSTANTS: AUDIT TARGETS
    VARIABLES: SCRIPT-LEVEL STATE
    FUNCTIONS: BATCH LOGGING
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this script. Most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-16  Migrated the connection, SQL primitive, operation wrapper, and step
#             wrapper functions to the shared xFACts-DmOpsFunctions.ps1 engine,
#             dot-sourced in IMPORTS. Renamed the surviving consumer-specific
#             functions and script-level state to the dmo_Shell convention, set
#             $script:dmo_BatchDetailTable for the shared audit writer, and
#             conformed the file to the Control Center PowerShell format spec.
# 2026-04-27  Aligned with shared infrastructure preview-mode contract. Logging
#             functions and the runtime exception-log INSERT now early-return when
#             $script:XFActsExecute is false; preview runs are console-only with
#             zero database writes. Step wrappers read $script:XFActsExecute
#             directly. Renamed ShellPurge_ExclusionLog to
#             ShellPurge_ConsumerExceptionLog for consistency with Archive.
# 2026-03-30  Phase 2 redesigned from sys.foreign_keys chain analysis.
#             Total: 101 steps, 34 new FK-required tables, FK ordering corrected
#             Added UPDATE operation path for suspense merge reference cleanup.
#             Removed the exclude_suspense toggle; all exclusions managed uniformly.
# 2026-03-24  Initial implementation.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   The [CmdletBinding()] attribute and param() block declaring the script-level
   parameters that drive target selection, batch sizing, and execute mode.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [string]$TargetInstance = "",
    [int]$BatchSize = 0,
    [int]$ChunkSize = 0,
    [switch]$Execute,
    [switch]$SingleBatch,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sources the shared orchestrator helpers and the DmOps shared
   consumer-deletion engine used throughout the script.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
. "$PSScriptRoot\xFACts-DmOpsFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   Establishes the platform script context (logging, execute flag, database
   connection settings) before any script-level state is declared.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Execute-DmShellPurge' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   CONSTANTS: AUDIT TARGETS
   ----------------------------------------------------------------------------
   Fixed identifiers consumed by the shared audit writer. The detail table name
   is read by Write-dmo_BatchDetail in the shared engine.
   Prefix: dmo
   ============================================================================ #>

# Audit detail table the shared Write-dmo_BatchDetail writes to.
$script:dmo_BatchDetailTable = 'DmOps.ShellPurge_BatchDetail'

<# ============================================================================
   VARIABLES: SCRIPT-LEVEL STATE
   ----------------------------------------------------------------------------
   Mutable runtime state: the target connection and resolved settings, the
   current batch identifier and per-batch counters, and the session-level
   rollups. Reset or accumulated as the batch loop runs.
   Prefix: dmo
   ============================================================================ #>

# Resolved crs5_oltp target server name.
$script:dmo_TargetServer = $null
# Persistent SqlConnection to the crs5_oltp target instance.
$script:dmo_TargetConnection = $null
# Rows per DELETE/UPDATE chunk (overridable via -ChunkSize or GlobalConfig).
$script:dmo_BatchChunkSize = 5000
# Consumers per batch in Full mode (from GlobalConfig).
$script:dmo_BatchSizeFull = 1000
# Consumers per batch in Reduced mode (from GlobalConfig).
$script:dmo_BatchSizeReduced = 100
# Current schedule mode: 'Full', 'Reduced', 'Manual', or 'Blocked'.
$script:dmo_ScheduleMode = $null
# ShellPurge_BatchLog.batch_id for the current batch.
$script:dmo_CurrentBatchId = $null
# Start timestamp of the current batch.
$script:dmo_BatchStartTime = $null
# True when -BatchSize was supplied (forces Manual sizing).
$script:dmo_ManualBatchSize = $false
# Teams alerting on/off (from GlobalConfig).
$script:dmo_AlertingEnabled = $false
# Resolved wrkgrp_id for WFAPURGE (cached across batches).
$script:dmo_PurgeWorkgroupId = $null
# Whether the exclusion log has been loaded into the target temp table.
$script:dmo_ExclusionsLoaded = $false
# Running row-delete count for the current batch.
$script:dmo_TotalDeleted = 0
# Tables successfully processed this batch.
$script:dmo_TablesProcessed = 0
# Tables skipped this batch.
$script:dmo_TablesSkipped = 0
# Tables that failed this batch.
$script:dmo_TablesFailed = 0
# Consumer ids selected for the current batch.
$script:dmo_BatchConsumerIds = @()
# Full consumer data for the current batch ConsumerLog write.
$script:dmo_BatchConsumerData = @()
# Total batches run this session.
$script:dmo_TotalBatchesRun = 0
# Total batches that failed this session.
$script:dmo_TotalBatchesFailed = 0
# Session rollup of rows deleted.
$script:dmo_SessionTotalDeleted = 0
# Session rollup of consumers purged.
$script:dmo_SessionTotalConsumers = 0

<# ============================================================================
   FUNCTIONS: BATCH LOGGING
   ----------------------------------------------------------------------------
   Batch-log lifecycle and consumer-log writers. Each early-returns in preview
   mode ($script:XFActsExecute false) and emits a single console line describing
   the write it would have made. No database writes occur in preview mode.
   Prefix: dmo
   ============================================================================ #>

# Creates the ShellPurge_BatchLog row for a new batch and captures its batch_id.
function New-dmo_ShellBatchLogEntry {
    param(
        [string]$ScheduleMode,
        [int]$BatchSizeUsed
    )

    if (-not $script:XFActsExecute) {
        Write-Log "  [Preview] Would create ShellPurge_BatchLog row (schedule=$ScheduleMode size=$BatchSizeUsed)" "INFO"
        return
    }

    try {
        $result = Get-SqlData -Query @"
            INSERT INTO DmOps.ShellPurge_BatchLog
                (schedule_mode, batch_size_used, status, executed_by)
            OUTPUT INSERTED.batch_id
            VALUES ('$ScheduleMode', $BatchSizeUsed, 'Running', SUSER_SNAME())
"@
        $script:dmo_CurrentBatchId = [long]$result.batch_id
        Write-Log "  Batch log created: batch_id = $($script:dmo_CurrentBatchId)" "INFO"
    }
    catch {
        Write-Log "  Failed to create batch log: $($_.Exception.Message)" "WARN"
        $script:dmo_CurrentBatchId = $null
    }
}

# Finalizes the current ShellPurge_BatchLog row with counts, duration, and status.
function Update-dmo_ShellBatchLogEntry {
    param(
        [string]$Status,
        [string]$ErrorMessage = $null
    )

    if (-not $script:XFActsExecute) {
        Write-Log "  [Preview] Would finalize ShellPurge_BatchLog (status=$Status consumer_count=$($script:dmo_BatchConsumerIds.Count) rows=$($script:dmo_TotalDeleted))" "INFO"
        return
    }

    if (-not $script:dmo_CurrentBatchId) { return }

    $escapedError = if ($ErrorMessage) { $ErrorMessage.Replace("'", "''").Substring(0, [Math]::Min($ErrorMessage.Length, 2000)) } else { $null }
    $errorClause = if ($escapedError) { "'$escapedError'" } else { "NULL" }

    $durationMs = [int]((Get-Date) - $script:dmo_BatchStartTime).TotalMilliseconds

    try {
        Invoke-SqlNonQuery -Query @"
            UPDATE DmOps.ShellPurge_BatchLog
            SET batch_end_dttm = GETDATE(),
                consumer_count = $($script:dmo_BatchConsumerIds.Count),
                total_rows_deleted = $($script:dmo_TotalDeleted),
                tables_processed = $($script:dmo_TablesProcessed),
                tables_skipped = $($script:dmo_TablesSkipped),
                tables_failed = $($script:dmo_TablesFailed),
                duration_ms = $durationMs,
                status = '$Status',
                error_message = $errorClause
            WHERE batch_id = $($script:dmo_CurrentBatchId)
"@ -Timeout 30 | Out-Null
    }
    catch {
        Write-Log "  Failed to update batch log: $($_.Exception.Message)" "WARN"
    }
}

# Bulk-inserts ShellPurge_ConsumerLog rows for every consumer purged in the batch.
function Write-dmo_ShellConsumerLog {
    param()

    if (-not $script:XFActsExecute) {
        if ($script:dmo_BatchConsumerData.Count -gt 0) {
            Write-Log "  [Preview] Would write $($script:dmo_BatchConsumerData.Count) ShellPurge_ConsumerLog rows" "INFO"
        }
        return
    }

    if (-not $script:dmo_CurrentBatchId -or $script:dmo_BatchConsumerData.Count -eq 0) { return }

    try {
        for ($i = 0; $i -lt $script:dmo_BatchConsumerData.Count; $i += 900) {
            $batch = $script:dmo_BatchConsumerData[$i..[Math]::Min($i + 899, $script:dmo_BatchConsumerData.Count - 1)]
            $valuesClause = ($batch | ForEach-Object {
                "($($script:dmo_CurrentBatchId), $($_.cnsmr_id), '$($_.cnsmr_idntfr_agncy_id)')"
            }) -join ",`n                "

            Invoke-SqlNonQuery -Query @"
                INSERT INTO DmOps.ShellPurge_ConsumerLog
                    (batch_id, cnsmr_id, cnsmr_idntfr_agncy_id)
                VALUES
                    $valuesClause
"@ -Timeout 120 | Out-Null
        }

        Write-Log "  Consumer log: $($script:dmo_BatchConsumerData.Count) records written" "SUCCESS"
    }
    catch {
        Write-Log "  Failed to write consumer log: $($_.Exception.Message)" "WARN"
    }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   The batch loop: resolve schedule and target, select consumers, run the
   FK-ordered delete sequence via the shared engine, finalize the batch log,
   and emit the session summary.
   Prefix: (none)
   ============================================================================ #>

$scriptStart = Get-Date

Write-ConsoleBanner "xFACts DM Shell Purge - Consumer-Level"

# -- STEP 1: Load Configuration & Pre-Flight Checks --

Write-Log "--- Step 1: Configuration ---"

# -- Abort flag check (overrides everything) --

if (Test-dmo_AbortFlag -Category 'ShellPurge' -SettingName 'shell_purge_abort') {
    Write-Log "Shell purge abort flag is set - exiting immediately" "WARN"
    exit 0
}

# -- Target instance --

if ([string]::IsNullOrEmpty($TargetInstance)) {
    $configResult = Get-SqlData -Query @"
        SELECT setting_value FROM dbo.GlobalConfig
        WHERE module_name = 'DmOps' AND category = 'ShellPurge'
          AND setting_name = 'target_instance' AND is_active = 1
"@
    if ($configResult) {
        $script:dmo_TargetServer = $configResult.setting_value
    } else {
        Write-Log "No target_instance configured in GlobalConfig (DmOps.ShellPurge)" "ERROR"
        exit 1
    }
} else {
    $script:dmo_TargetServer = $TargetInstance
}

# -- ServerRegistry enable check (skip if manual target override) --

if ([string]::IsNullOrEmpty($TargetInstance)) {
    $enabledResult = Get-SqlData -Query @"
        SELECT dmops_shell_purge_enabled
        FROM dbo.ServerRegistry
        WHERE server_name = '$($script:dmo_TargetServer)'
"@
    if (-not $enabledResult -or $enabledResult.dmops_shell_purge_enabled -ne 1) {
        Write-Log "Shell purge is disabled on $($script:dmo_TargetServer) (ServerRegistry.dmops_shell_purge_enabled)" "WARN"
        exit 0
    }
}

# -- GlobalConfig settings --

$configResults = Get-SqlData -Query @"
    SELECT setting_name, setting_value FROM dbo.GlobalConfig
    WHERE module_name = 'DmOps' AND category = 'ShellPurge' AND is_active = 1
"@

$configMap = @{}
if ($configResults) {
    foreach ($row in $configResults) {
        $configMap[[string]$row.setting_name] = [string]$row.setting_value
    }
}

if ($configMap.ContainsKey('batch_size'))         { $script:dmo_BatchSizeFull = [int]$configMap['batch_size'] }
if ($configMap.ContainsKey('batch_size_reduced')) { $script:dmo_BatchSizeReduced = [int]$configMap['batch_size_reduced'] }
if ($configMap.ContainsKey('chunk_size'))         { $script:dmo_BatchChunkSize = [int]$configMap['chunk_size'] }
if ($configMap.ContainsKey('alerting_enabled'))   { $script:dmo_AlertingEnabled = $configMap['alerting_enabled'] -eq '1' }

# -- ChunkSize parameter override --

if ($ChunkSize -gt 0) { $script:dmo_BatchChunkSize = $ChunkSize }

# -- BatchSize parameter override (Manual mode) --

if ($BatchSize -gt 0) {
    $script:dmo_ManualBatchSize = $true
    $script:dmo_ScheduleMode = 'Manual'
    $activeBatchSize = $BatchSize
    Write-Log "  Manual batch size override: $BatchSize" "INFO"
} else {
    # Determine batch size from schedule
    $scheduleValue = Get-dmo_ScheduleMode -ScheduleTable 'DmOps.ShellPurge_Schedule'
    switch ($scheduleValue) {
        0 {
            $script:dmo_ScheduleMode = 'Blocked'
            Write-Log "  Schedule: BLOCKED for current hour - exiting" "WARN"
            exit 0
        }
        1 {
            $script:dmo_ScheduleMode = 'Full'
            $activeBatchSize = $script:dmo_BatchSizeFull
        }
        2 {
            $script:dmo_ScheduleMode = 'Reduced'
            $activeBatchSize = $script:dmo_BatchSizeReduced
        }
        default {
            Write-Log "  Schedule: unexpected value ($scheduleValue) - treating as blocked" "WARN"
            exit 0
        }
    }
}

Write-Log "  Target Instance  : $($script:dmo_TargetServer)"
Write-Log "  xFACts Instance  : $ServerInstance"
Write-Log "  Schedule Mode    : $($script:dmo_ScheduleMode)"
Write-Log "  Batch Size       : $activeBatchSize consumers"
Write-Log "  Chunk Size       : $($script:dmo_BatchChunkSize) rows per delete"
Write-Log "  Alerting         : $(if ($script:dmo_AlertingEnabled) { 'Enabled' } else { 'Disabled' })"
Write-Log "  Loop Mode        : $(if ($SingleBatch) { 'Single batch' } else { 'Continuous' })"
Write-Log ""

# -- STEP 2: Open Persistent Connection --

Write-Log "--- Step 2: Open Connection ---"

if (-not (Open-dmo_TargetConnection)) {
    if ($TaskId -gt 0) {
        $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs $totalMs `
            -ErrorMessage "Failed to open connection to target instance"
    }
    exit 1
}

Write-Log ""

# -- BATCH LOOP --

$continueProcessing = $true

while ($continueProcessing) {

# -- Reset per-batch counters --

$script:dmo_TotalDeleted = 0
$script:dmo_TablesProcessed = 0
$script:dmo_TablesSkipped = 0
$script:dmo_TablesFailed = 0
$script:dmo_BatchConsumerIds = @()
$script:dmo_BatchConsumerData = @()
$script:dmo_StopProcessing = $false
$script:dmo_BatchStartTime = Get-Date

$script:dmo_TotalBatchesRun++

Write-ConsoleBanner "  Batch #$($script:dmo_TotalBatchesRun) - $($script:dmo_ScheduleMode) mode ($activeBatchSize consumers)" 'DarkCyan' '-'

# -- STEP 3: Select Shell Consumers --

Write-Log "--- Step 3: Select Shell Consumers ---"

# Step 3a: Resolve WFAPURGE workgroup ID (first batch only - reuse on subsequent batches)
if (-not $script:dmo_PurgeWorkgroupId) {
    try {
        $wrkgrpResult = Invoke-dmo_TargetQuery -Query "SELECT wrkgrp_id FROM crs5_oltp.dbo.wrkgrp WHERE wrkgrp_shrt_nm = 'WFAPURGE'"
        if ($wrkgrpResult.Rows.Count -eq 0) {
            Write-Log "WFAPURGE workgroup not found in crs5_oltp - exiting" "ERROR"
            Close-dmo_TargetConnection
            exit 1
        }
        $script:dmo_PurgeWorkgroupId = [long]$wrkgrpResult.Rows[0].wrkgrp_id
        Write-Log "  WFAPURGE workgroup resolved: wrkgrp_id = $($script:dmo_PurgeWorkgroupId)" "INFO"
    }
    catch {
        Write-Log "Failed to resolve WFAPURGE workgroup: $($_.Exception.Message)" "ERROR"
        Close-dmo_TargetConnection
        exit 1
    }
}

# Step 3b: Load exception log into temp table on target connection (first batch only)
if (-not $script:dmo_ExclusionsLoaded) {
    try {
        $exclCreateCmd = $script:dmo_TargetConnection.CreateCommand()
        $exclCreateCmd.CommandText = "IF OBJECT_ID('tempdb..#shell_exclusions') IS NOT NULL DROP TABLE #shell_exclusions; CREATE TABLE #shell_exclusions (cnsmr_id BIGINT PRIMARY KEY);"
        $exclCreateCmd.CommandTimeout = 30
        $exclCreateCmd.ExecuteNonQuery() | Out-Null
        $exclCreateCmd.Dispose()

        $exclData = Get-SqlData -Query "SELECT DISTINCT cnsmr_id FROM DmOps.ShellPurge_ConsumerExceptionLog"
        $exclCount = 0
        if ($exclData) {
            $exclIds = @($exclData | ForEach-Object { [long]$_.cnsmr_id })
            $exclCount = $exclIds.Count
            for ($i = 0; $i -lt $exclIds.Count; $i += 900) {
                $batch = $exclIds[$i..[Math]::Min($i + 899, $exclIds.Count - 1)]
                $valuesClause = ($batch | ForEach-Object { "($_)" }) -join ','
                $insertCmd = $script:dmo_TargetConnection.CreateCommand()
                $insertCmd.CommandText = "INSERT INTO #shell_exclusions (cnsmr_id) VALUES $valuesClause"
                $insertCmd.CommandTimeout = 60
                $insertCmd.ExecuteNonQuery() | Out-Null
                $insertCmd.Dispose()
            }
        }

        Write-Log "  Exception log loaded: $exclCount consumers" "INFO"
        $script:dmo_ExclusionsLoaded = $true
    }
    catch {
        Write-Log "Failed to load exception log: $($_.Exception.Message)" "ERROR"
        Close-dmo_TargetConnection
        exit 1
    }
}

# Step 3c: Select eligible shell consumers
$selectStart = Get-Date

$batchQuery = @"
    SELECT TOP ($activeBatchSize) c.cnsmr_id, c.cnsmr_idntfr_agncy_id
    FROM crs5_oltp.dbo.cnsmr c
    LEFT JOIN crs5_oltp.dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
    WHERE c.wrkgrp_id = $($script:dmo_PurgeWorkgroupId)
      AND ca.cnsmr_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM #shell_exclusions e WHERE e.cnsmr_id = c.cnsmr_id)
"@

try {
    $batchResult = Invoke-dmo_TargetQuery -Query $batchQuery
}
catch {
    Write-Log "Failed to select batch: $($_.Exception.Message)" "ERROR"
    Close-dmo_TargetConnection
    exit 1
}

if ($batchResult.Rows.Count -eq 0) {
    Write-Log "No eligible shell consumers found - work complete" "INFO"
    if ($script:dmo_AlertingEnabled) {
        $remainingResult = Invoke-dmo_TargetQuery -Query @"
SELECT COUNT(*) AS Remaining
FROM crs5_oltp.dbo.cnsmr c
LEFT JOIN crs5_oltp.dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
WHERE c.wrkgrp_id = $($script:dmo_PurgeWorkgroupId) AND ca.cnsmr_id IS NULL
"@
        $remainingCount = if ($remainingResult.Rows.Count -gt 0) { [int]$remainingResult.Rows[0].Remaining } else { 0 }

        $exceptionsResult = Get-SqlData -Query "SELECT COUNT(DISTINCT cnsmr_id) AS Exceptions FROM DmOps.ShellPurge_ConsumerExceptionLog"
        $exceptionsCount = if ($exceptionsResult) { [int]$exceptionsResult[0].Exceptions } else { 0 }

        $sessionDuration = New-TimeSpan -Start $scriptStart -End (Get-Date)
        $durationFriendly = "{0}h {1}m" -f [int]$sessionDuration.TotalHours, $sessionDuration.Minutes
        $alertDate = (Get-Date).ToString("MM/dd/yyyy")
        $alertMsg = @"
**Target:** $($script:dmo_TargetServer)
**Exit reason:** Queue exhausted

**Shells purged this run:** $('{0:N0}' -f $script:dmo_SessionTotalConsumers)
**Shells remaining:** $('{0:N0}' -f $remainingCount)
**Designated exceptions (skipped):** $('{0:N0}' -f $exceptionsCount)

**Batches run:** $($script:dmo_TotalBatchesRun)
**Batches failed:** $($script:dmo_TotalBatchesFailed)
**Run duration:** $durationFriendly
"@
        Send-TeamsAlert -SourceModule 'DmOps' -AlertCategory 'INFO' `
            -Title "Shell Purge Complete - Queue Exhausted - $alertDate {{CHECK}}" `
            -Message $alertMsg -Color 'good' `
            -TriggerType 'shell_purge_complete_exhausted' `
            -TriggerValue "$alertDate-$($script:dmo_TotalBatchesRun)" | Out-Null
    }
    $continueProcessing = $false
    break
}

# Step 3d: Validate batch against exclusion tables (catch new exceptions since seed) - see header notes for reasons
$exclusionChecks = @(
    @{ Name = 'cnsmr_pymnt_jrnl';              SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj WHERE cpj.cnsmr_id = sc.cnsmr_id)" }
#    @{ Name = 'dcmnt_rqst';                    SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.dcmnt_rqst dr WHERE dr.dcmnt_rqst_send_to_entty_id = sc.cnsmr_id AND dr.dcmnt_rqst_send_to_entty_assctn_cd = 2)" }
    @{ Name = 'agnt_crdtbl_actvty';            SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.agnt_crdtbl_actvty aca WHERE aca.cnsmr_id = sc.cnsmr_id)" }
    @{ Name = 'agnt_crdtbl_actvty_via_smmry';  SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.agnt_crdtbl_actvty aca WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT sps.schdld_pymnt_smmry_id FROM crs5_oltp.dbo.schdld_pymnt_smmry sps WHERE sps.cnsmr_id = sc.cnsmr_id))" }
    @{ Name = 'agnt_crdt';                     SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.agnt_crdt ac INNER JOIN crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj ON ac.cnsmr_pymnt_jrnl_id = cpj.cnsmr_pymnt_jrnl_id WHERE cpj.cnsmr_id = sc.cnsmr_id)" }
    @{ Name = 'bnkrptcy';                      SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.bnkrptcy b WHERE b.cnsmr_id = sc.cnsmr_id)" }
    @{ Name = 'schdld_pymnt_smmry';            SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.schdld_pymnt_smmry sps WHERE sps.cnsmr_id = sc.cnsmr_id)" }
    @{ Name = 'sspns_unresolved_cross_consumer'; SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci INNER JOIN crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn sci ON stci.sspns_trnsctn_cnsmr_idntfr_id = sci.sspns_trnsctn_cnsmr_idntfr_id INNER JOIN crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj ON cpj.sspns_cnsmr_imprt_trnsctn_id = sci.sspns_cnsmr_imprt_trnsctn_id WHERE stci.cnsmr_id = sc.cnsmr_id AND cpj.cnsmr_id != stci.cnsmr_id AND sci.sspns_trnsctn_stts_cd NOT IN (3, 5, 7, 10))" }
)

try {
    # Load batch into temp table for exclusion checks
    $createCheckSQL = "IF OBJECT_ID('tempdb..#shell_exclusion_check') IS NOT NULL DROP TABLE #shell_exclusion_check; CREATE TABLE #shell_exclusion_check (cnsmr_id BIGINT PRIMARY KEY, cnsmr_idntfr_agncy_id VARCHAR(50));"
    $cmd = $script:dmo_TargetConnection.CreateCommand()
    $cmd.CommandText = $createCheckSQL
    $cmd.CommandTimeout = 30
    $cmd.ExecuteNonQuery() | Out-Null
    $cmd.Dispose()

    # Populate from batch result
    for ($i = 0; $i -lt $batchResult.Rows.Count; $i += 900) {
        $endIdx = [Math]::Min($i + 899, $batchResult.Rows.Count - 1)
        $valuesClause = ($batchResult.Rows[$i..$endIdx] | ForEach-Object {
            "($([long]$_.cnsmr_id), '$([string]$_.cnsmr_idntfr_agncy_id)')"
        }) -join ','
        $insertCmd = $script:dmo_TargetConnection.CreateCommand()
        $insertCmd.CommandText = "INSERT INTO #shell_exclusion_check (cnsmr_id, cnsmr_idntfr_agncy_id) VALUES $valuesClause"
        $insertCmd.CommandTimeout = 30
        $insertCmd.ExecuteNonQuery() | Out-Null
        $insertCmd.Dispose()
    }

    # Run each exclusion check - log and remove any new discoveries
    $newExclusions = New-Object System.Collections.Generic.List[long]

    foreach ($excl in $exclusionChecks) {
        $exclResult = Invoke-dmo_TargetQuery -Query $excl.SQL
        if ($exclResult.Rows.Count -gt 0) {
            Write-Log "    New exception: $($exclResult.Rows.Count) consumers have $($excl.Name) data" "WARN"
            foreach ($exclRow in $exclResult.Rows) {
                $exclCnsmrId = [long]$exclRow.cnsmr_id
                $exclAgencyId = [string]$exclRow.cnsmr_idntfr_agncy_id
                if (-not $newExclusions.Contains($exclCnsmrId)) {
                    $newExclusions.Add($exclCnsmrId)
                }
                # Log to ConsumerExceptionLog (xFACts DB via platform wrapper).
                # Skipped in preview mode - exception identification still runs above
                # for accurate reporting, but no audit writes occur.
                if ($script:XFActsExecute) {
                    Invoke-SqlNonQuery -Query @"
                        IF NOT EXISTS (SELECT 1 FROM DmOps.ShellPurge_ConsumerExceptionLog WHERE cnsmr_id = $exclCnsmrId AND exception_reason = '$($excl.Name)')
                        INSERT INTO DmOps.ShellPurge_ConsumerExceptionLog (cnsmr_id, cnsmr_idntfr_agncy_id, exception_reason)
                        VALUES ($exclCnsmrId, '$exclAgencyId', '$($excl.Name)')
"@ -Timeout 30 | Out-Null
                }

                # Also add to #shell_exclusions on target so subsequent batches skip this consumer.
                # This is session-private temp-table state - safe to do in preview mode and
                # required so subsequent count queries reflect the post-validation batch composition.
                try {
                    $addExclCmd = $script:dmo_TargetConnection.CreateCommand()
                    $addExclCmd.CommandText = "IF NOT EXISTS (SELECT 1 FROM #shell_exclusions WHERE cnsmr_id = $exclCnsmrId) INSERT INTO #shell_exclusions (cnsmr_id) VALUES ($exclCnsmrId)"
                    $addExclCmd.CommandTimeout = 10
                    $addExclCmd.ExecuteNonQuery() | Out-Null
                    $addExclCmd.Dispose()
                } catch { }
            }
        }
    }

    if ($newExclusions.Count -gt 0) {
        if ($script:XFActsExecute) {
            Write-Log "  Logged $($newExclusions.Count) new exception(s) to ShellPurge_ConsumerExceptionLog" "INFO"
        } else {
            Write-Log "  [Preview] Would log $($newExclusions.Count) new exception(s) to ShellPurge_ConsumerExceptionLog" "INFO"
        }
    }
}
catch {
    Write-Log "Failed during exception validation: $($_.Exception.Message)" "WARN"
    # Non-fatal - proceed with the batch as selected, exclusions are a safety net
}

# Build final consumer lists (excluding any newly discovered exceptions)
$script:dmo_BatchConsumerIds = New-Object System.Collections.Generic.List[long]
$script:dmo_BatchConsumerData = New-Object System.Collections.Generic.List[PSObject]

foreach ($row in $batchResult.Rows) {
    $cid = [long]$row.cnsmr_id
    if ($newExclusions.Contains($cid)) { continue }
    $script:dmo_BatchConsumerIds.Add($cid)
    $script:dmo_BatchConsumerData.Add([PSCustomObject]@{
        cnsmr_id              = $cid
        cnsmr_idntfr_agncy_id = [string]$row.cnsmr_idntfr_agncy_id
    })
}

if ($script:dmo_BatchConsumerIds.Count -eq 0) {
    Write-Log "All batch candidates were excepted - retrying next batch" "WARN"
    continue
}

$totalSelectMs = [int]((Get-Date) - $selectStart).TotalMilliseconds
Write-Log "  Selected $($script:dmo_BatchConsumerIds.Count) shell consumers (${totalSelectMs}ms)" "INFO"
Write-Log ""

# -- Create batch log entry --

New-dmo_ShellBatchLogEntry -ScheduleMode $script:dmo_ScheduleMode -BatchSizeUsed $activeBatchSize

# -- Write consumer log --

Write-dmo_ShellConsumerLog

# -- STEP 4: Create Temp Tables --

Write-Log "--- Step 4: Load Batch ID Temp Tables ---"

$createTableSQL = @"
    IF OBJECT_ID('tempdb..#shell_batch_consumers') IS NOT NULL DROP TABLE #shell_batch_consumers;
    CREATE TABLE #shell_batch_consumers (cnsmr_id BIGINT PRIMARY KEY);
"@

try {
    $cmd = $script:dmo_TargetConnection.CreateCommand()
    $cmd.CommandText = $createTableSQL
    $cmd.CommandTimeout = 30
    $cmd.ExecuteNonQuery() | Out-Null
    $cmd.Dispose()

    for ($i = 0; $i -lt $script:dmo_BatchConsumerIds.Count; $i += 900) {
        $batch = $script:dmo_BatchConsumerIds[$i..[Math]::Min($i + 899, $script:dmo_BatchConsumerIds.Count - 1)]
        $valuesClause = ($batch | ForEach-Object { "($_)" }) -join ','
        $insertCmd = $script:dmo_TargetConnection.CreateCommand()
        $insertCmd.CommandText = "INSERT INTO #shell_batch_consumers (cnsmr_id) VALUES $valuesClause"
        $insertCmd.CommandTimeout = 30
        $insertCmd.ExecuteNonQuery() | Out-Null
        $insertCmd.Dispose()
    }

    Write-Log "  Temp table loaded: $($script:dmo_BatchConsumerIds.Count) consumers" "SUCCESS"
}
catch {
    Write-Log "Failed to create temp tables: $($_.Exception.Message)" "ERROR"
    Update-dmo_ShellBatchLogEntry -Status 'Failed' -ErrorMessage "Temp table creation failed: $($_.Exception.Message)"
    Close-dmo_TargetConnection
    exit 1
}

# -- Pre-materialize intermediate ID tables --

$materializeSQL = @"
    IF OBJECT_ID('tempdb..#shell_pymnt_instrmnt_ids') IS NOT NULL DROP TABLE #shell_pymnt_instrmnt_ids;
    SELECT cnsmr_pymnt_instrmnt_id INTO #shell_pymnt_instrmnt_ids
    FROM crs5_oltp.dbo.cnsmr_pymnt_instrmnt
    WHERE cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers);
    CREATE CLUSTERED INDEX CIX ON #shell_pymnt_instrmnt_ids (cnsmr_pymnt_instrmnt_id);

    IF OBJECT_ID('tempdb..#shell_pymnt_jrnl_ids') IS NOT NULL DROP TABLE #shell_pymnt_jrnl_ids;
    SELECT cnsmr_pymnt_jrnl_id INTO #shell_pymnt_jrnl_ids
    FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl
    WHERE cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers);
    CREATE CLUSTERED INDEX CIX ON #shell_pymnt_jrnl_ids (cnsmr_pymnt_jrnl_id);

    IF OBJECT_ID('tempdb..#shell_cntct_trnsctn_ids') IS NOT NULL DROP TABLE #shell_cntct_trnsctn_ids;
    SELECT cnsmr_cntct_trnsctn_log_id INTO #shell_cntct_trnsctn_ids
    FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log
    WHERE cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers);
    CREATE CLUSTERED INDEX CIX ON #shell_cntct_trnsctn_ids (cnsmr_cntct_trnsctn_log_id);

    IF OBJECT_ID('tempdb..#shell_smmry_ids') IS NOT NULL DROP TABLE #shell_smmry_ids;
    SELECT schdld_pymnt_smmry_id INTO #shell_smmry_ids
    FROM crs5_oltp.dbo.schdld_pymnt_smmry
    WHERE cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers);
    CREATE CLUSTERED INDEX CIX ON #shell_smmry_ids (schdld_pymnt_smmry_id);

    IF OBJECT_ID('tempdb..#shell_ar_log_ids') IS NOT NULL DROP TABLE #shell_ar_log_ids;
    SELECT cnsmr_accnt_ar_log_id INTO #shell_ar_log_ids
    FROM crs5_oltp.dbo.cnsmr_accnt_ar_log
    WHERE cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers);
    CREATE CLUSTERED INDEX CIX ON #shell_ar_log_ids (cnsmr_accnt_ar_log_id);

    SELECT
        (SELECT COUNT(*) FROM #shell_pymnt_instrmnt_ids) AS instrmnt_count,
        (SELECT COUNT(*) FROM #shell_pymnt_jrnl_ids) AS jrnl_count,
        (SELECT COUNT(*) FROM #shell_cntct_trnsctn_ids) AS cntct_count,
        (SELECT COUNT(*) FROM #shell_smmry_ids) AS smmry_count,
        (SELECT COUNT(*) FROM #shell_ar_log_ids) AS ar_log_count;
"@

try {
    $cmd = $script:dmo_TargetConnection.CreateCommand()
    $cmd.CommandText = $materializeSQL
    $cmd.CommandTimeout = 120
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $countTable = New-Object System.Data.DataTable
    [void]$adapter.Fill($countTable)
    $cmd.Dispose()
    $adapter.Dispose()

    $instrmntCount = [long]$countTable.Rows[0].instrmnt_count
    $jrnlCount = [long]$countTable.Rows[0].jrnl_count
    $cntctCount = [long]$countTable.Rows[0].cntct_count
    $smmryCount = [long]$countTable.Rows[0].smmry_count
    $arLogCount = [long]$countTable.Rows[0].ar_log_count

    Write-Log "  Intermediate ID tables materialized:" "SUCCESS"
    Write-Log "    Payment instruments: $instrmntCount" "INFO"
    Write-Log "    Payment journals:    $jrnlCount" "INFO"
    Write-Log "    Contact txn logs:    $cntctCount" "INFO"
    Write-Log "    Sched pymnt smmry:   $smmryCount" "INFO"
    Write-Log "    AR Log entries:      $arLogCount" "INFO"
}
catch {
    Write-Log "Failed to create intermediate temp tables: $($_.Exception.Message)" "ERROR"
    Update-dmo_ShellBatchLogEntry -Status 'Failed' -ErrorMessage "Intermediate temp table creation failed: $($_.Exception.Message)"
    Close-dmo_TargetConnection
    exit 1
}

Write-Log ""

# -- STEP 5: Execute Consumer-Level Deletions --

Write-Log "--- Step 5: Execute Consumer-Level Deletions ---"
Write-Log ""

$script:dmo_StopProcessing = $false

$wCnsmr       = "cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"
$wCntctLog    = "cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM #shell_cntct_trnsctn_ids)"
$wInstrmnt    = "cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
$wJrnl        = "cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
$wSmmry       = "schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
$wArLog       = "cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"

# -- Phase 1: Consumer-Level UDEF Tables (Dynamic Discovery) --

Write-Log "  Phase 1: Consumer-Level UDEF Tables (dynamic)" "INFO"

try {
    $udefCnsmrResult = Invoke-dmo_TargetQuery -Query @"
        SELECT t.name AS table_name
        FROM sys.tables t
        INNER JOIN sys.columns c ON t.object_id = c.object_id
        WHERE t.name LIKE 'UDEF%'
          AND c.name = 'cnsmr_id'
        ORDER BY t.name
"@
    $udefCnsmrTables = New-Object System.Collections.Generic.List[string]
    foreach ($row in $udefCnsmrResult.Rows) {
        $udefCnsmrTables.Add([string]$row.table_name)
    }
    Write-Log "    Discovered $($udefCnsmrTables.Count) consumer-level UDEF tables" "INFO"
}
catch {
    Write-Log "  Failed to discover UDEF tables: $($_.Exception.Message)" "ERROR"
    $script:dmo_StopProcessing = $true
}

if (-not $script:dmo_StopProcessing) {
    $udefOrder = 0
    foreach ($udefTable in $udefCnsmrTables) {
        $udefOrder++
        Step-dmo_Delete @{Order="U$udefOrder"; TableName=$udefTable; WhereClause=$wCnsmr}
    }
}

Write-Log ""

# -- Phase 2: Consumer-Level Tables (FK-ordered, all gaps filled) --

# Redesigned from sys.foreign_keys chain analysis against cnsmr terminal table.
# 101 steps: 34 new FK-required tables, FK ordering corrected, 3 exclusion-controlled chains.
# Tables marked [NEW] were not in the previous sequence.
# Tables marked [EXCL] are exclusion-controlled - currently no-ops while exclusions are active.
Write-Log "  Phase 2: Consumer-Level Tables" "INFO"

# -- Simple direct cnsmr_id tables (no FK children, no ordering concerns) --

Step-dmo_Delete @{Order=1; TableName='asst'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=2; TableName='attrny'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=3; TableName='cnsmr_addrss'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=4; TableName='cnsmr_Cmmnt'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=5; TableName='cnsmr_crdt'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=6; TableName='cnsmr_fee_spprss_cnfg'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=7; TableName='cnsmr_Fnncl'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=8; TableName='cnsmr_rndm_nmbr'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=9; TableName='cnsmr_Rvw_rqst'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=10; TableName='cnsmr_Tag'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=11; TableName='cnsmr_Wrk_actn'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=12; TableName='decsd'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=13; TableName='dfrrd_cnsmr'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=14; TableName='emplyr'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=15; TableName='ivr_call_log'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=16; TableName='job_skptrc_cnsmr'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=17; TableName='job_skptrc_instnc_log'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=18; TableName='strtgy_log'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=19; TableName='usr_rmndr'; WhereClause="usr_rmndr_cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"}
Step-dmo_Delete @{Order=20; TableName='cnsmr_accnt_spplmntl_info'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=21; TableName='cb_rpt_assctd_cnsmr_data'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=22; TableName='cb_rpt_base_data'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=23; TableName='cb_rpt_emplyr_data'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=24; TableName='cb_rpt_rqst_dtl'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=25; TableName='job_file'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=26; TableName='cnsmr_accnt_ownrs'; WhereClause=$wCnsmr}

# -- bal_rdctn_plan chain (FK: stpdwn -> plan -> cnsmr) --

Step-dmo_Delete @{Order=27; TableName='bal_rdctn_plan_stpdwn'; WhereClause="bal_rdctn_plan_id IN (SELECT bal_rdctn_plan_id FROM crs5_oltp.dbo.bal_rdctn_plan WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=28; TableName='bal_rdctn_plan'; WhereClause=$wCnsmr}

# -- ca_case chain (FK: children -> ca_case -> cnsmr) --

Step-dmo_Delete @{Order=29; TableName='ca_case_accnt_assctn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=30; TableName='ca_case_ar_log_assctn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=31; TableName='ca_case_bal_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=32; TableName='ca_case_cntct_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=33; TableName='ca_case_lck_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=34; TableName='ca_case_strtgy_log'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=35; TableName='ca_case_tag'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=36; TableName='dfrrd_ca_case'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=37; TableName='wrk_lst_case_cache'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=38; TableName='wrkgrp_scan_lst_case_cache'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=39; TableName='ca_case'; WhereClause=$wCnsmr}

# -- cmpgn chain (FK: dialer_trnsctn_log -> cmpgn_trnsctn_log -> cnsmr, cmpgn_cache -> cnsmr_Phn) --

Step-dmo_Delete @{Order=40; TableName='dialer_trnsctn_log'; WhereClause="cmpgn_trnsctn_log_id IN (SELECT cmpgn_trnsctn_log_id FROM crs5_oltp.dbo.cmpgn_trnsctn_log WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=41; TableName='cmpgn_trnsctn_log'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=42; TableName='cmpgn_cache'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=43; TableName='cnsmr_Phn'; WhereClause=$wCnsmr}

# -- cnsmr_accnt_ar_log chain - contact log children BEFORE ar_log --

Step-dmo_Delete @{Order=44; TableName='cnsmr_cntct_addrs_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
Step-dmo_Delete @{Order=45; TableName='cnsmr_cntct_phn_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
Step-dmo_Delete @{Order=46; TableName='cnsmr_cntct_email_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
Step-dmo_Delete @{Order=47; TableName='cnsmr_cntct_trnsctn_log'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=48; TableName='cnsmr_task_itm_cnsmr_accnt_ar_log_assctn'; WhereClause=$wArLog}

# -- agnt_crdtbl_actvty chain via ar_log - must clear before cnsmr_accnt_ar_log --

Step-dmo_JoinDelete @{
    Order = 49; TableName = 'agnt_crdtbl_actvty_spprssn'
    DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
    PassDescription = 'Pass 1: via ar_log'
}

Step-dmo_JoinDelete @{
    Order = 50; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
    DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
    PassDescription = 'Pass 1: via ar_log'
}

Step-dmo_JoinDelete @{
    Order = 51; TableName = 'agnt_crdtbl_actvty'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
    PassDescription = 'Pass 1: via ar_log'
}

Step-dmo_Delete @{Order=52; TableName='crdtr_srvc_evnt'; WhereClause=$wCnsmr; PassDescription='before ar_log (FK dependency)'}
Step-dmo_Delete @{Order=53; TableName='cnsmr_accnt_ar_log'; WhereClause=$wArLog}

# -- cnsmr_task_itm (must come after ar_log association at 48) --

Step-dmo_Delete @{Order=54; TableName='cnsmr_task_itm'; WhereClause=$wCnsmr}

# -- invc_crrctn chain (FK: dtl children -> parent -> cnsmr) --

Step-dmo_Delete @{Order=55; TableName='invc_crrctn_dtl_stgng'; WhereClause="invc_crrctn_trnsctn_stgng_id IN (SELECT invc_crrctn_trnsctn_stgng_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn_stgng WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=56; TableName='invc_crrctn_trnsctn_stgng'; WhereClause=$wCnsmr}
Step-dmo_Delete @{Order=57; TableName='invc_crrctn_dtl'; WhereClause="invc_crrctn_trnsctn_id IN (SELECT invc_crrctn_trnsctn_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=58; TableName='invc_crrctn_trnsctn'; WhereClause=$wCnsmr}

# -- jdgmnt chain (FK: jdgmnt_addtnl_info -> jdgmnt -> cnsmr) --

Step-dmo_Delete @{Order=59; TableName='jdgmnt_addtnl_info'; WhereClause="jdgmnt_id IN (SELECT jdgmnt_id FROM crs5_oltp.dbo.jdgmnt WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=60; TableName='jdgmnt'; WhereClause=$wCnsmr}

# -- Rltd_Prsn chain (FK: rltd_prsn_tag -> Rltd_Prsn -> cnsmr) --

Step-dmo_Delete @{Order=61; TableName='rltd_prsn_tag'; WhereClause="rltd_prsn_id IN (SELECT rltd_prsn_id FROM crs5_oltp.dbo.Rltd_Prsn WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=62; TableName='Rltd_Prsn'; WhereClause=$wCnsmr}

# -- cnsmr_chck_rqst chain (FK: children -> cnsmr_chck_rqst -> cnsmr) --

Step-dmo_Delete @{Order=63; TableName='cnsmr_accnt_bckt_chck_rqst'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=64; TableName='cnsmr_chck_btch_log'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=65; TableName='cnsmr_chck_rqst'; WhereClause=$wCnsmr}

# -- notice_rqst (must come before schdld_pymnt_instnc which has FK to notice_rqst) --

Step-dmo_Delete @{Order=66; TableName='notice_rqst'; WhereClause=$wCnsmr}

# -- sttlmnt_offr chain - must come before cnsmr_pymnt_instrmnt AND schdld_pymnt_smmry --

Step-dmo_Delete @{Order=67; TableName='sttlmnt_offr_accnt_assctn'; WhereClause="sttlmnt_offr_id IN (SELECT sttlmnt_offr_id FROM crs5_oltp.dbo.sttlmnt_offr WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=68; TableName='sttlmnt_offr_systm_dtl'; WhereClause="sttlmnt_offr_id IN (SELECT sttlmnt_offr_id FROM crs5_oltp.dbo.sttlmnt_offr WHERE $wCnsmr)"}
Step-dmo_Delete @{Order=69; TableName='sttlmnt_offr'; WhereClause=$wCnsmr}

# -- epp chain (FK: children -> epp_pymnt_typ_cnfg -> cnsmr_pymnt_instrmnt) --

Step-dmo_Delete @{Order=70; TableName='epp_cmmnctn_log'; WhereClause="epp_pymnt_typ_cnfg_id IN (SELECT epp_pymnt_typ_cnfg_id FROM crs5_oltp.dbo.epp_pymnt_typ_cnfg WHERE $wInstrmnt)"}
Step-dmo_Delete @{Order=71; TableName='epp_vrfctn_rspns'; WhereClause="epp_pymnt_typ_cnfg_id IN (SELECT epp_pymnt_typ_cnfg_id FROM crs5_oltp.dbo.epp_pymnt_typ_cnfg WHERE $wInstrmnt)"}
Step-dmo_Delete @{Order=72; TableName='epp_pymnt_typ_cnfg'; WhereClause=$wInstrmnt}
Step-dmo_Delete @{Order=73; TableName='epp_pymnt_rspns'; WhereClause=$wCnsmr}

# -- cpm_pm_assctn (FK to both cnsmr_pymnt_instrmnt AND cnsmr_pymnt_mthd) --

Step-dmo_Delete @{Order=74; TableName='cpm_pm_assctn'; WhereClause=$wInstrmnt}

# -- Scheduled payment children (before schdld_pymnt_instnc) --

Step-dmo_Delete @{Order=75; TableName='pymnt_schdl_notice_rqst_assctn'; WhereClause="schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE $wSmmry)"}
Step-dmo_Delete @{Order=76; TableName='schdld_pymnt_cnsmr_accnt_assctn'; WhereClause=$wSmmry; PassDescription='via smmry'}

# -- Agent credit chain [EXCL] - must clear before cnsmr_pymnt_jrnl --

# agnt_crdt has FK on cnsmr_pymnt_jrnl_id
Step-dmo_Delete @{Order=77; TableName='agnt_crdt_spprssn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE $wJrnl)"; PassDescription='[EXCL] via pymnt_jrnl'}
Step-dmo_Delete @{Order=78; TableName='agnt_crdtbl_actvty_crdt_assctn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE $wJrnl)"; PassDescription='[EXCL] Pass 1: via pymnt_jrnl'}
Step-dmo_Delete @{Order=79; TableName='agnt_crdt'; WhereClause=$wJrnl; PassDescription='[EXCL] via pymnt_jrnl'}

# -- Payment journal children (must clear before cnsmr_pymnt_jrnl) --

Step-dmo_Delete @{Order=80; TableName='cnsmr_chck_trnsctn'; WhereClause=$wJrnl; PassDescription='via pymnt_jrnl'}

Step-dmo_JoinDelete @{
    Order = 81; TableName = 'cpj_rvrsl_assctn'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.cpj_rvrsl_assctn WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cpj_rvrsl_assctn WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
    PassDescription = 'via pymnt_jrnl'
}

# cnsmr_pymnt_jrnl_schdld_pymnt_instnc: FK to BOTH cnsmr_pymnt_jrnl AND schdld_pymnt_instnc
Step-dmo_JoinDelete @{
    Order = 82; TableName = 'cnsmr_pymnt_jrnl_schdld_pymnt_instnc'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
    PassDescription = 'Pass 1: via pymnt_jrnl'
}

Step-dmo_JoinDelete @{
    Order = 83; TableName = 'cnsmr_pymnt_jrnl_schdld_pymnt_instnc'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"
    PassDescription = 'Pass 2: via smmry'
}

# -- cnsmr_pymnt_jrnl - all children now cleared --

Step-dmo_Delete @{Order=84; TableName='cnsmr_pymnt_jrnl'; WhereClause=$wCnsmr}

# -- schdld_pymnt_instnc - cnsmr_pymnt_jrnl_schdld_pymnt_instnc cleared above --

Step-dmo_Delete @{Order=85; TableName='schdld_pymnt_instnc'; WhereClause=$wSmmry; PassDescription='via smmry'}

# -- Suspense: NULL resolved cross-consumer payment journal references --

# When consumer A merges into consumer B, the payment journal moves to B but the
# sspns_cnsmr_imprt_trnsctn stays on A. The FK reference from B's cnsmr_pymnt_jrnl
# back to A's suspense record is a historical breadcrumb. For resolved suspense
# (status 3=RESOLVED, 5=RESOLVED_AS_REFUND, 7=RESOLVED_AS_ESCHEAT, 10=MULTI_RESOLVED),
# we NULL the reference to allow deletion. Unresolved cross-consumer suspense is
# caught by the exclusion check and never reaches this point.
Step-dmo_Update @{
    Order = 86; TableName = 'cnsmr_pymnt_jrnl'
    UpdateStatement = "UPDATE cpj SET cpj.sspns_cnsmr_imprt_trnsctn_id = NULL FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj WHERE cpj.sspns_cnsmr_imprt_trnsctn_id IN (SELECT sci.sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn sci INNER JOIN crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci ON sci.sspns_trnsctn_cnsmr_idntfr_id = stci.sspns_trnsctn_cnsmr_idntfr_id WHERE stci.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers) AND sci.sspns_trnsctn_stts_cd IN (3, 5, 7, 10))"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj WHERE cpj.sspns_cnsmr_imprt_trnsctn_id IN (SELECT sci.sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn sci INNER JOIN crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci ON sci.sspns_trnsctn_cnsmr_idntfr_id = stci.sspns_trnsctn_cnsmr_idntfr_id WHERE stci.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers) AND sci.sspns_trnsctn_stts_cd IN (3, 5, 7, 10))"
    PassDescription = 'NULL resolved suspense refs on merged consumers'
}

# -- Suspense chain - must come after cnsmr_pymnt_jrnl (which has FK to sspns_cnsmr_imprt_trnsctn) --

# Pass 1: via payment instrument
Step-dmo_Delete @{Order=87; TableName='sspns_cnsmr_trnsctn_log'; WhereClause="sspns_cnsmr_imprt_trnsctn_id IN (SELECT sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE $wInstrmnt)"; PassDescription='Pass 1: via pymnt_instrmnt'}

Step-dmo_JoinDelete @{
    Order = 88; TableName = 'sspns_cnsmr_imprt_trnsctn'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
    PassDescription = 'Pass 1: via pymnt_instrmnt'
}

# Pass 2: via sspns_trnsctn_cnsmr_idntfr - catches rows with NULL cnsmr_pymnt_instrmnt_id
Step-dmo_Delete @{Order=89; TableName='sspns_cnsmr_trnsctn_log'; WhereClause="sspns_cnsmr_imprt_trnsctn_id IN (SELECT sci.sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn sci INNER JOIN crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci ON sci.sspns_trnsctn_cnsmr_idntfr_id = stci.sspns_trnsctn_cnsmr_idntfr_id WHERE stci.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers))"; PassDescription='Pass 2: via sspns_trnsctn_cnsmr_idntfr'}

Step-dmo_Delete @{Order=90; TableName='sspns_cnsmr_imprt_trnsctn'; WhereClause="sspns_trnsctn_cnsmr_idntfr_id IN (SELECT sspns_trnsctn_cnsmr_idntfr_id FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr WHERE $wCnsmr)"; PassDescription='Pass 2: via sspns_trnsctn_cnsmr_idntfr'}

# -- Agent creditable activity chain [EXCL] - Pass 2: via direct cnsmr_id --

Step-dmo_JoinDelete @{
    Order = 91; TableName = 'agnt_crdtbl_actvty_spprssn'
    DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"
    PassDescription = '[EXCL] Pass 2: via direct cnsmr_id'
}

Step-dmo_JoinDelete @{
    Order = 92; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
    DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"
    PassDescription = '[EXCL] Pass 2: via direct cnsmr_id'
}

Step-dmo_Delete @{Order=93; TableName='agnt_crdtbl_actvty'; WhereClause=$wCnsmr; PassDescription='[EXCL] Pass 2: via direct cnsmr_id'}

# -- cnsmr_pymnt_instrmnt (now safe - ALL FK children cleared above) --

Step-dmo_Delete @{Order=94; TableName='cnsmr_pymnt_instrmnt'; WhereClause=$wCnsmr; PassDescription='Pass 1: direct'}

Step-dmo_JoinDelete @{
    Order = 95; TableName = 'cnsmr_pymnt_instrmnt'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_instrmnt WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl WHERE cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers))"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_instrmnt WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl WHERE cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers))"
    PassDescription = 'Pass 2: via pymnt_jrnl'
}

# -- cnsmr_pymnt_mthd (now safe - cpm_pm_assctn cleared at 74) --

Step-dmo_Delete @{Order=96; TableName='cnsmr_pymnt_mthd'; WhereClause=$wCnsmr}

# -- sspns_trnsctn_cnsmr_idntfr (now safe - all suspense children cleared) --

Step-dmo_Delete @{Order=97; TableName='sspns_trnsctn_cnsmr_idntfr'; WhereClause=$wCnsmr}

# -- Agent credit chain Pass 2: via schdld_pymnt_smmry --

# agnt_crdt.cnsmr_pymnt_schdl_id FK to schdld_pymnt_smmry - must clear before smmry delete
Step-dmo_Delete @{Order=98; TableName='agnt_crdt_spprssn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"; PassDescription='[EXCL] Pass 2: via smmry'}
Step-dmo_Delete @{Order=99; TableName='agnt_crdtbl_actvty_crdt_assctn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"; PassDescription='[EXCL] Pass 2: via smmry'}
Step-dmo_Delete @{Order=100; TableName='agnt_crdt'; WhereClause="cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"; PassDescription='[EXCL] Pass 2: via smmry'}

# -- agnt_crdtbl_actvty chain Pass 3: via schdld_pymnt_smmry --

# agnt_crdtbl_actvty.cnsmr_pymnt_schdl_id FK to schdld_pymnt_smmry
Step-dmo_JoinDelete @{
    Order = 101; TableName = 'agnt_crdtbl_actvty_spprssn'
    DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
    PassDescription = '[EXCL] Pass 3: via smmry'
}

Step-dmo_JoinDelete @{
    Order = 102; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
    DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
    PassDescription = '[EXCL] Pass 3: via smmry'
}

Step-dmo_Delete @{Order=103; TableName='agnt_crdtbl_actvty'; WhereClause="cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"; PassDescription='[EXCL] Pass 3: via smmry'}

# -- schdld_pymnt_smmry (now safe - all children cleared above) --

Step-dmo_Delete @{Order=104; TableName='schdld_pymnt_smmry'; WhereClause=$wSmmry}

# -- Bankruptcy chain [EXCL] --

Step-dmo_Delete @{Order=105; TableName='bnkrptcy_addtnl_info'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
Step-dmo_Delete @{Order=106; TableName='bnkrptcy_pttnr'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
Step-dmo_Delete @{Order=107; TableName='bnkrptcy_trustee'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
Step-dmo_Delete @{Order=108; TableName='bnkrptcy'; WhereClause=$wCnsmr; PassDescription='[EXCL]'}

# -- hc_payer_plan (direct cnsmr FK, no encntr dependency for shells) --

Step-dmo_Delete @{Order=109; TableName='hc_payer_plan'; WhereClause=$wCnsmr}

# -- TERMINAL: cnsmr record itself --

Step-dmo_Delete @{Order=110; TableName='cnsmr'; WhereClause=$wCnsmr}
Write-Log ""
Write-Log "  Consumer-level deletion sequence complete" "SUCCESS"

# -- Finalize batch log --

$batchStatus = if ($script:dmo_TablesFailed -gt 0) { "Failed" } else { "Success" }
$batchError = if ($script:dmo_TablesFailed -gt 0) { "One or more tables failed during delete sequence" } else { $null }
Update-dmo_ShellBatchLogEntry -Status $batchStatus -ErrorMessage $batchError

# -- Update session counters --

$script:dmo_SessionTotalDeleted += $script:dmo_TotalDeleted
$script:dmo_SessionTotalConsumers += $script:dmo_BatchConsumerIds.Count
if ($batchStatus -eq 'Failed') { $script:dmo_TotalBatchesFailed++ }

# -- Batch summary --

$batchDuration = (Get-Date) - $script:dmo_BatchStartTime
Write-Log "  Batch #$($script:dmo_TotalBatchesRun): $($script:dmo_BatchConsumerIds.Count) consumers, $($script:dmo_TotalDeleted) rows, $([math]::Round($batchDuration.TotalSeconds, 1))s - $batchStatus" "INFO"

# -- Queue Teams alert on failure --

if ($batchStatus -eq 'Failed' -and $script:dmo_AlertingEnabled) {
    Send-TeamsAlert -SourceModule 'DmOps' -AlertCategory 'WARNING' `
        -Title '{{WARN}} Shell purge batch failed - will retry next cycle' `
        -Message "**Batch:** #$($script:dmo_TotalBatchesRun) (batch_id: $($script:dmo_CurrentBatchId))`n**Target:** $($script:dmo_TargetServer)`n**Tables Failed:** $($script:dmo_TablesFailed)`n**Consumers in batch:** $($script:dmo_BatchConsumerIds.Count)`n`nThese consumers remain in shell state and will be re-selected on the next run. No action needed unless failures persist.`n`nCheck ShellPurge_BatchDetail for batch_id $($script:dmo_CurrentBatchId) for delete-step details." `
        -TriggerType 'Shell Purge Batch Failed' `
        -TriggerValue "$($script:dmo_CurrentBatchId)" | Out-Null
}
elseif ($batchStatus -eq 'Failed') {
    Write-Log "  Teams alert suppressed - alerting_enabled is off" "INFO"
}

# -- BATCH LOOP CONTINUATION CHECK --

if ($SingleBatch) {
    Write-Log "  Single batch mode - exiting loop" "INFO"
    $continueProcessing = $false
}
elseif ($batchStatus -eq 'Failed') {
    Write-Log "  Batch failed - stopping further processing" "ERROR"
    $continueProcessing = $false
}
elseif (Test-dmo_AbortFlag -Category 'ShellPurge' -SettingName 'shell_purge_abort') {
    Write-Log "  Shell purge abort flag detected - stopping after batch completion" "WARN"
    if ($script:dmo_AlertingEnabled) {
        $remainingResult = Invoke-dmo_TargetQuery -Query @"
SELECT COUNT(*) AS Remaining
FROM crs5_oltp.dbo.cnsmr c
LEFT JOIN crs5_oltp.dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
WHERE c.wrkgrp_id = $($script:dmo_PurgeWorkgroupId) AND ca.cnsmr_id IS NULL
"@
        $remainingCount = if ($remainingResult.Rows.Count -gt 0) { [int]$remainingResult.Rows[0].Remaining } else { 0 }

        $exceptionsResult = Get-SqlData -Query "SELECT COUNT(DISTINCT cnsmr_id) AS Exceptions FROM DmOps.ShellPurge_ConsumerExceptionLog"
        $exceptionsCount = if ($exceptionsResult) { [int]$exceptionsResult[0].Exceptions } else { 0 }

        $sessionDuration = New-TimeSpan -Start $scriptStart -End (Get-Date)
        $durationFriendly = "{0}h {1}m" -f [int]$sessionDuration.TotalHours, $sessionDuration.Minutes
        $alertDate = (Get-Date).ToString("MM/dd/yyyy")
        $alertMsg = @"
**Target:** $($script:dmo_TargetServer)
**Exit reason:** shell_purge_abort flag set in GlobalConfig

**Shells purged this run:** $('{0:N0}' -f $script:dmo_SessionTotalConsumers)
**Shells remaining:** $('{0:N0}' -f $remainingCount)
**Designated exceptions (skipped):** $('{0:N0}' -f $exceptionsCount)

**Batches run:** $($script:dmo_TotalBatchesRun)
**Batches failed:** $($script:dmo_TotalBatchesFailed)
**Run duration:** $durationFriendly
"@
        Send-TeamsAlert -SourceModule 'DmOps' -AlertCategory 'WARNING' `
            -Title "Shell Purge Stopped - Abort Flag Set - $alertDate {{WARN}}" `
            -Message $alertMsg -Color 'warning' `
            -TriggerType 'shell_purge_aborted' `
            -TriggerValue "$alertDate-$($script:dmo_TotalBatchesRun)" | Out-Null
    }
    $continueProcessing = $false
}
else {
    $nextScheduleValue = Get-dmo_ScheduleMode -ScheduleTable 'DmOps.ShellPurge_Schedule'
    if ($nextScheduleValue -eq 0) {
        Write-Log "  Schedule: now in BLOCKED window - stopping" "INFO"
        if ($script:dmo_AlertingEnabled) {
        $remainingResult = Invoke-dmo_TargetQuery -Query @"
SELECT COUNT(*) AS Remaining
FROM crs5_oltp.dbo.cnsmr c
LEFT JOIN crs5_oltp.dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
WHERE c.wrkgrp_id = $($script:dmo_PurgeWorkgroupId) AND ca.cnsmr_id IS NULL
"@
        $remainingCount = if ($remainingResult.Rows.Count -gt 0) { [int]$remainingResult.Rows[0].Remaining } else { 0 }

        $exceptionsResult = Get-SqlData -Query "SELECT COUNT(DISTINCT cnsmr_id) AS Exceptions FROM DmOps.ShellPurge_ConsumerExceptionLog"
        $exceptionsCount = if ($exceptionsResult) { [int]$exceptionsResult[0].Exceptions } else { 0 }

        $sessionDuration = New-TimeSpan -Start $scriptStart -End (Get-Date)
            $durationFriendly = "{0}h {1}m" -f [int]$sessionDuration.TotalHours, $sessionDuration.Minutes
            $alertDate = (Get-Date).ToString("MM/dd/yyyy")
            $alertMsg = @"
**Target:** $($script:dmo_TargetServer)
**Exit reason:** Schedule transitioned to BLOCKED

**Shells purged this run:** $('{0:N0}' -f $script:dmo_SessionTotalConsumers)
**Shells remaining:** $('{0:N0}' -f $remainingCount)
**Designated exceptions (skipped):** $('{0:N0}' -f $exceptionsCount)

**Batches run:** $($script:dmo_TotalBatchesRun)
**Batches failed:** $($script:dmo_TotalBatchesFailed)
**Run duration:** $durationFriendly
"@
            Send-TeamsAlert -SourceModule 'DmOps' -AlertCategory 'INFO' `
                -Title "Shell Purge Complete - Scheduled Cutoff - $alertDate {{CHECK}}" `
                -Message $alertMsg -Color 'good' `
                -TriggerType 'shell_purge_complete_schedule' `
                -TriggerValue "$alertDate-$($script:dmo_TotalBatchesRun)" | Out-Null
        }
        $continueProcessing = $false
    }
    else {
        # Re-read batch sizes from GlobalConfig (allows in-flight tuning)
        $refreshConfig = Get-SqlData -Query @"
            SELECT setting_name, setting_value FROM dbo.GlobalConfig
            WHERE module_name = 'DmOps' AND category = 'ShellPurge'
              AND setting_name IN ('batch_size', 'batch_size_reduced') AND is_active = 1
"@
        foreach ($cfg in $refreshConfig) {
            if ($cfg.setting_name -eq 'batch_size')         { $script:dmo_BatchSizeFull = [int]$cfg.setting_value }
            if ($cfg.setting_name -eq 'batch_size_reduced') { $script:dmo_BatchSizeReduced = [int]$cfg.setting_value }
        }

        $newMode = if ($nextScheduleValue -eq 1) { 'Full' } else { 'Reduced' }
        $newBatchSize = if ($nextScheduleValue -eq 1) { $script:dmo_BatchSizeFull } else { $script:dmo_BatchSizeReduced }

        if ($newMode -ne $script:dmo_ScheduleMode -or $newBatchSize -ne $activeBatchSize) {
            Write-Log "  Schedule/config update: $($script:dmo_ScheduleMode) ($activeBatchSize) -> $newMode ($newBatchSize)" "INFO"
            $script:dmo_ScheduleMode = $newMode
            $activeBatchSize = $newBatchSize
        }

        Start-Sleep -Seconds 2
    }
}

}

# -- CLEANUP --

Close-dmo_TargetConnection

# -- SESSION SUMMARY --

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart
$totalMs = [int]$scriptDuration.TotalMilliseconds

Write-ConsoleBanner "Session Summary"
Write-Log "  Mode            : $(if (-not $script:XFActsExecute) { 'PREVIEW' } else { 'EXECUTE' })"
Write-Log "  Target          : $($script:dmo_TargetServer)"
Write-Log "  Batches Run     : $($script:dmo_TotalBatchesRun)"
Write-Log "  Batches Failed  : $($script:dmo_TotalBatchesFailed)"
Write-Log "  Total Consumers : $($script:dmo_SessionTotalConsumers)"
if (-not $script:XFActsExecute) {
    Write-Log "  Rows to Delete  : $($script:dmo_SessionTotalDeleted)"
} else {
    Write-Log "  Rows Deleted    : $($script:dmo_SessionTotalDeleted)"
}
Write-Log "  Duration        : $([math]::Round($scriptDuration.TotalSeconds, 1))s"
Write-Console

if (-not $script:XFActsExecute) {
    Write-Console "  *** PREVIEW MODE - No changes were made ***" 'Yellow'
    Write-Console "  Run with -Execute to perform actual deletions" 'Yellow'
    Write-Console
}

# Orchestrator callback
if ($TaskId -gt 0) {
    $finalStatus = if ($script:dmo_TotalBatchesFailed -gt 0) { "FAILED" } else { "SUCCESS" }
    $outputSummary = "Batches:$($script:dmo_TotalBatchesRun) Failed:$($script:dmo_TotalBatchesFailed) Consumers:$($script:dmo_SessionTotalConsumers) Deleted:$($script:dmo_SessionTotalDeleted)"
    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}

if ($script:dmo_TotalBatchesFailed -gt 0) { exit 1 } else { exit 0 }
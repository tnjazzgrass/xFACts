<#
.SYNOPSIS
    xFACts - DM Shell Consumer Purge

.DESCRIPTION
    xFACts - DmOps.ShellPurge
    Script: Execute-DmShellPurge.ps1
    Version: Tracked in dbo.System_Metadata (component: DmOps.ShellPurge)

    Purges orphaned consumer records ("shells") from crs5_oltp. A shell is a
    consumer with no remaining cnsmr_accnt records — typically created by account
    archiving or consumer merge operations. Targets consumers in the WFAPURGE
    workgroup (populated nightly by a DM scheduled job).

    Pre-flight exclusions remove consumers that still have data in tables not
    covered by the delete sequence (cnsmr_pymnt_jrnl, dcmnt_rqst,
    agnt_crdtbl_actvty, bnkrptcy, schdld_pymnt_smmry, and optionally
    sspns_trnsctn_cnsmr_idntfr). These consumers are skipped rather than
    partially deleted.

    Delete sequence derived from Matt's sp_Delete_EmptyShell_Consumers with
    dynamic UDEF discovery and xFACts chunked delete infrastructure.

    Schedule-aware: reads DmOps.ShellPurge_Schedule to determine execution
    mode per hour (blocked/full/reduced). Checks schedule between batches.
    Emergency abort via GlobalConfig shell_purge_abort flag.

    Full audit trail: ShellPurge_BatchLog (batch summary),
    ShellPurge_BatchDetail (per-table operation detail),
    ShellPurge_ConsumerLog (every consumer purged).

    CHANGELOG
    ---------
    2026-03-24  Initial implementation

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER TargetInstance
    SQL Server instance hosting crs5_oltp to purge from.
    Default: reads from GlobalConfig DmOps.ShellPurge.target_instance.
    Override for testing against non-production environments.

.PARAMETER BatchSize
    Number of consumers per batch. Default: reads from GlobalConfig
    based on schedule mode. Override with -BatchSize for testing.
    When specified, overrides schedule-driven batch sizing.

.PARAMETER ChunkSize
    Maximum rows per DELETE operation. Larger tables are deleted in chunks
    of this size to prevent lock escalation and blocking. Default: 5000.

.PARAMETER Execute
    Perform deletions. Without this flag, runs in preview mode — shows
    what would be deleted without making changes.

.PARAMETER SingleBatch
    Run one batch only, then exit. Bypasses the batch loop and schedule
    re-check. Useful for testing and manual execution.

.PARAMETER TaskId
    Orchestrator TaskLog ID. Default 0 (manual execution).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID. Default 0 (manual execution).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
3. GlobalConfig entries required:
   - DmOps.ShellPurge.target_instance (server hosting crs5_oltp)
   - DmOps.ShellPurge.batch_size (consumers per batch, full mode)
   - DmOps.ShellPurge.batch_size_reduced (consumers per batch, reduced mode)
   - DmOps.ShellPurge.chunk_size (rows per delete chunk, default 5000)
   - DmOps.ShellPurge.shell_purge_abort (emergency shutoff, 0=normal, 1=stop)
   - DmOps.ShellPurge.alerting_enabled (1=on, 0=suppress alerts)
   - DmOps.ShellPurge.exclude_suspense (1=exclude consumers with suspense data)
4. ServerRegistry.dmops_shell_purge_enabled must be 1 on the target server.
5. DmOps.ShellPurge_Schedule must have 7 rows with hourly mode values.
6. The WFAPURGE workgroup must exist in crs5_oltp.dbo.wrkgrp.
7. The service account needs DELETE permission on crs5_oltp tables.
================================================================================
#>

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

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Execute-DmShellPurge' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# SCRIPT-LEVEL STATE
# ============================================================================

$Script:TargetServer = $null
$Script:TargetConnection = $null  # Persistent SqlConnection to crs5_oltp
$Script:BatchChunkSize = 5000
$Script:BatchSizeFull = 1000
$Script:BatchSizeReduced = 100
$Script:ScheduleMode = $null       # 'Full', 'Reduced', 'Manual', or 'Blocked'
$Script:CurrentBatchId = $null     # ShellPurge_BatchLog.batch_id for current batch
$Script:ManualBatchSize = $false   # True if -BatchSize parameter was specified
$Script:AlertingEnabled = $false   # Teams alerting on/off (from GlobalConfig)
$Script:PurgeWorkgroupId = $null   # Resolved wrkgrp_id for WFAPURGE (cached across batches)
$Script:ExclusionsLoaded = $false  # Whether exclusion log has been loaded into target temp table

# Per-batch counters (reset each batch)
$Script:TotalDeleted = 0
$Script:TablesProcessed = 0
$Script:TablesSkipped = 0
$Script:TablesFailed = 0
$Script:BatchConsumerIds = @()
$Script:BatchConsumerData = @()    # Full consumer data for ConsumerLog

# Session-level counters
$Script:TotalBatchesRun = 0
$Script:TotalBatchesFailed = 0
$Script:SessionTotalDeleted = 0
$Script:SessionTotalConsumers = 0

# ============================================================================
# PERSISTENT CONNECTION FUNCTIONS
# ============================================================================

function Open-TargetConnection {
    try {
        $connString = "Server=$($Script:TargetServer);Database=crs5_oltp;Integrated Security=True;Application Name=$($script:XFActsAppName);Connect Timeout=30"
        $Script:TargetConnection = New-Object System.Data.SqlClient.SqlConnection($connString)
        $Script:TargetConnection.Open()
        Write-Log "  Persistent connection opened to $($Script:TargetServer)/crs5_oltp" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to open connection to $($Script:TargetServer): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Close-TargetConnection {
    if ($Script:TargetConnection -and $Script:TargetConnection.State -eq 'Open') {
        $Script:TargetConnection.Close()
        $Script:TargetConnection.Dispose()
        $Script:TargetConnection = $null
        Write-Log "  Persistent connection closed" "INFO"
    }
}

function Invoke-TargetQuery {
    param(
        [Parameter(Mandatory)]
        [string]$Query,
        [int]$Timeout = 300
    )

    $cmd = $Script:TargetConnection.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = $Timeout

    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dataTable = New-Object System.Data.DataTable

    try {
        [void]$adapter.Fill($dataTable)
        return ,$dataTable
    }
    catch {
        throw $_
    }
    finally {
        $cmd.Dispose()
        $adapter.Dispose()
    }
}

function Invoke-TargetDelete {
    param(
        [Parameter(Mandatory)]
        [string]$DeleteSQL,
        [int]$Timeout = 600,
        [int]$MaxRetries = 10,
        [int]$RetryDelaySeconds = 5
    )

    $totalRowsDeleted = 0
    $chunkNumber = 0

    $chunkedSQL = $DeleteSQL -replace '(?i)^DELETE\s+(FROM\s+)', "DELETE TOP ($($Script:BatchChunkSize)) `$1"
    $chunkedSQL = $chunkedSQL -replace '(?i)^DELETE\s+(\w+)\s+(FROM\s+)', "DELETE TOP ($($Script:BatchChunkSize)) `$1 `$2"

    while ($true) {
        $chunkNumber++
        $retryCount = 0
        $chunkDeleted = -1

        while ($retryCount -lt $MaxRetries) {
            $cmd = $Script:TargetConnection.CreateCommand()
            $cmd.CommandTimeout = $Timeout

            try {
                $cmd.CommandText = @"
SET DEADLOCK_PRIORITY LOW;
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
$chunkedSQL
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
"@
                $chunkDeleted = $cmd.ExecuteNonQuery()
                break
            }
            catch {
                $errNum = 0
                $innerEx = $_.Exception
                while ($innerEx.InnerException) { $innerEx = $innerEx.InnerException }
                if ($innerEx -is [System.Data.SqlClient.SqlException]) {
                    $errNum = $innerEx.Number
                }

                if ($errNum -in @(1204, 1205, 1222, 3960)) {
                    $retryCount++
                    if ($retryCount -ge $MaxRetries) {
                        Write-Log "      Retry limit ($MaxRetries) exceeded on chunk $chunkNumber" "ERROR"
                        throw $_
                    }
                    Write-Log "      Retryable error ($errNum), attempt $retryCount/$MaxRetries — waiting ${RetryDelaySeconds}s..." "WARN"
                    Start-Sleep -Seconds $RetryDelaySeconds

                    try {
                        $resetCmd = $Script:TargetConnection.CreateCommand()
                        $resetCmd.CommandText = "SET TRANSACTION ISOLATION LEVEL READ COMMITTED;"
                        $resetCmd.ExecuteNonQuery() | Out-Null
                        $resetCmd.Dispose()
                    } catch { }
                }
                else {
                    throw $_
                }
            }
            finally {
                $cmd.Dispose()
            }
        }

        if ($chunkDeleted -le 0) { break }

        $totalRowsDeleted += $chunkDeleted

        if ($chunkDeleted -lt $Script:BatchChunkSize) { break }

        Start-Sleep -Milliseconds 100
    }

    return $totalRowsDeleted
}

# ============================================================================
# SCHEDULE & CONTROL FUNCTIONS
# ============================================================================

function Get-ShellPurgeScheduleMode {
    $currentHour = (Get-Date).Hour
    $hrCol = "hr{0:D2}" -f $currentHour

    try {
        $result = Get-SqlData -Query @"
            SELECT $hrCol AS schedule_mode
            FROM DmOps.ShellPurge_Schedule
            WHERE day_of_week = DATEPART(dw, GETDATE())
"@
        if ($result) {
            return [int]$result.schedule_mode
        }
        Write-Log "  No schedule row found for today — treating as blocked" "WARN"
        return 0
    }
    catch {
        Write-Log "  Failed to read schedule: $($_.Exception.Message) — treating as blocked" "WARN"
        return 0
    }
}

function Test-ShellPurgeAbort {
    try {
        $result = Get-SqlData -Query @"
            SELECT setting_value FROM dbo.GlobalConfig
            WHERE module_name = 'DmOps' AND category = 'ShellPurge'
              AND setting_name = 'shell_purge_abort' AND is_active = 1
"@
        if ($result -and $result.setting_value -eq '1') {
            return $true
        }
        return $false
    }
    catch {
        Write-Log "  Failed to check abort flag — proceeding cautiously" "WARN"
        return $false
    }
}

# ============================================================================
# BATCH LOGGING FUNCTIONS
# ============================================================================

function New-BatchLogEntry {
    param(
        [string]$ScheduleMode,
        [int]$BatchSizeUsed
    )
    try {
        $result = Get-SqlData -Query @"
            INSERT INTO DmOps.ShellPurge_BatchLog
                (schedule_mode, batch_size_used, status, executed_by)
            OUTPUT INSERTED.batch_id
            VALUES ('$ScheduleMode', $BatchSizeUsed, 'Running', SUSER_SNAME())
"@
        $Script:CurrentBatchId = [long]$result.batch_id
        Write-Log "  Batch log created: batch_id = $($Script:CurrentBatchId)" "INFO"
    }
    catch {
        Write-Log "  Failed to create batch log: $($_.Exception.Message)" "WARN"
        $Script:CurrentBatchId = $null
    }
}

function Update-BatchLogEntry {
    param(
        [string]$Status,
        [string]$ErrorMessage = $null
    )
    if (-not $Script:CurrentBatchId) { return }

    $escapedError = if ($ErrorMessage) { $ErrorMessage.Replace("'", "''").Substring(0, [Math]::Min($ErrorMessage.Length, 2000)) } else { $null }
    $errorClause = if ($escapedError) { "'$escapedError'" } else { "NULL" }

    $durationMs = [int]((Get-Date) - $Script:BatchStartTime).TotalMilliseconds

    try {
        Invoke-SqlNonQuery -Query @"
            UPDATE DmOps.ShellPurge_BatchLog
            SET batch_end_dttm = GETDATE(),
                consumer_count = $($Script:BatchConsumerIds.Count),
                total_rows_deleted = $($Script:TotalDeleted),
                tables_processed = $($Script:TablesProcessed),
                tables_skipped = $($Script:TablesSkipped),
                tables_failed = $($Script:TablesFailed),
                duration_ms = $durationMs,
                status = '$Status',
                error_message = $errorClause
            WHERE batch_id = $($Script:CurrentBatchId)
"@ -Timeout 30 | Out-Null
    }
    catch {
        Write-Log "  Failed to update batch log: $($_.Exception.Message)" "WARN"
    }
}

function Write-BatchDetail {
    param(
        [string]$DeleteOrder,
        [string]$TableName,
        [string]$PassDescription,
        [long]$RowsAffected,
        [int]$DurationMs,
        [string]$Status,
        [string]$ErrorMessage = $null
    )
    if (-not $Script:CurrentBatchId) { return }

    $escapedPass = if ($PassDescription) { "'$($PassDescription.Replace("'", "''"))'" } else { "NULL" }
    $escapedError = if ($ErrorMessage) { "'$($ErrorMessage.Replace("'", "''").Substring(0, [Math]::Min($ErrorMessage.Length, 2000)))'" } else { "NULL" }
    $durationClause = if ($DurationMs -ge 0) { "$DurationMs" } else { "NULL" }

    try {
        Invoke-SqlNonQuery -Query @"
            INSERT INTO DmOps.ShellPurge_BatchDetail
                (batch_id, delete_order, table_name, pass_description, rows_affected, duration_ms, status, error_message)
            VALUES
                ($($Script:CurrentBatchId), '$DeleteOrder', '$TableName', $escapedPass, $RowsAffected, $durationClause, '$Status', $escapedError)
"@ -Timeout 30 | Out-Null
    }
    catch {
        Write-Log "  Failed to write batch detail: $($_.Exception.Message)" "WARN"
    }
}

function Write-ConsumerLog {
    if (-not $Script:CurrentBatchId -or $Script:BatchConsumerData.Count -eq 0) { return }

    try {
        for ($i = 0; $i -lt $Script:BatchConsumerData.Count; $i += 900) {
            $batch = $Script:BatchConsumerData[$i..[Math]::Min($i + 899, $Script:BatchConsumerData.Count - 1)]
            $valuesClause = ($batch | ForEach-Object {
                "($($Script:CurrentBatchId), $($_.cnsmr_id), '$($_.cnsmr_idntfr_agncy_id)')"
            }) -join ",`n                "

            Invoke-SqlNonQuery -Query @"
                INSERT INTO DmOps.ShellPurge_ConsumerLog
                    (batch_id, cnsmr_id, cnsmr_idntfr_agncy_id)
                VALUES
                    $valuesClause
"@ -Timeout 120 | Out-Null
        }

        Write-Log "  Consumer log: $($Script:BatchConsumerData.Count) records written" "SUCCESS"
    }
    catch {
        Write-Log "  Failed to write consumer log: $($_.Exception.Message)" "WARN"
    }
}

# ============================================================================
# DELETE SEQUENCE FUNCTIONS
# ============================================================================

function Invoke-TableDelete {
    param(
        [Parameter(Mandatory)]
        $Order,
        [Parameter(Mandatory)]
        [string]$TableName,
        [Parameter(Mandatory)]
        [string]$WhereClause,
        [string]$PassDescription = "",
        [bool]$PreviewOnly = $true
    )

    $passLabel = if ($PassDescription) { " ($PassDescription)" } else { "" }
    $fullTable = "crs5_oltp.dbo.$TableName"

    if ($PreviewOnly) {
        try {
            $countResult = Invoke-TargetQuery -Query "SELECT COUNT(*) AS row_count FROM $fullTable WHERE $WhereClause" -Timeout 300
            $previewCount = [long]$countResult.Rows[0].row_count
            if ($previewCount -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel — no rows, skipping" "DEBUG"
                $Script:TablesSkipped++
                Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs 0 -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel — would delete $previewCount rows" "INFO"
                $Script:TotalDeleted += $previewCount
                $Script:TablesProcessed++
                Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $previewCount -DurationMs 0 -Status 'Success'
            }
            return $true
        }
        catch {
            Write-Log "  [$Order] $TableName$passLabel — count failed: $($_.Exception.Message)" "WARN"
            $Script:TablesFailed++
            Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs 0 -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
    else {
        $deleteSQL = "DELETE FROM $fullTable WHERE $WhereClause"
        $deleteStart = Get-Date

        try {
            $rowsDeleted = Invoke-TargetDelete -DeleteSQL $deleteSQL
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            if ($rowsDeleted -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel — no rows, skipping" "DEBUG"
                $Script:TablesSkipped++
                Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs $durationMs -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel — deleted $rowsDeleted rows (${durationMs}ms)" "SUCCESS"
                $Script:TotalDeleted += $rowsDeleted
                $Script:TablesProcessed++
                Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $rowsDeleted -DurationMs $durationMs -Status 'Success'
            }
            return $true
        }
        catch {
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            Write-Log "  [$Order] $TableName$passLabel — FAILED (${durationMs}ms): $($_.Exception.Message)" "ERROR"
            $Script:TablesFailed++
            Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs $durationMs -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
}

function Invoke-JoinTableDelete {
    param(
        [Parameter(Mandatory)]
        $Order,
        [Parameter(Mandatory)]
        [string]$TableName,
        [Parameter(Mandatory)]
        [string]$DeleteStatement,
        [string]$CountQuery,
        [string]$PassDescription = "",
        [bool]$PreviewOnly = $true
    )

    $passLabel = if ($PassDescription) { " ($PassDescription)" } else { "" }

    if ($PreviewOnly) {
        try {
            $countResult = Invoke-TargetQuery -Query $CountQuery -Timeout 300
            $previewCount = [long]$countResult.Rows[0].row_count
            if ($previewCount -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel — no rows, skipping" "DEBUG"
                $Script:TablesSkipped++
                Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs 0 -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel — would delete $previewCount rows" "INFO"
                $Script:TotalDeleted += $previewCount
                $Script:TablesProcessed++
                Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $previewCount -DurationMs 0 -Status 'Success'
            }
            return $true
        }
        catch {
            Write-Log "  [$Order] $TableName$passLabel — count failed: $($_.Exception.Message)" "WARN"
            $Script:TablesFailed++
            Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs 0 -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
    else {
        $deleteStart = Get-Date
        try {
            $rowsDeleted = Invoke-TargetDelete -DeleteSQL $DeleteStatement
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            if ($rowsDeleted -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel — no rows, skipping" "DEBUG"
                $Script:TablesSkipped++
                Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs $durationMs -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel — deleted $rowsDeleted rows (${durationMs}ms)" "SUCCESS"
                $Script:TotalDeleted += $rowsDeleted
                $Script:TablesProcessed++
                Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $rowsDeleted -DurationMs $durationMs -Status 'Success'
            }
            return $true
        }
        catch {
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            Write-Log "  [$Order] $TableName$passLabel — FAILED (${durationMs}ms): $($_.Exception.Message)" "ERROR"
            $Script:TablesFailed++
            Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs $durationMs -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$scriptStart = Get-Date

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  xFACts DM Shell Purge — Consumer-Level" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$previewOnly = -not $Execute

# ============================================================================
# STEP 1: Load Configuration & Pre-Flight Checks
# ============================================================================

Write-Log "--- Step 1: Configuration ---"

# ── Abort flag check (overrides everything) ──
if (Test-ShellPurgeAbort) {
    Write-Log "Shell purge abort flag is set — exiting immediately" "WARN"
    exit 0
}

# ── Target instance ──
if ([string]::IsNullOrEmpty($TargetInstance)) {
    $configResult = Get-SqlData -Query @"
        SELECT setting_value FROM dbo.GlobalConfig
        WHERE module_name = 'DmOps' AND category = 'ShellPurge'
          AND setting_name = 'target_instance' AND is_active = 1
"@
    if ($configResult) {
        $Script:TargetServer = $configResult.setting_value
    } else {
        Write-Log "No target_instance configured in GlobalConfig (DmOps.ShellPurge)" "ERROR"
        exit 1
    }
} else {
    $Script:TargetServer = $TargetInstance
}

# ── ServerRegistry enable check (skip if manual target override) ──
if ([string]::IsNullOrEmpty($TargetInstance)) {
    $enabledResult = Get-SqlData -Query @"
        SELECT dmops_shell_purge_enabled
        FROM dbo.ServerRegistry
        WHERE server_name = '$($Script:TargetServer)'
"@
    if (-not $enabledResult -or $enabledResult.dmops_shell_purge_enabled -ne 1) {
        Write-Log "Shell purge is disabled on $($Script:TargetServer) (ServerRegistry.dmops_shell_purge_enabled)" "WARN"
        exit 0
    }
}

# ── GlobalConfig settings ──
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

if ($configMap.ContainsKey('batch_size'))         { $Script:BatchSizeFull = [int]$configMap['batch_size'] }
if ($configMap.ContainsKey('batch_size_reduced')) { $Script:BatchSizeReduced = [int]$configMap['batch_size_reduced'] }
if ($configMap.ContainsKey('chunk_size'))         { $Script:BatchChunkSize = [int]$configMap['chunk_size'] }
if ($configMap.ContainsKey('alerting_enabled'))   { $Script:AlertingEnabled = $configMap['alerting_enabled'] -eq '1' }

# ── ChunkSize parameter override ──
if ($ChunkSize -gt 0) { $Script:BatchChunkSize = $ChunkSize }

# ── BatchSize parameter override (Manual mode) ──
if ($BatchSize -gt 0) {
    $Script:ManualBatchSize = $true
    $Script:ScheduleMode = 'Manual'
    $activeBatchSize = $BatchSize
    Write-Log "  Manual batch size override: $BatchSize" "INFO"
} else {
    # Determine batch size from schedule
    $scheduleValue = Get-ShellPurgeScheduleMode
    switch ($scheduleValue) {
        0 {
            $Script:ScheduleMode = 'Blocked'
            Write-Log "  Schedule: BLOCKED for current hour — exiting" "WARN"
            exit 0
        }
        1 {
            $Script:ScheduleMode = 'Full'
            $activeBatchSize = $Script:BatchSizeFull
        }
        2 {
            $Script:ScheduleMode = 'Reduced'
            $activeBatchSize = $Script:BatchSizeReduced
        }
        default {
            Write-Log "  Schedule: unexpected value ($scheduleValue) — treating as blocked" "WARN"
            exit 0
        }
    }
}

Write-Log "  Target Instance  : $($Script:TargetServer)"
Write-Log "  xFACts Instance  : $ServerInstance"
Write-Log "  Schedule Mode    : $($Script:ScheduleMode)"
Write-Log "  Batch Size       : $activeBatchSize consumers"
Write-Log "  Chunk Size       : $($Script:BatchChunkSize) rows per delete"
Write-Log "  Alerting         : $(if ($Script:AlertingEnabled) { 'Enabled' } else { 'Disabled' })"
Write-Log "  Loop Mode        : $(if ($SingleBatch) { 'Single batch' } else { 'Continuous' })"
Write-Log ""

# ============================================================================
# STEP 2: Open Persistent Connection
# ============================================================================

Write-Log "--- Step 2: Open Connection ---"

if (-not (Open-TargetConnection)) {
    if ($TaskId -gt 0) {
        $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs $totalMs `
            -ErrorMessage "Failed to open connection to target instance"
    }
    exit 1
}

Write-Log ""

# ============================================================================
# BATCH LOOP
# ============================================================================

$continueProcessing = $true

while ($continueProcessing) {

# ── Reset per-batch counters ──
$Script:TotalDeleted = 0
$Script:TablesProcessed = 0
$Script:TablesSkipped = 0
$Script:TablesFailed = 0
$Script:BatchConsumerIds = @()
$Script:BatchConsumerData = @()
$Script:StopProcessing = $false
$Script:BatchStartTime = Get-Date

$Script:TotalBatchesRun++

Write-Host ""
Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host "  Batch #$($Script:TotalBatchesRun) — $($Script:ScheduleMode) mode ($activeBatchSize consumers)" -ForegroundColor DarkCyan
Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host ""

# ============================================================================
# STEP 3: Select Shell Consumers
# ============================================================================

Write-Log "--- Step 3: Select Shell Consumers ---"

# Step 3a: Resolve WFAPURGE workgroup ID (first batch only — reuse on subsequent batches)
if (-not $Script:PurgeWorkgroupId) {
    try {
        $wrkgrpResult = Invoke-TargetQuery -Query "SELECT wrkgrp_id FROM crs5_oltp.dbo.wrkgrp WHERE wrkgrp_shrt_nm = 'WFAPURGE'"
        if ($wrkgrpResult.Rows.Count -eq 0) {
            Write-Log "WFAPURGE workgroup not found in crs5_oltp — exiting" "ERROR"
            Close-TargetConnection
            exit 1
        }
        $Script:PurgeWorkgroupId = [long]$wrkgrpResult.Rows[0].wrkgrp_id
        Write-Log "  WFAPURGE workgroup resolved: wrkgrp_id = $($Script:PurgeWorkgroupId)" "INFO"
    }
    catch {
        Write-Log "Failed to resolve WFAPURGE workgroup: $($_.Exception.Message)" "ERROR"
        Close-TargetConnection
        exit 1
    }
}

# Step 3b: Load exclusion log into temp table on target connection (first batch only)
if (-not $Script:ExclusionsLoaded) {
    try {
        $exclCreateCmd = $Script:TargetConnection.CreateCommand()
        $exclCreateCmd.CommandText = "IF OBJECT_ID('tempdb..#shell_exclusions') IS NOT NULL DROP TABLE #shell_exclusions; CREATE TABLE #shell_exclusions (cnsmr_id BIGINT PRIMARY KEY);"
        $exclCreateCmd.CommandTimeout = 30
        $exclCreateCmd.ExecuteNonQuery() | Out-Null
        $exclCreateCmd.Dispose()

        $exclData = Get-SqlData -Query "SELECT DISTINCT cnsmr_id FROM DmOps.ShellPurge_ExclusionLog"
        $exclCount = 0
        if ($exclData) {
            $exclIds = @($exclData | ForEach-Object { [long]$_.cnsmr_id })
            $exclCount = $exclIds.Count
            for ($i = 0; $i -lt $exclIds.Count; $i += 900) {
                $batch = $exclIds[$i..[Math]::Min($i + 899, $exclIds.Count - 1)]
                $valuesClause = ($batch | ForEach-Object { "($_)" }) -join ','
                $insertCmd = $Script:TargetConnection.CreateCommand()
                $insertCmd.CommandText = "INSERT INTO #shell_exclusions (cnsmr_id) VALUES $valuesClause"
                $insertCmd.CommandTimeout = 60
                $insertCmd.ExecuteNonQuery() | Out-Null
                $insertCmd.Dispose()
            }
        }

        Write-Log "  Exclusion log loaded: $exclCount consumers" "INFO"
        $Script:ExclusionsLoaded = $true
    }
    catch {
        Write-Log "Failed to load exclusion log: $($_.Exception.Message)" "ERROR"
        Close-TargetConnection
        exit 1
    }
}

# Step 3c: Select eligible shell consumers
$selectStart = Get-Date

$batchQuery = @"
    SELECT TOP ($activeBatchSize) c.cnsmr_id, c.cnsmr_idntfr_agncy_id
    FROM crs5_oltp.dbo.cnsmr c
    LEFT JOIN crs5_oltp.dbo.cnsmr_accnt ca ON ca.cnsmr_id = c.cnsmr_id
    WHERE c.wrkgrp_id = $($Script:PurgeWorkgroupId)
      AND ca.cnsmr_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM #shell_exclusions e WHERE e.cnsmr_id = c.cnsmr_id)
"@

try {
    $batchResult = Invoke-TargetQuery -Query $batchQuery
}
catch {
    Write-Log "Failed to select batch: $($_.Exception.Message)" "ERROR"
    Close-TargetConnection
    exit 1
}

if ($batchResult.Rows.Count -eq 0) {
    Write-Log "No eligible shell consumers found — work complete" "INFO"
    $continueProcessing = $false
    break
}

# Step 3c: Validate batch against exclusion tables (catch new exclusions since seed)
$exclusionChecks = @(
#    @{ Name = 'cnsmr_pymnt_jrnl';              SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj WHERE cpj.cnsmr_id = sc.cnsmr_id)" }
#    @{ Name = 'dcmnt_rqst';                    SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.dcmnt_rqst dr WHERE dr.dcmnt_rqst_send_to_entty_id = sc.cnsmr_id AND dr.dcmnt_rqst_send_to_entty_assctn_cd = 2)" }
#    @{ Name = 'agnt_crdtbl_actvty';             SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.agnt_crdtbl_actvty aca WHERE aca.cnsmr_id = sc.cnsmr_id)" }
#    @{ Name = 'agnt_crdtbl_actvty_via_smmry';   SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.agnt_crdtbl_actvty aca WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT sps.schdld_pymnt_smmry_id FROM crs5_oltp.dbo.schdld_pymnt_smmry sps WHERE sps.cnsmr_id = sc.cnsmr_id))" }
#    @{ Name = 'agnt_crdt';                     SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.agnt_crdt ac INNER JOIN crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj ON ac.cnsmr_pymnt_jrnl_id = cpj.cnsmr_pymnt_jrnl_id WHERE cpj.cnsmr_id = sc.cnsmr_id)" }
#    @{ Name = 'bnkrptcy';                      SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.bnkrptcy b WHERE b.cnsmr_id = sc.cnsmr_id)" }
#    @{ Name = 'schdld_pymnt_smmry';             SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.schdld_pymnt_smmry sps WHERE sps.cnsmr_id = sc.cnsmr_id)" }
#    @{ Name = 'sspns_trnsctn_cnsmr_idntfr';    SQL = "SELECT sc.cnsmr_id, sc.cnsmr_idntfr_agncy_id FROM #shell_exclusion_check sc WHERE EXISTS (SELECT 1 FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci WHERE stci.cnsmr_id = sc.cnsmr_id)" }
)

try {
    # Load batch into temp table for exclusion checks
    $createCheckSQL = "IF OBJECT_ID('tempdb..#shell_exclusion_check') IS NOT NULL DROP TABLE #shell_exclusion_check; CREATE TABLE #shell_exclusion_check (cnsmr_id BIGINT PRIMARY KEY, cnsmr_idntfr_agncy_id VARCHAR(50));"
    $cmd = $Script:TargetConnection.CreateCommand()
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
        $insertCmd = $Script:TargetConnection.CreateCommand()
        $insertCmd.CommandText = "INSERT INTO #shell_exclusion_check (cnsmr_id, cnsmr_idntfr_agncy_id) VALUES $valuesClause"
        $insertCmd.CommandTimeout = 30
        $insertCmd.ExecuteNonQuery() | Out-Null
        $insertCmd.Dispose()
    }

    # Run each exclusion check — log and remove any new discoveries
    $newExclusions = New-Object System.Collections.Generic.List[long]

    foreach ($excl in $exclusionChecks) {
        $exclResult = Invoke-TargetQuery -Query $excl.SQL
        if ($exclResult.Rows.Count -gt 0) {
            Write-Log "    New exclusion: $($exclResult.Rows.Count) consumers have $($excl.Name) data" "WARN"
            foreach ($exclRow in $exclResult.Rows) {
                $exclCnsmrId = [long]$exclRow.cnsmr_id
                $exclAgencyId = [string]$exclRow.cnsmr_idntfr_agncy_id
                if (-not $newExclusions.Contains($exclCnsmrId)) {
                    $newExclusions.Add($exclCnsmrId)
                }
                # Log to ExclusionLog (xFACts DB via platform wrapper)
                Invoke-SqlNonQuery -Query @"
                    IF NOT EXISTS (SELECT 1 FROM DmOps.ShellPurge_ExclusionLog WHERE cnsmr_id = $exclCnsmrId AND exclusion_reason = '$($excl.Name)')
                    INSERT INTO DmOps.ShellPurge_ExclusionLog (cnsmr_id, cnsmr_idntfr_agncy_id, exclusion_reason)
                    VALUES ($exclCnsmrId, '$exclAgencyId', '$($excl.Name)')
"@ -Timeout 30 | Out-Null

                # Also add to #shell_exclusions on target so subsequent batches skip this consumer
                try {
                    $addExclCmd = $Script:TargetConnection.CreateCommand()
                    $addExclCmd.CommandText = "IF NOT EXISTS (SELECT 1 FROM #shell_exclusions WHERE cnsmr_id = $exclCnsmrId) INSERT INTO #shell_exclusions (cnsmr_id) VALUES ($exclCnsmrId)"
                    $addExclCmd.CommandTimeout = 10
                    $addExclCmd.ExecuteNonQuery() | Out-Null
                    $addExclCmd.Dispose()
                } catch { }
            }
        }
    }

    if ($newExclusions.Count -gt 0) {
        Write-Log "  Logged $($newExclusions.Count) new exclusion(s) to ShellPurge_ExclusionLog" "INFO"
    }
}
catch {
    Write-Log "Failed during exclusion validation: $($_.Exception.Message)" "WARN"
    # Non-fatal — proceed with the batch as selected, exclusions are a safety net
}

# Build final consumer lists (excluding any newly discovered exclusions)
$Script:BatchConsumerIds = New-Object System.Collections.Generic.List[long]
$Script:BatchConsumerData = New-Object System.Collections.Generic.List[PSObject]

foreach ($row in $batchResult.Rows) {
    $cid = [long]$row.cnsmr_id
    if ($newExclusions.Contains($cid)) { continue }
    $Script:BatchConsumerIds.Add($cid)
    $Script:BatchConsumerData.Add([PSCustomObject]@{
        cnsmr_id              = $cid
        cnsmr_idntfr_agncy_id = [string]$row.cnsmr_idntfr_agncy_id
    })
}

if ($Script:BatchConsumerIds.Count -eq 0) {
    Write-Log "All batch candidates were excluded — retrying next batch" "WARN"
    continue
}

$totalSelectMs = [int]((Get-Date) - $selectStart).TotalMilliseconds
Write-Log "  Selected $($Script:BatchConsumerIds.Count) shell consumers (${totalSelectMs}ms)" "INFO"
Write-Log ""

# ── Create batch log entry ──
New-BatchLogEntry -ScheduleMode $Script:ScheduleMode -BatchSizeUsed $activeBatchSize

# ── Write consumer log ──
Write-ConsumerLog

# ============================================================================
# STEP 4: Create Temp Tables
# ============================================================================

Write-Log "--- Step 4: Load Batch ID Temp Tables ---"

$createTableSQL = @"
    IF OBJECT_ID('tempdb..#shell_batch_consumers') IS NOT NULL DROP TABLE #shell_batch_consumers;
    CREATE TABLE #shell_batch_consumers (cnsmr_id BIGINT PRIMARY KEY);
"@

try {
    $cmd = $Script:TargetConnection.CreateCommand()
    $cmd.CommandText = $createTableSQL
    $cmd.CommandTimeout = 30
    $cmd.ExecuteNonQuery() | Out-Null
    $cmd.Dispose()

    for ($i = 0; $i -lt $Script:BatchConsumerIds.Count; $i += 900) {
        $batch = $Script:BatchConsumerIds[$i..[Math]::Min($i + 899, $Script:BatchConsumerIds.Count - 1)]
        $valuesClause = ($batch | ForEach-Object { "($_)" }) -join ','
        $insertCmd = $Script:TargetConnection.CreateCommand()
        $insertCmd.CommandText = "INSERT INTO #shell_batch_consumers (cnsmr_id) VALUES $valuesClause"
        $insertCmd.CommandTimeout = 30
        $insertCmd.ExecuteNonQuery() | Out-Null
        $insertCmd.Dispose()
    }

    Write-Log "  Temp table loaded: $($Script:BatchConsumerIds.Count) consumers" "SUCCESS"
}
catch {
    Write-Log "Failed to create temp tables: $($_.Exception.Message)" "ERROR"
    Update-BatchLogEntry -Status 'Failed' -ErrorMessage "Temp table creation failed: $($_.Exception.Message)"
    Close-TargetConnection
    exit 1
}

# ── Pre-materialize intermediate ID tables ──
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

    SELECT
        (SELECT COUNT(*) FROM #shell_pymnt_instrmnt_ids) AS instrmnt_count,
        (SELECT COUNT(*) FROM #shell_pymnt_jrnl_ids) AS jrnl_count,
        (SELECT COUNT(*) FROM #shell_cntct_trnsctn_ids) AS cntct_count,
        (SELECT COUNT(*) FROM #shell_smmry_ids) AS smmry_count;
"@

try {
    $cmd = $Script:TargetConnection.CreateCommand()
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

    Write-Log "  Intermediate ID tables materialized:" "SUCCESS"
    Write-Log "    Payment instruments: $instrmntCount" "INFO"
    Write-Log "    Payment journals:    $jrnlCount" "INFO"
    Write-Log "    Contact txn logs:    $cntctCount" "INFO"
    Write-Log "    Sched pymnt smmry:   $smmryCount" "INFO"
}
catch {
    Write-Log "Failed to create intermediate temp tables: $($_.Exception.Message)" "ERROR"
    Update-BatchLogEntry -Status 'Failed' -ErrorMessage "Intermediate temp table creation failed: $($_.Exception.Message)"
    Close-TargetConnection
    exit 1
}

Write-Log ""

# ============================================================================
# STEP 5: Execute Consumer-Level Deletions
# ============================================================================

Write-Log "--- Step 5: Execute Consumer-Level Deletions ---"
Write-Log ""

$Script:StopProcessing = $false

$wCnsmr       = "cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"
$wCntctLog    = "cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM #shell_cntct_trnsctn_ids)"
$wInstrmnt    = "cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
$wJrnl        = "cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
$wSmmry       = "schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"

function Step-Delete {
    param([hashtable]$Params)
    if ($Script:StopProcessing) { return }
    $ok = Invoke-TableDelete @Params -PreviewOnly $previewOnly
    if (-not $ok) {
        Write-Log "  STOPPING — cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $Script:StopProcessing = $true
    }
}

function Step-JoinDelete {
    param([hashtable]$Params)
    if ($Script:StopProcessing) { return }
    $ok = Invoke-JoinTableDelete @Params -PreviewOnly $previewOnly
    if (-not $ok) {
        Write-Log "  STOPPING — cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $Script:StopProcessing = $true
    }
}

# ── Phase 1: Consumer-Level UDEF Tables (Dynamic Discovery) ──
Write-Log "  Phase 1: Consumer-Level UDEF Tables (dynamic)" "INFO"

try {
    $udefCnsmrResult = Invoke-TargetQuery -Query @"
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
    $Script:StopProcessing = $true
}

if (-not $Script:StopProcessing) {
    $udefOrder = 0
    foreach ($udefTable in $udefCnsmrTables) {
        $udefOrder++
        Step-Delete @{Order="U$udefOrder"; TableName=$udefTable; WhereClause=$wCnsmr}
    }
}

Write-Log ""

# ── Phase 2: Consumer-Level Tables (FK-ordered, all gaps filled) ──
# Redesigned from sys.foreign_keys chain analysis against cnsmr terminal table.
# 98 steps: 34 new FK-required tables, 11 ordering corrections, 3 exclusion-controlled chains.
# Tables marked [NEW] were not in the previous sequence.
# Tables marked [EXCL] are exclusion-controlled — currently no-ops while exclusions are active.
Write-Log "  Phase 2: Consumer-Level Tables" "INFO"

# ── Simple direct cnsmr_id tables (no FK children, no ordering concerns) ──
Step-Delete @{Order=1; TableName='asst'; WhereClause=$wCnsmr}
Step-Delete @{Order=2; TableName='attrny'; WhereClause=$wCnsmr}
Step-Delete @{Order=3; TableName='cnsmr_addrss'; WhereClause=$wCnsmr}
Step-Delete @{Order=4; TableName='cnsmr_Cmmnt'; WhereClause=$wCnsmr}
Step-Delete @{Order=5; TableName='cnsmr_crdt'; WhereClause=$wCnsmr}
Step-Delete @{Order=6; TableName='cnsmr_fee_spprss_cnfg'; WhereClause=$wCnsmr}
Step-Delete @{Order=7; TableName='cnsmr_Fnncl'; WhereClause=$wCnsmr}
Step-Delete @{Order=8; TableName='cnsmr_rndm_nmbr'; WhereClause=$wCnsmr}
Step-Delete @{Order=9; TableName='cnsmr_Rvw_rqst'; WhereClause=$wCnsmr}
Step-Delete @{Order=10; TableName='cnsmr_Tag'; WhereClause=$wCnsmr}
Step-Delete @{Order=11; TableName='cnsmr_Wrk_actn'; WhereClause=$wCnsmr}
Step-Delete @{Order=12; TableName='decsd'; WhereClause=$wCnsmr}
Step-Delete @{Order=13; TableName='dfrrd_cnsmr'; WhereClause=$wCnsmr}
Step-Delete @{Order=14; TableName='emplyr'; WhereClause=$wCnsmr}
Step-Delete @{Order=15; TableName='ivr_call_log'; WhereClause=$wCnsmr}
Step-Delete @{Order=16; TableName='job_skptrc_cnsmr'; WhereClause=$wCnsmr}
Step-Delete @{Order=17; TableName='job_skptrc_instnc_log'; WhereClause=$wCnsmr}
Step-Delete @{Order=18; TableName='strtgy_log'; WhereClause=$wCnsmr}
Step-Delete @{Order=19; TableName='usr_rmndr'; WhereClause="usr_rmndr_cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"}
Step-Delete @{Order=20; TableName='cnsmr_accnt_spplmntl_info'; WhereClause=$wCnsmr}
Step-Delete @{Order=21; TableName='cb_rpt_assctd_cnsmr_data'; WhereClause=$wCnsmr}
Step-Delete @{Order=22; TableName='cb_rpt_base_data'; WhereClause=$wCnsmr}
Step-Delete @{Order=23; TableName='cb_rpt_emplyr_data'; WhereClause=$wCnsmr}
Step-Delete @{Order=24; TableName='cb_rpt_rqst_dtl'; WhereClause=$wCnsmr}
Step-Delete @{Order=25; TableName='job_file'; WhereClause=$wCnsmr}
Step-Delete @{Order=26; TableName='cnsmr_accnt_ownrs'; WhereClause=$wCnsmr}

# ── bal_rdctn_plan chain (FK: stpdwn → plan → cnsmr) ──
# [NEW] bal_rdctn_plan_stpdwn: FK child of bal_rdctn_plan — 0 rows
Step-Delete @{Order=27; TableName='bal_rdctn_plan_stpdwn'; WhereClause="bal_rdctn_plan_id IN (SELECT bal_rdctn_plan_id FROM crs5_oltp.dbo.bal_rdctn_plan WHERE $wCnsmr)"}
Step-Delete @{Order=28; TableName='bal_rdctn_plan'; WhereClause=$wCnsmr}

# ── ca_case chain (FK: children → ca_case → cnsmr) ──
# [NEW] All ca_case children — 0 rows across all tables
Step-Delete @{Order=29; TableName='ca_case_accnt_assctn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-Delete @{Order=30; TableName='ca_case_ar_log_assctn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-Delete @{Order=31; TableName='ca_case_bal_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-Delete @{Order=32; TableName='ca_case_cntct_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-Delete @{Order=33; TableName='ca_case_lck_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-Delete @{Order=34; TableName='ca_case_strtgy_log'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-Delete @{Order=35; TableName='ca_case_tag'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-Delete @{Order=36; TableName='dfrrd_ca_case'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-Delete @{Order=37; TableName='wrk_lst_case_cache'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-Delete @{Order=38; TableName='wrkgrp_scan_lst_case_cache'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
Step-Delete @{Order=39; TableName='ca_case'; WhereClause=$wCnsmr}

# ── cmpgn chain (FK: dialer_trnsctn_log → cmpgn_trnsctn_log → cnsmr, cmpgn_cache → cnsmr_Phn) ──
# [NEW] dialer_trnsctn_log: FK child of cmpgn_trnsctn_log — 0 rows
Step-Delete @{Order=40; TableName='dialer_trnsctn_log'; WhereClause="cmpgn_trnsctn_log_id IN (SELECT cmpgn_trnsctn_log_id FROM crs5_oltp.dbo.cmpgn_trnsctn_log WHERE $wCnsmr)"}
Step-Delete @{Order=41; TableName='cmpgn_trnsctn_log'; WhereClause=$wCnsmr}
Step-Delete @{Order=42; TableName='cmpgn_cache'; WhereClause=$wCnsmr}
# cnsmr_Phn must come after cmpgn_cache and cmpgn_trnsctn_log (both FK to cnsmr_Phn)
Step-Delete @{Order=43; TableName='cnsmr_Phn'; WhereClause=$wCnsmr}

# ── cnsmr_accnt_ar_log chain — CORRECTED ORDERING ──
# Contact log children BEFORE cnsmr_cntct_trnsctn_log BEFORE cnsmr_accnt_ar_log
Step-Delete @{Order=44; TableName='cnsmr_cntct_addrs_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
# [NEW] cnsmr_cntct_phn_log: FK child of cnsmr_cntct_trnsctn_log — 83 rows
Step-Delete @{Order=45; TableName='cnsmr_cntct_phn_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
# [NEW] cnsmr_cntct_email_log: FK child of cnsmr_cntct_trnsctn_log — 0 rows
Step-Delete @{Order=46; TableName='cnsmr_cntct_email_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
Step-Delete @{Order=47; TableName='cnsmr_cntct_trnsctn_log'; WhereClause=$wCnsmr}
# [NEW] cnsmr_task_itm_cnsmr_accnt_ar_log_assctn: FK to cnsmr_accnt_ar_log and cnsmr_task_itm — 0 rows
Step-Delete @{Order=48; TableName='cnsmr_task_itm_cnsmr_accnt_ar_log_assctn'; WhereClause="cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM crs5_oltp.dbo.cnsmr_accnt_ar_log WHERE $wCnsmr)"}

# [NEW] agnt_crdtbl_actvty chain via ar_log — must clear before cnsmr_accnt_ar_log
Step-JoinDelete @{
    Order = 49; TableName = 'agnt_crdtbl_actvty_spprssn'
    DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM crs5_oltp.dbo.cnsmr_accnt_ar_log WHERE $wCnsmr)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM crs5_oltp.dbo.cnsmr_accnt_ar_log WHERE $wCnsmr)"
    PassDescription = 'Pass 1: via ar_log (before ar_log delete)'
}

Step-JoinDelete @{
    Order = 50; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
    DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM crs5_oltp.dbo.cnsmr_accnt_ar_log WHERE $wCnsmr)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM crs5_oltp.dbo.cnsmr_accnt_ar_log WHERE $wCnsmr)"
    PassDescription = 'Pass 1: via ar_log (before ar_log delete)'
}

Step-JoinDelete @{
    Order = 51; TableName = 'agnt_crdtbl_actvty'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM crs5_oltp.dbo.cnsmr_accnt_ar_log WHERE $wCnsmr)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM crs5_oltp.dbo.cnsmr_accnt_ar_log WHERE $wCnsmr)"
    PassDescription = 'Pass 1: via ar_log (before ar_log delete)'
}

Step-Delete @{Order=52; TableName='crdtr_srvc_evnt'; WhereClause=$wCnsmr; PassDescription='before ar_log (FK dependency)'}
Step-Delete @{Order=53; TableName='cnsmr_accnt_ar_log'; WhereClause=$wCnsmr}

# ── cnsmr_task_itm (must come after ar_log association at 48) ──
Step-Delete @{Order=54; TableName='cnsmr_task_itm'; WhereClause=$wCnsmr}

# ── invc_crrctn chain (FK: dtl children → parent → cnsmr) ──
# [NEW] invc_crrctn_dtl_stgng: FK child of invc_crrctn_trnsctn_stgng — 0 rows
Step-Delete @{Order=55; TableName='invc_crrctn_dtl_stgng'; WhereClause="invc_crrctn_trnsctn_stgng_id IN (SELECT invc_crrctn_trnsctn_stgng_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn_stgng WHERE $wCnsmr)"}
Step-Delete @{Order=56; TableName='invc_crrctn_trnsctn_stgng'; WhereClause=$wCnsmr}
# [NEW] invc_crrctn_dtl: FK child of invc_crrctn_trnsctn — 0 rows
Step-Delete @{Order=57; TableName='invc_crrctn_dtl'; WhereClause="invc_crrctn_trnsctn_id IN (SELECT invc_crrctn_trnsctn_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn WHERE $wCnsmr)"}
Step-Delete @{Order=58; TableName='invc_crrctn_trnsctn'; WhereClause=$wCnsmr}

# ── jdgmnt chain (FK: jdgmnt_addtnl_info → jdgmnt → cnsmr) ──
# [NEW] jdgmnt_addtnl_info: FK child of jdgmnt — 5,237 rows
Step-Delete @{Order=59; TableName='jdgmnt_addtnl_info'; WhereClause="jdgmnt_id IN (SELECT jdgmnt_id FROM crs5_oltp.dbo.jdgmnt WHERE $wCnsmr)"}
Step-Delete @{Order=60; TableName='jdgmnt'; WhereClause=$wCnsmr}

# ── Rltd_Prsn chain (FK: rltd_prsn_tag → Rltd_Prsn → cnsmr) ──
# [NEW] rltd_prsn_tag: FK child of Rltd_Prsn — 0 rows
Step-Delete @{Order=61; TableName='rltd_prsn_tag'; WhereClause="rltd_prsn_id IN (SELECT rltd_prsn_id FROM crs5_oltp.dbo.Rltd_Prsn WHERE $wCnsmr)"}
Step-Delete @{Order=62; TableName='Rltd_Prsn'; WhereClause=$wCnsmr}

# ── cnsmr_chck_rqst chain (FK: children → cnsmr_chck_rqst → cnsmr) ──
# [NEW] cnsmr_accnt_bckt_chck_rqst: FK child of cnsmr_chck_rqst — 55 rows
Step-Delete @{Order=63; TableName='cnsmr_accnt_bckt_chck_rqst'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wCnsmr)"}
# [NEW] cnsmr_chck_btch_log: FK child of cnsmr_chck_rqst — 6 rows
Step-Delete @{Order=64; TableName='cnsmr_chck_btch_log'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wCnsmr)"}
Step-Delete @{Order=65; TableName='cnsmr_chck_rqst'; WhereClause=$wCnsmr}

# ── notice_rqst (must come before schdld_pymnt_instnc which has FK to notice_rqst) ──
Step-Delete @{Order=66; TableName='notice_rqst'; WhereClause=$wCnsmr}

# ── sttlmnt_offr chain — must come before cnsmr_pymnt_instrmnt AND schdld_pymnt_smmry ──
# [NEW] sttlmnt_offr_accnt_assctn: FK child of sttlmnt_offr — 5 rows
Step-Delete @{Order=67; TableName='sttlmnt_offr_accnt_assctn'; WhereClause="sttlmnt_offr_id IN (SELECT sttlmnt_offr_id FROM crs5_oltp.dbo.sttlmnt_offr WHERE $wCnsmr)"}
# [NEW] sttlmnt_offr_systm_dtl: FK child of sttlmnt_offr — 5 rows
Step-Delete @{Order=68; TableName='sttlmnt_offr_systm_dtl'; WhereClause="sttlmnt_offr_id IN (SELECT sttlmnt_offr_id FROM crs5_oltp.dbo.sttlmnt_offr WHERE $wCnsmr)"}
Step-Delete @{Order=69; TableName='sttlmnt_offr'; WhereClause=$wCnsmr}

# ── epp chain (FK: children → epp_pymnt_typ_cnfg → cnsmr_pymnt_instrmnt) ──
# Must come before cnsmr_pymnt_instrmnt
# [NEW] epp_cmmnctn_log: FK child of epp_pymnt_typ_cnfg — 4,945 rows
Step-Delete @{Order=70; TableName='epp_cmmnctn_log'; WhereClause="epp_pymnt_typ_cnfg_id IN (SELECT epp_pymnt_typ_cnfg_id FROM crs5_oltp.dbo.epp_pymnt_typ_cnfg WHERE $wInstrmnt)"}
# [NEW] epp_vrfctn_rspns: FK child of epp_pymnt_typ_cnfg — 8 rows
Step-Delete @{Order=71; TableName='epp_vrfctn_rspns'; WhereClause="epp_pymnt_typ_cnfg_id IN (SELECT epp_pymnt_typ_cnfg_id FROM crs5_oltp.dbo.epp_pymnt_typ_cnfg WHERE $wInstrmnt)"}
# [NEW] epp_pymnt_typ_cnfg: FK child of cnsmr_pymnt_instrmnt — 8 rows
Step-Delete @{Order=72; TableName='epp_pymnt_typ_cnfg'; WhereClause=$wInstrmnt}
# epp_pymnt_rspns: FK to cnsmr_pymnt_instrmnt — must come before it
Step-Delete @{Order=73; TableName='epp_pymnt_rspns'; WhereClause=$wCnsmr}

# ── cpm_pm_assctn (FK to both cnsmr_pymnt_instrmnt AND cnsmr_pymnt_mthd) ──
# [NEW] Must come before both parents — 0 rows
Step-Delete @{Order=74; TableName='cpm_pm_assctn'; WhereClause=$wInstrmnt}

# ── Scheduled payment children (before schdld_pymnt_instnc) ──
# [NEW] pymnt_schdl_notice_rqst_assctn: FK child of schdld_pymnt_instnc — 0 rows
Step-Delete @{Order=75; TableName='pymnt_schdl_notice_rqst_assctn'; WhereClause="schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE $wSmmry)"}
Step-Delete @{Order=76; TableName='schdld_pymnt_cnsmr_accnt_assctn'; WhereClause=$wSmmry; PassDescription='via smmry'}
 
# ── Agent credit chain [EXCL] — must clear before cnsmr_pymnt_jrnl ──
# agnt_crdt has FK on cnsmr_pymnt_jrnl_id
# [NEW][EXCL] agnt_crdt_spprssn: FK child of agnt_crdt — 0 rows
Step-Delete @{Order=77; TableName='agnt_crdt_spprssn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE $wJrnl)"; PassDescription='[EXCL] via pymnt_jrnl'}
# [NEW][EXCL] agnt_crdtbl_actvty_crdt_assctn: FK child of agnt_crdt — 1.4M rows
Step-Delete @{Order=78; TableName='agnt_crdtbl_actvty_crdt_assctn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE $wJrnl)"; PassDescription='[EXCL] Pass 1: via pymnt_jrnl'}
# [NEW][EXCL] agnt_crdt: FK child of cnsmr_pymnt_jrnl — 13.6M rows
Step-Delete @{Order=79; TableName='agnt_crdt'; WhereClause=$wJrnl; PassDescription='[EXCL] via pymnt_jrnl'}
 
# ── Payment journal children (must clear before cnsmr_pymnt_jrnl) ──
# [NEW] cnsmr_chck_trnsctn: FK child of cnsmr_pymnt_jrnl — 11 rows
Step-Delete @{Order=80; TableName='cnsmr_chck_trnsctn'; WhereClause=$wJrnl; PassDescription='via pymnt_jrnl'}
 
Step-JoinDelete @{
    Order = 81; TableName = 'cpj_rvrsl_assctn'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.cpj_rvrsl_assctn WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cpj_rvrsl_assctn WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
    PassDescription = 'via pymnt_jrnl'
}
 
# cnsmr_pymnt_jrnl_schdld_pymnt_instnc: FK to BOTH cnsmr_pymnt_jrnl AND schdld_pymnt_instnc
# Must come before cnsmr_pymnt_jrnl — schdld_pymnt_instnc already cleared at 79
Step-JoinDelete @{
    Order = 82; TableName = 'cnsmr_pymnt_jrnl_schdld_pymnt_instnc'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
    PassDescription = 'Pass 1: via pymnt_jrnl'
}
 
Step-JoinDelete @{
    Order = 83; TableName = 'cnsmr_pymnt_jrnl_schdld_pymnt_instnc'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"
    PassDescription = 'Pass 2: via smmry'
}
 
# ── cnsmr_pymnt_jrnl — all children now cleared ──
# FK to cnsmr_pymnt_instrmnt AND sspns_cnsmr_imprt_trnsctn (both deleted later)
Step-Delete @{Order=84; TableName='cnsmr_pymnt_jrnl'; WhereClause=$wCnsmr}
 
# ── schdld_pymnt_instnc — cnsmr_pymnt_jrnl_schdld_pymnt_instnc cleared above ──
# FK to cnsmr_pymnt_instrmnt and notice_rqst (notice_rqst cleared at 66)
Step-Delete @{Order=85; TableName='schdld_pymnt_instnc'; WhereClause=$wSmmry; PassDescription='via smmry'}
 
# ── Suspense chain — must come after cnsmr_pymnt_jrnl (which has FK to sspns_cnsmr_imprt_trnsctn) ──
# [NEW] sspns_cnsmr_trnsctn_log: FK child of sspns_cnsmr_imprt_trnsctn — 1.6M rows
Step-Delete @{Order=86; TableName='sspns_cnsmr_trnsctn_log'; WhereClause="sspns_cnsmr_imprt_trnsctn_id IN (SELECT sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE $wInstrmnt)"; PassDescription='via pymnt_instrmnt'}
 
Step-JoinDelete @{
    Order = 87; TableName = 'sspns_cnsmr_imprt_trnsctn'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
    PassDescription = 'via pymnt_instrmnt'
}
 
# ── Agent creditable activity chain [EXCL] — Pass 2: via direct cnsmr_id ──
# Catches any agnt_crdtbl_actvty rows not reached through the ar_log path (orders 49-51)
 
Step-JoinDelete @{
    Order = 88; TableName = 'agnt_crdtbl_actvty_spprssn'
    DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"
    PassDescription = '[EXCL] Pass 2: via direct cnsmr_id'
}
 
Step-JoinDelete @{
    Order = 89; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
    DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers)"
    PassDescription = '[EXCL] Pass 2: via direct cnsmr_id'
}
 
Step-Delete @{Order=90; TableName='agnt_crdtbl_actvty'; WhereClause=$wCnsmr; PassDescription='[EXCL] Pass 2: via direct cnsmr_id'}
 
# ── cnsmr_pymnt_instrmnt (now safe — ALL FK children cleared above) ──
Step-Delete @{Order=91; TableName='cnsmr_pymnt_instrmnt'; WhereClause=$wCnsmr; PassDescription='Pass 1: direct'}
 
Step-JoinDelete @{
    Order = 92; TableName = 'cnsmr_pymnt_instrmnt'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_instrmnt WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl WHERE cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers))"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_instrmnt WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl WHERE cnsmr_id IN (SELECT cnsmr_id FROM #shell_batch_consumers))"
    PassDescription = 'Pass 2: via pymnt_jrnl'
}
 
# ── cnsmr_pymnt_mthd (now safe — cpm_pm_assctn cleared at 74) ──
Step-Delete @{Order=93; TableName='cnsmr_pymnt_mthd'; WhereClause=$wCnsmr}
 
# ── sspns_trnsctn_cnsmr_idntfr (now safe — sspns_cnsmr_imprt_trnsctn cleared at 87) ──
Step-Delete @{Order=94; TableName='sspns_trnsctn_cnsmr_idntfr'; WhereClause=$wCnsmr}
 
# ── schdld_pymnt_smmry (now safe — all children cleared above) ──
Step-Delete @{Order=95; TableName='schdld_pymnt_smmry'; WhereClause=$wCnsmr}
 
# ── Bankruptcy chain [EXCL] ──
# Currently exclusion-controlled. Legal retention — Operations decision.
# [NEW][EXCL] bnkrptcy_addtnl_info: FK child of bnkrptcy — 348K rows
Step-Delete @{Order=96; TableName='bnkrptcy_addtnl_info'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
# [NEW][EXCL] bnkrptcy_pttnr: FK child of bnkrptcy — 0 rows
Step-Delete @{Order=97; TableName='bnkrptcy_pttnr'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
# [NEW][EXCL] bnkrptcy_trustee: FK child of bnkrptcy — 306K rows
Step-Delete @{Order=98; TableName='bnkrptcy_trustee'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
# [NEW][EXCL] bnkrptcy — 533K rows
Step-Delete @{Order=99; TableName='bnkrptcy'; WhereClause=$wCnsmr; PassDescription='[EXCL]'}
 
# ── hc_payer_plan (direct cnsmr FK, no encntr dependency for shells) ──
Step-Delete @{Order=100; TableName='hc_payer_plan'; WhereClause=$wCnsmr}
 
# ── TERMINAL: cnsmr record itself ──
Step-Delete @{Order=101; TableName='cnsmr'; WhereClause=$wCnsmr}
Write-Log ""
Write-Log "  Consumer-level deletion sequence complete" "SUCCESS"
# ── Finalize batch log ──
$batchStatus = if ($Script:TablesFailed -gt 0) { "Failed" } else { "Success" }
$batchError = if ($Script:TablesFailed -gt 0) { "One or more tables failed during delete sequence" } else { $null }
Update-BatchLogEntry -Status $batchStatus -ErrorMessage $batchError

# ── Update session counters ──
$Script:SessionTotalDeleted += $Script:TotalDeleted
$Script:SessionTotalConsumers += $Script:BatchConsumerIds.Count
if ($batchStatus -eq 'Failed') { $Script:TotalBatchesFailed++ }

# ── Batch summary ──
$batchDuration = (Get-Date) - $Script:BatchStartTime
Write-Log "  Batch #$($Script:TotalBatchesRun): $($Script:BatchConsumerIds.Count) consumers, $($Script:TotalDeleted) rows, $([math]::Round($batchDuration.TotalSeconds, 1))s — $batchStatus" "INFO"

# ── Queue Teams alert on failure ──
if ($batchStatus -eq 'Failed' -and $Script:AlertingEnabled) {
    Send-TeamsAlert -SourceModule 'DmOps' -AlertCategory 'CRITICAL' `
        -Title '{{FIRE}} Shell purge batch failed' `
        -Message "**Batch:** #$($Script:TotalBatchesRun) (batch_id: $($Script:CurrentBatchId))`n**Target:** $($Script:TargetServer)`n**Tables Failed:** $($Script:TablesFailed)`n**Consumers:** $($Script:BatchConsumerIds.Count)`n`nCheck ShellPurge_BatchDetail for batch_id $($Script:CurrentBatchId)." `
        -TriggerType 'SHELL_PURGE_BATCH_FAILED' `
        -TriggerValue "$($Script:CurrentBatchId)" | Out-Null
}
elseif ($batchStatus -eq 'Failed') {
    Write-Log "  Teams alert suppressed — alerting_enabled is off" "INFO"
}

# ============================================================================
# BATCH LOOP CONTINUATION CHECK
# ============================================================================

if ($SingleBatch) {
    Write-Log "  Single batch mode — exiting loop" "INFO"
    $continueProcessing = $false
}
elseif ($batchStatus -eq 'Failed') {
    Write-Log "  Batch failed — stopping further processing" "ERROR"
    $continueProcessing = $false
}
elseif (Test-ShellPurgeAbort) {
    Write-Log "  Shell purge abort flag detected — stopping after batch completion" "WARN"
    $continueProcessing = $false
}
else {
    $nextScheduleValue = Get-ShellPurgeScheduleMode
    if ($nextScheduleValue -eq 0) {
        Write-Log "  Schedule: now in BLOCKED window — stopping" "INFO"
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
            if ($cfg.setting_name -eq 'batch_size')         { $Script:BatchSizeFull = [int]$cfg.setting_value }
            if ($cfg.setting_name -eq 'batch_size_reduced') { $Script:BatchSizeReduced = [int]$cfg.setting_value }
        }

        $newMode = if ($nextScheduleValue -eq 1) { 'Full' } else { 'Reduced' }
        $newBatchSize = if ($nextScheduleValue -eq 1) { $Script:BatchSizeFull } else { $Script:BatchSizeReduced }

        if ($newMode -ne $Script:ScheduleMode -or $newBatchSize -ne $activeBatchSize) {
            Write-Log "  Schedule/config update: $($Script:ScheduleMode) ($activeBatchSize) → $newMode ($newBatchSize)" "INFO"
            $Script:ScheduleMode = $newMode
            $activeBatchSize = $newBatchSize
        }

        Start-Sleep -Seconds 2
    }
}

}  # end while ($continueProcessing)

# ============================================================================
# CLEANUP
# ============================================================================

Close-TargetConnection

# ============================================================================
# SESSION SUMMARY
# ============================================================================

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart
$totalMs = [int]$scriptDuration.TotalMilliseconds

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Session Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "  Mode            : $(if ($previewOnly) { 'PREVIEW' } else { 'EXECUTE' })"
Write-Log "  Target          : $($Script:TargetServer)"
Write-Log "  Batches Run     : $($Script:TotalBatchesRun)"
Write-Log "  Batches Failed  : $($Script:TotalBatchesFailed)"
Write-Log "  Total Consumers : $($Script:SessionTotalConsumers)"
if ($previewOnly) {
    Write-Log "  Rows to Delete  : $($Script:SessionTotalDeleted)"
} else {
    Write-Log "  Rows Deleted    : $($Script:SessionTotalDeleted)"
}
Write-Log "  Duration        : $([math]::Round($scriptDuration.TotalSeconds, 1))s"
Write-Host ""

if ($previewOnly) {
    Write-Host "  *** PREVIEW MODE — No changes were made ***" -ForegroundColor Yellow
    Write-Host "  Run with -Execute to perform actual deletions" -ForegroundColor Yellow
    Write-Host ""
}

# Orchestrator callback
if ($TaskId -gt 0) {
    $finalStatus = if ($Script:TotalBatchesFailed -gt 0) { "FAILED" } else { "SUCCESS" }
    $outputSummary = "Batches:$($Script:TotalBatchesRun) Failed:$($Script:TotalBatchesFailed) Consumers:$($Script:SessionTotalConsumers) Deleted:$($Script:SessionTotalDeleted)"
    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}

if ($Script:TotalBatchesFailed -gt 0) { exit 1 } else { exit 0 }
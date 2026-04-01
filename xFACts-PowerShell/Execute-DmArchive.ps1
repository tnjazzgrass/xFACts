<#
.SYNOPSIS
    xFACts - DM Archive Execution (Account-Level)

.DESCRIPTION
    xFACts - DmOps.Archive
    Script: Execute-DmArchive.ps1
    Version: Tracked in dbo.System_Metadata (component: DmOps.Archive)

    Executes account-level data archiving against crs5_oltp. Runs in a
    continuous batch loop: selects a batch of consumers with TA_ARCH-tagged
    accounts, executes the full FK-ordered delete sequence, logs results,
    then checks the schedule and abort flag before starting the next batch.

    Phase 1: Account-level only. Deletes all account child data and the
    cnsmr_accnt record itself. Does not touch consumer-level tables.

    Schedule-aware: reads DmOps.Archive_Schedule to determine execution
    mode per hour (blocked/full/reduced). Checks schedule between batches.
    Emergency abort via GlobalConfig archive_abort flag.

    Full audit trail: Archive_BatchLog (batch summary), Archive_BatchDetail
    (per-table operation detail), Archive_ConsumerLog (every account archived
    with BIDATA migration confirmation).

    The delete sequence is derived from the tested DM_Purge stored procedures
    (sp_DM_Purge_Cnsmr_Accnt_udp, sp_DM_Purge_cnsmr_accnt) with duplicates
    removed, FK ordering validated, and multi-pass tables preserved.

    CHANGELOG
    ---------
    2026-03-24  BIDATA P-to-C migration (Step 6), Anonymize switch,
                bidata_status on BatchLog, bidata_migrated on ConsumerLog
    2026-03-24  Schedule-aware batch loop, batch/detail/consumer logging,
                abort flag, ServerRegistry enable check, Teams alerting
    2026-03-23  Complete refactor — persistent SqlConnection, chunked deletes,
                standard platform initialization, hardcoded delete sequence
    2026-03-23  Initial implementation — registry-driven account-level archiving

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER TargetInstance
    SQL Server instance hosting crs5_oltp to archive from.
    Default: reads from GlobalConfig DmOps.Archive.target_instance.
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

.PARAMETER Anonymize
    Anonymize PII columns during BIDATA P-to-C migration. When off (default),
    rows are copied as-is for testing/verification. When on, PII columns are
    replaced with 'Y' after the copy. Enable for production use.

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
   - DmOps.Archive.target_instance (server hosting crs5_oltp)
   - DmOps.Archive.bidata_instance (server hosting BIDATA database)
   - DmOps.Archive.batch_size (consumers per batch, full mode)
   - DmOps.Archive.batch_size_reduced (consumers per batch, reduced mode)
   - DmOps.Archive.chunk_size (rows per delete chunk, default 5000)
   - DmOps.Archive.archive_abort (emergency shutoff, 0=normal, 1=stop)
   - DmOps.Archive.alerting_enabled (1=on, 0=suppress alerts)
4. ServerRegistry.dmops_archive_enabled must be 1 on the target server.
5. DmOps.Archive_Schedule must have 7 rows with hourly mode values.
6. The TA_ARCH tag must exist in crs5_oltp.dbo.tag.
7. The service account needs DELETE permission on crs5_oltp tables.
8. The service account needs SELECT/INSERT/DELETE on BIDATA Gen* tables.
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
    [switch]$NoAnonymize,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Execute-DmArchive' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# SCRIPT-LEVEL STATE
# ============================================================================

$Script:TargetServer = $null
$Script:TargetConnection = $null  # Persistent SqlConnection to crs5_oltp
$Script:BatchChunkSize = 5000
$Script:BatchSizeFull = 10000
$Script:BatchSizeReduced = 100
$Script:ScheduleMode = $null       # 'Full', 'Reduced', 'Manual', or 'Blocked'
$Script:CurrentBatchId = $null     # Archive_BatchLog.batch_id for current batch
$Script:ManualBatchSize = $false   # True if -BatchSize parameter was specified
$Script:BidataServer = $null
$Script:BidataConnection = $null  # Connection to BIDATA database for P→C migration
$Script:BidataStatus = $null       # Per-batch BIDATA migration status
$Script:AlertingEnabled = $false   # Teams alerting on/off (from GlobalConfig)
$Script:BidataBuildJobName = 'BIDATA Daily Build'  # SQL Agent job name, overridden by GlobalConfig

# Per-batch counters (reset each batch)
$Script:TotalDeleted = 0
$Script:TablesProcessed = 0
$Script:TablesSkipped = 0
$Script:TablesFailed = 0
$Script:BatchConsumerIds = @()
$Script:BatchAccountIds = @()
$Script:BatchAccountData = @()     # Full account data for ConsumerLog

# Session-level counters
$Script:TotalBatchesRun = 0
$Script:TotalBatchesFailed = 0
$Script:SessionTotalDeleted = 0
$Script:SessionTotalConsumers = 0
$Script:SessionTotalAccounts = 0

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

function Open-BidataConnection {
    <#
    .SYNOPSIS
        Opens a SqlConnection to the BIDATA database for P→C migration.
        Separate from the crs5_oltp target connection — BIDATA may be on
        a different server (currently DM-PROD-REP, may move independently).
    #>
    try {
        $connString = "Server=$($Script:BidataServer);Database=BIDATA;Integrated Security=True;Application Name=$($script:XFActsAppName);Connect Timeout=30"
        $Script:BidataConnection = New-Object System.Data.SqlClient.SqlConnection($connString)
        $Script:BidataConnection.Open()
        Write-Log "  BIDATA connection opened to $($Script:BidataServer)/BIDATA" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "  Failed to open BIDATA connection to $($Script:BidataServer): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Close-BidataConnection {
    if ($Script:BidataConnection -and $Script:BidataConnection.State -eq 'Open') {
        $Script:BidataConnection.Close()
        $Script:BidataConnection.Dispose()
        $Script:BidataConnection = $null
        Write-Log "  BIDATA connection closed" "INFO"
    }
}

function Invoke-BidataTableMigration {
    <#
    .SYNOPSIS
        Migrates rows from a GenXxxTblP table to GenXxxTblC for the current
        batch's account IDs. INSERT INTO C SELECT * FROM P, then DELETE FROM P,
        wrapped in a single transaction for atomicity with count validation.
        Returns a hashtable with Inserted and Deleted counts, or throws on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourceTable,
        [Parameter(Mandatory)]
        [string]$DestTable
    )

    $cmd = $Script:BidataConnection.CreateCommand()
    $cmd.CommandTimeout = 300

    try {
        # Count source rows first (for validation)
        $cmd.CommandText = "SELECT COUNT(*) FROM BIDATA.dbo.$SourceTable WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts)"
        $sourceCount = [long]$cmd.ExecuteScalar()

        if ($sourceCount -eq 0) {
            return @{ Inserted = 0; Deleted = 0 }
        }

        # Begin transaction — INSERT then DELETE atomically
        $cmd.CommandText = @"
            BEGIN TRANSACTION;

            INSERT INTO BIDATA.dbo.$DestTable
            SELECT * FROM BIDATA.dbo.$SourceTable
            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts);

            DECLARE @insertCount INT = @@ROWCOUNT;

            DELETE FROM BIDATA.dbo.$SourceTable
            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts);

            DECLARE @deleteCount INT = @@ROWCOUNT;

            -- Validate: inserted count should match source count
            IF @insertCount <> $sourceCount
            BEGIN
                ROLLBACK TRANSACTION;
                RAISERROR('Count mismatch: expected %d, inserted %d', 16, 1, $sourceCount, @insertCount);
                RETURN;
            END

            COMMIT TRANSACTION;

            SELECT @insertCount AS inserted, @deleteCount AS deleted;
"@
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $resultTable = New-Object System.Data.DataTable
        [void]$adapter.Fill($resultTable)
        $adapter.Dispose()

        $inserted = [long]$resultTable.Rows[0].inserted
        $deleted = [long]$resultTable.Rows[0].deleted

        return @{ Inserted = $inserted; Deleted = $deleted }
    }
    catch {
        # Attempt rollback if transaction is still open
        try {
            $rollbackCmd = $Script:BidataConnection.CreateCommand()
            $rollbackCmd.CommandText = "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;"
            $rollbackCmd.ExecuteNonQuery() | Out-Null
            $rollbackCmd.Dispose()
        } catch { }

        throw $_
    }
    finally {
        $cmd.Dispose()
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

function Get-ArchiveScheduleMode {
    $currentHour = (Get-Date).Hour
    $hrCol = "hr{0:D2}" -f $currentHour

    try {
        $result = Get-SqlData -Query @"
            SELECT $hrCol AS schedule_mode
            FROM DmOps.Archive_Schedule
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

function Test-ArchiveAbort {
    try {
        $result = Get-SqlData -Query @"
            SELECT setting_value FROM dbo.GlobalConfig
            WHERE module_name = 'DmOps' AND category = 'Archive'
              AND setting_name = 'archive_abort' AND is_active = 1
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

function Test-BidataBuildInProgress {
    <#
    .SYNOPSIS
        Checks whether the BIDATA Daily Build SQL Agent job is currently
        running on the bidata_instance server. Queries msdb.dbo.sysjobhistory
        directly — no dependency on xFACts BuildExecution tracking.
    .RETURNS
        $true if build is in progress (step rows exist but no step 0 outcome),
        $false if build completed, failed, or hasn't started today.
    #>
    if (-not $Script:BidataServer) {
        Write-Log "  BIDATA pre-flight: bidata_instance not configured — skipping check" "DEBUG"
        return $false
    }

    try {
        $runDateInt = [int](Get-Date).ToString("yyyyMMdd")
        $jobName = $Script:BidataBuildJobName.Replace("'", "''")

        $conn = New-Object System.Data.SqlClient.SqlConnection(
            "Server=$($Script:BidataServer);Database=msdb;Integrated Security=True;Application Name=$($script:XFActsAppName);Connect Timeout=15"
        )
        $conn.Open()

        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 15
        $cmd.CommandText = @"
            SELECT
                COUNT(CASE WHEN h.step_id > 0 THEN 1 END) AS step_count,
                COUNT(CASE WHEN h.step_id = 0 THEN 1 END) AS outcome_count,
                MAX(CASE WHEN h.step_id = 0 THEN h.run_status END) AS outcome_status
            FROM msdb.dbo.sysjobhistory h
            INNER JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
            WHERE j.name = '$jobName'
              AND h.run_date = $runDateInt
"@

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $result = New-Object System.Data.DataTable
        [void]$adapter.Fill($result)
        $adapter.Dispose()
        $cmd.Dispose()
        $conn.Close()
        $conn.Dispose()

        if ($result.Rows.Count -eq 0) {
            return $false
        }

        $stepCount = [int]$result.Rows[0].step_count
        $outcomeCount = [int]$result.Rows[0].outcome_count

        if ($stepCount -eq 0) {
            # No activity today — build hasn't started
            return $false
        }

        if ($outcomeCount -gt 0) {
            # Step 0 exists — build finished (completed or failed)
            $outcomeStatus = $result.Rows[0].outcome_status
            if ($outcomeStatus -isnot [DBNull]) {
                $statusText = switch ([int]$outcomeStatus) {
                    0 { "Failed" }
                    1 { "Succeeded" }
                    2 { "Retry" }
                    3 { "Canceled" }
                    default { "Unknown ($outcomeStatus)" }
                }
                Write-Log "  BIDATA pre-flight: build completed today (status: $statusText)" "DEBUG"
            }
            return $false
        }

        # Steps exist but no outcome — build is in progress
        Write-Log "  BIDATA pre-flight: build is IN PROGRESS ($stepCount steps completed, awaiting outcome)" "WARN"
        return $true
    }
    catch {
        # If we can't check, log and proceed cautiously rather than blocking
        Write-Log "  BIDATA pre-flight: check failed — $($_.Exception.Message). Proceeding cautiously." "WARN"
        return $false
    }
}

# ============================================================================
# BATCH LOGGING FUNCTIONS
# ============================================================================

function New-BatchLogEntry {
    param(
        [string]$ScheduleMode,
        [int]$BatchSizeUsed,
        [long]$RetryOfBatchId = 0
    )
    try {
        $result = Get-SqlData -Query @"
            INSERT INTO DmOps.Archive_BatchLog
                (schedule_mode, batch_size_used, status, executed_by)
            OUTPUT INSERTED.batch_id
            VALUES ('$ScheduleMode', $BatchSizeUsed, 'Running', SUSER_SNAME())
"@
        $Script:CurrentBatchId = [long]$result.batch_id

        if ($RetryOfBatchId -gt 0) {
            # Immediately mark the original failed batch as retried — unconditional
            Invoke-SqlNonQuery -Query @"
                UPDATE DmOps.Archive_BatchLog
                SET batch_retry = 1, retry_batch_id = $($Script:CurrentBatchId)
                WHERE batch_id = $RetryOfBatchId
"@ -Timeout 30 | Out-Null
            Write-Log "  Batch log created: batch_id = $($Script:CurrentBatchId) (retry of batch_id $RetryOfBatchId)" "INFO"
        }
        else {
            Write-Log "  Batch log created: batch_id = $($Script:CurrentBatchId)" "INFO"
        }
    }
    catch {
        Write-Log "  Failed to create batch log: $($_.Exception.Message)" "WARN"
        $Script:CurrentBatchId = $null
    }
}

function Update-BatchLogEntry {
    param(
        [string]$Status,
        [string]$ErrorMessage = $null,
        [string]$BidataStatus = $null
    )
    if (-not $Script:CurrentBatchId) { return }

    $escapedError = if ($ErrorMessage) { $ErrorMessage.Replace("'", "''").Substring(0, [Math]::Min($ErrorMessage.Length, 2000)) } else { $null }
    $errorClause = if ($escapedError) { "'$escapedError'" } else { "NULL" }
    $bidataClause = if ($BidataStatus) { "'$BidataStatus'" } else { "NULL" }

    $durationMs = [int]((Get-Date) - $Script:BatchStartTime).TotalMilliseconds

    try {
        Invoke-SqlNonQuery -Query @"
            UPDATE DmOps.Archive_BatchLog
            SET batch_end_dttm = GETDATE(),
                consumer_count = $($Script:BatchConsumerIds.Count),
                account_count = $($Script:BatchAccountIds.Count),
                total_rows_deleted = $($Script:TotalDeleted),
                tables_processed = $($Script:TablesProcessed),
                tables_skipped = $($Script:TablesSkipped),
                tables_failed = $($Script:TablesFailed),
                duration_ms = $durationMs,
                status = '$Status',
                error_message = $errorClause,
                bidata_status = $bidataClause
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
            INSERT INTO DmOps.Archive_BatchDetail
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
    if (-not $Script:CurrentBatchId -or $Script:BatchAccountData.Count -eq 0) { return }

    try {
        for ($i = 0; $i -lt $Script:BatchAccountData.Count; $i += 900) {
            $batch = $Script:BatchAccountData[$i..[Math]::Min($i + 899, $Script:BatchAccountData.Count - 1)]
            $valuesClause = ($batch | ForEach-Object {
                "($($Script:CurrentBatchId), $($_.cnsmr_id), '$($_.cnsmr_idntfr_agncy_id)', $($_.cnsmr_accnt_id), '$($_.cnsmr_accnt_idntfr_agncy_id)', $($_.crdtr_id))"
            }) -join ",`n                "

            Invoke-SqlNonQuery -Query @"
                INSERT INTO DmOps.Archive_ConsumerLog
                    (batch_id, cnsmr_id, cnsmr_idntfr_agncy_id, cnsmr_accnt_id, cnsmr_accnt_idntfr_agncy_id, crdtr_id)
                VALUES
                    $valuesClause
"@ -Timeout 120 | Out-Null
        }

        Write-Log "  Consumer log: $($Script:BatchAccountData.Count) records written" "SUCCESS"
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
Write-Host "  xFACts DM Archive Execution — Phase 1 (Account-Level)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$previewOnly = -not $Execute

# ============================================================================
# STEP 1: Load Configuration & Pre-Flight Checks
# ============================================================================

Write-Log "--- Step 1: Configuration ---"

# ── Abort flag check (overrides everything) ──
if (Test-ArchiveAbort) {
    Write-Log "Archive abort flag is set — exiting immediately" "WARN"
    exit 0
}

# ── Target instance ──
if ([string]::IsNullOrEmpty($TargetInstance)) {
    $configResult = Get-SqlData -Query @"
        SELECT setting_value FROM dbo.GlobalConfig
        WHERE module_name = 'DmOps' AND category = 'Archive'
          AND setting_name = 'target_instance' AND is_active = 1
"@
    if ($configResult) {
        $Script:TargetServer = $configResult.setting_value
    } else {
        Write-Log "No target_instance configured in GlobalConfig (DmOps.Archive)" "ERROR"
        exit 1
    }
} else {
    $Script:TargetServer = $TargetInstance
}

# ── ServerRegistry enable check (skip if manual target override) ──
if ([string]::IsNullOrEmpty($TargetInstance)) {
    $enabledResult = Get-SqlData -Query @"
        SELECT dmops_archive_enabled
        FROM dbo.ServerRegistry
        WHERE server_name = '$($Script:TargetServer)'
"@
    if (-not $enabledResult -or $enabledResult.dmops_archive_enabled -ne 1) {
        Write-Log "Archive is disabled on $($Script:TargetServer) (ServerRegistry.dmops_archive_enabled)" "WARN"
        exit 0
    }
}

# ── GlobalConfig settings ──
$configResults = Get-SqlData -Query @"
    SELECT setting_name, setting_value FROM dbo.GlobalConfig
    WHERE module_name = 'DmOps' AND category = 'Archive' AND is_active = 1
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
if ($configMap.ContainsKey('bidata_instance'))    { $Script:BidataServer = $configMap['bidata_instance'] }
if ($configMap.ContainsKey('alerting_enabled'))   { $Script:AlertingEnabled = $configMap['alerting_enabled'] -eq '1' }
if ($configMap.ContainsKey('bidata_build_job_name'))  { $Script:BidataBuildJobName = $configMap['bidata_build_job_name'] }

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
    $scheduleValue = Get-ArchiveScheduleMode
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

# ── BIDATA build pre-flight check ──
if (Test-BidataBuildInProgress) {
    Write-Log "BIDATA Daily Build is in progress on $($Script:BidataServer) — exiting to avoid contention" "WARN"
    exit 0
}

Write-Log "  Target Instance : $($Script:TargetServer)"
Write-Log "  BIDATA Instance : $(if ($Script:BidataServer) { $Script:BidataServer } else { '(not configured)' })"
Write-Log "  xFACts Instance : $ServerInstance"
Write-Log "  Schedule Mode   : $($Script:ScheduleMode)"
Write-Log "  Batch Size      : $activeBatchSize consumers"
Write-Log "  Chunk Size      : $($Script:BatchChunkSize) rows per delete"
Write-Log "  Anonymize       : $(if (-not $NoAnonymize) { 'Yes' } else { 'No (testing mode)' })"
Write-Log "  Alerting        : $(if ($Script:AlertingEnabled) { 'Enabled' } else { 'Disabled' })"
Write-Log "  Loop Mode       : $(if ($SingleBatch) { 'Single batch' } else { 'Continuous' })"
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
$Script:BatchAccountIds = @()
$Script:BatchAccountData = @()
$Script:StopProcessing = $false
$Script:BatchStartTime = Get-Date
$Script:BidataStatus = $null
$Script:RetryOfBatchId = 0

$Script:TotalBatchesRun++

# ============================================================================
# STEP 3: Select Batch (Retry or Normal)
#
# Check for failed batches first. If any exist, load from ConsumerLog.
# Otherwise, select new consumers via TA_ARCH tag query.
# ============================================================================

# ── Check for unresolved failed batches ──
$failedBatchId = $null
try {
    $failedResult = Get-SqlData -Query @"
        SELECT TOP 1 batch_id
        FROM DmOps.Archive_BatchLog
        WHERE status = 'Failed' AND batch_retry = 0
        ORDER BY batch_id ASC
"@
    if ($failedResult -and $failedResult.batch_id) {
        $failedBatchId = [long]$failedResult.batch_id
    }
}
catch {
    Write-Log "  Failed to check for failed batches: $($_.Exception.Message)" "WARN"
}

if ($failedBatchId) {
    # ══════════════════════════════════════════════════════════════════
    # RETRY PATH: Load batch from ConsumerLog for failed batch
    # ══════════════════════════════════════════════════════════════════

    $Script:RetryOfBatchId = $failedBatchId

    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host "  RETRY Batch #$($Script:TotalBatchesRun) — retrying failed batch_id $failedBatchId" -ForegroundColor Yellow
    Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host ""

    Write-Log "--- Step 3: Load Batch from ConsumerLog (retry of batch_id $failedBatchId) ---"

    try {
        $retryData = Get-SqlData -Query @"
            SELECT DISTINCT
                cnsmr_id, cnsmr_idntfr_agncy_id,
                cnsmr_accnt_id, cnsmr_accnt_idntfr_agncy_id,
                crdtr_id
            FROM DmOps.Archive_ConsumerLog
            WHERE batch_id = $failedBatchId
"@
    }
    catch {
        Write-Log "  Failed to load ConsumerLog for batch $failedBatchId : $($_.Exception.Message)" "ERROR"
        Write-Log "  Cannot retry — stopping" "ERROR"
        Close-TargetConnection
        exit 1
    }

    $retryRows = if ($retryData -is [System.Data.DataTable]) { @($retryData.Rows) } else { @($retryData) }

    if ($retryRows.Count -eq 0) {
        Write-Log "  No ConsumerLog records found for batch $failedBatchId — cannot retry" "ERROR"
        Close-TargetConnection
        exit 1
    }

    # Build PowerShell arrays from ConsumerLog data
    $Script:BatchConsumerIds = New-Object System.Collections.Generic.List[long]
    $Script:BatchAccountIds = New-Object System.Collections.Generic.List[long]
    $Script:BatchAccountData = New-Object System.Collections.Generic.List[PSObject]
    $agencyMap = @{}

    foreach ($row in $retryRows) {
        $cid = [long]$row.cnsmr_id
        if (-not $Script:BatchConsumerIds.Contains($cid)) {
            $Script:BatchConsumerIds.Add($cid)
        }
        $Script:BatchAccountIds.Add([long]$row.cnsmr_accnt_id)
        $agencyMap[$cid] = [string]$row.cnsmr_idntfr_agncy_id
        $Script:BatchAccountData.Add([PSCustomObject]@{
            cnsmr_id                    = $cid
            cnsmr_idntfr_agncy_id       = [string]$row.cnsmr_idntfr_agncy_id
            cnsmr_accnt_id              = [long]$row.cnsmr_accnt_id
            cnsmr_accnt_idntfr_agncy_id = [string]$row.cnsmr_accnt_idntfr_agncy_id
            crdtr_id                    = [long]$row.crdtr_id
        })
    }

    Write-Log "  Loaded $($Script:BatchConsumerIds.Count) consumers, $($Script:BatchAccountIds.Count) accounts from ConsumerLog" "INFO"
}
else {
    # ══════════════════════════════════════════════════════════════════
    # NORMAL PATH: Select new batch via TA_ARCH tags
    # ══════════════════════════════════════════════════════════════════

    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  Batch #$($Script:TotalBatchesRun) — $($Script:ScheduleMode) mode ($activeBatchSize consumers)" -ForegroundColor DarkCyan
    Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    Write-Log "--- Step 3: Select Batch ---"

    $batchQuery = @"
        SELECT TOP ($activeBatchSize) ca.cnsmr_id
        FROM crs5_oltp.dbo.cnsmr_accnt_tag cat
        INNER JOIN crs5_oltp.dbo.tag t ON cat.tag_id = t.tag_id
        INNER JOIN crs5_oltp.dbo.cnsmr_accnt ca ON cat.cnsmr_accnt_id = ca.cnsmr_accnt_id
        WHERE t.tag_shrt_nm = 'TA_ARCH'
          AND cat.cnsmr_accnt_sft_delete_flg = 'N'
        GROUP BY ca.cnsmr_id
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
        Write-Log "No consumers with active TA_ARCH tagged accounts found — work complete" "INFO"
        $continueProcessing = $false
        break
    }

    $Script:BatchConsumerIds = New-Object System.Collections.Generic.List[long]
    foreach ($row in $batchResult.Rows) {
        $Script:BatchConsumerIds.Add([long]$row.cnsmr_id)
    }

    Write-Log "  Selected $($Script:BatchConsumerIds.Count) consumers" "INFO"
}


# ============================================================================
# STEP 4: Create Temp Tables, Expand Accounts & Pre-Materialize IDs
# ============================================================================

Write-Log "--- Step 4: Load Batch ID Temp Tables ---"

# ── Create core temp tables and load consumer IDs ──
$createTableSQL = @"
    IF OBJECT_ID('tempdb..#archive_batch_accounts') IS NOT NULL DROP TABLE #archive_batch_accounts;
    IF OBJECT_ID('tempdb..#archive_batch_consumers') IS NOT NULL DROP TABLE #archive_batch_consumers;
    CREATE TABLE #archive_batch_accounts (cnsmr_accnt_id BIGINT PRIMARY KEY);
    CREATE TABLE #archive_batch_consumers (cnsmr_id BIGINT PRIMARY KEY);
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
        $insertCmd.CommandText = "INSERT INTO #archive_batch_consumers (cnsmr_id) VALUES $valuesClause"
        $insertCmd.CommandTimeout = 30
        $insertCmd.ExecuteNonQuery() | Out-Null
        $insertCmd.Dispose()
    }
}
catch {
    Write-Log "Failed to create core temp tables: $($_.Exception.Message)" "ERROR"
    Update-BatchLogEntry -Status 'Failed' -ErrorMessage "Temp table creation failed: $($_.Exception.Message)"
    Close-TargetConnection
    exit 1
}

# ── Expand to account IDs ──
if ($Script:RetryOfBatchId -gt 0) {
    # Retry path: load accounts directly from PowerShell array (already populated from ConsumerLog)
    try {
        for ($i = 0; $i -lt $Script:BatchAccountIds.Count; $i += 900) {
            $batch = $Script:BatchAccountIds[$i..[Math]::Min($i + 899, $Script:BatchAccountIds.Count - 1)]
            $valuesClause = ($batch | ForEach-Object { "($_)" }) -join ','
            $insertCmd = $Script:TargetConnection.CreateCommand()
            $insertCmd.CommandText = "INSERT INTO #archive_batch_accounts (cnsmr_accnt_id) VALUES $valuesClause"
            $insertCmd.CommandTimeout = 30
            $insertCmd.ExecuteNonQuery() | Out-Null
            $insertCmd.Dispose()
        }
        Write-Log "  Core temp tables loaded: $($Script:BatchConsumerIds.Count) consumers, $($Script:BatchAccountIds.Count) accounts" "SUCCESS"
    }
    catch {
        Write-Log "Failed to load account temp table: $($_.Exception.Message)" "ERROR"
        Update-BatchLogEntry -Status 'Failed' -ErrorMessage "Account temp table load failed: $($_.Exception.Message)"
        Close-TargetConnection
        exit 1
    }
}
else {
    # Normal path: expand via tag query join
    $accountQuery = @"
        SELECT DISTINCT
            ca.cnsmr_id,
            c.cnsmr_idntfr_agncy_id,
            ca.cnsmr_accnt_id,
            ca.cnsmr_accnt_idntfr_agncy_id,
            ca.crdtr_id
        FROM crs5_oltp.dbo.cnsmr_accnt_tag cat
        INNER JOIN crs5_oltp.dbo.tag t ON cat.tag_id = t.tag_id
        INNER JOIN crs5_oltp.dbo.cnsmr_accnt ca ON cat.cnsmr_accnt_id = ca.cnsmr_accnt_id
        INNER JOIN crs5_oltp.dbo.cnsmr c ON ca.cnsmr_id = c.cnsmr_id
        INNER JOIN #archive_batch_consumers bc ON ca.cnsmr_id = bc.cnsmr_id
        WHERE t.tag_shrt_nm = 'TA_ARCH'
          AND cat.cnsmr_accnt_sft_delete_flg = 'N'
"@

    try {
        $accountResult = Invoke-TargetQuery -Query $accountQuery
    }
    catch {
        Write-Log "Failed to expand accounts: $($_.Exception.Message)" "ERROR"
        Close-TargetConnection
        exit 1
    }

    $Script:BatchAccountIds = New-Object System.Collections.Generic.List[long]
    $Script:BatchAccountData = New-Object System.Collections.Generic.List[PSObject]
    $agencyMap = @{}

    foreach ($row in $accountResult.Rows) {
        $Script:BatchAccountIds.Add([long]$row.cnsmr_accnt_id)
        $agencyMap[[long]$row.cnsmr_id] = [string]$row.cnsmr_idntfr_agncy_id
        $Script:BatchAccountData.Add([PSCustomObject]@{
            cnsmr_id                    = [long]$row.cnsmr_id
            cnsmr_idntfr_agncy_id       = [string]$row.cnsmr_idntfr_agncy_id
            cnsmr_accnt_id              = [long]$row.cnsmr_accnt_id
            cnsmr_accnt_idntfr_agncy_id = [string]$row.cnsmr_accnt_idntfr_agncy_id
            crdtr_id                    = [long]$row.crdtr_id
        })
    }

    Write-Log "  Expanded to $($Script:BatchAccountIds.Count) tagged accounts" "INFO"

    if ($Script:BatchAccountIds.Count -eq 0) {
        Write-Log "No tagged accounts found for selected consumers" "WARN"
        $continueProcessing = $false
        break
    }

    # ── Load account IDs into temp table ──
    try {
        $acctCmd = $Script:TargetConnection.CreateCommand()
        $acctCmd.CommandText = @"
            INSERT INTO #archive_batch_accounts (cnsmr_accnt_id)
            SELECT DISTINCT cat.cnsmr_accnt_id
            FROM crs5_oltp.dbo.cnsmr_accnt_tag cat
            INNER JOIN crs5_oltp.dbo.tag t ON cat.tag_id = t.tag_id
            INNER JOIN crs5_oltp.dbo.cnsmr_accnt ca ON cat.cnsmr_accnt_id = ca.cnsmr_accnt_id
            INNER JOIN #archive_batch_consumers bc ON ca.cnsmr_id = bc.cnsmr_id
            WHERE t.tag_shrt_nm = 'TA_ARCH'
              AND cat.cnsmr_accnt_sft_delete_flg = 'N'
"@
        $acctCmd.CommandTimeout = 60
        $acctInserted = $acctCmd.ExecuteNonQuery()
        $acctCmd.Dispose()

        Write-Log "  Core temp tables loaded: $($Script:BatchConsumerIds.Count) consumers, $acctInserted accounts" "SUCCESS"
    }
    catch {
        Write-Log "Failed to load account temp table: $($_.Exception.Message)" "ERROR"
        Update-BatchLogEntry -Status 'Failed' -ErrorMessage "Account temp table load failed: $($_.Exception.Message)"
        Close-TargetConnection
        exit 1
    }
}

# ── Create batch log entry ──
$retryScheduleMode = if ($Script:RetryOfBatchId -gt 0) { 'Retry' } else { $Script:ScheduleMode }
$retryBatchSize = if ($Script:RetryOfBatchId -gt 0) { $Script:BatchAccountIds.Count } else { $activeBatchSize }
New-BatchLogEntry -ScheduleMode $retryScheduleMode -BatchSizeUsed $retryBatchSize -RetryOfBatchId $Script:RetryOfBatchId

# ── Write consumer log ──
Write-ConsumerLog

$materializeSQL = @"

    IF OBJECT_ID('tempdb..#batch_ar_log_ids') IS NOT NULL DROP TABLE #batch_ar_log_ids;
    SELECT cnsmr_accnt_ar_log_id INTO #batch_ar_log_ids
    FROM crs5_oltp.dbo.cnsmr_accnt_ar_log
    WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #archive_batch_accounts);
    CREATE UNIQUE CLUSTERED INDEX CIX ON #batch_ar_log_ids (cnsmr_accnt_ar_log_id);

    IF OBJECT_ID('tempdb..#batch_trnsctn_ids') IS NOT NULL DROP TABLE #batch_trnsctn_ids;
    SELECT cnsmr_accnt_trnsctn_id INTO #batch_trnsctn_ids
    FROM crs5_oltp.dbo.cnsmr_accnt_trnsctn
    WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #archive_batch_accounts);
    CREATE UNIQUE CLUSTERED INDEX CIX ON #batch_trnsctn_ids (cnsmr_accnt_trnsctn_id);

    IF OBJECT_ID('tempdb..#batch_pmtjrnl_ids') IS NOT NULL DROP TABLE #batch_pmtjrnl_ids;
    SELECT cnsmr_accnt_pymnt_jrnl_id INTO #batch_pmtjrnl_ids
    FROM crs5_oltp.dbo.cnsmr_accnt_pymnt_jrnl
    WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #archive_batch_accounts);
    CREATE UNIQUE CLUSTERED INDEX CIX ON #batch_pmtjrnl_ids (cnsmr_accnt_pymnt_jrnl_id);

    IF OBJECT_ID('tempdb..#batch_pmtjrnl_trnsctn_ids') IS NOT NULL DROP TABLE #batch_pmtjrnl_trnsctn_ids;
    SELECT cnsmr_accnt_trnsctn_id INTO #batch_pmtjrnl_trnsctn_ids
    FROM crs5_oltp.dbo.cnsmr_accnt_trnsctn
    WHERE cnsmr_accnt_pymnt_jrnl_id IN (SELECT cnsmr_accnt_pymnt_jrnl_id FROM #batch_pmtjrnl_ids);
    CREATE UNIQUE CLUSTERED INDEX CIX ON #batch_pmtjrnl_trnsctn_ids (cnsmr_accnt_trnsctn_id);

    IF OBJECT_ID('tempdb..#batch_encntr_ids') IS NOT NULL DROP TABLE #batch_encntr_ids;
    SELECT hc_encntr_id INTO #batch_encntr_ids
    FROM crs5_oltp.dbo.hc_encntr
    WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #archive_batch_accounts);
    CREATE UNIQUE CLUSTERED INDEX CIX ON #batch_encntr_ids (hc_encntr_id);

    SELECT
        (SELECT COUNT(*) FROM #batch_ar_log_ids) AS ar_log_count,
        (SELECT COUNT(*) FROM #batch_trnsctn_ids) AS trnsctn_count,
        (SELECT COUNT(*) FROM #batch_pmtjrnl_ids) AS pmtjrnl_count,
        (SELECT COUNT(*) FROM #batch_pmtjrnl_trnsctn_ids) AS pmtjrnl_trnsctn_count,
        (SELECT COUNT(*) FROM #batch_encntr_ids) AS encntr_count;
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

    $arLogCount = [long]$countTable.Rows[0].ar_log_count
    $trnsctnCount = [long]$countTable.Rows[0].trnsctn_count
    $pmtjrnlCount = [long]$countTable.Rows[0].pmtjrnl_count
    $pmtjrnlTrnsctnCount = [long]$countTable.Rows[0].pmtjrnl_trnsctn_count
    $encntrCount = [long]$countTable.Rows[0].encntr_count

    Write-Log "  Intermediate ID tables materialized:" "SUCCESS"
    Write-Log "    AR Log entries:         $arLogCount" "INFO"
    Write-Log "    Transactions (direct):  $trnsctnCount" "INFO"
    Write-Log "    Payment journals:       $pmtjrnlCount" "INFO"
    Write-Log "    Transactions (pymnt):   $pmtjrnlTrnsctnCount" "INFO"
    Write-Log "    Encounters:             $encntrCount" "INFO"
}
catch {
    Write-Log "Failed to create temp tables: $($_.Exception.Message)" "ERROR"
    Update-BatchLogEntry -Status 'Failed' -ErrorMessage "Intermediate temp table creation failed: $($_.Exception.Message)"
    Close-TargetConnection
    exit 1
}

Write-Log ""

# ============================================================================
# STEP 5: Execute Account-Level Deletions
# ============================================================================

Write-Log "--- Step 5: Execute Account-Level Deletions ---"
Write-Log ""

$Script:StopProcessing = $false

$wAcct       = "cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #archive_batch_accounts)"
$wArLog      = "cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
$wTrnsctn    = "cnsmr_accnt_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_trnsctn_ids)"
$wPmtJrnl    = "cnsmr_accnt_pymnt_jrnl_id IN (SELECT cnsmr_accnt_pymnt_jrnl_id FROM #batch_pmtjrnl_ids)"
$wPmtTrnsctn = "cnsmr_accnt_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_pmtjrnl_trnsctn_ids)"
$wEncntr     = "hc_encntr_id IN (SELECT hc_encntr_id FROM #batch_encntr_ids)"
$wPrgrmPlan = "hc_prgrm_plan_id IN (SELECT hc_prgrm_plan_id FROM crs5_oltp.dbo.hc_prgrm_plan WHERE $wEncntr)"

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

# ── Phase 1: Account-Level UDEF Tables (Dynamic Discovery) ──
Write-Log "  Phase 1: Account-Level UDEF Tables (dynamic)" "INFO"

try {
    $udefAcctResult = Invoke-TargetQuery -Query @"
        SELECT t.name AS table_name
        FROM sys.tables t
        INNER JOIN sys.columns c ON t.object_id = c.object_id
        WHERE t.name LIKE 'UDEF%'
          AND c.name = 'cnsmr_accnt_id'
        ORDER BY t.name
"@
    $udefAcctTables = New-Object System.Collections.Generic.List[string]
    foreach ($row in $udefAcctResult.Rows) {
        $udefAcctTables.Add([string]$row.table_name)
    }
    Write-Log "    Discovered $($udefAcctTables.Count) account-level UDEF tables" "INFO"
}
catch {
    Write-Log "  Failed to discover UDEF tables: $($_.Exception.Message)" "ERROR"
    $Script:StopProcessing = $true
}

if (-not $Script:StopProcessing) {
    $udefOrder = 0
    foreach ($udefTable in $udefAcctTables) {
        $udefOrder++
        Step-Delete @{Order="U$udefOrder"; TableName=$udefTable; WhereClause=$wAcct}
    }
}

Write-Log ""

# ── Phase 2: Account-Level Tables ──
# 11 new FK-required tables added, tax_jrsdctn_trnsctn two-pass,
# cnsmr_accnt_ar_log safety re-delete before terminal.
# Tables marked [NEW] were not in the previous sequence.
Write-Log "  Phase 2: Account-Level Tables" "INFO"

Step-Delete @{Order=1; TableName='rcvr_autoassign_grp_log'; WhereClause=$wAcct}
Step-Delete @{Order=2; TableName='dfrrd_cnsmr_accnt'; WhereClause=$wAcct}
Step-Delete @{Order=3; TableName='hc_dfrrd_prgrm_plan'; WhereClause="hc_prgrm_plan_id IN (SELECT hc_prgrm_plan_id FROM crs5_oltp.dbo.hc_prgrm_plan WHERE $wEncntr)"}
Step-Delete @{Order=4; TableName='invc_crrctn_dtl_stgng'; WhereClause="invc_crrctn_trnsctn_stgng_id IN (SELECT invc_crrctn_trnsctn_stgng_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn_stgng WHERE $wTrnsctn)"}
Step-Delete @{Order=5; TableName='invc_crrctn_trnsctn_stgng'; WhereClause=$wTrnsctn}
Step-Delete @{Order=6; TableName='hc_prgrm_plan_trnsctn_log'; WhereClause="hc_prgrm_plan_id IN (SELECT hc_prgrm_plan_id FROM crs5_oltp.dbo.hc_prgrm_plan WHERE $wEncntr)"}
Step-Delete @{Order=7; TableName='cnsmr_accnt_rndm_nmbr'; WhereClause=$wAcct}
Step-Delete @{Order=8; TableName='cnsmr_accnt_strtgy_log'; WhereClause=$wAcct}
Step-Delete @{Order=9; TableName='cnsmr_accnt_strtgy_wrk_actn'; WhereClause=$wAcct}
Step-Delete @{Order=10; TableName='cnsmr_accnt_wrkgrp_assctn'; WhereClause=$wAcct}
Step-Delete @{Order=11; TableName='cnsmr_accnt_srvc_rqst'; WhereClause=$wAcct}
Step-Delete @{Order=12; TableName='cnsmr_accnt_rehab_pymnt_optn'; WhereClause="cnsmr_accnt_rehab_dtl_id IN (SELECT cnsmr_accnt_rehab_dtl_id FROM crs5_oltp.dbo.cnsmr_accnt_rehab_dtl WHERE $wAcct)"}
Step-Delete @{Order=13; TableName='cnsmr_accnt_rehab_pymnt_tier'; WhereClause=$wAcct}
Step-Delete @{Order=14; TableName='cnsmr_accnt_rehab_dtl'; WhereClause=$wAcct}
Step-Delete @{Order=15; TableName='rcvr_sttmnt_pndng_trnsctn_dtl'; WhereClause=$wTrnsctn}
Step-Delete @{Order=16; TableName='cnsmr_accnt_wrk_actn'; WhereClause=$wAcct}
Step-Delete @{Order=17; TableName='cnsmr_accnt_frwrd_rcll_dtl'; WhereClause=$wAcct}
Step-Delete @{Order=18; TableName='cnsmr_accnt_bckt_sttlmnt'; WhereClause="cnsmr_accnt_sttlmnt_id IN (SELECT cnsmr_accnt_sttlmnt_id FROM crs5_oltp.dbo.cnsmr_accnt_Sttlmnt WHERE $wAcct)"; PassDescription='Pass 1: via direct sttlmnt'}
Step-Delete @{Order=19; TableName='cnsmr_accnt_Sttlmnt'; WhereClause=$wAcct; PassDescription='Pass 1: direct'}
Step-Delete @{Order=20; TableName='cnsmr_accnt_loan_dtl_wrk_actn'; WhereClause="cnsmr_accnt_loan_dtl_id IN (SELECT cnsmr_accnt_loan_dtl_id FROM crs5_oltp.dbo.cnsmr_accnt_loan_dtl WHERE $wAcct)"}
Step-Delete @{Order=21; TableName='cnsmr_accnt_loan_dtl'; WhereClause=$wAcct}
Step-Delete @{Order=22; TableName='cnsmr_Accnt_Tag'; WhereClause=$wAcct}
Step-Delete @{Order=23; TableName='rcvr_fnncl_trnsctn_exprt_dtl'; WhereClause=$wTrnsctn; PassDescription='Pass 1: via direct trnsctn'}
Step-Delete @{Order=24; TableName='rcvr_sttmnt_of_accnt_dtl'; WhereClause=$wTrnsctn; PassDescription='Pass 1: via direct trnsctn'}
Step-Delete @{Order=25; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause="crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct)"; PassDescription='Pass 1: via crdtr_trnsctn'}
Step-Delete @{Order=26; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause=$wTrnsctn; PassDescription='Pass 2: via cnsmr_accnt_trnsctn'}
Step-Delete @{Order=27; TableName='invc_crrctn_dtl'; WhereClause="invc_crrctn_trnsctn_id IN (SELECT invc_crrctn_trnsctn_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn WHERE $wTrnsctn)"}
Step-Delete @{Order=28; TableName='invc_crrctn_trnsctn'; WhereClause=$wTrnsctn}
Step-Delete @{Order=29; TableName='wash_assctn'; WhereClause="wash_assctn_pymnt_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_trnsctn_ids)"; PassDescription='Pass 1: payment side'}
Step-Delete @{Order=30; TableName='wash_assctn'; WhereClause="wash_assctn_nsf_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_trnsctn_ids)"; PassDescription='Pass 2: NSF side'}
Step-Delete @{Order=31; TableName='cnsmr_accnt_crdt_bru_cnfg'; WhereClause=$wAcct}
Step-Delete @{Order=32; TableName='cnsmr_accnt_trnsctn'; WhereClause=$wAcct; PassDescription='Pass 1: direct'}
Step-Delete @{Order=33; TableName='cb_rpt_assctd_cnsmr_data'; WhereClause=$wAcct}
Step-Delete @{Order=34; TableName='cb_rpt_base_data'; WhereClause=$wAcct}
Step-Delete @{Order=35; TableName='cb_rpt_emplyr_data'; WhereClause=$wAcct}
Step-Delete @{Order=36; TableName='cnsmr_accnt_cnfg'; WhereClause=$wAcct}
# [NEW] crdtr_invc_sctn_trnsctn_dtl has FK on tax_jrsdctn_trnsctn_id — must clear before tax_jrsdctn_trnsctn
Step-Delete @{Order=37; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause="tax_jrsdctn_trnsctn_id IN (SELECT tax_jrsdctn_trnsctn_id FROM crs5_oltp.dbo.tax_jrsdctn_trnsctn WHERE $wTrnsctn)"; PassDescription='Pass 3: via tax_jrsdctn_trnsctn (cnsmr_accnt_trnsctn path)'}
Step-Delete @{Order=38; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause="tax_jrsdctn_trnsctn_id IN (SELECT tax_jrsdctn_trnsctn_id FROM crs5_oltp.dbo.tax_jrsdctn_trnsctn WHERE crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct))"; PassDescription='Pass 4: via tax_jrsdctn_trnsctn (crdtr_trnsctn path)'}
# [NEW] tax_jrsdctn_trnsctn: 914K rows via cnsmr_accnt_trnsctn, 794 rows via crdtr_trnsctn (mutually exclusive paths)
Step-Delete @{Order=39; TableName='tax_jrsdctn_trnsctn'; WhereClause=$wTrnsctn; PassDescription='Pass 1: via cnsmr_accnt_trnsctn'}
Step-Delete @{Order=40; TableName='tax_jrsdctn_trnsctn'; WhereClause="crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct)"; PassDescription='Pass 2: via crdtr_trnsctn'}
Step-Delete @{Order=41; TableName='tax_jrsdctn_accnt_assctn'; WhereClause="tax_jrsdctn_accnt_id IN (SELECT cnsmr_accnt_id FROM crs5_oltp.dbo.cnsmr_accnt WHERE $wAcct)"}
Step-Delete @{Order=42; TableName='cb_rpt_rqst_btch_log'; WhereClause=$wAcct}
Step-Delete @{Order=43; TableName='notice_rqst_cnsmr_accnt'; WhereClause=$wAcct}
Step-Delete @{Order=44; TableName='crdtr_srvc_evnt'; WhereClause=$wAcct; PassDescription='Pass 1: direct cnsmr_accnt_id'}
Step-Delete @{Order=45; TableName='crdtr_srvc_evnt'; WhereClause="crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct)"; PassDescription='Pass 2: via crdtr_trnsctn'}
Step-Delete @{Order=46; TableName='crdtr_trnsctn'; WhereClause=$wAcct}
Step-Delete @{Order=47; TableName='loan_rehab_cntr'; WhereClause="loan_rehab_dtl_id IN (SELECT loan_rehab_dtl_id FROM crs5_oltp.dbo.loan_rehab_dtl WHERE $wAcct)"}
Step-Delete @{Order=48; TableName='loan_rehab_dtl'; WhereClause=$wAcct}
# [NEW] bal_rdctn_plan_stpdwn: child of bal_rdctn_plan (FK: bal_rdctn_plan_id) — 0 rows currently
Step-Delete @{Order=49; TableName='bal_rdctn_plan_stpdwn'; WhereClause="bal_rdctn_plan_id IN (SELECT bal_rdctn_plan_id FROM crs5_oltp.dbo.bal_rdctn_plan WHERE $wAcct)"}
# [NEW] bal_rdctn_plan: direct child of cnsmr_accnt (FK: cnsmr_accnt_id) — 0 rows currently
Step-Delete @{Order=50; TableName='bal_rdctn_plan'; WhereClause=$wAcct}
Step-Delete @{Order=51; TableName='schdld_pymnt_accnt_dstrbtn'; WhereClause=$wAcct}
Step-Delete @{Order=52; TableName='cnsmr_accnt_spplmntl_info'; WhereClause=$wAcct}

Step-Delete @{Order=53; TableName='rcvr_ar_evnt'; WhereClause=$wArLog}
Step-Delete @{Order=54; TableName='crdtr_srvc_evnt'; WhereClause=$wArLog; PassDescription='Pass 3: via ar_log'}
# [NEW] cnsmr_cntct_addrs_log: child of cnsmr_cntct_trnsctn_log (FK: cnsmr_cntct_trnsctn_log_id) — account-level only
Step-Delete @{Order=55; TableName='cnsmr_cntct_addrs_log'; WhereClause="cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log WHERE cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids))"}
# [NEW] cnsmr_cntct_phn_log: same FK path as addrs_log
Step-Delete @{Order=56; TableName='cnsmr_cntct_phn_log'; WhereClause="cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log WHERE cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids))"}
# [NEW] cnsmr_cntct_email_log: same FK path as addrs_log — 0 rows currently
Step-Delete @{Order=57; TableName='cnsmr_cntct_email_log'; WhereClause="cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log WHERE cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids))"}
Step-Delete @{Order=58; TableName='cnsmr_cntct_trnsctn_log'; WhereClause="cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"}
Step-Delete @{Order=59; TableName='agncy_accnt_trnsctn_stgng'; WhereClause="agncy_accnt_trnsctn_id IN (SELECT agncy_accnt_trnsctn_id FROM crs5_oltp.dbo.agncy_accnt_trnsctn WHERE $wArLog)"}
Step-Delete @{Order=60; TableName='agncy_accnt_trnsctn'; WhereClause=$wArLog}
Step-Delete @{Order=61; TableName='img_info_cnsmr_accnt_ar_log_assctn'; WhereClause=$wArLog}

# [NEW] agnt_crdtbl_actvty_spprssn: child of agnt_crdtbl_actvty (FK: agnt_crdtbl_actvty_id) — 0 rows currently
Step-JoinDelete @{
    Order = 62; TableName = 'agnt_crdtbl_actvty_spprssn'
    DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
}

Step-JoinDelete @{
    Order = 63; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
    DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
    PassDescription = 'Pass 1: via ar_log'
}

Step-JoinDelete @{
    Order = 64; TableName = 'agnt_crdtbl_actvty'
    DeleteStatement = "DELETE FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
    CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
}

# [NEW] cnsmr_task_itm_cnsmr_accnt_ar_log_assctn: FK to cnsmr_accnt_ar_log (via cnsmr_accnt_ar_log_id) — 0 rows currently
Step-Delete @{Order=65; TableName='cnsmr_task_itm_cnsmr_accnt_ar_log_assctn'; WhereClause=$wArLog}
Step-Delete @{Order=66; TableName='cnsmr_accnt_ar_log'; WhereClause=$wAcct}
Step-Delete @{Order=67; TableName='cnsmr_accnt_bal'; WhereClause=$wAcct}
Step-Delete @{Order=68; TableName='cnsmr_accnt_bckt_bal_rprtng'; WhereClause=$wAcct}
Step-Delete @{Order=69; TableName='schdld_pymnt_cnsmr_accnt_assctn'; WhereClause=$wAcct}
Step-Delete @{Order=70; TableName='cnsmr_accnt_Cmmnt'; WhereClause=$wAcct}
Step-Delete @{Order=71; TableName='cnsmr_accnt_frwrd_rcll'; WhereClause=$wAcct}
Step-Delete @{Order=72; TableName='pymnt_arrngmnt_accnt_dstrbtn'; WhereClause=$wAcct}

if ($pmtjrnlCount -gt 0 -and -not $Script:StopProcessing) {
    Write-Log "    Payment journal chain: $pmtjrnlCount rows — processing Pass 2 tables" "INFO"

    Step-Delete @{Order=73; TableName='cnsmr_accnt_Sttlmnt'; WhereClause="cnsmr_accnt_sttlmnt_pymnt_jrnl_id IN (SELECT cnsmr_accnt_pymnt_jrnl_id FROM #batch_pmtjrnl_ids)"; PassDescription='Pass 2: via pymnt_jrnl'}
    Step-Delete @{Order=74; TableName='cnsmr_accnt_trnsctn'; WhereClause=$wPmtJrnl; PassDescription='Pass 2: via pymnt_jrnl'}
    Step-Delete @{Order=75; TableName='cnsmr_accnt_trnsctn_stgng'; WhereClause=$wPmtJrnl}
    Step-Delete @{Order=76; TableName='pymnt_arrngmnt_accnt_dstrbtn_loan_rehab_cntrbtn'; WhereClause=$wPmtJrnl; PassDescription='Pass 2: via pymnt_jrnl'}
    Step-Delete @{Order=77; TableName='pymnt_arrngmnt_accnt_bckt_dstrbtn'; WhereClause="pymnt_arrngmnt_accnt_dstrbtn_id IN (SELECT pymnt_arrngmnt_accnt_dstrbtn_id FROM crs5_oltp.dbo.pymnt_arrngmnt_accnt_dstrbtn WHERE $wAcct)"}
    Step-Delete @{Order=78; TableName='cnsmr_accnt_bckt_sttlmnt'; WhereClause="cnsmr_accnt_sttlmnt_id IN (SELECT cnsmr_accnt_sttlmnt_id FROM crs5_oltp.dbo.cnsmr_accnt_Sttlmnt WHERE cnsmr_accnt_sttlmnt_pymnt_jrnl_id IN (SELECT cnsmr_accnt_pymnt_jrnl_id FROM #batch_pmtjrnl_ids))"; PassDescription='Pass 2: via pymnt_jrnl chain'}
    Step-Delete @{Order=79; TableName='rcvr_fnncl_trnsctn_exprt_dtl'; WhereClause=$wPmtTrnsctn; PassDescription='Pass 2: via pymnt_jrnl chain'}
    Step-Delete @{Order=80; TableName='rcvr_sttmnt_of_accnt_dtl'; WhereClause=$wPmtTrnsctn; PassDescription='Pass 2: via pymnt_jrnl chain'}
    Step-Delete @{Order=81; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause=$wPmtTrnsctn; PassDescription='Pass 5: via pymnt_jrnl chain'}
} elseif (-not $Script:StopProcessing) {
    Write-Log "    Payment journal chain: no rows — skipping Pass 2 tables (orders 73-81)" "DEBUG"
    $Script:TablesSkipped += 9
}

Step-Delete @{Order=82; TableName='cnsmr_accnt_ownrs'; WhereClause="$wAcct AND cnsmr_accnt_ownrshp_sft_dlt_flg = 'Y'"; PassDescription='soft-deleted only'}
Step-Delete @{Order=83; TableName='crdt_Bureau_Trnsmssn'; WhereClause=$wAcct}
Step-Delete @{Order=84; TableName='cb_rpt_rqst_dtl'; WhereClause="cnsmr_accnt_idntfr_agncy_id IN (SELECT cnsmr_accnt_idntfr_agncy_id FROM crs5_oltp.dbo.cnsmr_accnt WHERE $wAcct)"}
Step-Delete @{Order=85; TableName='cnsmr_accnt_effctv_fee_schdl'; WhereClause=$wAcct}
Step-Delete @{Order=86; TableName='cnsmr_accnt_effctv_intrst_rt'; WhereClause=$wAcct}
# [NEW] sspns_cnsmr_accnt_bckt_imprt_trnsctn: deepest child in suspense chain — FK to sspns_cnsmr_accnt_imprt_trnsctn
Step-Delete @{Order=87; TableName='sspns_cnsmr_accnt_bckt_imprt_trnsctn'; WhereClause="sspns_cnsmr_accnt_imprt_trnsctn_id IN (SELECT sspns_cnsmr_accnt_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_accnt_imprt_trnsctn WHERE sspns_trnsctn_cnsmr_accnt_idntfr_id IN (SELECT sspns_trnsctn_cnsmr_accnt_idntfr_id FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_accnt_idntfr WHERE $wAcct))"}
# [NEW] sspns_cnsmr_accnt_imprt_trnsctn: FK to sspns_trnsctn_cnsmr_accnt_idntfr
Step-Delete @{Order=88; TableName='sspns_cnsmr_accnt_imprt_trnsctn'; WhereClause="sspns_trnsctn_cnsmr_accnt_idntfr_id IN (SELECT sspns_trnsctn_cnsmr_accnt_idntfr_id FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_accnt_idntfr WHERE $wAcct)"}
Step-Delete @{Order=89; TableName='sspns_trnsctn_cnsmr_accnt_idntfr'; WhereClause=$wAcct}
Step-Delete @{Order=90; TableName='cnsmr_accnt_effctv_mk_whl_cnfg'; WhereClause=$wAcct}
Step-Delete @{Order=91; TableName='ca_case_accnt_assctn'; WhereClause=$wAcct}

Step-Delete @{Order=92; TableName='hc_encntr_code_value_assctn'; WhereClause=$wEncntr}
Step-Delete @{Order=93; TableName='hc_encntr_srvc_claim'; WhereClause=$wEncntr; PassDescription='Pass 1: via encntr'}
Step-Delete @{Order=94; TableName='hc_encntr_srvc_dtl'; WhereClause=$wEncntr}
Step-Delete @{Order=95; TableName='hc_encntr_srvc_prvdr'; WhereClause=$wEncntr}
Step-Delete @{Order=96; TableName='hc_payer_plan'; WhereClause=$wEncntr}
Step-Delete @{Order=97; TableName='hc_ptnt'; WhereClause=$wEncntr}
Step-Delete @{Order=98; TableName='hc_encntr_srvc_code_value_assctn'; WhereClause="hc_encntr_srvc_dtl_id IN (SELECT hc_encntr_srvc_dtl_id FROM crs5_oltp.dbo.hc_encntr_srvc_dtl WHERE $wEncntr)"}
Step-Delete @{Order=99; TableName='hc_encntr_srvc_pymnt_history'; WhereClause="hc_encntr_srvc_dtl_id IN (SELECT hc_encntr_srvc_dtl_id FROM crs5_oltp.dbo.hc_encntr_srvc_dtl WHERE $wEncntr)"}
Step-Delete @{Order=100; TableName='hc_physcn'; WhereClause="hc_encntr_srvc_dtl_id IN (SELECT hc_encntr_srvc_dtl_id FROM crs5_oltp.dbo.hc_encntr_srvc_dtl WHERE $wEncntr)"}
Step-Delete @{Order=101; TableName='hc_encntr_srvc_claim'; WhereClause="hc_payer_plan_id IN (SELECT hc_payer_plan_id FROM crs5_oltp.dbo.hc_payer_plan WHERE $wEncntr)"; PassDescription='Pass 2: via payer_plan'}
Step-Delete @{Order=102; TableName='hc_encntr_ptnt_cndtn_assctn'; WhereClause="hc_ptnt_id IN (SELECT hc_ptnt_id FROM crs5_oltp.dbo.hc_ptnt WHERE $wEncntr)"}

Step-Delete @{Order=103; TableName='hc_prgrm_plan_tag'; WhereClause=$wPrgrmPlan}
Step-Delete @{Order=104; TableName='hc_prgrm_plan_wrk_actn'; WhereClause=$wPrgrmPlan}
Step-Delete @{Order=105; TableName='hc_prgrm_plan'; WhereClause=$wEncntr}
Step-Delete @{Order=106; TableName='hc_encntr'; WhereClause=$wAcct}

Step-Delete @{Order=107; TableName='job_file'; WhereClause=$wAcct}
Step-Delete @{Order=108; TableName='cnsmr_accnt_ownrs'; WhereClause=$wAcct; PassDescription='all remaining'}

# [NEW] sttlmnt_offr_accnt_assctn: direct child of cnsmr_accnt — the accidentally dropped table
Step-Delete @{Order=109; TableName='sttlmnt_offr_accnt_assctn'; WhereClause=$wAcct}

Step-Delete @{Order=110; TableName='pymnt_arrngmnt_accnt_dstrbtn_loan_rehab_cntrbtn'; WhereClause=$wPmtJrnl; PassDescription='Pass 2: via pymnt_jrnl'}
Step-Delete @{Order=111; TableName='cnsmr_accnt_pymnt_jrnl_stgng'; WhereClause=$wPmtJrnl}
Step-Delete @{Order=112; TableName='cnsmr_accnt_pymnt_jrnl'; WhereClause=$wAcct}

Step-Delete @{Order=113; TableName='cnsmr_accnt_bckt_chck_rqst'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wAcct)"}
Step-Delete @{Order=114; TableName='cnsmr_chck_btch_log'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wAcct)"}
Step-Delete @{Order=115; TableName='cnsmr_chck_rqst'; WhereClause=$wAcct}

# Safety re-delete: catch any ar_log rows written by concurrent DM activity during the batch window
Step-Delete @{Order=116; TableName='cnsmr_accnt_ar_log'; WhereClause=$wAcct; PassDescription='Pass 2: safety re-delete'}

Step-Delete @{Order=117; TableName='cnsmr_accnt'; WhereClause=$wAcct}
Write-Log ""
Write-Log "  Account-level deletion sequence complete" "SUCCESS"

# ============================================================================
# STEP 6: BIDATA P→C Migration
# ============================================================================

Write-Log ""
Write-Log "--- Step 6: BIDATA P→C Migration ---"

if ($Script:TablesFailed -gt 0) {
    Write-Log "  Skipping BIDATA migration — delete sequence had failures" "WARN"
    $Script:BidataStatus = 'Skipped'
}
elseif (-not $Script:BidataServer) {
    Write-Log "  Skipping BIDATA migration — bidata_instance not configured" "WARN"
    $Script:BidataStatus = 'Skipped'
}
elseif ($previewOnly) {
    Write-Log "  Skipping BIDATA migration — preview mode" "INFO"
    $Script:BidataStatus = 'Skipped'
}
else {
    # Open BIDATA connection and load batch account IDs into temp table
    $bidataOk = Open-BidataConnection
    if (-not $bidataOk) {
        Write-Log "  BIDATA migration failed — could not connect" "ERROR"
        $Script:BidataStatus = 'Failed'
    }
    else {
        try {
            # Create temp table on BIDATA connection with batch account IDs
            $createCmd = $Script:BidataConnection.CreateCommand()
            $createCmd.CommandText = "IF OBJECT_ID('tempdb..#bidata_batch_accounts') IS NOT NULL DROP TABLE #bidata_batch_accounts; CREATE TABLE #bidata_batch_accounts (cnsmr_accnt_id BIGINT PRIMARY KEY);"
            $createCmd.CommandTimeout = 30
            $createCmd.ExecuteNonQuery() | Out-Null
            $createCmd.Dispose()

            # Populate from PowerShell array in batches of 900
            for ($i = 0; $i -lt $Script:BatchAccountIds.Count; $i += 900) {
                $batch = $Script:BatchAccountIds[$i..[Math]::Min($i + 899, $Script:BatchAccountIds.Count - 1)]
                $valuesClause = ($batch | ForEach-Object { "($_)" }) -join ','
                $insertCmd = $Script:BidataConnection.CreateCommand()
                $insertCmd.CommandText = "INSERT INTO #bidata_batch_accounts (cnsmr_accnt_id) VALUES $valuesClause"
                $insertCmd.CommandTimeout = 30
                $insertCmd.ExecuteNonQuery() | Out-Null
                $insertCmd.Dispose()
            }

            Write-Log "  BIDATA temp table loaded: $($Script:BatchAccountIds.Count) account IDs" "INFO"

            # Define the four P→C table pairs
            $bidataTables = @(
                @{ Order = 'B1'; Source = 'GenAccountTblP';    Dest = 'GenAccountTblC' }
                @{ Order = 'B2'; Source = 'GenAccPayTblP';     Dest = 'GenAccPayTblC' }
                @{ Order = 'B3'; Source = 'GenAccPayAggTblP';  Dest = 'GenAccPayAggTblC' }
                @{ Order = 'B4'; Source = 'GenPaymentTblP';    Dest = 'GenPaymentTblC' }
            )

            $bidataAllOk = $true

            foreach ($tbl in $bidataTables) {
                $stepStart = Get-Date
                try {
                    $result = Invoke-BidataTableMigration -SourceTable $tbl.Source -DestTable $tbl.Dest
                    $stepMs = [int]((Get-Date) - $stepStart).TotalMilliseconds

                    if ($result.Inserted -eq 0) {
                        Write-Log "  [$($tbl.Order)] $($tbl.Source) -> $($tbl.Dest) — no rows, skipping" "DEBUG"
                        Write-BatchDetail -DeleteOrder $tbl.Order -TableName "$($tbl.Source) -> $($tbl.Dest)" `
                            -PassDescription 'P -> C migration' -RowsAffected 0 -DurationMs $stepMs -Status 'Skipped'
                    }
                    else {
                        Write-Log "  [$($tbl.Order)] $($tbl.Source) -> $($tbl.Dest) — migrated $($result.Inserted) rows, deleted $($result.Deleted) from P (${stepMs}ms)" "SUCCESS"
                        Write-BatchDetail -DeleteOrder $tbl.Order -TableName "$($tbl.Source) -> $($tbl.Dest)" `
                            -PassDescription 'P -> C migration' -RowsAffected $result.Inserted -DurationMs $stepMs -Status 'Success'
                    }
                }
                catch {
                    $stepMs = [int]((Get-Date) - $stepStart).TotalMilliseconds
                    Write-Log "  [$($tbl.Order)] $($tbl.Source) → $($tbl.Dest) — FAILED (${stepMs}ms): $($_.Exception.Message)" "ERROR"
                    Write-BatchDetail -DeleteOrder $tbl.Order -TableName "$($tbl.Source) -> $($tbl.Dest)" `
                        -PassDescription 'P -> C migration' -RowsAffected 0 -DurationMs $stepMs -Status 'Failed' -ErrorMessage $_.Exception.Message
                    $bidataAllOk = $false
                    break  # Stop BIDATA processing on first failure
                }
            }

            if ($bidataAllOk) {
                $Script:BidataStatus = 'Success'

            # ── Anonymize PII and set purge flags on C tables ──
                if (-not $NoAnonymize) {
                    $anonymizeStart = Get-Date
                    try {
                        # GenAccountTblC — has ssn column unique to this table
                        $anonCmd = $Script:BidataConnection.CreateCommand()
                        $anonCmd.CommandTimeout = 300
                        $anonCmd.CommandText = @"
                            UPDATE BIDATA.dbo.GenAccountTblC
                            SET first_name = 'Y', last_name = 'Y', middle_name = 'Y',
                                name_prefix = 'Y', name_suffix = 'Y',
                                ssn = 'Y', cnsmr_idntfr_ssn_txt = 'Y',
                                commericial_name = 'Y', regarding = 'Y',
                                city = 'Y', county = 'Y',
                                address1 = 'Y', address2 = 'Y', address3 = 'Y',
                                zip_code = 'Y', state = 'Y',
                                patient_city = 'Y', patient_address = 'Y',
                                patient_state = 'Y', patient_zip = 'Y',
                                patient_dob = NULL, patient_first_name = 'Y', patient_last_name = 'Y',
                                cnsmr_brth_dt = NULL,
                                cnsmr_idntfr_drvr_lcns_txt = 'Y', cnsmr_idntfr_drvr_lcns_issr_txt = 'Y',
                                is_purged = 'Y', purge_date = GETDATE()
                            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts)
"@
                        $anonAcct = $anonCmd.ExecuteNonQuery()
                        $anonCmd.Dispose()

                        # GenAccPayTblC — no ssn column
                        $anonCmd = $Script:BidataConnection.CreateCommand()
                        $anonCmd.CommandTimeout = 300
                        $anonCmd.CommandText = @"
                            UPDATE BIDATA.dbo.GenAccPayTblC
                            SET first_name = 'Y', last_name = 'Y', middle_name = 'Y',
                                name_prefix = 'Y', name_suffix = 'Y',
                                cnsmr_idntfr_ssn_txt = 'Y',
                                commericial_name = 'Y', regarding = 'Y',
                                city = 'Y', county = 'Y',
                                address1 = 'Y', address2 = 'Y', address3 = 'Y',
                                zip_code = 'Y', state = 'Y',
                                patient_city = 'Y', patient_address = 'Y',
                                patient_state = 'Y', patient_zip = 'Y',
                                patient_dob = NULL, patient_first_name = 'Y', patient_last_name = 'Y',
                                cnsmr_brth_dt = NULL,
                                cnsmr_idntfr_drvr_lcns_txt = 'Y', cnsmr_idntfr_drvr_lcns_issr_txt = 'Y',
                                is_purged = 'Y', purge_date = GETDATE()
                            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts)
"@
                        $anonAccPay = $anonCmd.ExecuteNonQuery()
                        $anonCmd.Dispose()

                        # GenAccPayAggTblC — no ssn column
                        $anonCmd = $Script:BidataConnection.CreateCommand()
                        $anonCmd.CommandTimeout = 300
                        $anonCmd.CommandText = @"
                            UPDATE BIDATA.dbo.GenAccPayAggTblC
                            SET first_name = 'Y', last_name = 'Y', middle_name = 'Y',
                                name_prefix = 'Y', name_suffix = 'Y',
                                cnsmr_idntfr_ssn_txt = 'Y',
                                commericial_name = 'Y', regarding = 'Y',
                                city = 'Y', county = 'Y',
                                address1 = 'Y', address2 = 'Y', address3 = 'Y',
                                zip_code = 'Y', state = 'Y',
                                patient_city = 'Y', patient_address = 'Y',
                                patient_state = 'Y', patient_zip = 'Y',
                                patient_dob = NULL, patient_first_name = 'Y', patient_last_name = 'Y',
                                cnsmr_brth_dt = NULL,
                                cnsmr_idntfr_drvr_lcns_txt = 'Y', cnsmr_idntfr_drvr_lcns_issr_txt = 'Y',
                                is_purged = 'Y', purge_date = GETDATE()
                            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts)
"@
                        $anonAccPayAgg = $anonCmd.ExecuteNonQuery()
                        $anonCmd.Dispose()

                        # GenPaymentTblC — no PII columns, only purge flags
                        $anonCmd = $Script:BidataConnection.CreateCommand()
                        $anonCmd.CommandTimeout = 300
                        $anonCmd.CommandText = @"
                            UPDATE BIDATA.dbo.GenPaymentTblC
                            SET is_purged = 'Y', purge_date = GETDATE()
                            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts)
"@
                        $anonPmt = $anonCmd.ExecuteNonQuery()
                        $anonCmd.Dispose()

                        $anonMs = [int]((Get-Date) - $anonymizeStart).TotalMilliseconds
                        Write-Log "  [ANON] Anonymized: Account=$anonAcct, AccPay=$anonAccPay, AccPayAgg=$anonAccPayAgg, Payment=$anonPmt (${anonMs}ms)" "SUCCESS"
                    }
                    catch {
                        $anonMs = [int]((Get-Date) - $anonymizeStart).TotalMilliseconds
                        Write-Log "  [ANON] Anonymization FAILED (${anonMs}ms): $($_.Exception.Message)" "ERROR"
                        # Anonymization failure does not fail the batch — data is migrated, just not scrubbed
                    }
                }
                else {
                    # Not anonymizing — still set purge flags
                    try {
                        $purgeCmd = $Script:BidataConnection.CreateCommand()
                        $purgeCmd.CommandTimeout = 300
                        $purgeCmd.CommandText = @"
                            UPDATE BIDATA.dbo.GenAccountTblC SET is_purged = 'Y', purge_date = GETDATE()
                            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts);
                            UPDATE BIDATA.dbo.GenAccPayTblC SET is_purged = 'Y', purge_date = GETDATE()
                            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts);
                            UPDATE BIDATA.dbo.GenAccPayAggTblC SET is_purged = 'Y', purge_date = GETDATE()
                            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts);
                            UPDATE BIDATA.dbo.GenPaymentTblC SET is_purged = 'Y', purge_date = GETDATE()
                            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts);
"@
                        $purgeCmd.ExecuteNonQuery() | Out-Null
                        $purgeCmd.Dispose()
                        Write-Log "  [PURGE] Purge flags set on all C tables" "SUCCESS"
                    }
                    catch {
                        Write-Log "  [PURGE] Failed to set purge flags: $($_.Exception.Message)" "WARN"
                    }
                }

                # Mark all ConsumerLog records for this batch as BIDATA migrated
                Invoke-SqlNonQuery -Query @"
                    UPDATE DmOps.Archive_ConsumerLog
                    SET bidata_migrated = 1
                    WHERE batch_id = $($Script:CurrentBatchId)
"@ -Timeout 30 | Out-Null

                Write-Log "  BIDATA migration complete — ConsumerLog updated" "SUCCESS"
            }
            else {
                $Script:BidataStatus = 'Failed'
                Write-Log "  BIDATA migration failed — ConsumerLog.bidata_migrated remains 0" "ERROR"
            }
        }
        catch {
            Write-Log "  BIDATA migration failed: $($_.Exception.Message)" "ERROR"
            $Script:BidataStatus = 'Failed'
        }
        finally {
            Close-BidataConnection
        }
    }
}

Write-Log ""

# ── Finalize batch log ──
$batchStatus = if ($Script:TablesFailed -gt 0) { "Failed" }
               elseif ($Script:BidataStatus -eq 'Failed') { "Failed" }
               else { "Success" }
$batchError = if ($Script:TablesFailed -gt 0) { "One or more tables failed during delete sequence" }
              elseif ($Script:BidataStatus -eq 'Failed') { "BIDATA P-to-C migration failed" }
              else { $null }
Update-BatchLogEntry -Status $batchStatus -ErrorMessage $batchError -BidataStatus $Script:BidataStatus

# ── Update session counters ──
$Script:SessionTotalDeleted += $Script:TotalDeleted
$Script:SessionTotalConsumers += $Script:BatchConsumerIds.Count
$Script:SessionTotalAccounts += $Script:BatchAccountIds.Count
if ($batchStatus -eq 'Failed') { $Script:TotalBatchesFailed++ }

# ── Batch summary ──
$batchDuration = (Get-Date) - $Script:BatchStartTime
$retryNote = if ($Script:RetryOfBatchId -gt 0) { " [retry of batch_id $($Script:RetryOfBatchId)]" } else { "" }
Write-Log "  Batch #$($Script:TotalBatchesRun): $($Script:BatchConsumerIds.Count) consumers, $($Script:BatchAccountIds.Count) accounts, $($Script:TotalDeleted) rows, $([math]::Round($batchDuration.TotalSeconds, 1))s — $batchStatus (BIDATA: $($Script:BidataStatus))$retryNote" "INFO"

# ── Queue Teams alert on failure ──
if ($batchStatus -eq 'Failed' -and $Script:AlertingEnabled) {
    Send-TeamsAlert -SourceModule 'DmOps' -AlertCategory 'CRITICAL' `
        -Title '{{FIRE}} Archive batch failed' `
        -Message "**Batch:** #$($Script:TotalBatchesRun) (batch_id: $($Script:CurrentBatchId))$retryNote`n**Target:** $($Script:TargetServer)`n**Tables Failed:** $($Script:TablesFailed)`n**Consumers:** $($Script:BatchConsumerIds.Count)`n**Accounts:** $($Script:BatchAccountIds.Count)`n`nCheck Archive_BatchDetail for batch_id $($Script:CurrentBatchId)." `
        -TriggerType 'ARCHIVE_BATCH_FAILED' `
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
elseif (Test-ArchiveAbort) {
    Write-Log "  Archive abort flag detected — stopping after batch completion" "WARN"
    $continueProcessing = $false
}
elseif (Test-BidataBuildInProgress) {
    Write-Log "  BIDATA Daily Build started on $($Script:BidataServer) — stopping to avoid contention" "WARN"
    $continueProcessing = $false
}
else {
    $nextScheduleValue = Get-ArchiveScheduleMode
    if ($nextScheduleValue -eq 0) {
        Write-Log "  Schedule: now in BLOCKED window — stopping" "INFO"
        $continueProcessing = $false
    }
    else {
        # Re-read batch sizes from GlobalConfig (allows in-flight tuning)
        $refreshConfig = Get-SqlData -Query @"
            SELECT setting_name, setting_value FROM dbo.GlobalConfig
            WHERE module_name = 'DmOps' AND category = 'Archive'
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
Write-Log "  Total Accounts  : $($Script:SessionTotalAccounts)"
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
    $outputSummary = "Batches:$($Script:TotalBatchesRun) Failed:$($Script:TotalBatchesFailed) Consumers:$($Script:SessionTotalConsumers) Accounts:$($Script:SessionTotalAccounts) Deleted:$($Script:SessionTotalDeleted)"
    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}

if ($Script:TotalBatchesFailed -gt 0) { exit 1 } else { exit 0 }
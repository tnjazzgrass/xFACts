<#
.SYNOPSIS
    xFACts - DM Consumer-Level Archive (Unified)

.DESCRIPTION
    xFACts - DmOps.Archive
    Script: Execute-DmConsumerArchive.ps1
    Version: Tracked in dbo.System_Metadata (component: DmOps.Archive)

    Unified consumer-level archive process for crs5_oltp. Replaces the legacy
    account-level archive (Execute-DmArchive.ps1) which is preserved as
    historical reference under Reference/. Selection is driven by the TC_ARCH
    consumer tag, applied nightly by a DM JobFlow job to consumers whose
    every account already carries TA_ARCH. Per batch:

        1. Select TC_ARCH-tagged candidates (TOP-N from cnsmr_Tag)
        2. Runtime re-verification (Pattern B: mirror apply-job eligibility
           logic, inverted, scoped to current batch). Exceptions are removed
           from the batch, soft-delete the TC_ARCH tag, write a CC/CC AR
           event, and log to Archive_ConsumerExceptionLog.
        3. Account-level deletes (Phase 1 UDEFs AU1+, Phase 2 orders A1-A117)
        4. BIDATA P->C migration (orders AB1-AB4, anonymization with per-table
           SET clauses, purge flags). Failure halts the batch — consumer-level
           deletes do not run, leaving the consumer in a recoverable
           near-shell state for retry.
        5. Consumer-level deletes (Phase 1 UDEFs CU1+, Phase 2 orders C1-C110,
           includes order C86 Step-Update for cross-consumer suspense
           reference cleanup)

    Five startup lookups are required and resolved before the persistent
    target connection is opened — four GlobalConfig values
    (tag_removal_actn_cd, tag_removal_rslt_cd, tag_removal_user,
    tag_removal_msg_txt) plus the runtime TC_ARCH tag_id. Any NULL result
    causes a fail-fast exit so configuration problems surface immediately
    instead of mid-batch.

    BIDATA migration sits between the two delete halves by design. Running
    it earlier risks duplicate C-row creation if the next BIDATA build
    repopulates P from OLTP after a delete failure. Running it later risks
    losing the financial snapshot entirely if account deletes succeed but
    consumer-level deletes fail. The mid-batch position keeps the consumer
    in a recoverable state at every fail point.

    Does NOT replace Execute-DmShellPurge.ps1 — shell purge runs
    independently for naturally-occurring shells (existing WFAPURGE backlog
    plus ongoing shells from new-business loads, consumer merges, manual
    activity). The two processes operate on disjoint populations.

    Schedule-aware: reads DmOps.Archive_Schedule to determine execution
    mode per hour (blocked/full/reduced). Checks schedule between batches.
    Emergency abort via GlobalConfig archive_abort flag. Stops gracefully
    when the BIDATA Daily Build SQL Agent job starts to avoid contention.

    Failed batches retry from Archive_ConsumerLog on the next run (Retry
    schedule_mode). Retry path skips re-verification — consumers in
    ConsumerLog have already passed re-verification once and are past the
    point of no return.

    Preview vs Execute: when the -Execute switch is omitted, the script
    runs in PREVIEW mode and performs no writes anywhere — no row inserts
    into Archive_BatchLog/BatchDetail/ConsumerLog/ConsumerExceptionLog,
    no UPDATE/INSERT against crs5_oltp tables, no BIDATA migration. The
    only outputs are console + log file (via Write-Log) showing what
    each step would do. Step 3.5 re-verification still runs its SELECT
    queries to identify exceptions for accurate preview reporting, but
    no exception writes occur.

    Full audit trail (execute mode only):
        Archive_BatchLog             - batch summary, exception_count,
                                       bidata_status, retry linkage
        Archive_BatchDetail          - per-table per-pass operation detail
        Archive_ConsumerLog          - every (consumer, account) pair processed
        Archive_ConsumerExceptionLog - every consumer excepted by Step 3.5

    CHANGELOG
    ---------
    2026-04-26  Initial unified consumer archive implementation. Replaces
                account-level Execute-DmArchive.ps1 (moved to Reference/).
                Combines TC_ARCH-driven batch selection, runtime
                re-verification, account-level Phase 2 deletes (orders
                A1-A117), BIDATA P->C migration (orders AB1-AB4) with
                anonymization, and consumer-level Phase 2 deletes (orders
                C1-C110, including C86 Step-Update for cross-consumer
                suspense reference cleanup) into a single batch flow
                targeting the cnsmr terminal table. Logging functions
                are guarded by $script:XFActsExecute so preview mode is
                console-only with zero database writes.

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER TargetInstance
    SQL Server instance hosting crs5_oltp to archive from.
    Default: reads from GlobalConfig DmOps.Archive.target_instance.
    Override for testing against non-production environments.

.PARAMETER BatchSize
    Number of consumers to select per batch. Default: reads from
    GlobalConfig based on schedule mode. Override with -BatchSize for
    testing — sets schedule_mode to 'Manual'.

.PARAMETER ChunkSize
    Rows per chunked DELETE/UPDATE inside a single delete operation.
    Default: reads from GlobalConfig DmOps.Archive.chunk_size.

.PARAMETER Execute
    Switch. Without this switch the script runs in PREVIEW mode — counts
    rows and emits console + log file output, but performs NO writes
    anywhere (no audit table inserts, no crs5_oltp DELETE/UPDATE/INSERT,
    no BIDATA migration). With -Execute, all operations run normally.

.PARAMETER NoAnonymize
    Switch. When set, skips PII anonymization on the BIDATA C tables
    after migration. Purge flags (is_purged='Y', purge_date=GETDATE()) are
    still applied. Anonymization is the production default; this switch
    is for diagnostic scenarios where anonymization is undesirable.

.PARAMETER SingleBatch
    Switch. Run exactly one batch and exit. Skips the schedule-driven
    continuation loop.

.PARAMETER TaskId
    Orchestrator task ID for callback. When > 0, completion status is
    reported via Complete-OrchestratorTask. Default: 0 (no callback).

.PARAMETER ProcessId
    Orchestrator process ID, paired with TaskId for the callback. Default: 0.

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. Deploy to E:\xFACts-PowerShell on FA-SQLDBB.
2. xFACts-OrchestratorFunctions.ps1 must be in the same directory.
3. GlobalConfig entries required (DmOps.Archive):
   - target_instance        (server hosting crs5_oltp)
   - bidata_instance        (server hosting BIDATA database)
   - batch_size             (consumers per batch, full mode)
   - batch_size_reduced     (consumers per batch, reduced mode)
   - chunk_size             (rows per delete chunk, default 5000)
   - archive_abort          (emergency shutoff, 0=normal, 1=stop)
   - alerting_enabled       (1=on, 0=suppress alerts)
   - bidata_build_job_name  (SQL Agent job name to monitor)
   - tag_removal_actn_cd    (default 'CC' — resolved to actn_cd at startup)
   - tag_removal_rslt_cd    (default 'CC' — resolved to rslt_cd at startup)
   - tag_removal_user       (default 'sqlmon' — resolved to usr_id at startup)
   - tag_removal_msg_txt    (AR event message text used during exception writes)
4. ServerRegistry.dmops_archive_enabled must be 1 on the target server.
5. DmOps.Archive_Schedule must have 7 rows with hourly mode values.
6. The TC_ARCH tag must exist in crs5_oltp.dbo.tag (active).
7. The TA_ARCH tag must exist in crs5_oltp.dbo.tag (active).
8. The service account needs DELETE/UPDATE/INSERT permission on crs5_oltp.
9. The service account needs SELECT/INSERT/DELETE on BIDATA Gen* tables.
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
    [switch]$NoAnonymize,
    [switch]$SingleBatch,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Execute-DmConsumerArchive' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# SCRIPT-LEVEL STATE
# ============================================================================

# ── Connections ──
$Script:TargetServer            = $null   # crs5_oltp host (resolved from GlobalConfig or -TargetInstance)
$Script:TargetConnection        = $null   # Persistent SqlConnection to crs5_oltp
$Script:BidataServer            = $null   # BIDATA host (resolved from GlobalConfig)
$Script:BidataConnection        = $null   # Persistent SqlConnection to BIDATA

# ── Configuration (defaults overridden from GlobalConfig in Step 1) ──
$Script:BatchChunkSize          = 5000
$Script:BatchSizeFull           = 10000
$Script:BatchSizeReduced        = 100
$Script:ManualBatchSize         = $false
$Script:AlertingEnabled         = $false
$Script:BidataBuildJobName      = 'BIDATA Daily Build'

# ── Resolved startup lookups (Step 1, fail-fast) ──
$Script:TcArchTagId             = $null
$Script:TagRemovalActnCd        = $null
$Script:TagRemovalRsltCd        = $null
$Script:TagRemovalUserId        = $null
$Script:TagRemovalMsgTxt        = $null

# ── Schedule state ──
$Script:ScheduleMode            = $null   # 'Full' | 'Reduced' | 'Manual' | 'Retry' | 'Blocked'

# ── Per-batch state (reset each batch) ──
$Script:CurrentBatchId          = $null
$Script:BatchStartTime          = $null
$Script:BatchConsumerIds        = @()
$Script:BatchAccountIds         = @()
$Script:BatchAccountData        = @()
$Script:BatchExceptions         = @()
$Script:TotalDeleted            = 0
$Script:TablesProcessed         = 0
$Script:TablesSkipped           = 0
$Script:TablesFailed            = 0
$Script:StopProcessing          = $false
$Script:BidataStatus            = $null
$Script:RetryOfBatchId          = 0

# ── Session-level counters ──
$Script:TotalBatchesRun         = 0
$Script:TotalBatchesFailed      = 0
$Script:SessionTotalDeleted     = 0
$Script:SessionTotalConsumers   = 0
$Script:SessionTotalAccounts    = 0
$Script:SessionTotalExceptions  = 0

# ============================================================================
# CONNECTION FUNCTIONS
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
        Opens a SqlConnection to the BIDATA database for P->C migration.
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

# ============================================================================
# STARTUP LOOKUPS (Step 1, fail-fast)
# ============================================================================

function Resolve-StartupLookups {
    <#
    .SYNOPSIS
        Resolves the five startup lookups required for runtime re-verification:
        - $Script:TcArchTagId         from crs5_oltp.dbo.tag
        - $Script:TagRemovalActnCd    from crs5_oltp.dbo.actn_cd
        - $Script:TagRemovalRsltCd    from crs5_oltp.dbo.rslt_cd
        - $Script:TagRemovalUserId    from crs5_oltp.dbo.usr
        - $Script:TagRemovalMsgTxt    from dbo.GlobalConfig (no lookup, raw value)
        All five must resolve to non-NULL values; any failure returns $false
        so the caller can fail-fast before opening the persistent connection.
    .RETURNS
        $true on success, $false if any lookup failed.
    #>
    param(
        [hashtable]$ConfigMap
    )

    $actnShortVal = $ConfigMap['tag_removal_actn_cd']
    $rsltShortVal = $ConfigMap['tag_removal_rslt_cd']
    $userShortVal = $ConfigMap['tag_removal_user']
    $msgTxt       = $ConfigMap['tag_removal_msg_txt']

    if ([string]::IsNullOrEmpty($actnShortVal) -or [string]::IsNullOrEmpty($rsltShortVal) -or
        [string]::IsNullOrEmpty($userShortVal) -or [string]::IsNullOrEmpty($msgTxt)) {
        Write-Log "Missing one or more required GlobalConfig values: tag_removal_actn_cd, tag_removal_rslt_cd, tag_removal_user, tag_removal_msg_txt" "ERROR"
        return $false
    }

    $Script:TagRemovalMsgTxt = $msgTxt

    try {
        $connString = "Server=$($Script:TargetServer);Database=crs5_oltp;Integrated Security=True;Application Name=$($script:XFActsAppName);Connect Timeout=30"
        $tempConn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $tempConn.Open()
    }
    catch {
        Write-Log "Failed to open lookup connection to $($Script:TargetServer): $($_.Exception.Message)" "ERROR"
        return $false
    }

    try {
        # ── 1. Resolve TC_ARCH tag_id ──
        $cmd = $tempConn.CreateCommand()
        $cmd.CommandText = "SELECT tag_id FROM crs5_oltp.dbo.tag WHERE tag_shrt_nm = 'TC_ARCH' AND tag_actv_flg = 'Y'"
        $cmd.CommandTimeout = 30
        $r = $cmd.ExecuteScalar()
        $cmd.Dispose()
        if ($r -is [DBNull] -or $null -eq $r) {
            Write-Log "Lookup failed: tag.tag_id for TC_ARCH (active)" "ERROR"
            return $false
        }
        $Script:TcArchTagId = [long]$r

        # ── 2. Resolve actn_cd ──
        $cmd = $tempConn.CreateCommand()
        $cmd.CommandText = "SELECT actn_cd FROM crs5_oltp.dbo.actn_cd WHERE actn_cd_shrt_val_txt = '$($actnShortVal.Replace("'", "''"))' AND actn_cd_actv_flg = 'Y'"
        $cmd.CommandTimeout = 30
        $r = $cmd.ExecuteScalar()
        $cmd.Dispose()
        if ($r -is [DBNull] -or $null -eq $r) {
            Write-Log "Lookup failed: actn_cd for short value '$actnShortVal' (active)" "ERROR"
            return $false
        }
        $Script:TagRemovalActnCd = [int]$r

        # ── 3. Resolve rslt_cd ──
        $cmd = $tempConn.CreateCommand()
        $cmd.CommandText = "SELECT rslt_cd FROM crs5_oltp.dbo.rslt_cd WHERE rslt_cd_shrt_val_txt = '$($rsltShortVal.Replace("'", "''"))' AND rslt_cd_actv_flg = 'Y'"
        $cmd.CommandTimeout = 30
        $r = $cmd.ExecuteScalar()
        $cmd.Dispose()
        if ($r -is [DBNull] -or $null -eq $r) {
            Write-Log "Lookup failed: rslt_cd for short value '$rsltShortVal' (active)" "ERROR"
            return $false
        }
        $Script:TagRemovalRsltCd = [int]$r

        # ── 4. Resolve usr_id ──
        $cmd = $tempConn.CreateCommand()
        $cmd.CommandText = "SELECT usr_id FROM crs5_oltp.dbo.usr WHERE usr_usrnm = '$($userShortVal.Replace("'", "''"))' AND usr_actv_flg = 'Y'"
        $cmd.CommandTimeout = 30
        $r = $cmd.ExecuteScalar()
        $cmd.Dispose()
        if ($r -is [DBNull] -or $null -eq $r) {
            Write-Log "Lookup failed: usr.usr_id for username '$userShortVal' (active)" "ERROR"
            return $false
        }
        $Script:TagRemovalUserId = [long]$r

        Write-Log "  Startup lookups resolved:" "SUCCESS"
        Write-Log "    TC_ARCH tag_id       : $($Script:TcArchTagId)" "INFO"
        Write-Log "    tag_removal_actn_cd  : '$actnShortVal' -> $($Script:TagRemovalActnCd)" "INFO"
        Write-Log "    tag_removal_rslt_cd  : '$rsltShortVal' -> $($Script:TagRemovalRsltCd)" "INFO"
        Write-Log "    tag_removal_user     : '$userShortVal' -> $($Script:TagRemovalUserId)" "INFO"
        Write-Log "    tag_removal_msg_txt  : '$msgTxt'" "INFO"
        return $true
    }
    catch {
        Write-Log "Lookup resolution failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
    finally {
        if ($tempConn -and $tempConn.State -eq 'Open') {
            $tempConn.Close()
            $tempConn.Dispose()
        }
    }
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

        $result = Get-SqlData -Instance $Script:BidataServer -DatabaseName 'msdb' -Timeout 15 -Query @"
            SELECT
                COUNT(CASE WHEN h.step_id > 0 THEN 1 END) AS step_count,
                COUNT(CASE WHEN h.step_id = 0 THEN 1 END) AS outcome_count,
                MAX(CASE WHEN h.step_id = 0 THEN h.run_status END) AS outcome_status
            FROM msdb.dbo.sysjobhistory h
            INNER JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
            WHERE j.name = '$jobName'
              AND h.run_date = $runDateInt
"@

        if (-not $result) {
            return $false
        }

        $stepCount = [int]$result.step_count
        $outcomeCount = [int]$result.outcome_count

        if ($stepCount -eq 0) {
            return $false
        }

        if ($outcomeCount -gt 0) {
            $outcomeStatus = $result.outcome_status
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

        Write-Log "  BIDATA pre-flight: build is IN PROGRESS ($stepCount steps completed, awaiting outcome)" "WARN"
        return $true
    }
    catch {
        Write-Log "  BIDATA pre-flight: check failed — $($_.Exception.Message). Proceeding cautiously." "WARN"
        return $false
    }
}

# ============================================================================
# SQL PRIMITIVES (persistent connection — used by deletion sequence)
# ============================================================================

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
    <#
    .SYNOPSIS
        Executes a DELETE against the target crs5_oltp with snapshot isolation,
        deadlock retry, and chunked execution for production safety.
    #>
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

function Invoke-TargetUpdate {
    <#
    .SYNOPSIS
        Executes an UPDATE against the target crs5_oltp with snapshot isolation,
        deadlock retry, and chunked execution for production safety.
        Mirrors Invoke-TargetDelete but for UPDATE operations (e.g., NULLing
        FK references before deleting parent records).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$UpdateSQL,
        [int]$Timeout = 600,
        [int]$MaxRetries = 10,
        [int]$RetryDelaySeconds = 5
    )

    $totalRowsUpdated = 0
    $chunkNumber = 0

    $chunkedSQL = $UpdateSQL -replace '(?i)^UPDATE\s+', "UPDATE TOP ($($Script:BatchChunkSize)) "

    while ($true) {
        $chunkNumber++
        $retryCount = 0
        $chunkUpdated = -1

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
                $chunkUpdated = $cmd.ExecuteNonQuery()
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

        if ($chunkUpdated -le 0) { break }

        $totalRowsUpdated += $chunkUpdated

        if ($chunkUpdated -lt $Script:BatchChunkSize) { break }

        Start-Sleep -Milliseconds 100
    }

    return $totalRowsUpdated
}

# ============================================================================
# BIDATA MIGRATION
# ============================================================================

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
    $cmd.CommandTimeout = 900

    try {
        $cmd.CommandText = "SELECT COUNT(*) FROM BIDATA.dbo.$SourceTable WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts)"
        $sourceCount = [long]$cmd.ExecuteScalar()

        if ($sourceCount -eq 0) {
            return @{ Inserted = 0; Deleted = 0 }
        }

        $cmd.CommandText = @"
            BEGIN TRANSACTION;

            INSERT INTO BIDATA.dbo.$DestTable
            SELECT * FROM BIDATA.dbo.$SourceTable
            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts);

            DECLARE @insertCount INT = @@ROWCOUNT;

            DELETE FROM BIDATA.dbo.$SourceTable
            WHERE cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #bidata_batch_accounts);

            DECLARE @deleteCount INT = @@ROWCOUNT;

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

# ============================================================================
# BATCH LOGGING FUNCTIONS
# ============================================================================
# All functions below early-return in preview mode ($script:XFActsExecute eq
# $false) and emit a single console line describing what they would have
# written. No database writes occur in preview mode.
# ============================================================================

function New-BatchLogEntry {
    <#
    .SYNOPSIS
        Creates a new Archive_BatchLog row at the start of a batch with
        accurate exception_count from re-verification. Per design, this is
        called AFTER batch selection and re-verification complete, so all
        counts passed in are final.
    #>
    param(
        [string]$ScheduleMode,
        [int]$BatchSizeUsed,
        [int]$ExceptionCount = 0,
        [long]$RetryOfBatchId = 0
    )

    if (-not $script:XFActsExecute) {
        Write-Log "  [Preview] Would create Archive_BatchLog row (schedule=$ScheduleMode size=$BatchSizeUsed exceptions=$ExceptionCount retry_of=$RetryOfBatchId)" "INFO"
        return
    }

    try {
        $result = Get-SqlData -Query @"
            INSERT INTO DmOps.Archive_BatchLog
                (schedule_mode, batch_size_used, exception_count, status, executed_by)
            OUTPUT INSERTED.batch_id
            VALUES ('$ScheduleMode', $BatchSizeUsed, $ExceptionCount, 'Running', SUSER_SNAME())
"@
        $Script:CurrentBatchId = [long]$result.batch_id

        if ($RetryOfBatchId -gt 0) {
            Invoke-SqlNonQuery -Query @"
                UPDATE DmOps.Archive_BatchLog
                SET batch_retry = 1, retry_batch_id = $($Script:CurrentBatchId)
                WHERE batch_id = $RetryOfBatchId
"@ -Timeout 30 | Out-Null
            Write-Log "  Batch log created: batch_id = $($Script:CurrentBatchId) (retry of batch_id $RetryOfBatchId)" "INFO"
        }
        else {
            Write-Log "  Batch log created: batch_id = $($Script:CurrentBatchId) (exceptions: $ExceptionCount)" "INFO"
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

    if (-not $script:XFActsExecute) {
        Write-Log "  [Preview] Would finalize Archive_BatchLog (status=$Status bidata=$BidataStatus consumer_count=$($Script:BatchConsumerIds.Count) account_count=$($Script:BatchAccountIds.Count) rows=$($Script:TotalDeleted))" "INFO"
        return
    }

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

    if (-not $script:XFActsExecute) { return }
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
    if (-not $script:XFActsExecute) {
        if ($Script:BatchAccountData.Count -gt 0) {
            Write-Log "  [Preview] Would write $($Script:BatchAccountData.Count) Archive_ConsumerLog rows" "INFO"
        }
        return
    }

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

function Write-ExceptionLog {
    <#
    .SYNOPSIS
        Bulk-inserts Archive_ConsumerExceptionLog rows for the current batch's
        re-verification exceptions. Each row carries tag_removed and
        ar_event_written confirmation flags reflecting the best-effort writes
        performed during re-verification. Called after batch log creation.
    #>
    if (-not $script:XFActsExecute) {
        if ($Script:BatchExceptions.Count -gt 0) {
            Write-Log "  [Preview] Would write $($Script:BatchExceptions.Count) Archive_ConsumerExceptionLog rows" "INFO"
        }
        return
    }

    if (-not $Script:CurrentBatchId -or $Script:BatchExceptions.Count -eq 0) { return }

    try {
        for ($i = 0; $i -lt $Script:BatchExceptions.Count; $i += 900) {
            $batch = $Script:BatchExceptions[$i..[Math]::Min($i + 899, $Script:BatchExceptions.Count - 1)]
            $valuesClause = ($batch | ForEach-Object {
                "($($Script:CurrentBatchId), $($_.cnsmr_id), '$($_.cnsmr_idntfr_agncy_id)', $($_.tag_removed), $($_.ar_event_written))"
            }) -join ",`n                "

            Invoke-SqlNonQuery -Query @"
                INSERT INTO DmOps.Archive_ConsumerExceptionLog
                    (batch_id, cnsmr_id, cnsmr_idntfr_agncy_id, tag_removed, ar_event_written)
                VALUES
                    $valuesClause
"@ -Timeout 120 | Out-Null
        }

        Write-Log "  Exception log: $($Script:BatchExceptions.Count) records written" "SUCCESS"
    }
    catch {
        Write-Log "  Failed to write exception log: $($_.Exception.Message)" "WARN"
    }
}

# ============================================================================
# RUNTIME RE-VERIFICATION
# ============================================================================

function Invoke-RuntimeReVerification {
    <#
    .SYNOPSIS
        Runs the inverted apply-job eligibility query scoped to the current
        batch. For each consumer that no longer satisfies "all accounts have
        TA_ARCH": (1) removes the consumer from #archive_batch_consumers and
        from $Script:BatchConsumerIds, (2) loops the exception list and
        performs three best-effort writes per consumer:
            a. UPDATE cnsmr_Tag — soft-delete the TC_ARCH row
            b. INSERT cnsmr_accnt_ar_log — write CC/CC AR event
            c. (deferred) Append to $Script:BatchExceptions for batch INSERT
               into Archive_ConsumerExceptionLog by Write-ExceptionLog

        The unconditional removal happens FIRST, before any of the three
        writes — guarantees that excepted consumers are out of the batch
        even if any subsequent best-effort write fails.

        In PREVIEW mode the function still queries to identify exceptions
        and removes them from the temp table (so subsequent steps see
        accurate row counts), but skips the UPDATE/INSERT writes against
        crs5_oltp. The exception list is still populated so totals and
        logging are accurate.
    .RETURNS
        Hashtable with CandidateCount, ExceptionCount, RemainingCount.
    #>

    Write-Log "--- Runtime Re-Verification ---"

    $candidateCount = $Script:BatchConsumerIds.Count
    $Script:BatchExceptions = New-Object System.Collections.Generic.List[PSObject]

    # ── Run the inverted apply-job query, scoped to this batch ──
    # Eligibility: total accounts on consumer == accounts with active TA_ARCH
    # Inverted: total accounts on consumer != active TA_ARCH count (or no TA_ARCH at all)
    $reVerifyQuery = @"
        SELECT c.cnsmr_id, c.wrkgrp_id, c.cnsmr_idntfr_agncy_id
        FROM crs5_oltp.dbo.cnsmr c
        INNER JOIN #archive_batch_consumers bc ON bc.cnsmr_id = c.cnsmr_id
        INNER JOIN
        (
            SELECT ca.cnsmr_id, COUNT(ca.cnsmr_accnt_id) AS TotalCount
            FROM crs5_oltp.dbo.cnsmr_accnt ca
            GROUP BY ca.cnsmr_id
        ) total ON total.cnsmr_id = c.cnsmr_id
        LEFT JOIN
        (
            SELECT ca.cnsmr_id, COUNT(ca.cnsmr_accnt_id) AS TotalCount
            FROM crs5_oltp.dbo.cnsmr_accnt ca
            INNER JOIN crs5_oltp.dbo.cnsmr_accnt_tag cat
                ON cat.cnsmr_accnt_id = ca.cnsmr_accnt_id
               AND cat.cnsmr_accnt_sft_delete_flg = 'N'
               AND cat.tag_id IN (SELECT tag_id FROM crs5_oltp.dbo.tag WHERE tag_shrt_nm = 'TA_ARCH')
            GROUP BY ca.cnsmr_id
        ) tagged ON tagged.cnsmr_id = c.cnsmr_id
        WHERE total.TotalCount <> ISNULL(tagged.TotalCount, 0)
"@

    try {
        $reVerifyResult = Invoke-TargetQuery -Query $reVerifyQuery -Timeout 600
    }
    catch {
        Write-Log "  Re-verification query failed: $($_.Exception.Message)" "ERROR"
        throw $_
    }

    $exceptionCount = $reVerifyResult.Rows.Count

    if ($exceptionCount -eq 0) {
        Write-Log "  Re-verification: $candidateCount candidates, 0 excepted, $candidateCount proceeding" "SUCCESS"
        return @{ CandidateCount = $candidateCount; ExceptionCount = 0; RemainingCount = $candidateCount }
    }

    Write-Log "  Re-verification: $exceptionCount of $candidateCount candidates failed eligibility" "WARN"

    foreach ($row in $reVerifyResult.Rows) {
        $Script:BatchExceptions.Add([PSCustomObject]@{
            cnsmr_id              = [long]$row.cnsmr_id
            wrkgrp_id             = [long]$row.wrkgrp_id
            cnsmr_idntfr_agncy_id = [string]$row.cnsmr_idntfr_agncy_id
            tag_removed           = 0
            ar_event_written      = 0
        })
    }

    # ── Step 1 (UNCONDITIONAL): Remove excepted consumers from temp table and in-memory list ──
    # Operates on session-private temp table; safe in preview mode (required so
    # subsequent count queries reflect the post-re-verification batch composition).
    try {
        $exceptedIds = @($Script:BatchExceptions | ForEach-Object { $_.cnsmr_id })

        for ($i = 0; $i -lt $exceptedIds.Count; $i += 900) {
            $endIdx = [Math]::Min($i + 899, $exceptedIds.Count - 1)
            $idList = ($exceptedIds[$i..$endIdx] -join ',')
            $delCmd = $Script:TargetConnection.CreateCommand()
            $delCmd.CommandText = "DELETE FROM #archive_batch_consumers WHERE cnsmr_id IN ($idList)"
            $delCmd.CommandTimeout = 60
            $delCmd.ExecuteNonQuery() | Out-Null
            $delCmd.Dispose()
        }

        $exceptedSet = New-Object 'System.Collections.Generic.HashSet[long]'
        foreach ($eid in $exceptedIds) { [void]$exceptedSet.Add($eid) }
        $newList = New-Object System.Collections.Generic.List[long]
        foreach ($cid in $Script:BatchConsumerIds) {
            if (-not $exceptedSet.Contains($cid)) { $newList.Add($cid) }
        }
        $Script:BatchConsumerIds = $newList

        Write-Log "  Removed $exceptionCount excepted consumers from batch" "INFO"
    }
    catch {
        Write-Log "  Failed to remove excepted consumers from temp table: $($_.Exception.Message)" "ERROR"
        throw $_
    }

    # ── Step 2 (BEST-EFFORT, EXECUTE MODE ONLY): UPDATE cnsmr_Tag + INSERT cnsmr_accnt_ar_log ──
    if (-not $script:XFActsExecute) {
        Write-Log "  [Preview] Would soft-delete $exceptionCount TC_ARCH tag rows and write $exceptionCount AR events" "INFO"
    }
    else {
        $msgEscaped = $Script:TagRemovalMsgTxt.Replace("'", "''")
        $writeStart = Get-Date
        $tagsRemoved = 0
        $arEventsWritten = 0

        foreach ($exc in $Script:BatchExceptions) {
            # ── 2a. UPDATE cnsmr_Tag — soft-delete the active TC_ARCH row ──
            try {
                $updCmd = $Script:TargetConnection.CreateCommand()
                $updCmd.CommandTimeout = 30
                $updCmd.CommandText = @"
                    UPDATE crs5_oltp.dbo.cnsmr_Tag
                    SET cnsmr_tag_sft_delete_flg = 'Y',
                        upsrt_dttm = GETDATE(),
                        upsrt_trnsctn_nmbr = upsrt_trnsctn_nmbr + 1,
                        upsrt_soft_comp_id = 113,
                        upsrt_usr_id = $($Script:TagRemovalUserId)
                    WHERE cnsmr_id = $($exc.cnsmr_id)
                      AND tag_id = $($Script:TcArchTagId)
                      AND cnsmr_tag_sft_delete_flg = 'N'
"@
                $rows = $updCmd.ExecuteNonQuery()
                $updCmd.Dispose()
                if ($rows -gt 0) {
                    $exc.tag_removed = 1
                    $tagsRemoved++
                }
            }
            catch {
                Write-Log "    Tag soft-delete failed for cnsmr_id $($exc.cnsmr_id): $($_.Exception.Message)" "WARN"
            }

            # ── 2b. INSERT cnsmr_accnt_ar_log — CC/CC consumer-level event ──
            try {
                $insCmd = $Script:TargetConnection.CreateCommand()
                $insCmd.CommandTimeout = 30
                $insCmd.CommandText = @"
                    INSERT INTO crs5_oltp.dbo.cnsmr_accnt_ar_log
                        (cnsmr_id, wrkgrp_id, actn_cd, rslt_cd,
                         cnsmr_accnt_ar_log_crt_usr_id, cnsmr_accnt_ar_mssg_txt,
                         upsrt_dttm, upsrt_soft_comp_id, upsrt_trnsctn_nmbr, upsrt_usr_id)
                    VALUES
                        ($($exc.cnsmr_id), $($exc.wrkgrp_id), $($Script:TagRemovalActnCd), $($Script:TagRemovalRsltCd),
                         $($Script:TagRemovalUserId), '$msgEscaped',
                         GETDATE(), 113, 0, $($Script:TagRemovalUserId))
"@
                $rows = $insCmd.ExecuteNonQuery()
                $insCmd.Dispose()
                if ($rows -gt 0) {
                    $exc.ar_event_written = 1
                    $arEventsWritten++
                }
            }
            catch {
                Write-Log "    AR event insert failed for cnsmr_id $($exc.cnsmr_id): $($_.Exception.Message)" "WARN"
            }
        }

        $writeMs = [int]((Get-Date) - $writeStart).TotalMilliseconds
        Write-Log "  Exception writes complete: $tagsRemoved tags removed, $arEventsWritten AR events written (${writeMs}ms)" "INFO"
    }

    Write-Log "  Re-verification: $candidateCount candidates, $exceptionCount excepted, $($Script:BatchConsumerIds.Count) proceeding" "SUCCESS"

    return @{
        CandidateCount = $candidateCount
        ExceptionCount = $exceptionCount
        RemainingCount = $Script:BatchConsumerIds.Count
    }
}

# ============================================================================
# OPERATION WRAPPERS (Delete / Update with logging, error handling, preview)
# ============================================================================

function Invoke-TableDelete {
    <#
    .SYNOPSIS
        Executes a single table deletion with logging and error handling.
        In preview mode, counts rows. In execute mode, deletes with chunking.
        Returns $true on success, $false on failure.
    #>
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
    <#
    .SYNOPSIS
        Same as Invoke-TableDelete but for DELETE with JOIN syntax (alias required).
        Returns $true on success, $false on failure.
    #>
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

function Invoke-TableUpdate {
    <#
    .SYNOPSIS
        Executes a single table UPDATE with logging and error handling.
        In preview mode, counts rows. In execute mode, updates with chunking.
        Used for severing FK references before deleting parent records
        (e.g., NULLing resolved suspense references on merged consumers).
        Returns $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory)]
        $Order,
        [Parameter(Mandatory)]
        [string]$TableName,
        [Parameter(Mandatory)]
        [string]$UpdateStatement,
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
                Write-Log "  [$Order] $TableName$passLabel — would update $previewCount rows" "INFO"
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
        $updateStart = Get-Date
        try {
            $rowsUpdated = Invoke-TargetUpdate -UpdateSQL $UpdateStatement
            $durationMs = [int]((Get-Date) - $updateStart).TotalMilliseconds
            if ($rowsUpdated -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel — no rows, skipping" "DEBUG"
                $Script:TablesSkipped++
                Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs $durationMs -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel — updated $rowsUpdated rows (${durationMs}ms)" "SUCCESS"
                $Script:TablesProcessed++
                Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $rowsUpdated -DurationMs $durationMs -Status 'Success'
            }
            return $true
        }
        catch {
            $durationMs = [int]((Get-Date) - $updateStart).TotalMilliseconds
            Write-Log "  [$Order] $TableName$passLabel — FAILED (${durationMs}ms): $($_.Exception.Message)" "ERROR"
            $Script:TablesFailed++
            Write-BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs $durationMs -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
}

# ============================================================================
# STEP WRAPPERS (set $Script:StopProcessing on failure)
# ============================================================================

function Step-Delete {
    param([hashtable]$Params)
    if ($Script:StopProcessing) { return }
    $ok = Invoke-TableDelete @Params -PreviewOnly (-not $script:XFActsExecute)
    if (-not $ok) {
        Write-Log "  STOPPING — cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $Script:StopProcessing = $true
    }
}

function Step-JoinDelete {
    param([hashtable]$Params)
    if ($Script:StopProcessing) { return }
    $ok = Invoke-JoinTableDelete @Params -PreviewOnly (-not $script:XFActsExecute)
    if (-not $ok) {
        Write-Log "  STOPPING — cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $Script:StopProcessing = $true
    }
}

function Step-Update {
    param([hashtable]$Params)
    if ($Script:StopProcessing) { return }
    $ok = Invoke-TableUpdate @Params -PreviewOnly (-not $script:XFActsExecute)
    if (-not $ok) {
        Write-Log "  STOPPING — cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $Script:StopProcessing = $true
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$scriptStart = Get-Date

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  xFACts DM Consumer Archive (Unified)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# STEP 1: Load Configuration & Pre-Flight Checks
# ============================================================================

Write-Log "--- Step 1: Configuration ---"

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

if ($configMap.ContainsKey('batch_size'))            { $Script:BatchSizeFull       = [int]$configMap['batch_size'] }
if ($configMap.ContainsKey('batch_size_reduced'))    { $Script:BatchSizeReduced    = [int]$configMap['batch_size_reduced'] }
if ($configMap.ContainsKey('chunk_size'))            { $Script:BatchChunkSize      = [int]$configMap['chunk_size'] }
if ($configMap.ContainsKey('bidata_instance'))       { $Script:BidataServer        = $configMap['bidata_instance'] }
if ($configMap.ContainsKey('alerting_enabled'))      { $Script:AlertingEnabled     = $configMap['alerting_enabled'] -eq '1' }
if ($configMap.ContainsKey('bidata_build_job_name')) { $Script:BidataBuildJobName  = $configMap['bidata_build_job_name'] }

if ($ChunkSize -gt 0) { $Script:BatchChunkSize = $ChunkSize }

if ($BatchSize -gt 0) {
    $Script:ManualBatchSize = $true
    $Script:ScheduleMode = 'Manual'
    $activeBatchSize = $BatchSize
    Write-Log "  Manual batch size override: $BatchSize" "INFO"
} else {
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

if (Test-BidataBuildInProgress) {
    Write-Log "BIDATA Daily Build is in progress on $($Script:BidataServer) — exiting to avoid contention" "WARN"
    exit 0
}

if (-not (Resolve-StartupLookups -ConfigMap $configMap)) {
    Write-Log "Startup lookup resolution failed — exiting" "ERROR"
    exit 1
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
# STEP 2: Open Persistent Connections (target + BIDATA)
# ============================================================================

Write-Log "--- Step 2: Open Connections ---"

if (-not (Open-TargetConnection)) {
    if ($TaskId -gt 0) {
        $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs $totalMs `
            -ErrorMessage "Failed to open connection to target instance"
    }
    exit 1
}

# BIDATA connection opened up-front when in execute mode — required mid-batch.
# In preview mode no BIDATA writes occur so we skip this entirely.
if ($Script:BidataServer -and $script:XFActsExecute) {
    if (-not (Open-BidataConnection)) {
        Close-TargetConnection
        if ($TaskId -gt 0) {
            $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
            Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
                -Status "FAILED" -DurationMs $totalMs `
                -ErrorMessage "Failed to open connection to BIDATA instance"
        }
        exit 1
    }
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
$Script:BatchExceptions = @()
$Script:StopProcessing = $false
$Script:BatchStartTime = Get-Date
$Script:BidataStatus = $null
$Script:RetryOfBatchId = 0

$Script:TotalBatchesRun++

# ============================================================================
# STEP 3: Select Batch (Retry or New TC_ARCH Selection)
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
    # Retry skips re-verification — past the point of no return.
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
        Close-BidataConnection
        Close-TargetConnection
        exit 1
    }

    $retryRows = if ($retryData -is [System.Data.DataTable]) { @($retryData.Rows) } else { @($retryData) }

    if ($retryRows.Count -eq 0) {
        Write-Log "  No ConsumerLog records found for batch $failedBatchId — cannot retry" "ERROR"
        Close-BidataConnection
        Close-TargetConnection
        exit 1
    }

    $Script:BatchConsumerIds = New-Object System.Collections.Generic.List[long]
    $Script:BatchAccountIds = New-Object System.Collections.Generic.List[long]
    $Script:BatchAccountData = New-Object System.Collections.Generic.List[PSObject]

    foreach ($row in $retryRows) {
        $cid = [long]$row.cnsmr_id
        if (-not $Script:BatchConsumerIds.Contains($cid)) {
            $Script:BatchConsumerIds.Add($cid)
        }
        $Script:BatchAccountIds.Add([long]$row.cnsmr_accnt_id)
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
    # NORMAL PATH: Select TC_ARCH-tagged candidates (TOP-N)
    # ══════════════════════════════════════════════════════════════════

    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  Batch #$($Script:TotalBatchesRun) — $($Script:ScheduleMode) mode ($activeBatchSize consumers)" -ForegroundColor DarkCyan
    Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    Write-Log "--- Step 3: Select Batch ---"

    # Trust the TC_ARCH tag at selection time. Step 5 does the rigorous
    # eligibility re-verification against the apply-job logic.
    $batchQuery = @"
        SELECT TOP ($activeBatchSize) ct.cnsmr_id
        FROM crs5_oltp.dbo.cnsmr_Tag ct
        WHERE ct.tag_id = $($Script:TcArchTagId)
          AND ct.cnsmr_tag_sft_delete_flg = 'N'
        ORDER BY ct.cnsmr_id
"@

    try {
        $batchResult = Invoke-TargetQuery -Query $batchQuery
    }
    catch {
        Write-Log "Failed to select batch: $($_.Exception.Message)" "ERROR"
        Close-BidataConnection
        Close-TargetConnection
        exit 1
    }

    if ($batchResult.Rows.Count -eq 0) {
        Write-Log "No TC_ARCH-tagged consumers found — work complete" "INFO"
        $continueProcessing = $false
        break
    }

    $Script:BatchConsumerIds = New-Object System.Collections.Generic.List[long]
    foreach ($row in $batchResult.Rows) {
        $Script:BatchConsumerIds.Add([long]$row.cnsmr_id)
    }

    Write-Log "  Selected $($Script:BatchConsumerIds.Count) TC_ARCH candidates" "INFO"
}

# ============================================================================
# STEP 4: Create Core Temp Tables and Populate Consumer IDs
# ============================================================================
# Both paths (retry and normal) need #archive_batch_consumers populated
# before re-verification can run. Account temp table is empty for now —
# populated in Step 6 after re-verification trims the consumer set.

Write-Log "--- Step 4: Create Core Temp Tables ---"

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

    Write-Log "  Core temp tables created; $($Script:BatchConsumerIds.Count) consumers loaded" "SUCCESS"
}
catch {
    Write-Log "Failed to create core temp tables: $($_.Exception.Message)" "ERROR"
    Close-BidataConnection
    Close-TargetConnection
    exit 1
}

Write-Log ""

# ============================================================================
# STEP 5: Runtime Re-Verification (skipped on retry)
# ============================================================================

if ($Script:RetryOfBatchId -eq 0) {
    try {
        $reVerifyResult = Invoke-RuntimeReVerification
    }
    catch {
        Write-Log "Re-verification failed catastrophically: $($_.Exception.Message)" "ERROR"
        Close-BidataConnection
        Close-TargetConnection
        exit 1
    }

    # Handle all-excepted batch — no consumers remaining to process
    if ($Script:BatchConsumerIds.Count -eq 0) {
        Write-Log "  All $($reVerifyResult.CandidateCount) candidates were excepted — finalizing batch as Success with consumer_count=0" "WARN"

        # Create BatchLog row to record the all-excepted batch for audit (execute mode only)
        $batchSizeUsed = $reVerifyResult.CandidateCount
        New-BatchLogEntry -ScheduleMode $Script:ScheduleMode -BatchSizeUsed $batchSizeUsed `
            -ExceptionCount $reVerifyResult.ExceptionCount -RetryOfBatchId 0
        Write-ExceptionLog
        Update-BatchLogEntry -Status 'Success' -BidataStatus 'Skipped'

        $Script:SessionTotalExceptions += $reVerifyResult.ExceptionCount

        # Continue to next batch (still bound by SingleBatch / abort / schedule)
        if ($SingleBatch) {
            Write-Log "  Single batch mode — exiting loop" "INFO"
            $continueProcessing = $false
        }
        elseif (Test-ArchiveAbort) {
            Write-Log "  Archive abort flag detected — stopping after batch completion" "WARN"
            $continueProcessing = $false
        }
        else {
            $nextScheduleValue = Get-ArchiveScheduleMode
            if ($nextScheduleValue -eq 0) {
                Write-Log "  Schedule: now in BLOCKED window — stopping" "INFO"
                $continueProcessing = $false
            }
            else {
                Start-Sleep -Seconds 2
            }
        }
        continue
    }
}
else {
    Write-Log "--- Step 5: Skipped (retry path — consumers already cleared by prior batch) ---"
}

Write-Log ""

# ============================================================================
# STEP 6: Expand Accounts, Materialize Account-Level Temp Tables, Create BatchLog
# ============================================================================

Write-Log "--- Step 6: Load Account-Level Temp Tables ---"

# ── Expand consumers to account IDs ──
if ($Script:RetryOfBatchId -gt 0) {
    # Retry path: load accounts from ConsumerLog data (already in $Script:BatchAccountIds)
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
        Write-Log "  Account temp table loaded (retry): $($Script:BatchConsumerIds.Count) consumers, $($Script:BatchAccountIds.Count) accounts" "SUCCESS"
    }
    catch {
        Write-Log "Failed to load account temp table: $($_.Exception.Message)" "ERROR"
        Close-BidataConnection
        Close-TargetConnection
        exit 1
    }
}
else {
    # Normal path: re-expand against the post-re-verification trimmed consumer set.
    # No tag filter on cnsmr_accnt — at consumer level we archive everything
    # the consumer owns, regardless of TA_ARCH tag state.
    $accountQuery = @"
        SELECT DISTINCT
            ca.cnsmr_id,
            c.cnsmr_idntfr_agncy_id,
            ca.cnsmr_accnt_id,
            ca.cnsmr_accnt_idntfr_agncy_id,
            ca.crdtr_id
        FROM crs5_oltp.dbo.cnsmr_accnt ca
        INNER JOIN crs5_oltp.dbo.cnsmr c ON ca.cnsmr_id = c.cnsmr_id
        INNER JOIN #archive_batch_consumers bc ON ca.cnsmr_id = bc.cnsmr_id
"@

    try {
        $accountResult = Invoke-TargetQuery -Query $accountQuery
    }
    catch {
        Write-Log "Failed to expand accounts: $($_.Exception.Message)" "ERROR"
        Close-BidataConnection
        Close-TargetConnection
        exit 1
    }

    $Script:BatchAccountIds = New-Object System.Collections.Generic.List[long]
    $Script:BatchAccountData = New-Object System.Collections.Generic.List[PSObject]

    foreach ($row in $accountResult.Rows) {
        $Script:BatchAccountIds.Add([long]$row.cnsmr_accnt_id)
        $Script:BatchAccountData.Add([PSCustomObject]@{
            cnsmr_id                    = [long]$row.cnsmr_id
            cnsmr_idntfr_agncy_id       = [string]$row.cnsmr_idntfr_agncy_id
            cnsmr_accnt_id              = [long]$row.cnsmr_accnt_id
            cnsmr_accnt_idntfr_agncy_id = [string]$row.cnsmr_accnt_idntfr_agncy_id
            crdtr_id                    = [long]$row.crdtr_id
        })
    }

    Write-Log "  Expanded to $($Script:BatchAccountIds.Count) accounts" "INFO"

    # Load account IDs into #archive_batch_accounts
    if ($Script:BatchAccountIds.Count -gt 0) {
        try {
            $acctCmd = $Script:TargetConnection.CreateCommand()
            $acctCmd.CommandText = @"
                INSERT INTO #archive_batch_accounts (cnsmr_accnt_id)
                SELECT DISTINCT ca.cnsmr_accnt_id
                FROM crs5_oltp.dbo.cnsmr_accnt ca
                INNER JOIN #archive_batch_consumers bc ON ca.cnsmr_id = bc.cnsmr_id
"@
            $acctCmd.CommandTimeout = 60
            $acctInserted = $acctCmd.ExecuteNonQuery()
            $acctCmd.Dispose()

            Write-Log "  Account temp table loaded: $($Script:BatchConsumerIds.Count) consumers, $acctInserted accounts" "SUCCESS"
        }
        catch {
            Write-Log "Failed to load account temp table: $($_.Exception.Message)" "ERROR"
            Close-BidataConnection
            Close-TargetConnection
            exit 1
        }
    }
    else {
        Write-Log "  Consumers have zero accounts (degenerate shell case) — proceeding to consumer-level deletes only" "WARN"
    }
}

# ── Create batch log entry (now that all counts are final) ──
$useScheduleMode = if ($Script:RetryOfBatchId -gt 0) { 'Retry' } else { $Script:ScheduleMode }
$useBatchSize = if ($Script:RetryOfBatchId -gt 0) {
    $Script:BatchConsumerIds.Count
} else {
    # batch_size_used = consumer_count + exception_count (post-re-verification invariant)
    $Script:BatchConsumerIds.Count + $Script:BatchExceptions.Count
}
$useExceptionCount = $Script:BatchExceptions.Count
New-BatchLogEntry -ScheduleMode $useScheduleMode -BatchSizeUsed $useBatchSize `
    -ExceptionCount $useExceptionCount -RetryOfBatchId $Script:RetryOfBatchId

# ── Write consumer log and exception log (execute mode only — both functions guard internally) ──
Write-ConsumerLog
Write-ExceptionLog

# ── Pre-materialize account-level intermediate ID tables ──
if ($Script:BatchAccountIds.Count -gt 0) {
    $materializeAcctSQL = @"

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
        $cmd.CommandText = $materializeAcctSQL
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

        Write-Log "  Account-level intermediate ID tables materialized:" "SUCCESS"
        Write-Log "    AR Log entries:         $arLogCount" "INFO"
        Write-Log "    Transactions (direct):  $trnsctnCount" "INFO"
        Write-Log "    Payment journals:       $pmtjrnlCount" "INFO"
        Write-Log "    Transactions (pymnt):   $pmtjrnlTrnsctnCount" "INFO"
        Write-Log "    Encounters:             $encntrCount" "INFO"
    }
    catch {
        Write-Log "Failed to create account-level temp tables: $($_.Exception.Message)" "ERROR"
        Update-BatchLogEntry -Status 'Failed' -ErrorMessage "Account-level temp table creation failed: $($_.Exception.Message)"
        Close-BidataConnection
        Close-TargetConnection
        exit 1
    }
}
else {
    # Degenerate case: zero accounts — skip materialization, set counts to 0
    $arLogCount = 0
    $trnsctnCount = 0
    $pmtjrnlCount = 0
    $pmtjrnlTrnsctnCount = 0
    $encntrCount = 0
    Write-Log "  Skipping account-level materialization — no accounts to process" "INFO"
}

Write-Log ""
# ============================================================================
# STEP 7: Execute Account-Level Deletions (Phase 1 UDEFs AU* + Phase 2 A1-A117)
# ============================================================================

if ($Script:BatchAccountIds.Count -eq 0) {
    Write-Log "--- Step 7: Skipped (no accounts to delete) ---"
    Write-Log ""
}
else {
    Write-Log "--- Step 7: Execute Account-Level Deletions ---"
    Write-Log ""

    $Script:StopProcessing = $false

    # Account-level where-clause variables
    $wAcct       = "cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #archive_batch_accounts)"
    $wArLog      = "cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
    $wTrnsctn    = "cnsmr_accnt_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_trnsctn_ids)"
    $wPmtJrnl    = "cnsmr_accnt_pymnt_jrnl_id IN (SELECT cnsmr_accnt_pymnt_jrnl_id FROM #batch_pmtjrnl_ids)"
    $wPmtTrnsctn = "cnsmr_accnt_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_pmtjrnl_trnsctn_ids)"
    $wEncntr     = "hc_encntr_id IN (SELECT hc_encntr_id FROM #batch_encntr_ids)"
    $wPrgrmPlan  = "hc_prgrm_plan_id IN (SELECT hc_prgrm_plan_id FROM crs5_oltp.dbo.hc_prgrm_plan WHERE $wEncntr)"

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
            Step-Delete @{Order="AU$udefOrder"; TableName=$udefTable; WhereClause=$wAcct}
        }
    }

    Write-Log ""

    # ── Phase 2: Account-Level Tables (orders A1-A117) ──
    Write-Log "  Phase 2: Account-Level Tables" "INFO"

    Step-Delete @{Order='A1'; TableName='rcvr_autoassign_grp_log'; WhereClause=$wAcct}
    Step-Delete @{Order='A2'; TableName='dfrrd_cnsmr_accnt'; WhereClause=$wAcct}
    Step-Delete @{Order='A3'; TableName='hc_dfrrd_prgrm_plan'; WhereClause="hc_prgrm_plan_id IN (SELECT hc_prgrm_plan_id FROM crs5_oltp.dbo.hc_prgrm_plan WHERE $wEncntr)"}
    Step-Delete @{Order='A4'; TableName='invc_crrctn_dtl_stgng'; WhereClause="invc_crrctn_trnsctn_stgng_id IN (SELECT invc_crrctn_trnsctn_stgng_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn_stgng WHERE $wTrnsctn)"}
    Step-Delete @{Order='A5'; TableName='invc_crrctn_trnsctn_stgng'; WhereClause=$wTrnsctn}
    Step-Delete @{Order='A6'; TableName='hc_prgrm_plan_trnsctn_log'; WhereClause="hc_prgrm_plan_id IN (SELECT hc_prgrm_plan_id FROM crs5_oltp.dbo.hc_prgrm_plan WHERE $wEncntr)"}
    Step-Delete @{Order='A7'; TableName='cnsmr_accnt_rndm_nmbr'; WhereClause=$wAcct}
    Step-Delete @{Order='A8'; TableName='cnsmr_accnt_strtgy_log'; WhereClause=$wAcct}
    Step-Delete @{Order='A9'; TableName='cnsmr_accnt_strtgy_wrk_actn'; WhereClause=$wAcct}
    Step-Delete @{Order='A10'; TableName='cnsmr_accnt_wrkgrp_assctn'; WhereClause=$wAcct}
    Step-Delete @{Order='A11'; TableName='cnsmr_accnt_srvc_rqst'; WhereClause=$wAcct}
    Step-Delete @{Order='A12'; TableName='cnsmr_accnt_rehab_pymnt_optn'; WhereClause="cnsmr_accnt_rehab_dtl_id IN (SELECT cnsmr_accnt_rehab_dtl_id FROM crs5_oltp.dbo.cnsmr_accnt_rehab_dtl WHERE $wAcct)"}
    Step-Delete @{Order='A13'; TableName='cnsmr_accnt_rehab_pymnt_tier'; WhereClause=$wAcct}
    Step-Delete @{Order='A14'; TableName='cnsmr_accnt_rehab_dtl'; WhereClause=$wAcct}
    Step-Delete @{Order='A15'; TableName='rcvr_sttmnt_pndng_trnsctn_dtl'; WhereClause=$wTrnsctn}
    Step-Delete @{Order='A16'; TableName='cnsmr_accnt_wrk_actn'; WhereClause=$wAcct}
    Step-Delete @{Order='A17'; TableName='cnsmr_accnt_frwrd_rcll_dtl'; WhereClause=$wAcct}
    Step-Delete @{Order='A18'; TableName='cnsmr_accnt_bckt_sttlmnt'; WhereClause="cnsmr_accnt_sttlmnt_id IN (SELECT cnsmr_accnt_sttlmnt_id FROM crs5_oltp.dbo.cnsmr_accnt_Sttlmnt WHERE $wAcct)"; PassDescription='Pass 1: via direct sttlmnt'}
    Step-Delete @{Order='A19'; TableName='cnsmr_accnt_Sttlmnt'; WhereClause=$wAcct; PassDescription='Pass 1: direct'}
    Step-Delete @{Order='A20'; TableName='cnsmr_accnt_loan_dtl_wrk_actn'; WhereClause="cnsmr_accnt_loan_dtl_id IN (SELECT cnsmr_accnt_loan_dtl_id FROM crs5_oltp.dbo.cnsmr_accnt_loan_dtl WHERE $wAcct)"}
    Step-Delete @{Order='A21'; TableName='cnsmr_accnt_loan_dtl'; WhereClause=$wAcct}
    Step-Delete @{Order='A22'; TableName='cnsmr_Accnt_Tag'; WhereClause=$wAcct}
    Step-Delete @{Order='A23'; TableName='rcvr_fnncl_trnsctn_exprt_dtl'; WhereClause=$wTrnsctn; PassDescription='Pass 1: via direct trnsctn'}
    Step-Delete @{Order='A24'; TableName='rcvr_sttmnt_of_accnt_dtl'; WhereClause=$wTrnsctn; PassDescription='Pass 1: via direct trnsctn'}
    Step-Delete @{Order='A25'; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause="crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct)"; PassDescription='Pass 1: via crdtr_trnsctn'}
    Step-Delete @{Order='A26'; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause=$wTrnsctn; PassDescription='Pass 2: via cnsmr_accnt_trnsctn'}
    Step-Delete @{Order='A27'; TableName='invc_crrctn_dtl'; WhereClause="invc_crrctn_trnsctn_id IN (SELECT invc_crrctn_trnsctn_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn WHERE $wTrnsctn)"}
    Step-Delete @{Order='A28'; TableName='invc_crrctn_trnsctn'; WhereClause=$wTrnsctn}
    Step-Delete @{Order='A29'; TableName='wash_assctn'; WhereClause="wash_assctn_pymnt_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_trnsctn_ids)"; PassDescription='Pass 1: payment side'}
    Step-Delete @{Order='A30'; TableName='wash_assctn'; WhereClause="wash_assctn_nsf_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_trnsctn_ids)"; PassDescription='Pass 2: NSF side'}
    Step-Delete @{Order='A31'; TableName='cnsmr_accnt_crdt_bru_cnfg'; WhereClause=$wAcct}
    Step-Delete @{Order='A32'; TableName='cnsmr_accnt_trnsctn'; WhereClause=$wAcct; PassDescription='Pass 1: direct'}
    Step-Delete @{Order='A33'; TableName='cb_rpt_assctd_cnsmr_data'; WhereClause=$wAcct}
    Step-Delete @{Order='A34'; TableName='cb_rpt_base_data'; WhereClause=$wAcct}
    Step-Delete @{Order='A35'; TableName='cb_rpt_emplyr_data'; WhereClause=$wAcct}
    Step-Delete @{Order='A36'; TableName='cnsmr_accnt_cnfg'; WhereClause=$wAcct}
    Step-Delete @{Order='A37'; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause="tax_jrsdctn_trnsctn_id IN (SELECT tax_jrsdctn_trnsctn_id FROM crs5_oltp.dbo.tax_jrsdctn_trnsctn WHERE $wTrnsctn)"; PassDescription='Pass 3: via tax_jrsdctn_trnsctn (cnsmr_accnt_trnsctn path)'}
    Step-Delete @{Order='A38'; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause="tax_jrsdctn_trnsctn_id IN (SELECT tax_jrsdctn_trnsctn_id FROM crs5_oltp.dbo.tax_jrsdctn_trnsctn WHERE crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct))"; PassDescription='Pass 4: via tax_jrsdctn_trnsctn (crdtr_trnsctn path)'}
    Step-Delete @{Order='A39'; TableName='tax_jrsdctn_trnsctn'; WhereClause=$wTrnsctn; PassDescription='Pass 1: via cnsmr_accnt_trnsctn'}
    Step-Delete @{Order='A40'; TableName='tax_jrsdctn_trnsctn'; WhereClause="crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct)"; PassDescription='Pass 2: via crdtr_trnsctn'}
    Step-Delete @{Order='A41'; TableName='tax_jrsdctn_accnt_assctn'; WhereClause="tax_jrsdctn_accnt_id IN (SELECT cnsmr_accnt_id FROM crs5_oltp.dbo.cnsmr_accnt WHERE $wAcct)"}
    Step-Delete @{Order='A42'; TableName='cb_rpt_rqst_btch_log'; WhereClause=$wAcct}
    Step-Delete @{Order='A43'; TableName='notice_rqst_cnsmr_accnt'; WhereClause=$wAcct}
    Step-Delete @{Order='A44'; TableName='crdtr_srvc_evnt'; WhereClause=$wAcct; PassDescription='Pass 1: direct cnsmr_accnt_id'}
    Step-Delete @{Order='A45'; TableName='crdtr_srvc_evnt'; WhereClause="crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct)"; PassDescription='Pass 2: via crdtr_trnsctn'}
    Step-Delete @{Order='A46'; TableName='crdtr_trnsctn'; WhereClause=$wAcct}
    Step-Delete @{Order='A47'; TableName='loan_rehab_cntr'; WhereClause="loan_rehab_dtl_id IN (SELECT loan_rehab_dtl_id FROM crs5_oltp.dbo.loan_rehab_dtl WHERE $wAcct)"}
    Step-Delete @{Order='A48'; TableName='loan_rehab_dtl'; WhereClause=$wAcct}
    Step-Delete @{Order='A49'; TableName='bal_rdctn_plan_stpdwn'; WhereClause="bal_rdctn_plan_id IN (SELECT bal_rdctn_plan_id FROM crs5_oltp.dbo.bal_rdctn_plan WHERE $wAcct)"}
    Step-Delete @{Order='A50'; TableName='bal_rdctn_plan'; WhereClause=$wAcct}
    Step-Delete @{Order='A51'; TableName='schdld_pymnt_accnt_dstrbtn'; WhereClause=$wAcct}
    Step-Delete @{Order='A52'; TableName='cnsmr_accnt_spplmntl_info'; WhereClause=$wAcct}
    Step-Delete @{Order='A53'; TableName='rcvr_ar_evnt'; WhereClause=$wArLog}
    Step-Delete @{Order='A54'; TableName='crdtr_srvc_evnt'; WhereClause=$wArLog; PassDescription='Pass 3: via ar_log'}
    Step-Delete @{Order='A55'; TableName='cnsmr_cntct_addrs_log'; WhereClause="cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log WHERE cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids))"}
    Step-Delete @{Order='A56'; TableName='cnsmr_cntct_phn_log'; WhereClause="cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log WHERE cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids))"}
    Step-Delete @{Order='A57'; TableName='cnsmr_cntct_email_log'; WhereClause="cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log WHERE cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids))"}
    Step-Delete @{Order='A58'; TableName='cnsmr_cntct_trnsctn_log'; WhereClause="cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"}
    Step-Delete @{Order='A59'; TableName='agncy_accnt_trnsctn_stgng'; WhereClause="agncy_accnt_trnsctn_id IN (SELECT agncy_accnt_trnsctn_id FROM crs5_oltp.dbo.agncy_accnt_trnsctn WHERE $wArLog)"}
    Step-Delete @{Order='A60'; TableName='agncy_accnt_trnsctn'; WhereClause=$wArLog}
    Step-Delete @{Order='A61'; TableName='img_info_cnsmr_accnt_ar_log_assctn'; WhereClause=$wArLog}

    Step-JoinDelete @{
        Order = 'A62'; TableName = 'agnt_crdtbl_actvty_spprssn'
        DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
    }

    Step-JoinDelete @{
        Order = 'A63'; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
        DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
        PassDescription = 'Pass 1: via ar_log'
    }

    Step-JoinDelete @{
        Order = 'A64'; TableName = 'agnt_crdtbl_actvty'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
    }

    Step-Delete @{Order='A65'; TableName='cnsmr_task_itm_cnsmr_accnt_ar_log_assctn'; WhereClause=$wArLog}
    Step-Delete @{Order='A66'; TableName='cnsmr_accnt_ar_log'; WhereClause=$wAcct}
    Step-Delete @{Order='A67'; TableName='cnsmr_accnt_bal'; WhereClause=$wAcct}
    Step-Delete @{Order='A68'; TableName='cnsmr_accnt_bckt_bal_rprtng'; WhereClause=$wAcct}
    Step-Delete @{Order='A69'; TableName='schdld_pymnt_cnsmr_accnt_assctn'; WhereClause=$wAcct}
    Step-Delete @{Order='A70'; TableName='cnsmr_accnt_Cmmnt'; WhereClause=$wAcct}
    Step-Delete @{Order='A71'; TableName='cnsmr_accnt_frwrd_rcll'; WhereClause=$wAcct}
    Step-Delete @{Order='A72'; TableName='pymnt_arrngmnt_accnt_dstrbtn'; WhereClause=$wAcct}

    if ($pmtjrnlCount -gt 0 -and -not $Script:StopProcessing) {
        Write-Log "    Payment journal chain: $pmtjrnlCount rows — processing Pass 2 tables" "INFO"

        Step-Delete @{Order='A73'; TableName='cnsmr_accnt_Sttlmnt'; WhereClause="cnsmr_accnt_sttlmnt_pymnt_jrnl_id IN (SELECT cnsmr_accnt_pymnt_jrnl_id FROM #batch_pmtjrnl_ids)"; PassDescription='Pass 2: via pymnt_jrnl'}
        Step-Delete @{Order='A74'; TableName='cnsmr_accnt_trnsctn'; WhereClause=$wPmtJrnl; PassDescription='Pass 2: via pymnt_jrnl'}
        Step-Delete @{Order='A75'; TableName='cnsmr_accnt_trnsctn_stgng'; WhereClause=$wPmtJrnl}
        Step-Delete @{Order='A76'; TableName='pymnt_arrngmnt_accnt_dstrbtn_loan_rehab_cntrbtn'; WhereClause=$wPmtJrnl; PassDescription='Pass 2: via pymnt_jrnl'}
        Step-Delete @{Order='A77'; TableName='pymnt_arrngmnt_accnt_bckt_dstrbtn'; WhereClause="pymnt_arrngmnt_accnt_dstrbtn_id IN (SELECT pymnt_arrngmnt_accnt_dstrbtn_id FROM crs5_oltp.dbo.pymnt_arrngmnt_accnt_dstrbtn WHERE $wAcct)"}
        Step-Delete @{Order='A78'; TableName='cnsmr_accnt_bckt_sttlmnt'; WhereClause="cnsmr_accnt_sttlmnt_id IN (SELECT cnsmr_accnt_sttlmnt_id FROM crs5_oltp.dbo.cnsmr_accnt_Sttlmnt WHERE cnsmr_accnt_sttlmnt_pymnt_jrnl_id IN (SELECT cnsmr_accnt_pymnt_jrnl_id FROM #batch_pmtjrnl_ids))"; PassDescription='Pass 2: via pymnt_jrnl chain'}
        Step-Delete @{Order='A79'; TableName='rcvr_fnncl_trnsctn_exprt_dtl'; WhereClause=$wPmtTrnsctn; PassDescription='Pass 2: via pymnt_jrnl chain'}
        Step-Delete @{Order='A80'; TableName='rcvr_sttmnt_of_accnt_dtl'; WhereClause=$wPmtTrnsctn; PassDescription='Pass 2: via pymnt_jrnl chain'}
        Step-Delete @{Order='A81'; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause=$wPmtTrnsctn; PassDescription='Pass 5: via pymnt_jrnl chain'}
    } elseif (-not $Script:StopProcessing) {
        Write-Log "    Payment journal chain: no rows — skipping Pass 2 tables (orders A73-A81)" "DEBUG"
        $Script:TablesSkipped += 9
    }

    Step-Delete @{Order='A82'; TableName='cnsmr_accnt_ownrs'; WhereClause="$wAcct AND cnsmr_accnt_ownrshp_sft_dlt_flg = 'Y'"; PassDescription='soft-deleted only'}
    Step-Delete @{Order='A83'; TableName='crdt_Bureau_Trnsmssn'; WhereClause=$wAcct}
    Step-Delete @{Order='A84'; TableName='cb_rpt_rqst_dtl'; WhereClause="cnsmr_accnt_idntfr_agncy_id IN (SELECT cnsmr_accnt_idntfr_agncy_id FROM crs5_oltp.dbo.cnsmr_accnt WHERE $wAcct)"}
    Step-Delete @{Order='A85'; TableName='cnsmr_accnt_effctv_fee_schdl'; WhereClause=$wAcct}
    Step-Delete @{Order='A86'; TableName='cnsmr_accnt_effctv_intrst_rt'; WhereClause=$wAcct}
    Step-Delete @{Order='A87'; TableName='sspns_cnsmr_accnt_bckt_imprt_trnsctn'; WhereClause="sspns_cnsmr_accnt_imprt_trnsctn_id IN (SELECT sspns_cnsmr_accnt_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_accnt_imprt_trnsctn WHERE sspns_trnsctn_cnsmr_accnt_idntfr_id IN (SELECT sspns_trnsctn_cnsmr_accnt_idntfr_id FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_accnt_idntfr WHERE $wAcct))"}
    Step-Delete @{Order='A88'; TableName='sspns_cnsmr_accnt_imprt_trnsctn'; WhereClause="sspns_trnsctn_cnsmr_accnt_idntfr_id IN (SELECT sspns_trnsctn_cnsmr_accnt_idntfr_id FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_accnt_idntfr WHERE $wAcct)"}
    Step-Delete @{Order='A89'; TableName='sspns_trnsctn_cnsmr_accnt_idntfr'; WhereClause=$wAcct}
    Step-Delete @{Order='A90'; TableName='cnsmr_accnt_effctv_mk_whl_cnfg'; WhereClause=$wAcct}
    Step-Delete @{Order='A91'; TableName='ca_case_accnt_assctn'; WhereClause=$wAcct}

    Step-Delete @{Order='A92'; TableName='hc_encntr_code_value_assctn'; WhereClause=$wEncntr}
    Step-Delete @{Order='A93'; TableName='hc_encntr_srvc_claim'; WhereClause=$wEncntr; PassDescription='Pass 1: via encntr'}
    Step-Delete @{Order='A94'; TableName='hc_encntr_srvc_dtl'; WhereClause=$wEncntr}
    Step-Delete @{Order='A95'; TableName='hc_encntr_srvc_prvdr'; WhereClause=$wEncntr}
    Step-Delete @{Order='A96'; TableName='hc_payer_plan'; WhereClause=$wEncntr}
    Step-Delete @{Order='A97'; TableName='hc_ptnt'; WhereClause=$wEncntr}
    Step-Delete @{Order='A98'; TableName='hc_encntr_srvc_code_value_assctn'; WhereClause="hc_encntr_srvc_dtl_id IN (SELECT hc_encntr_srvc_dtl_id FROM crs5_oltp.dbo.hc_encntr_srvc_dtl WHERE $wEncntr)"}
    Step-Delete @{Order='A99'; TableName='hc_encntr_srvc_pymnt_history'; WhereClause="hc_encntr_srvc_dtl_id IN (SELECT hc_encntr_srvc_dtl_id FROM crs5_oltp.dbo.hc_encntr_srvc_dtl WHERE $wEncntr)"}
    Step-Delete @{Order='A100'; TableName='hc_physcn'; WhereClause="hc_encntr_srvc_dtl_id IN (SELECT hc_encntr_srvc_dtl_id FROM crs5_oltp.dbo.hc_encntr_srvc_dtl WHERE $wEncntr)"}
    Step-Delete @{Order='A101'; TableName='hc_encntr_srvc_claim'; WhereClause="hc_payer_plan_id IN (SELECT hc_payer_plan_id FROM crs5_oltp.dbo.hc_payer_plan WHERE $wEncntr)"; PassDescription='Pass 2: via payer_plan'}
    Step-Delete @{Order='A102'; TableName='hc_encntr_ptnt_cndtn_assctn'; WhereClause="hc_ptnt_id IN (SELECT hc_ptnt_id FROM crs5_oltp.dbo.hc_ptnt WHERE $wEncntr)"}

    Step-Delete @{Order='A103'; TableName='hc_prgrm_plan_tag'; WhereClause=$wPrgrmPlan}
    Step-Delete @{Order='A104'; TableName='hc_prgrm_plan_wrk_actn'; WhereClause=$wPrgrmPlan}
    Step-Delete @{Order='A105'; TableName='hc_prgrm_plan'; WhereClause=$wEncntr}
    Step-Delete @{Order='A106'; TableName='hc_encntr'; WhereClause=$wAcct}

    Step-Delete @{Order='A107'; TableName='job_file'; WhereClause=$wAcct}
    Step-Delete @{Order='A108'; TableName='cnsmr_accnt_ownrs'; WhereClause=$wAcct; PassDescription='all remaining'}
    Step-Delete @{Order='A109'; TableName='sttlmnt_offr_accnt_assctn'; WhereClause=$wAcct}

    Step-Delete @{Order='A110'; TableName='pymnt_arrngmnt_accnt_dstrbtn_loan_rehab_cntrbtn'; WhereClause=$wPmtJrnl; PassDescription='Pass 2: via pymnt_jrnl'}
    Step-Delete @{Order='A111'; TableName='cnsmr_accnt_pymnt_jrnl_stgng'; WhereClause=$wPmtJrnl}
    Step-Delete @{Order='A112'; TableName='cnsmr_accnt_pymnt_jrnl'; WhereClause=$wAcct}

    Step-Delete @{Order='A113'; TableName='cnsmr_accnt_bckt_chck_rqst'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wAcct)"}
    Step-Delete @{Order='A114'; TableName='cnsmr_chck_btch_log'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wAcct)"}
    Step-Delete @{Order='A115'; TableName='cnsmr_chck_rqst'; WhereClause=$wAcct}

    # Safety re-delete: catch any ar_log rows written by concurrent DM activity during the batch window
    Step-Delete @{Order='A116'; TableName='cnsmr_accnt_ar_log'; WhereClause=$wAcct; PassDescription='Pass 2: safety re-delete'}

    Step-Delete @{Order='A117'; TableName='cnsmr_accnt'; WhereClause=$wAcct}
    Write-Log ""
    Write-Log "  Account-level deletion sequence complete" "SUCCESS"
}

# ============================================================================
# STEP 8: BIDATA P->C Migration (orders AB1-AB4)
# ============================================================================

Write-Log ""
Write-Log "--- Step 8: BIDATA P->C Migration ---"

if ($Script:TablesFailed -gt 0) {
    Write-Log "  Skipping BIDATA migration — account-level deletes had failures" "WARN"
    $Script:BidataStatus = 'Skipped'
}
elseif ($Script:BatchAccountIds.Count -eq 0) {
    Write-Log "  Skipping BIDATA migration — no accounts in batch" "INFO"
    $Script:BidataStatus = 'Skipped'
}
elseif (-not $Script:BidataServer) {
    Write-Log "  Skipping BIDATA migration — bidata_instance not configured" "WARN"
    $Script:BidataStatus = 'Skipped'
}
elseif (-not $script:XFActsExecute) {
    Write-Log "  Skipping BIDATA migration — preview mode" "INFO"
    $Script:BidataStatus = 'Skipped'
}
else {
    # BIDATA connection was opened up-front in Step 2. Verify still open.
    if (-not $Script:BidataConnection -or $Script:BidataConnection.State -ne 'Open') {
        Write-Log "  BIDATA connection not open — attempting to reopen" "WARN"
        $bidataOk = Open-BidataConnection
    } else {
        $bidataOk = $true
    }

    if (-not $bidataOk) {
        Write-Log "  BIDATA migration failed — connection unavailable" "ERROR"
        $Script:BidataStatus = 'Failed'
    }
    else {
        try {
            # Create #bidata_batch_accounts on BIDATA connection and populate
            $createCmd = $Script:BidataConnection.CreateCommand()
            $createCmd.CommandText = "IF OBJECT_ID('tempdb..#bidata_batch_accounts') IS NOT NULL DROP TABLE #bidata_batch_accounts; CREATE TABLE #bidata_batch_accounts (cnsmr_accnt_id BIGINT PRIMARY KEY);"
            $createCmd.CommandTimeout = 30
            $createCmd.ExecuteNonQuery() | Out-Null
            $createCmd.Dispose()

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

            # The four P->C table pairs (orders AB1-AB4)
            $bidataTables = @(
                @{ Order = 'AB1'; Source = 'GenAccountTblP';    Dest = 'GenAccountTblC' }
                @{ Order = 'AB2'; Source = 'GenAccPayTblP';     Dest = 'GenAccPayTblC' }
                @{ Order = 'AB3'; Source = 'GenAccPayAggTblP';  Dest = 'GenAccPayAggTblC' }
                @{ Order = 'AB4'; Source = 'GenPaymentTblP';    Dest = 'GenPaymentTblC' }
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
                    Write-Log "  [$($tbl.Order)] $($tbl.Source) -> $($tbl.Dest) — FAILED (${stepMs}ms): $($_.Exception.Message)" "ERROR"
                    Write-BatchDetail -DeleteOrder $tbl.Order -TableName "$($tbl.Source) -> $($tbl.Dest)" `
                        -PassDescription 'P -> C migration' -RowsAffected 0 -DurationMs $stepMs -Status 'Failed' -ErrorMessage $_.Exception.Message
                    $bidataAllOk = $false
                    break
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
                        $anonCmd.CommandTimeout = 900
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
                        $anonCmd.CommandTimeout = 900
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
                        $anonCmd.CommandTimeout = 900
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
                        $anonCmd.CommandTimeout = 900
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
                        $purgeCmd.CommandTimeout = 900
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
                # Halt the batch — Steps 9/10 will skip
                $Script:StopProcessing = $true
            }
        }
        catch {
            Write-Log "  BIDATA migration failed: $($_.Exception.Message)" "ERROR"
            $Script:BidataStatus = 'Failed'
            $Script:StopProcessing = $true
        }
    }
}

Write-Log ""

# ============================================================================
# STEP 9: Materialize Consumer-Level Temp Tables
# ============================================================================

if ($Script:StopProcessing) {
    Write-Log "--- Step 9: Skipped (prior failure halts consumer-level processing) ---"
    Write-Log ""
}
else {
    Write-Log "--- Step 9: Materialize Consumer-Level Temp Tables ---"

    $materializeCnsmrSQL = @"
    IF OBJECT_ID('tempdb..#shell_pymnt_instrmnt_ids') IS NOT NULL DROP TABLE #shell_pymnt_instrmnt_ids;
    SELECT cnsmr_pymnt_instrmnt_id INTO #shell_pymnt_instrmnt_ids
    FROM crs5_oltp.dbo.cnsmr_pymnt_instrmnt
    WHERE cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers);
    CREATE CLUSTERED INDEX CIX ON #shell_pymnt_instrmnt_ids (cnsmr_pymnt_instrmnt_id);

    IF OBJECT_ID('tempdb..#shell_pymnt_jrnl_ids') IS NOT NULL DROP TABLE #shell_pymnt_jrnl_ids;
    SELECT cnsmr_pymnt_jrnl_id INTO #shell_pymnt_jrnl_ids
    FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl
    WHERE cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers);
    CREATE CLUSTERED INDEX CIX ON #shell_pymnt_jrnl_ids (cnsmr_pymnt_jrnl_id);

    IF OBJECT_ID('tempdb..#shell_cntct_trnsctn_ids') IS NOT NULL DROP TABLE #shell_cntct_trnsctn_ids;
    SELECT cnsmr_cntct_trnsctn_log_id INTO #shell_cntct_trnsctn_ids
    FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log
    WHERE cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers);
    CREATE CLUSTERED INDEX CIX ON #shell_cntct_trnsctn_ids (cnsmr_cntct_trnsctn_log_id);

    IF OBJECT_ID('tempdb..#shell_smmry_ids') IS NOT NULL DROP TABLE #shell_smmry_ids;
    SELECT schdld_pymnt_smmry_id INTO #shell_smmry_ids
    FROM crs5_oltp.dbo.schdld_pymnt_smmry
    WHERE cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers);
    CREATE CLUSTERED INDEX CIX ON #shell_smmry_ids (schdld_pymnt_smmry_id);

    IF OBJECT_ID('tempdb..#shell_ar_log_ids') IS NOT NULL DROP TABLE #shell_ar_log_ids;
    SELECT cnsmr_accnt_ar_log_id INTO #shell_ar_log_ids
    FROM crs5_oltp.dbo.cnsmr_accnt_ar_log
    WHERE cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers);
    CREATE CLUSTERED INDEX CIX ON #shell_ar_log_ids (cnsmr_accnt_ar_log_id);

    SELECT
        (SELECT COUNT(*) FROM #shell_pymnt_instrmnt_ids) AS instrmnt_count,
        (SELECT COUNT(*) FROM #shell_pymnt_jrnl_ids) AS jrnl_count,
        (SELECT COUNT(*) FROM #shell_cntct_trnsctn_ids) AS cntct_count,
        (SELECT COUNT(*) FROM #shell_smmry_ids) AS smmry_count,
        (SELECT COUNT(*) FROM #shell_ar_log_ids) AS ar_log_count;
"@

    try {
        $cmd = $Script:TargetConnection.CreateCommand()
        $cmd.CommandText = $materializeCnsmrSQL
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
        $shellArLogCount = [long]$countTable.Rows[0].ar_log_count

        Write-Log "  Consumer-level intermediate ID tables materialized:" "SUCCESS"
        Write-Log "    Payment instruments: $instrmntCount" "INFO"
        Write-Log "    Payment journals:    $jrnlCount" "INFO"
        Write-Log "    Contact txn logs:    $cntctCount" "INFO"
        Write-Log "    Sched pymnt smmry:   $smmryCount" "INFO"
        Write-Log "    AR Log entries:      $shellArLogCount" "INFO"
    }
    catch {
        Write-Log "Failed to create consumer-level temp tables: $($_.Exception.Message)" "ERROR"
        $Script:StopProcessing = $true
    }

    Write-Log ""
}

# ============================================================================
# STEP 10: Execute Consumer-Level Deletions (Phase 1 UDEFs CU* + Phase 2 C1-C110)
# ============================================================================

if ($Script:StopProcessing) {
    Write-Log "--- Step 10: Skipped (prior failure halts consumer-level processing) ---"
    Write-Log ""
}
else {
    Write-Log "--- Step 10: Execute Consumer-Level Deletions ---"
    Write-Log ""

    # Reassign where-clause variables for consumer-level scope.
    # NOTE: $wArLog is reassigned from its account-level meaning above
    #       (#batch_ar_log_ids) to consumer-level (#shell_ar_log_ids).
    # NOTE: $wCnsmr references #archive_batch_consumers (unified naming),
    #       not #shell_batch_consumers from the standalone shell purge script.
    $wCnsmr       = "cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"
    $wCntctLog    = "cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM #shell_cntct_trnsctn_ids)"
    $wInstrmnt    = "cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
    $wJrnl        = "cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
    $wSmmry       = "schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
    $wArLog       = "cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"

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
            Step-Delete @{Order="CU$udefOrder"; TableName=$udefTable; WhereClause=$wCnsmr}
        }
    }

    Write-Log ""

    # ── Phase 2: Consumer-Level Tables (orders C1-C110) ──
    # Tables marked [EXCL] in the standalone shell purge are exclusion-controlled.
    # Under the unified archive flow no exclusions apply (Step 5 handles eligibility),
    # so these run unconditionally. Pass description preserved for cross-reference.
    Write-Log "  Phase 2: Consumer-Level Tables" "INFO"

    # ── Simple direct cnsmr_id tables (no FK children, no ordering concerns) ──
    Step-Delete @{Order='C1'; TableName='asst'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C2'; TableName='attrny'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C3'; TableName='cnsmr_addrss'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C4'; TableName='cnsmr_Cmmnt'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C5'; TableName='cnsmr_crdt'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C6'; TableName='cnsmr_fee_spprss_cnfg'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C7'; TableName='cnsmr_Fnncl'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C8'; TableName='cnsmr_rndm_nmbr'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C9'; TableName='cnsmr_Rvw_rqst'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C10'; TableName='cnsmr_Tag'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C11'; TableName='cnsmr_Wrk_actn'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C12'; TableName='decsd'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C13'; TableName='dfrrd_cnsmr'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C14'; TableName='emplyr'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C15'; TableName='ivr_call_log'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C16'; TableName='job_skptrc_cnsmr'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C17'; TableName='job_skptrc_instnc_log'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C18'; TableName='strtgy_log'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C19'; TableName='usr_rmndr'; WhereClause="usr_rmndr_cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"}
    Step-Delete @{Order='C20'; TableName='cnsmr_accnt_spplmntl_info'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C21'; TableName='cb_rpt_assctd_cnsmr_data'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C22'; TableName='cb_rpt_base_data'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C23'; TableName='cb_rpt_emplyr_data'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C24'; TableName='cb_rpt_rqst_dtl'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C25'; TableName='job_file'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C26'; TableName='cnsmr_accnt_ownrs'; WhereClause=$wCnsmr}

    # ── bal_rdctn_plan chain (FK: stpdwn -> plan -> cnsmr) ──
    Step-Delete @{Order='C27'; TableName='bal_rdctn_plan_stpdwn'; WhereClause="bal_rdctn_plan_id IN (SELECT bal_rdctn_plan_id FROM crs5_oltp.dbo.bal_rdctn_plan WHERE $wCnsmr)"}
    Step-Delete @{Order='C28'; TableName='bal_rdctn_plan'; WhereClause=$wCnsmr}

    # ── ca_case chain (FK: children -> ca_case -> cnsmr) ──
    Step-Delete @{Order='C29'; TableName='ca_case_accnt_assctn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-Delete @{Order='C30'; TableName='ca_case_ar_log_assctn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-Delete @{Order='C31'; TableName='ca_case_bal_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-Delete @{Order='C32'; TableName='ca_case_cntct_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-Delete @{Order='C33'; TableName='ca_case_lck_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-Delete @{Order='C34'; TableName='ca_case_strtgy_log'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-Delete @{Order='C35'; TableName='ca_case_tag'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-Delete @{Order='C36'; TableName='dfrrd_ca_case'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-Delete @{Order='C37'; TableName='wrk_lst_case_cache'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-Delete @{Order='C38'; TableName='wrkgrp_scan_lst_case_cache'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-Delete @{Order='C39'; TableName='ca_case'; WhereClause=$wCnsmr}

    # ── cmpgn chain (FK: dialer_trnsctn_log -> cmpgn_trnsctn_log -> cnsmr, cmpgn_cache -> cnsmr_Phn) ──
    Step-Delete @{Order='C40'; TableName='dialer_trnsctn_log'; WhereClause="cmpgn_trnsctn_log_id IN (SELECT cmpgn_trnsctn_log_id FROM crs5_oltp.dbo.cmpgn_trnsctn_log WHERE $wCnsmr)"}
    Step-Delete @{Order='C41'; TableName='cmpgn_trnsctn_log'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C42'; TableName='cmpgn_cache'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C43'; TableName='cnsmr_Phn'; WhereClause=$wCnsmr}

    # ── cnsmr_accnt_ar_log chain — contact log children BEFORE ar_log ──
    Step-Delete @{Order='C44'; TableName='cnsmr_cntct_addrs_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
    Step-Delete @{Order='C45'; TableName='cnsmr_cntct_phn_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
    Step-Delete @{Order='C46'; TableName='cnsmr_cntct_email_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
    Step-Delete @{Order='C47'; TableName='cnsmr_cntct_trnsctn_log'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C48'; TableName='cnsmr_task_itm_cnsmr_accnt_ar_log_assctn'; WhereClause=$wArLog}

    # ── agnt_crdtbl_actvty chain via ar_log — must clear before cnsmr_accnt_ar_log ──
    Step-JoinDelete @{
        Order = 'C49'; TableName = 'agnt_crdtbl_actvty_spprssn'
        DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        PassDescription = 'Pass 1: via ar_log'
    }

    Step-JoinDelete @{
        Order = 'C50'; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
        DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        PassDescription = 'Pass 1: via ar_log'
    }

    Step-JoinDelete @{
        Order = 'C51'; TableName = 'agnt_crdtbl_actvty'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        PassDescription = 'Pass 1: via ar_log'
    }

    Step-Delete @{Order='C52'; TableName='crdtr_srvc_evnt'; WhereClause=$wCnsmr; PassDescription='before ar_log (FK dependency)'}
    Step-Delete @{Order='C53'; TableName='cnsmr_accnt_ar_log'; WhereClause=$wArLog}

    # ── cnsmr_task_itm (must come after ar_log association at C48) ──
    Step-Delete @{Order='C54'; TableName='cnsmr_task_itm'; WhereClause=$wCnsmr}

    # ── invc_crrctn chain (FK: dtl children -> parent -> cnsmr) ──
    Step-Delete @{Order='C55'; TableName='invc_crrctn_dtl_stgng'; WhereClause="invc_crrctn_trnsctn_stgng_id IN (SELECT invc_crrctn_trnsctn_stgng_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn_stgng WHERE $wCnsmr)"}
    Step-Delete @{Order='C56'; TableName='invc_crrctn_trnsctn_stgng'; WhereClause=$wCnsmr}
    Step-Delete @{Order='C57'; TableName='invc_crrctn_dtl'; WhereClause="invc_crrctn_trnsctn_id IN (SELECT invc_crrctn_trnsctn_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn WHERE $wCnsmr)"}
    Step-Delete @{Order='C58'; TableName='invc_crrctn_trnsctn'; WhereClause=$wCnsmr}

    # ── jdgmnt chain (FK: jdgmnt_addtnl_info -> jdgmnt -> cnsmr) ──
    Step-Delete @{Order='C59'; TableName='jdgmnt_addtnl_info'; WhereClause="jdgmnt_id IN (SELECT jdgmnt_id FROM crs5_oltp.dbo.jdgmnt WHERE $wCnsmr)"}
    Step-Delete @{Order='C60'; TableName='jdgmnt'; WhereClause=$wCnsmr}

    # ── Rltd_Prsn chain (FK: rltd_prsn_tag -> Rltd_Prsn -> cnsmr) ──
    Step-Delete @{Order='C61'; TableName='rltd_prsn_tag'; WhereClause="rltd_prsn_id IN (SELECT rltd_prsn_id FROM crs5_oltp.dbo.Rltd_Prsn WHERE $wCnsmr)"}
    Step-Delete @{Order='C62'; TableName='Rltd_Prsn'; WhereClause=$wCnsmr}

    # ── cnsmr_chck_rqst chain (FK: children -> cnsmr_chck_rqst -> cnsmr) ──
    Step-Delete @{Order='C63'; TableName='cnsmr_accnt_bckt_chck_rqst'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wCnsmr)"}
    Step-Delete @{Order='C64'; TableName='cnsmr_chck_btch_log'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wCnsmr)"}
    Step-Delete @{Order='C65'; TableName='cnsmr_chck_rqst'; WhereClause=$wCnsmr}

    # ── notice_rqst (must come before schdld_pymnt_instnc which has FK to notice_rqst) ──
    Step-Delete @{Order='C66'; TableName='notice_rqst'; WhereClause=$wCnsmr}

    # ── sttlmnt_offr chain — must come before cnsmr_pymnt_instrmnt AND schdld_pymnt_smmry ──
    Step-Delete @{Order='C67'; TableName='sttlmnt_offr_accnt_assctn'; WhereClause="sttlmnt_offr_id IN (SELECT sttlmnt_offr_id FROM crs5_oltp.dbo.sttlmnt_offr WHERE $wCnsmr)"}
    Step-Delete @{Order='C68'; TableName='sttlmnt_offr_systm_dtl'; WhereClause="sttlmnt_offr_id IN (SELECT sttlmnt_offr_id FROM crs5_oltp.dbo.sttlmnt_offr WHERE $wCnsmr)"}
    Step-Delete @{Order='C69'; TableName='sttlmnt_offr'; WhereClause=$wCnsmr}

    # ── epp chain (FK: children -> epp_pymnt_typ_cnfg -> cnsmr_pymnt_instrmnt) ──
    Step-Delete @{Order='C70'; TableName='epp_cmmnctn_log'; WhereClause="epp_pymnt_typ_cnfg_id IN (SELECT epp_pymnt_typ_cnfg_id FROM crs5_oltp.dbo.epp_pymnt_typ_cnfg WHERE $wInstrmnt)"}
    Step-Delete @{Order='C71'; TableName='epp_vrfctn_rspns'; WhereClause="epp_pymnt_typ_cnfg_id IN (SELECT epp_pymnt_typ_cnfg_id FROM crs5_oltp.dbo.epp_pymnt_typ_cnfg WHERE $wInstrmnt)"}
    Step-Delete @{Order='C72'; TableName='epp_pymnt_typ_cnfg'; WhereClause=$wInstrmnt}
    Step-Delete @{Order='C73'; TableName='epp_pymnt_rspns'; WhereClause=$wCnsmr}

    # ── cpm_pm_assctn (FK to both cnsmr_pymnt_instrmnt AND cnsmr_pymnt_mthd) ──
    Step-Delete @{Order='C74'; TableName='cpm_pm_assctn'; WhereClause=$wInstrmnt}

    # ── Scheduled payment children (before schdld_pymnt_instnc) ──
    Step-Delete @{Order='C75'; TableName='pymnt_schdl_notice_rqst_assctn'; WhereClause="schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE $wSmmry)"}
    Step-Delete @{Order='C76'; TableName='schdld_pymnt_cnsmr_accnt_assctn'; WhereClause=$wSmmry; PassDescription='via smmry'}

    # ── Agent credit chain [EXCL] — must clear before cnsmr_pymnt_jrnl ──
    # agnt_crdt has FK on cnsmr_pymnt_jrnl_id
    Step-Delete @{Order='C77'; TableName='agnt_crdt_spprssn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE $wJrnl)"; PassDescription='[EXCL] via pymnt_jrnl'}
    Step-Delete @{Order='C78'; TableName='agnt_crdtbl_actvty_crdt_assctn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE $wJrnl)"; PassDescription='[EXCL] Pass 1: via pymnt_jrnl'}
    Step-Delete @{Order='C79'; TableName='agnt_crdt'; WhereClause=$wJrnl; PassDescription='[EXCL] via pymnt_jrnl'}

    # ── Payment journal children (must clear before cnsmr_pymnt_jrnl) ──
    Step-Delete @{Order='C80'; TableName='cnsmr_chck_trnsctn'; WhereClause=$wJrnl; PassDescription='via pymnt_jrnl'}

    Step-JoinDelete @{
        Order = 'C81'; TableName = 'cpj_rvrsl_assctn'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.cpj_rvrsl_assctn WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cpj_rvrsl_assctn WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
        PassDescription = 'via pymnt_jrnl'
    }

    # cnsmr_pymnt_jrnl_schdld_pymnt_instnc: FK to BOTH cnsmr_pymnt_jrnl AND schdld_pymnt_instnc
    Step-JoinDelete @{
        Order = 'C82'; TableName = 'cnsmr_pymnt_jrnl_schdld_pymnt_instnc'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
        PassDescription = 'Pass 1: via pymnt_jrnl'
    }

    Step-JoinDelete @{
        Order = 'C83'; TableName = 'cnsmr_pymnt_jrnl_schdld_pymnt_instnc'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"
        PassDescription = 'Pass 2: via smmry'
    }

    # ── cnsmr_pymnt_jrnl — all children now cleared ──
    Step-Delete @{Order='C84'; TableName='cnsmr_pymnt_jrnl'; WhereClause=$wCnsmr}

    # ── schdld_pymnt_instnc — cnsmr_pymnt_jrnl_schdld_pymnt_instnc cleared above ──
    Step-Delete @{Order='C85'; TableName='schdld_pymnt_instnc'; WhereClause=$wSmmry; PassDescription='via smmry'}

    # ── Suspense: NULL resolved cross-consumer payment journal references ──
    # When consumer A merges into consumer B, the payment journal moves to B but the
    # sspns_cnsmr_imprt_trnsctn stays on A. The FK reference from B's cnsmr_pymnt_jrnl
    # back to A's suspense record is a historical breadcrumb. For resolved suspense
    # (status 3=RESOLVED, 5=RESOLVED_AS_REFUND, 7=RESOLVED_AS_ESCHEAT, 10=MULTI_RESOLVED),
    # we NULL the reference to allow deletion.
    Step-Update @{
        Order = 'C86'; TableName = 'cnsmr_pymnt_jrnl'
        UpdateStatement = "UPDATE cpj SET cpj.sspns_cnsmr_imprt_trnsctn_id = NULL FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj WHERE cpj.sspns_cnsmr_imprt_trnsctn_id IN (SELECT sci.sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn sci INNER JOIN crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci ON sci.sspns_trnsctn_cnsmr_idntfr_id = stci.sspns_trnsctn_cnsmr_idntfr_id WHERE stci.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers) AND sci.sspns_trnsctn_stts_cd IN (3, 5, 7, 10))"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj WHERE cpj.sspns_cnsmr_imprt_trnsctn_id IN (SELECT sci.sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn sci INNER JOIN crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci ON sci.sspns_trnsctn_cnsmr_idntfr_id = stci.sspns_trnsctn_cnsmr_idntfr_id WHERE stci.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers) AND sci.sspns_trnsctn_stts_cd IN (3, 5, 7, 10))"
        PassDescription = 'NULL resolved suspense refs on merged consumers'
    }

    # ── Suspense chain — must come after cnsmr_pymnt_jrnl (which has FK to sspns_cnsmr_imprt_trnsctn) ──
    Step-Delete @{Order='C87'; TableName='sspns_cnsmr_trnsctn_log'; WhereClause="sspns_cnsmr_imprt_trnsctn_id IN (SELECT sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE $wInstrmnt)"; PassDescription='Pass 1: via pymnt_instrmnt'}

    Step-JoinDelete @{
        Order = 'C88'; TableName = 'sspns_cnsmr_imprt_trnsctn'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
        PassDescription = 'Pass 1: via pymnt_instrmnt'
    }

    Step-Delete @{Order='C89'; TableName='sspns_cnsmr_trnsctn_log'; WhereClause="sspns_cnsmr_imprt_trnsctn_id IN (SELECT sci.sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn sci INNER JOIN crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci ON sci.sspns_trnsctn_cnsmr_idntfr_id = stci.sspns_trnsctn_cnsmr_idntfr_id WHERE stci.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers))"; PassDescription='Pass 2: via sspns_trnsctn_cnsmr_idntfr'}

    Step-Delete @{Order='C90'; TableName='sspns_cnsmr_imprt_trnsctn'; WhereClause="sspns_trnsctn_cnsmr_idntfr_id IN (SELECT sspns_trnsctn_cnsmr_idntfr_id FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr WHERE $wCnsmr)"; PassDescription='Pass 2: via sspns_trnsctn_cnsmr_idntfr'}

    # ── Agent creditable activity chain [EXCL] — Pass 2: via direct cnsmr_id ──
    Step-JoinDelete @{
        Order = 'C91'; TableName = 'agnt_crdtbl_actvty_spprssn'
        DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"
        PassDescription = '[EXCL] Pass 2: via direct cnsmr_id'
    }

    Step-JoinDelete @{
        Order = 'C92'; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
        DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"
        PassDescription = '[EXCL] Pass 2: via direct cnsmr_id'
    }

    Step-Delete @{Order='C93'; TableName='agnt_crdtbl_actvty'; WhereClause=$wCnsmr; PassDescription='[EXCL] Pass 2: via direct cnsmr_id'}

    # ── cnsmr_pymnt_instrmnt (now safe — ALL FK children cleared above) ──
    Step-Delete @{Order='C94'; TableName='cnsmr_pymnt_instrmnt'; WhereClause=$wCnsmr; PassDescription='Pass 1: direct'}

    Step-JoinDelete @{
        Order = 'C95'; TableName = 'cnsmr_pymnt_instrmnt'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_instrmnt WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl WHERE cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers))"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_instrmnt WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl WHERE cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers))"
        PassDescription = 'Pass 2: via pymnt_jrnl'
    }

    # ── cnsmr_pymnt_mthd (now safe — cpm_pm_assctn cleared at C74) ──
    Step-Delete @{Order='C96'; TableName='cnsmr_pymnt_mthd'; WhereClause=$wCnsmr}

    # ── sspns_trnsctn_cnsmr_idntfr (now safe — all suspense children cleared) ──
    Step-Delete @{Order='C97'; TableName='sspns_trnsctn_cnsmr_idntfr'; WhereClause=$wCnsmr}

    # ── Agent credit chain Pass 2: via schdld_pymnt_smmry ──
    Step-Delete @{Order='C98'; TableName='agnt_crdt_spprssn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"; PassDescription='[EXCL] Pass 2: via smmry'}
    Step-Delete @{Order='C99'; TableName='agnt_crdtbl_actvty_crdt_assctn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"; PassDescription='[EXCL] Pass 2: via smmry'}
    Step-Delete @{Order='C100'; TableName='agnt_crdt'; WhereClause="cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"; PassDescription='[EXCL] Pass 2: via smmry'}

    # ── agnt_crdtbl_actvty chain Pass 3: via schdld_pymnt_smmry ──
    Step-JoinDelete @{
        Order = 'C101'; TableName = 'agnt_crdtbl_actvty_spprssn'
        DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
        PassDescription = '[EXCL] Pass 3: via smmry'
    }

    Step-JoinDelete @{
        Order = 'C102'; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
        DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
        PassDescription = '[EXCL] Pass 3: via smmry'
    }

    Step-Delete @{Order='C103'; TableName='agnt_crdtbl_actvty'; WhereClause="cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"; PassDescription='[EXCL] Pass 3: via smmry'}

    # ── schdld_pymnt_smmry (now safe — all children cleared above) ──
    Step-Delete @{Order='C104'; TableName='schdld_pymnt_smmry'; WhereClause=$wSmmry}

    # ── Bankruptcy chain [EXCL] ──
    Step-Delete @{Order='C105'; TableName='bnkrptcy_addtnl_info'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
    Step-Delete @{Order='C106'; TableName='bnkrptcy_pttnr'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
    Step-Delete @{Order='C107'; TableName='bnkrptcy_trustee'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
    Step-Delete @{Order='C108'; TableName='bnkrptcy'; WhereClause=$wCnsmr; PassDescription='[EXCL]'}

    # ── hc_payer_plan (direct cnsmr FK, no encntr dependency for shells) ──
    Step-Delete @{Order='C109'; TableName='hc_payer_plan'; WhereClause=$wCnsmr}

    # ── TERMINAL: cnsmr record itself ──
    Step-Delete @{Order='C110'; TableName='cnsmr'; WhereClause=$wCnsmr}

    Write-Log ""
    Write-Log "  Consumer-level deletion sequence complete" "SUCCESS"
}

# ============================================================================
# STEP 11: Finalize Batch Log
# ============================================================================

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
$Script:SessionTotalExceptions += $Script:BatchExceptions.Count
if ($batchStatus -eq 'Failed') { $Script:TotalBatchesFailed++ }

# ── Batch summary ──
$batchDuration = (Get-Date) - $Script:BatchStartTime
$retryNote = if ($Script:RetryOfBatchId -gt 0) { " [retry of batch_id $($Script:RetryOfBatchId)]" } else { "" }
$exceptionNote = if ($Script:BatchExceptions.Count -gt 0) { " (exceptions: $($Script:BatchExceptions.Count))" } else { "" }
Write-Log "  Batch #$($Script:TotalBatchesRun): $($Script:BatchConsumerIds.Count) consumers, $($Script:BatchAccountIds.Count) accounts, $($Script:TotalDeleted) rows, $([math]::Round($batchDuration.TotalSeconds, 1))s — $batchStatus (BIDATA: $($Script:BidataStatus))$exceptionNote$retryNote" "INFO"

# ── Queue Teams alert on failure (execute mode only — Send-TeamsAlert writes to Teams.AlertQueue) ──
if ($batchStatus -eq 'Failed' -and $Script:AlertingEnabled -and $script:XFActsExecute) {
    Send-TeamsAlert -SourceModule 'DmOps' -AlertCategory 'CRITICAL' `
        -Title '{{FIRE}} Consumer archive batch failed' `
        -Message "**Batch:** #$($Script:TotalBatchesRun) (batch_id: $($Script:CurrentBatchId))$retryNote`n**Target:** $($Script:TargetServer)`n**Tables Failed:** $($Script:TablesFailed)`n**Consumers:** $($Script:BatchConsumerIds.Count)`n**Accounts:** $($Script:BatchAccountIds.Count)`n**Exceptions:** $($Script:BatchExceptions.Count)`n**BIDATA:** $($Script:BidataStatus)`n`nCheck Archive_BatchDetail for batch_id $($Script:CurrentBatchId)." `
        -TriggerType 'ARCHIVE_BATCH_FAILED' `
        -TriggerValue "$($Script:CurrentBatchId)" | Out-Null
}
elseif ($batchStatus -eq 'Failed' -and -not $script:XFActsExecute) {
    Write-Log "  [Preview] Would queue Teams alert (ARCHIVE_BATCH_FAILED)" "INFO"
}
elseif ($batchStatus -eq 'Failed') {
    Write-Log "  Teams alert suppressed — alerting_enabled is off" "INFO"
}

# ============================================================================
# STEP 12: Batch Loop Continuation Check
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
            Write-Log "  Schedule/config update: $($Script:ScheduleMode) ($activeBatchSize) -> $newMode ($newBatchSize)" "INFO"
            $Script:ScheduleMode = $newMode
            $activeBatchSize = $newBatchSize
        }

        Start-Sleep -Seconds 2
    }
}

}  # end while ($continueProcessing)

# ============================================================================
# STEP 13: Cleanup, Session Summary, Orchestrator Callback
# ============================================================================

Close-BidataConnection
Close-TargetConnection

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart
$totalMs = [int]$scriptDuration.TotalMilliseconds

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Session Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "  Mode             : $(if ($script:XFActsExecute) { 'EXECUTE' } else { 'PREVIEW' })"
Write-Log "  Target           : $($Script:TargetServer)"
Write-Log "  Batches Run      : $($Script:TotalBatchesRun)"
Write-Log "  Batches Failed   : $($Script:TotalBatchesFailed)"
Write-Log "  Total Consumers  : $($Script:SessionTotalConsumers)"
Write-Log "  Total Accounts   : $($Script:SessionTotalAccounts)"
Write-Log "  Total Exceptions : $($Script:SessionTotalExceptions)"
if (-not $script:XFActsExecute) {
    Write-Log "  Rows to Delete   : $($Script:SessionTotalDeleted)"
} else {
    Write-Log "  Rows Deleted     : $($Script:SessionTotalDeleted)"
}
Write-Log "  Duration         : $([math]::Round($scriptDuration.TotalSeconds, 1))s"
Write-Host ""

if (-not $script:XFActsExecute) {
    Write-Host "  *** PREVIEW MODE — No changes were made ***" -ForegroundColor Yellow
    Write-Host "  Run with -Execute to perform actual deletions" -ForegroundColor Yellow
    Write-Host ""
}

# Orchestrator callback
if ($TaskId -gt 0) {
    $finalStatus = if ($Script:TotalBatchesFailed -gt 0) { "FAILED" } else { "SUCCESS" }
    $outputSummary = "Batches:$($Script:TotalBatchesRun) Failed:$($Script:TotalBatchesFailed) Consumers:$($Script:SessionTotalConsumers) Accounts:$($Script:SessionTotalAccounts) Exceptions:$($Script:SessionTotalExceptions) Deleted:$($Script:SessionTotalDeleted)"
    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}

if ($Script:TotalBatchesFailed -gt 0) { exit 1 } else { exit 0 }
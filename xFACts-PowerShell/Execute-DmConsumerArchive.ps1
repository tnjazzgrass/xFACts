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
    SET clauses, purge flags). Failure halts the batch - consumer-level
    deletes do not run, leaving the consumer in a recoverable
    near-shell state for retry.
    5. Consumer-level deletes (Phase 1 UDEFs CU1+, Phase 2 orders C1-C110,
    includes order C86 Step-dmo_Update for cross-consumer suspense
    reference cleanup)

    Five startup lookups are required and resolved before the persistent
    target connection is opened - four GlobalConfig values
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

    Does NOT replace Execute-DmShellPurge.ps1 - shell purge runs
    independently for naturally-occurring shells (existing WFAPURGE backlog
    plus ongoing shells from new-business loads, consumer merges, manual
    activity). The two processes operate on disjoint populations.

    Schedule-aware: reads DmOps.Archive_Schedule to determine execution
    mode per hour (blocked/full/reduced). Checks schedule between batches.
    Emergency abort via GlobalConfig archive_abort flag. Stops gracefully
    when the BIDATA Daily Build SQL Agent job starts to avoid contention.

    Failed batches retry from Archive_ConsumerLog on the next run (Retry
    schedule_mode). Retry path skips re-verification - consumers in
    ConsumerLog have already passed re-verification once and are past the
    point of no return.

    Preview vs Execute: when the -Execute switch is omitted, the script
    runs in PREVIEW mode and performs no writes anywhere - no row inserts
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
    testing - sets schedule_mode to 'Manual'.

.PARAMETER ChunkSize
    Rows per chunked DELETE/UPDATE inside a single delete operation.
    Default: reads from GlobalConfig DmOps.Archive.chunk_size.

.PARAMETER Execute
    Switch. Without this switch the script runs in PREVIEW mode - counts
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

.COMPONENT
    DmOps

.NOTES
    File Name : Execute-DmConsumerArchive.ps1
    Location  : E:\xFACts-PowerShell\Execute-DmConsumerArchive.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    VARIABLES: SCRIPT-LEVEL STATE
    FUNCTIONS: CONNECTION MANAGEMENT
    FUNCTIONS: STARTUP LOOKUPS
    FUNCTIONS: SCHEDULE AND CONTROL
    FUNCTIONS: SQL PRIMITIVES
    FUNCTIONS: BIDATA MIGRATION
    FUNCTIONS: BATCH LOGGING
    FUNCTIONS: RUNTIME RE-VERIFICATION
    FUNCTIONS: OPERATION WRAPPERS
    FUNCTIONS: STEP WRAPPERS
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this script. Most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-04-26  Initial unified consumer archive implementation. Replaces
#             account-level Execute-DmArchive.ps1 (moved to Reference/). Combines
#             TC_ARCH-driven batch selection, runtime re-verification, account-level
#             Phase 2 deletes (orders A1-A117), BIDATA P->C migration (orders AB1-AB4)
#             with anonymization, and consumer-level Phase 2 deletes (orders C1-C110,
#             including C86 Step-dmo_Update for cross-consumer suspense reference
#             cleanup) into a single batch flow targeting the cnsmr terminal table.
#             Logging functions are guarded by $script:XFActsExecute so preview mode
#             is console-only with zero database writes.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   The CmdletBinding attribute and script parameter declarations.
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
    [switch]$NoAnonymize,
    [switch]$SingleBatch,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sources the shared orchestrator helpers used throughout the script.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Execute-DmConsumerArchive' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   VARIABLES: SCRIPT-LEVEL STATE
   ----------------------------------------------------------------------------
   Connection handles, resolved configuration and lookups, workgroup
   selection state, per-batch accumulators, and session counters. Mutated as
   the script runs.
   Prefix: dmo
   ============================================================================ #>

# Connections
# crs5_oltp host (resolved from GlobalConfig or -TargetInstance)
$script:dmo_TargetServer            = $null
# Persistent SqlConnection to crs5_oltp
$script:dmo_TargetConnection        = $null
# BIDATA host (resolved from GlobalConfig)
$script:dmo_BidataServer            = $null
# Persistent SqlConnection to BIDATA
$script:dmo_BidataConnection        = $null

# Configuration (defaults overridden from GlobalConfig in Step 1)
$script:dmo_BatchChunkSize          = 5000
# Consumers per batch in full schedule mode.
$script:dmo_BatchSizeFull           = 10000
# Consumers per batch in reduced schedule mode.
$script:dmo_BatchSizeReduced        = 100
# True when -BatchSize overrode the schedule-driven size.
$script:dmo_ManualBatchSize         = $false
# True when failure alerts are enabled via GlobalConfig.
$script:dmo_AlertingEnabled         = $false
# Name of the BIDATA Daily Build SQL Agent job to monitor.
$script:dmo_BidataBuildJobName      = 'BIDATA Daily Build'

# Resolved startup lookups (Step 1, fail-fast)
$script:dmo_TcArchTagId             = $null
# Resolved actn_cd used when writing tag-removal AR events.
$script:dmo_TagRemovalActnCd        = $null
# Resolved rslt_cd used when writing tag-removal AR events.
$script:dmo_TagRemovalRsltCd        = $null
# Resolved usr_id stamped on tag-removal AR events.
$script:dmo_TagRemovalUserId        = $null
# Message text written on tag-removal AR events.
$script:dmo_TagRemovalMsgTxt        = $null

# Workgroup selection (line of business)
# Resolved wrkgrp_id values for the two archive workgroups (Step 1, fail-fast).
# Both are resolved regardless of the active target_workgroups setting so a
# missing/renamed workgroup surfaces immediately as a misconfiguration.
# wrkgrp_id of WFAARCH1 (1st party)
$script:dmo_WfaArch1Id              = $null
# wrkgrp_id of WFAARCH3 (3rd party)
$script:dmo_WfaArch3Id              = $null
# Active target setting from GlobalConfig DmOps.Archive.target_workgroups,
# re-read between batches: 'WFAARCH1' | 'WFAARCH3' | 'BOTH'.
$script:dmo_TargetWorkgroups        = 'BOTH'
# Short name of the workgroup the LAST batch ran against; drives BOTH-mode
# alternation. Null until the first batch picks one.
$script:dmo_LastWorkgroupUsed       = $null

# Schedule state
# 'Full' | 'Reduced' | 'Manual' | 'Retry' | 'Blocked'
$script:dmo_ScheduleMode            = $null

# Per-batch state (reset each batch)
$script:dmo_CurrentBatchId          = $null
# Start timestamp of the current batch.
$script:dmo_BatchStartTime          = $null
# Consumer ids selected for the current batch.
$script:dmo_BatchConsumerIds        = @()
# Account ids expanded from the current batch consumers.
$script:dmo_BatchAccountIds         = @()
# Per-account data rows for the current batch.
$script:dmo_BatchAccountData        = @()
# Consumers excepted by re-verification this batch.
$script:dmo_BatchExceptions         = @()
# Running row-delete count for the current batch.
$script:dmo_TotalDeleted            = 0
# Tables successfully processed this batch.
$script:dmo_TablesProcessed         = 0
# Tables skipped (zero rows) this batch.
$script:dmo_TablesSkipped           = 0
# Tables that failed this batch.
$script:dmo_TablesFailed            = 0
# Set true to halt the batch after a failure.
$script:dmo_StopProcessing          = $false
# Outcome of the BIDATA migration for the current batch.
$script:dmo_BidataStatus            = $null
# Original batch_id when the current batch is a retry.
$script:dmo_RetryOfBatchId          = 0
# Short name of the workgroup THIS batch ran against (stamped into
# Archive_BatchLog.source_workgroup). Set by Get-dmo_NextBatchWorkgroup on the
# normal path, or inherited from the original batch on the retry path.
$script:dmo_BatchWorkgroup          = $null

# Session-level counters
$script:dmo_TotalBatchesRun         = 0
# Count of batches that failed this session.
$script:dmo_TotalBatchesFailed      = 0
# Total rows deleted across the session.
$script:dmo_SessionTotalDeleted     = 0
# Total consumers archived across the session.
$script:dmo_SessionTotalConsumers   = 0
# Total accounts archived across the session.
$script:dmo_SessionTotalAccounts    = 0
# Total consumers excepted across the session.
$script:dmo_SessionTotalExceptions  = 0

<# ============================================================================
   FUNCTIONS: CONNECTION MANAGEMENT
   ----------------------------------------------------------------------------
   Open and close the persistent SqlConnection objects for the crs5_oltp
   target and the BIDATA database.
   Prefix: dmo
   ============================================================================ #>

# Opens the persistent SqlConnection to the crs5_oltp target instance.
function Open-dmo_TargetConnection {
    param()

    try {
        $connString = "Server=$($script:dmo_TargetServer);Database=crs5_oltp;Integrated Security=True;Application Name=$($script:XFActsAppName);Connect Timeout=30"
        $script:dmo_TargetConnection = New-Object System.Data.SqlClient.SqlConnection($connString)
        $script:dmo_TargetConnection.Open()
        Write-Log "  Persistent connection opened to $($script:dmo_TargetServer)/crs5_oltp" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to open connection to $($script:dmo_TargetServer): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Closes the persistent crs5_oltp target connection if open.
function Close-dmo_TargetConnection {
    param()

    if ($script:dmo_TargetConnection -and $script:dmo_TargetConnection.State -eq 'Open') {
        $script:dmo_TargetConnection.Close()
        $script:dmo_TargetConnection.Dispose()
        $script:dmo_TargetConnection = $null
        Write-Log "  Persistent connection closed" "INFO"
    }
}

# Opens a SqlConnection to the BIDATA database for the P-to-C migration.
function Open-dmo_BidataConnection {
    param()

    try {
        $connString = "Server=$($script:dmo_BidataServer);Database=BIDATA;Integrated Security=True;Application Name=$($script:XFActsAppName);Connect Timeout=30"
        $script:dmo_BidataConnection = New-Object System.Data.SqlClient.SqlConnection($connString)
        $script:dmo_BidataConnection.Open()
        Write-Log "  BIDATA connection opened to $($script:dmo_BidataServer)/BIDATA" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "  Failed to open BIDATA connection to $($script:dmo_BidataServer): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Closes the BIDATA connection if open.
function Close-dmo_BidataConnection {
    param()

    if ($script:dmo_BidataConnection -and $script:dmo_BidataConnection.State -eq 'Open') {
        $script:dmo_BidataConnection.Close()
        $script:dmo_BidataConnection.Dispose()
        $script:dmo_BidataConnection = $null
        Write-Log "  BIDATA connection closed" "INFO"
    }
}

<# ============================================================================
   FUNCTIONS: STARTUP LOOKUPS
   ----------------------------------------------------------------------------
   Resolve the GlobalConfig values, tag id, and workgroup ids required before
   the persistent connection opens. Any NULL result fails the script fast.
   Prefix: dmo
   ============================================================================ #>

# Resolves the startup lookups (tag id, removal codes/user/message, workgroup ids) before the persistent connection opens, failing fast on any NULL.
function Resolve-dmo_StartupLookups {
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

    $script:dmo_TagRemovalMsgTxt = $msgTxt

    try {
        $connString = "Server=$($script:dmo_TargetServer);Database=crs5_oltp;Integrated Security=True;Application Name=$($script:XFActsAppName);Connect Timeout=30"
        $tempConn = New-Object System.Data.SqlClient.SqlConnection($connString)
        $tempConn.Open()
    }
    catch {
        Write-Log "Failed to open lookup connection to $($script:dmo_TargetServer): $($_.Exception.Message)" "ERROR"
        return $false
    }

    try {
        # 1. Resolve TC_ARCH tag_id
        $cmd = $tempConn.CreateCommand()
        $cmd.CommandText = "SELECT tag_id FROM crs5_oltp.dbo.tag WHERE tag_shrt_nm = 'TC_ARCH' AND tag_actv_flg = 'Y'"
        $cmd.CommandTimeout = 30
        $r = $cmd.ExecuteScalar()
        $cmd.Dispose()
        if ($r -is [DBNull] -or $null -eq $r) {
            Write-Log "Lookup failed: tag.tag_id for TC_ARCH (active)" "ERROR"
            return $false
        }
        $script:dmo_TcArchTagId = [long]$r

        # 2. Resolve actn_cd
        $cmd = $tempConn.CreateCommand()
        $cmd.CommandText = "SELECT actn_cd FROM crs5_oltp.dbo.actn_cd WHERE actn_cd_shrt_val_txt = '$($actnShortVal.Replace("'", "''"))' AND actn_cd_actv_flg = 'Y'"
        $cmd.CommandTimeout = 30
        $r = $cmd.ExecuteScalar()
        $cmd.Dispose()
        if ($r -is [DBNull] -or $null -eq $r) {
            Write-Log "Lookup failed: actn_cd for short value '$actnShortVal' (active)" "ERROR"
            return $false
        }
        $script:dmo_TagRemovalActnCd = [int]$r

        # 3. Resolve rslt_cd
        $cmd = $tempConn.CreateCommand()
        $cmd.CommandText = "SELECT rslt_cd FROM crs5_oltp.dbo.rslt_cd WHERE rslt_cd_shrt_val_txt = '$($rsltShortVal.Replace("'", "''"))' AND rslt_cd_actv_flg = 'Y'"
        $cmd.CommandTimeout = 30
        $r = $cmd.ExecuteScalar()
        $cmd.Dispose()
        if ($r -is [DBNull] -or $null -eq $r) {
            Write-Log "Lookup failed: rslt_cd for short value '$rsltShortVal' (active)" "ERROR"
            return $false
        }
        $script:dmo_TagRemovalRsltCd = [int]$r

        # 4. Resolve usr_id
        $cmd = $tempConn.CreateCommand()
        $cmd.CommandText = "SELECT usr_id FROM crs5_oltp.dbo.usr WHERE usr_usrnm = '$($userShortVal.Replace("'", "''"))' AND usr_actv_flg = 'Y'"
        $cmd.CommandTimeout = 30
        $r = $cmd.ExecuteScalar()
        $cmd.Dispose()
        if ($r -is [DBNull] -or $null -eq $r) {
            Write-Log "Lookup failed: usr.usr_id for username '$userShortVal' (active)" "ERROR"
            return $false
        }
        $script:dmo_TagRemovalUserId = [long]$r

        # 5. Resolve WFAARCH1 wrkgrp_id
        $cmd = $tempConn.CreateCommand()
        $cmd.CommandText = "SELECT wrkgrp_id FROM crs5_oltp.dbo.wrkgrp WHERE wrkgrp_shrt_nm = 'WFAARCH1'"
        $cmd.CommandTimeout = 30
        $r = $cmd.ExecuteScalar()
        $cmd.Dispose()
        if ($r -is [DBNull] -or $null -eq $r) {
            Write-Log "Lookup failed: wrkgrp.wrkgrp_id for WFAARCH1" "ERROR"
            return $false
        }
        $script:dmo_WfaArch1Id = [long]$r

        # 6. Resolve WFAARCH3 wrkgrp_id
        $cmd = $tempConn.CreateCommand()
        $cmd.CommandText = "SELECT wrkgrp_id FROM crs5_oltp.dbo.wrkgrp WHERE wrkgrp_shrt_nm = 'WFAARCH3'"
        $cmd.CommandTimeout = 30
        $r = $cmd.ExecuteScalar()
        $cmd.Dispose()
        if ($r -is [DBNull] -or $null -eq $r) {
            Write-Log "Lookup failed: wrkgrp.wrkgrp_id for WFAARCH3" "ERROR"
            return $false
        }
        $script:dmo_WfaArch3Id = [long]$r

        Write-Log "  Startup lookups resolved:" "SUCCESS"
        Write-Log "    TC_ARCH tag_id       : $($script:dmo_TcArchTagId)" "INFO"
        Write-Log "    tag_removal_actn_cd  : '$actnShortVal' -> $($script:dmo_TagRemovalActnCd)" "INFO"
        Write-Log "    tag_removal_rslt_cd  : '$rsltShortVal' -> $($script:dmo_TagRemovalRsltCd)" "INFO"
        Write-Log "    tag_removal_user     : '$userShortVal' -> $($script:dmo_TagRemovalUserId)" "INFO"
        Write-Log "    tag_removal_msg_txt  : '$msgTxt'" "INFO"
        Write-Log "    WFAARCH1 wrkgrp_id   : $($script:dmo_WfaArch1Id)" "INFO"
        Write-Log "    WFAARCH3 wrkgrp_id   : $($script:dmo_WfaArch3Id)" "INFO"
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

<# ============================================================================
   FUNCTIONS: SCHEDULE AND CONTROL
   ----------------------------------------------------------------------------
   Schedule-mode lookup, abort-flag check, target-workgroup selection, and the
   BIDATA-build contention check that govern whether and what a batch runs.
   Prefix: dmo
   ============================================================================ #>

# Returns the current hours schedule mode from DmOps.Archive_Schedule.
function Get-dmo_ArchiveScheduleMode {
    param()

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
        Write-Log "  No schedule row found for today - treating as blocked" "WARN"
        return 0
    }
    catch {
        Write-Log "  Failed to read schedule: $($_.Exception.Message) - treating as blocked" "WARN"
        return 0
    }
}

# Returns true when the GlobalConfig archive_abort emergency flag is set.
function Test-dmo_ArchiveAbort {
    param()

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
        Write-Log "  Failed to check abort flag - proceeding cautiously" "WARN"
        return $false
    }
}

# Reads and validates the target_workgroups GlobalConfig setting, returning WFAARCH1, WFAARCH3, or BOTH.
function Get-dmo_TargetWorkgroupsSetting {
    param()

    try {
        $result = Get-SqlData -Query @"
            SELECT setting_value FROM dbo.GlobalConfig
            WHERE module_name = 'DmOps' AND category = 'Archive'
              AND setting_name = 'target_workgroups' AND is_active = 1
"@
        if ($result -and $result.setting_value) {
            $val = ([string]$result.setting_value).Trim().ToUpper()
            if ($val -in @('WFAARCH1', 'WFAARCH3', 'BOTH')) {
                return $val
            }
            Write-Log "  target_workgroups value '$val' not recognized -- defaulting to BOTH" "WARN"
            return 'BOTH'
        }
        Write-Log "  target_workgroups not configured -- defaulting to BOTH" "WARN"
        return 'BOTH'
    }
    catch {
        Write-Log "  Failed to read target_workgroups -- defaulting to BOTH" "WARN"
        return 'BOTH'
    }
}

# Returns the count of TC_ARCH consumers currently in the given workgroup id.
function Get-dmo_WorkgroupRemainingCount {
    param(
        [Parameter(Mandatory)]
        [long]$WorkgroupId
    )

    $countQuery = @"
        SELECT COUNT(*) AS remaining_count
        FROM crs5_oltp.dbo.cnsmr_Tag ct
        INNER JOIN crs5_oltp.dbo.cnsmr c ON c.cnsmr_id = ct.cnsmr_id
        WHERE ct.tag_id = $($script:dmo_TcArchTagId)
          AND ct.cnsmr_tag_sft_delete_flg = 'N'
          AND c.wrkgrp_id = $WorkgroupId
"@
    $result = Invoke-dmo_TargetQuery -Query $countQuery -Timeout 120
    return [long]$result.Rows[0].remaining_count
}

# Decides the single workgroup the next batch targets, honoring the setting and skipping drained workgroups.
function Get-dmo_NextBatchWorkgroup {
    param(
        [Parameter(Mandatory)]
        [string]$TargetSetting
    )

    # Single-workgroup targets: one candidate workgroup, drained-or-not.
    if ($TargetSetting -eq 'WFAARCH1') {
        if ((Get-dmo_WorkgroupRemainingCount -WorkgroupId $script:dmo_WfaArch1Id) -gt 0) { return 'WFAARCH1' }
        return $null
    }
    if ($TargetSetting -eq 'WFAARCH3') {
        if ((Get-dmo_WorkgroupRemainingCount -WorkgroupId $script:dmo_WfaArch3Id) -gt 0) { return 'WFAARCH3' }
        return $null
    }

    # BOTH: prefer the workgroup the last batch did NOT use (alternation),
    # then fall back to the other if the preferred one is empty.
    $preferred = if ($script:dmo_LastWorkgroupUsed -eq 'WFAARCH1') { 'WFAARCH3' } else { 'WFAARCH1' }
    $other     = if ($preferred -eq 'WFAARCH1') { 'WFAARCH3' } else { 'WFAARCH1' }

    $preferredId = if ($preferred -eq 'WFAARCH1') { $script:dmo_WfaArch1Id } else { $script:dmo_WfaArch3Id }
    if ((Get-dmo_WorkgroupRemainingCount -WorkgroupId $preferredId) -gt 0) { return $preferred }

    $otherId = if ($other -eq 'WFAARCH1') { $script:dmo_WfaArch1Id } else { $script:dmo_WfaArch3Id }
    if ((Get-dmo_WorkgroupRemainingCount -WorkgroupId $otherId) -gt 0) { return $other }

    return $null
}

# Returns true when the BIDATA Daily Build SQL Agent job is currently running.
function Test-dmo_BidataBuildInProgress {
    param()

    if (-not $script:dmo_BidataServer) {
        Write-Log "  BIDATA pre-flight: bidata_instance not configured - skipping check" "DEBUG"
        return $false
    }

    try {
        $runDateInt = [int](Get-Date).ToString("yyyyMMdd")
        $jobName = $script:dmo_BidataBuildJobName.Replace("'", "''")

        $result = Get-SqlData -Instance $script:dmo_BidataServer -DatabaseName 'msdb' -Timeout 15 -Query @"
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
        Write-Log "  BIDATA pre-flight: check failed - $($_.Exception.Message). Proceeding cautiously." "WARN"
        return $false
    }
}

<# ============================================================================
   FUNCTIONS: SQL PRIMITIVES
   ----------------------------------------------------------------------------
   Low-level query, delete, and update primitives that run against the persistent
   crs5_oltp connection with snapshot isolation, deadlock retry, and chunking.
   Prefix: dmo
   ============================================================================ #>

# Runs a read query against the persistent crs5_oltp connection and returns a DataTable.
function Invoke-dmo_TargetQuery {
    param(
        [Parameter(Mandatory)]
        [string]$Query,
        [int]$Timeout = 300
    )

    $cmd = $script:dmo_TargetConnection.CreateCommand()
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

# Executes a chunked DELETE against crs5_oltp with snapshot isolation and deadlock retry.
function Invoke-dmo_TargetDelete {
    param(
        [Parameter(Mandatory)]
        [string]$DeleteSQL,
        [int]$Timeout = 600,
        [int]$MaxRetries = 10,
        [int]$RetryDelaySeconds = 5
    )

    $totalRowsDeleted = 0
    $chunkNumber = 0

    $chunkedSQL = $DeleteSQL -replace '(?i)^DELETE\s+(FROM\s+)', "DELETE TOP ($($script:dmo_BatchChunkSize)) `$1"
    $chunkedSQL = $chunkedSQL -replace '(?i)^DELETE\s+(\w+)\s+(FROM\s+)', "DELETE TOP ($($script:dmo_BatchChunkSize)) `$1 `$2"

    while ($true) {
        $chunkNumber++
        $retryCount = 0
        $chunkDeleted = -1

        while ($retryCount -lt $MaxRetries) {
            $cmd = $script:dmo_TargetConnection.CreateCommand()
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
                    Write-Log "      Retryable error ($errNum), attempt $retryCount/$MaxRetries - waiting ${RetryDelaySeconds}s..." "WARN"
                    Start-Sleep -Seconds $RetryDelaySeconds

                    try {
                        $resetCmd = $script:dmo_TargetConnection.CreateCommand()
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

        if ($chunkDeleted -lt $script:dmo_BatchChunkSize) { break }

        Start-Sleep -Milliseconds 100
    }

    return $totalRowsDeleted
}

# Executes a chunked UPDATE against crs5_oltp with snapshot isolation and deadlock retry.
function Invoke-dmo_TargetUpdate {
    param(
        [Parameter(Mandatory)]
        [string]$UpdateSQL,
        [int]$Timeout = 600,
        [int]$MaxRetries = 10,
        [int]$RetryDelaySeconds = 5
    )

    $totalRowsUpdated = 0
    $chunkNumber = 0

    $chunkedSQL = $UpdateSQL -replace '(?i)^UPDATE\s+', "UPDATE TOP ($($script:dmo_BatchChunkSize)) "

    while ($true) {
        $chunkNumber++
        $retryCount = 0
        $chunkUpdated = -1

        while ($retryCount -lt $MaxRetries) {
            $cmd = $script:dmo_TargetConnection.CreateCommand()
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
                    Write-Log "      Retryable error ($errNum), attempt $retryCount/$MaxRetries - waiting ${RetryDelaySeconds}s..." "WARN"
                    Start-Sleep -Seconds $RetryDelaySeconds

                    try {
                        $resetCmd = $script:dmo_TargetConnection.CreateCommand()
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

        if ($chunkUpdated -lt $script:dmo_BatchChunkSize) { break }

        Start-Sleep -Milliseconds 100
    }

    return $totalRowsUpdated
}

<# ============================================================================
   FUNCTIONS: BIDATA MIGRATION
   ----------------------------------------------------------------------------
   Migrate the batchs rows from the BIDATA P tables to their C counterparts
   within a single validated transaction.
   Prefix: dmo
   ============================================================================ #>

# Migrates the current batchs rows from a BIDATA P table to its C table in a single transaction with count validation.
function Invoke-dmo_BidataTableMigration {
    param(
        [Parameter(Mandatory)]
        [string]$SourceTable,
        [Parameter(Mandatory)]
        [string]$DestTable
    )

    $cmd = $script:dmo_BidataConnection.CreateCommand()
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
            $rollbackCmd = $script:dmo_BidataConnection.CreateCommand()
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

<# ============================================================================
   FUNCTIONS: BATCH LOGGING
   ----------------------------------------------------------------------------
   Audit-trail writers for Archive_BatchLog, Archive_BatchDetail,
   Archive_ConsumerLog, and Archive_ConsumerExceptionLog. Each early-returns in
   preview mode, emitting a console line in place of any database write.
   Prefix: dmo
   ============================================================================ #>

# Creates the Archive_BatchLog row for a batch with final counts after selection and re-verification.
function New-dmo_BatchLogEntry {
    param(
        [string]$ScheduleMode,
        [int]$BatchSizeUsed,
        [int]$ExceptionCount = 0,
        [long]$RetryOfBatchId = 0,
        [string]$SourceWorkgroup = $null
    )

    if (-not $script:XFActsExecute) {
        $wgPreview = if ($SourceWorkgroup) { $SourceWorkgroup } else { 'NULL' }
        Write-Log "  [Preview] Would create Archive_BatchLog row (workgroup=$wgPreview schedule=$ScheduleMode size=$BatchSizeUsed exceptions=$ExceptionCount retry_of=$RetryOfBatchId)" "INFO"
        return
    }

    try {
        $wgClause = if ($SourceWorkgroup) { "'$SourceWorkgroup'" } else { "NULL" }
        $result = Get-SqlData -Query @"
            INSERT INTO DmOps.Archive_BatchLog
                (schedule_mode, batch_size_used, exception_count, status, source_workgroup, executed_by)
            OUTPUT INSERTED.batch_id
            VALUES ('$ScheduleMode', $BatchSizeUsed, $ExceptionCount, 'Running', $wgClause, SUSER_SNAME())
"@
        $script:dmo_CurrentBatchId = [long]$result.batch_id

        if ($RetryOfBatchId -gt 0) {
            Invoke-SqlNonQuery -Query @"
                UPDATE DmOps.Archive_BatchLog
                SET batch_retry = 1, retry_batch_id = $($script:dmo_CurrentBatchId)
                WHERE batch_id = $RetryOfBatchId
"@ -Timeout 30 | Out-Null
            Write-Log "  Batch log created: batch_id = $($script:dmo_CurrentBatchId) (retry of batch_id $RetryOfBatchId)" "INFO"
        }
        else {
            Write-Log "  Batch log created: batch_id = $($script:dmo_CurrentBatchId) (exceptions: $ExceptionCount)" "INFO"
        }
    }
    catch {
        Write-Log "  Failed to create batch log: $($_.Exception.Message)" "WARN"
        $script:dmo_CurrentBatchId = $null
    }
}

# Updates the current Archive_BatchLog row with final status, error, and BIDATA status.
function Update-dmo_BatchLogEntry {
    param(
        [string]$Status,
        [string]$ErrorMessage = $null,
        [string]$BidataStatus = $null
    )

    if (-not $script:XFActsExecute) {
        Write-Log "  [Preview] Would finalize Archive_BatchLog (status=$Status bidata=$BidataStatus consumer_count=$($script:dmo_BatchConsumerIds.Count) account_count=$($script:dmo_BatchAccountIds.Count) rows=$($script:dmo_TotalDeleted))" "INFO"
        return
    }

    if (-not $script:dmo_CurrentBatchId) { return }

    $escapedError = if ($ErrorMessage) { $ErrorMessage.Replace("'", "''").Substring(0, [Math]::Min($ErrorMessage.Length, 2000)) } else { $null }
    $errorClause = if ($escapedError) { "'$escapedError'" } else { "NULL" }
    $bidataClause = if ($BidataStatus) { "'$BidataStatus'" } else { "NULL" }

    $durationMs = [int]((Get-Date) - $script:dmo_BatchStartTime).TotalMilliseconds

    try {
        Invoke-SqlNonQuery -Query @"
            UPDATE DmOps.Archive_BatchLog
            SET batch_end_dttm = GETDATE(),
                consumer_count = $($script:dmo_BatchConsumerIds.Count),
                account_count = $($script:dmo_BatchAccountIds.Count),
                total_rows_deleted = $($script:dmo_TotalDeleted),
                tables_processed = $($script:dmo_TablesProcessed),
                tables_skipped = $($script:dmo_TablesSkipped),
                tables_failed = $($script:dmo_TablesFailed),
                duration_ms = $durationMs,
                status = '$Status',
                error_message = $errorClause,
                bidata_status = $bidataClause
            WHERE batch_id = $($script:dmo_CurrentBatchId)
"@ -Timeout 30 | Out-Null
    }
    catch {
        Write-Log "  Failed to update batch log: $($_.Exception.Message)" "WARN"
    }
}

# Inserts one Archive_BatchDetail row recording a single table/pass operation.
function Write-dmo_BatchDetail {
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
    if (-not $script:dmo_CurrentBatchId) { return }

    $escapedPass = if ($PassDescription) { "'$($PassDescription.Replace("'", "''"))'" } else { "NULL" }
    $escapedError = if ($ErrorMessage) { "'$($ErrorMessage.Replace("'", "''").Substring(0, [Math]::Min($ErrorMessage.Length, 2000)))'" } else { "NULL" }
    $durationClause = if ($DurationMs -ge 0) { "$DurationMs" } else { "NULL" }

    try {
        Invoke-SqlNonQuery -Query @"
            INSERT INTO DmOps.Archive_BatchDetail
                (batch_id, delete_order, table_name, pass_description, rows_affected, duration_ms, status, error_message)
            VALUES
                ($($script:dmo_CurrentBatchId), '$DeleteOrder', '$TableName', $escapedPass, $RowsAffected, $durationClause, '$Status', $escapedError)
"@ -Timeout 30 | Out-Null
    }
    catch {
        Write-Log "  Failed to write batch detail: $($_.Exception.Message)" "WARN"
    }
}

# Bulk-inserts Archive_ConsumerLog rows for every consumer/account pair in the batch.
function Write-dmo_ConsumerLog {
    param()

    if (-not $script:XFActsExecute) {
        if ($script:dmo_BatchAccountData.Count -gt 0) {
            Write-Log "  [Preview] Would write $($script:dmo_BatchAccountData.Count) Archive_ConsumerLog rows" "INFO"
        }
        return
    }

    if (-not $script:dmo_CurrentBatchId -or $script:dmo_BatchAccountData.Count -eq 0) { return }

    try {
        for ($i = 0; $i -lt $script:dmo_BatchAccountData.Count; $i += 900) {
            $batch = $script:dmo_BatchAccountData[$i..[Math]::Min($i + 899, $script:dmo_BatchAccountData.Count - 1)]
            $valuesClause = ($batch | ForEach-Object {
                "($($script:dmo_CurrentBatchId), $($_.cnsmr_id), '$($_.cnsmr_idntfr_agncy_id)', $($_.cnsmr_accnt_id), '$($_.cnsmr_accnt_idntfr_agncy_id)', $($_.crdtr_id))"
            }) -join ",`n                "

            Invoke-SqlNonQuery -Query @"
                INSERT INTO DmOps.Archive_ConsumerLog
                    (batch_id, cnsmr_id, cnsmr_idntfr_agncy_id, cnsmr_accnt_id, cnsmr_accnt_idntfr_agncy_id, crdtr_id)
                VALUES
                    $valuesClause
"@ -Timeout 120 | Out-Null
        }

        Write-Log "  Consumer log: $($script:dmo_BatchAccountData.Count) records written" "SUCCESS"
    }
    catch {
        Write-Log "  Failed to write consumer log: $($_.Exception.Message)" "WARN"
    }
}

# Bulk-inserts Archive_ConsumerExceptionLog rows for the batchs re-verification exceptions.
function Write-dmo_ExceptionLog {
    param()

    if (-not $script:XFActsExecute) {
        if ($script:dmo_BatchExceptions.Count -gt 0) {
            Write-Log "  [Preview] Would write $($script:dmo_BatchExceptions.Count) Archive_ConsumerExceptionLog rows" "INFO"
        }
        return
    }

    if (-not $script:dmo_CurrentBatchId -or $script:dmo_BatchExceptions.Count -eq 0) { return }

    try {
        for ($i = 0; $i -lt $script:dmo_BatchExceptions.Count; $i += 900) {
            $batch = $script:dmo_BatchExceptions[$i..[Math]::Min($i + 899, $script:dmo_BatchExceptions.Count - 1)]
            $valuesClause = ($batch | ForEach-Object {
                "($($script:dmo_CurrentBatchId), $($_.cnsmr_id), '$($_.cnsmr_idntfr_agncy_id)', $($_.tag_removed), $($_.ar_event_written))"
            }) -join ",`n                "

            Invoke-SqlNonQuery -Query @"
                INSERT INTO DmOps.Archive_ConsumerExceptionLog
                    (batch_id, cnsmr_id, cnsmr_idntfr_agncy_id, tag_removed, ar_event_written)
                VALUES
                    $valuesClause
"@ -Timeout 120 | Out-Null
        }

        Write-Log "  Exception log: $($script:dmo_BatchExceptions.Count) records written" "SUCCESS"
    }
    catch {
        Write-Log "  Failed to write exception log: $($_.Exception.Message)" "WARN"
    }
}

<# ============================================================================
   FUNCTIONS: RUNTIME RE-VERIFICATION
   ----------------------------------------------------------------------------
   Re-check batch eligibility against current account state, removing and
   logging any consumer that no longer qualifies for archive.
   Prefix: dmo
   ============================================================================ #>

# Runs the inverted apply-job eligibility check for the batch, removing and logging consumers no longer eligible.
function Invoke-dmo_RuntimeReVerification {
    param()

    Write-Log "--- Runtime Re-Verification ---"

    $candidateCount = $script:dmo_BatchConsumerIds.Count
    $script:dmo_BatchExceptions = New-Object System.Collections.Generic.List[PSObject]

    # Run the inverted apply-job query, scoped to this batch
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
        $reVerifyResult = Invoke-dmo_TargetQuery -Query $reVerifyQuery -Timeout 600
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
        $script:dmo_BatchExceptions.Add([PSCustomObject]@{
            cnsmr_id              = [long]$row.cnsmr_id
            wrkgrp_id             = [long]$row.wrkgrp_id
            cnsmr_idntfr_agncy_id = [string]$row.cnsmr_idntfr_agncy_id
            tag_removed           = 0
            ar_event_written      = 0
        })
    }

    # Step 1 (UNCONDITIONAL): Remove excepted consumers from temp table and in-memory list
    # Operates on session-private temp table; safe in preview mode (required so
    # subsequent count queries reflect the post-re-verification batch composition).
    try {
        $exceptedIds = @($script:dmo_BatchExceptions | ForEach-Object { $_.cnsmr_id })

        for ($i = 0; $i -lt $exceptedIds.Count; $i += 900) {
            $endIdx = [Math]::Min($i + 899, $exceptedIds.Count - 1)
            $idList = ($exceptedIds[$i..$endIdx] -join ',')
            $delCmd = $script:dmo_TargetConnection.CreateCommand()
            $delCmd.CommandText = "DELETE FROM #archive_batch_consumers WHERE cnsmr_id IN ($idList)"
            $delCmd.CommandTimeout = 60
            $delCmd.ExecuteNonQuery() | Out-Null
            $delCmd.Dispose()
        }

        $exceptedSet = New-Object 'System.Collections.Generic.HashSet[long]'
        foreach ($eid in $exceptedIds) { [void]$exceptedSet.Add($eid) }
        $newList = New-Object System.Collections.Generic.List[long]
        foreach ($cid in $script:dmo_BatchConsumerIds) {
            if (-not $exceptedSet.Contains($cid)) { $newList.Add($cid) }
        }
        $script:dmo_BatchConsumerIds = $newList

        Write-Log "  Removed $exceptionCount excepted consumers from batch" "INFO"
    }
    catch {
        Write-Log "  Failed to remove excepted consumers from temp table: $($_.Exception.Message)" "ERROR"
        throw $_
    }

    # Step 2 (BEST-EFFORT, EXECUTE MODE ONLY): UPDATE cnsmr_Tag + INSERT cnsmr_accnt_ar_log
    if (-not $script:XFActsExecute) {
        Write-Log "  [Preview] Would soft-delete $exceptionCount TC_ARCH tag rows and write $exceptionCount AR events" "INFO"
    }
    else {
        $msgEscaped = $script:dmo_TagRemovalMsgTxt.Replace("'", "''")
        $writeStart = Get-Date
        $tagsRemoved = 0
        $arEventsWritten = 0

        foreach ($exc in $script:dmo_BatchExceptions) {
            # 2a. UPDATE cnsmr_Tag - soft-delete the active TC_ARCH row
            try {
                $updCmd = $script:dmo_TargetConnection.CreateCommand()
                $updCmd.CommandTimeout = 30
                $updCmd.CommandText = @"
                    UPDATE crs5_oltp.dbo.cnsmr_Tag
                    SET cnsmr_tag_sft_delete_flg = 'Y',
                        upsrt_dttm = GETDATE(),
                        upsrt_trnsctn_nmbr = upsrt_trnsctn_nmbr + 1,
                        upsrt_soft_comp_id = 113,
                        upsrt_usr_id = $($script:dmo_TagRemovalUserId)
                    WHERE cnsmr_id = $($exc.cnsmr_id)
                      AND tag_id = $($script:dmo_TcArchTagId)
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

            # 2b. INSERT cnsmr_accnt_ar_log - CC/CC consumer-level event
            try {
                $insCmd = $script:dmo_TargetConnection.CreateCommand()
                $insCmd.CommandTimeout = 30
                $insCmd.CommandText = @"
                    INSERT INTO crs5_oltp.dbo.cnsmr_accnt_ar_log
                        (cnsmr_id, wrkgrp_id, actn_cd, rslt_cd,
                         cnsmr_accnt_ar_log_crt_usr_id, cnsmr_accnt_ar_mssg_txt,
                         upsrt_dttm, upsrt_soft_comp_id, upsrt_trnsctn_nmbr, upsrt_usr_id)
                    VALUES
                        ($($exc.cnsmr_id), $($exc.wrkgrp_id), $($script:dmo_TagRemovalActnCd), $($script:dmo_TagRemovalRsltCd),
                         $($script:dmo_TagRemovalUserId), '$msgEscaped',
                         GETDATE(), 113, 0, $($script:dmo_TagRemovalUserId))
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

    Write-Log "  Re-verification: $candidateCount candidates, $exceptionCount excepted, $($script:dmo_BatchConsumerIds.Count) proceeding" "SUCCESS"

    return @{
        CandidateCount = $candidateCount
        ExceptionCount = $exceptionCount
        RemainingCount = $script:dmo_BatchConsumerIds.Count
    }
}

<# ============================================================================
   FUNCTIONS: OPERATION WRAPPERS
   ----------------------------------------------------------------------------
   Per-table delete and update operations with logging, error handling, and the
   preview/execute split applied uniformly across the deletion sequence.
   Prefix: dmo
   ============================================================================ #>

# Executes a single-table delete with counting in preview and chunked deletion in execute mode.
function Invoke-dmo_TableDelete {
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
            $countResult = Invoke-dmo_TargetQuery -Query "SELECT COUNT(*) AS row_count FROM $fullTable WHERE $WhereClause" -Timeout 300
            $previewCount = [long]$countResult.Rows[0].row_count
            if ($previewCount -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs 0 -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - would delete $previewCount rows" "INFO"
                $script:dmo_TotalDeleted += $previewCount
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $previewCount -DurationMs 0 -Status 'Success'
            }
            return $true
        }
        catch {
            Write-Log "  [$Order] $TableName$passLabel - count failed: $($_.Exception.Message)" "WARN"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs 0 -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
    else {
        $deleteSQL = "DELETE FROM $fullTable WHERE $WhereClause"
        $deleteStart = Get-Date

        try {
            $rowsDeleted = Invoke-dmo_TargetDelete -DeleteSQL $deleteSQL
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            if ($rowsDeleted -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs $durationMs -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - deleted $rowsDeleted rows (${durationMs}ms)" "SUCCESS"
                $script:dmo_TotalDeleted += $rowsDeleted
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $rowsDeleted -DurationMs $durationMs -Status 'Success'
            }
            return $true
        }
        catch {
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            Write-Log "  [$Order] $TableName$passLabel - FAILED (${durationMs}ms): $($_.Exception.Message)" "ERROR"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs $durationMs -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
}

# Executes a DELETE-with-JOIN operation with counting in preview and chunked deletion in execute mode.
function Invoke-dmo_JoinTableDelete {
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
            $countResult = Invoke-dmo_TargetQuery -Query $CountQuery -Timeout 300
            $previewCount = [long]$countResult.Rows[0].row_count
            if ($previewCount -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs 0 -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - would delete $previewCount rows" "INFO"
                $script:dmo_TotalDeleted += $previewCount
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $previewCount -DurationMs 0 -Status 'Success'
            }
            return $true
        }
        catch {
            Write-Log "  [$Order] $TableName$passLabel - count failed: $($_.Exception.Message)" "WARN"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs 0 -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
    else {
        $deleteStart = Get-Date
        try {
            $rowsDeleted = Invoke-dmo_TargetDelete -DeleteSQL $DeleteStatement
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            if ($rowsDeleted -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs $durationMs -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - deleted $rowsDeleted rows (${durationMs}ms)" "SUCCESS"
                $script:dmo_TotalDeleted += $rowsDeleted
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $rowsDeleted -DurationMs $durationMs -Status 'Success'
            }
            return $true
        }
        catch {
            $durationMs = [int]((Get-Date) - $deleteStart).TotalMilliseconds
            Write-Log "  [$Order] $TableName$passLabel - FAILED (${durationMs}ms): $($_.Exception.Message)" "ERROR"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs $durationMs -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
}

# Executes a single-table update with counting in preview and chunked update in execute mode.
function Invoke-dmo_TableUpdate {
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
            $countResult = Invoke-dmo_TargetQuery -Query $CountQuery -Timeout 300
            $previewCount = [long]$countResult.Rows[0].row_count
            if ($previewCount -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs 0 -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - would update $previewCount rows" "INFO"
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $previewCount -DurationMs 0 -Status 'Success'
            }
            return $true
        }
        catch {
            Write-Log "  [$Order] $TableName$passLabel - count failed: $($_.Exception.Message)" "WARN"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs 0 -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
    else {
        $updateStart = Get-Date
        try {
            $rowsUpdated = Invoke-dmo_TargetUpdate -UpdateSQL $UpdateStatement
            $durationMs = [int]((Get-Date) - $updateStart).TotalMilliseconds
            if ($rowsUpdated -eq 0) {
                Write-Log "  [$Order] $TableName$passLabel - no rows, skipping" "DEBUG"
                $script:dmo_TablesSkipped++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected 0 -DurationMs $durationMs -Status 'Skipped'
            } else {
                Write-Log "  [$Order] $TableName$passLabel - updated $rowsUpdated rows (${durationMs}ms)" "SUCCESS"
                $script:dmo_TablesProcessed++
                Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                    -RowsAffected $rowsUpdated -DurationMs $durationMs -Status 'Success'
            }
            return $true
        }
        catch {
            $durationMs = [int]((Get-Date) - $updateStart).TotalMilliseconds
            Write-Log "  [$Order] $TableName$passLabel - FAILED (${durationMs}ms): $($_.Exception.Message)" "ERROR"
            $script:dmo_TablesFailed++
            Write-dmo_BatchDetail -DeleteOrder "$Order" -TableName $TableName -PassDescription $PassDescription `
                -RowsAffected 0 -DurationMs $durationMs -Status 'Failed' -ErrorMessage $_.Exception.Message
            return $false
        }
    }
}

<# ============================================================================
   FUNCTIONS: STEP WRAPPERS
   ----------------------------------------------------------------------------
   Thin wrappers over the operation functions that set the stop flag on failure
   so the batch halts safely at the first error.
   Prefix: dmo
   ============================================================================ #>

# Wraps Invoke-dmo_TableDelete, setting the stop flag on failure.
function Step-dmo_Delete {
    param([hashtable]$Params)
    if ($script:dmo_StopProcessing) { return }
    $ok = Invoke-dmo_TableDelete @Params -PreviewOnly (-not $script:XFActsExecute)
    if (-not $ok) {
        Write-Log "  STOPPING - cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $script:dmo_StopProcessing = $true
    }
}

# Wraps Invoke-dmo_JoinTableDelete, setting the stop flag on failure.
function Step-dmo_JoinDelete {
    param([hashtable]$Params)
    if ($script:dmo_StopProcessing) { return }
    $ok = Invoke-dmo_JoinTableDelete @Params -PreviewOnly (-not $script:XFActsExecute)
    if (-not $ok) {
        Write-Log "  STOPPING - cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $script:dmo_StopProcessing = $true
    }
}

# Wraps Invoke-dmo_TableUpdate, setting the stop flag on failure.
function Step-dmo_Update {
    param([hashtable]$Params)
    if ($script:dmo_StopProcessing) { return }
    $ok = Invoke-dmo_TableUpdate @Params -PreviewOnly (-not $script:XFActsExecute)
    if (-not $ok) {
        Write-Log "  STOPPING - cannot safely continue after failure at order $($Params.Order)" "ERROR"
        $script:dmo_StopProcessing = $true
    }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Loads configuration, opens the persistent connections, and runs the
   schedule-driven batch loop end to end, then reports the session summary.
   Prefix: (none)
   ============================================================================ #>

$scriptStart = Get-Date

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  xFACts DM Consumer Archive (Unified)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# STEP 1: Load Configuration & Pre-Flight Checks

Write-Log "--- Step 1: Configuration ---"

if (Test-dmo_ArchiveAbort) {
    Write-Log "Archive abort flag is set - exiting immediately" "WARN"
    exit 0
}

# Target instance
if ([string]::IsNullOrEmpty($TargetInstance)) {
    $configResult = Get-SqlData -Query @"
        SELECT setting_value FROM dbo.GlobalConfig
        WHERE module_name = 'DmOps' AND category = 'Archive'
          AND setting_name = 'target_instance' AND is_active = 1
"@
    if ($configResult) {
        $script:dmo_TargetServer = $configResult.setting_value
    } else {
        Write-Log "No target_instance configured in GlobalConfig (DmOps.Archive)" "ERROR"
        exit 1
    }
} else {
    $script:dmo_TargetServer = $TargetInstance
}

# ServerRegistry enable check (skip if manual target override)
if ([string]::IsNullOrEmpty($TargetInstance)) {
    $enabledResult = Get-SqlData -Query @"
        SELECT dmops_archive_enabled
        FROM dbo.ServerRegistry
        WHERE server_name = '$($script:dmo_TargetServer)'
"@
    if (-not $enabledResult -or $enabledResult.dmops_archive_enabled -ne 1) {
        Write-Log "Archive is disabled on $($script:dmo_TargetServer) (ServerRegistry.dmops_archive_enabled)" "WARN"
        exit 0
    }
}

# GlobalConfig settings
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

if ($configMap.ContainsKey('batch_size'))            { $script:dmo_BatchSizeFull       = [int]$configMap['batch_size'] }
if ($configMap.ContainsKey('batch_size_reduced'))    { $script:dmo_BatchSizeReduced    = [int]$configMap['batch_size_reduced'] }
if ($configMap.ContainsKey('chunk_size'))            { $script:dmo_BatchChunkSize      = [int]$configMap['chunk_size'] }
if ($configMap.ContainsKey('bidata_instance'))       { $script:dmo_BidataServer        = $configMap['bidata_instance'] }
if ($configMap.ContainsKey('alerting_enabled'))      { $script:dmo_AlertingEnabled     = $configMap['alerting_enabled'] -eq '1' }
if ($configMap.ContainsKey('bidata_build_job_name')) { $script:dmo_BidataBuildJobName  = $configMap['bidata_build_job_name'] }

# Initial target workgroup selection from GlobalConfig (re-read between batches
# via Get-dmo_TargetWorkgroupsSetting). Validated; unrecognized/missing -> BOTH.
if ($configMap.ContainsKey('target_workgroups')) {
    $tw = ([string]$configMap['target_workgroups']).Trim().ToUpper()
    if ($tw -in @('WFAARCH1', 'WFAARCH3', 'BOTH')) {
        $script:dmo_TargetWorkgroups = $tw
    } else {
        Write-Log "  target_workgroups value '$tw' not recognized -- defaulting to BOTH" "WARN"
        $script:dmo_TargetWorkgroups = 'BOTH'
    }
} else {
    $script:dmo_TargetWorkgroups = 'BOTH'
}

if ($ChunkSize -gt 0) { $script:dmo_BatchChunkSize = $ChunkSize }

if ($BatchSize -gt 0) {
    $script:dmo_ManualBatchSize = $true
    $script:dmo_ScheduleMode = 'Manual'
    $activeBatchSize = $BatchSize
    Write-Log "  Manual batch size override: $BatchSize" "INFO"
} else {
    $scheduleValue = Get-dmo_ArchiveScheduleMode
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

if (Test-dmo_BidataBuildInProgress) {
    Write-Log "BIDATA Daily Build is in progress on $($script:dmo_BidataServer) - exiting to avoid contention" "WARN"
    exit 0
}

if (-not (Resolve-dmo_StartupLookups -ConfigMap $configMap)) {
    Write-Log "Startup lookup resolution failed - exiting" "ERROR"
    exit 1
}

Write-Log "  Target Instance : $($script:dmo_TargetServer)"
Write-Log "  BIDATA Instance : $(if ($script:dmo_BidataServer) { $script:dmo_BidataServer } else { '(not configured)' })"
Write-Log "  xFACts Instance : $ServerInstance"
Write-Log "  Schedule Mode   : $($script:dmo_ScheduleMode)"
Write-Log "  Batch Size      : $activeBatchSize consumers"
Write-Log "  Target WG(s)    : $($script:dmo_TargetWorkgroups)"
Write-Log "  Chunk Size      : $($script:dmo_BatchChunkSize) rows per delete"
Write-Log "  Anonymize       : $(if (-not $NoAnonymize) { 'Yes' } else { 'No (testing mode)' })"
Write-Log "  Alerting        : $(if ($script:dmo_AlertingEnabled) { 'Enabled' } else { 'Disabled' })"
Write-Log "  Loop Mode       : $(if ($SingleBatch) { 'Single batch' } else { 'Continuous' })"
Write-Log ""

# STEP 2: Open Persistent Connections (target + BIDATA)

Write-Log "--- Step 2: Open Connections ---"

if (-not (Open-dmo_TargetConnection)) {
    if ($TaskId -gt 0) {
        $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs $totalMs `
            -ErrorMessage "Failed to open connection to target instance"
    }
    exit 1
}

# BIDATA connection opened up-front when in execute mode - required mid-batch.
# In preview mode no BIDATA writes occur so we skip this entirely.
if ($script:dmo_BidataServer -and $script:XFActsExecute) {
    if (-not (Open-dmo_BidataConnection)) {
        Close-dmo_TargetConnection
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

# BATCH LOOP

$continueProcessing = $true

while ($continueProcessing) {

# Reset per-batch counters
$script:dmo_TotalDeleted = 0
# Tables successfully processed this batch.
$script:dmo_TablesProcessed = 0
# Tables skipped (zero rows) this batch.
$script:dmo_TablesSkipped = 0
# Tables that failed this batch.
$script:dmo_TablesFailed = 0
# Consumer ids selected for the current batch.
$script:dmo_BatchConsumerIds = @()
# Account ids expanded from the current batch consumers.
$script:dmo_BatchAccountIds = @()
# Per-account data rows for the current batch.
$script:dmo_BatchAccountData = @()
# Consumers excepted by re-verification this batch.
$script:dmo_BatchExceptions = @()
# Set true to halt the batch after a failure.
$script:dmo_StopProcessing = $false
# Start timestamp of the current batch.
$script:dmo_BatchStartTime = Get-Date
# Outcome of the BIDATA migration for the current batch.
$script:dmo_BidataStatus = $null
# Original batch_id when the current batch is a retry.
$script:dmo_RetryOfBatchId = 0
$script:dmo_BatchWorkgroup = $null

$script:dmo_TotalBatchesRun++

# STEP 3: Select Batch (Retry or New TC_ARCH Selection)

# Check for unresolved failed batches
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
    # ==================================================================
    # RETRY PATH: Load batch from ConsumerLog for failed batch
    # Retry skips re-verification - past the point of no return.
    # ==================================================================

    $script:dmo_RetryOfBatchId = $failedBatchId

    # Retry inherits the original batch's workgroup so the retry row is
    # attributed to the same line of business. NULL on pre-split historical
    # batches is inherited as-is (correct: they predate the workgroup split).
    $script:dmo_BatchWorkgroup = $null
    try {
        $origWg = Get-SqlData -Query @"
            SELECT source_workgroup
            FROM DmOps.Archive_BatchLog
            WHERE batch_id = $failedBatchId
"@
        if ($origWg -and $origWg.source_workgroup -and $origWg.source_workgroup -isnot [DBNull]) {
            $script:dmo_BatchWorkgroup = [string]$origWg.source_workgroup
        }
    }
    catch {
        Write-Log "  Could not read source_workgroup for failed batch $failedBatchId -- retry will record NULL workgroup" "WARN"
    }

    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host "  RETRY Batch #$($script:dmo_TotalBatchesRun) — retrying failed batch_id $failedBatchId" -ForegroundColor Yellow
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
        Write-Log "  Cannot retry - stopping" "ERROR"
        Close-dmo_BidataConnection
        Close-dmo_TargetConnection
        exit 1
    }

    $retryRows = if ($retryData -is [System.Data.DataTable]) { @($retryData.Rows) } else { @($retryData) }

    if ($retryRows.Count -eq 0) {
        Write-Log "  No ConsumerLog records found for batch $failedBatchId - cannot retry" "ERROR"
        Close-dmo_BidataConnection
        Close-dmo_TargetConnection
        exit 1
    }

    $script:dmo_BatchConsumerIds = New-Object System.Collections.Generic.List[long]
    $script:dmo_BatchAccountIds = New-Object System.Collections.Generic.List[long]
    $script:dmo_BatchAccountData = New-Object System.Collections.Generic.List[PSObject]

    foreach ($row in $retryRows) {
        $cid = [long]$row.cnsmr_id
        if (-not $script:dmo_BatchConsumerIds.Contains($cid)) {
            $script:dmo_BatchConsumerIds.Add($cid)
        }
        $script:dmo_BatchAccountIds.Add([long]$row.cnsmr_accnt_id)
        $script:dmo_BatchAccountData.Add([PSCustomObject]@{
            cnsmr_id                    = $cid
            cnsmr_idntfr_agncy_id       = [string]$row.cnsmr_idntfr_agncy_id
            cnsmr_accnt_id              = [long]$row.cnsmr_accnt_id
            cnsmr_accnt_idntfr_agncy_id = [string]$row.cnsmr_accnt_idntfr_agncy_id
            crdtr_id                    = [long]$row.crdtr_id
        })
    }

    Write-Log "  Loaded $($script:dmo_BatchConsumerIds.Count) consumers, $($script:dmo_BatchAccountIds.Count) accounts from ConsumerLog" "INFO"
}
else {
    # ==================================================================
    # NORMAL PATH: Select TC_ARCH-tagged candidates (TOP-N) for one
    # workgroup (line of business). The workgroup is chosen per batch,
    # drain-aware, honoring the current target_workgroups setting.
    # ==================================================================

    # Re-read the target setting fresh so a mid-run change (badges / modal)
    # takes effect at this batch boundary, then pick this batch's workgroup.
    $script:dmo_TargetWorkgroups = Get-dmo_TargetWorkgroupsSetting
    $batchWorkgroup = Get-dmo_NextBatchWorkgroup -TargetSetting $script:dmo_TargetWorkgroups

    if ($null -eq $batchWorkgroup) {
        Write-Log "No TC_ARCH candidates remain in targeted workgroup(s) [$($script:dmo_TargetWorkgroups)] -- work complete" "INFO"
        $continueProcessing = $false
        break
    }

    $script:dmo_BatchWorkgroup = $batchWorkgroup
    $batchWorkgroupId = if ($batchWorkgroup -eq 'WFAARCH1') { $script:dmo_WfaArch1Id } else { $script:dmo_WfaArch3Id }

    Write-Host ""
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  Batch #$($script:dmo_TotalBatchesRun) -- $($script:dmo_ScheduleMode) mode ($activeBatchSize consumers) -- $batchWorkgroup" -ForegroundColor DarkCyan
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host ""

    Write-Log "--- Step 3: Select Batch ($batchWorkgroup) ---"

    # Trust the TC_ARCH tag at selection time, scoped to this batch's
    # workgroup. Step 5 does the rigorous eligibility re-verification
    # against the apply-job logic.
    $batchQuery = @"
        SELECT TOP ($activeBatchSize) ct.cnsmr_id
        FROM crs5_oltp.dbo.cnsmr_Tag ct
        INNER JOIN crs5_oltp.dbo.cnsmr c ON c.cnsmr_id = ct.cnsmr_id
        WHERE ct.tag_id = $($script:dmo_TcArchTagId)
          AND ct.cnsmr_tag_sft_delete_flg = 'N'
          AND c.wrkgrp_id = $batchWorkgroupId
        ORDER BY ct.cnsmr_id
"@

    try {
        $batchResult = Invoke-dmo_TargetQuery -Query $batchQuery
    }
    catch {
        Write-Log "Failed to select batch: $($_.Exception.Message)" "ERROR"
        Close-dmo_BidataConnection
        Close-dmo_TargetConnection
        exit 1
    }

    if ($batchResult.Rows.Count -eq 0) {
        # Defensive: Get-dmo_NextBatchWorkgroup already confirmed candidates exist,
        # but a concurrent change could empty the workgroup between the check
        # and the select. Treat as drained for this iteration and re-evaluate.
        Write-Log "  $batchWorkgroup returned no candidates at selection -- re-evaluating next iteration" "WARN"
        $script:dmo_LastWorkgroupUsed = $batchWorkgroup
        continue
    }

    $script:dmo_BatchConsumerIds = New-Object System.Collections.Generic.List[long]
    foreach ($row in $batchResult.Rows) {
        $script:dmo_BatchConsumerIds.Add([long]$row.cnsmr_id)
    }

    # Record which workgroup this batch used so BOTH-mode alternation can
    # switch to the other workgroup on the next iteration.
    $script:dmo_LastWorkgroupUsed = $batchWorkgroup

    Write-Log "  Selected $($script:dmo_BatchConsumerIds.Count) TC_ARCH candidates from $batchWorkgroup" "INFO"
}

# STEP 4: Create Core Temp Tables and Populate Consumer IDs
# Both paths (retry and normal) need #archive_batch_consumers populated
# before re-verification can run. Account temp table is empty for now -
# populated in Step 6 after re-verification trims the consumer set.

Write-Log "--- Step 4: Create Core Temp Tables ---"

$createTableSQL = @"
    IF OBJECT_ID('tempdb..#archive_batch_accounts') IS NOT NULL DROP TABLE #archive_batch_accounts;
    IF OBJECT_ID('tempdb..#archive_batch_consumers') IS NOT NULL DROP TABLE #archive_batch_consumers;
    CREATE TABLE #archive_batch_accounts (cnsmr_accnt_id BIGINT PRIMARY KEY);
    CREATE TABLE #archive_batch_consumers (cnsmr_id BIGINT PRIMARY KEY);
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
        $insertCmd.CommandText = "INSERT INTO #archive_batch_consumers (cnsmr_id) VALUES $valuesClause"
        $insertCmd.CommandTimeout = 30
        $insertCmd.ExecuteNonQuery() | Out-Null
        $insertCmd.Dispose()
    }

    Write-Log "  Core temp tables created; $($script:dmo_BatchConsumerIds.Count) consumers loaded" "SUCCESS"
}
catch {
    Write-Log "Failed to create core temp tables: $($_.Exception.Message)" "ERROR"
    Close-dmo_BidataConnection
    Close-dmo_TargetConnection
    exit 1
}

Write-Log ""

# STEP 5: Runtime Re-Verification (skipped on retry)

if ($script:dmo_RetryOfBatchId -eq 0) {
    try {
        $reVerifyResult = Invoke-dmo_RuntimeReVerification
    }
    catch {
        Write-Log "Re-verification failed catastrophically: $($_.Exception.Message)" "ERROR"
        Close-dmo_BidataConnection
        Close-dmo_TargetConnection
        exit 1
    }

    # Handle all-excepted batch - no consumers remaining to process
    if ($script:dmo_BatchConsumerIds.Count -eq 0) {
        Write-Log "  All $($reVerifyResult.CandidateCount) candidates were excepted - finalizing batch as Success with consumer_count=0" "WARN"

        # Create BatchLog row to record the all-excepted batch for audit (execute mode only)
        $batchSizeUsed = $reVerifyResult.CandidateCount
        New-dmo_BatchLogEntry -ScheduleMode $script:dmo_ScheduleMode -BatchSizeUsed $batchSizeUsed `
            -ExceptionCount $reVerifyResult.ExceptionCount -RetryOfBatchId 0 `
            -SourceWorkgroup $script:dmo_BatchWorkgroup
        Write-dmo_ExceptionLog
        Update-dmo_BatchLogEntry -Status 'Success' -BidataStatus 'Skipped'

        $script:dmo_SessionTotalExceptions += $reVerifyResult.ExceptionCount

        # Continue to next batch (still bound by SingleBatch / abort / schedule)
        if ($SingleBatch) {
            Write-Log "  Single batch mode - exiting loop" "INFO"
            $continueProcessing = $false
        }
        elseif (Test-dmo_ArchiveAbort) {
            Write-Log "  Archive abort flag detected - stopping after batch completion" "WARN"
            $continueProcessing = $false
        }
        else {
            $nextScheduleValue = Get-dmo_ArchiveScheduleMode
            if ($nextScheduleValue -eq 0) {
                Write-Log "  Schedule: now in BLOCKED window - stopping" "INFO"
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
    Write-Log "--- Step 5: Skipped (retry path - consumers already cleared by prior batch) ---"
}

Write-Log ""

# STEP 6: Expand Accounts, Materialize Account-Level Temp Tables, Create BatchLog

Write-Log "--- Step 6: Load Account-Level Temp Tables ---"

# Expand consumers to account IDs
if ($script:dmo_RetryOfBatchId -gt 0) {
    # Retry path: load accounts from ConsumerLog data (already in $script:dmo_BatchAccountIds)
    try {
        for ($i = 0; $i -lt $script:dmo_BatchAccountIds.Count; $i += 900) {
            $batch = $script:dmo_BatchAccountIds[$i..[Math]::Min($i + 899, $script:dmo_BatchAccountIds.Count - 1)]
            $valuesClause = ($batch | ForEach-Object { "($_)" }) -join ','
            $insertCmd = $script:dmo_TargetConnection.CreateCommand()
            $insertCmd.CommandText = "INSERT INTO #archive_batch_accounts (cnsmr_accnt_id) VALUES $valuesClause"
            $insertCmd.CommandTimeout = 30
            $insertCmd.ExecuteNonQuery() | Out-Null
            $insertCmd.Dispose()
        }
        Write-Log "  Account temp table loaded (retry): $($script:dmo_BatchConsumerIds.Count) consumers, $($script:dmo_BatchAccountIds.Count) accounts" "SUCCESS"
    }
    catch {
        Write-Log "Failed to load account temp table: $($_.Exception.Message)" "ERROR"
        Close-dmo_BidataConnection
        Close-dmo_TargetConnection
        exit 1
    }
}
else {
    # Normal path: re-expand against the post-re-verification trimmed consumer set.
    # No tag filter on cnsmr_accnt - at consumer level we archive everything
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
        $accountResult = Invoke-dmo_TargetQuery -Query $accountQuery
    }
    catch {
        Write-Log "Failed to expand accounts: $($_.Exception.Message)" "ERROR"
        Close-dmo_BidataConnection
        Close-dmo_TargetConnection
        exit 1
    }

    $script:dmo_BatchAccountIds = New-Object System.Collections.Generic.List[long]
    $script:dmo_BatchAccountData = New-Object System.Collections.Generic.List[PSObject]

    foreach ($row in $accountResult.Rows) {
        $script:dmo_BatchAccountIds.Add([long]$row.cnsmr_accnt_id)
        $script:dmo_BatchAccountData.Add([PSCustomObject]@{
            cnsmr_id                    = [long]$row.cnsmr_id
            cnsmr_idntfr_agncy_id       = [string]$row.cnsmr_idntfr_agncy_id
            cnsmr_accnt_id              = [long]$row.cnsmr_accnt_id
            cnsmr_accnt_idntfr_agncy_id = [string]$row.cnsmr_accnt_idntfr_agncy_id
            crdtr_id                    = [long]$row.crdtr_id
        })
    }

    Write-Log "  Expanded to $($script:dmo_BatchAccountIds.Count) accounts" "INFO"

    # Load account IDs into #archive_batch_accounts
    if ($script:dmo_BatchAccountIds.Count -gt 0) {
        try {
            $acctCmd = $script:dmo_TargetConnection.CreateCommand()
            $acctCmd.CommandText = @"
                INSERT INTO #archive_batch_accounts (cnsmr_accnt_id)
                SELECT DISTINCT ca.cnsmr_accnt_id
                FROM crs5_oltp.dbo.cnsmr_accnt ca
                INNER JOIN #archive_batch_consumers bc ON ca.cnsmr_id = bc.cnsmr_id
"@
            $acctCmd.CommandTimeout = 60
            $acctInserted = $acctCmd.ExecuteNonQuery()
            $acctCmd.Dispose()

            Write-Log "  Account temp table loaded: $($script:dmo_BatchConsumerIds.Count) consumers, $acctInserted accounts" "SUCCESS"
        }
        catch {
            Write-Log "Failed to load account temp table: $($_.Exception.Message)" "ERROR"
            Close-dmo_BidataConnection
            Close-dmo_TargetConnection
            exit 1
        }
    }
    else {
        Write-Log "  Consumers have zero accounts (degenerate shell case) - proceeding to consumer-level deletes only" "WARN"
    }
}

# Create batch log entry (now that all counts are final)
$useScheduleMode = if ($script:dmo_RetryOfBatchId -gt 0) { 'Retry' } else { $script:dmo_ScheduleMode }
$useBatchSize = if ($script:dmo_RetryOfBatchId -gt 0) {
    $script:dmo_BatchConsumerIds.Count
} else {
    # batch_size_used = consumer_count + exception_count (post-re-verification invariant)
    $script:dmo_BatchConsumerIds.Count + $script:dmo_BatchExceptions.Count
}
$useExceptionCount = $script:dmo_BatchExceptions.Count
New-dmo_BatchLogEntry -ScheduleMode $useScheduleMode -BatchSizeUsed $useBatchSize `
    -ExceptionCount $useExceptionCount -RetryOfBatchId $script:dmo_RetryOfBatchId `
    -SourceWorkgroup $script:dmo_BatchWorkgroup

# Write consumer log and exception log (execute mode only - both functions guard internally)
Write-dmo_ConsumerLog
Write-dmo_ExceptionLog

# Pre-materialize account-level intermediate ID tables
if ($script:dmo_BatchAccountIds.Count -gt 0) {
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
        $cmd = $script:dmo_TargetConnection.CreateCommand()
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
        Update-dmo_BatchLogEntry -Status 'Failed' -ErrorMessage "Account-level temp table creation failed: $($_.Exception.Message)"
        Close-dmo_BidataConnection
        Close-dmo_TargetConnection
        exit 1
    }
}
else {
    # Degenerate case: zero accounts - skip materialization, set counts to 0
    $arLogCount = 0
    $trnsctnCount = 0
    $pmtjrnlCount = 0
    $pmtjrnlTrnsctnCount = 0
    $encntrCount = 0
    Write-Log "  Skipping account-level materialization - no accounts to process" "INFO"
}

Write-Log ""
# STEP 7: Execute Account-Level Deletions (Phase 1 UDEFs AU* + Phase 2 A1-A117)

if ($script:dmo_BatchAccountIds.Count -eq 0) {
    Write-Log "--- Step 7: Skipped (no accounts to delete) ---"
    Write-Log ""
}
else {
    Write-Log "--- Step 7: Execute Account-Level Deletions ---"
    Write-Log ""

    $script:dmo_StopProcessing = $false

    # Account-level where-clause variables
    $wAcct       = "cnsmr_accnt_id IN (SELECT cnsmr_accnt_id FROM #archive_batch_accounts)"
    $wArLog      = "cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
    $wTrnsctn    = "cnsmr_accnt_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_trnsctn_ids)"
    $wPmtJrnl    = "cnsmr_accnt_pymnt_jrnl_id IN (SELECT cnsmr_accnt_pymnt_jrnl_id FROM #batch_pmtjrnl_ids)"
    $wPmtTrnsctn = "cnsmr_accnt_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_pmtjrnl_trnsctn_ids)"
    $wEncntr     = "hc_encntr_id IN (SELECT hc_encntr_id FROM #batch_encntr_ids)"
    $wPrgrmPlan  = "hc_prgrm_plan_id IN (SELECT hc_prgrm_plan_id FROM crs5_oltp.dbo.hc_prgrm_plan WHERE $wEncntr)"

    # Phase 1: Account-Level UDEF Tables (Dynamic Discovery)
    Write-Log "  Phase 1: Account-Level UDEF Tables (dynamic)" "INFO"

    try {
        $udefAcctResult = Invoke-dmo_TargetQuery -Query @"
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
        $script:dmo_StopProcessing = $true
    }

    if (-not $script:dmo_StopProcessing) {
        $udefOrder = 0
        foreach ($udefTable in $udefAcctTables) {
            $udefOrder++
            Step-dmo_Delete @{Order="AU$udefOrder"; TableName=$udefTable; WhereClause=$wAcct}
        }
    }

    Write-Log ""

    # Phase 2: Account-Level Tables (orders A1-A117)
    Write-Log "  Phase 2: Account-Level Tables" "INFO"

    Step-dmo_Delete @{Order='A1'; TableName='rcvr_autoassign_grp_log'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A2'; TableName='dfrrd_cnsmr_accnt'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A3'; TableName='hc_dfrrd_prgrm_plan'; WhereClause="hc_prgrm_plan_id IN (SELECT hc_prgrm_plan_id FROM crs5_oltp.dbo.hc_prgrm_plan WHERE $wEncntr)"}
    Step-dmo_Delete @{Order='A4'; TableName='invc_crrctn_dtl_stgng'; WhereClause="invc_crrctn_trnsctn_stgng_id IN (SELECT invc_crrctn_trnsctn_stgng_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn_stgng WHERE $wTrnsctn)"}
    Step-dmo_Delete @{Order='A5'; TableName='invc_crrctn_trnsctn_stgng'; WhereClause=$wTrnsctn}
    Step-dmo_Delete @{Order='A6'; TableName='hc_prgrm_plan_trnsctn_log'; WhereClause="hc_prgrm_plan_id IN (SELECT hc_prgrm_plan_id FROM crs5_oltp.dbo.hc_prgrm_plan WHERE $wEncntr)"}
    Step-dmo_Delete @{Order='A7'; TableName='cnsmr_accnt_rndm_nmbr'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A8'; TableName='cnsmr_accnt_strtgy_log'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A9'; TableName='cnsmr_accnt_strtgy_wrk_actn'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A10'; TableName='cnsmr_accnt_wrkgrp_assctn'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A11'; TableName='cnsmr_accnt_srvc_rqst'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A12'; TableName='cnsmr_accnt_rehab_pymnt_optn'; WhereClause="cnsmr_accnt_rehab_dtl_id IN (SELECT cnsmr_accnt_rehab_dtl_id FROM crs5_oltp.dbo.cnsmr_accnt_rehab_dtl WHERE $wAcct)"}
    Step-dmo_Delete @{Order='A13'; TableName='cnsmr_accnt_rehab_pymnt_tier'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A14'; TableName='cnsmr_accnt_rehab_dtl'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A15'; TableName='rcvr_sttmnt_pndng_trnsctn_dtl'; WhereClause=$wTrnsctn}
    Step-dmo_Delete @{Order='A16'; TableName='cnsmr_accnt_wrk_actn'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A17'; TableName='cnsmr_accnt_frwrd_rcll_dtl'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A18'; TableName='cnsmr_accnt_bckt_sttlmnt'; WhereClause="cnsmr_accnt_sttlmnt_id IN (SELECT cnsmr_accnt_sttlmnt_id FROM crs5_oltp.dbo.cnsmr_accnt_Sttlmnt WHERE $wAcct)"; PassDescription='Pass 1: via direct sttlmnt'}
    Step-dmo_Delete @{Order='A19'; TableName='cnsmr_accnt_Sttlmnt'; WhereClause=$wAcct; PassDescription='Pass 1: direct'}
    Step-dmo_Delete @{Order='A20'; TableName='cnsmr_accnt_loan_dtl_wrk_actn'; WhereClause="cnsmr_accnt_loan_dtl_id IN (SELECT cnsmr_accnt_loan_dtl_id FROM crs5_oltp.dbo.cnsmr_accnt_loan_dtl WHERE $wAcct)"}
    Step-dmo_Delete @{Order='A21'; TableName='cnsmr_accnt_loan_dtl'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A22'; TableName='cnsmr_Accnt_Tag'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A23'; TableName='rcvr_fnncl_trnsctn_exprt_dtl'; WhereClause=$wTrnsctn; PassDescription='Pass 1: via direct trnsctn'}
    Step-dmo_Delete @{Order='A24'; TableName='rcvr_sttmnt_of_accnt_dtl'; WhereClause=$wTrnsctn; PassDescription='Pass 1: via direct trnsctn'}
    Step-dmo_Delete @{Order='A25'; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause="crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct)"; PassDescription='Pass 1: via crdtr_trnsctn'}
    Step-dmo_Delete @{Order='A26'; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause=$wTrnsctn; PassDescription='Pass 2: via cnsmr_accnt_trnsctn'}
    Step-dmo_Delete @{Order='A27'; TableName='invc_crrctn_dtl'; WhereClause="invc_crrctn_trnsctn_id IN (SELECT invc_crrctn_trnsctn_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn WHERE $wTrnsctn)"}
    Step-dmo_Delete @{Order='A28'; TableName='invc_crrctn_trnsctn'; WhereClause=$wTrnsctn}
    Step-dmo_Delete @{Order='A29'; TableName='wash_assctn'; WhereClause="wash_assctn_pymnt_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_trnsctn_ids)"; PassDescription='Pass 1: payment side'}
    Step-dmo_Delete @{Order='A30'; TableName='wash_assctn'; WhereClause="wash_assctn_nsf_trnsctn_id IN (SELECT cnsmr_accnt_trnsctn_id FROM #batch_trnsctn_ids)"; PassDescription='Pass 2: NSF side'}
    Step-dmo_Delete @{Order='A31'; TableName='cnsmr_accnt_crdt_bru_cnfg'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A32'; TableName='cnsmr_accnt_trnsctn'; WhereClause=$wAcct; PassDescription='Pass 1: direct'}
    Step-dmo_Delete @{Order='A33'; TableName='cb_rpt_assctd_cnsmr_data'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A34'; TableName='cb_rpt_base_data'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A35'; TableName='cb_rpt_emplyr_data'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A36'; TableName='cnsmr_accnt_cnfg'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A37'; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause="tax_jrsdctn_trnsctn_id IN (SELECT tax_jrsdctn_trnsctn_id FROM crs5_oltp.dbo.tax_jrsdctn_trnsctn WHERE $wTrnsctn)"; PassDescription='Pass 3: via tax_jrsdctn_trnsctn (cnsmr_accnt_trnsctn path)'}
    Step-dmo_Delete @{Order='A38'; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause="tax_jrsdctn_trnsctn_id IN (SELECT tax_jrsdctn_trnsctn_id FROM crs5_oltp.dbo.tax_jrsdctn_trnsctn WHERE crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct))"; PassDescription='Pass 4: via tax_jrsdctn_trnsctn (crdtr_trnsctn path)'}
    Step-dmo_Delete @{Order='A39'; TableName='tax_jrsdctn_trnsctn'; WhereClause=$wTrnsctn; PassDescription='Pass 1: via cnsmr_accnt_trnsctn'}
    Step-dmo_Delete @{Order='A40'; TableName='tax_jrsdctn_trnsctn'; WhereClause="crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct)"; PassDescription='Pass 2: via crdtr_trnsctn'}
    Step-dmo_Delete @{Order='A41'; TableName='tax_jrsdctn_accnt_assctn'; WhereClause="tax_jrsdctn_accnt_id IN (SELECT cnsmr_accnt_id FROM crs5_oltp.dbo.cnsmr_accnt WHERE $wAcct)"}
    Step-dmo_Delete @{Order='A42'; TableName='cb_rpt_rqst_btch_log'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A43'; TableName='notice_rqst_cnsmr_accnt'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A44'; TableName='crdtr_srvc_evnt'; WhereClause=$wAcct; PassDescription='Pass 1: direct cnsmr_accnt_id'}
    Step-dmo_Delete @{Order='A45'; TableName='crdtr_srvc_evnt'; WhereClause="crdtr_trnsctn_id IN (SELECT crdtr_trnsctn_id FROM crs5_oltp.dbo.crdtr_trnsctn WHERE $wAcct)"; PassDescription='Pass 2: via crdtr_trnsctn'}
    Step-dmo_Delete @{Order='A46'; TableName='crdtr_trnsctn'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A47'; TableName='loan_rehab_cntr'; WhereClause="loan_rehab_dtl_id IN (SELECT loan_rehab_dtl_id FROM crs5_oltp.dbo.loan_rehab_dtl WHERE $wAcct)"}
    Step-dmo_Delete @{Order='A48'; TableName='loan_rehab_dtl'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A49'; TableName='bal_rdctn_plan_stpdwn'; WhereClause="bal_rdctn_plan_id IN (SELECT bal_rdctn_plan_id FROM crs5_oltp.dbo.bal_rdctn_plan WHERE $wAcct)"}
    Step-dmo_Delete @{Order='A50'; TableName='bal_rdctn_plan'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A51'; TableName='schdld_pymnt_accnt_dstrbtn'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A52'; TableName='cnsmr_accnt_spplmntl_info'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A53'; TableName='rcvr_ar_evnt'; WhereClause=$wArLog}
    Step-dmo_Delete @{Order='A54'; TableName='crdtr_srvc_evnt'; WhereClause=$wArLog; PassDescription='Pass 3: via ar_log'}
    Step-dmo_Delete @{Order='A55'; TableName='cnsmr_cntct_addrs_log'; WhereClause="cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log WHERE cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids))"}
    Step-dmo_Delete @{Order='A56'; TableName='cnsmr_cntct_phn_log'; WhereClause="cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log WHERE cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids))"}
    Step-dmo_Delete @{Order='A57'; TableName='cnsmr_cntct_email_log'; WhereClause="cnsmr_cntct_trnsctn_log_id IN (SELECT cnsmr_cntct_trnsctn_log_id FROM crs5_oltp.dbo.cnsmr_cntct_trnsctn_log WHERE cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids))"}
    Step-dmo_Delete @{Order='A58'; TableName='cnsmr_cntct_trnsctn_log'; WhereClause="cnsmr_cntct_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"}
    Step-dmo_Delete @{Order='A59'; TableName='agncy_accnt_trnsctn_stgng'; WhereClause="agncy_accnt_trnsctn_id IN (SELECT agncy_accnt_trnsctn_id FROM crs5_oltp.dbo.agncy_accnt_trnsctn WHERE $wArLog)"}
    Step-dmo_Delete @{Order='A60'; TableName='agncy_accnt_trnsctn'; WhereClause=$wArLog}
    Step-dmo_Delete @{Order='A61'; TableName='img_info_cnsmr_accnt_ar_log_assctn'; WhereClause=$wArLog}

    Step-dmo_JoinDelete @{
        Order = 'A62'; TableName = 'agnt_crdtbl_actvty_spprssn'
        DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
    }

    Step-dmo_JoinDelete @{
        Order = 'A63'; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
        DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
        PassDescription = 'Pass 1: via ar_log'
    }

    Step-dmo_JoinDelete @{
        Order = 'A64'; TableName = 'agnt_crdtbl_actvty'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #batch_ar_log_ids)"
    }

    Step-dmo_Delete @{Order='A65'; TableName='cnsmr_task_itm_cnsmr_accnt_ar_log_assctn'; WhereClause=$wArLog}
    Step-dmo_Delete @{Order='A66'; TableName='cnsmr_accnt_ar_log'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A67'; TableName='cnsmr_accnt_bal'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A68'; TableName='cnsmr_accnt_bckt_bal_rprtng'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A69'; TableName='schdld_pymnt_cnsmr_accnt_assctn'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A70'; TableName='cnsmr_accnt_Cmmnt'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A71'; TableName='cnsmr_accnt_frwrd_rcll'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A72'; TableName='pymnt_arrngmnt_accnt_dstrbtn'; WhereClause=$wAcct}

    if ($pmtjrnlCount -gt 0 -and -not $script:dmo_StopProcessing) {
        Write-Log "    Payment journal chain: $pmtjrnlCount rows - processing Pass 2 tables" "INFO"

        Step-dmo_Delete @{Order='A73'; TableName='cnsmr_accnt_Sttlmnt'; WhereClause="cnsmr_accnt_sttlmnt_pymnt_jrnl_id IN (SELECT cnsmr_accnt_pymnt_jrnl_id FROM #batch_pmtjrnl_ids)"; PassDescription='Pass 2: via pymnt_jrnl'}
        Step-dmo_Delete @{Order='A74'; TableName='cnsmr_accnt_trnsctn'; WhereClause=$wPmtJrnl; PassDescription='Pass 2: via pymnt_jrnl'}
        Step-dmo_Delete @{Order='A75'; TableName='cnsmr_accnt_trnsctn_stgng'; WhereClause=$wPmtJrnl}
        Step-dmo_Delete @{Order='A76'; TableName='pymnt_arrngmnt_accnt_dstrbtn_loan_rehab_cntrbtn'; WhereClause=$wPmtJrnl; PassDescription='Pass 2: via pymnt_jrnl'}
        Step-dmo_Delete @{Order='A77'; TableName='pymnt_arrngmnt_accnt_bckt_dstrbtn'; WhereClause="pymnt_arrngmnt_accnt_dstrbtn_id IN (SELECT pymnt_arrngmnt_accnt_dstrbtn_id FROM crs5_oltp.dbo.pymnt_arrngmnt_accnt_dstrbtn WHERE $wAcct)"}
        Step-dmo_Delete @{Order='A78'; TableName='cnsmr_accnt_bckt_sttlmnt'; WhereClause="cnsmr_accnt_sttlmnt_id IN (SELECT cnsmr_accnt_sttlmnt_id FROM crs5_oltp.dbo.cnsmr_accnt_Sttlmnt WHERE cnsmr_accnt_sttlmnt_pymnt_jrnl_id IN (SELECT cnsmr_accnt_pymnt_jrnl_id FROM #batch_pmtjrnl_ids))"; PassDescription='Pass 2: via pymnt_jrnl chain'}
        Step-dmo_Delete @{Order='A79'; TableName='rcvr_fnncl_trnsctn_exprt_dtl'; WhereClause=$wPmtTrnsctn; PassDescription='Pass 2: via pymnt_jrnl chain'}
        Step-dmo_Delete @{Order='A80'; TableName='rcvr_sttmnt_of_accnt_dtl'; WhereClause=$wPmtTrnsctn; PassDescription='Pass 2: via pymnt_jrnl chain'}
        Step-dmo_Delete @{Order='A81'; TableName='crdtr_invc_sctn_trnsctn_dtl'; WhereClause=$wPmtTrnsctn; PassDescription='Pass 5: via pymnt_jrnl chain'}
    } elseif (-not $script:dmo_StopProcessing) {
        Write-Log "    Payment journal chain: no rows - skipping Pass 2 tables (orders A73-A81)" "DEBUG"
        $script:dmo_TablesSkipped += 9
    }

    Step-dmo_Delete @{Order='A82'; TableName='cnsmr_accnt_ownrs'; WhereClause="$wAcct AND cnsmr_accnt_ownrshp_sft_dlt_flg = 'Y'"; PassDescription='soft-deleted only'}
    Step-dmo_Delete @{Order='A83'; TableName='crdt_Bureau_Trnsmssn'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A84'; TableName='cb_rpt_rqst_dtl'; WhereClause="cnsmr_accnt_idntfr_agncy_id IN (SELECT cnsmr_accnt_idntfr_agncy_id FROM crs5_oltp.dbo.cnsmr_accnt WHERE $wAcct)"}
    Step-dmo_Delete @{Order='A85'; TableName='cnsmr_accnt_effctv_fee_schdl'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A86'; TableName='cnsmr_accnt_effctv_intrst_rt'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A87'; TableName='sspns_cnsmr_accnt_bckt_imprt_trnsctn'; WhereClause="sspns_cnsmr_accnt_imprt_trnsctn_id IN (SELECT sspns_cnsmr_accnt_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_accnt_imprt_trnsctn WHERE sspns_trnsctn_cnsmr_accnt_idntfr_id IN (SELECT sspns_trnsctn_cnsmr_accnt_idntfr_id FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_accnt_idntfr WHERE $wAcct))"}
    Step-dmo_Delete @{Order='A88'; TableName='sspns_cnsmr_accnt_imprt_trnsctn'; WhereClause="sspns_trnsctn_cnsmr_accnt_idntfr_id IN (SELECT sspns_trnsctn_cnsmr_accnt_idntfr_id FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_accnt_idntfr WHERE $wAcct)"}
    Step-dmo_Delete @{Order='A89'; TableName='sspns_trnsctn_cnsmr_accnt_idntfr'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A90'; TableName='cnsmr_accnt_effctv_mk_whl_cnfg'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A91'; TableName='ca_case_accnt_assctn'; WhereClause=$wAcct}

    Step-dmo_Delete @{Order='A92'; TableName='hc_encntr_code_value_assctn'; WhereClause=$wEncntr}
    Step-dmo_Delete @{Order='A93'; TableName='hc_encntr_srvc_claim'; WhereClause=$wEncntr; PassDescription='Pass 1: via encntr'}
    Step-dmo_Delete @{Order='A94'; TableName='hc_encntr_srvc_dtl'; WhereClause=$wEncntr}
    Step-dmo_Delete @{Order='A95'; TableName='hc_encntr_srvc_prvdr'; WhereClause=$wEncntr}
    Step-dmo_Delete @{Order='A96'; TableName='hc_payer_plan'; WhereClause=$wEncntr}
    Step-dmo_Delete @{Order='A97'; TableName='hc_ptnt'; WhereClause=$wEncntr}
    Step-dmo_Delete @{Order='A98'; TableName='hc_encntr_srvc_code_value_assctn'; WhereClause="hc_encntr_srvc_dtl_id IN (SELECT hc_encntr_srvc_dtl_id FROM crs5_oltp.dbo.hc_encntr_srvc_dtl WHERE $wEncntr)"}
    Step-dmo_Delete @{Order='A99'; TableName='hc_encntr_srvc_pymnt_history'; WhereClause="hc_encntr_srvc_dtl_id IN (SELECT hc_encntr_srvc_dtl_id FROM crs5_oltp.dbo.hc_encntr_srvc_dtl WHERE $wEncntr)"}
    Step-dmo_Delete @{Order='A100'; TableName='hc_physcn'; WhereClause="hc_encntr_srvc_dtl_id IN (SELECT hc_encntr_srvc_dtl_id FROM crs5_oltp.dbo.hc_encntr_srvc_dtl WHERE $wEncntr)"}
    Step-dmo_Delete @{Order='A101'; TableName='hc_encntr_srvc_claim'; WhereClause="hc_payer_plan_id IN (SELECT hc_payer_plan_id FROM crs5_oltp.dbo.hc_payer_plan WHERE $wEncntr)"; PassDescription='Pass 2: via payer_plan'}
    Step-dmo_Delete @{Order='A102'; TableName='hc_encntr_ptnt_cndtn_assctn'; WhereClause="hc_ptnt_id IN (SELECT hc_ptnt_id FROM crs5_oltp.dbo.hc_ptnt WHERE $wEncntr)"}

    Step-dmo_Delete @{Order='A103'; TableName='hc_prgrm_plan_tag'; WhereClause=$wPrgrmPlan}
    Step-dmo_Delete @{Order='A104'; TableName='hc_prgrm_plan_wrk_actn'; WhereClause=$wPrgrmPlan}
    Step-dmo_Delete @{Order='A105'; TableName='hc_prgrm_plan'; WhereClause=$wEncntr}
    Step-dmo_Delete @{Order='A106'; TableName='hc_encntr'; WhereClause=$wAcct}

    Step-dmo_Delete @{Order='A107'; TableName='job_file'; WhereClause=$wAcct}
    Step-dmo_Delete @{Order='A108'; TableName='cnsmr_accnt_ownrs'; WhereClause=$wAcct; PassDescription='all remaining'}
    Step-dmo_Delete @{Order='A109'; TableName='sttlmnt_offr_accnt_assctn'; WhereClause=$wAcct}

    Step-dmo_Delete @{Order='A110'; TableName='pymnt_arrngmnt_accnt_dstrbtn_loan_rehab_cntrbtn'; WhereClause=$wPmtJrnl; PassDescription='Pass 2: via pymnt_jrnl'}
    Step-dmo_Delete @{Order='A111'; TableName='cnsmr_accnt_pymnt_jrnl_stgng'; WhereClause=$wPmtJrnl}
    Step-dmo_Delete @{Order='A112'; TableName='cnsmr_accnt_pymnt_jrnl'; WhereClause=$wAcct}

    Step-dmo_Delete @{Order='A113'; TableName='cnsmr_accnt_bckt_chck_rqst'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wAcct)"}
    Step-dmo_Delete @{Order='A114'; TableName='cnsmr_chck_btch_log'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wAcct)"}
    Step-dmo_Delete @{Order='A115'; TableName='cnsmr_chck_rqst'; WhereClause=$wAcct}

    # Safety re-delete: catch any ar_log rows written by concurrent DM activity during the batch window
    Step-dmo_Delete @{Order='A116'; TableName='cnsmr_accnt_ar_log'; WhereClause=$wAcct; PassDescription='Pass 2: safety re-delete'}

    Step-dmo_Delete @{Order='A117'; TableName='cnsmr_accnt'; WhereClause=$wAcct}
    Write-Log ""
    Write-Log "  Account-level deletion sequence complete" "SUCCESS"
}

# STEP 8: BIDATA P->C Migration (orders AB1-AB4)

Write-Log ""
Write-Log "--- Step 8: BIDATA P->C Migration ---"

if ($script:dmo_TablesFailed -gt 0) {
    Write-Log "  Skipping BIDATA migration - account-level deletes had failures" "WARN"
    $script:dmo_BidataStatus = 'Skipped'
}
elseif ($script:dmo_BatchAccountIds.Count -eq 0) {
    Write-Log "  Skipping BIDATA migration - no accounts in batch" "INFO"
    $script:dmo_BidataStatus = 'Skipped'
}
elseif (-not $script:dmo_BidataServer) {
    Write-Log "  Skipping BIDATA migration - bidata_instance not configured" "WARN"
    $script:dmo_BidataStatus = 'Skipped'
}
elseif (-not $script:XFActsExecute) {
    Write-Log "  Skipping BIDATA migration - preview mode" "INFO"
    $script:dmo_BidataStatus = 'Skipped'
}
else {
    # BIDATA connection was opened up-front in Step 2. Verify still open.
    if (-not $script:dmo_BidataConnection -or $script:dmo_BidataConnection.State -ne 'Open') {
        Write-Log "  BIDATA connection not open - attempting to reopen" "WARN"
        $bidataOk = Open-dmo_BidataConnection
    } else {
        $bidataOk = $true
    }

    if (-not $bidataOk) {
        Write-Log "  BIDATA migration failed - connection unavailable" "ERROR"
        $script:dmo_BidataStatus = 'Failed'
    }
    else {
        try {
            # Create #bidata_batch_accounts on BIDATA connection and populate
            $createCmd = $script:dmo_BidataConnection.CreateCommand()
            $createCmd.CommandText = "IF OBJECT_ID('tempdb..#bidata_batch_accounts') IS NOT NULL DROP TABLE #bidata_batch_accounts; CREATE TABLE #bidata_batch_accounts (cnsmr_accnt_id BIGINT PRIMARY KEY);"
            $createCmd.CommandTimeout = 30
            $createCmd.ExecuteNonQuery() | Out-Null
            $createCmd.Dispose()

            for ($i = 0; $i -lt $script:dmo_BatchAccountIds.Count; $i += 900) {
                $batch = $script:dmo_BatchAccountIds[$i..[Math]::Min($i + 899, $script:dmo_BatchAccountIds.Count - 1)]
                $valuesClause = ($batch | ForEach-Object { "($_)" }) -join ','
                $insertCmd = $script:dmo_BidataConnection.CreateCommand()
                $insertCmd.CommandText = "INSERT INTO #bidata_batch_accounts (cnsmr_accnt_id) VALUES $valuesClause"
                $insertCmd.CommandTimeout = 30
                $insertCmd.ExecuteNonQuery() | Out-Null
                $insertCmd.Dispose()
            }

            Write-Log "  BIDATA temp table loaded: $($script:dmo_BatchAccountIds.Count) account IDs" "INFO"

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
                    $result = Invoke-dmo_BidataTableMigration -SourceTable $tbl.Source -DestTable $tbl.Dest
                    $stepMs = [int]((Get-Date) - $stepStart).TotalMilliseconds

                    if ($result.Inserted -eq 0) {
                        Write-Log "  [$($tbl.Order)] $($tbl.Source) -> $($tbl.Dest) - no rows, skipping" "DEBUG"
                        Write-dmo_BatchDetail -DeleteOrder $tbl.Order -TableName "$($tbl.Source) -> $($tbl.Dest)" `
                            -PassDescription 'P -> C migration' -RowsAffected 0 -DurationMs $stepMs -Status 'Skipped'
                    }
                    else {
                        Write-Log "  [$($tbl.Order)] $($tbl.Source) -> $($tbl.Dest) - migrated $($result.Inserted) rows, deleted $($result.Deleted) from P (${stepMs}ms)" "SUCCESS"
                        Write-dmo_BatchDetail -DeleteOrder $tbl.Order -TableName "$($tbl.Source) -> $($tbl.Dest)" `
                            -PassDescription 'P -> C migration' -RowsAffected $result.Inserted -DurationMs $stepMs -Status 'Success'
                    }
                }
                catch {
                    $stepMs = [int]((Get-Date) - $stepStart).TotalMilliseconds
                    Write-Log "  [$($tbl.Order)] $($tbl.Source) -> $($tbl.Dest) - FAILED (${stepMs}ms): $($_.Exception.Message)" "ERROR"
                    Write-dmo_BatchDetail -DeleteOrder $tbl.Order -TableName "$($tbl.Source) -> $($tbl.Dest)" `
                        -PassDescription 'P -> C migration' -RowsAffected 0 -DurationMs $stepMs -Status 'Failed' -ErrorMessage $_.Exception.Message
                    $bidataAllOk = $false
                    break
                }
            }

            if ($bidataAllOk) {
                $script:dmo_BidataStatus = 'Success'

                # Anonymize PII and set purge flags on C tables
                if (-not $NoAnonymize) {
                    $anonymizeStart = Get-Date
                    try {
                        # GenAccountTblC - has ssn column unique to this table
                        $anonCmd = $script:dmo_BidataConnection.CreateCommand()
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

                        # GenAccPayTblC - no ssn column
                        $anonCmd = $script:dmo_BidataConnection.CreateCommand()
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

                        # GenAccPayAggTblC - no ssn column
                        $anonCmd = $script:dmo_BidataConnection.CreateCommand()
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

                        # GenPaymentTblC - no PII columns, only purge flags
                        $anonCmd = $script:dmo_BidataConnection.CreateCommand()
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
                        # Anonymization failure does not fail the batch - data is migrated, just not scrubbed
                    }
                }
                else {
                    # Not anonymizing - still set purge flags
                    try {
                        $purgeCmd = $script:dmo_BidataConnection.CreateCommand()
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
                    WHERE batch_id = $($script:dmo_CurrentBatchId)
"@ -Timeout 30 | Out-Null

                Write-Log "  BIDATA migration complete - ConsumerLog updated" "SUCCESS"
            }
            else {
                $script:dmo_BidataStatus = 'Failed'
                Write-Log "  BIDATA migration failed - ConsumerLog.bidata_migrated remains 0" "ERROR"
                # Halt the batch - Steps 9/10 will skip
                $script:dmo_StopProcessing = $true
            }
        }
        catch {
            Write-Log "  BIDATA migration failed: $($_.Exception.Message)" "ERROR"
            $script:dmo_BidataStatus = 'Failed'
            $script:dmo_StopProcessing = $true
        }
    }
}

Write-Log ""

# STEP 9: Materialize Consumer-Level Temp Tables

if ($script:dmo_StopProcessing) {
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
        $cmd = $script:dmo_TargetConnection.CreateCommand()
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
        $script:dmo_StopProcessing = $true
    }

    Write-Log ""
}

# STEP 10: Execute Consumer-Level Deletions (Phase 1 UDEFs CU* + Phase 2 C1-C110)

if ($script:dmo_StopProcessing) {
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

    # Phase 1: Consumer-Level UDEF Tables (Dynamic Discovery)
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
            Step-dmo_Delete @{Order="CU$udefOrder"; TableName=$udefTable; WhereClause=$wCnsmr}
        }
    }

    Write-Log ""

    # Phase 2: Consumer-Level Tables (orders C1-C110)
    # Tables marked [EXCL] in the standalone shell purge are exclusion-controlled.
    # Under the unified archive flow no exclusions apply (Step 5 handles eligibility),
    # so these run unconditionally. Pass description preserved for cross-reference.
    Write-Log "  Phase 2: Consumer-Level Tables" "INFO"

    # Simple direct cnsmr_id tables (no FK children, no ordering concerns)
    Step-dmo_Delete @{Order='C1'; TableName='asst'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C2'; TableName='attrny'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C3'; TableName='cnsmr_addrss'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C4'; TableName='cnsmr_Cmmnt'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C5'; TableName='cnsmr_crdt'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C6'; TableName='cnsmr_fee_spprss_cnfg'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C7'; TableName='cnsmr_Fnncl'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C8'; TableName='cnsmr_rndm_nmbr'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C9'; TableName='cnsmr_Rvw_rqst'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C10'; TableName='cnsmr_Tag'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C11'; TableName='cnsmr_Wrk_actn'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C12'; TableName='decsd'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C13'; TableName='dfrrd_cnsmr'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C14'; TableName='emplyr'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C15'; TableName='ivr_call_log'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C16'; TableName='job_skptrc_cnsmr'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C17'; TableName='job_skptrc_instnc_log'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C18'; TableName='strtgy_log'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C19'; TableName='usr_rmndr'; WhereClause="usr_rmndr_cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"}
    Step-dmo_Delete @{Order='C20'; TableName='cnsmr_accnt_spplmntl_info'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C21'; TableName='cb_rpt_assctd_cnsmr_data'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C22'; TableName='cb_rpt_base_data'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C23'; TableName='cb_rpt_emplyr_data'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C24'; TableName='cb_rpt_rqst_dtl'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C25'; TableName='job_file'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C26'; TableName='cnsmr_accnt_ownrs'; WhereClause=$wCnsmr}

    # bal_rdctn_plan chain (FK: stpdwn -> plan -> cnsmr)
    Step-dmo_Delete @{Order='C27'; TableName='bal_rdctn_plan_stpdwn'; WhereClause="bal_rdctn_plan_id IN (SELECT bal_rdctn_plan_id FROM crs5_oltp.dbo.bal_rdctn_plan WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C28'; TableName='bal_rdctn_plan'; WhereClause=$wCnsmr}

    # ca_case chain (FK: children -> ca_case -> cnsmr)
    Step-dmo_Delete @{Order='C29'; TableName='ca_case_accnt_assctn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C30'; TableName='ca_case_ar_log_assctn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C31'; TableName='ca_case_bal_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C32'; TableName='ca_case_cntct_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C33'; TableName='ca_case_lck_wrk_actn'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C34'; TableName='ca_case_strtgy_log'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C35'; TableName='ca_case_tag'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C36'; TableName='dfrrd_ca_case'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C37'; TableName='wrk_lst_case_cache'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C38'; TableName='wrkgrp_scan_lst_case_cache'; WhereClause="ca_case_id IN (SELECT ca_case_id FROM crs5_oltp.dbo.ca_case WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C39'; TableName='ca_case'; WhereClause=$wCnsmr}

    # cmpgn chain (FK: dialer_trnsctn_log -> cmpgn_trnsctn_log -> cnsmr, cmpgn_cache -> cnsmr_Phn)
    Step-dmo_Delete @{Order='C40'; TableName='dialer_trnsctn_log'; WhereClause="cmpgn_trnsctn_log_id IN (SELECT cmpgn_trnsctn_log_id FROM crs5_oltp.dbo.cmpgn_trnsctn_log WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C41'; TableName='cmpgn_trnsctn_log'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C42'; TableName='cmpgn_cache'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C43'; TableName='cnsmr_Phn'; WhereClause=$wCnsmr}

    # cnsmr_accnt_ar_log chain - contact log children BEFORE ar_log
    Step-dmo_Delete @{Order='C44'; TableName='cnsmr_cntct_addrs_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
    Step-dmo_Delete @{Order='C45'; TableName='cnsmr_cntct_phn_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
    Step-dmo_Delete @{Order='C46'; TableName='cnsmr_cntct_email_log'; WhereClause=$wCntctLog; PassDescription='via cntct_trnsctn_log'}
    Step-dmo_Delete @{Order='C47'; TableName='cnsmr_cntct_trnsctn_log'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C48'; TableName='cnsmr_task_itm_cnsmr_accnt_ar_log_assctn'; WhereClause=$wArLog}

    # agnt_crdtbl_actvty chain via ar_log - must clear before cnsmr_accnt_ar_log
    Step-dmo_JoinDelete @{
        Order = 'C49'; TableName = 'agnt_crdtbl_actvty_spprssn'
        DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        PassDescription = 'Pass 1: via ar_log'
    }

    Step-dmo_JoinDelete @{
        Order = 'C50'; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
        DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        PassDescription = 'Pass 1: via ar_log'
    }

    Step-dmo_JoinDelete @{
        Order = 'C51'; TableName = 'agnt_crdtbl_actvty'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty WHERE cnsmr_accnt_ar_log_id IN (SELECT cnsmr_accnt_ar_log_id FROM #shell_ar_log_ids)"
        PassDescription = 'Pass 1: via ar_log'
    }

    Step-dmo_Delete @{Order='C52'; TableName='crdtr_srvc_evnt'; WhereClause=$wCnsmr; PassDescription='before ar_log (FK dependency)'}
    Step-dmo_Delete @{Order='C53'; TableName='cnsmr_accnt_ar_log'; WhereClause=$wArLog}

    # cnsmr_task_itm (must come after ar_log association at C48)
    Step-dmo_Delete @{Order='C54'; TableName='cnsmr_task_itm'; WhereClause=$wCnsmr}

    # invc_crrctn chain (FK: dtl children -> parent -> cnsmr)
    Step-dmo_Delete @{Order='C55'; TableName='invc_crrctn_dtl_stgng'; WhereClause="invc_crrctn_trnsctn_stgng_id IN (SELECT invc_crrctn_trnsctn_stgng_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn_stgng WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C56'; TableName='invc_crrctn_trnsctn_stgng'; WhereClause=$wCnsmr}
    Step-dmo_Delete @{Order='C57'; TableName='invc_crrctn_dtl'; WhereClause="invc_crrctn_trnsctn_id IN (SELECT invc_crrctn_trnsctn_id FROM crs5_oltp.dbo.invc_crrctn_trnsctn WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C58'; TableName='invc_crrctn_trnsctn'; WhereClause=$wCnsmr}

    # jdgmnt chain (FK: jdgmnt_addtnl_info -> jdgmnt -> cnsmr)
    Step-dmo_Delete @{Order='C59'; TableName='jdgmnt_addtnl_info'; WhereClause="jdgmnt_id IN (SELECT jdgmnt_id FROM crs5_oltp.dbo.jdgmnt WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C60'; TableName='jdgmnt'; WhereClause=$wCnsmr}

    # Rltd_Prsn chain (FK: rltd_prsn_tag -> Rltd_Prsn -> cnsmr)
    Step-dmo_Delete @{Order='C61'; TableName='rltd_prsn_tag'; WhereClause="rltd_prsn_id IN (SELECT rltd_prsn_id FROM crs5_oltp.dbo.Rltd_Prsn WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C62'; TableName='Rltd_Prsn'; WhereClause=$wCnsmr}

    # cnsmr_chck_rqst chain (FK: children -> cnsmr_chck_rqst -> cnsmr)
    Step-dmo_Delete @{Order='C63'; TableName='cnsmr_accnt_bckt_chck_rqst'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C64'; TableName='cnsmr_chck_btch_log'; WhereClause="cnsmr_chck_rqst_id IN (SELECT cnsmr_chck_rqst_id FROM crs5_oltp.dbo.cnsmr_chck_rqst WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C65'; TableName='cnsmr_chck_rqst'; WhereClause=$wCnsmr}

    # notice_rqst (must come before schdld_pymnt_instnc which has FK to notice_rqst)
    Step-dmo_Delete @{Order='C66'; TableName='notice_rqst'; WhereClause=$wCnsmr}

    # sttlmnt_offr chain - must come before cnsmr_pymnt_instrmnt AND schdld_pymnt_smmry
    Step-dmo_Delete @{Order='C67'; TableName='sttlmnt_offr_accnt_assctn'; WhereClause="sttlmnt_offr_id IN (SELECT sttlmnt_offr_id FROM crs5_oltp.dbo.sttlmnt_offr WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C68'; TableName='sttlmnt_offr_systm_dtl'; WhereClause="sttlmnt_offr_id IN (SELECT sttlmnt_offr_id FROM crs5_oltp.dbo.sttlmnt_offr WHERE $wCnsmr)"}
    Step-dmo_Delete @{Order='C69'; TableName='sttlmnt_offr'; WhereClause=$wCnsmr}

    # epp chain (FK: children -> epp_pymnt_typ_cnfg -> cnsmr_pymnt_instrmnt)
    Step-dmo_Delete @{Order='C70'; TableName='epp_cmmnctn_log'; WhereClause="epp_pymnt_typ_cnfg_id IN (SELECT epp_pymnt_typ_cnfg_id FROM crs5_oltp.dbo.epp_pymnt_typ_cnfg WHERE $wInstrmnt)"}
    Step-dmo_Delete @{Order='C71'; TableName='epp_vrfctn_rspns'; WhereClause="epp_pymnt_typ_cnfg_id IN (SELECT epp_pymnt_typ_cnfg_id FROM crs5_oltp.dbo.epp_pymnt_typ_cnfg WHERE $wInstrmnt)"}
    Step-dmo_Delete @{Order='C72'; TableName='epp_pymnt_typ_cnfg'; WhereClause=$wInstrmnt}
    Step-dmo_Delete @{Order='C73'; TableName='epp_pymnt_rspns'; WhereClause=$wCnsmr}

    # cpm_pm_assctn (FK to both cnsmr_pymnt_instrmnt AND cnsmr_pymnt_mthd)
    Step-dmo_Delete @{Order='C74'; TableName='cpm_pm_assctn'; WhereClause=$wInstrmnt}

    # Scheduled payment children (before schdld_pymnt_instnc)
    Step-dmo_Delete @{Order='C75'; TableName='pymnt_schdl_notice_rqst_assctn'; WhereClause="schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE $wSmmry)"}
    Step-dmo_Delete @{Order='C76'; TableName='schdld_pymnt_cnsmr_accnt_assctn'; WhereClause=$wSmmry; PassDescription='via smmry'}

    # Agent credit chain [EXCL] - must clear before cnsmr_pymnt_jrnl
    # agnt_crdt has FK on cnsmr_pymnt_jrnl_id
    Step-dmo_Delete @{Order='C77'; TableName='agnt_crdt_spprssn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE $wJrnl)"; PassDescription='[EXCL] via pymnt_jrnl'}
    Step-dmo_Delete @{Order='C78'; TableName='agnt_crdtbl_actvty_crdt_assctn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE $wJrnl)"; PassDescription='[EXCL] Pass 1: via pymnt_jrnl'}
    Step-dmo_Delete @{Order='C79'; TableName='agnt_crdt'; WhereClause=$wJrnl; PassDescription='[EXCL] via pymnt_jrnl'}

    # Payment journal children (must clear before cnsmr_pymnt_jrnl)
    Step-dmo_Delete @{Order='C80'; TableName='cnsmr_chck_trnsctn'; WhereClause=$wJrnl; PassDescription='via pymnt_jrnl'}

    Step-dmo_JoinDelete @{
        Order = 'C81'; TableName = 'cpj_rvrsl_assctn'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.cpj_rvrsl_assctn WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cpj_rvrsl_assctn WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
        PassDescription = 'via pymnt_jrnl'
    }

    # cnsmr_pymnt_jrnl_schdld_pymnt_instnc: FK to BOTH cnsmr_pymnt_jrnl AND schdld_pymnt_instnc
    Step-dmo_JoinDelete @{
        Order = 'C82'; TableName = 'cnsmr_pymnt_jrnl_schdld_pymnt_instnc'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE cnsmr_pymnt_jrnl_id IN (SELECT cnsmr_pymnt_jrnl_id FROM #shell_pymnt_jrnl_ids)"
        PassDescription = 'Pass 1: via pymnt_jrnl'
    }

    Step-dmo_JoinDelete @{
        Order = 'C83'; TableName = 'cnsmr_pymnt_jrnl_schdld_pymnt_instnc'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl_schdld_pymnt_instnc WHERE schdld_pymnt_instnc_id IN (SELECT schdld_pymnt_instnc_id FROM crs5_oltp.dbo.schdld_pymnt_instnc WHERE schdld_pymnt_smmry_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"
        PassDescription = 'Pass 2: via smmry'
    }

    # cnsmr_pymnt_jrnl - all children now cleared
    Step-dmo_Delete @{Order='C84'; TableName='cnsmr_pymnt_jrnl'; WhereClause=$wCnsmr}

    # schdld_pymnt_instnc - cnsmr_pymnt_jrnl_schdld_pymnt_instnc cleared above
    Step-dmo_Delete @{Order='C85'; TableName='schdld_pymnt_instnc'; WhereClause=$wSmmry; PassDescription='via smmry'}

    # Suspense: NULL resolved cross-consumer payment journal references
    # When consumer A merges into consumer B, the payment journal moves to B but the
    # sspns_cnsmr_imprt_trnsctn stays on A. The FK reference from B's cnsmr_pymnt_jrnl
    # back to A's suspense record is a historical breadcrumb. For resolved suspense
    # (status 3=RESOLVED, 5=RESOLVED_AS_REFUND, 7=RESOLVED_AS_ESCHEAT, 10=MULTI_RESOLVED),
    # we NULL the reference to allow deletion.
    Step-dmo_Update @{
        Order = 'C86'; TableName = 'cnsmr_pymnt_jrnl'
        UpdateStatement = "UPDATE cpj SET cpj.sspns_cnsmr_imprt_trnsctn_id = NULL FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj WHERE cpj.sspns_cnsmr_imprt_trnsctn_id IN (SELECT sci.sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn sci INNER JOIN crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci ON sci.sspns_trnsctn_cnsmr_idntfr_id = stci.sspns_trnsctn_cnsmr_idntfr_id WHERE stci.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers) AND sci.sspns_trnsctn_stts_cd IN (3, 5, 7, 10))"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl cpj WHERE cpj.sspns_cnsmr_imprt_trnsctn_id IN (SELECT sci.sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn sci INNER JOIN crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci ON sci.sspns_trnsctn_cnsmr_idntfr_id = stci.sspns_trnsctn_cnsmr_idntfr_id WHERE stci.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers) AND sci.sspns_trnsctn_stts_cd IN (3, 5, 7, 10))"
        PassDescription = 'NULL resolved suspense refs on merged consumers'
    }

    # Suspense chain - must come after cnsmr_pymnt_jrnl (which has FK to sspns_cnsmr_imprt_trnsctn)
    Step-dmo_Delete @{Order='C87'; TableName='sspns_cnsmr_trnsctn_log'; WhereClause="sspns_cnsmr_imprt_trnsctn_id IN (SELECT sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE $wInstrmnt)"; PassDescription='Pass 1: via pymnt_instrmnt'}

    Step-dmo_JoinDelete @{
        Order = 'C88'; TableName = 'sspns_cnsmr_imprt_trnsctn'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM #shell_pymnt_instrmnt_ids)"
        PassDescription = 'Pass 1: via pymnt_instrmnt'
    }

    Step-dmo_Delete @{Order='C89'; TableName='sspns_cnsmr_trnsctn_log'; WhereClause="sspns_cnsmr_imprt_trnsctn_id IN (SELECT sci.sspns_cnsmr_imprt_trnsctn_id FROM crs5_oltp.dbo.sspns_cnsmr_imprt_trnsctn sci INNER JOIN crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr stci ON sci.sspns_trnsctn_cnsmr_idntfr_id = stci.sspns_trnsctn_cnsmr_idntfr_id WHERE stci.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers))"; PassDescription='Pass 2: via sspns_trnsctn_cnsmr_idntfr'}

    Step-dmo_Delete @{Order='C90'; TableName='sspns_cnsmr_imprt_trnsctn'; WhereClause="sspns_trnsctn_cnsmr_idntfr_id IN (SELECT sspns_trnsctn_cnsmr_idntfr_id FROM crs5_oltp.dbo.sspns_trnsctn_cnsmr_idntfr WHERE $wCnsmr)"; PassDescription='Pass 2: via sspns_trnsctn_cnsmr_idntfr'}

    # Agent creditable activity chain [EXCL] - Pass 2: via direct cnsmr_id
    Step-dmo_JoinDelete @{
        Order = 'C91'; TableName = 'agnt_crdtbl_actvty_spprssn'
        DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"
        PassDescription = '[EXCL] Pass 2: via direct cnsmr_id'
    }

    Step-dmo_JoinDelete @{
        Order = 'C92'; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
        DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers)"
        PassDescription = '[EXCL] Pass 2: via direct cnsmr_id'
    }

    Step-dmo_Delete @{Order='C93'; TableName='agnt_crdtbl_actvty'; WhereClause=$wCnsmr; PassDescription='[EXCL] Pass 2: via direct cnsmr_id'}

    # cnsmr_pymnt_instrmnt (now safe - ALL FK children cleared above)
    Step-dmo_Delete @{Order='C94'; TableName='cnsmr_pymnt_instrmnt'; WhereClause=$wCnsmr; PassDescription='Pass 1: direct'}

    Step-dmo_JoinDelete @{
        Order = 'C95'; TableName = 'cnsmr_pymnt_instrmnt'
        DeleteStatement = "DELETE FROM crs5_oltp.dbo.cnsmr_pymnt_instrmnt WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl WHERE cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers))"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.cnsmr_pymnt_instrmnt WHERE cnsmr_pymnt_instrmnt_id IN (SELECT cnsmr_pymnt_instrmnt_id FROM crs5_oltp.dbo.cnsmr_pymnt_jrnl WHERE cnsmr_id IN (SELECT cnsmr_id FROM #archive_batch_consumers))"
        PassDescription = 'Pass 2: via pymnt_jrnl'
    }

    # cnsmr_pymnt_mthd (now safe - cpm_pm_assctn cleared at C74)
    Step-dmo_Delete @{Order='C96'; TableName='cnsmr_pymnt_mthd'; WhereClause=$wCnsmr}

    # sspns_trnsctn_cnsmr_idntfr (now safe - all suspense children cleared)
    Step-dmo_Delete @{Order='C97'; TableName='sspns_trnsctn_cnsmr_idntfr'; WhereClause=$wCnsmr}

    # Agent credit chain Pass 2: via schdld_pymnt_smmry
    Step-dmo_Delete @{Order='C98'; TableName='agnt_crdt_spprssn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"; PassDescription='[EXCL] Pass 2: via smmry'}
    Step-dmo_Delete @{Order='C99'; TableName='agnt_crdtbl_actvty_crdt_assctn'; WhereClause="agnt_crdt_id IN (SELECT agnt_crdt_id FROM crs5_oltp.dbo.agnt_crdt WHERE cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids))"; PassDescription='[EXCL] Pass 2: via smmry'}
    Step-dmo_Delete @{Order='C100'; TableName='agnt_crdt'; WhereClause="cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"; PassDescription='[EXCL] Pass 2: via smmry'}

    # agnt_crdtbl_actvty chain Pass 3: via schdld_pymnt_smmry
    Step-dmo_JoinDelete @{
        Order = 'C101'; TableName = 'agnt_crdtbl_actvty_spprssn'
        DeleteStatement = "DELETE acas FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_spprssn acas JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acas.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
        PassDescription = '[EXCL] Pass 3: via smmry'
    }

    Step-dmo_JoinDelete @{
        Order = 'C102'; TableName = 'agnt_crdtbl_actvty_crdt_assctn'
        DeleteStatement = "DELETE acac FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
        CountQuery = "SELECT COUNT(*) AS row_count FROM crs5_oltp.dbo.agnt_crdtbl_actvty_crdt_assctn acac JOIN crs5_oltp.dbo.agnt_crdtbl_actvty aca ON acac.agnt_crdtbl_actvty_id = aca.agnt_crdtbl_actvty_id WHERE aca.cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"
        PassDescription = '[EXCL] Pass 3: via smmry'
    }

    Step-dmo_Delete @{Order='C103'; TableName='agnt_crdtbl_actvty'; WhereClause="cnsmr_pymnt_schdl_id IN (SELECT schdld_pymnt_smmry_id FROM #shell_smmry_ids)"; PassDescription='[EXCL] Pass 3: via smmry'}

    # schdld_pymnt_smmry (now safe - all children cleared above)
    Step-dmo_Delete @{Order='C104'; TableName='schdld_pymnt_smmry'; WhereClause=$wSmmry}

    # Bankruptcy chain [EXCL]
    Step-dmo_Delete @{Order='C105'; TableName='bnkrptcy_addtnl_info'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
    Step-dmo_Delete @{Order='C106'; TableName='bnkrptcy_pttnr'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
    Step-dmo_Delete @{Order='C107'; TableName='bnkrptcy_trustee'; WhereClause="bnkrptcy_id IN (SELECT bnkrptcy_id FROM crs5_oltp.dbo.bnkrptcy WHERE $wCnsmr)"; PassDescription='[EXCL]'}
    Step-dmo_Delete @{Order='C108'; TableName='bnkrptcy'; WhereClause=$wCnsmr; PassDescription='[EXCL]'}

    # hc_payer_plan (direct cnsmr FK, no encntr dependency for shells)
    Step-dmo_Delete @{Order='C109'; TableName='hc_payer_plan'; WhereClause=$wCnsmr}

    # TERMINAL: cnsmr record itself
    Step-dmo_Delete @{Order='C110'; TableName='cnsmr'; WhereClause=$wCnsmr}

    Write-Log ""
    Write-Log "  Consumer-level deletion sequence complete" "SUCCESS"
}

# STEP 11: Finalize Batch Log

$batchStatus = if ($script:dmo_TablesFailed -gt 0) { "Failed" }
               elseif ($script:dmo_BidataStatus -eq 'Failed') { "Failed" }
               else { "Success" }
$batchError = if ($script:dmo_TablesFailed -gt 0) { "One or more tables failed during delete sequence" }
              elseif ($script:dmo_BidataStatus -eq 'Failed') { "BIDATA P-to-C migration failed" }
              else { $null }
Update-dmo_BatchLogEntry -Status $batchStatus -ErrorMessage $batchError -BidataStatus $script:dmo_BidataStatus

# Update session counters
$script:dmo_SessionTotalDeleted += $script:dmo_TotalDeleted
$script:dmo_SessionTotalConsumers += $script:dmo_BatchConsumerIds.Count
$script:dmo_SessionTotalAccounts += $script:dmo_BatchAccountIds.Count
$script:dmo_SessionTotalExceptions += $script:dmo_BatchExceptions.Count
if ($batchStatus -eq 'Failed') { $script:dmo_TotalBatchesFailed++ }

# Batch summary
$batchDuration = (Get-Date) - $script:dmo_BatchStartTime
$retryNote = if ($script:dmo_RetryOfBatchId -gt 0) { " [retry of batch_id $($script:dmo_RetryOfBatchId)]" } else { "" }
$exceptionNote = if ($script:dmo_BatchExceptions.Count -gt 0) { " (exceptions: $($script:dmo_BatchExceptions.Count))" } else { "" }
Write-Log "  Batch #$($script:dmo_TotalBatchesRun): $($script:dmo_BatchConsumerIds.Count) consumers, $($script:dmo_BatchAccountIds.Count) accounts, $($script:dmo_TotalDeleted) rows, $([math]::Round($batchDuration.TotalSeconds, 1))s - $batchStatus (BIDATA: $($script:dmo_BidataStatus))$exceptionNote$retryNote" "INFO"

# Queue Teams alert on failure (execute mode only - Send-TeamsAlert writes to Teams.AlertQueue)
if ($batchStatus -eq 'Failed' -and $script:dmo_AlertingEnabled -and $script:XFActsExecute) {
    Send-TeamsAlert -SourceModule 'DmOps' -AlertCategory 'CRITICAL' `
        -Title '{{FIRE}} Consumer archive batch failed' `
        -Message "**Batch:** #$($script:dmo_TotalBatchesRun) (batch_id: $($script:dmo_CurrentBatchId))$retryNote`n**Target:** $($script:dmo_TargetServer)`n**Tables Failed:** $($script:dmo_TablesFailed)`n**Consumers:** $($script:dmo_BatchConsumerIds.Count)`n**Accounts:** $($script:dmo_BatchAccountIds.Count)`n**Exceptions:** $($script:dmo_BatchExceptions.Count)`n**BIDATA:** $($script:dmo_BidataStatus)`n`nCheck Archive_BatchDetail for batch_id $($script:dmo_CurrentBatchId)." `
        -TriggerType 'ARCHIVE_BATCH_FAILED' `
        -TriggerValue "$($script:dmo_CurrentBatchId)" | Out-Null
}
elseif ($batchStatus -eq 'Failed' -and -not $script:XFActsExecute) {
    Write-Log "  [Preview] Would queue Teams alert (ARCHIVE_BATCH_FAILED)" "INFO"
}
elseif ($batchStatus -eq 'Failed') {
    Write-Log "  Teams alert suppressed - alerting_enabled is off" "INFO"
}

# STEP 12: Batch Loop Continuation Check

if ($SingleBatch) {
    Write-Log "  Single batch mode - exiting loop" "INFO"
    $continueProcessing = $false
}
elseif ($batchStatus -eq 'Failed') {
    Write-Log "  Batch failed - stopping further processing" "ERROR"
    $continueProcessing = $false
}
elseif (Test-dmo_ArchiveAbort) {
    Write-Log "  Archive abort flag detected - stopping after batch completion" "WARN"
    $continueProcessing = $false
}
elseif (Test-dmo_BidataBuildInProgress) {
    Write-Log "  BIDATA Daily Build started on $($script:dmo_BidataServer) - stopping to avoid contention" "WARN"
    $continueProcessing = $false
}
else {
    $nextScheduleValue = Get-dmo_ArchiveScheduleMode
    if ($nextScheduleValue -eq 0) {
        Write-Log "  Schedule: now in BLOCKED window - stopping" "INFO"
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

# STEP 13: Cleanup, Session Summary, Orchestrator Callback

Close-dmo_BidataConnection
Close-dmo_TargetConnection

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart
$totalMs = [int]$scriptDuration.TotalMilliseconds

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Session Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "  Mode             : $(if ($script:XFActsExecute) { 'EXECUTE' } else { 'PREVIEW' })"
Write-Log "  Target           : $($script:dmo_TargetServer)"
Write-Log "  Batches Run      : $($script:dmo_TotalBatchesRun)"
Write-Log "  Batches Failed   : $($script:dmo_TotalBatchesFailed)"
Write-Log "  Total Consumers  : $($script:dmo_SessionTotalConsumers)"
Write-Log "  Total Accounts   : $($script:dmo_SessionTotalAccounts)"
Write-Log "  Total Exceptions : $($script:dmo_SessionTotalExceptions)"
if (-not $script:XFActsExecute) {
    Write-Log "  Rows to Delete   : $($script:dmo_SessionTotalDeleted)"
} else {
    Write-Log "  Rows Deleted     : $($script:dmo_SessionTotalDeleted)"
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
    $finalStatus = if ($script:dmo_TotalBatchesFailed -gt 0) { "FAILED" } else { "SUCCESS" }
    $outputSummary = "Batches:$($script:dmo_TotalBatchesRun) Failed:$($script:dmo_TotalBatchesFailed) Consumers:$($script:dmo_SessionTotalConsumers) Accounts:$($script:dmo_SessionTotalAccounts) Exceptions:$($script:dmo_SessionTotalExceptions) Deleted:$($script:dmo_SessionTotalDeleted)"
    Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}

if ($script:dmo_TotalBatchesFailed -gt 0) { exit 1 } else { exit 0 }
<#
.SYNOPSIS
    xFACts - Payment Batch Status Collection

.DESCRIPTION
    Monitors Debt Manager Payment batch lifecycle from creation through terminal
    state. Collects new batches, updates status for in-flight batches, and tracks
    log activity for stall detection. Covers all payment batch types (Manual,
    Import, Reversal, Reapply, Balance Adjustment, Virtual, etc.).

    Follows the xFACts collect/evaluate pattern: reads from a configurable AG
    replica for DM queries, writes to xFACts via the AG listener for all
    BatchOps.* table updates, detects current PRIMARY/SECONDARY roles
    automatically, and supports preview mode for safe testing.

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR).

.PARAMETER Database
    xFACts database name (default: xFACts).

.PARAMETER SourceDB
    Source database for Debt Manager data (default: crs5_oltp).

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER ForceSourceServer
    Override the GlobalConfig replica setting and connect to a specific server for
    reads. Useful for testing or when AG detection fails.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for
    task completion callback. Default 0 (no callback when run manually).

.COMPONENT
    BatchOps

.NOTES
    File Name : Collect-PMTBatchStatus.ps1
    Location  : E:\xFACts-PowerShell

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    VARIABLES: GLOBAL STATE
    FUNCTIONS: SOURCE AND CONFIGURATION
    FUNCTIONS: COLLECTION STEPS
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-driven change history for this collector. Most-recent entry first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-18  Migrated to the shared xFACts-BatchOpsFunctions.ps1 helpers.
#             Removed the local Get-bat_PMT_SourceData, Get-bat_PMT_-
#             AGReplicaRoles, and Step-bat_PMT_UpdateStatus; calls now use
#             Get-bat_SourceData, the shared Get-AGReplicaRoles via
#             Resolve-bat_ReadServer, and Set-bat_BatchStatus for the
#             RUNNING and IDLE Status writes. All four alert checks
#             dispatch through Send-bat_BatchAlert. Dropped the dead
#             AGPrimary/AGSecondary script variables. Behavior unchanged.
# 2026-04-28  Standardized Teams alerting via Send-TeamsAlert shared function.
#             Converted all 4 alert checks from direct INSERT to Send-TeamsAlert.
#             Inline Teams.RequestLog dedup queries removed (handled by shared function).
#             Jira branches and routing bitmask logic unchanged.
# 2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure.
#             Removed inline Write-Log, Get-xFACtsData, Invoke-xFACtsWrite.
#             Renamed $xFACtsServer/$xFACtsDB to $ServerInstance/$Database.
# 2026-02-17  PARTIAL non-terminal fix: PARTIAL (5) removed from terminal state
#             detection. Recovery detection resets completed fields and alert_count.
# 2026-02-13  Terminal failure alerting: IMPORTFAILED, FAILED, PARTIAL, REVERSALFAILED
#             conditions. Per-condition routing via GlobalConfig with RequestLog dedup.
# 2026-02-11  Initial implementation. Payment batch lifecycle tracking (all batch types),
#             AG-aware replica detection, log-based stall detection, hard delete detection,
#             preview mode, Orchestrator v2 integration.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   The [CmdletBinding()] attribute and param() block declaring script-level parameters.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [string]$SourceDB = "crs5_oltp",
    [switch]$Execute,
    [string]$ForceSourceServer = $null,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sources the platform shared orchestrator functions consumed by this script.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"
. "$PSScriptRoot\xFACts-BatchOpsFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   One-time setup that must run at file scope before other content executes.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Collect-PMTBatchStatus' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

<# ============================================================================
   VARIABLES: GLOBAL STATE
   ----------------------------------------------------------------------------
   Mutable script-scope state populated during configuration and execution.
   Prefix: bat
   ============================================================================ #>

# Server the script reads DM source data from (PRIMARY or SECONDARY per config).
$script:ReadServer = $null

# Server the script writes xFACts updates to (the AG listener).
$script:WriteServer = $null

# Loaded GlobalConfig settings and PMT thresholds.
$script:Config = @{}

<# ============================================================================
   FUNCTIONS: SOURCE AND CONFIGURATION
   ----------------------------------------------------------------------------
   Source-data access, AG replica role detection, and configuration loading.
   Prefix: bat
   ============================================================================ #>

# Loads GlobalConfig settings, resolves AG replica roles, and sets read/write servers.
function Initialize-bat_PMT_Configuration {
    param()
    Write-Log "Loading configuration..." "INFO"

    # Load GlobalConfig settings
    $configQuery = @"
        SELECT module_name, setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name IN ('BatchOps', 'Shared', 'dbo')
          AND is_active = 1
"@

    $configResults = Get-SqlData -Query $configQuery

    # Set defaults
    $script:Config = @{
        AGName                      = "DMPRODAG"
        SourceReplica               = "SECONDARY"
        PMT_AlertingEnabled         = $false
        PMT_LookbackDays            = 7
        # Alert routing: 0=None, 1=Teams, 2=Jira, 3=Both
        PMT_Alert_ImportFailed      = 3
        PMT_Alert_Failed            = 3
        PMT_Alert_Partial           = 3
        PMT_Alert_ReversalFailed    = 3
    }

    # Override with GlobalConfig values - track source for diagnostics
    $script:ConfigSource = @{}
    if ($configResults) {
        foreach ($row in $configResults) {
            switch ($row.setting_name) {
                "AGName"                                { $script:Config.AGName = $row.setting_value; $script:ConfigSource.AGName = 'GlobalConfig' }
                "SourceReplica"                         { $script:Config.SourceReplica = $row.setting_value; $script:ConfigSource.SourceReplica = 'GlobalConfig' }
                "pmt_alerting_enabled"                  { $script:Config.PMT_AlertingEnabled = [bool][int]$row.setting_value; $script:ConfigSource.PMT_AlertingEnabled = 'GlobalConfig' }
                "pmt_lookback_days"                     { $script:Config.PMT_LookbackDays = [int]$row.setting_value; $script:ConfigSource.PMT_LookbackDays = 'GlobalConfig' }
                "pmt_alert_import_failed_routing"       { $script:Config.PMT_Alert_ImportFailed = [int]$row.setting_value; $script:ConfigSource.PMT_Alert_ImportFailed = 'GlobalConfig' }
                "pmt_alert_failed_routing"              { $script:Config.PMT_Alert_Failed = [int]$row.setting_value; $script:ConfigSource.PMT_Alert_Failed = 'GlobalConfig' }
                "pmt_alert_partial_routing"             { $script:Config.PMT_Alert_Partial = [int]$row.setting_value; $script:ConfigSource.PMT_Alert_Partial = 'GlobalConfig' }
                "pmt_alert_reversal_failed_routing"     { $script:Config.PMT_Alert_ReversalFailed = [int]$row.setting_value; $script:ConfigSource.PMT_Alert_ReversalFailed = 'GlobalConfig' }
            }
        }
    }

    # Tag any settings not loaded from GlobalConfig as defaults
    foreach ($key in @($script:Config.Keys)) {
        if (-not $script:ConfigSource.ContainsKey($key)) {
            $script:ConfigSource[$key] = 'default'
        }
    }

    $gcCount = ($script:ConfigSource.Values | Where-Object { $_ -eq 'GlobalConfig' }).Count
    $dfCount = ($script:ConfigSource.Values | Where-Object { $_ -eq 'default' }).Count
    Write-Log "  Config loaded: $gcCount from GlobalConfig, $dfCount from script defaults" "INFO"

    Write-Log "  AGName: $($script:Config.AGName) ($($script:ConfigSource.AGName))" "INFO"
    Write-Log "  SourceReplica: $($script:Config.SourceReplica) ($($script:ConfigSource.SourceReplica))" "INFO"
    Write-Log "  PMT_AlertingEnabled: $($script:Config.PMT_AlertingEnabled) ($($script:ConfigSource.PMT_AlertingEnabled))" "INFO"
    Write-Log "  PMT_LookbackDays: $($script:Config.PMT_LookbackDays) ($($script:ConfigSource.PMT_LookbackDays))" "INFO"
    Write-Log "  PMT_Alert_ImportFailed: $($script:Config.PMT_Alert_ImportFailed) ($($script:ConfigSource.PMT_Alert_ImportFailed))" "INFO"
    Write-Log "  PMT_Alert_Failed: $($script:Config.PMT_Alert_Failed) ($($script:ConfigSource.PMT_Alert_Failed))" "INFO"
    Write-Log "  PMT_Alert_Partial: $($script:Config.PMT_Alert_Partial) ($($script:ConfigSource.PMT_Alert_Partial))" "INFO"
    Write-Log "  PMT_Alert_ReversalFailed: $($script:Config.PMT_Alert_ReversalFailed) ($($script:ConfigSource.PMT_Alert_ReversalFailed))" "INFO"

    # Set write server (always the listener)
    $script:WriteServer = $ServerInstance

    # Determine read server
    $script:ReadServer = Resolve-bat_ReadServer -AGName $script:Config.AGName -SourceReplica $script:Config.SourceReplica -ForceSourceServer $ForceSourceServer
    if (-not $script:ReadServer) {
        return $false
    }

    Write-Log "  WriteServer: $($script:WriteServer)" "INFO"

    return $true
}

<# ============================================================================
   FUNCTIONS: COLLECTION STEPS
   ----------------------------------------------------------------------------
   The collect, update, alert-evaluation, and status-update steps executed against
   tracked PMT batches.
   Prefix: bat
   ============================================================================ #>

# Discovers new PMT batches (all types) in DM not yet tracked in xFACts and inserts them.
function Step-bat_PMT_CollectNewBatches {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect New Batches" "STEP"

    $newBatchCount = 0

    try {
        # Get list of batch IDs already tracked
        $trackedQuery = "SELECT batch_id FROM BatchOps.PMT_BatchTracking"
        $trackedBatches = Get-SqlData -Query $trackedQuery

        $trackedIds = @()
        if ($trackedBatches) {
            $trackedIds = @($trackedBatches | ForEach-Object { $_.batch_id })
        }

        # Query DM for all batches within lookback window
        $lookbackDays = $script:Config.PMT_LookbackDays

        $sourceQuery = @"
            SELECT
                cpb.cnsmr_pymnt_btch_id,
                cpb.cnsmr_pymnt_btch_nm,
                cpb.cnsmr_pymnt_btch_extrnl_nm,
                cpb.cnsmr_pymnt_btch_file_registry_id,
                cpb.cnsmr_pymnt_btch_typ_cd,
                rpt.pymnt_btch_typ_val_txt,
                cpb.cnsmr_pymnt_btch_auto_post_flg,
                cpb.cnsmr_pymnt_btch_orgnl_id,
                cpb.cnsmr_pymnt_btch_crt_usrid,
                cpb.cnsmr_pymnt_btch_assgnd_usrid,
                cpb.cnsmr_pymnt_btch_stts_cd,
                rpbs.pymnt_btch_stts_val_txt AS batch_status_txt,
                cpb.cnsmr_pymnt_btch_crt_dttm,
                cpb.cnsmr_pymnt_btch_rlsd_dttm,
                cpb.cnsmr_pymnt_btch_prcssd_dttm,
                cpb.cnsmr_pymnt_btch_rvrsl_dt,
                cpb.cnsmr_pymnt_btch_pymnt_cnt_nmbr,
                cpb.cnsmr_pymnt_btch_imprtd_rec_cnt,
                cpb.cnsmr_pymnt_btch_actv_rec_cnt,
                cpb.cnsmr_pymnt_btch_pstd_rec_cnt,
                cpb.cnsmr_pymnt_btch_sspns_rec_cnt,
                cpb.cnsmr_pymnt_btch_pymnt_ttl_amnt,
                cpb.cnsmr_pymnt_btch_actv_pymnt_ttl_amnt,
                cpb.cnsmr_pymnt_btch_pstd_pymnt_ttl_amnt,
                cpb.cnsmr_pymnt_btch_sspns_pymnt_ttl_amnt,
                cpb.upsrt_dttm
            FROM dbo.cnsmr_pymnt_btch cpb
            INNER JOIN dbo.Ref_pymnt_btch_stts_cd rpbs
                ON cpb.cnsmr_pymnt_btch_stts_cd = rpbs.pymnt_btch_stts_cd
            INNER JOIN dbo.Ref_pymnt_btch_typ_cd rpt
                ON cpb.cnsmr_pymnt_btch_typ_cd = rpt.pymnt_btch_typ_cd
            WHERE cpb.cnsmr_pymnt_btch_crt_dttm >= DATEADD(DAY, -$lookbackDays, GETDATE())
"@

        $sourceBatches = Get-bat_SourceData -Query $sourceQuery

        if (-not $sourceBatches) {
            Write-Log "  No source batches returned (or query failed)" "WARN"
            return @{ NewBatches = 0 }
        }

        # Filter to only new batches
        $newBatches = @($sourceBatches | Where-Object { $trackedIds -notcontains $_.cnsmr_pymnt_btch_id })

        if ($newBatches.Count -eq 0) {
            Write-Log "  No new batches to collect" "INFO"
            return @{ NewBatches = 0 }
        }

        Write-Log "  Found $($newBatches.Count) new batch(es)" "INFO"

        foreach ($batch in $newBatches) {
            $batchId = $batch.cnsmr_pymnt_btch_id
            $batchStatusCd = $batch.cnsmr_pymnt_btch_stts_cd

            # Determine terminal state at insert time
            # Terminal: POSTED (4), FAILED (6), IMPORTFAILED (11), REVERSALFAILED (27)
            # Note: PARTIAL (5) is NOT terminal - batches can be re-fired back to INPROCESS
            $isComplete = 0
            $completedStatus = "NULL"
            $completedDttm = "NULL"

            if ($batchStatusCd -in @(4, 6, 27)) {
                $isComplete = 1
                if ($batchStatusCd -eq 4) {
                    # POSTED - use processed timestamp
                    $completedStatus = "'POSTED'"
                    if ($batch.cnsmr_pymnt_btch_prcssd_dttm -is [DBNull]) {
                        $completedDttm = "'" + $batch.upsrt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"
                    }
                    else {
                        $completedDttm = "'" + $batch.cnsmr_pymnt_btch_prcssd_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"
                    }
                }
                elseif ($batchStatusCd -eq 6) {
                    $completedStatus = "'FAILED'"
                    $completedDttm = "'" + $batch.upsrt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"
                }
                elseif ($batchStatusCd -eq 11) {
                    $completedStatus = "'IMPORTFAILED'"
                    $completedDttm = "'" + $batch.upsrt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"
                }
                elseif ($batchStatusCd -eq 27) {
                    $completedStatus = "'REVERSALFAILED'"
                    $completedDttm = "'" + $batch.upsrt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"
                }
            }

            # Safe string values
            $batchNameSafe = if ($batch.cnsmr_pymnt_btch_nm -is [DBNull]) { "NULL" } else { "'" + ($batch.cnsmr_pymnt_btch_nm -replace "'", "''").Trim() + "'" }
            $externalNameSafe = if ($batch.cnsmr_pymnt_btch_extrnl_nm -is [DBNull]) { "NULL" } else { "'" + ($batch.cnsmr_pymnt_btch_extrnl_nm -replace "'", "''") + "'" }
            $fileRegId = if ($batch.cnsmr_pymnt_btch_file_registry_id -is [DBNull]) { "NULL" } else { $batch.cnsmr_pymnt_btch_file_registry_id }
            $batchTypeCd = if ($batch.cnsmr_pymnt_btch_typ_cd -is [DBNull]) { "NULL" } else { $batch.cnsmr_pymnt_btch_typ_cd }
            $batchTypeTxt = if ($batch.pymnt_btch_typ_val_txt -is [DBNull]) { "NULL" } else { "'" + ($batch.pymnt_btch_typ_val_txt -replace "'", "''") + "'" }
            $isAutoPost = if ($batch.cnsmr_pymnt_btch_auto_post_flg -eq 'Y') { 1 } else { 0 }
            $origBatchId = if ($batch.cnsmr_pymnt_btch_orgnl_id -is [DBNull]) { "NULL" } else { $batch.cnsmr_pymnt_btch_orgnl_id }
            $crtUserId = if ($batch.cnsmr_pymnt_btch_crt_usrid -is [DBNull]) { "NULL" } else { $batch.cnsmr_pymnt_btch_crt_usrid }
            $asgnUserId = if ($batch.cnsmr_pymnt_btch_assgnd_usrid -is [DBNull]) { "NULL" } else { $batch.cnsmr_pymnt_btch_assgnd_usrid }
            $batchStatusTxt = "'" + ($batch.batch_status_txt -replace "'", "''") + "'"

            # Datetime values
            $crtDttm = if ($batch.cnsmr_pymnt_btch_crt_dttm -is [DBNull]) { "NULL" } else { "'" + $batch.cnsmr_pymnt_btch_crt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $rlsDttm = if ($batch.cnsmr_pymnt_btch_rlsd_dttm -is [DBNull]) { "NULL" } else { "'" + $batch.cnsmr_pymnt_btch_rlsd_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $prcssdDttm = if ($batch.cnsmr_pymnt_btch_prcssd_dttm -is [DBNull]) { "NULL" } else { "'" + $batch.cnsmr_pymnt_btch_prcssd_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $rvslDt = if ($batch.cnsmr_pymnt_btch_rvrsl_dt -is [DBNull]) { "NULL" } else { "'" + $batch.cnsmr_pymnt_btch_rvrsl_dt.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }

            # Numeric values (nullable) - explicit [string] cast on decimals to prevent DBNull op_Multiply errors
            $pymntCnt = if ($batch.cnsmr_pymnt_btch_pymnt_cnt_nmbr -is [DBNull]) { "NULL" } else { [string]$batch.cnsmr_pymnt_btch_pymnt_cnt_nmbr }
            $imprtdCnt = if ($batch.cnsmr_pymnt_btch_imprtd_rec_cnt -is [DBNull]) { "NULL" } else { [string]$batch.cnsmr_pymnt_btch_imprtd_rec_cnt }
            $actvCnt = if ($batch.cnsmr_pymnt_btch_actv_rec_cnt -is [DBNull]) { "NULL" } else { [string]$batch.cnsmr_pymnt_btch_actv_rec_cnt }
            $pstdCnt = if ($batch.cnsmr_pymnt_btch_pstd_rec_cnt -is [DBNull]) { "NULL" } else { [string]$batch.cnsmr_pymnt_btch_pstd_rec_cnt }
            $sspnsCnt = if ($batch.cnsmr_pymnt_btch_sspns_rec_cnt -is [DBNull]) { "NULL" } else { [string]$batch.cnsmr_pymnt_btch_sspns_rec_cnt }
            $pymntAmt = if ($batch.cnsmr_pymnt_btch_pymnt_ttl_amnt -is [DBNull]) { "NULL" } else { [string]$batch.cnsmr_pymnt_btch_pymnt_ttl_amnt }
            $actvAmt = if ($batch.cnsmr_pymnt_btch_actv_pymnt_ttl_amnt -is [DBNull]) { "NULL" } else { [string]$batch.cnsmr_pymnt_btch_actv_pymnt_ttl_amnt }
            $pstdAmt = if ($batch.cnsmr_pymnt_btch_pstd_pymnt_ttl_amnt -is [DBNull]) { "NULL" } else { [string]$batch.cnsmr_pymnt_btch_pstd_pymnt_ttl_amnt }
            $sspnsAmt = if ($batch.cnsmr_pymnt_btch_sspns_pymnt_ttl_amnt -is [DBNull]) { "NULL" } else { [string]$batch.cnsmr_pymnt_btch_sspns_pymnt_ttl_amnt }

            # Display name for logging
            $displayName = if ($batch.cnsmr_pymnt_btch_nm -is [DBNull]) { "batch $batchId" } else { ($batch.cnsmr_pymnt_btch_nm -replace "'", "''").Trim() }

            if ($PreviewOnly) {
                $statusInfo = if ($isComplete -eq 1) { "COMPLETE ($($completedStatus -replace "'", ''))" } else { $batch.batch_status_txt }
                Write-Log "  [Preview] Would insert batch $batchId ($displayName) - $statusInfo" "INFO"
            }
            else {
                $insertQuery = @"
                    INSERT INTO BatchOps.PMT_BatchTracking (
                        batch_id, batch_name, external_name, file_registry_id,
                        batch_type_code, batch_type, is_auto_post,
                        original_batch_id, created_by_userid, assigned_userid,
                        batch_status_code, batch_status,
                        batch_created_dttm, released_dttm, processed_dttm, reversal_dttm,
                        payment_count, imported_count, active_count, posted_count, suspense_count,
                        payment_total_amt, active_total_amt, posted_total_amt, suspense_total_amt,
                        is_complete, completed_dttm, completed_status,
                        stall_poll_count, alert_count, last_polled_dttm
                    )
                    VALUES (
                        $batchId, $batchNameSafe, $externalNameSafe, $fileRegId,
                        $batchTypeCd, $batchTypeTxt, $isAutoPost,
                        $origBatchId, $crtUserId, $asgnUserId,
                        $batchStatusCd, $batchStatusTxt,
                        $crtDttm, $rlsDttm, $prcssdDttm, $rvslDt,
                        $pymntCnt, $imprtdCnt, $actvCnt, $pstdCnt, $sspnsCnt,
                        $pymntAmt, $actvAmt, $pstdAmt, $sspnsAmt,
                        $isComplete, $completedDttm, $completedStatus,
                        0, 0, GETDATE()
                    )
"@

                $result = Invoke-SqlNonQuery -Query $insertQuery
                if ($result) {
                    $newBatchCount++
                    Write-Log "  Inserted batch $batchId ($displayName)" "SUCCESS"
                }
                else {
                    Write-Log "  Failed to insert batch $batchId ($displayName)" "ERROR"
                }
            }
        }

        if ($PreviewOnly) {
            $newBatchCount = $newBatches.Count
        }

        Write-Log "  New batches collected: $newBatchCount" "INFO"
        return @{ NewBatches = $newBatchCount }
    }
    catch {
        Write-Log "  Error in Collect New Batches: $($_.Exception.Message)" "ERROR"
        return @{ NewBatches = 0; Error = $_.Exception.Message }
    }
}

# Updates all incomplete tracked batches with current DM state and detects hard deletes.
function Step-bat_PMT_UpdateIncompleteBatches {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Update Incomplete Batches" "STEP"

    $batchesUpdated = 0
    $batchesCompleted = 0
    $batchesDeleted = 0

    try {
        # Get all incomplete batches from tracking table
        $incompleteQuery = @"
            SELECT tracking_id, batch_id, batch_name, last_log_id, stall_poll_count,
                   batch_type_code, journal_posted_count, completed_status, alert_count
            FROM BatchOps.PMT_BatchTracking
            WHERE is_complete = 0
"@

        $incompleteBatches = Get-SqlData -Query $incompleteQuery

        if (-not $incompleteBatches) {
            Write-Log "  No incomplete batches to update" "INFO"
            return @{ Updated = 0; Completed = 0; Deleted = 0 }
        }

        $batchCount = @($incompleteBatches).Count
        Write-Log "  Found $batchCount incomplete batch(es)" "INFO"

        foreach ($tracking in @($incompleteBatches)) {
            $batchId = $tracking.batch_id
            $batchName = if ($tracking.batch_name -is [DBNull]) { "batch $batchId" } else { $tracking.batch_name }
            $currentLogId = if ($tracking.last_log_id -is [DBNull]) { $null } else { $tracking.last_log_id }
            $currentStallCount = $tracking.stall_poll_count
            $batchTypeCode = if ($tracking.batch_type_code -is [DBNull]) { $null } else { $tracking.batch_type_code }
            $currentJournalPosted = if ($tracking.journal_posted_count -is [DBNull]) { $null } else { $tracking.journal_posted_count }

            # Query DM for current batch state
            $batchQuery = @"
                SELECT
                    cpb.cnsmr_pymnt_btch_stts_cd,
                    rpbs.pymnt_btch_stts_val_txt AS batch_status_txt,
                    cpb.cnsmr_pymnt_btch_rlsd_dttm,
                    cpb.cnsmr_pymnt_btch_prcssd_dttm,
                    cpb.cnsmr_pymnt_btch_rvrsl_dt,
                    cpb.cnsmr_pymnt_btch_pymnt_cnt_nmbr,
                    cpb.cnsmr_pymnt_btch_imprtd_rec_cnt,
                    cpb.cnsmr_pymnt_btch_actv_rec_cnt,
                    cpb.cnsmr_pymnt_btch_pstd_rec_cnt,
                    cpb.cnsmr_pymnt_btch_sspns_rec_cnt,
                    cpb.cnsmr_pymnt_btch_pymnt_ttl_amnt,
                    cpb.cnsmr_pymnt_btch_actv_pymnt_ttl_amnt,
                    cpb.cnsmr_pymnt_btch_pstd_pymnt_ttl_amnt,
                    cpb.cnsmr_pymnt_btch_sspns_pymnt_ttl_amnt
                FROM dbo.cnsmr_pymnt_btch cpb
                INNER JOIN dbo.Ref_pymnt_btch_stts_cd rpbs
                    ON cpb.cnsmr_pymnt_btch_stts_cd = rpbs.pymnt_btch_stts_cd
                WHERE cpb.cnsmr_pymnt_btch_id = $batchId
"@

            $batchState = Get-bat_SourceData -Query $batchQuery

            # Hard delete detection: batch no longer exists in DM
            if (-not $batchState) {
                Write-Log "  Batch $batchId ($batchName): no longer exists in DM - marking as DELETED" "WARN"

                if ($PreviewOnly) {
                    Write-Log "  [Preview] Would mark batch $batchId as DELETED (hard delete)" "INFO"
                    $batchesDeleted++
                }
                else {
                    $deleteQuery = @"
                        UPDATE BatchOps.PMT_BatchTracking
                        SET is_complete = 1,
                            completed_dttm = GETDATE(),
                            completed_status = 'DELETED',
                            last_polled_dttm = GETDATE()
                        WHERE batch_id = $batchId
"@
                    $result = Invoke-SqlNonQuery -Query $deleteQuery
                    if ($result) {
                        $batchesDeleted++
                        Write-Log "  Batch $batchId ($batchName): marked DELETED" "SUCCESS"
                    }
                    else {
                        Write-Log "  Batch $batchId ($batchName): failed to mark DELETED" "ERROR"
                    }
                }
                continue
            }

            # Query log table for activity
            $logQuery = @"
                SELECT
                    MAX(cnsmr_pymnt_btch_log_id) AS max_log_id,
                    MAX(cnsmr_pymnt_btch_log_dttm) AS max_log_dttm
                FROM dbo.cnsmr_pymnt_btch_log
                WHERE cnsmr_pymnt_btch_id = $batchId
"@

            $logData = Get-bat_SourceData -Query $logQuery

            # Extract values
            $batchStatusCd = $batchState.cnsmr_pymnt_btch_stts_cd
            $batchStatusTxt = ($batchState.batch_status_txt -replace "'", "''").Trim()

            # Datetime values
            $rlsDttm = if ($batchState.cnsmr_pymnt_btch_rlsd_dttm -is [DBNull]) { "NULL" } else { "'" + $batchState.cnsmr_pymnt_btch_rlsd_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $prcssdDttm = if ($batchState.cnsmr_pymnt_btch_prcssd_dttm -is [DBNull]) { "NULL" } else { "'" + $batchState.cnsmr_pymnt_btch_prcssd_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $rvslDt = if ($batchState.cnsmr_pymnt_btch_rvrsl_dt -is [DBNull]) { "NULL" } else { "'" + $batchState.cnsmr_pymnt_btch_rvrsl_dt.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }

            # Metrics - explicit [string] cast on decimals to prevent DBNull op_Multiply errors
            $pymntCnt = if ($batchState.cnsmr_pymnt_btch_pymnt_cnt_nmbr -is [DBNull]) { "NULL" } else { [string]$batchState.cnsmr_pymnt_btch_pymnt_cnt_nmbr }
            $imprtdCnt = if ($batchState.cnsmr_pymnt_btch_imprtd_rec_cnt -is [DBNull]) { "NULL" } else { [string]$batchState.cnsmr_pymnt_btch_imprtd_rec_cnt }
            $actvCnt = if ($batchState.cnsmr_pymnt_btch_actv_rec_cnt -is [DBNull]) { "NULL" } else { [string]$batchState.cnsmr_pymnt_btch_actv_rec_cnt }
            $pstdCnt = if ($batchState.cnsmr_pymnt_btch_pstd_rec_cnt -is [DBNull]) { "NULL" } else { [string]$batchState.cnsmr_pymnt_btch_pstd_rec_cnt }
            $sspnsCnt = if ($batchState.cnsmr_pymnt_btch_sspns_rec_cnt -is [DBNull]) { "NULL" } else { [string]$batchState.cnsmr_pymnt_btch_sspns_rec_cnt }
            $pymntAmt = if ($batchState.cnsmr_pymnt_btch_pymnt_ttl_amnt -is [DBNull]) { "NULL" } else { [string]$batchState.cnsmr_pymnt_btch_pymnt_ttl_amnt }
            $actvAmt = if ($batchState.cnsmr_pymnt_btch_actv_pymnt_ttl_amnt -is [DBNull]) { "NULL" } else { [string]$batchState.cnsmr_pymnt_btch_actv_pymnt_ttl_amnt }
            $pstdAmt = if ($batchState.cnsmr_pymnt_btch_pstd_pymnt_ttl_amnt -is [DBNull]) { "NULL" } else { [string]$batchState.cnsmr_pymnt_btch_pstd_pymnt_ttl_amnt }
            $sspnsAmt = if ($batchState.cnsmr_pymnt_btch_sspns_pymnt_ttl_amnt -is [DBNull]) { "NULL" } else { [string]$batchState.cnsmr_pymnt_btch_sspns_pymnt_ttl_amnt }

            # Log data
            $newLogId = if (-not $logData -or $logData.max_log_id -is [DBNull]) { $null } else { $logData.max_log_id }
            $maxLogDttm = if (-not $logData -or $logData.max_log_dttm -is [DBNull]) { "NULL" } else { "'" + $logData.max_log_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }

            # Journal query - any batch in INPROCESS or terminal state
            # Provides real-time posted/failed counts (header doesn't update during processing)
            # Covers: INPROCESS(3), POSTED(4), PARTIAL(5), FAILED(6), REVERSALFAILED(27)
            $jrnlPostedCnt = "NULL"
            $jrnlFailedCnt = "NULL"
            $lastPostedDttm = "NULL"
            $newJournalPosted = $null

            if ($batchStatusCd -in @(3, 4, 5, 6, 27)) {
                $journalQuery = @"
                    SELECT
                        COUNT(CASE WHEN cnsmr_pymnt_stts_cd = 5 THEN 1 END) AS posted_count,
                        COUNT(CASE WHEN cnsmr_pymnt_stts_cd = 4 THEN 1 END) AS failed_count,
                        MAX(CASE WHEN cnsmr_pymnt_stts_cd = 5 THEN upsrt_dttm END) AS last_posted_dttm
                    FROM dbo.cnsmr_pymnt_jrnl
                    WHERE cnsmr_pymnt_btch_id = $batchId
"@

                $journalData = Get-bat_SourceData -Query $journalQuery

                if ($journalData) {
                    $newJournalPosted = if ($journalData.posted_count -is [DBNull]) { 0 } else { $journalData.posted_count }
                    $jrnlPostedCnt = [string]$newJournalPosted
                    $jrnlFailedCnt = if ($journalData.failed_count -is [DBNull]) { "0" } else { [string]$journalData.failed_count }
                    $lastPostedDttm = if ($journalData.last_posted_dttm -is [DBNull]) { "NULL" } else { "'" + $journalData.last_posted_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
                }
            }

            # Stall detection logic - IMPORT batches only (type_code = 3)
            # Manual and other batch types have unpredictable lifecycles
            if ($batchTypeCode -eq 3) {
                if ($batchStatusCd -eq 3 -and $null -ne $newJournalPosted) {
                    # INPROCESS: use journal_posted_count delta for stall detection
                    if ($null -ne $currentJournalPosted -and $newJournalPosted -eq $currentJournalPosted) {
                        $newStallCount = $currentStallCount + 1
                    }
                    else {
                        $newStallCount = 0
                    }
                }
                else {
                    # Non-INPROCESS phases: use log_id for stall detection
                    if ($null -eq $newLogId) {
                        $newStallCount = $currentStallCount
                    }
                    elseif ($null -ne $currentLogId -and $newLogId -eq $currentLogId) {
                        $newStallCount = $currentStallCount + 1
                    }
                    else {
                        $newStallCount = 0
                    }
                }
            }
            else {
                # Non-IMPORT: no stall tracking
                $newStallCount = 0
            }
            $lastLogIdSql = if ($null -eq $newLogId) { "NULL" } else { $newLogId }

            # Terminal state detection
            # Terminal: POSTED (4), FAILED (6), IMPORTFAILED (11), REVERSALFAILED (27)
            # Note: PARTIAL (5) is NOT terminal - batches can be re-fired back to INPROCESS
            $isComplete = 0
            $completedDttm = "NULL"
            $completedStatus = "NULL"
            $alertCountReset = $null

            if ($batchStatusCd -in @(4, 6, 11, 27)) {
                $isComplete = 1
                if ($batchStatusCd -eq 4) {
                    $completedStatus = "'POSTED'"
                    $completedDttm = if ($batchState.cnsmr_pymnt_btch_prcssd_dttm -is [DBNull]) { "GETDATE()" } else { "'" + $batchState.cnsmr_pymnt_btch_prcssd_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
                }
                elseif ($batchStatusCd -eq 6) {
                    $completedStatus = "'FAILED'"
                    $completedDttm = "GETDATE()"
                }
                elseif ($batchStatusCd -eq 11) {
                    $completedStatus = "'IMPORTFAILED'"
                    $completedDttm = "GETDATE()"
                }
                elseif ($batchStatusCd -eq 27) {
                    $completedStatus = "'REVERSALFAILED'"
                    $completedDttm = "GETDATE()"
                }
            }

            # Recovery detection: batch was PARTIAL but has been re-fired
            # Reset completed fields and alert_count so fresh alerts can fire if it fails again
            $currentCompletedStatus = if ($tracking.completed_status -is [DBNull]) { $null } else { $tracking.completed_status }
            $currentAlertCount = if ($tracking.alert_count -is [DBNull]) { 0 } else { $tracking.alert_count }

            if ($currentCompletedStatus -eq 'PARTIAL' -and $batchStatusCd -notin @(5)) {
                # Batch was PARTIAL but is now back in a non-PARTIAL state (likely INPROCESS)
                $completedStatus = "NULL"
                $completedDttm = "NULL"
                $alertCountReset = 0
                Write-Log "  Batch $batchId ($batchName): recovered from PARTIAL -> $batchStatusTxt (resetting alert_count)" "SUCCESS"
            }

            if ($PreviewOnly) {
                $statusDesc = "$batchStatusTxt"
                if ($isComplete -eq 1) { $statusDesc += " -> COMPLETE" }
                if ($null -ne $newJournalPosted) { $statusDesc += " (journal: $newJournalPosted posted)" }
                if ($newStallCount -gt 0) { $statusDesc += " (stall: $newStallCount)" }
                Write-Log "  [Preview] Would update batch $batchId ($batchName): $statusDesc" "INFO"
                $batchesUpdated++
                if ($isComplete -eq 1) { $batchesCompleted++ }
            }
            else {
                $updateQuery = @"
                    UPDATE BatchOps.PMT_BatchTracking
                    SET batch_status_code    = $batchStatusCd,
                        batch_status         = '$batchStatusTxt',
                        released_dttm        = $rlsDttm,
                        processed_dttm       = $prcssdDttm,
                        reversal_dttm        = $rvslDt,
                        payment_count        = $pymntCnt,
                        imported_count       = $imprtdCnt,
                        active_count         = $actvCnt,
                        posted_count         = $pstdCnt,
                        suspense_count       = $sspnsCnt,
                        payment_total_amt    = $pymntAmt,
                        active_total_amt     = $actvAmt,
                        posted_total_amt     = $pstdAmt,
                        suspense_total_amt   = $sspnsAmt,
                        last_log_id          = $lastLogIdSql,
                        last_log_dttm        = $maxLogDttm,
                        journal_posted_count = $jrnlPostedCnt,
                        journal_failed_count = $jrnlFailedCnt,
                        last_posted_dttm     = $lastPostedDttm,
                        stall_poll_count     = $newStallCount,
                        is_complete          = $isComplete,
                        completed_dttm       = $(if ($completedDttm -eq 'NULL') { 'NULL' } else { $completedDttm }),
                        completed_status     = $(if ($completedStatus -eq 'NULL') { 'NULL' } else { $completedStatus }),
                        alert_count          = $(if ($null -ne $alertCountReset) { $alertCountReset } else { 'alert_count' }),
                        last_polled_dttm     = GETDATE()
                    WHERE batch_id = $batchId
"@

                $result = Invoke-SqlNonQuery -Query $updateQuery
                if ($result) {
                    $batchesUpdated++
                    if ($isComplete -eq 1) {
                        $batchesCompleted++
                        Write-Log "  Batch $batchId ($batchName): COMPLETED ($batchStatusTxt)" "SUCCESS"
                    }
                    else {
                        $logMsg = "  Batch $batchId ($batchName): updated"
                        if ($null -ne $newJournalPosted) { $logMsg += " (journal: $newJournalPosted posted)" }
                        if ($newStallCount -gt 0) { $logMsg += " (stall: $newStallCount)" }
                        Write-Log $logMsg "DEBUG"
                    }
                }
                else {
                    Write-Log "  Batch $batchId ($batchName): update failed" "ERROR"
                }
            }
        }

        Write-Log "  Batches updated: $batchesUpdated, Completed: $batchesCompleted, Hard deleted: $batchesDeleted" "INFO"
        return @{ Updated = $batchesUpdated; Completed = $batchesCompleted; Deleted = $batchesDeleted }
    }
    catch {
        Write-Log "  Error in Update Incomplete Batches: $($_.Exception.Message)" "ERROR"
        return @{ Updated = $batchesUpdated; Completed = $batchesCompleted; Deleted = $batchesDeleted; Error = $_.Exception.Message }
    }
}

# Evaluates the PMT terminal-failure alert conditions and routes alerts to Jira and/or Teams.
function Step-bat_PMT_EvaluateAlerts {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Evaluate Alert Conditions" "STEP"

    $alertsDetected = 0
    $alertsFired = 0

    try {
        if (-not $script:Config.PMT_AlertingEnabled) {
            Write-Log "  Alerting is DISABLED (pmt_alerting_enabled = 0)" "INFO"
        }

        # CHECK 1: Import Failed (batch_status_code = 11)
        # Terminal failure - one alert per batch
        $routing = $script:Config.PMT_Alert_ImportFailed

        $importFailedQuery = @"
            SELECT batch_id, batch_name, external_name, batch_type,
                   payment_count, batch_created_dttm, alert_count
            FROM BatchOps.PMT_BatchTracking
            WHERE batch_status_code = 11
              AND alert_count = 0
"@

        $importFailures = Get-SqlData -Query $importFailedQuery

        if ($importFailures) {
            foreach ($batch in @($importFailures)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = if ($batch.batch_name -isnot [DBNull]) { $batch.batch_name } else { "batch $batchId" }
                Write-Log "  ALERT: Import failure detected - batch $batchId ($batchName)" "WARN"

                if ($script:Config.PMT_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $externalName = if ($batch.external_name -isnot [DBNull]) { $batch.external_name } else { 'N/A' }
                    $pymntCount = if ($batch.payment_count -isnot [DBNull]) { $batch.payment_count } else { 0 }
                    $triggerType = 'PMT_ImportFailed'
                    $triggerValue = "$batchId"
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                    # Error extraction placeholder - pending confirmation that
                    # cnsmr_pymnt_btch_log contains actionable error messages
                    $errorSection = "Check Debt Manager batch log for error details."

                    # Jira ticket (routing 2 or 3)
                    $jiraSummary = "Payment Batch Import Failed: $batchId"
                    $jiraDesc = @"
Payment Batch Import Failed

Batch ID: $batchId
Batch Name: $batchName
External File: $externalName
Payment Count: $pymntCount

$errorSection

Action: Review the failed import in Debt Manager and re-import if appropriate.

Detection Date: $detectionTime
"@
                    $teamsTitle = "{{FIRE}} Payment Batch Import Failed: $batchId"
                    $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**External File:** $externalName
**Payment Count:** $pymntCount
**Created:** $(if ($batch.batch_created_dttm -isnot [DBNull]) { $batch.batch_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' })

$errorSection

Action: Review the failed import in Debt Manager and re-import if appropriate.

**Detection:** $detectionTime
"@
                    Send-bat_BatchAlert -Routing $routing -TriggerType $triggerType -TriggerValue $triggerValue -CascadingChild 'Payment File Issue' `
                        -JiraSummary $jiraSummary -JiraDescription $jiraDesc `
                        -TeamsTitle $teamsTitle -TeamsMessage $teamsMessage -TeamsCategory 'CRITICAL' -TeamsColor 'attention'

                    # Increment alert_count
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.PMT_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }

        # CHECK 2: Failed (batch_status_code = 6)
        # Terminal failure - one alert per batch
        $routing = $script:Config.PMT_Alert_Failed

        $failedQuery = @"
            SELECT batch_id, batch_name, batch_type, external_name,
                   active_count, posted_count, journal_posted_count,
                   journal_failed_count, payment_count,
                   batch_created_dttm, released_dttm, alert_count
            FROM BatchOps.PMT_BatchTracking
            WHERE batch_status_code = 6
              AND alert_count = 0
"@

        $failures = Get-SqlData -Query $failedQuery

        if ($failures) {
            foreach ($batch in @($failures)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = if ($batch.batch_name -isnot [DBNull]) { $batch.batch_name } else { "batch $batchId" }
                Write-Log "  ALERT: Batch failure detected - batch $batchId ($batchName)" "WARN"

                if ($script:Config.PMT_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $batchType = if ($batch.batch_type -isnot [DBNull]) { $batch.batch_type } else { 'Unknown' }
                    $externalName = if ($batch.external_name -isnot [DBNull]) { $batch.external_name } else { 'N/A' }
                    $pymntCount = if ($batch.payment_count -isnot [DBNull]) { $batch.payment_count } else { 0 }
                    $actvCount = if ($batch.active_count -isnot [DBNull]) { $batch.active_count } else { 0 }
                    $pstdCount = if ($batch.posted_count -isnot [DBNull]) { $batch.posted_count } else { 0 }
                    $jrnlPosted = if ($batch.journal_posted_count -isnot [DBNull]) { $batch.journal_posted_count } else { 'N/A' }
                    $jrnlFailed = if ($batch.journal_failed_count -isnot [DBNull]) { $batch.journal_failed_count } else { 'N/A' }
                    $triggerType = 'PMT_Failed'
                    $triggerValue = "$batchId"
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                    # Jira ticket (routing 2 or 3)
                    $jiraSummary = "Payment Batch Failed: $batchId"
                    $jiraDesc = @"
Payment Batch Processing Failed

Batch ID: $batchId
Batch Name: $batchName
Batch Type: $batchType
External File: $externalName
Payment Count: $pymntCount
Active: $actvCount | Posted (header): $pstdCount | Posted (journal): $jrnlPosted | Failed (journal): $jrnlFailed

Action: Review the failed batch in Debt Manager and determine corrective action.

Detection Date: $detectionTime
"@
                    $teamsTitle = "{{FIRE}} Payment Batch Failed: $batchId"
                    $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**Batch Type:** $batchType
**External File:** $externalName
**Payment Count:** $pymntCount
**Active:** $actvCount | **Posted (header):** $pstdCount | **Posted (journal):** $jrnlPosted | **Failed (journal):** $jrnlFailed
**Created:** $(if ($batch.batch_created_dttm -isnot [DBNull]) { $batch.batch_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' })
**Released:** $(if ($batch.released_dttm -isnot [DBNull]) { $batch.released_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' })

Action: Review the failed batch in Debt Manager and determine corrective action.

**Detection:** $detectionTime
"@
                    Send-bat_BatchAlert -Routing $routing -TriggerType $triggerType -TriggerValue $triggerValue -CascadingChild 'Payment File Issue' `
                        -JiraSummary $jiraSummary -JiraDescription $jiraDesc `
                        -TeamsTitle $teamsTitle -TeamsMessage $teamsMessage -TeamsCategory 'CRITICAL' -TeamsColor 'attention'

                    # Increment alert_count
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.PMT_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }

        # CHECK 3: Partial (batch_status_code = 5)
        # Some payments posted, some failed - one alert per batch
        $routing = $script:Config.PMT_Alert_Partial

        $partialQuery = @"
            SELECT batch_id, batch_name, batch_type, external_name,
                   active_count, posted_count, suspense_count,
                   journal_posted_count, journal_failed_count, payment_count,
                   batch_created_dttm, released_dttm, alert_count
            FROM BatchOps.PMT_BatchTracking
            WHERE batch_status_code = 5
              AND alert_count = 0
"@

        $partials = Get-SqlData -Query $partialQuery

        if ($partials) {
            foreach ($batch in @($partials)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = if ($batch.batch_name -isnot [DBNull]) { $batch.batch_name } else { "batch $batchId" }
                Write-Log "  ALERT: Partial failure detected - batch $batchId ($batchName)" "WARN"

                if ($script:Config.PMT_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $batchType = if ($batch.batch_type -isnot [DBNull]) { $batch.batch_type } else { 'Unknown' }
                    $externalName = if ($batch.external_name -isnot [DBNull]) { $batch.external_name } else { 'N/A' }
                    $pymntCount = if ($batch.payment_count -isnot [DBNull]) { $batch.payment_count } else { 0 }
                    $actvCount = if ($batch.active_count -isnot [DBNull]) { $batch.active_count } else { 0 }
                    $pstdCount = if ($batch.posted_count -isnot [DBNull]) { $batch.posted_count } else { 0 }
                    $sspnsCount = if ($batch.suspense_count -isnot [DBNull]) { $batch.suspense_count } else { 0 }
                    $jrnlPosted = if ($batch.journal_posted_count -isnot [DBNull]) { $batch.journal_posted_count } else { 'N/A' }
                    $jrnlFailed = if ($batch.journal_failed_count -isnot [DBNull]) { $batch.journal_failed_count } else { 'N/A' }
                    $triggerType = 'PMT_Partial'
                    $triggerValue = "$batchId"
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                    # Jira ticket (routing 2 or 3)
                    $jiraSummary = "Payment Batch Partial Failure: $batchId"
                    $jiraDesc = @"
Payment Batch Partial Failure

Batch ID: $batchId
Batch Name: $batchName
Batch Type: $batchType
External File: $externalName
Payment Count: $pymntCount
Active: $actvCount | Posted (header): $pstdCount | Suspense: $sspnsCount
Posted (journal): $jrnlPosted | Failed (journal): $jrnlFailed

Some payments failed to post. Manual intervention required to review failed payments and determine corrective action.

Detection Date: $detectionTime
"@
                    $teamsTitle = "{{WARN}} Payment Batch Partial Failure: $batchId"
                    $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**Batch Type:** $batchType
**External File:** $externalName
**Payment Count:** $pymntCount
**Active:** $actvCount | **Posted (header):** $pstdCount | **Suspense:** $sspnsCount
**Posted (journal):** $jrnlPosted | **Failed (journal):** $jrnlFailed
**Created:** $(if ($batch.batch_created_dttm -isnot [DBNull]) { $batch.batch_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' })
**Released:** $(if ($batch.released_dttm -isnot [DBNull]) { $batch.released_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' })

Some payments failed to post. Manual intervention required.

**Detection:** $detectionTime
"@
                    Send-bat_BatchAlert -Routing $routing -TriggerType $triggerType -TriggerValue $triggerValue -CascadingChild 'Payment File Issue' `
                        -JiraSummary $jiraSummary -JiraDescription $jiraDesc `
                        -TeamsTitle $teamsTitle -TeamsMessage $teamsMessage -TeamsCategory 'WARNING' -TeamsColor 'warning'

                    # Increment alert_count
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.PMT_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }

        # CHECK 4: Reversal Failed (batch_status_code = 27)
        # Terminal failure - one alert per batch
        $routing = $script:Config.PMT_Alert_ReversalFailed

        $reversalFailedQuery = @"
            SELECT batch_id, batch_name, batch_type, external_name,
                   original_batch_id, active_count, posted_count,
                   journal_posted_count, payment_count,
                   batch_created_dttm, reversal_dttm, alert_count
            FROM BatchOps.PMT_BatchTracking
            WHERE batch_status_code = 27
              AND alert_count = 0
"@

        $reversalFailures = Get-SqlData -Query $reversalFailedQuery

        if ($reversalFailures) {
            foreach ($batch in @($reversalFailures)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = if ($batch.batch_name -isnot [DBNull]) { $batch.batch_name } else { "batch $batchId" }
                Write-Log "  ALERT: Reversal failure detected - batch $batchId ($batchName)" "WARN"

                if ($script:Config.PMT_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $batchType = if ($batch.batch_type -isnot [DBNull]) { $batch.batch_type } else { 'Unknown' }
                    $externalName = if ($batch.external_name -isnot [DBNull]) { $batch.external_name } else { 'N/A' }
                    $pymntCount = if ($batch.payment_count -isnot [DBNull]) { $batch.payment_count } else { 0 }
                    $actvCount = if ($batch.active_count -isnot [DBNull]) { $batch.active_count } else { 0 }
                    $pstdCount = if ($batch.posted_count -isnot [DBNull]) { $batch.posted_count } else { 0 }
                    $jrnlPosted = if ($batch.journal_posted_count -isnot [DBNull]) { $batch.journal_posted_count } else { 'N/A' }
                    $origBatchId = if ($batch.original_batch_id -isnot [DBNull]) { $batch.original_batch_id } else { 'N/A' }
                    $triggerType = 'PMT_ReversalFailed'
                    $triggerValue = "$batchId"
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                    # Jira ticket (routing 2 or 3)
                    $jiraSummary = "Payment Batch Reversal Failed: $batchId"
                    $jiraDesc = @"
Payment Batch Reversal Failed

Batch ID: $batchId
Batch Name: $batchName
Batch Type: $batchType
Original Batch ID: $origBatchId
Payment Count: $pymntCount
Active: $actvCount | Posted (header): $pstdCount | Posted (journal): $jrnlPosted

A payment batch reversal has failed. Manual intervention required to review the reversal and original batch.

Detection Date: $detectionTime
"@
                    $teamsTitle = "{{FIRE}} Payment Batch Reversal Failed: $batchId"
                    $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**Batch Type:** $batchType
**Original Batch ID:** $origBatchId
**Payment Count:** $pymntCount
**Active:** $actvCount | **Posted (header):** $pstdCount | **Posted (journal):** $jrnlPosted
**Created:** $(if ($batch.batch_created_dttm -isnot [DBNull]) { $batch.batch_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' })
**Reversal Date:** $(if ($batch.reversal_dttm -isnot [DBNull]) { $batch.reversal_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' })

A payment batch reversal has failed. Manual intervention required.

**Detection:** $detectionTime
"@
                    Send-bat_BatchAlert -Routing $routing -TriggerType $triggerType -TriggerValue $triggerValue -CascadingChild 'Payment File Issue' `
                        -JiraSummary $jiraSummary -JiraDescription $jiraDesc `
                        -TeamsTitle $teamsTitle -TeamsMessage $teamsMessage -TeamsCategory 'CRITICAL' -TeamsColor 'attention'

                    # Increment alert_count
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.PMT_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }

        # Summary
        Write-Log "  Alerts detected: $alertsDetected, Alerts fired: $alertsFired" "INFO"
        return @{ Detected = $alertsDetected; Fired = $alertsFired }
    }
    catch {
        Write-Log "  Error in Evaluate Alerts: $($_.Exception.Message)" "ERROR"
        return @{ Detected = $alertsDetected; Fired = $alertsFired; Error = $_.Exception.Message }
    }
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Orchestrates the collect/update/alert pipeline, records run status in
   BatchOps.Status, prints an operator summary, and reports completion to the
   orchestrator.
   Prefix: (none)
   ============================================================================ #>

# Capture start time for duration reporting.
$scriptStart = Get-Date

Write-Console ''
Write-Console "================================================================" Cyan
Write-Console "  xFACts PMT Batch Status Collection" Cyan
Write-Console "================================================================" Cyan
Write-Console ''

if ($Execute) {
    Write-Log "Mode: EXECUTE (changes will be applied)" "WARN"
}
else {
    Write-Log "Mode: PREVIEW (no changes will be made)" "INFO"
}

Write-Console ''

# Initialize configuration and server connections
if (-not (Initialize-bat_PMT_Configuration)) {
    Write-Log "Configuration initialization failed - exiting" "ERROR"

    if ($TaskId -gt 0) {
        $totalMs = [int]((Get-Date) - $scriptStart).TotalMilliseconds
        Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
            -TaskId $TaskId -ProcessId $ProcessId `
            -Status "FAILED" -DurationMs $totalMs `
            -ErrorMessage "Configuration initialization failed"
    }

    exit 1
}

Write-Console ''

# Preview mode unless -Execute was supplied.
$previewOnly = -not $Execute
# Accumulates per-step result objects for the summary.
$stepResults = @{}

# Mark as RUNNING
if (-not $previewOnly) {
    Set-bat_BatchStatus -CollectorName 'Collect-PMTBatchStatus' -State RUNNING
}

Write-Console "----------------------------------------------------------------" DarkGray
Write-Console "  Executing Steps" DarkGray
Write-Console "----------------------------------------------------------------" DarkGray
Write-Console ''

# Step 1: Collect new batches from DM
$stepResults.Collect = Step-bat_PMT_CollectNewBatches -PreviewOnly $previewOnly

# Step 2: Update all incomplete batches
$stepResults.Update = Step-bat_PMT_UpdateIncompleteBatches -PreviewOnly $previewOnly

# Step 3: Evaluate alert conditions
$stepResults.Alerts = Step-bat_PMT_EvaluateAlerts -PreviewOnly $previewOnly

# ============================================================================
# SUMMARY
# ============================================================================

# Capture end time for duration reporting.
$scriptEnd = Get-Date
# Total elapsed wall-clock time.
$scriptDuration = $scriptEnd - $scriptStart
# Elapsed time in milliseconds for status reporting.
$totalMs = [int]$scriptDuration.TotalMilliseconds

# Overall run status; flips to FAILED if any step errored.
$finalStatus = "SUCCESS"
if ($stepResults.Collect.Error -or $stepResults.Update.Error -or $stepResults.Alerts.Error) {
    $finalStatus = "FAILED"
}

Write-Console ''
Write-Console "================================================================" Cyan
Write-Console "  Execution Summary" Cyan
Write-Console "================================================================" Cyan
Write-Console ''
Write-Console "  Read Server:  $($script:ReadServer)"
Write-Console "  Write Server: $($script:WriteServer)"
Write-Console ''
Write-Console "  Results:"
Write-Console "    New Batches:       $($stepResults.Collect.NewBatches)"
Write-Console "    Batches Updated:   $($stepResults.Update.Updated)"
Write-Console "    Batches Completed: $($stepResults.Update.Completed)"
Write-Console "    Hard Deleted:      $($stepResults.Update.Deleted)"
Write-Console "    Alerts Detected:   $($stepResults.Alerts.Detected)"
Write-Console "    Alerts Fired:      $($stepResults.Alerts.Fired)"
Write-Console ''
Write-Console "  Duration: $totalMs ms"
Write-Console ''

if (-not $Execute) {
    Write-Console "  *** PREVIEW MODE - No changes were made ***" Yellow
    Write-Console "  Run with -Execute to perform actual updates" Yellow
    Write-Console ''
}

# Update Status table
if (-not $previewOnly) {
    Set-bat_BatchStatus -CollectorName 'Collect-PMTBatchStatus' -State IDLE -Status $finalStatus -DurationMs $totalMs
}

Write-Console "================================================================" Cyan
Write-Console "  PMT Batch Status Collection Complete" Cyan
Write-Console "================================================================" Cyan
Write-Console ''

# Orchestrator callback
if ($TaskId -gt 0) {
    $gcCount = ($script:ConfigSource.Values | Where-Object { $_ -eq 'GlobalConfig' }).Count
    $dfCount = ($script:ConfigSource.Values | Where-Object { $_ -eq 'default' }).Count
    $outputSummary = "New:$($stepResults.Collect.NewBatches) Updated:$($stepResults.Update.Updated) Completed:$($stepResults.Update.Completed) Deleted:$($stepResults.Update.Deleted) Alerts:$($stepResults.Alerts.Fired) Config:$gcCount/GC,$dfCount/Def"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}

if ($finalStatus -eq "FAILED") { exit 1 } else { exit 0 }
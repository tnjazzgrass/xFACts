<#
.SYNOPSIS
    xFACts - New Business Batch Status Collection

.DESCRIPTION
    xFACts - BatchOps
    Script: Collect-NBBatchStatus.ps1
    Version: Tracked in dbo.System_Metadata (component: BatchOps)

    Monitors Debt Manager New Business batch lifecycle from creation through
    terminal state. Collects new batches, updates status for in-flight batches,
    tracks merge log activity for stall detection, and evaluates alert conditions.

    Follows the xFACts collect/evaluate pattern:
    - Reads from configurable AG replica (PRIMARY or SECONDARY) for DM queries
    - Writes to xFACts via the AG listener for all BatchOps.* table updates
    - AG-aware: automatically detects current PRIMARY/SECONDARY roles
    - Supports preview mode for safe testing

    CHANGELOG
    ---------
    2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure
                Removed inline Write-Log, Get-xFACtsData, Invoke-xFACtsWrite
                Renamed $xFACtsServer/$xFACtsDB to $ServerInstance/$Database
                Updated header to component-level versioning format
    2026-02-17  Release-merge skip stall threshold
                CHECK 7 changed from immediate to stall-threshold-based
                Alert count resets when log activity resumes
                Stall poll count resets on RELEASING->non-RELEASING transition
    2026-02-09  Alerting implementation (7 alert conditions)
                Per-condition Jira/Teams routing via GlobalConfig
                RequestLog deduplication, error extraction for upload failures
                Added is_auto_merge, split CHECK 5 into auto-merge ON/OFF paths
    2026-02-08  Initial implementation
                NB batch lifecycle tracking, AG-aware replica reads
                Log-based stall detection, alert framework (disabled by default)
                Preview mode support, Orchestrator v2 integration

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    xFACts database name (default: xFACts)

.PARAMETER SourceDB
    Source database for Debt Manager data (default: crs5_oltp)

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER ForceSourceServer
    Override the GlobalConfig replica setting and connect to specific server for reads.
    Useful for testing or when AG detection fails.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for
    task completion callback. Default 0 (no callback when run manually).

================================================================================
DEPLOYMENT REMINDERS
================================================================================
1. This is deployed in an Availability Group - ensure this script is placed
   on both servers in the appropriate folder.
2. The service account running this script needs:
   - Read access to crs5_oltp on both DM-PROD-DB and DM-PROD-REP
   - Read/Write access to xFACts database
3. Required GlobalConfig entries:
   - Shared.AGName (default: DMPRODAG)
   - Shared.SourceReplica (PRIMARY or SECONDARY, default: SECONDARY)
   - BatchOps.nb_stall_poll_threshold (default: 6)
   - BatchOps.nb_upload_stall_minutes (default: 120)
   - BatchOps.nb_queue_wait_minutes (default: 300)
   - BatchOps.nb_alerting_enabled (default: 0)
   - BatchOps.nb_lookback_days (default: 7)
================================================================================
#>

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

# ============================================================================
# STANDARD INITIALIZATION
# ============================================================================

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

Initialize-XFActsScript -ScriptName 'Collect-NBBatchStatus' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

$Script:AGPrimary = $null
$Script:AGSecondary = $null
$Script:ReadServer = $null
$Script:WriteServer = $null
$Script:Config = @{}

# ============================================================================
# FUNCTIONS
# ============================================================================

function Get-SourceData {
    param(
        [string]$Query,
        [int]$Timeout = 60
    )

    if (-not $Script:ReadServer) {
        Write-Log "ReadServer not configured - cannot query source" "ERROR"
        return $null
    }

    try {
        Invoke-Sqlcmd -ServerInstance $Script:ReadServer -Database $SourceDB -Query $Query -QueryTimeout $Timeout -ApplicationName $script:XFActsAppName -ErrorAction Stop -SuppressProviderContextWarning -TrustServerCertificate
    }
    catch {
        Write-Log "Source query failed on $($Script:ReadServer): $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ============================================================================
# CONFIGURATION FUNCTIONS
# ============================================================================

function Get-AGReplicaRoles {
    $agName = $Script:Config.AGName

    if (-not $agName) {
        Write-Log "AGName not configured - cannot query replica states" "ERROR"
        return $null
    }

    $query = @"
        SELECT
            ar.replica_server_name,
            ars.role_desc
        FROM sys.dm_hadr_availability_replica_states ars
        INNER JOIN sys.availability_replicas ar
            ON ars.replica_id = ar.replica_id
        INNER JOIN sys.availability_groups ag
            ON ar.group_id = ag.group_id
        WHERE ag.name = '$agName'
"@

    $results = Get-SqlData -Query $query

    if (-not $results) {
        Write-Log "Failed to query AG replica states" "ERROR"
        return $null
    }

    $roles = @{
        PRIMARY = $null
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

function Initialize-Configuration {
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
    $Script:Config = @{
        AGName                              = "DMPRODAG"
        SourceReplica                       = "SECONDARY"
        NB_StallPollThreshold               = 12
        NB_ReleaseMergeSkipStallThreshold   = 6
        NB_UploadStallMinutes               = 120
        NB_QueueWaitMinutes                 = 300
        NB_QueueWaitNoMergeMinutes          = 1440
        NB_UnreleasedMinutes                = 480
        NB_AlertingEnabled                  = $false
        NB_LookbackDays                     = 7
        # Alert routing: 0=None, 1=Teams, 2=Jira, 3=Both
        NB_Alert_UploadFailed               = 3
        NB_Alert_ReleaseFailed              = 3
        NB_Alert_StalledMerge               = 3
        NB_Alert_UploadStall                = 1
        NB_Alert_QueueWait                  = 1
        NB_Alert_QueueWaitNoMerge           = 1
        NB_Alert_Unreleased                 = 1
        NB_Alert_ReleaseMergeSkip           = 3
    }

    # Override with GlobalConfig values
    if ($configResults) {
        foreach ($row in $configResults) {
            switch ($row.setting_name) {
                "AGName"                              { $Script:Config.AGName = $row.setting_value }
                "SourceReplica"                       { $Script:Config.SourceReplica = $row.setting_value }
                "nb_stall_poll_threshold"             { $Script:Config.NB_StallPollThreshold = [int]$row.setting_value }
                "nb_upload_stall_minutes"             { $Script:Config.NB_UploadStallMinutes = [int]$row.setting_value }
                "nb_queue_wait_minutes"               { $Script:Config.NB_QueueWaitMinutes = [int]$row.setting_value }
                "nb_alert_queue_wait_no_merge_routing" { $Script:Config.NB_Alert_QueueWaitNoMerge = [int]$row.setting_value }
                "nb_unreleased_minutes"               { $Script:Config.NB_UnreleasedMinutes = [int]$row.setting_value }
                "nb_alerting_enabled"                 { $Script:Config.NB_AlertingEnabled = [bool][int]$row.setting_value }
                "nb_lookback_days"                    { $Script:Config.NB_LookbackDays = [int]$row.setting_value }
                "nb_alert_upload_failed_routing"      { $Script:Config.NB_Alert_UploadFailed = [int]$row.setting_value }
                "nb_alert_release_failed_routing"     { $Script:Config.NB_Alert_ReleaseFailed = [int]$row.setting_value }
                "nb_alert_stalled_merge_routing"      { $Script:Config.NB_Alert_StalledMerge = [int]$row.setting_value }
                "nb_alert_upload_stall_routing"       { $Script:Config.NB_Alert_UploadStall = [int]$row.setting_value }
                "nb_alert_queue_wait_routing"         { $Script:Config.NB_Alert_QueueWait = [int]$row.setting_value }
                "nb_queue_wait_no_merge_minutes"      { $Script:Config.NB_QueueWaitNoMergeMinutes = [int]$row.setting_value }
                "nb_alert_unreleased_routing"         { $Script:Config.NB_Alert_Unreleased = [int]$row.setting_value }
                "nb_alert_release_merge_skip_routing" { $Script:Config.NB_Alert_ReleaseMergeSkip = [int]$row.setting_value }
                "nb_release_merge_skip_stall_threshold" { $Script:Config.NB_ReleaseMergeSkipStallThreshold = [int]$row.setting_value }
            }
        }
    }

    Write-Log "  AGName: $($Script:Config.AGName)" "INFO"
    Write-Log "  SourceReplica: $($Script:Config.SourceReplica)" "INFO"
    Write-Log "  NB_StallPollThreshold: $($Script:Config.NB_StallPollThreshold)" "INFO"
    Write-Log "  NB_ReleaseMergeSkipStallThreshold: $($Script:Config.NB_ReleaseMergeSkipStallThreshold)" "INFO"
    Write-Log "  NB_UploadStallMinutes: $($Script:Config.NB_UploadStallMinutes)" "INFO"
    Write-Log "  NB_QueueWaitMinutes: $($Script:Config.NB_QueueWaitMinutes)" "INFO"
    Write-Log "  NB_QueueWaitNoMergeMinutes: $($Script:Config.NB_QueueWaitNoMergeMinutes)" "INFO"
    Write-Log "  NB_UnreleasedMinutes: $($Script:Config.NB_UnreleasedMinutes)" "INFO"
    Write-Log "  NB_AlertingEnabled: $($Script:Config.NB_AlertingEnabled)" "INFO"
    Write-Log "  NB_LookbackDays: $($Script:Config.NB_LookbackDays)" "INFO"

    # Set write server (always the listener)
    $Script:WriteServer = $ServerInstance

    # Determine read server
    if ($ForceSourceServer) {
        $Script:ReadServer = $ForceSourceServer
        Write-Log "  ReadServer: $($Script:ReadServer) (forced via parameter)" "WARN"
    }
    else {
        Write-Log "Detecting AG replica roles..." "INFO"
        $agRoles = Get-AGReplicaRoles

        if (-not $agRoles) {
            Write-Log "AG detection failed - cannot determine read server" "ERROR"
            return $false
        }

        $Script:AGPrimary = $agRoles.PRIMARY
        $Script:AGSecondary = $agRoles.SECONDARY

        Write-Log "  AG PRIMARY: $($Script:AGPrimary)" "INFO"
        Write-Log "  AG SECONDARY: $($Script:AGSecondary)" "INFO"

        if ($Script:Config.SourceReplica -eq "PRIMARY") {
            $Script:ReadServer = $Script:AGPrimary
        }
        else {
            $Script:ReadServer = $Script:AGSecondary
        }

        if (-not $Script:ReadServer) {
            Write-Log "Could not determine ReadServer from AG roles" "ERROR"
            return $false
        }

        Write-Log "  ReadServer: $($Script:ReadServer) (from GlobalConfig: $($Script:Config.SourceReplica))" "SUCCESS"
    }

    Write-Log "  WriteServer: $($Script:WriteServer)" "INFO"

    # Resolve polling interval from ProcessRegistry for stall time estimates
    $Script:PollingIntervalMinutes = $null
    if ($ProcessId -gt 0) {
        $intervalQuery = @"
            SELECT interval_seconds
            FROM Orchestrator.ProcessRegistry
            WHERE process_id = $ProcessId
"@
        $intervalResult = Get-SqlData -Query $intervalQuery
        if ($intervalResult -and $intervalResult.interval_seconds -isnot [DBNull]) {
            $Script:PollingIntervalMinutes = [math]::Round($intervalResult.interval_seconds / 60, 1)
            Write-Log "  PollingIntervalMinutes: $($Script:PollingIntervalMinutes) (from ProcessRegistry)" "INFO"
        }
        else {
            Write-Log "  PollingIntervalMinutes: unknown (ProcessRegistry lookup failed)" "WARN"
        }
    }
    else {
        Write-Log "  PollingIntervalMinutes: unknown (manual run, no ProcessId)" "INFO"
    }

    return $true
}

function Get-StallDurationText {
    <#
    .SYNOPSIS
        Formats stall poll count into a human-readable duration string.
        Uses the resolved polling interval from ProcessRegistry when available.
    #>
    param([int]$PollCount)

    if ($null -ne $Script:PollingIntervalMinutes) {
        $totalMinutes = [math]::Round($PollCount * $Script:PollingIntervalMinutes)
        return "$PollCount polls (~$totalMinutes min)"
    }
    else {
        return "$PollCount polls"
    }
}

# ============================================================================
# STEP FUNCTIONS
# ============================================================================

function Step-CollectNewBatches {
    <#
    .SYNOPSIS
        Discovers new NB batches in DM not yet tracked in xFACts and inserts them.
        Does not include log table data - that is handled in the update pass.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect New Batches" "STEP"

    $newBatchCount = 0

    try {
        # Get list of batch IDs already tracked
        $trackedQuery = "SELECT batch_id FROM BatchOps.NB_BatchTracking"
        $trackedBatches = Get-SqlData -Query $trackedQuery

        $trackedIds = @()
        if ($trackedBatches) {
            $trackedIds = @($trackedBatches | ForEach-Object { $_.batch_id })
        }

        # Query DM for all batches, we'll filter in memory
        # Limit to batches created within the configured lookback window
        $lookbackDays = $Script:Config.NB_LookbackDays

        $sourceQuery = @"
            SELECT
                nbb.new_bsnss_btch_id,
                nbb.new_bsnss_btch_shrt_nm,
                nbb.file_registry_id,
                COALESCE(fr.file_name_full_txt, nbb.new_bsnss_btch_upload_file_txt) AS upload_filename,
                nbb.new_bsnss_btch_mnul_upld_flg,
                nbb.new_bsnss_btch_auto_rls_flg,
                nbb.new_bsnss_btch_auto_mrg_flg,
                nbb.new_bsnss_btch_stts_cd,
                rsts.new_bsnss_btch_stts_val_txt AS batch_status_txt,
                nbb.new_bsnss_btch_crt_dt,
                nbb.new_bsnss_btch_rls_strt_dttm,
                nbb.new_bsnss_btch_rlsd_dt,
                nbb.cnsmr_mrg_lnk_stts_cd,
                rnbb.cnsmr_mrg_lnk_stts_val_txt AS merge_status_txt,
                nbb.upsrt_dttm,
                nbb.new_bsnss_btch_cnsmr_actl_ttl_nmbr,
                nbb.new_bsnss_btch_cnsmr_accnt_actl_ttl_nmbr,
                nbb.new_bsnss_btch_cnsmr_accnt_bal_actl_ttl_amnt,
                nbb.new_bsnss_btch_cnsmr_accnt_pstd_ttl_nmbr,
                nbb.new_bsnss_btch_cnsmr_accnt_pstd_actl_ttl_amnt,
                nbb.new_bsnss_rls_cnsmr_prcssng_excld_cnt,
                nbb.new_bsnss_rls_cnsmr_prcssng_excld_bal_amnt,
                nbb.new_bsnss_btch_orgnl_prncpl_amnt,
                nbb.new_bsnss_btch_orgnl_intrst_amnt,
                nbb.new_bsnss_btch_orgnl_cllctn_chrg_amnt,
                nbb.new_bsnss_btch_orgnl_cst_amnt,
                nbb.new_bsnss_btch_orgnl_oth_amnt
            FROM dbo.new_bsnss_btch nbb
            INNER JOIN dbo.Ref_new_bsnss_btch_stts_cd rsts
                ON nbb.new_bsnss_btch_stts_cd = rsts.new_bsnss_btch_stts_cd
            LEFT JOIN dbo.ref_cnsmr_mrg_lnk_stts_cd rnbb
                ON nbb.cnsmr_mrg_lnk_stts_cd = rnbb.cnsmr_mrg_lnk_stts_cd
            LEFT JOIN dbo.File_Registry fr
                ON nbb.file_registry_id = fr.File_registry_id
            WHERE nbb.new_bsnss_btch_crt_dt >= DATEADD(DAY, -$lookbackDays, GETDATE())
"@

        $sourceBatches = Get-SourceData -Query $sourceQuery

        if (-not $sourceBatches) {
            Write-Log "  No source batches returned (or query failed)" "WARN"
            return @{ NewBatches = 0 }
        }

        # Filter to only new batches
        $newBatches = @($sourceBatches | Where-Object { $trackedIds -notcontains $_.new_bsnss_btch_id })

        if ($newBatches.Count -eq 0) {
            Write-Log "  No new batches to collect" "INFO"
            return @{ NewBatches = 0 }
        }

        Write-Log "  Found $($newBatches.Count) new batch(es)" "INFO"

        foreach ($batch in $newBatches) {
            $batchId = $batch.new_bsnss_btch_id
            $batchName = $batch.new_bsnss_btch_shrt_nm
            $batchStatusCd = $batch.new_bsnss_btch_stts_cd
            $mergeStatusCd = if ($batch.cnsmr_mrg_lnk_stts_cd -is [DBNull]) { $null } else { $batch.cnsmr_mrg_lnk_stts_cd }

            # Determine terminal state at insert time
            $isComplete = 0
            $completedStatus = "NULL"
            $completedDttm = "NULL"
            $mergeCompletedDttm = "NULL"

            # Terminal batch statuses: DELETED (5), FAILED (13)
            if ($batchStatusCd -in @(5, 13)) {
                $isComplete = 1
                $upsrtDttm = $batch.upsrt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff")
                $completedDttm = "'$upsrtDttm'"
                if ($batchStatusCd -eq 5) { $completedStatus = "'DELETED'" }
                elseif ($batchStatusCd -eq 13) { $completedStatus = "'FAILED'" }
            }
            # Terminal merge statuses: 3, 5, 6, 8, 10
            elseif ($null -ne $mergeStatusCd -and $mergeStatusCd -in @(3, 5, 6, 8, 10)) {
                $isComplete = 1
                $upsrtDttm = $batch.upsrt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff")
                $completedDttm = "'$upsrtDttm'"
                $mergeCompletedDttm = "'$upsrtDttm'"
                $mergeStatusTxt = $batch.merge_status_txt -replace "'", "''"
                $completedStatus = "'$mergeStatusTxt'"
            }

            # Safe string values
            $batchNameSafe = ($batchName -replace "'", "''").Trim()
            $uploadFileSafe = if ($batch.upload_filename -is [DBNull]) { "NULL" } else { "'" + ($batch.upload_filename -replace "'", "''") + "'" }
            $fileRegId = if ($batch.file_registry_id -is [DBNull]) { "NULL" } else { $batch.file_registry_id }
            $isManual = if ($batch.new_bsnss_btch_mnul_upld_flg -eq 'Y') { 1 } else { 0 }
            $isAutoRls = if ($batch.new_bsnss_btch_auto_rls_flg -eq 'Y') { 1 } else { 0 }
            $isAutoMrg = if ($batch.new_bsnss_btch_auto_mrg_flg -eq 'Y') { 1 } else { 0 }
            $batchStatusTxt = "'" + ($batch.batch_status_txt -replace "'", "''") + "'"
            $mergeStatusTxt = if ($null -eq $mergeStatusCd) { "NULL" } else { "'" + ($batch.merge_status_txt -replace "'", "''") + "'" }
            $mergeStatusCdSql = if ($null -eq $mergeStatusCd) { "NULL" } else { $mergeStatusCd }

            # Datetime values
            $crtDt = if ($batch.new_bsnss_btch_crt_dt -is [DBNull]) { "NULL" } else { "'" + $batch.new_bsnss_btch_crt_dt.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $rlsStart = if ($batch.new_bsnss_btch_rls_strt_dttm -is [DBNull]) { "NULL" } else { "'" + $batch.new_bsnss_btch_rls_strt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $rlsEnd = if ($batch.new_bsnss_btch_rlsd_dt -is [DBNull]) { "NULL" } else { "'" + $batch.new_bsnss_btch_rlsd_dt.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }

            # Numeric values (nullable)
            $consumerCnt = if ($batch.new_bsnss_btch_cnsmr_actl_ttl_nmbr -is [DBNull]) { "NULL" } else { $batch.new_bsnss_btch_cnsmr_actl_ttl_nmbr }
            $accountCnt = if ($batch.new_bsnss_btch_cnsmr_accnt_actl_ttl_nmbr -is [DBNull]) { "NULL" } else { $batch.new_bsnss_btch_cnsmr_accnt_actl_ttl_nmbr }
            $totalBal = if ($batch.new_bsnss_btch_cnsmr_accnt_bal_actl_ttl_amnt -is [DBNull]) { "NULL" } else { $batch.new_bsnss_btch_cnsmr_accnt_bal_actl_ttl_amnt }
            $postedAcct = if ($batch.new_bsnss_btch_cnsmr_accnt_pstd_ttl_nmbr -is [DBNull]) { "NULL" } else { $batch.new_bsnss_btch_cnsmr_accnt_pstd_ttl_nmbr }
            $postedBal = if ($batch.new_bsnss_btch_cnsmr_accnt_pstd_actl_ttl_amnt -is [DBNull]) { "NULL" } else { $batch.new_bsnss_btch_cnsmr_accnt_pstd_actl_ttl_amnt }
            $exclCons = if ($batch.new_bsnss_rls_cnsmr_prcssng_excld_cnt -is [DBNull]) { "NULL" } else { $batch.new_bsnss_rls_cnsmr_prcssng_excld_cnt }
            $exclBal = if ($batch.new_bsnss_rls_cnsmr_prcssng_excld_bal_amnt -is [DBNull]) { "NULL" } else { $batch.new_bsnss_rls_cnsmr_prcssng_excld_bal_amnt }
            $principal = if ($batch.new_bsnss_btch_orgnl_prncpl_amnt -is [DBNull]) { "NULL" } else { $batch.new_bsnss_btch_orgnl_prncpl_amnt }
            $interest = if ($batch.new_bsnss_btch_orgnl_intrst_amnt -is [DBNull]) { "NULL" } else { $batch.new_bsnss_btch_orgnl_intrst_amnt }
            $collCharges = if ($batch.new_bsnss_btch_orgnl_cllctn_chrg_amnt -is [DBNull]) { "NULL" } else { $batch.new_bsnss_btch_orgnl_cllctn_chrg_amnt }
            $cost = if ($batch.new_bsnss_btch_orgnl_cst_amnt -is [DBNull]) { "NULL" } else { $batch.new_bsnss_btch_orgnl_cst_amnt }
            $other = if ($batch.new_bsnss_btch_orgnl_oth_amnt -is [DBNull]) { "NULL" } else { $batch.new_bsnss_btch_orgnl_oth_amnt }

            if ($PreviewOnly) {
                $statusInfo = if ($isComplete -eq 1) { "COMPLETE" } else { $batch.batch_status_txt }
                Write-Log "  [Preview] Would insert batch $batchId ($batchNameSafe) - $statusInfo" "INFO"
            }
            else {
                $insertQuery = @"
                    INSERT INTO BatchOps.NB_BatchTracking (
                        batch_id, batch_name, file_registry_id, upload_filename,
                        is_manual_upload, is_auto_release, is_auto_merge,
                        batch_status_code, batch_status,
                        batch_created_dttm, release_started_dttm, release_completed_dttm,
                        merge_status_code, merge_status, merge_completed_dttm,
                        consumer_count, account_count, total_balance_amt,
                        posted_account_count, posted_balance_amt,
                        excluded_consumer_count, excluded_balance_amt,
                        original_principal_amt, original_interest_amt,
                        original_collection_charges_amt, original_cost_amt, original_other_amt,
                        is_complete, completed_dttm, completed_status,
                        stall_poll_count, reset_count, alert_count, last_polled_dttm
                    )
                    VALUES (
                        $batchId, '$batchNameSafe', $fileRegId, $uploadFileSafe,
                        $isManual, $isAutoRls, $isAutoMrg,
                        $batchStatusCd, $batchStatusTxt,
                        $crtDt, $rlsStart, $rlsEnd,
                        $mergeStatusCdSql, $mergeStatusTxt, $mergeCompletedDttm,
                        $consumerCnt, $accountCnt, $totalBal,
                        $postedAcct, $postedBal,
                        $exclCons, $exclBal,
                        $principal, $interest,
                        $collCharges, $cost, $other,
                        $isComplete, $completedDttm, $completedStatus,
                        0, 0, 0, GETDATE()
                    )
"@

                $result = Invoke-SqlNonQuery -Query $insertQuery
                if ($result) {
                    $newBatchCount++
                    Write-Log "  Inserted batch $batchId ($batchNameSafe)" "SUCCESS"
                }
                else {
                    Write-Log "  Failed to insert batch $batchId ($batchNameSafe)" "ERROR"
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

function Step-UpdateIncompleteBatches {
    <#
    .SYNOPSIS
        Updates all incomplete batches in the tracking table with current DM state.
        Queries DM for batch status, metrics, and log activity per batch.
        Updates stall detection counters and detects terminal states.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Update Incomplete Batches" "STEP"

    $batchesUpdated = 0
    $batchesCompleted = 0

    try {
        # Get all incomplete batches from tracking table
        $incompleteQuery = @"
            SELECT tracking_id, batch_id, batch_name, last_log_id, stall_poll_count,
                   merge_started_dttm, is_complete, batch_status_code, alert_count
            FROM BatchOps.NB_BatchTracking
            WHERE is_complete = 0
"@

        $incompleteBatches = Get-SqlData -Query $incompleteQuery

        if (-not $incompleteBatches) {
            Write-Log "  No incomplete batches to update" "INFO"
            return @{ Updated = 0; Completed = 0 }
        }

        $batchCount = @($incompleteBatches).Count
        Write-Log "  Found $batchCount incomplete batch(es)" "INFO"

        foreach ($tracking in @($incompleteBatches)) {
            $batchId = $tracking.batch_id
            $batchName = $tracking.batch_name
            $currentLogId = if ($tracking.last_log_id -is [DBNull]) { $null } else { $tracking.last_log_id }
            $currentStallCount = $tracking.stall_poll_count
            $currentMergeStart = if ($tracking.merge_started_dttm -is [DBNull]) { $null } else { $tracking.merge_started_dttm }
            $previousStatusCode = if ($tracking.batch_status_code -is [DBNull]) { $null } else { $tracking.batch_status_code }
            $currentAlertCount = if ($tracking.alert_count -is [DBNull]) { 0 } else { $tracking.alert_count }

            # Query DM for current batch state
            $batchQuery = @"
                SELECT
                    nbb.new_bsnss_btch_stts_cd,
                    rsts.new_bsnss_btch_stts_val_txt AS batch_status_txt,
                    nbb.cnsmr_mrg_lnk_stts_cd,
                    rnbb.cnsmr_mrg_lnk_stts_val_txt AS merge_status_txt,
                    nbb.new_bsnss_btch_rls_strt_dttm,
                    nbb.new_bsnss_btch_rlsd_dt,
                    nbb.new_bsnss_btch_cnsmr_actl_ttl_nmbr,
                    nbb.new_bsnss_btch_cnsmr_accnt_actl_ttl_nmbr,
                    nbb.new_bsnss_btch_cnsmr_accnt_bal_actl_ttl_amnt,
                    nbb.new_bsnss_btch_cnsmr_accnt_pstd_ttl_nmbr,
                    nbb.new_bsnss_btch_cnsmr_accnt_pstd_actl_ttl_amnt,
                    nbb.new_bsnss_rls_cnsmr_prcssng_excld_cnt,
                    nbb.new_bsnss_rls_cnsmr_prcssng_excld_bal_amnt
                FROM dbo.new_bsnss_btch nbb
                INNER JOIN dbo.Ref_new_bsnss_btch_stts_cd rsts
                    ON nbb.new_bsnss_btch_stts_cd = rsts.new_bsnss_btch_stts_cd
                LEFT JOIN dbo.ref_cnsmr_mrg_lnk_stts_cd rnbb
                    ON nbb.cnsmr_mrg_lnk_stts_cd = rnbb.cnsmr_mrg_lnk_stts_cd
                WHERE nbb.new_bsnss_btch_id = $batchId
"@

            $batchState = Get-SourceData -Query $batchQuery

            if (-not $batchState) {
                Write-Log "  Batch $batchId ($batchName): failed to query DM" "WARN"
                continue
            }

            # Query log table for activity
            $logQuery = @"
                SELECT
                    MAX(new_bsnss_log_id) AS max_log_id,
                    MAX(upsrt_dttm) AS max_log_dttm,
                    MIN(upsrt_dttm) AS min_log_dttm,
                    SUM(CASE
                        WHEN new_bsnss_log_mssg_txt = 'New Business batch moved to RELEASED state since it has no consumers to be released'
                        THEN 1 ELSE 0
                    END) AS reset_count,
                    MAX(CASE
                        WHEN new_bsnss_log_mssg_txt = 'New Business batch moved to RELEASED state since it has no consumers to be released'
                        THEN upsrt_dttm ELSE NULL
                    END) AS last_reset_dttm
                FROM dbo.new_bsnss_log
                WHERE new_bsnss_btch_id = $batchId
"@

            $logData = Get-SourceData -Query $logQuery

            # Extract values
            $batchStatusCd = $batchState.new_bsnss_btch_stts_cd
            $batchStatusTxt = ($batchState.batch_status_txt -replace "'", "''").Trim()
            $mergeStatusCd = if ($batchState.cnsmr_mrg_lnk_stts_cd -is [DBNull]) { $null } else { $batchState.cnsmr_mrg_lnk_stts_cd }
            $mergeStatusTxt = if ($null -eq $mergeStatusCd) { "NULL" } else { "'" + ($batchState.merge_status_txt -replace "'", "''") + "'" }
            $mergeStatusCdSql = if ($null -eq $mergeStatusCd) { "NULL" } else { $mergeStatusCd }

            # Datetime values
            $rlsStart = if ($batchState.new_bsnss_btch_rls_strt_dttm -is [DBNull]) { "NULL" } else { "'" + $batchState.new_bsnss_btch_rls_strt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $rlsEnd = if ($batchState.new_bsnss_btch_rlsd_dt -is [DBNull]) { "NULL" } else { "'" + $batchState.new_bsnss_btch_rlsd_dt.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }

            # Metrics
            $consumerCnt = if ($batchState.new_bsnss_btch_cnsmr_actl_ttl_nmbr -is [DBNull]) { "NULL" } else { $batchState.new_bsnss_btch_cnsmr_actl_ttl_nmbr }
            $accountCnt = if ($batchState.new_bsnss_btch_cnsmr_accnt_actl_ttl_nmbr -is [DBNull]) { "NULL" } else { $batchState.new_bsnss_btch_cnsmr_accnt_actl_ttl_nmbr }
            $totalBal = if ($batchState.new_bsnss_btch_cnsmr_accnt_bal_actl_ttl_amnt -is [DBNull]) { "NULL" } else { $batchState.new_bsnss_btch_cnsmr_accnt_bal_actl_ttl_amnt }
            $postedAcct = if ($batchState.new_bsnss_btch_cnsmr_accnt_pstd_ttl_nmbr -is [DBNull]) { "NULL" } else { $batchState.new_bsnss_btch_cnsmr_accnt_pstd_ttl_nmbr }
            $postedBal = if ($batchState.new_bsnss_btch_cnsmr_accnt_pstd_actl_ttl_amnt -is [DBNull]) { "NULL" } else { $batchState.new_bsnss_btch_cnsmr_accnt_pstd_actl_ttl_amnt }
            $exclCons = if ($batchState.new_bsnss_rls_cnsmr_prcssng_excld_cnt -is [DBNull]) { "NULL" } else { $batchState.new_bsnss_rls_cnsmr_prcssng_excld_cnt }
            $exclBal = if ($batchState.new_bsnss_rls_cnsmr_prcssng_excld_bal_amnt -is [DBNull]) { "NULL" } else { $batchState.new_bsnss_rls_cnsmr_prcssng_excld_bal_amnt }

            # Log data
            $newLogId = if (-not $logData -or $logData.max_log_id -is [DBNull]) { $null } else { $logData.max_log_id }
            $maxLogDttm = if (-not $logData -or $logData.max_log_dttm -is [DBNull]) { "NULL" } else { "'" + $logData.max_log_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $minLogDttm = if (-not $logData -or $logData.min_log_dttm -is [DBNull]) { $null } else { $logData.min_log_dttm }
            $resetCount = if (-not $logData -or $logData.reset_count -is [DBNull]) { 0 } else { $logData.reset_count }
            $lastResetDttm = if (-not $logData -or $logData.last_reset_dttm -is [DBNull]) { "NULL" } else { "'" + $logData.last_reset_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }

            # Stall detection logic
            $newAlertCount = $currentAlertCount
            if ($null -eq $newLogId) {
                # No logs yet - don't change stall counter
                $newStallCount = $currentStallCount
            }
            elseif ($null -ne $currentLogId -and $newLogId -eq $currentLogId) {
                # Same log ID as last poll - no new activity
                $newStallCount = $currentStallCount + 1
            }
            else {
                # New activity detected - reset stall counter and alert_count
                $newStallCount = 0
                if ($currentAlertCount -gt 0) {
                    $newAlertCount = 0
                    Write-Log "  Batch $batchId ($batchName): activity resumed, resetting alert_count" "DEBUG"
                }
            }

            # Status transition: RELEASING (7) -> non-RELEASING resets stall counter
            # The batch transitioned out of the anomalous state, so the stall timer starts fresh
            if ($previousStatusCode -eq 7 -and $batchStatusCd -ne 7) {
                $newStallCount = 0
                if ($currentAlertCount -gt 0) {
                    $newAlertCount = 0
                    Write-Log "  Batch $batchId ($batchName): transitioned from RELEASING to $batchStatusTxt, resetting stall and alert_count" "DEBUG"
                }
            }
            $lastLogIdSql = if ($null -eq $newLogId) { "NULL" } else { $newLogId }

            # Merge started: set from first log entry if we don't have it yet
            $mergeStartSql = if ($null -ne $currentMergeStart) {
                "'" + $currentMergeStart.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"
            }
            elseif ($null -ne $minLogDttm) {
                "'" + $minLogDttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"
            }
            else { "NULL" }

            # Terminal state detection
            $isComplete = 0
            $completedDttm = "NULL"
            $completedStatus = "NULL"
            $mergeCompletedDttm = "NULL"

            if ($batchStatusCd -in @(5, 13)) {
                $isComplete = 1
                $completedDttm = "GETDATE()"
                if ($batchStatusCd -eq 5) { $completedStatus = "'DELETED'" }
                elseif ($batchStatusCd -eq 13) { $completedStatus = "'FAILED'" }
            }
            elseif ($null -ne $mergeStatusCd -and $mergeStatusCd -in @(3, 5, 6, 8, 10)) {
                $isComplete = 1
                $completedDttm = "GETDATE()"
                $mergeCompletedDttm = "GETDATE()"
                $completedStatus = $mergeStatusTxt  # already quoted
            }

            if ($PreviewOnly) {
                $statusDesc = "$batchStatusTxt"
                if ($null -ne $mergeStatusCd) { $statusDesc += " / $($batchState.merge_status_txt)" }
                if ($isComplete -eq 1) { $statusDesc += " -> COMPLETE" }
                if ($newStallCount -gt 0) { $statusDesc += " (stall: $newStallCount)" }
                Write-Log "  [Preview] Would update batch $batchId ($batchName): $statusDesc" "INFO"
                $batchesUpdated++
                if ($isComplete -eq 1) { $batchesCompleted++ }
            }
            else {
                $updateQuery = @"
                    UPDATE BatchOps.NB_BatchTracking
                    SET batch_status_code    = $batchStatusCd,
                        batch_status         = '$batchStatusTxt',
                        merge_status_code    = $mergeStatusCdSql,
                        merge_status         = $mergeStatusTxt,
                        release_started_dttm = $rlsStart,
                        release_completed_dttm = $rlsEnd,
                        merge_started_dttm   = $mergeStartSql,
                        merge_completed_dttm = COALESCE(merge_completed_dttm, $mergeCompletedDttm),
                        consumer_count       = $consumerCnt,
                        account_count        = $accountCnt,
                        total_balance_amt    = $totalBal,
                        posted_account_count = $postedAcct,
                        posted_balance_amt   = $postedBal,
                        excluded_consumer_count = $exclCons,
                        excluded_balance_amt = $exclBal,
                        last_log_id          = $lastLogIdSql,
                        last_log_dttm        = $maxLogDttm,
                        stall_poll_count     = $newStallCount,
                        alert_count          = $newAlertCount,
                        reset_count          = $resetCount,
                        last_reset_dttm      = $lastResetDttm,
                        is_complete          = $isComplete,
                        completed_dttm       = COALESCE(completed_dttm, $completedDttm),
                        completed_status     = COALESCE(completed_status, $completedStatus),
                        last_polled_dttm     = GETDATE()
                    WHERE batch_id = $batchId
"@

                $result = Invoke-SqlNonQuery -Query $updateQuery
                if ($result) {
                    $batchesUpdated++
                    if ($isComplete -eq 1) {
                        $batchesCompleted++
                        Write-Log "  Batch $batchId ($batchName): COMPLETED ($($batchState.merge_status_txt))" "SUCCESS"
                    }
                    else {
                        Write-Log "  Batch $batchId ($batchName): updated (stall: $newStallCount)" "DEBUG"
                    }
                }
                else {
                    Write-Log "  Batch $batchId ($batchName): update failed" "ERROR"
                }
            }
        }

        Write-Log "  Batches updated: $batchesUpdated, Completed: $batchesCompleted" "INFO"
        return @{ Updated = $batchesUpdated; Completed = $batchesCompleted }
    }
    catch {
        Write-Log "  Error in Update Incomplete Batches: $($_.Exception.Message)" "ERROR"
        return @{ Updated = $batchesUpdated; Completed = $batchesCompleted; Error = $_.Exception.Message }
    }
}

function Step-DetectOrphanedBatches {
    <#
    .SYNOPSIS
        Detects incomplete batches in the tracking table whose source rows have been
        hard-deleted from DM (dbo.new_bsnss_btch). Marks them as HARD_DELETED.
        This handles cases where batches are removed outside the normal DM lifecycle
        (e.g., Matt's manual cleanup of failed Rollover batches).
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Detect Orphaned Batches" "STEP"
    $orphanCount = 0

    try {
        # Get all incomplete batch IDs from tracking table
        $incompleteQuery = @"
            SELECT batch_id, batch_name
            FROM BatchOps.NB_BatchTracking
            WHERE is_complete = 0
"@
        $incompleteBatches = Get-SqlData -Query $incompleteQuery

        if (-not $incompleteBatches) {
            Write-Log "  No incomplete batches to check" "INFO"
            return @{ Orphaned = 0 }
        }

        $batchCount = @($incompleteBatches).Count
        Write-Log "  Checking $batchCount incomplete batch(es) against DM" "INFO"

        # Build comma-separated ID list for bulk existence check
        $batchIds = @($incompleteBatches | ForEach-Object { $_.batch_id }) -join ','

        # Query DM for which of these batch IDs still exist
        $existsQuery = @"
            SELECT new_bsnss_btch_id
            FROM dbo.new_bsnss_btch
            WHERE new_bsnss_btch_id IN ($batchIds)
"@
        $existingBatches = Get-SourceData -Query $existsQuery

        $existingIds = @()
        if ($existingBatches) {
            $existingIds = @($existingBatches | ForEach-Object { $_.new_bsnss_btch_id })
        }

        # Find orphans — tracked but no longer in DM
        $orphans = @($incompleteBatches | Where-Object { $existingIds -notcontains $_.batch_id })

        if ($orphans.Count -eq 0) {
            Write-Log "  No orphaned batches detected" "INFO"
            return @{ Orphaned = 0 }
        }

        Write-Log "  Found $($orphans.Count) orphaned batch(es)" "WARN"

        foreach ($orphan in $orphans) {
            $batchId = $orphan.batch_id
            $batchName = $orphan.batch_name

            if ($PreviewOnly) {
                Write-Log "  [Preview] Would mark batch $batchId ($batchName) as HARD_DELETED" "INFO"
                $orphanCount++
            }
            else {
                $updateQuery = @"
                    UPDATE BatchOps.NB_BatchTracking
                    SET is_complete      = 1,
                        completed_dttm   = GETDATE(),
                        completed_status = 'HARD_DELETED',
                        stall_poll_count = 0,
                        alert_count      = 0,
                        last_polled_dttm = GETDATE()
                    WHERE batch_id = $batchId
"@
                $result = Invoke-SqlNonQuery -Query $updateQuery
                if ($result) {
                    $orphanCount++
                    Write-Log "  Batch $batchId ($batchName): marked HARD_DELETED" "SUCCESS"
                }
                else {
                    Write-Log "  Batch $batchId ($batchName): update failed" "ERROR"
                }
            }
        }

        if ($PreviewOnly) { $orphanCount = $orphans.Count }
        Write-Log "  Orphaned batches resolved: $orphanCount" "INFO"
        return @{ Orphaned = $orphanCount }
    }
    catch {
        Write-Log "  Error in Detect Orphaned Batches: $($_.Exception.Message)" "ERROR"
        return @{ Orphaned = $orphanCount; Error = $_.Exception.Message }
    }
}

function Step-EvaluateAlerts {
    <#
    .SYNOPSIS
        Evaluates 7 alert conditions on tracked NB batches.
        Routes alerts to Jira and/or Teams based on per-condition GlobalConfig routing.
        Master switch: nb_alerting_enabled must be 1 for alerts to fire.
        Each condition uses RequestLog dedup to prevent duplicate alerts.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Evaluate Alert Conditions" "STEP"

    $alertsDetected = 0
    $alertsFired = 0

    # ── Jira ticket constants (hardcoded per xFACts convention) ──
    $jiraProjectKey = 'SD'
    $jiraIssueType = 'Issue'
    $jiraPriority = 'Highest'
    $jiraCascadingFieldId = 'customfield_18401'
    $jiraCascadingParent = 'File Processing'
    $jiraCustomField1Id = 'customfield_10305'
    $jiraCustomField1Value = 'FAC INFORMATION TECHNOLOGY'
    $jiraCustomField2Id = 'customfield_10009'
    $jiraCustomField2Value = 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa'
    $jiraEmailRecipients = 'applications@frost-arnett.com'

    # Due date: today if weekday, Monday if weekend
    $dayOfWeek = [int](Get-Date).DayOfWeek  # 0=Sun, 1=Mon ... 6=Sat
    if ($dayOfWeek -eq 0) { $jiraDueDate = (Get-Date).AddDays(1).ToString("yyyy-MM-dd") }
    elseif ($dayOfWeek -eq 6) { $jiraDueDate = (Get-Date).AddDays(2).ToString("yyyy-MM-dd") }
    else { $jiraDueDate = (Get-Date).ToString("yyyy-MM-dd") }

    try {
        if (-not $Script:Config.NB_AlertingEnabled) {
            Write-Log "  Alerting is DISABLED (nb_alerting_enabled = 0)" "INFO"
        }

        # ══════════════════════════════════════════════════════════════════
        # CHECK 1: Upload Failures (batch_status_code IN (3, 13))
        # Terminal failures - one alert per batch, error extraction from log
        # ══════════════════════════════════════════════════════════════════
        $routing = $Script:Config.NB_Alert_UploadFailed

        $uploadFailedQuery = @"
            SELECT batch_id, batch_name, batch_status_code, batch_status,
                   upload_filename, account_count, batch_created_dttm, alert_count
            FROM BatchOps.NB_BatchTracking
            WHERE is_complete = 0
              AND batch_status_code IN (3, 13)
              AND alert_count = 0
              AND NOT (is_auto_release = 0 AND is_manual_upload = 0 AND is_auto_merge = 0)
"@

        $uploadFailures = Get-SqlData -Query $uploadFailedQuery

        if ($uploadFailures) {
            foreach ($batch in @($uploadFailures)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = $batch.batch_name
                Write-Log "  ALERT: Upload failure detected - batch $batchId ($batchName)" "WARN"

                if ($Script:Config.NB_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {

                    # ── Error extraction from new_bsnss_log ──
                    $errorCountQuery = @"
                        SELECT COUNT(DISTINCT new_bsnss_log_mssg_txt) AS error_count
                        FROM dbo.new_bsnss_log
                        WHERE new_bsnss_btch_id = $batchId
                          AND new_bsnss_log_mssg_txt NOT LIKE '%not in valid state to perform the operation%'
                          AND new_bsnss_log_mssg_txt NOT LIKE 'Error while saving new business consumer information%'
"@
                    $errorCountResult = Get-SourceData -Query $errorCountQuery
                    $errorCount = if ($errorCountResult -and $errorCountResult.error_count -isnot [DBNull]) { $errorCountResult.error_count } else { 0 }

                    $errorListQuery = @"
                        ;WITH DistinctErrors AS (
                            SELECT DISTINCT TOP 5 new_bsnss_log_mssg_txt
                            FROM dbo.new_bsnss_log
                            WHERE new_bsnss_btch_id = $batchId
                              AND new_bsnss_log_mssg_txt NOT LIKE '%not in valid state to perform the operation%'
                              AND new_bsnss_log_mssg_txt NOT LIKE 'Error while saving new business consumer information%'
                            ORDER BY new_bsnss_log_mssg_txt
                        )
                        SELECT STRING_AGG(new_bsnss_log_mssg_txt, CHAR(10)) AS error_list,
                               COUNT(*) AS displayed_count
                        FROM DistinctErrors
"@
                    $errorListResult = Get-SourceData -Query $errorListQuery
                    $errorList = if ($errorListResult -and $errorListResult.error_list -isnot [DBNull]) { $errorListResult.error_list } else { $null }
                    $displayedCount = if ($errorListResult -and $errorListResult.displayed_count -isnot [DBNull]) { $errorListResult.displayed_count } else { 0 }

                    # Build error section text
                    if ($errorList) {
                        if ($errorCount -gt $displayedCount) {
                            $errorSection = "Errors (first $displayedCount of ${errorCount}):`n$errorList"
                        }
                        else {
                            $errorSection = "Errors (${errorCount}):`n$errorList"
                        }
                    }
                    else {
                        $errorSection = "Errors: No error details found in batch log."
                    }

                    $uploadFile = if ($batch.upload_filename -isnot [DBNull]) { $batch.upload_filename } else { 'N/A' }
                    $acctCount = if ($batch.account_count -isnot [DBNull]) { $batch.account_count } else { 0 }
                    $triggerType = 'NB_UploadFailed'
                    $triggerValue = "$batchId"
                    $cascadingChild = 'Upload Failure'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                    # ── Jira ticket (routing 2 or 3) ──
                    if ($routing -band 2) {
                        $jiraDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS ticket_exists
                            FROM Jira.RequestLog
                            WHERE Trigger_Type = '$triggerType'
                              AND Trigger_Value = '$triggerValue'
                              AND StatusCode = 201
                              AND TicketKey IS NOT NULL
                              AND TicketKey != 'Email'
"@
                        if (-not $jiraDedup) {
                            $jiraSummary = "New Business Batch Upload Failed: $batchId"
                            $jiraDesc = @"
New Business Batch Upload Failed

Batch ID: $batchId
Batch Name: $batchName
Filename: $uploadFile
Records: $acctCount

$errorSection

Action: Delete the failed batch in Debt Manager and re-upload.

Detection Date: $detectionTime
"@
                            $jiraSummarySafe = $jiraSummary -replace "'", "''"
                            $jiraDescSafe = $jiraDesc -replace "'", "''"

                            $queueTicketQuery = @"
                                EXEC Jira.sp_QueueTicket
                                    @SourceModule = 'BatchOps',
                                    @ProjectKey = '$jiraProjectKey',
                                    @Summary = N'$jiraSummarySafe',
                                    @Description = N'$jiraDescSafe',
                                    @IssueType = '$jiraIssueType',
                                    @Priority = '$jiraPriority',
                                    @EmailRecipients = '$jiraEmailRecipients',
                                    @CascadingField_ID = '$jiraCascadingFieldId',
                                    @CascadingField_ParentValue = '$jiraCascadingParent',
                                    @CascadingField_ChildValue = '$cascadingChild',
                                    @CustomField_ID = '$jiraCustomField1Id',
                                    @CustomField_Value = '$jiraCustomField1Value',
                                    @CustomField2_ID = '$jiraCustomField2Id',
                                    @CustomField2_Value = '$jiraCustomField2Value',
                                    @DueDate = '$jiraDueDate',
                                    @TriggerType = '$triggerType',
                                    @TriggerValue = '$triggerValue'
"@
                            Invoke-SqlNonQuery -Query $queueTicketQuery | Out-Null
                            Write-Log "    Jira ticket queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Jira dedup: ticket already exists for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Teams alert (routing 1 or 3) ──
                    if ($routing -band 1) {
                        $teamsDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS alert_exists
                            FROM Teams.RequestLog
                            WHERE trigger_type = '$triggerType'
                              AND trigger_value = '$triggerValue'
                              AND status_code = 200
"@
                        if (-not $teamsDedup) {
                            $teamsTitle = "{{FIRE}} New Business Batch Upload Failed: $batchId"
                            $teamsColor = 'attention'
                            $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**File:** $uploadFile
**Records:** $acctCount
**Created:** $(if ($batch.batch_created_dttm -isnot [DBNull]) { $batch.batch_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' })

$errorSection

Action: Delete the failed batch in Debt Manager and re-upload.

**Detection:** $detectionTime
"@
                            $teamsTitleSafe = $teamsTitle -replace "'", "''"
                            $teamsMessageSafe = $teamsMessage -replace "'", "''"

                            $teamsInsert = @"
                                INSERT INTO Teams.AlertQueue (
                                    source_module, alert_category, title, message, color,
                                    trigger_type, trigger_value, status, created_dttm
                                )
                                VALUES (
                                    'BatchOps', 'CRITICAL', N'$teamsTitleSafe',
                                    N'$teamsMessageSafe', '$teamsColor',
                                    '$triggerType', '$triggerValue',
                                    'Pending', GETDATE()
                                )
"@
                            Invoke-SqlNonQuery -Query $teamsInsert | Out-Null
                            Write-Log "    Teams alert queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Teams dedup: alert already sent for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Increment alert_count ──
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.NB_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }


        # ══════════════════════════════════════════════════════════════════
        # CHECK 2: Release Failed (batch_status_code = 9)
        # Terminal failure - one alert per batch, no error extraction
        # ══════════════════════════════════════════════════════════════════
        $routing = $Script:Config.NB_Alert_ReleaseFailed

        $releaseFailedQuery = @"
            SELECT batch_id, batch_name, batch_status, upload_filename,
                   account_count, batch_created_dttm, release_started_dttm, alert_count
            FROM BatchOps.NB_BatchTracking
            WHERE is_complete = 0
              AND batch_status_code = 9
              AND alert_count = 0
              AND NOT (is_auto_release = 0 AND is_manual_upload = 0 AND is_auto_merge = 0)
"@

        $releaseFailures = Get-SqlData -Query $releaseFailedQuery

        if ($releaseFailures) {
            foreach ($batch in @($releaseFailures)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = $batch.batch_name
                Write-Log "  ALERT: Release failure detected - batch $batchId ($batchName)" "WARN"

                if ($Script:Config.NB_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $uploadFile = if ($batch.upload_filename -isnot [DBNull]) { $batch.upload_filename } else { 'N/A' }
                    $acctCount = if ($batch.account_count -isnot [DBNull]) { $batch.account_count } else { 0 }
                    $triggerType = 'NB_ReleaseFailed'
                    $triggerValue = "$batchId"
                    $cascadingChild = 'Placement File Issue'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $rlsStarted = if ($batch.release_started_dttm -isnot [DBNull]) { $batch.release_started_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }

                    # ── Jira ticket (routing 2 or 3) ──
                    if ($routing -band 2) {
                        $jiraDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS ticket_exists
                            FROM Jira.RequestLog
                            WHERE Trigger_Type = '$triggerType'
                              AND Trigger_Value = '$triggerValue'
                              AND StatusCode = 201
                              AND TicketKey IS NOT NULL
                              AND TicketKey != 'Email'
"@
                        if (-not $jiraDedup) {
                            $jiraSummary = "New Business Batch Release Failed: $batchId"
                            $jiraDesc = @"
New Business Batch Release Failed

Batch ID: $batchId
Batch Name: $batchName
Filename: $uploadFile
Records: $acctCount
Release Started: $rlsStarted

Action: Set batch back to Uploaded status and re-release manually.

Detection Date: $detectionTime
"@
                            $jiraSummarySafe = $jiraSummary -replace "'", "''"
                            $jiraDescSafe = $jiraDesc -replace "'", "''"

                            $queueTicketQuery = @"
                                EXEC Jira.sp_QueueTicket
                                    @SourceModule = 'BatchOps',
                                    @ProjectKey = '$jiraProjectKey',
                                    @Summary = N'$jiraSummarySafe',
                                    @Description = N'$jiraDescSafe',
                                    @IssueType = '$jiraIssueType',
                                    @Priority = '$jiraPriority',
                                    @EmailRecipients = '$jiraEmailRecipients',
                                    @CascadingField_ID = '$jiraCascadingFieldId',
                                    @CascadingField_ParentValue = '$jiraCascadingParent',
                                    @CascadingField_ChildValue = '$cascadingChild',
                                    @CustomField_ID = '$jiraCustomField1Id',
                                    @CustomField_Value = '$jiraCustomField1Value',
                                    @CustomField2_ID = '$jiraCustomField2Id',
                                    @CustomField2_Value = '$jiraCustomField2Value',
                                    @DueDate = '$jiraDueDate',
                                    @TriggerType = '$triggerType',
                                    @TriggerValue = '$triggerValue'
"@
                            Invoke-SqlNonQuery -Query $queueTicketQuery | Out-Null
                            Write-Log "    Jira ticket queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Jira dedup: ticket already exists for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Teams alert (routing 1 or 3) ──
                    if ($routing -band 1) {
                        $teamsDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS alert_exists
                            FROM Teams.RequestLog
                            WHERE trigger_type = '$triggerType'
                              AND trigger_value = '$triggerValue'
                              AND status_code = 200
"@
                        if (-not $teamsDedup) {
                            $teamsTitle = "{{FIRE}} New Business Batch Release Failed: $batchId"
                            $teamsColor = 'attention'
                            $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**File:** $uploadFile
**Records:** $acctCount
**Release Started:** $rlsStarted

Action: Set batch back to Uploaded status and re-release manually.

**Detection:** $detectionTime
"@
                            $teamsTitleSafe = $teamsTitle -replace "'", "''"
                            $teamsMessageSafe = $teamsMessage -replace "'", "''"

                            $teamsInsert = @"
                                INSERT INTO Teams.AlertQueue (
                                    source_module, alert_category, title, message, color,
                                    trigger_type, trigger_value, status, created_dttm
                                )
                                VALUES (
                                    'BatchOps', 'CRITICAL', N'$teamsTitleSafe',
                                    N'$teamsMessageSafe', '$teamsColor',
                                    '$triggerType', '$triggerValue',
                                    'Pending', GETDATE()
                                )
"@
                            Invoke-SqlNonQuery -Query $teamsInsert | Out-Null
                            Write-Log "    Teams alert queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Teams dedup: alert already sent for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Increment alert_count ──
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.NB_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }


        # ══════════════════════════════════════════════════════════════════
        # CHECK 3: Stalled Merges (stall_poll_count >= threshold)
        # Re-alertable per stall episode using composite trigger
        # ══════════════════════════════════════════════════════════════════
        $routing = $Script:Config.NB_Alert_StalledMerge
        $stallThreshold = $Script:Config.NB_StallPollThreshold

        $stalledQuery = @"
            SELECT batch_id, batch_name, stall_poll_count, last_log_id, last_log_dttm,
                   merge_status, merge_status_code, consumer_count, account_count,
                   batch_created_dttm, alert_count
            FROM BatchOps.NB_BatchTracking
            WHERE is_complete = 0
              AND stall_poll_count >= $stallThreshold
              AND last_log_id IS NOT NULL
              AND alert_count = 0
              AND NOT (is_auto_release = 0 AND is_manual_upload = 0 AND is_auto_merge = 0)
"@

        $stalledBatches = Get-SqlData -Query $stalledQuery

        if ($stalledBatches) {
            foreach ($batch in @($stalledBatches)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = $batch.batch_name
                $lastLogId = $batch.last_log_id
                Write-Log "  ALERT: Merge stall detected - batch $batchId ($batchName) - $($batch.stall_poll_count) polls unchanged" "WARN"

                if ($Script:Config.NB_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $triggerType = 'NB_StalledMerge'
                    $triggerValue = "${batchId}_${lastLogId}"
                    $cascadingChild = 'Placement File Issue'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $consCount = if ($batch.consumer_count -isnot [DBNull]) { $batch.consumer_count } else { 'N/A' }
                    $mergeStatus = if ($batch.merge_status -isnot [DBNull]) { $batch.merge_status } else { 'N/A' }
                    $lastLogTime = if ($batch.last_log_dttm -isnot [DBNull]) { $batch.last_log_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }
                    $stallDuration = Get-StallDurationText -PollCount $batch.stall_poll_count

                    # ── Jira ticket (routing 2 or 3) ──
                    if ($routing -band 2) {
                        $jiraDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS ticket_exists
                            FROM Jira.RequestLog
                            WHERE Trigger_Type = '$triggerType'
                              AND Trigger_Value = '$triggerValue'
                              AND StatusCode = 201
                              AND TicketKey IS NOT NULL
                              AND TicketKey != 'Email'
"@
                        if (-not $jiraDedup) {
                            $jiraSummary = "New Business Batch Merge Stalled: $batchId"
                            $jiraDesc = @"
New Business Batch Merge Stalled

Batch ID: $batchId
Batch Name: $batchName
Merge Status: $mergeStatus
Consumers: $consCount
Stalled: $stallDuration with no log activity
Last Log Activity: $lastLogTime

Action: Check merge queue and batch status in Debt Manager. May need to reset batch to Uploaded and re-release.

Detection Date: $detectionTime
"@
                            $jiraSummarySafe = $jiraSummary -replace "'", "''"
                            $jiraDescSafe = $jiraDesc -replace "'", "''"

                            $queueTicketQuery = @"
                                EXEC Jira.sp_QueueTicket
                                    @SourceModule = 'BatchOps',
                                    @ProjectKey = '$jiraProjectKey',
                                    @Summary = N'$jiraSummarySafe',
                                    @Description = N'$jiraDescSafe',
                                    @IssueType = '$jiraIssueType',
                                    @Priority = '$jiraPriority',
                                    @EmailRecipients = '$jiraEmailRecipients',
                                    @CascadingField_ID = '$jiraCascadingFieldId',
                                    @CascadingField_ParentValue = '$jiraCascadingParent',
                                    @CascadingField_ChildValue = '$cascadingChild',
                                    @CustomField_ID = '$jiraCustomField1Id',
                                    @CustomField_Value = '$jiraCustomField1Value',
                                    @CustomField2_ID = '$jiraCustomField2Id',
                                    @CustomField2_Value = '$jiraCustomField2Value',
                                    @DueDate = '$jiraDueDate',
                                    @TriggerType = '$triggerType',
                                    @TriggerValue = '$triggerValue'
"@
                            Invoke-SqlNonQuery -Query $queueTicketQuery | Out-Null
                            Write-Log "    Jira ticket queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Jira dedup: ticket already exists for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Teams alert (routing 1 or 3) ──
                    if ($routing -band 1) {
                        $teamsDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS alert_exists
                            FROM Teams.RequestLog
                            WHERE trigger_type = '$triggerType'
                              AND trigger_value = '$triggerValue'
                              AND status_code = 200
"@
                        if (-not $teamsDedup) {
                            $teamsTitle = "{{FIRE}} New Business Batch Merge Stalled: $batchId"
                            $teamsColor = 'attention'
                            $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**Merge Status:** $mergeStatus
**Consumers:** $consCount
**Stalled:** $stallDuration with no log activity
**Last Activity:** $lastLogTime

Action: Check merge queue and batch status in Debt Manager. May need to reset batch to Uploaded and re-release.

**Detection:** $detectionTime
"@
                            $teamsTitleSafe = $teamsTitle -replace "'", "''"
                            $teamsMessageSafe = $teamsMessage -replace "'", "''"

                            $teamsInsert = @"
                                INSERT INTO Teams.AlertQueue (
                                    source_module, alert_category, title, message, color,
                                    trigger_type, trigger_value, status, created_dttm
                                )
                                VALUES (
                                    'BatchOps', 'CRITICAL', N'$teamsTitleSafe',
                                    N'$teamsMessageSafe', '$teamsColor',
                                    '$triggerType', '$triggerValue',
                                    'Pending', GETDATE()
                                )
"@
                            Invoke-SqlNonQuery -Query $teamsInsert | Out-Null
                            Write-Log "    Teams alert queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Teams dedup: alert already sent for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Increment alert_count ──
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.NB_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }


        # ══════════════════════════════════════════════════════════════════
        # CHECK 4: Upload Stall (stuck in UPLOADING too long)
        # Daily re-alert using composite trigger with date
        # ══════════════════════════════════════════════════════════════════
        $routing = $Script:Config.NB_Alert_UploadStall
        $uploadStallMinutes = $Script:Config.NB_UploadStallMinutes

        $uploadStallQuery = @"
            SELECT batch_id, batch_name, batch_created_dttm,
                   DATEDIFF(MINUTE, batch_created_dttm, GETDATE()) AS minutes_uploading,
                   alert_count
            FROM BatchOps.NB_BatchTracking
            WHERE is_complete = 0
              AND batch_status_code = 2
              AND DATEDIFF(MINUTE, batch_created_dttm, GETDATE()) >= $uploadStallMinutes
              AND NOT (is_auto_release = 0 AND is_manual_upload = 0 AND is_auto_merge = 0)
"@

        $uploadStalls = Get-SqlData -Query $uploadStallQuery

        if ($uploadStalls) {
            foreach ($batch in @($uploadStalls)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = $batch.batch_name
                Write-Log "  ALERT: Upload stall detected - batch $batchId ($batchName) - uploading for $($batch.minutes_uploading) minutes" "WARN"

                if ($Script:Config.NB_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $triggerType = 'NB_UploadStall'
                    $todayStr = (Get-Date).ToString("yyyy-MM-dd")
                    $triggerValue = "${batchId}_${todayStr}"
                    $cascadingChild = 'Upload Failure'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $createdTime = if ($batch.batch_created_dttm -isnot [DBNull]) { $batch.batch_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }

                    # ── Jira ticket (routing 2 or 3) ──
                    if ($routing -band 2) {
                        $jiraDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS ticket_exists
                            FROM Jira.RequestLog
                            WHERE Trigger_Type = '$triggerType'
                              AND Trigger_Value = '$triggerValue'
                              AND StatusCode = 201
                              AND TicketKey IS NOT NULL
                              AND TicketKey != 'Email'
"@
                        if (-not $jiraDedup) {
                            $jiraSummary = "New Business Batch Upload Stall: $batchId"
                            $jiraDesc = @"
New Business Batch Upload Stall

Batch ID: $batchId
Batch Name: $batchName
Created: $createdTime
Uploading For: $($batch.minutes_uploading) minutes (threshold: $uploadStallMinutes)

Action: Check upload process in Debt Manager. Upload may need to be cancelled and restarted.

Detection Date: $detectionTime
"@
                            $jiraSummarySafe = $jiraSummary -replace "'", "''"
                            $jiraDescSafe = $jiraDesc -replace "'", "''"

                            $queueTicketQuery = @"
                                EXEC Jira.sp_QueueTicket
                                    @SourceModule = 'BatchOps',
                                    @ProjectKey = '$jiraProjectKey',
                                    @Summary = N'$jiraSummarySafe',
                                    @Description = N'$jiraDescSafe',
                                    @IssueType = '$jiraIssueType',
                                    @Priority = '$jiraPriority',
                                    @EmailRecipients = '$jiraEmailRecipients',
                                    @CascadingField_ID = '$jiraCascadingFieldId',
                                    @CascadingField_ParentValue = '$jiraCascadingParent',
                                    @CascadingField_ChildValue = '$cascadingChild',
                                    @CustomField_ID = '$jiraCustomField1Id',
                                    @CustomField_Value = '$jiraCustomField1Value',
                                    @CustomField2_ID = '$jiraCustomField2Id',
                                    @CustomField2_Value = '$jiraCustomField2Value',
                                    @DueDate = '$jiraDueDate',
                                    @TriggerType = '$triggerType',
                                    @TriggerValue = '$triggerValue'
"@
                            Invoke-SqlNonQuery -Query $queueTicketQuery | Out-Null
                            Write-Log "    Jira ticket queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Jira dedup: ticket already exists for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Teams alert (routing 1 or 3) ──
                    if ($routing -band 1) {
                        $teamsDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS alert_exists
                            FROM Teams.RequestLog
                            WHERE trigger_type = '$triggerType'
                              AND trigger_value = '$triggerValue'
                              AND status_code = 200
"@
                        if (-not $teamsDedup) {
                            $teamsTitle = "{{WARN}} New Business Batch Upload Stall: $batchId"
                            $teamsColor = 'warning'
                            $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**Created:** $createdTime
**Uploading For:** $($batch.minutes_uploading) minutes (threshold: $uploadStallMinutes)

Action: Check upload process in Debt Manager. Upload may need to be cancelled and restarted.

**Detection:** $detectionTime
"@
                            $teamsTitleSafe = $teamsTitle -replace "'", "''"
                            $teamsMessageSafe = $teamsMessage -replace "'", "''"

                            $teamsInsert = @"
                                INSERT INTO Teams.AlertQueue (
                                    source_module, alert_category, title, message, color,
                                    trigger_type, trigger_value, status, created_dttm
                                )
                                VALUES (
                                    'BatchOps', 'WARNING', N'$teamsTitleSafe',
                                    N'$teamsMessageSafe', '$teamsColor',
                                    '$triggerType', '$triggerValue',
                                    'Pending', GETDATE()
                                )
"@
                            Invoke-SqlNonQuery -Query $teamsInsert | Out-Null
                            Write-Log "    Teams alert queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Teams dedup: alert already sent for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Increment alert_count ──
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.NB_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }


  # ══════════════════════════════════════════════════════════════════
        # CHECK 5a: Queue Wait (RELEASED, auto-merge ON, no log activity)
        # Standard threshold - these batches SHOULD be merging
        # Daily re-alert using composite trigger with date
        # ══════════════════════════════════════════════════════════════════
        $routing = $Script:Config.NB_Alert_QueueWait
        $queueWaitMinutes = $Script:Config.NB_QueueWaitMinutes

        $queueWaitQuery = @"
            SELECT batch_id, batch_name, release_completed_dttm, consumer_count,
                   DATEDIFF(MINUTE, release_completed_dttm, GETDATE()) AS minutes_in_queue,
                   alert_count
            FROM BatchOps.NB_BatchTracking
            WHERE is_complete = 0
              AND batch_status_code = 8
              AND last_log_id IS NULL
              AND release_completed_dttm IS NOT NULL
              AND is_auto_merge = 1
              AND DATEDIFF(MINUTE, release_completed_dttm, GETDATE()) >= $queueWaitMinutes
              AND NOT (is_auto_release = 0 AND is_manual_upload = 0 AND is_auto_merge = 0)
"@

        $queueWaits = Get-SqlData -Query $queueWaitQuery

        if ($queueWaits) {
            foreach ($batch in @($queueWaits)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = $batch.batch_name
                Write-Log "  ALERT: Queue wait detected - batch $batchId ($batchName) - waiting $($batch.minutes_in_queue) minutes" "WARN"

                if ($Script:Config.NB_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $triggerType = 'NB_QueueWait'
                    $todayStr = (Get-Date).ToString("yyyy-MM-dd")
                    $triggerValue = "${batchId}_${todayStr}"
                    $cascadingChild = 'Placement File Issue'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $releasedTime = if ($batch.release_completed_dttm -isnot [DBNull]) { $batch.release_completed_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }
                    $consCount = if ($batch.consumer_count -isnot [DBNull]) { $batch.consumer_count } else { 'N/A' }

                    # ── Jira ticket (routing 2 or 3) ──
                    if ($routing -band 2) {
                        $jiraDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS ticket_exists
                            FROM Jira.RequestLog
                            WHERE Trigger_Type = '$triggerType'
                              AND Trigger_Value = '$triggerValue'
                              AND StatusCode = 201
                              AND TicketKey IS NOT NULL
                              AND TicketKey != 'Email'
"@
                        if (-not $jiraDedup) {
                            $jiraSummary = "New Business Batch Queue Wait: $batchId"
                            $jiraDesc = @"
New Business Batch Queue Wait

Batch ID: $batchId
Batch Name: $batchName
Consumers: $consCount
Released: $releasedTime
Waiting: $($batch.minutes_in_queue) minutes (threshold: $queueWaitMinutes)

No merge log activity since release. Merge queue may be backed up or batch may not have been picked up.

Detection Date: $detectionTime
"@
                            $jiraSummarySafe = $jiraSummary -replace "'", "''"
                            $jiraDescSafe = $jiraDesc -replace "'", "''"

                            $queueTicketQuery = @"
                                EXEC Jira.sp_QueueTicket
                                    @SourceModule = 'BatchOps',
                                    @ProjectKey = '$jiraProjectKey',
                                    @Summary = N'$jiraSummarySafe',
                                    @Description = N'$jiraDescSafe',
                                    @IssueType = '$jiraIssueType',
                                    @Priority = '$jiraPriority',
                                    @EmailRecipients = '$jiraEmailRecipients',
                                    @CascadingField_ID = '$jiraCascadingFieldId',
                                    @CascadingField_ParentValue = '$jiraCascadingParent',
                                    @CascadingField_ChildValue = '$cascadingChild',
                                    @CustomField_ID = '$jiraCustomField1Id',
                                    @CustomField_Value = '$jiraCustomField1Value',
                                    @CustomField2_ID = '$jiraCustomField2Id',
                                    @CustomField2_Value = '$jiraCustomField2Value',
                                    @DueDate = '$jiraDueDate',
                                    @TriggerType = '$triggerType',
                                    @TriggerValue = '$triggerValue'
"@
                            Invoke-SqlNonQuery -Query $queueTicketQuery | Out-Null
                            Write-Log "    Jira ticket queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Jira dedup: ticket already exists for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Teams alert (routing 1 or 3) ──
                    if ($routing -band 1) {
                        $teamsDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS alert_exists
                            FROM Teams.RequestLog
                            WHERE trigger_type = '$triggerType'
                              AND trigger_value = '$triggerValue'
                              AND status_code = 200
"@
                        if (-not $teamsDedup) {
                            $teamsTitle = "{{WARN}} New Business Batch Queue Wait: $batchId"
                            $teamsColor = 'warning'
                            $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**Consumers:** $consCount
**Released:** $releasedTime
**Waiting:** $($batch.minutes_in_queue) minutes (threshold: $queueWaitMinutes)

No merge log activity since release. Merge queue may be backed up or batch may not have been picked up.

**Detection:** $detectionTime
"@
                            $teamsTitleSafe = $teamsTitle -replace "'", "''"
                            $teamsMessageSafe = $teamsMessage -replace "'", "''"

                            $teamsInsert = @"
                                INSERT INTO Teams.AlertQueue (
                                    source_module, alert_category, title, message, color,
                                    trigger_type, trigger_value, status, created_dttm
                                )
                                VALUES (
                                    'BatchOps', 'WARNING', N'$teamsTitleSafe',
                                    N'$teamsMessageSafe', '$teamsColor',
                                    '$triggerType', '$triggerValue',
                                    'Pending', GETDATE()
                                )
"@
                            Invoke-SqlNonQuery -Query $teamsInsert | Out-Null
                            Write-Log "    Teams alert queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Teams dedup: alert already sent for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Increment alert_count ──
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.NB_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }


        # ══════════════════════════════════════════════════════════════════
        # CHECK 5b: Queue Wait (RELEASED, auto-merge OFF, no log activity)
        # Longer threshold - these batches are intentionally held
        # Daily re-alert using composite trigger with date
        # ══════════════════════════════════════════════════════════════════
        $routingNoMerge = $Script:Config.NB_Alert_QueueWaitNoMerge
        $queueWaitNoMergeMinutes = $Script:Config.NB_QueueWaitNoMergeMinutes

        $queueWaitNoMergeQuery = @"
            SELECT batch_id, batch_name, release_completed_dttm, consumer_count,
                   DATEDIFF(MINUTE, release_completed_dttm, GETDATE()) AS minutes_in_queue,
                   alert_count
            FROM BatchOps.NB_BatchTracking
            WHERE is_complete = 0
              AND batch_status_code = 8
              AND last_log_id IS NULL
              AND release_completed_dttm IS NOT NULL
              AND is_auto_merge = 0
              AND DATEDIFF(MINUTE, release_completed_dttm, GETDATE()) >= $queueWaitNoMergeMinutes
              AND NOT (is_auto_release = 0 AND is_manual_upload = 0 AND is_auto_merge = 0)
"@

        $queueWaitNoMerge = Get-SqlData -Query $queueWaitNoMergeQuery

        if ($queueWaitNoMerge) {
            foreach ($batch in @($queueWaitNoMerge)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = $batch.batch_name
                Write-Log "  ALERT: No-auto-merge queue wait detected - batch $batchId ($batchName) - waiting $($batch.minutes_in_queue) minutes" "WARN"

                if ($Script:Config.NB_AlertingEnabled -and -not $PreviewOnly -and $routingNoMerge -gt 0) {
                    $triggerType = 'NB_QueueWaitNoMerge'
                    $todayStr = (Get-Date).ToString("yyyy-MM-dd")
                    $triggerValue = "${batchId}_${todayStr}"
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $releasedTime = if ($batch.release_completed_dttm -isnot [DBNull]) { $batch.release_completed_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }
                    $consCount = if ($batch.consumer_count -isnot [DBNull]) { $batch.consumer_count } else { 'N/A' }
                    $hoursWaiting = [math]::Round($batch.minutes_in_queue / 60, 1)

                    # ── Jira ticket (routing 2 or 3) ──
                    if ($routingNoMerge -band 2) {
                        $jiraDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS ticket_exists
                            FROM Jira.RequestLog
                            WHERE Trigger_Type = '$triggerType'
                              AND Trigger_Value = '$triggerValue'
                              AND StatusCode = 201
                              AND TicketKey IS NOT NULL
                              AND TicketKey != 'Email'
"@
                        if (-not $jiraDedup) {
                            $jiraSummary = "New Business Batch Held (No Auto-Merge): $batchId"
                            $jiraDesc = @"
New Business Batch Held - Auto-Merge Disabled

Batch ID: $batchId
Batch Name: $batchName
Consumers: $consCount
Released: $releasedTime
Waiting: $hoursWaiting hours (threshold: $([math]::Round($queueWaitNoMergeMinutes / 60, 1)) hours)

This batch has auto-merge disabled and has been in RELEASED status without merge activity.
Manual merge initiation may be required.

Detection Date: $detectionTime
"@
                            $jiraSummarySafe = $jiraSummary -replace "'", "''"
                            $jiraDescSafe = $jiraDesc -replace "'", "''"

                            $queueTicketQuery = @"
                                EXEC Jira.sp_QueueTicket
                                    @SourceModule = 'BatchOps',
                                    @ProjectKey = '$jiraProjectKey',
                                    @Summary = N'$jiraSummarySafe',
                                    @Description = N'$jiraDescSafe',
                                    @IssueType = '$jiraIssueType',
                                    @Priority = '$jiraPriority',
                                    @EmailRecipients = '$jiraEmailRecipients',
                                    @CascadingField_ID = '$jiraCascadingFieldId',
                                    @CascadingField_ParentValue = '$jiraCascadingParent',
                                    @CascadingField_ChildValue = 'Placement File Issue',
                                    @CustomField_ID = '$jiraCustomField1Id',
                                    @CustomField_Value = '$jiraCustomField1Value',
                                    @CustomField2_ID = '$jiraCustomField2Id',
                                    @CustomField2_Value = '$jiraCustomField2Value',
                                    @DueDate = '$jiraDueDate',
                                    @TriggerType = '$triggerType',
                                    @TriggerValue = '$triggerValue'
"@
                            Invoke-SqlNonQuery -Query $queueTicketQuery | Out-Null
                            Write-Log "    Jira ticket queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Jira dedup: ticket already exists for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Teams alert (routing 1 or 3) ──
                    if ($routingNoMerge -band 1) {
                        $teamsDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS alert_exists
                            FROM Teams.RequestLog
                            WHERE trigger_type = '$triggerType'
                              AND trigger_value = '$triggerValue'
                              AND status_code = 200
"@
                        if (-not $teamsDedup) {
                            $teamsTitle = "{{INFO}} New Business Batch Held (No Auto-Merge): $batchId"
                            $teamsColor = 'accent'
                            $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**Consumers:** $consCount
**Released:** $releasedTime
**Waiting:** $hoursWaiting hours (threshold: $([math]::Round($queueWaitNoMergeMinutes / 60, 1)) hours)

This batch has auto-merge disabled and has been in RELEASED status without merge activity. Manual merge initiation may be required.

**Detection:** $detectionTime
"@
                            $teamsTitleSafe = $teamsTitle -replace "'", "''"
                            $teamsMessageSafe = $teamsMessage -replace "'", "''"

                            $teamsInsert = @"
                                INSERT INTO Teams.AlertQueue (
                                    source_module, alert_category, title, message, color,
                                    trigger_type, trigger_value, status, created_dttm
                                )
                                VALUES (
                                    'BatchOps', 'INFO', N'$teamsTitleSafe',
                                    N'$teamsMessageSafe', '$teamsColor',
                                    '$triggerType', '$triggerValue',
                                    'Pending', GETDATE()
                                )
"@
                            Invoke-SqlNonQuery -Query $teamsInsert | Out-Null
                            Write-Log "    Teams alert queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Teams dedup: alert already sent for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Increment alert_count ──
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.NB_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }


        # ══════════════════════════════════════════════════════════════════
        # CHECK 6: Unreleased Batch (manual release pending too long)
        # Daily re-alert using composite trigger with date
        # ══════════════════════════════════════════════════════════════════
        $routing = $Script:Config.NB_Alert_Unreleased
        $unreleasedMinutes = $Script:Config.NB_UnreleasedMinutes

        $unreleasedQuery = @"
            SELECT batch_id, batch_name, upload_filename, account_count,
                   batch_created_dttm, batch_status, batch_status_code,
                   DATEDIFF(MINUTE, batch_created_dttm, GETDATE()) AS minutes_waiting,
                   alert_count
            FROM BatchOps.NB_BatchTracking
            WHERE is_complete = 0
              AND batch_status_code IN (4, 6)
              AND is_auto_release = 0
              AND DATEDIFF(MINUTE, batch_created_dttm, GETDATE()) >= $unreleasedMinutes
              AND NOT (is_auto_release = 0 AND is_manual_upload = 0 AND is_auto_merge = 0)
"@

        $unreleasedBatches = Get-SqlData -Query $unreleasedQuery

        if ($unreleasedBatches) {
            foreach ($batch in @($unreleasedBatches)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = $batch.batch_name
                Write-Log "  ALERT: Unreleased batch detected - batch $batchId ($batchName) - waiting $($batch.minutes_waiting) minutes" "WARN"

                if ($Script:Config.NB_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $triggerType = 'NB_Unreleased'
                    $todayStr = (Get-Date).ToString("yyyy-MM-dd")
                    $triggerValue = "${batchId}_${todayStr}"
                    $cascadingChild = 'Placement File Issue'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $uploadFile = if ($batch.upload_filename -isnot [DBNull]) { $batch.upload_filename } else { 'N/A' }
                    $acctCount = if ($batch.account_count -isnot [DBNull]) { $batch.account_count } else { 0 }
                    $createdTime = if ($batch.batch_created_dttm -isnot [DBNull]) { $batch.batch_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }
                    $hoursWaiting = [math]::Round($batch.minutes_waiting / 60, 1)

                    # ── Jira ticket (routing 2 or 3) ──
                    if ($routing -band 2) {
                        $jiraDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS ticket_exists
                            FROM Jira.RequestLog
                            WHERE Trigger_Type = '$triggerType'
                              AND Trigger_Value = '$triggerValue'
                              AND StatusCode = 201
                              AND TicketKey IS NOT NULL
                              AND TicketKey != 'Email'
"@
                        if (-not $jiraDedup) {
                            $jiraSummary = "New Business Batch Awaiting Release: $batchId"
                            $jiraDesc = @"
New Business Batch Awaiting Manual Release

Batch ID: $batchId
Batch Name: $batchName
Filename: $uploadFile
Records: $acctCount
Status: $($batch.batch_status)
Created: $createdTime
Waiting: $hoursWaiting hours (threshold: $([math]::Round($unreleasedMinutes / 60, 1)) hours)

Action: Release this batch manually in Debt Manager. Client is not configured for auto-release.

Detection Date: $detectionTime
"@
                            $jiraSummarySafe = $jiraSummary -replace "'", "''"
                            $jiraDescSafe = $jiraDesc -replace "'", "''"

                            $queueTicketQuery = @"
                                EXEC Jira.sp_QueueTicket
                                    @SourceModule = 'BatchOps',
                                    @ProjectKey = '$jiraProjectKey',
                                    @Summary = N'$jiraSummarySafe',
                                    @Description = N'$jiraDescSafe',
                                    @IssueType = '$jiraIssueType',
                                    @Priority = '$jiraPriority',
                                    @EmailRecipients = '$jiraEmailRecipients',
                                    @CascadingField_ID = '$jiraCascadingFieldId',
                                    @CascadingField_ParentValue = '$jiraCascadingParent',
                                    @CascadingField_ChildValue = '$cascadingChild',
                                    @CustomField_ID = '$jiraCustomField1Id',
                                    @CustomField_Value = '$jiraCustomField1Value',
                                    @CustomField2_ID = '$jiraCustomField2Id',
                                    @CustomField2_Value = '$jiraCustomField2Value',
                                    @DueDate = '$jiraDueDate',
                                    @TriggerType = '$triggerType',
                                    @TriggerValue = '$triggerValue'
"@
                            Invoke-SqlNonQuery -Query $queueTicketQuery | Out-Null
                            Write-Log "    Jira ticket queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Jira dedup: ticket already exists for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Teams alert (routing 1 or 3) ──
                    if ($routing -band 1) {
                        $teamsDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS alert_exists
                            FROM Teams.RequestLog
                            WHERE trigger_type = '$triggerType'
                              AND trigger_value = '$triggerValue'
                              AND status_code = 200
"@
                        if (-not $teamsDedup) {
                            $teamsTitle = "{{WARN}} New Business Batch Awaiting Release: $batchId"
                            $teamsColor = 'warning'
                            $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**File:** $uploadFile
**Records:** $acctCount
**Status:** $($batch.batch_status)
**Created:** $createdTime
**Waiting:** $hoursWaiting hours

Action: Release this batch manually in Debt Manager. Client is not configured for auto-release.

**Detection:** $detectionTime
"@
                            $teamsTitleSafe = $teamsTitle -replace "'", "''"
                            $teamsMessageSafe = $teamsMessage -replace "'", "''"

                            $teamsInsert = @"
                                INSERT INTO Teams.AlertQueue (
                                    source_module, alert_category, title, message, color,
                                    trigger_type, trigger_value, status, created_dttm
                                )
                                VALUES (
                                    'BatchOps', 'WARNING', N'$teamsTitleSafe',
                                    N'$teamsMessageSafe', '$teamsColor',
                                    '$triggerType', '$triggerValue',
                                    'Pending', GETDATE()
                                )
"@
                            Invoke-SqlNonQuery -Query $teamsInsert | Out-Null
                            Write-Log "    Teams alert queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Teams dedup: alert already sent for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Increment alert_count ──
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.NB_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }

        # ══════════════════════════════════════════════════════════════════
        # CHECK 7: Release-Merge Skip Stall (RELEASING but merge has started, stalled)
        # Fires when batch is in RELEASING+merging state and stall_poll_count reaches threshold
        # Alert count resets when activity resumes, allowing re-alerting on subsequent stall episodes
        # ══════════════════════════════════════════════════════════════════
        $routing = $Script:Config.NB_Alert_ReleaseMergeSkip
        $releaseMergeSkipThreshold = $Script:Config.NB_ReleaseMergeSkipStallThreshold

        $releaseMergeSkipQuery = @"
            SELECT batch_id, batch_name, batch_status, merge_status, merge_status_code,
                   upload_filename, account_count, consumer_count,
                   batch_created_dttm, release_started_dttm, alert_count,
                   stall_poll_count, last_log_id, last_log_dttm
            FROM BatchOps.NB_BatchTracking
            WHERE is_complete = 0
              AND batch_status_code = 7
              AND merge_status_code >= 2
              AND stall_poll_count >= $releaseMergeSkipThreshold
              AND alert_count = 0
              AND NOT (is_auto_release = 0 AND is_manual_upload = 0 AND is_auto_merge = 0)
"@

        $releaseMergeSkips = Get-SqlData -Query $releaseMergeSkipQuery

        if ($releaseMergeSkips) {
            foreach ($batch in @($releaseMergeSkips)) {
                $alertsDetected++
                $batchId = $batch.batch_id
                $batchName = $batch.batch_name
                $stallDuration = Get-StallDurationText -PollCount $batch.stall_poll_count
                Write-Log "  ALERT: Release-merge skip stall - batch $batchId ($batchName) - RELEASING+merging with no activity for $stallDuration" "WARN"

                if ($Script:Config.NB_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $triggerType = 'NB_ReleaseMergeSkip'
                    $triggerValue = "$batchId"
                    $cascadingChild = 'Placement File Issue'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $uploadFile = if ($batch.upload_filename -isnot [DBNull]) { $batch.upload_filename } else { 'N/A' }
                    $acctCount = if ($batch.account_count -isnot [DBNull]) { $batch.account_count } else { 0 }
                    $consCount = if ($batch.consumer_count -isnot [DBNull]) { $batch.consumer_count } else { 'N/A' }
                    $mergeStatus = if ($batch.merge_status -isnot [DBNull]) { $batch.merge_status } else { 'N/A' }
                    $rlsStarted = if ($batch.release_started_dttm -isnot [DBNull]) { $batch.release_started_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }
                    $lastLogTime = if ($batch.last_log_dttm -isnot [DBNull]) { $batch.last_log_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }

                    # ── Jira ticket (routing 2 or 3) ──
                    if ($routing -band 2) {
                        $jiraDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS ticket_exists
                            FROM Jira.RequestLog
                            WHERE Trigger_Type = '$triggerType'
                              AND Trigger_Value = '$triggerValue'
                              AND StatusCode = 201
                              AND TicketKey IS NOT NULL
                              AND TicketKey != 'Email'
"@
                        if (-not $jiraDedup) {
                            $jiraSummary = "New Business Batch Release-Merge Skip Stall: $batchId"
                            $jiraDesc = @"
New Business Batch Release-Merge Skip Stall

Batch ID: $batchId
Batch Name: $batchName
Filename: $uploadFile
Records: $acctCount
Consumers: $consCount
Batch Status: RELEASING (code 7)
Merge Status: $mergeStatus
Release Started: $rlsStarted
Stalled: $stallDuration with no log activity
Last Log Activity: $lastLogTime

This batch is in RELEASING status with active merging but has not produced any new log activity ($stallDuration). This may indicate the batch is stuck and requires manual intervention, or it may recover on its own.

If the batch does not resume processing, set it back to Uploaded status and re-release manually.

Detection Date: $detectionTime
"@
                            $jiraSummarySafe = $jiraSummary -replace "'", "''"
                            $jiraDescSafe = $jiraDesc -replace "'", "''"

                            $queueTicketQuery = @"
                                EXEC Jira.sp_QueueTicket
                                    @SourceModule = 'BatchOps',
                                    @ProjectKey = '$jiraProjectKey',
                                    @Summary = N'$jiraSummarySafe',
                                    @Description = N'$jiraDescSafe',
                                    @IssueType = '$jiraIssueType',
                                    @Priority = '$jiraPriority',
                                    @EmailRecipients = '$jiraEmailRecipients',
                                    @CascadingField_ID = '$jiraCascadingFieldId',
                                    @CascadingField_ParentValue = '$jiraCascadingParent',
                                    @CascadingField_ChildValue = '$cascadingChild',
                                    @CustomField_ID = '$jiraCustomField1Id',
                                    @CustomField_Value = '$jiraCustomField1Value',
                                    @CustomField2_ID = '$jiraCustomField2Id',
                                    @CustomField2_Value = '$jiraCustomField2Value',
                                    @DueDate = '$jiraDueDate',
                                    @TriggerType = '$triggerType',
                                    @TriggerValue = '$triggerValue'
"@
                            Invoke-SqlNonQuery -Query $queueTicketQuery | Out-Null
                            Write-Log "    Jira ticket queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Jira dedup: ticket already exists for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Teams alert (routing 1 or 3) ──
                    if ($routing -band 1) {
                        $teamsDedup = Get-SqlData -Query @"
                            SELECT TOP 1 1 AS alert_exists
                            FROM Teams.RequestLog
                            WHERE trigger_type = '$triggerType'
                              AND trigger_value = '$triggerValue'
                              AND status_code = 200
"@
                        if (-not $teamsDedup) {
                            $teamsTitle = "{{FIRE}} New Business Batch Release-Merge Skip Stall: $batchId"
                            $teamsColor = 'attention'
                            $teamsMessage = @"
**Batch ID:** $batchId
**Batch Name:** $batchName
**File:** $uploadFile
**Records:** $acctCount
**Batch Status:** RELEASING (should be RELEASED)
**Merge Status:** $mergeStatus
**Stalled:** $stallDuration with no log activity
**Last Log Activity:** $lastLogTime

Batch is in RELEASING+merging state with no progress ($stallDuration).
May recover on its own or may require manual intervention.

If batch does not resume, set back to Uploaded and re-release.

**Detection:** $detectionTime
"@
                            $teamsTitleSafe = $teamsTitle -replace "'", "''"
                            $teamsMessageSafe = $teamsMessage -replace "'", "''"

                            $teamsInsert = @"
                                INSERT INTO Teams.AlertQueue (
                                    source_module, alert_category, title, message, color,
                                    trigger_type, trigger_value, status, created_dttm
                                )
                                VALUES (
                                    'BatchOps', 'CRITICAL', N'$teamsTitleSafe',
                                    N'$teamsMessageSafe', '$teamsColor',
                                    '$triggerType', '$triggerValue',
                                    'Pending', GETDATE()
                                )
"@
                            Invoke-SqlNonQuery -Query $teamsInsert | Out-Null
                            Write-Log "    Teams alert queued for batch $batchId" "SUCCESS"
                        }
                        else {
                            Write-Log "    Teams dedup: alert already sent for $triggerType/$triggerValue" "INFO"
                        }
                    }

                    # ── Increment alert_count ──
                    Invoke-SqlNonQuery -Query @"
                        UPDATE BatchOps.NB_BatchTracking
                        SET alert_count = alert_count + 1
                        WHERE batch_id = $batchId
"@ | Out-Null

                    $alertsFired++
                }
            }
        }


        Write-Log "  Alert conditions detected: $alertsDetected, Alerts fired: $alertsFired" "INFO"
        return @{ Detected = $alertsDetected; Fired = $alertsFired }
    }
    catch {
        Write-Log "  Error in Evaluate Alerts: $($_.Exception.Message)" "ERROR"
        return @{ Detected = $alertsDetected; Fired = $alertsFired; Error = $_.Exception.Message }
    }
}

function Step-UpdateStatus {
    <#
    .SYNOPSIS
        Updates BatchOps.Status with execution results
    #>
    param(
        [bool]$PreviewOnly = $true,
        [string]$Status = "SUCCESS",
        [int]$DurationMs = 0
    )

    if ($PreviewOnly) {
        Write-Log "  [Preview] Would update BatchOps.Status for Collect-NBBatchStatus" "INFO"
        return
    }

    try {
        $statusQuery = @"
            UPDATE BatchOps.Status
            SET processing_status = 'IDLE',
                completed_dttm = GETDATE(),
                last_duration_ms = $DurationMs,
                last_status = '$Status'
            WHERE collector_name = 'Collect-NBBatchStatus'
"@

        Invoke-SqlNonQuery -Query $statusQuery | Out-Null
    }
    catch {
        Write-Log "  Failed to update Status: $($_.Exception.Message)" "WARN"
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$scriptStart = Get-Date

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  xFACts NB Batch Status Collection v1.3.0" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

if ($Execute) {
    Write-Log "Mode: EXECUTE (changes will be applied)" "WARN"
}
else {
    Write-Log "Mode: PREVIEW (no changes will be made)" "INFO"
}

Write-Host ""

# Initialize configuration and server connections
if (-not (Initialize-Configuration)) {
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

Write-Host ""

$previewOnly = -not $Execute
$stepResults = @{}

# Mark as RUNNING
if (-not $previewOnly) {
    Invoke-SqlNonQuery -Query @"
        UPDATE BatchOps.Status
        SET processing_status = 'RUNNING',
            started_dttm = GETDATE()
        WHERE collector_name = 'Collect-NBBatchStatus'
"@ | Out-Null
}

Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Executing Steps" -ForegroundColor DarkGray
Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# Step 1: Collect new batches from DM
$stepResults.Collect = Step-CollectNewBatches -PreviewOnly $previewOnly

# Step 2: Update all incomplete batches
$stepResults.Update = Step-UpdateIncompleteBatches -PreviewOnly $previewOnly

# Step 3: Detect orphaned batches (hard-deleted from DM)
$stepResults.Orphans = Step-DetectOrphanedBatches -PreviewOnly $previewOnly

# Step 4: Evaluate alert conditions
$stepResults.Alerts = Step-EvaluateAlerts -PreviewOnly $previewOnly

# ============================================================================
# SUMMARY
# ============================================================================

$scriptEnd = Get-Date
$scriptDuration = $scriptEnd - $scriptStart
$totalMs = [int]$scriptDuration.TotalMilliseconds

$finalStatus = "SUCCESS"
if ($stepResults.Collect.Error -or $stepResults.Update.Error -or $stepResults.Orphans.Error -or $stepResults.Alerts.Error) {
    $finalStatus = "FAILED"
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Execution Summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Read Server:  $($Script:ReadServer)"
Write-Host "  Write Server: $($Script:WriteServer)"
Write-Host ""
Write-Host "  Results:"
Write-Host "    New Batches:       $($stepResults.Collect.NewBatches)"
Write-Host "    Batches Updated:   $($stepResults.Update.Updated)"
Write-Host "    Batches Completed: $($stepResults.Update.Completed)"
Write-Host "    Orphans Resolved:  $($stepResults.Orphans.Orphaned)"
Write-Host "    Alerts Detected:   $($stepResults.Alerts.Detected)"
Write-Host "    Alerts Fired:      $($stepResults.Alerts.Fired)"
Write-Host ""
Write-Host "  Duration: $totalMs ms"
Write-Host ""

if (-not $Execute) {
    Write-Host "  *** PREVIEW MODE - No changes were made ***" -ForegroundColor Yellow
    Write-Host "  Run with -Execute to perform actual updates" -ForegroundColor Yellow
    Write-Host ""
}

# Update Status table
Step-UpdateStatus -PreviewOnly $previewOnly -Status $finalStatus -DurationMs $totalMs

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  NB Batch Status Collection Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Orchestrator callback
if ($TaskId -gt 0) {
    $outputSummary = "New:$($stepResults.Collect.NewBatches) Updated:$($stepResults.Update.Updated) Completed:$($stepResults.Update.Completed) Orphans:$($stepResults.Orphans.Orphaned) Alerts:$($stepResults.Alerts.Detected)"

    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status $finalStatus -DurationMs $totalMs `
        -Output $outputSummary
}

if ($finalStatus -eq "FAILED") { exit 1 } else { exit 0 }
<#
.SYNOPSIS
    xFACts - BDL Batch Status Collection

.DESCRIPTION
    Monitors Debt Manager BDL (Bulk Data Load) file lifecycle from registration
    through terminal state. Collects new files, updates status for in-flight files
    with partition-based progress tracking, captures DM summary counts, and
    evaluates alert conditions.

    Terminal state is determined by File_Registry.file_stts_cd (authoritative):
      5 = PROCESSED (success)
      6 = FAILED (failure)
      7 = CANCELED (failure, never observed)
      8 = PARTIALLY_PROCESSED (partial success)

    Non-terminal File_Registry statuses (file remains in-flight):
      0 = UNKNOWN, 1 = NEW, 2 = UPDATING, 3 = READY, 4 = PROCESSING,
      9 = WAITING, 10 = STAGED, 11 = RETRY

    BDL lifecycle in bdl_log (used for progress tracking and timestamps, NOT terminal detection):
      File-level rows (sub_entty_nm_txt IS NULL): PROCESSING (2), STAGED (10), IMPORTED (12)
      Cleanup rows excluded from tracking: DELETING (13), DELETED (14), DELETE_FAILED (15)

    Follows the xFACts collect/evaluate pattern: reads from a configurable AG replica
    for DM queries, writes to xFACts via the AG listener for all BatchOps.* table
    updates, detects current PRIMARY/SECONDARY roles automatically, and supports
    preview mode for safe testing.

.PARAMETER ServerInstance
    SQL Server instance hosting xFACts database (default: AVG-PROD-LSNR).

.PARAMETER Database
    xFACts database name (default: xFACts).

.PARAMETER SourceDB
    Source database for Debt Manager data (default: crs5_oltp).

.PARAMETER Execute
    Perform writes. Without this flag, runs in preview/dry-run mode.

.PARAMETER ForceSourceServer
    Override the GlobalConfig replica setting and connect to a specific server for reads.

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Default 0.

.COMPONENT
    BatchOps

.NOTES
    File Name : Collect-BDLBatchStatus.ps1
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
#             Removed the local Get-bat_BDL_SourceData, Get-bat_BDL_-
#             AGReplicaRoles, and Get-bat_BDL_StallDurationText; calls now
#             use Get-bat_SourceData, the shared Get-AGReplicaRoles via
#             Resolve-bat_ReadServer, and Get-bat_StallDurationText.
#             BatchOps.Status writes go through Set-bat_BatchStatus, and
#             the alert dispatch through Send-bat_BatchAlert. Dropped the
#             dead AGPrimary/AGSecondary script variables. Behavior
#             unchanged.
# 2026-04-06  Terminal detection refactored to use File_Registry.file_stts_cd
#             instead of bdl_log status codes. file_registry_status_code stored on tracking row.
#             completed_status vocabulary aligned with DM: PROCESSED, FAILED,
#             PARTIALLY_PROCESSED, CANCELED. ABANDONED status retired.
#             completed_dttm sourced from File_Registry.upsrt_dttm.
#             Alert evaluation consolidated: STAGEFAILED + IMPORT_FAILED merged
#             into single FAILED check.
# 2026-04-04  Refactored to bulk query pattern matching NB/PMT collectors.
#             Collect step uses single bulk query with joins instead of per-file queries.
#             Update step uses bulk queries for status, partitions, and custom details.
# 2026-04-04  Initial implementation. Three-step execution: Collect -> Update -> Evaluate.
#             Partition-based progress and stall detection. DM summary counts from
#             file_rgstry_dtl / file_rgstry_cstm_dtl. Three alert conditions:
#             STAGEFAILED, IMPORT_FAILED, Stall.

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

Initialize-XFActsScript -ScriptName 'Collect-BDLBatchStatus' `
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

# Loaded GlobalConfig settings and BDL thresholds.
$script:Config = @{}

# Orchestrator polling interval in minutes, resolved from ProcessRegistry at runtime.
$script:PollingIntervalMinutes = $null

<# ============================================================================
   FUNCTIONS: SOURCE AND CONFIGURATION
   ----------------------------------------------------------------------------
   Source-data access, AG replica role detection, configuration loading, and
   the stall-duration text helper.
   Prefix: bat
   ============================================================================ #>

# Loads GlobalConfig settings, resolves AG replica roles, and sets read/write servers.
function Initialize-bat_BDL_Configuration {
    param()
    Write-Log "Loading configuration..." "INFO"

    $configQuery = @"
        SELECT module_name, setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name IN ('BatchOps', 'Shared', 'dbo')
          AND is_active = 1
"@
    $configResults = Get-SqlData -Query $configQuery

    $script:Config = @{
        AGName                          = "DMPRODAG"
        SourceReplica                   = "SECONDARY"
        BDL_StallPollThreshold          = 12
        BDL_AlertingEnabled             = $false
        BDL_LookbackDays                = 7
        BDL_Alert_Failed                = 3
        BDL_Alert_Stall                 = 1
    }

    if ($configResults) {
        foreach ($row in $configResults) {
            switch ($row.setting_name) {
                "AGName"                            { $script:Config.AGName = $row.setting_value }
                "SourceReplica"                     { $script:Config.SourceReplica = $row.setting_value }
                "bdl_stall_poll_threshold"          { $script:Config.BDL_StallPollThreshold = [int]$row.setting_value }
                "bdl_alerting_enabled"              { $script:Config.BDL_AlertingEnabled = [bool][int]$row.setting_value }
                "bdl_lookback_days"                 { $script:Config.BDL_LookbackDays = [int]$row.setting_value }
                "bdl_alert_failed_routing"          { $script:Config.BDL_Alert_Failed = [int]$row.setting_value }
                "bdl_alert_stall_routing"           { $script:Config.BDL_Alert_Stall = [int]$row.setting_value }
            }
        }
    }

    Write-Log "  AGName: $($script:Config.AGName)" "INFO"
    Write-Log "  SourceReplica: $($script:Config.SourceReplica)" "INFO"
    Write-Log "  BDL_StallPollThreshold: $($script:Config.BDL_StallPollThreshold)" "INFO"
    Write-Log "  BDL_AlertingEnabled: $($script:Config.BDL_AlertingEnabled)" "INFO"
    Write-Log "  BDL_LookbackDays: $($script:Config.BDL_LookbackDays)" "INFO"

    $script:WriteServer = $ServerInstance

    $script:ReadServer = Resolve-bat_ReadServer -AGName $script:Config.AGName -SourceReplica $script:Config.SourceReplica -ForceSourceServer $ForceSourceServer
    if (-not $script:ReadServer) {
        return $false
    }

    Write-Log "  WriteServer: $($script:WriteServer)" "INFO"

    $script:PollingIntervalMinutes = $null
    if ($ProcessId -gt 0) {
        $intervalQuery = "SELECT interval_seconds FROM Orchestrator.ProcessRegistry WHERE process_id = $ProcessId"
        $intervalResult = Get-SqlData -Query $intervalQuery
        if ($intervalResult -and $intervalResult.interval_seconds -isnot [DBNull]) {
            $script:PollingIntervalMinutes = [math]::Round($intervalResult.interval_seconds / 60, 1)
            Write-Log "  PollingIntervalMinutes: $($script:PollingIntervalMinutes) (from ProcessRegistry)" "INFO"
        } else {
            Write-Log "  PollingIntervalMinutes: unknown (ProcessRegistry lookup failed)" "WARN"
        }
    } else {
        Write-Log "  PollingIntervalMinutes: unknown (manual run, no ProcessId)" "INFO"
    }

    return $true
}

<# ============================================================================
   FUNCTIONS: COLLECTION STEPS
   ----------------------------------------------------------------------------
   The three-step collect/update/evaluate pipeline executed against tracked BDL files.
   Prefix: bat
   ============================================================================ #>

# Discovers new BDL files in DM not yet tracked in xFACts and inserts them.
function Step-bat_BDL_CollectNewFiles {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect New Files" "STEP"
    $newFileCount = 0

    try {
        $trackedQuery = "SELECT file_registry_id FROM BatchOps.BDL_BatchTracking"
        $trackedFiles = Get-SqlData -Query $trackedQuery
        $trackedIds = @()
        if ($trackedFiles) { $trackedIds = @($trackedFiles | ForEach-Object { $_.file_registry_id }) }

        $lookbackDays = $script:Config.BDL_LookbackDays

        # Single bulk query: all BDL file data in one round trip
        # Terminal detection from File_Registry.file_stts_cd, not bdl_log
        $sourceQuery = @"
            ;WITH CurrentBDLStatus AS (
                SELECT
                    bl.file_registry_id,
                    bl.bdl_prcss_stss_cd,
                    s.entty_async_stts_val_txt AS status_text,
                    bl.bdl_log_msg,
                    bl.crtd_dttm,
                    ROW_NUMBER() OVER (PARTITION BY bl.file_registry_id ORDER BY bl.crtd_dttm DESC) AS rn
                FROM dbo.bdl_log bl
                INNER JOIN dbo.ref_entty_async_stts_cd s ON bl.bdl_prcss_stss_cd = s.entty_async_stts_cd
                WHERE bl.sub_entty_nm_txt IS NULL
                  AND bl.bdl_prcss_stss_cd NOT IN (13, 14, 15)
                  AND bl.crtd_dttm >= DATEADD(DAY, -$lookbackDays, GETDATE())
            ),
            FileTimestamps AS (
                SELECT bl.file_registry_id,
                    MIN(CASE WHEN bl.bdl_prcss_stss_cd = 2 THEN bl.crtd_dttm END) AS processing_started,
                    MIN(CASE WHEN bl.bdl_prcss_stss_cd = 10 THEN bl.crtd_dttm END) AS staged,
                    MIN(CASE WHEN bl.bdl_prcss_stss_cd = 12 THEN bl.crtd_dttm END) AS imported
                FROM dbo.bdl_log bl
                WHERE bl.sub_entty_nm_txt IS NULL
                  AND bl.crtd_dttm >= DATEADD(DAY, -$lookbackDays, GETDATE())
                GROUP BY bl.file_registry_id
            ),
            EntityType AS (
                SELECT file_registry_id, sub_entty_nm_txt,
                    ROW_NUMBER() OVER (PARTITION BY file_registry_id ORDER BY bdl_log_id) AS rn
                FROM dbo.bdl_log
                WHERE sub_entty_nm_txt IS NOT NULL
                  AND crtd_dttm >= DATEADD(DAY, -$lookbackDays, GETDATE())
            ),
            PartitionProgress AS (
                SELECT bl.file_registry_id,
                    COUNT(DISTINCT bl.bdl_prttn_nmbr) AS partition_count,
                    SUM(CASE WHEN bl.bdl_prcss_stss_cd IN (3, 7) AND bl.bdl_prcssd_cnt IS NOT NULL THEN 1 ELSE 0 END) AS partitions_completed,
                    MAX(bl.bdl_log_id) AS max_log_id,
                    MAX(bl.crtd_dttm) AS max_log_dttm
                FROM dbo.bdl_log bl
                WHERE bl.sub_entty_nm_txt IS NOT NULL
                  AND bl.crtd_dttm >= DATEADD(DAY, -$lookbackDays, GETDATE())
                GROUP BY bl.file_registry_id
            ),
            CustomDetails AS (
                SELECT d.file_registry_id,
                    MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_staging_success_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS staging_success,
                    MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_staging_failed_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS staging_failed,
                    MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_import_processed_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS import_processed,
                    MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_import_success_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS import_success,
                    MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_import_failed_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS import_failed
                FROM dbo.file_rgstry_cstm_dtl cd
                INNER JOIN dbo.file_rgstry_dtl d ON cd.file_rgstry_dtl_id = d.file_rgstry_dtl_id
                GROUP BY d.file_registry_id
            )
            SELECT cs.file_registry_id, cs.bdl_prcss_stss_cd AS bdl_log_status_code, cs.status_text AS bdl_log_status,
                cs.bdl_log_msg AS error_message, cs.crtd_dttm AS status_dttm,
                fr.file_name_full_txt AS filename, fr.file_crt_dttm AS file_created_dttm, fr.file_err_msg_txt,
                fr.file_stts_cd AS file_registry_status_code, frs.file_stts_val_txt AS file_registry_status, fr.upsrt_dttm AS file_registry_upsrt_dttm,
                frd.file_rgstry_dtl_rec_ttl_cnt AS total_record_count, frd.btch_idntfr_txt AS batch_identifier,
                ft.processing_started, ft.staged, ft.imported,
                et.sub_entty_nm_txt AS entity_type,
                pp.partition_count, pp.partitions_completed, pp.max_log_id, pp.max_log_dttm,
                cd.staging_success, cd.staging_failed, cd.import_processed, cd.import_success, cd.import_failed
            FROM CurrentBDLStatus cs
            INNER JOIN dbo.File_Registry fr ON cs.file_registry_id = fr.File_registry_id
            INNER JOIN dbo.Ref_File_Stts_Cd frs ON fr.file_stts_cd = frs.file_stts_cd
            INNER JOIN FileTimestamps ft ON cs.file_registry_id = ft.file_registry_id
            LEFT JOIN dbo.file_rgstry_dtl frd ON cs.file_registry_id = frd.file_registry_id
            LEFT JOIN EntityType et ON cs.file_registry_id = et.file_registry_id AND et.rn = 1
            LEFT JOIN PartitionProgress pp ON cs.file_registry_id = pp.file_registry_id
            LEFT JOIN CustomDetails cd ON cs.file_registry_id = cd.file_registry_id
            WHERE cs.rn = 1
            ORDER BY cs.file_registry_id
"@

        $sourceFiles = Get-bat_SourceData -Query $sourceQuery -Timeout 120

        if (-not $sourceFiles) {
            Write-Log "  No source files returned (or query failed)" "WARN"
            return @{ NewFiles = 0 }
        }

        $newFiles = @($sourceFiles | Where-Object { $trackedIds -notcontains $_.file_registry_id })

        if ($newFiles.Count -eq 0) {
            Write-Log "  No new files to collect" "INFO"
            return @{ NewFiles = 0 }
        }

        Write-Log "  Found $($newFiles.Count) new file(s)" "INFO"

        foreach ($file in $newFiles) {
            $fileRegId = $file.file_registry_id
            $fileSttsCode = $file.file_registry_status_code
            $fileSttsText = ($file.file_registry_status -replace "'", "''").Trim()
            $statusCode = $file.bdl_log_status_code

            $filenameSafe = if ($file.filename -is [DBNull]) { "NULL" } else { "'" + ($file.filename -replace "'", "''") + "'" }
            $entityType = if ($file.entity_type -is [DBNull]) { "NULL" } else { "'" + ($file.entity_type -replace "'", "''") + "'" }
            $batchIdent = if ($file.batch_identifier -is [DBNull]) { "NULL" } else { "'" + ($file.batch_identifier -replace "'", "''") + "'" }
            $totalRecCnt = if ($file.total_record_count -is [DBNull]) { "NULL" } else { $file.total_record_count }
            $statusText = ($file.bdl_log_status -replace "'", "''").Trim()

            $fileCrtDttm = if ($file.file_created_dttm -is [DBNull]) { "NULL" } else { "'" + $file.file_created_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $procStarted = if ($file.processing_started -is [DBNull]) { "NULL" } else { "'" + $file.processing_started.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $stagedDttm = if ($file.staged -is [DBNull]) { "NULL" } else { "'" + $file.staged.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $importedDttm = if ($file.imported -is [DBNull]) { "NULL" } else { "'" + $file.imported.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }

            $stagingSuccess = if ($file.staging_success -is [DBNull]) { "NULL" } else { $file.staging_success }
            $stagingFailed = if ($file.staging_failed -is [DBNull]) { "NULL" } else { $file.staging_failed }
            $importProcessed = if ($file.import_processed -is [DBNull]) { "NULL" } else { $file.import_processed }
            $importSuccess = if ($file.import_success -is [DBNull]) { "NULL" } else { $file.import_success }
            $importFailed = if ($file.import_failed -is [DBNull]) { "NULL" } else { $file.import_failed }

            $partCount = if ($file.partition_count -is [DBNull]) { "NULL" } else { $file.partition_count }
            $partCompleted = if ($file.partitions_completed -is [DBNull]) { "NULL" } else { $file.partitions_completed }
            $lastLogId = if ($file.max_log_id -is [DBNull]) { "NULL" } else { $file.max_log_id }
            $lastLogDttm = if ($file.max_log_dttm -is [DBNull]) { "NULL" } else { "'" + $file.max_log_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }

            $errorMsg = "NULL"
            $logMsg = if ($file.error_message -is [DBNull]) { $null } else { $file.error_message }
            $fileErrMsg = if ($file.file_err_msg_txt -is [DBNull]) { $null } else { $file.file_err_msg_txt }
            if ($logMsg) { $errorMsg = "'" + ($logMsg -replace "'", "''").Trim() + "'" }
            elseif ($fileErrMsg -and $fileErrMsg.Trim() -ne '') { $errorMsg = "'" + ($fileErrMsg -replace "'", "''").Trim() + "'" }

            # Terminal detection from File_Registry.file_stts_cd
            $isComplete = 0; $completedDttm = "NULL"; $completedStatus = "NULL"
            if ($fileSttsCode -in @(5, 6, 7, 8)) {
                $isComplete = 1
                $completedDttm = "'" + $file.file_registry_upsrt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"
                $completedStatus = "'$fileSttsText'"
            }

            if ($PreviewOnly) {
                $statusInfo = if ($isComplete -eq 1) { "COMPLETE ($completedStatus)" } else { "$statusText (File_Registry: $fileSttsText)" }
                $filenameDisplay = if ($file.filename -is [DBNull]) { "unknown" } else { $file.filename }
                Write-Log "  [Preview] Would insert file $fileRegId ($filenameDisplay) - $statusInfo" "INFO"
                $newFileCount++
            }
            else {
                $insertQuery = @"
                    INSERT INTO BatchOps.BDL_BatchTracking (
                        file_registry_id, file_name, entity_type, batch_identifier, total_record_count,
                        bdl_log_status_code, bdl_log_status, file_registry_status_code, file_registry_status,
                        file_created_dttm, processing_started_dttm, staged_dttm, imported_dttm,
                        staging_success_count, staging_failed_count,
                        import_processed_count, import_success_count, import_failed_count,
                        partition_count, partitions_completed, error_message,
                        is_complete, completed_dttm, completed_status,
                        last_log_id, last_log_dttm,
                        stall_poll_count, alert_count, last_polled_dttm
                    )
                    VALUES (
                        $fileRegId, $filenameSafe, $entityType, $batchIdent, $totalRecCnt,
                        $statusCode, '$statusText', $fileSttsCode, '$fileSttsText',
                        $fileCrtDttm, $procStarted, $stagedDttm, $importedDttm,
                        $stagingSuccess, $stagingFailed,
                        $importProcessed, $importSuccess, $importFailed,
                        $partCount, $partCompleted, $errorMsg,
                        $isComplete, $completedDttm, $completedStatus,
                        $lastLogId, $lastLogDttm,
                        0, 0, GETDATE()
                    )
"@
                $result = Invoke-SqlNonQuery -Query $insertQuery
                if ($result) {
                    $newFileCount++
                    Write-Log "  Inserted file $fileRegId - $(if ($isComplete -eq 1) { "COMPLETE ($fileSttsText)" } else { "$statusText (File_Registry: $fileSttsText)" })" "SUCCESS"
                } else {
                    Write-Log "  Failed to insert file $fileRegId" "ERROR"
                }
            }
        }

        if ($PreviewOnly) { $newFileCount = $newFiles.Count }
        Write-Log "  New files collected: $newFileCount" "INFO"
        return @{ NewFiles = $newFileCount }
    }
    catch {
        Write-Log "  Error in Collect New Files: $($_.Exception.Message)" "ERROR"
        return @{ NewFiles = 0; Error = $_.Exception.Message }
    }
}

# Updates all incomplete tracked files with current DM state via bulk queries.
function Step-bat_BDL_UpdateIncompleteFiles {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Update Incomplete Files" "STEP"
    $filesUpdated = 0
    $filesCompleted = 0

    try {
        $incompleteQuery = @"
            SELECT tracking_id, file_registry_id, file_name,
                   last_log_id, stall_poll_count, alert_count, bdl_log_status_code
            FROM BatchOps.BDL_BatchTracking
            WHERE is_complete = 0
"@
        $incompleteFiles = Get-SqlData -Query $incompleteQuery

        if (-not $incompleteFiles) {
            Write-Log "  No incomplete files to update" "INFO"
            return @{ Updated = 0; Completed = 0 }
        }

        $fileCount = @($incompleteFiles).Count
        Write-Log "  Found $fileCount incomplete file(s)" "INFO"

        # Build comma-separated ID list for bulk queries
        $fileIds = @($incompleteFiles | ForEach-Object { $_.file_registry_id }) -join ','

        # Bulk query 1: File_Registry status (authoritative terminal detection)
        $fileRegistryQuery = @"
            SELECT fr.File_registry_id, fr.file_stts_cd AS file_registry_status_code, frs.file_stts_val_txt AS file_registry_status,
                   fr.upsrt_dttm AS file_registry_upsrt_dttm, fr.file_err_msg_txt
            FROM dbo.File_Registry fr
            INNER JOIN dbo.Ref_File_Stts_Cd frs ON fr.file_stts_cd = frs.file_stts_cd
            WHERE fr.File_registry_id IN ($fileIds)
"@
        $fileRegistryData = Get-bat_SourceData -Query $fileRegistryQuery

        # Bulk query 2: Current bdl_log file-level status (for progress info)
        $statusQuery = @"
            ;WITH RankedStatus AS (
                SELECT bl.file_registry_id, bl.bdl_prcss_stss_cd, s.entty_async_stts_val_txt AS status_text,
                    bl.bdl_log_msg, bl.crtd_dttm,
                    ROW_NUMBER() OVER (PARTITION BY bl.file_registry_id ORDER BY bl.crtd_dttm DESC) AS rn
                FROM dbo.bdl_log bl
                INNER JOIN dbo.ref_entty_async_stts_cd s ON bl.bdl_prcss_stss_cd = s.entty_async_stts_cd
                WHERE bl.file_registry_id IN ($fileIds)
                  AND bl.sub_entty_nm_txt IS NULL
                  AND bl.bdl_prcss_stss_cd NOT IN (13, 14, 15)
            )
            SELECT file_registry_id, bdl_prcss_stss_cd, status_text, bdl_log_msg, crtd_dttm
            FROM RankedStatus WHERE rn = 1
"@
        $statusData = Get-bat_SourceData -Query $statusQuery

        # Bulk query 3: Lifecycle timestamps
        $timestampQuery = @"
            SELECT bl.file_registry_id,
                MIN(CASE WHEN bl.bdl_prcss_stss_cd = 10 THEN bl.crtd_dttm END) AS staged,
                MIN(CASE WHEN bl.bdl_prcss_stss_cd = 12 THEN bl.crtd_dttm END) AS imported
            FROM dbo.bdl_log bl
            WHERE bl.file_registry_id IN ($fileIds) AND bl.sub_entty_nm_txt IS NULL
            GROUP BY bl.file_registry_id
"@
        $timestampData = Get-bat_SourceData -Query $timestampQuery

        # Bulk query 4: Entity types
        $entityQuery = @"
            ;WITH RankedEntity AS (
                SELECT file_registry_id, sub_entty_nm_txt,
                    ROW_NUMBER() OVER (PARTITION BY file_registry_id ORDER BY bdl_log_id) AS rn
                FROM dbo.bdl_log
                WHERE file_registry_id IN ($fileIds) AND sub_entty_nm_txt IS NOT NULL
            )
            SELECT file_registry_id, sub_entty_nm_txt FROM RankedEntity WHERE rn = 1
"@
        $entityData = Get-bat_SourceData -Query $entityQuery

        # Bulk query 5: Partition progress
        $partitionQuery = @"
            SELECT bl.file_registry_id,
                COUNT(DISTINCT bl.bdl_prttn_nmbr) AS partition_count,
                SUM(CASE WHEN bl.bdl_prcss_stss_cd IN (3, 7) AND bl.bdl_prcssd_cnt IS NOT NULL THEN 1 ELSE 0 END) AS partitions_completed,
                MAX(bl.bdl_log_id) AS max_log_id,
                MAX(bl.crtd_dttm) AS max_log_dttm
            FROM dbo.bdl_log bl
            WHERE bl.file_registry_id IN ($fileIds) AND bl.sub_entty_nm_txt IS NOT NULL
            GROUP BY bl.file_registry_id
"@
        $partitionData = Get-bat_SourceData -Query $partitionQuery

        # Bulk query 6: Custom details
        $customDtlQuery = @"
            SELECT d.file_registry_id,
                MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_staging_success_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS staging_success,
                MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_staging_failed_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS staging_failed,
                MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_import_processed_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS import_processed,
                MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_import_success_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS import_success,
                MAX(CASE WHEN cd.file_rgstry_cstm_dtl_nm = 'Dm_import_failed_count' THEN cd.file_rgstry_cstm_dtl_val_txt END) AS import_failed
            FROM dbo.file_rgstry_cstm_dtl cd
            INNER JOIN dbo.file_rgstry_dtl d ON cd.file_rgstry_dtl_id = d.file_rgstry_dtl_id
            WHERE d.file_registry_id IN ($fileIds)
            GROUP BY d.file_registry_id
"@
        $customDtlData = Get-bat_SourceData -Query $customDtlQuery

        # Build lookup hashtables for O(1) access
        $fileRegistryLookup = @{}
        if ($fileRegistryData) { foreach ($r in @($fileRegistryData)) { $fileRegistryLookup[$r.File_registry_id] = $r } }
        $statusLookup = @{}
        if ($statusData) { foreach ($r in @($statusData)) { $statusLookup[$r.file_registry_id] = $r } }
        $timestampLookup = @{}
        if ($timestampData) { foreach ($r in @($timestampData)) { $timestampLookup[$r.file_registry_id] = $r } }
        $entityLookup = @{}
        if ($entityData) { foreach ($r in @($entityData)) { $entityLookup[$r.file_registry_id] = $r } }
        $partitionLookup = @{}
        if ($partitionData) { foreach ($r in @($partitionData)) { $partitionLookup[$r.file_registry_id] = $r } }
        $customDtlLookup = @{}
        if ($customDtlData) { foreach ($r in @($customDtlData)) { $customDtlLookup[$r.file_registry_id] = $r } }

        # Process each incomplete file from bulk data
        foreach ($tracking in @($incompleteFiles)) {
            $fileRegId = $tracking.file_registry_id
            $currentLogId = if ($tracking.last_log_id -is [DBNull]) { $null } else { $tracking.last_log_id }
            $currentStallCount = $tracking.stall_poll_count
            $currentAlertCount = if ($tracking.alert_count -is [DBNull]) { 0 } else { $tracking.alert_count }
            $filenameDisplay = if ($tracking.filename -is [DBNull]) { "file $fileRegId" } else { $tracking.filename }

            # File_Registry lookup (authoritative)
            $frData = $fileRegistryLookup[$fileRegId]
            if (-not $frData) {
                Write-Log "  File ${fileRegId}: no File_Registry data found" "WARN"
                continue
            }
            $fileSttsCode = $frData.file_registry_status_code
            $fileSttsText = ($frData.file_registry_status -replace "'", "''").Trim()

            # bdl_log status (for progress info)
            $status = $statusLookup[$fileRegId]
            $statusCode = if ($status) { $status.bdl_prcss_stss_cd } else { $null }
            $statusText = if ($status) { ($status.status_text -replace "'", "''").Trim() } else { "UNKNOWN" }
            $logMsg = if ($status -and $status.bdl_log_msg -isnot [DBNull]) { $status.bdl_log_msg } else { $null }

            $ts = $timestampLookup[$fileRegId]
            $stagedDttm = if (-not $ts -or $ts.staged -is [DBNull]) { "NULL" } else { "'" + $ts.staged.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $importedDttm = if (-not $ts -or $ts.imported -is [DBNull]) { "NULL" } else { "'" + $ts.imported.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }

            $et = $entityLookup[$fileRegId]
            $entityType = if (-not $et -or $et.sub_entty_nm_txt -is [DBNull]) { "NULL" } else { "'" + ($et.sub_entty_nm_txt -replace "'", "''") + "'" }

            $cd = $customDtlLookup[$fileRegId]
            $stagingSuccess = if (-not $cd -or $cd.staging_success -is [DBNull]) { "NULL" } else { $cd.staging_success }
            $stagingFailed = if (-not $cd -or $cd.staging_failed -is [DBNull]) { "NULL" } else { $cd.staging_failed }
            $importProcessed = if (-not $cd -or $cd.import_processed -is [DBNull]) { "NULL" } else { $cd.import_processed }
            $importSuccess = if (-not $cd -or $cd.import_success -is [DBNull]) { "NULL" } else { $cd.import_success }
            $importFailed = if (-not $cd -or $cd.import_failed -is [DBNull]) { "NULL" } else { $cd.import_failed }

            $pp = $partitionLookup[$fileRegId]
            $partCount = if (-not $pp -or $pp.partition_count -is [DBNull]) { "NULL" } else { $pp.partition_count }
            $partCompleted = if (-not $pp -or $pp.partitions_completed -is [DBNull]) { "NULL" } else { $pp.partitions_completed }
            $newLogId = if (-not $pp -or $pp.max_log_id -is [DBNull]) { $null } else { $pp.max_log_id }
            $lastLogDttm = if (-not $pp -or $pp.max_log_dttm -is [DBNull]) { "NULL" } else { "'" + $pp.max_log_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'" }
            $lastLogIdSql = if ($null -eq $newLogId) { "NULL" } else { $newLogId }

            $errorMsg = "NULL"
            $fileErrMsg = if ($frData.file_err_msg_txt -isnot [DBNull]) { $frData.file_err_msg_txt } else { $null }
            if ($logMsg) { $errorMsg = "'" + ($logMsg -replace "'", "''").Trim() + "'" }
            elseif ($fileErrMsg -and $fileErrMsg.Trim() -ne '') { $errorMsg = "'" + ($fileErrMsg -replace "'", "''").Trim() + "'" }

            # Use bdl_log status code for bdl_log_status_code if available, otherwise keep existing
            $statusCodeSql = if ($null -ne $statusCode) { $statusCode } else { "bdl_log_status_code" }
            $statusTextSql = if ($status) { "'$statusText'" } else { "bdl_log_status" }

            # Stall detection (still based on partition activity in bdl_log)
            $newAlertCount = $currentAlertCount
            if ($null -eq $newLogId) {
                $newStallCount = $currentStallCount
            } elseif ($null -ne $currentLogId -and $newLogId -eq $currentLogId) {
                $newStallCount = $currentStallCount + 1
            } else {
                $newStallCount = 0
                if ($currentAlertCount -gt 0) {
                    $newAlertCount = 0
                    Write-Log "  File ${fileRegId}: activity resumed, resetting alert_count" "DEBUG"
                }
            }

            # Terminal state detection from File_Registry.file_stts_cd
            $isComplete = 0; $completedDttm = "NULL"; $completedStatus = "NULL"
            if ($fileSttsCode -in @(5, 6, 7, 8)) {
                $isComplete = 1
                $completedDttm = "'" + $frData.file_registry_upsrt_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"
                $completedStatus = "'$fileSttsText'"
            }

            if ($PreviewOnly) {
                $statusDesc = "$statusText (File_Registry: $fileSttsText)"
                if ($isComplete -eq 1) { $statusDesc += " -> COMPLETE ($completedStatus)" }
                if ($newStallCount -gt 0) { $statusDesc += " (stall: $newStallCount)" }
                Write-Log "  [Preview] Would update file $fileRegId ($filenameDisplay): $statusDesc" "INFO"
                $filesUpdated++
                if ($isComplete -eq 1) { $filesCompleted++ }
            }
            else {
                $updateQuery = @"
                    UPDATE BatchOps.BDL_BatchTracking
                    SET bdl_log_status_code         = $statusCodeSql,
                        bdl_log_status              = $statusTextSql,
                        file_registry_status_code = $fileSttsCode,
                        file_registry_status         = '$fileSttsText',
                        entity_type              = COALESCE(entity_type, $entityType),
                        staged_dttm              = COALESCE(staged_dttm, $stagedDttm),
                        imported_dttm            = COALESCE(imported_dttm, $importedDttm),
                        staging_success_count    = COALESCE($stagingSuccess, staging_success_count),
                        staging_failed_count     = COALESCE($stagingFailed, staging_failed_count),
                        import_processed_count   = COALESCE($importProcessed, import_processed_count),
                        import_success_count     = COALESCE($importSuccess, import_success_count),
                        import_failed_count      = COALESCE($importFailed, import_failed_count),
                        partition_count          = $partCount,
                        partitions_completed     = $partCompleted,
                        error_message            = COALESCE(error_message, $errorMsg),
                        last_log_id              = $lastLogIdSql,
                        last_log_dttm            = $lastLogDttm,
                        stall_poll_count         = $newStallCount,
                        alert_count              = $newAlertCount,
                        is_complete              = $isComplete,
                        completed_dttm           = COALESCE(completed_dttm, $completedDttm),
                        completed_status         = COALESCE(completed_status, $completedStatus),
                        last_polled_dttm         = GETDATE()
                    WHERE file_registry_id = $fileRegId
"@
                $result = Invoke-SqlNonQuery -Query $updateQuery
                if ($result) {
                    $filesUpdated++
                    if ($isComplete -eq 1) {
                        $filesCompleted++
                        Write-Log "  File ${fileRegId}: COMPLETED ($fileSttsText)" "SUCCESS"
                    } else {
                        Write-Log "  File ${fileRegId}: updated (File_Registry: $fileSttsText, stall: $newStallCount)" "DEBUG"
                    }
                } else {
                    Write-Log "  File ${fileRegId}: update failed" "ERROR"
                }
            }
        }

        Write-Log "  Files updated: $filesUpdated, Completed: $filesCompleted" "INFO"
        return @{ Updated = $filesUpdated; Completed = $filesCompleted }
    }
    catch {
        Write-Log "  Error in Update Incomplete Files: $($_.Exception.Message)" "ERROR"
        return @{ Updated = $filesUpdated; Completed = $filesCompleted; Error = $_.Exception.Message }
    }
}

# Evaluates BDL alert conditions (FAILED and stalled processing) and fires alerts.
function Step-bat_BDL_EvaluateAlerts {
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Evaluate Alert Conditions" "STEP"
    $alertsDetected = 0
    $alertsFired = 0

    try {
        if (-not $script:Config.BDL_AlertingEnabled) {
            Write-Log "  Alerting is DISABLED (bdl_alerting_enabled = 0)" "INFO"
        }

        # CHECK 1: Failed (completed_status = 'FAILED')
        # Covers both stage failures and import failures
        $routing = $script:Config.BDL_Alert_Failed

        $failures = Get-SqlData -Query @"
            SELECT file_registry_id, file_name, entity_type, total_record_count,
                   staging_success_count, staging_failed_count,
                   import_success_count, import_failed_count,
                   error_message, file_created_dttm, bdl_log_status, alert_count
            FROM BatchOps.BDL_BatchTracking
            WHERE is_complete = 1 AND completed_status = 'FAILED' AND alert_count = 0
"@

        if ($failures) {
            foreach ($file in @($failures)) {
                $alertsDetected++
                $fileRegId = $file.file_registry_id
                $filenameDisplay = if ($file.filename -isnot [DBNull]) { $file.filename } else { "File $fileRegId" }
                Write-Log "  ALERT: Failed - file $fileRegId ($filenameDisplay)" "WARN"

                if ($script:Config.BDL_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $entityType = if ($file.entity_type -isnot [DBNull]) { $file.entity_type } else { 'Unknown' }
                    $totalRecs = if ($file.total_record_count -isnot [DBNull]) { $file.total_record_count } else { 'N/A' }
                    $fileStatus = if ($file.bdl_log_status -isnot [DBNull]) { $file.bdl_log_status } else { 'Unknown' }
                    $stagedCount = if ($file.staging_success_count -isnot [DBNull]) { $file.staging_success_count } else { 'N/A' }
                    $stageFailed = if ($file.staging_failed_count -isnot [DBNull]) { $file.staging_failed_count } else { 'N/A' }
                    $importSuccess = if ($file.import_success_count -isnot [DBNull]) { $file.import_success_count } else { 'N/A' }
                    $importFailed = if ($file.import_failed_count -isnot [DBNull]) { $file.import_failed_count } else { 'N/A' }
                    $errMsg = if ($file.error_message -isnot [DBNull]) { $file.error_message } else { 'No error details available' }
                    $triggerType = 'BDL_Failed'; $triggerValue = "$fileRegId"; $cascadingChild = 'BDL Import Failure'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $createdTime = if ($file.file_created_dttm -isnot [DBNull]) { $file.file_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }

                    $jiraSummary = "BDL Failed: $filenameDisplay"
                    $jiraDesc = "BDL File Failed`n`nFile Registry ID: $fileRegId`nFilename: $filenameDisplay`nEntity Type: $entityType`nTotal Records: $totalRecs`nLast BDL Status: $fileStatus`nRecords Staged: $stagedCount (Failed: $stageFailed)`nImport Success: $importSuccess (Failed: $importFailed)`nCreated: $createdTime`n`nError: $errMsg`n`nAction: Review the BDL file in Debt Manager for failure details.`n`nDetection Date: $detectionTime"
                    $teamsTitle = "{{FIRE}} BDL Failed: $filenameDisplay"
                    $teamsMessage = "**File Registry ID:** $fileRegId`n**Filename:** $filenameDisplay`n**Entity Type:** $entityType`n**Total Records:** $totalRecs`n**Last BDL Status:** $fileStatus`n**Records Staged:** $stagedCount (Failed: $stageFailed)`n**Import Success:** $importSuccess (Failed: $importFailed)`n**Created:** $createdTime`n`n**Error:** $errMsg`n`nAction: Review the BDL file in Debt Manager for failure details.`n`n**Detection:** $detectionTime"
                    Send-bat_BatchAlert -Routing $routing -TriggerType $triggerType -TriggerValue $triggerValue -CascadingChild $cascadingChild `
                        -JiraSummary $jiraSummary -JiraDescription $jiraDesc `
                        -TeamsTitle $teamsTitle -TeamsMessage $teamsMessage -TeamsCategory 'CRITICAL' -TeamsColor 'attention'
                    Invoke-SqlNonQuery -Query "UPDATE BatchOps.BDL_BatchTracking SET alert_count = alert_count + 1 WHERE file_registry_id = $fileRegId" | Out-Null
                    $alertsFired++
                }
            }
        }

        # CHECK 2: Stalled Processing (stall_poll_count >= threshold)
        # Re-alertable per stall episode using composite trigger
        $routing = $script:Config.BDL_Alert_Stall
        $stallThreshold = $script:Config.BDL_StallPollThreshold

        $stalledFiles = Get-SqlData -Query @"
            SELECT file_registry_id, file_name, entity_type, total_record_count,
                   bdl_log_status, bdl_log_status_code, file_registry_status_code, file_registry_status,
                   partition_count, partitions_completed,
                   stall_poll_count, last_log_id, last_log_dttm, file_created_dttm, alert_count
            FROM BatchOps.BDL_BatchTracking
            WHERE is_complete = 0 AND stall_poll_count >= $stallThreshold AND alert_count = 0
"@

        if ($stalledFiles) {
            foreach ($file in @($stalledFiles)) {
                $alertsDetected++
                $fileRegId = $file.file_registry_id
                $filenameDisplay = if ($file.filename -isnot [DBNull]) { $file.filename } else { "File $fileRegId" }
                $stallDuration = Get-bat_StallDurationText -PollCount $file.stall_poll_count
                Write-Log "  ALERT: Stall detected - file $fileRegId ($filenameDisplay) - $stallDuration" "WARN"

                if ($script:Config.BDL_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $entityType = if ($file.entity_type -isnot [DBNull]) { $file.entity_type } else { 'Unknown' }
                    $totalRecs = if ($file.total_record_count -isnot [DBNull]) { $file.total_record_count } else { 'N/A' }
                    $partCount = if ($file.partition_count -isnot [DBNull]) { $file.partition_count } else { 'N/A' }
                    $partCompleted = if ($file.partitions_completed -isnot [DBNull]) { $file.partitions_completed } else { 'N/A' }
                    $fileStatus = if ($file.bdl_log_status -isnot [DBNull]) { $file.bdl_log_status } else { 'Unknown' }
                    $fileSttsCode = if ($file.file_registry_status_code -isnot [DBNull]) { $file.file_registry_status_code } else { 'N/A' }
                    $lastLogId = $file.last_log_id
                    $lastLogTime = if ($file.last_log_dttm -isnot [DBNull]) { $file.last_log_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }
                    $triggerType = 'BDL_Stall'; $triggerValue = "${fileRegId}_${lastLogId}"; $cascadingChild = 'BDL Import Failure'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $createdTime = if ($file.file_created_dttm -isnot [DBNull]) { $file.file_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }

                    $jiraSummary = "BDL Processing Stalled: $filenameDisplay"
                    $jiraDesc = "BDL File Processing Stalled`n`nFile Registry ID: $fileRegId`nFilename: $filenameDisplay`nEntity Type: $entityType`nTotal Records: $totalRecs`nBDL Status: $fileStatus`nFile Registry Status: $fileSttsCode`nPartitions: $partCompleted of $partCount completed`nStalled: $stallDuration with no partition activity`nLast Activity: $lastLogTime`nCreated: $createdTime`n`nAction: Check BDL processing status in Debt Manager.`n`nDetection Date: $detectionTime"
                    $teamsTitle = "{{WARN}} BDL Processing Stalled: $filenameDisplay"
                    $teamsMessage = "**File Registry ID:** $fileRegId`n**Filename:** $filenameDisplay`n**Entity Type:** $entityType`n**Total Records:** $totalRecs`n**BDL Status:** $fileStatus`n**File Registry Status:** $fileSttsCode`n**Partitions:** $partCompleted of $partCount completed`n**Stalled:** $stallDuration with no partition activity`n**Last Activity:** $lastLogTime`n`nAction: Check BDL processing status in Debt Manager.`n`n**Detection:** $detectionTime"
                    Send-bat_BatchAlert -Routing $routing -TriggerType $triggerType -TriggerValue $triggerValue -CascadingChild $cascadingChild `
                        -JiraSummary $jiraSummary -JiraDescription $jiraDesc `
                        -TeamsTitle $teamsTitle -TeamsMessage $teamsMessage -TeamsCategory 'WARNING' -TeamsColor 'warning'
                    Invoke-SqlNonQuery -Query "UPDATE BatchOps.BDL_BatchTracking SET alert_count = alert_count + 1 WHERE file_registry_id = $fileRegId" | Out-Null
                    $alertsFired++
                }
            }
        }

        Write-Log "  Alerts detected: $alertsDetected, fired: $alertsFired" "INFO"
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
   Orchestrates the collect/update/evaluate pipeline, records run status in
   BatchOps.Status, and reports completion to the orchestrator.
   Prefix: (none)
   ============================================================================ #>

# Tracks whether all pipeline steps succeeded.
$overallSuccess = $true
# Measures total execution time for run-status reporting.
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $configOk = Initialize-bat_BDL_Configuration
    if (-not $configOk) {
        Write-Log "Configuration initialization failed - aborting" "ERROR"
        $overallSuccess = $false
        return
    }

    if ($Execute) {
        Set-bat_BatchStatus -CollectorName 'Collect-BDLBatchStatus' -State RUNNING
    }

    $previewOnly = -not $Execute

    $collectResult = Step-bat_BDL_CollectNewFiles -PreviewOnly $previewOnly
    $updateResult = Step-bat_BDL_UpdateIncompleteFiles -PreviewOnly $previewOnly
    $alertResult = Step-bat_BDL_EvaluateAlerts -PreviewOnly $previewOnly

    $stopwatch.Stop()
    Write-Log "Execution complete in $($stopwatch.ElapsedMilliseconds)ms" "INFO"
    Write-Log "  New files: $($collectResult.NewFiles)" "INFO"
    Write-Log "  Updated: $($updateResult.Updated), Completed: $($updateResult.Completed)" "INFO"
    Write-Log "  Alerts detected: $($alertResult.Detected), Fired: $($alertResult.Fired)" "INFO"

    if ($collectResult.Error -or $updateResult.Error -or $alertResult.Error) { $overallSuccess = $false }
}
catch {
    $overallSuccess = $false
    Write-Log "Fatal error: $($_.Exception.Message)" "ERROR"
    $stopwatch.Stop()
}
finally {
    if ($Execute) {
        $statusText = if ($overallSuccess) { 'SUCCESS' } else { 'FAILED' }
        Set-bat_BatchStatus -CollectorName 'Collect-BDLBatchStatus' -State IDLE -Status $statusText -DurationMs $stopwatch.ElapsedMilliseconds
    }

    if ($TaskId -gt 0 -and $ProcessId -gt 0) {
        $exitStatus = if ($overallSuccess) { 'SUCCESS' } else { 'FAILED' }
        $outputSummary = "New:$($collectResult.NewFiles) Updated:$($updateResult.Updated) Completed:$($updateResult.Completed) Alerts:$($alertResult.Fired)"
        Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
            -Status $exitStatus -OutputSummary $outputSummary `
            -ServerInstance $ServerInstance -Database $Database
    }
}
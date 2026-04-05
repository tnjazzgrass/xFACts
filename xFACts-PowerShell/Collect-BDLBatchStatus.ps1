<#
.SYNOPSIS
    xFACts - BDL Batch Status Collection

.DESCRIPTION
    xFACts - BatchOps
    Script: Collect-BDLBatchStatus.ps1
    Version: Tracked in dbo.System_Metadata (component: BatchOps)

    Monitors Debt Manager BDL (Bulk Data Load) file lifecycle from registration
    through terminal state. Collects new files, updates status for in-flight files
    with partition-based progress tracking, captures DM summary counts, and
    evaluates alert conditions.

    BDL lifecycle (file-level, filtered by sub_entty_nm_txt IS NULL):
      Happy path:    PROCESSING (2) -> STAGED (10) -> IMPORTED (12)
      Stage failure: PROCESSING (2) -> STAGEFAILED (8)
      Import failure: PROCESSING (2) -> STAGED (10) -> IMPORT_FAILED (11)
      Cleanup (not monitored): DELETING (13) -> DELETED (14)

    Follows the xFACts collect/evaluate pattern:
    - Reads from configurable AG replica (PRIMARY or SECONDARY) for DM queries
    - Writes to xFACts via the AG listener for all BatchOps.* table updates
    - AG-aware: automatically detects current PRIMARY/SECONDARY roles
    - Supports preview mode for safe testing

    CHANGELOG
    ---------
    2026-04-04  Refactored to bulk query pattern matching NB/PMT collectors
                Collect step uses single bulk query with joins instead of per-file queries
                Update step uses bulk queries for status, partitions, and custom details
    2026-04-04  Initial implementation
                Three-step execution: Collect -> Update -> Evaluate
                Partition-based progress and stall detection
                DM summary counts from file_rgstry_dtl / file_rgstry_cstm_dtl
                Three alert conditions: STAGEFAILED, IMPORT_FAILED, Stall

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

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Default 0.

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Default 0.

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
   - BatchOps.bdl_stall_poll_threshold (default: 12)
   - BatchOps.bdl_alerting_enabled (default: 0)
   - BatchOps.bdl_lookback_days (default: 7)
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

Initialize-XFActsScript -ScriptName 'Collect-BDLBatchStatus' `
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
        [int]$Timeout = 120
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

function Get-AGReplicaRoles {
    $agName = $Script:Config.AGName
    if (-not $agName) {
        Write-Log "AGName not configured - cannot query replica states" "ERROR"
        return $null
    }

    $query = @"
        SELECT ar.replica_server_name, ars.role_desc
        FROM sys.dm_hadr_availability_replica_states ars
        INNER JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
        INNER JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
        WHERE ag.name = '$agName'
"@

    $results = Get-SqlData -Query $query
    if (-not $results) {
        Write-Log "Failed to query AG replica states" "ERROR"
        return $null
    }

    $roles = @{ PRIMARY = $null; SECONDARY = $null }
    foreach ($row in $results) {
        if ($row.role_desc -eq 'PRIMARY') { $roles.PRIMARY = $row.replica_server_name }
        elseif ($row.role_desc -eq 'SECONDARY') { $roles.SECONDARY = $row.replica_server_name }
    }
    return $roles
}

function Initialize-Configuration {
    Write-Log "Loading configuration..." "INFO"

    $configQuery = @"
        SELECT module_name, setting_name, setting_value
        FROM dbo.GlobalConfig
        WHERE module_name IN ('BatchOps', 'Shared', 'dbo')
          AND is_active = 1
"@
    $configResults = Get-SqlData -Query $configQuery

    $Script:Config = @{
        AGName                          = "DMPRODAG"
        SourceReplica                   = "SECONDARY"
        BDL_StallPollThreshold          = 12
        BDL_AlertingEnabled             = $false
        BDL_LookbackDays                = 7
        BDL_Alert_StageFailed           = 3
        BDL_Alert_ImportFailed          = 3
        BDL_Alert_Stall                 = 1
    }

    if ($configResults) {
        foreach ($row in $configResults) {
            switch ($row.setting_name) {
                "AGName"                            { $Script:Config.AGName = $row.setting_value }
                "SourceReplica"                     { $Script:Config.SourceReplica = $row.setting_value }
                "bdl_stall_poll_threshold"          { $Script:Config.BDL_StallPollThreshold = [int]$row.setting_value }
                "bdl_alerting_enabled"              { $Script:Config.BDL_AlertingEnabled = [bool][int]$row.setting_value }
                "bdl_lookback_days"                 { $Script:Config.BDL_LookbackDays = [int]$row.setting_value }
                "bdl_alert_stagefailed_routing"     { $Script:Config.BDL_Alert_StageFailed = [int]$row.setting_value }
                "bdl_alert_import_failed_routing"   { $Script:Config.BDL_Alert_ImportFailed = [int]$row.setting_value }
                "bdl_alert_stall_routing"           { $Script:Config.BDL_Alert_Stall = [int]$row.setting_value }
            }
        }
    }

    Write-Log "  AGName: $($Script:Config.AGName)" "INFO"
    Write-Log "  SourceReplica: $($Script:Config.SourceReplica)" "INFO"
    Write-Log "  BDL_StallPollThreshold: $($Script:Config.BDL_StallPollThreshold)" "INFO"
    Write-Log "  BDL_AlertingEnabled: $($Script:Config.BDL_AlertingEnabled)" "INFO"
    Write-Log "  BDL_LookbackDays: $($Script:Config.BDL_LookbackDays)" "INFO"

    $Script:WriteServer = $ServerInstance

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
        } else {
            $Script:ReadServer = $Script:AGSecondary
        }

        if (-not $Script:ReadServer) {
            Write-Log "Could not determine ReadServer from AG roles" "ERROR"
            return $false
        }
        Write-Log "  ReadServer: $($Script:ReadServer) (from GlobalConfig: $($Script:Config.SourceReplica))" "SUCCESS"
    }

    Write-Log "  WriteServer: $($Script:WriteServer)" "INFO"

    $Script:PollingIntervalMinutes = $null
    if ($ProcessId -gt 0) {
        $intervalQuery = "SELECT interval_seconds FROM Orchestrator.ProcessRegistry WHERE process_id = $ProcessId"
        $intervalResult = Get-SqlData -Query $intervalQuery
        if ($intervalResult -and $intervalResult.interval_seconds -isnot [DBNull]) {
            $Script:PollingIntervalMinutes = [math]::Round($intervalResult.interval_seconds / 60, 1)
            Write-Log "  PollingIntervalMinutes: $($Script:PollingIntervalMinutes) (from ProcessRegistry)" "INFO"
        } else {
            Write-Log "  PollingIntervalMinutes: unknown (ProcessRegistry lookup failed)" "WARN"
        }
    } else {
        Write-Log "  PollingIntervalMinutes: unknown (manual run, no ProcessId)" "INFO"
    }

    return $true
}

function Get-StallDurationText {
    param([int]$PollCount)
    if ($null -ne $Script:PollingIntervalMinutes) {
        $totalMinutes = [math]::Round($PollCount * $Script:PollingIntervalMinutes)
        return "$PollCount polls (~$totalMinutes min)"
    } else {
        return "$PollCount polls"
    }
}

# ============================================================================
# STEP FUNCTIONS
# ============================================================================

function Step-CollectNewFiles {
    <#
    .SYNOPSIS
        Discovers new BDL files in DM not yet tracked in xFACts and inserts them.
        Single bulk query with joins pulls all data, then filters in memory.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Collect New Files" "STEP"
    $newFileCount = 0

    try {
        $trackedQuery = "SELECT file_registry_id FROM BatchOps.BDL_BatchTracking"
        $trackedFiles = Get-SqlData -Query $trackedQuery
        $trackedIds = @()
        if ($trackedFiles) { $trackedIds = @($trackedFiles | ForEach-Object { $_.file_registry_id }) }

        $lookbackDays = $Script:Config.BDL_LookbackDays

        # Single bulk query: all BDL file data in one round trip
        $sourceQuery = @"
            ;WITH CurrentStatus AS (
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
            SELECT cs.file_registry_id, cs.bdl_prcss_stss_cd AS file_status_code, cs.status_text AS file_status,
                cs.bdl_log_msg AS error_message, cs.crtd_dttm AS status_dttm,
                fr.file_name_full_txt AS filename, fr.file_crt_dttm AS file_created_dttm, fr.file_err_msg_txt,
                frd.file_rgstry_dtl_rec_ttl_cnt AS total_record_count, frd.btch_idntfr_txt AS batch_identifier,
                ft.processing_started, ft.staged, ft.imported,
                et.sub_entty_nm_txt AS entity_type,
                pp.partition_count, pp.partitions_completed, pp.max_log_id, pp.max_log_dttm,
                cd.staging_success, cd.staging_failed, cd.import_processed, cd.import_success, cd.import_failed
            FROM CurrentStatus cs
            INNER JOIN dbo.File_Registry fr ON cs.file_registry_id = fr.File_registry_id
            INNER JOIN FileTimestamps ft ON cs.file_registry_id = ft.file_registry_id
            LEFT JOIN dbo.file_rgstry_dtl frd ON cs.file_registry_id = frd.file_registry_id
            LEFT JOIN EntityType et ON cs.file_registry_id = et.file_registry_id AND et.rn = 1
            LEFT JOIN PartitionProgress pp ON cs.file_registry_id = pp.file_registry_id
            LEFT JOIN CustomDetails cd ON cs.file_registry_id = cd.file_registry_id
            WHERE cs.rn = 1
            ORDER BY cs.file_registry_id
"@

        $sourceFiles = Get-SourceData -Query $sourceQuery -Timeout 120

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
            $statusCode = $file.file_status_code

            $filenameSafe = if ($file.filename -is [DBNull]) { "NULL" } else { "'" + ($file.filename -replace "'", "''") + "'" }
            $entityType = if ($file.entity_type -is [DBNull]) { "NULL" } else { "'" + ($file.entity_type -replace "'", "''") + "'" }
            $batchIdent = if ($file.batch_identifier -is [DBNull]) { "NULL" } else { "'" + ($file.batch_identifier -replace "'", "''") + "'" }
            $totalRecCnt = if ($file.total_record_count -is [DBNull]) { "NULL" } else { $file.total_record_count }
            $statusText = ($file.file_status -replace "'", "''").Trim()

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

            $isComplete = 0; $completedDttm = "NULL"; $completedStatus = "NULL"
            if ($statusCode -eq 12) {
                $isComplete = 1; $completedDttm = $importedDttm; $completedStatus = "'IMPORTED'"
            } elseif ($statusCode -eq 8) {
                $isComplete = 1; $completedDttm = "'" + $file.status_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"; $completedStatus = "'STAGEFAILED'"
            } elseif ($statusCode -eq 11) {
                $isComplete = 1; $completedDttm = "'" + $file.status_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"; $completedStatus = "'IMPORT_FAILED'"
            }

            if ($PreviewOnly) {
                $statusInfo = if ($isComplete -eq 1) { "COMPLETE ($completedStatus)" } else { $statusText }
                $filenameDisplay = if ($file.filename -is [DBNull]) { "unknown" } else { $file.filename }
                Write-Log "  [Preview] Would insert file $fileRegId ($filenameDisplay) - $statusInfo" "INFO"
                $newFileCount++
            }
            else {
                $insertQuery = @"
                    INSERT INTO BatchOps.BDL_BatchTracking (
                        file_registry_id, filename, entity_type, batch_identifier, total_record_count,
                        file_status_code, file_status,
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
                        $statusCode, '$statusText',
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
                    Write-Log "  Inserted file $fileRegId - $(if ($isComplete -eq 1) { 'COMPLETE' } else { $statusText })" "SUCCESS"
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

function Step-UpdateIncompleteFiles {
    <#
    .SYNOPSIS
        Updates all incomplete files with current DM state. Uses bulk queries
        to minimize round trips, then matches against tracked rows in memory.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Update Incomplete Files" "STEP"
    $filesUpdated = 0
    $filesCompleted = 0

    try {
        $incompleteQuery = @"
            SELECT tracking_id, file_registry_id, filename,
                   last_log_id, stall_poll_count, alert_count, file_status_code
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

        # ── Bulk query 1: Current file-level status ──
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
        $statusData = Get-SourceData -Query $statusQuery

        # ── Bulk query 2: Lifecycle timestamps ──
        $timestampQuery = @"
            SELECT bl.file_registry_id,
                MIN(CASE WHEN bl.bdl_prcss_stss_cd = 10 THEN bl.crtd_dttm END) AS staged,
                MIN(CASE WHEN bl.bdl_prcss_stss_cd = 12 THEN bl.crtd_dttm END) AS imported
            FROM dbo.bdl_log bl
            WHERE bl.file_registry_id IN ($fileIds) AND bl.sub_entty_nm_txt IS NULL
            GROUP BY bl.file_registry_id
"@
        $timestampData = Get-SourceData -Query $timestampQuery

        # ── Bulk query 3: Entity types ──
        $entityQuery = @"
            ;WITH RankedEntity AS (
                SELECT file_registry_id, sub_entty_nm_txt,
                    ROW_NUMBER() OVER (PARTITION BY file_registry_id ORDER BY bdl_log_id) AS rn
                FROM dbo.bdl_log
                WHERE file_registry_id IN ($fileIds) AND sub_entty_nm_txt IS NOT NULL
            )
            SELECT file_registry_id, sub_entty_nm_txt FROM RankedEntity WHERE rn = 1
"@
        $entityData = Get-SourceData -Query $entityQuery

        # ── Bulk query 4: Partition progress ──
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
        $partitionData = Get-SourceData -Query $partitionQuery

        # ── Bulk query 5: Custom details ──
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
        $customDtlData = Get-SourceData -Query $customDtlQuery

        # ── Build lookup hashtables for O(1) access ──
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

        # ── Process each incomplete file from bulk data ──
        foreach ($tracking in @($incompleteFiles)) {
            $fileRegId = $tracking.file_registry_id
            $currentLogId = if ($tracking.last_log_id -is [DBNull]) { $null } else { $tracking.last_log_id }
            $currentStallCount = $tracking.stall_poll_count
            $currentAlertCount = if ($tracking.alert_count -is [DBNull]) { 0 } else { $tracking.alert_count }
            $filenameDisplay = if ($tracking.filename -is [DBNull]) { "file $fileRegId" } else { $tracking.filename }

            $status = $statusLookup[$fileRegId]
            if (-not $status) {
                Write-Log "  File ${fileRegId}: no status data found in DM" "WARN"
                continue
            }

            $statusCode = $status.bdl_prcss_stss_cd
            $statusText = ($status.status_text -replace "'", "''").Trim()
            $logMsg = if ($status.bdl_log_msg -is [DBNull]) { $null } else { $status.bdl_log_msg }

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
            if ($logMsg) { $errorMsg = "'" + ($logMsg -replace "'", "''").Trim() + "'" }

            # Stall detection
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

            # Terminal state detection
            $isComplete = 0; $completedDttm = "NULL"; $completedStatus = "NULL"
            if ($statusCode -eq 12) {
                $isComplete = 1; $completedDttm = $importedDttm; $completedStatus = "'IMPORTED'"
            } elseif ($statusCode -eq 8) {
                $isComplete = 1; $completedDttm = "'" + $status.crtd_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"; $completedStatus = "'STAGEFAILED'"
            } elseif ($statusCode -eq 11) {
                $isComplete = 1; $completedDttm = "'" + $status.crtd_dttm.ToString("yyyy-MM-dd HH:mm:ss.fff") + "'"; $completedStatus = "'IMPORT_FAILED'"
            }

            if ($PreviewOnly) {
                $statusDesc = $statusText
                if ($isComplete -eq 1) { $statusDesc += " -> COMPLETE" }
                if ($newStallCount -gt 0) { $statusDesc += " (stall: $newStallCount)" }
                Write-Log "  [Preview] Would update file $fileRegId ($filenameDisplay): $statusDesc" "INFO"
                $filesUpdated++
                if ($isComplete -eq 1) { $filesCompleted++ }
            }
            else {
                $updateQuery = @"
                    UPDATE BatchOps.BDL_BatchTracking
                    SET file_status_code         = $statusCode,
                        file_status              = '$statusText',
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
                        Write-Log "  File ${fileRegId}: COMPLETED ($completedStatus)" "SUCCESS"
                    } else {
                        Write-Log "  File ${fileRegId}: updated (stall: $newStallCount)" "DEBUG"
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

function Step-EvaluateAlerts {
    <#
    .SYNOPSIS
        Evaluates 3 alert conditions on tracked BDL files.
        Master switch: bdl_alerting_enabled must be 1 for alerts to fire.
    #>
    param([bool]$PreviewOnly = $true)

    Write-Log "Step: Evaluate Alert Conditions" "STEP"
    $alertsDetected = 0
    $alertsFired = 0

    $jiraProjectKey = 'SD'; $jiraIssueType = 'Issue'; $jiraPriority = 'Highest'
    $jiraCascadingFieldId = 'customfield_18401'; $jiraCascadingParent = 'File Processing'
    $jiraCustomField1Id = 'customfield_10305'; $jiraCustomField1Value = 'FAC INFORMATION TECHNOLOGY'
    $jiraCustomField2Id = 'customfield_10009'; $jiraCustomField2Value = 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa'
    $jiraEmailRecipients = 'applications@frost-arnett.com'

    $dayOfWeek = [int](Get-Date).DayOfWeek
    if ($dayOfWeek -eq 0) { $jiraDueDate = (Get-Date).AddDays(1).ToString("yyyy-MM-dd") }
    elseif ($dayOfWeek -eq 6) { $jiraDueDate = (Get-Date).AddDays(2).ToString("yyyy-MM-dd") }
    else { $jiraDueDate = (Get-Date).ToString("yyyy-MM-dd") }

    try {
        if (-not $Script:Config.BDL_AlertingEnabled) {
            Write-Log "  Alerting is DISABLED (bdl_alerting_enabled = 0)" "INFO"
        }

        # ══════════════════════════════════════════════════════════════════
        # CHECK 1: Stage Failed (completed_status = 'STAGEFAILED')
        # ══════════════════════════════════════════════════════════════════
        $routing = $Script:Config.BDL_Alert_StageFailed

        $stageFailures = Get-SqlData -Query @"
            SELECT file_registry_id, filename, entity_type, total_record_count,
                   error_message, file_created_dttm, alert_count
            FROM BatchOps.BDL_BatchTracking
            WHERE is_complete = 1 AND completed_status = 'STAGEFAILED' AND alert_count = 0
"@

        if ($stageFailures) {
            foreach ($file in @($stageFailures)) {
                $alertsDetected++
                $fileRegId = $file.file_registry_id
                $filenameDisplay = if ($file.filename -isnot [DBNull]) { $file.filename } else { "File $fileRegId" }
                Write-Log "  ALERT: Stage failed - file $fileRegId ($filenameDisplay)" "WARN"

                if ($Script:Config.BDL_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $entityType = if ($file.entity_type -isnot [DBNull]) { $file.entity_type } else { 'Unknown' }
                    $totalRecs = if ($file.total_record_count -isnot [DBNull]) { $file.total_record_count } else { 'N/A' }
                    $errMsg = if ($file.error_message -isnot [DBNull]) { $file.error_message } else { 'No error details available' }
                    $triggerType = 'BDL_StageFailed'; $triggerValue = "$fileRegId"; $cascadingChild = 'BDL Import Failure'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $createdTime = if ($file.file_created_dttm -isnot [DBNull]) { $file.file_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }

                    if ($routing -band 2) {
                        $jiraDedup = Get-SqlData -Query "SELECT TOP 1 1 AS x FROM Jira.RequestLog WHERE Trigger_Type = '$triggerType' AND Trigger_Value = '$triggerValue' AND StatusCode = 201 AND TicketKey IS NOT NULL AND TicketKey != 'Email'"
                        if (-not $jiraDedup) {
                            $jiraSummary = ("BDL Stage Failed: $filenameDisplay") -replace "'", "''"
                            $jiraDesc = ("BDL File Stage Failed`n`nFile Registry ID: $fileRegId`nFilename: $filenameDisplay`nEntity Type: $entityType`nTotal Records: $totalRecs`nCreated: $createdTime`n`nError: $errMsg`n`nAction: Review the BDL file for XML validation errors or unconfigured entity types.`n`nDetection Date: $detectionTime") -replace "'", "''"
                            Invoke-SqlNonQuery -Query "EXEC Jira.sp_QueueTicket @SourceModule = 'BatchOps', @ProjectKey = '$jiraProjectKey', @Summary = N'$jiraSummary', @Description = N'$jiraDesc', @IssueType = '$jiraIssueType', @Priority = '$jiraPriority', @EmailRecipients = '$jiraEmailRecipients', @CascadingField_ID = '$jiraCascadingFieldId', @CascadingField_ParentValue = '$jiraCascadingParent', @CascadingField_ChildValue = '$cascadingChild', @CustomField_ID = '$jiraCustomField1Id', @CustomField_Value = '$jiraCustomField1Value', @CustomField2_ID = '$jiraCustomField2Id', @CustomField2_Value = '$jiraCustomField2Value', @DueDate = '$jiraDueDate', @TriggerType = '$triggerType', @TriggerValue = '$triggerValue'" | Out-Null
                            Write-Log "    Jira ticket queued for file $fileRegId" "SUCCESS"
                        } else { Write-Log "    Jira dedup: ticket exists for $triggerType/$triggerValue" "INFO" }
                    }
                    if ($routing -band 1) {
                        $teamsDedup = Get-SqlData -Query "SELECT TOP 1 1 AS x FROM Teams.RequestLog WHERE trigger_type = '$triggerType' AND trigger_value = '$triggerValue' AND status_code = 200"
                        if (-not $teamsDedup) {
                            $teamsTitleSafe = ("{{FIRE}} BDL Stage Failed: $filenameDisplay") -replace "'", "''"
                            $teamsMessageSafe = ("**File Registry ID:** $fileRegId`n**Filename:** $filenameDisplay`n**Entity Type:** $entityType`n**Total Records:** $totalRecs`n**Created:** $createdTime`n`n**Error:** $errMsg`n`nAction: Review the BDL file for XML validation errors or unconfigured entity types.`n`n**Detection:** $detectionTime") -replace "'", "''"
                            Invoke-SqlNonQuery -Query "INSERT INTO Teams.AlertQueue (source_module, alert_category, title, message, color, trigger_type, trigger_value, status, created_dttm) VALUES ('BatchOps', 'CRITICAL', N'$teamsTitleSafe', N'$teamsMessageSafe', 'attention', '$triggerType', '$triggerValue', 'Pending', GETDATE())" | Out-Null
                            Write-Log "    Teams alert queued for file $fileRegId" "SUCCESS"
                        } else { Write-Log "    Teams dedup: alert exists for $triggerType/$triggerValue" "INFO" }
                    }
                    Invoke-SqlNonQuery -Query "UPDATE BatchOps.BDL_BatchTracking SET alert_count = alert_count + 1 WHERE file_registry_id = $fileRegId" | Out-Null
                    $alertsFired++
                }
            }
        }

        # ══════════════════════════════════════════════════════════════════
        # CHECK 2: Import Failed (completed_status = 'IMPORT_FAILED')
        # ══════════════════════════════════════════════════════════════════
        $routing = $Script:Config.BDL_Alert_ImportFailed

        $importFailures = Get-SqlData -Query @"
            SELECT file_registry_id, filename, entity_type, total_record_count,
                   staging_success_count, error_message, file_created_dttm, alert_count
            FROM BatchOps.BDL_BatchTracking
            WHERE is_complete = 1 AND completed_status = 'IMPORT_FAILED' AND alert_count = 0
"@

        if ($importFailures) {
            foreach ($file in @($importFailures)) {
                $alertsDetected++
                $fileRegId = $file.file_registry_id
                $filenameDisplay = if ($file.filename -isnot [DBNull]) { $file.filename } else { "File $fileRegId" }
                Write-Log "  ALERT: Import failed - file $fileRegId ($filenameDisplay)" "WARN"

                if ($Script:Config.BDL_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $entityType = if ($file.entity_type -isnot [DBNull]) { $file.entity_type } else { 'Unknown' }
                    $totalRecs = if ($file.total_record_count -isnot [DBNull]) { $file.total_record_count } else { 'N/A' }
                    $stagedCount = if ($file.staging_success_count -isnot [DBNull]) { $file.staging_success_count } else { 'N/A' }
                    $errMsg = if ($file.error_message -isnot [DBNull]) { $file.error_message } else { 'No error details available' }
                    $triggerType = 'BDL_ImportFailed'; $triggerValue = "$fileRegId"; $cascadingChild = 'BDL Import Failure'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $createdTime = if ($file.file_created_dttm -isnot [DBNull]) { $file.file_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }

                    if ($routing -band 2) {
                        $jiraDedup = Get-SqlData -Query "SELECT TOP 1 1 AS x FROM Jira.RequestLog WHERE Trigger_Type = '$triggerType' AND Trigger_Value = '$triggerValue' AND StatusCode = 201 AND TicketKey IS NOT NULL AND TicketKey != 'Email'"
                        if (-not $jiraDedup) {
                            $jiraSummary = ("BDL Import Failed: $filenameDisplay") -replace "'", "''"
                            $jiraDesc = ("BDL File Import Failed`n`nFile Registry ID: $fileRegId`nFilename: $filenameDisplay`nEntity Type: $entityType`nTotal Records: $totalRecs`nRecords Staged: $stagedCount`nCreated: $createdTime`n`nError: $errMsg`n`nAction: Review import processing errors in Debt Manager.`n`nDetection Date: $detectionTime") -replace "'", "''"
                            Invoke-SqlNonQuery -Query "EXEC Jira.sp_QueueTicket @SourceModule = 'BatchOps', @ProjectKey = '$jiraProjectKey', @Summary = N'$jiraSummary', @Description = N'$jiraDesc', @IssueType = '$jiraIssueType', @Priority = '$jiraPriority', @EmailRecipients = '$jiraEmailRecipients', @CascadingField_ID = '$jiraCascadingFieldId', @CascadingField_ParentValue = '$jiraCascadingParent', @CascadingField_ChildValue = '$cascadingChild', @CustomField_ID = '$jiraCustomField1Id', @CustomField_Value = '$jiraCustomField1Value', @CustomField2_ID = '$jiraCustomField2Id', @CustomField2_Value = '$jiraCustomField2Value', @DueDate = '$jiraDueDate', @TriggerType = '$triggerType', @TriggerValue = '$triggerValue'" | Out-Null
                            Write-Log "    Jira ticket queued for file $fileRegId" "SUCCESS"
                        } else { Write-Log "    Jira dedup: ticket exists for $triggerType/$triggerValue" "INFO" }
                    }
                    if ($routing -band 1) {
                        $teamsDedup = Get-SqlData -Query "SELECT TOP 1 1 AS x FROM Teams.RequestLog WHERE trigger_type = '$triggerType' AND trigger_value = '$triggerValue' AND status_code = 200"
                        if (-not $teamsDedup) {
                            $teamsTitleSafe = ("{{FIRE}} BDL Import Failed: $filenameDisplay") -replace "'", "''"
                            $teamsMessageSafe = ("**File Registry ID:** $fileRegId`n**Filename:** $filenameDisplay`n**Entity Type:** $entityType`n**Total Records:** $totalRecs`n**Records Staged:** $stagedCount`n**Created:** $createdTime`n`n**Error:** $errMsg`n`nAction: Review import processing errors in Debt Manager.`n`n**Detection:** $detectionTime") -replace "'", "''"
                            Invoke-SqlNonQuery -Query "INSERT INTO Teams.AlertQueue (source_module, alert_category, title, message, color, trigger_type, trigger_value, status, created_dttm) VALUES ('BatchOps', 'CRITICAL', N'$teamsTitleSafe', N'$teamsMessageSafe', 'attention', '$triggerType', '$triggerValue', 'Pending', GETDATE())" | Out-Null
                            Write-Log "    Teams alert queued for file $fileRegId" "SUCCESS"
                        } else { Write-Log "    Teams dedup: alert exists for $triggerType/$triggerValue" "INFO" }
                    }
                    Invoke-SqlNonQuery -Query "UPDATE BatchOps.BDL_BatchTracking SET alert_count = alert_count + 1 WHERE file_registry_id = $fileRegId" | Out-Null
                    $alertsFired++
                }
            }
        }

        # ══════════════════════════════════════════════════════════════════
        # CHECK 3: Stalled Processing (stall_poll_count >= threshold)
        # Re-alertable per stall episode using composite trigger
        # ══════════════════════════════════════════════════════════════════
        $routing = $Script:Config.BDL_Alert_Stall
        $stallThreshold = $Script:Config.BDL_StallPollThreshold

        $stalledFiles = Get-SqlData -Query @"
            SELECT file_registry_id, filename, entity_type, total_record_count,
                   file_status, file_status_code, partition_count, partitions_completed,
                   stall_poll_count, last_log_id, last_log_dttm, file_created_dttm, alert_count
            FROM BatchOps.BDL_BatchTracking
            WHERE is_complete = 0 AND stall_poll_count >= $stallThreshold AND alert_count = 0
"@

        if ($stalledFiles) {
            foreach ($file in @($stalledFiles)) {
                $alertsDetected++
                $fileRegId = $file.file_registry_id
                $filenameDisplay = if ($file.filename -isnot [DBNull]) { $file.filename } else { "File $fileRegId" }
                $stallDuration = Get-StallDurationText -PollCount $file.stall_poll_count
                Write-Log "  ALERT: Stall detected - file $fileRegId ($filenameDisplay) - $stallDuration" "WARN"

                if ($Script:Config.BDL_AlertingEnabled -and -not $PreviewOnly -and $routing -gt 0) {
                    $entityType = if ($file.entity_type -isnot [DBNull]) { $file.entity_type } else { 'Unknown' }
                    $totalRecs = if ($file.total_record_count -isnot [DBNull]) { $file.total_record_count } else { 'N/A' }
                    $partCount = if ($file.partition_count -isnot [DBNull]) { $file.partition_count } else { 'N/A' }
                    $partCompleted = if ($file.partitions_completed -isnot [DBNull]) { $file.partitions_completed } else { 'N/A' }
                    $fileStatus = if ($file.file_status -isnot [DBNull]) { $file.file_status } else { 'Unknown' }
                    $lastLogId = $file.last_log_id
                    $lastLogTime = if ($file.last_log_dttm -isnot [DBNull]) { $file.last_log_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }
                    $triggerType = 'BDL_Stall'; $triggerValue = "${fileRegId}_${lastLogId}"; $cascadingChild = 'BDL Import Failure'
                    $detectionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $createdTime = if ($file.file_created_dttm -isnot [DBNull]) { $file.file_created_dttm.ToString("yyyy-MM-dd HH:mm:ss") } else { 'N/A' }

                    if ($routing -band 2) {
                        $jiraDedup = Get-SqlData -Query "SELECT TOP 1 1 AS x FROM Jira.RequestLog WHERE Trigger_Type = '$triggerType' AND Trigger_Value = '$triggerValue' AND StatusCode = 201 AND TicketKey IS NOT NULL AND TicketKey != 'Email'"
                        if (-not $jiraDedup) {
                            $jiraSummary = ("BDL Processing Stalled: $filenameDisplay") -replace "'", "''"
                            $jiraDesc = ("BDL File Processing Stalled`n`nFile Registry ID: $fileRegId`nFilename: $filenameDisplay`nEntity Type: $entityType`nTotal Records: $totalRecs`nFile Status: $fileStatus`nPartitions: $partCompleted of $partCount completed`nStalled: $stallDuration with no partition activity`nLast Activity: $lastLogTime`nCreated: $createdTime`n`nAction: Check BDL processing status in Debt Manager.`n`nDetection Date: $detectionTime") -replace "'", "''"
                            Invoke-SqlNonQuery -Query "EXEC Jira.sp_QueueTicket @SourceModule = 'BatchOps', @ProjectKey = '$jiraProjectKey', @Summary = N'$jiraSummary', @Description = N'$jiraDesc', @IssueType = '$jiraIssueType', @Priority = '$jiraPriority', @EmailRecipients = '$jiraEmailRecipients', @CascadingField_ID = '$jiraCascadingFieldId', @CascadingField_ParentValue = '$jiraCascadingParent', @CascadingField_ChildValue = '$cascadingChild', @CustomField_ID = '$jiraCustomField1Id', @CustomField_Value = '$jiraCustomField1Value', @CustomField2_ID = '$jiraCustomField2Id', @CustomField2_Value = '$jiraCustomField2Value', @DueDate = '$jiraDueDate', @TriggerType = '$triggerType', @TriggerValue = '$triggerValue'" | Out-Null
                            Write-Log "    Jira ticket queued for file $fileRegId" "SUCCESS"
                        } else { Write-Log "    Jira dedup: ticket exists for $triggerType/$triggerValue" "INFO" }
                    }
                    if ($routing -band 1) {
                        $teamsDedup = Get-SqlData -Query "SELECT TOP 1 1 AS x FROM Teams.RequestLog WHERE trigger_type = '$triggerType' AND trigger_value = '$triggerValue' AND status_code = 200"
                        if (-not $teamsDedup) {
                            $teamsTitleSafe = ("{{WARN}} BDL Processing Stalled: $filenameDisplay") -replace "'", "''"
                            $teamsMessageSafe = ("**File Registry ID:** $fileRegId`n**Filename:** $filenameDisplay`n**Entity Type:** $entityType`n**Total Records:** $totalRecs`n**File Status:** $fileStatus`n**Partitions:** $partCompleted of $partCount completed`n**Stalled:** $stallDuration with no partition activity`n**Last Activity:** $lastLogTime`n`nAction: Check BDL processing status in Debt Manager.`n`n**Detection:** $detectionTime") -replace "'", "''"
                            Invoke-SqlNonQuery -Query "INSERT INTO Teams.AlertQueue (source_module, alert_category, title, message, color, trigger_type, trigger_value, status, created_dttm) VALUES ('BatchOps', 'WARNING', N'$teamsTitleSafe', N'$teamsMessageSafe', 'warning', '$triggerType', '$triggerValue', 'Pending', GETDATE())" | Out-Null
                            Write-Log "    Teams alert queued for file $fileRegId" "SUCCESS"
                        } else { Write-Log "    Teams dedup: alert exists for $triggerType/$triggerValue" "INFO" }
                    }
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

# ============================================================================
# MAIN EXECUTION
# ============================================================================

$overallSuccess = $true
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $configOk = Initialize-Configuration
    if (-not $configOk) {
        Write-Log "Configuration initialization failed - aborting" "ERROR"
        $overallSuccess = $false
        return
    }

    if ($Execute) {
        Invoke-SqlNonQuery -Query "UPDATE BatchOps.Status SET processing_status = 'RUNNING', started_dttm = GETDATE() WHERE collector_name = 'Collect-BDLBatchStatus'" | Out-Null
    }

    $previewOnly = -not $Execute

    $collectResult = Step-CollectNewFiles -PreviewOnly $previewOnly
    $updateResult = Step-UpdateIncompleteFiles -PreviewOnly $previewOnly
    $alertResult = Step-EvaluateAlerts -PreviewOnly $previewOnly

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
        Invoke-SqlNonQuery -Query "UPDATE BatchOps.Status SET processing_status = 'IDLE', completed_dttm = GETDATE(), last_duration_ms = $($stopwatch.ElapsedMilliseconds), last_status = '$statusText' WHERE collector_name = 'Collect-BDLBatchStatus'" | Out-Null
    }

    if ($TaskId -gt 0 -and $ProcessId -gt 0) {
        $exitStatus = if ($overallSuccess) { 'SUCCESS' } else { 'FAILED' }
        $outputSummary = "New:$($collectResult.NewFiles) Updated:$($updateResult.Updated) Completed:$($updateResult.Completed) Alerts:$($alertResult.Fired)"
        Complete-OrchestratorTask -TaskId $TaskId -ProcessId $ProcessId `
            -Status $exitStatus -OutputSummary $outputSummary `
            -ServerInstance $ServerInstance -Database $Database
    }
}
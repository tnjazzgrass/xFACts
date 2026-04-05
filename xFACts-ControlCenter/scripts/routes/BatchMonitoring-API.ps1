# ============================================================================
# xFACts Control Center - Batch Monitoring API
# Location: E:\xFACts-ControlCenter\scripts\routes\BatchMonitoring-API.ps1
# Version: Tracked in dbo.System_Metadata (component: BatchOps)
#
# API endpoints for Batch Monitoring dashboard.
# All endpoints require ADLogin authentication.
#
# Endpoints:
#   GET /api/batch-monitoring/process-status    - Collector health from BatchOps.Status
#   GET /api/batch-monitoring/active-batches    - Currently in-flight NB + PMT + BDL batches
#   GET /api/batch-monitoring/daily-summary     - Today's batch counts and status breakdown
#   GET /api/batch-monitoring/history           - Year/month rollup for tree navigation
#   GET /api/batch-monitoring/history-month     - Day-level detail for a given month
#   GET /api/batch-monitoring/history-day       - Individual batch detail for a given day
#
# ============================================================================

# ============================================================================
# Process Status - Collector Health Cards
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/batch-monitoring/process-status' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $results = Invoke-XFActsQuery -Query @"
            SELECT
                s.collector_name,
                s.batch_type,
                s.processing_status,
                s.started_dttm,
                s.completed_dttm,
                s.last_duration_ms,
                s.last_status,
                DATEDIFF(SECOND, s.completed_dttm, GETDATE()) AS seconds_since_run,
                pr.interval_seconds,
                pr.scheduled_time,
                CASE
                    WHEN s.processing_status = 'RUNNING' THEN 'running'
                    WHEN s.last_status = 'FAILED' THEN 'critical'
                    WHEN pr.scheduled_time IS NOT NULL THEN 'healthy'
                    WHEN s.completed_dttm IS NULL THEN 'critical'
                    WHEN DATEDIFF(SECOND, s.completed_dttm, GETDATE()) > (pr.interval_seconds * 3) THEN 'critical'
                    WHEN DATEDIFF(SECOND, s.completed_dttm, GETDATE()) > (pr.interval_seconds * 2) THEN 'warning'
                    ELSE 'healthy'
                END AS health_status
            FROM BatchOps.Status s
            LEFT JOIN Orchestrator.ProcessRegistry pr
                ON pr.process_name = s.collector_name
                AND pr.module_name = 'BatchOps'
            ORDER BY s.collector_name
"@
        
        Write-PodeJsonResponse -Value @{ processes = $results }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# Active Batches - Live view from Debt Manager (via AG secondary replica)
# Queries crs5_oltp directly for real-time batch status. No dependency on
# xFACts tracking tables — batches appear as soon as DM creates them.
# 3-day lookback window covers weekends and lingering problem batches.
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/batch-monitoring/active-batches' -Authentication 'ADLogin' -ScriptBlock {
    try {
        # Active NB batches - direct from DM source tables
        # Excludes: DELETED (5), terminal merge statuses (3, 5, 6, 8, 10)
        # Keeps: UPLOADFAILED (3), RELEASEFAILED (9), FAILED (13) visible until resolved/deleted
        $nbBatches = Invoke-CRS5ReadQuery -Query @"
            SELECT
                'NB' AS batch_type,
                b.new_bsnss_btch_id AS batch_id,
                b.new_bsnss_btch_upload_file_txt AS batch_name,
                bs.new_bsnss_btch_stts_val_txt AS batch_status,
                ms.cnsmr_mrg_lnk_stts_val_txt AS merge_status,
                b.new_bsnss_btch_crt_dt AS batch_created_dttm,
                DATEDIFF(MINUTE, b.new_bsnss_btch_crt_dt, GETDATE()) AS age_minutes,
                b.new_bsnss_btch_cnsmr_accnt_actl_ttl_nmbr AS account_count,
                b.new_bsnss_btch_cnsmr_accnt_pstd_ttl_nmbr AS posted_account_count,
                b.new_bsnss_btch_stts_cd AS batch_status_code,
                b.cnsmr_mrg_lnk_stts_cd AS merge_status_code,
                CASE WHEN b.new_bsnss_btch_auto_mrg_flg = 'Y' THEN 1 ELSE 0 END AS is_auto_merge,
                b.new_bsnss_btch_cnsmr_cnt_nmr AS consumer_count,
                lp.merge_processed_count
            FROM dbo.new_bsnss_btch b
            INNER JOIN dbo.Ref_new_bsnss_btch_stts_cd bs 
                ON b.new_bsnss_btch_stts_cd = bs.new_bsnss_btch_stts_cd
            LEFT JOIN dbo.ref_cnsmr_mrg_lnk_stts_cd ms 
                ON b.cnsmr_mrg_lnk_stts_cd = ms.cnsmr_mrg_lnk_stts_cd
            OUTER APPLY (
                SELECT COUNT(DISTINCT l.frm_cnsmr_idntfr_agncy_id) - 1 AS merge_processed_count
                FROM dbo.new_bsnss_log l
                WHERE l.new_bsnss_btch_id = b.new_bsnss_btch_id
                  AND l.frm_cnsmr_idntfr_agncy_id IS NOT NULL
            ) lp
            WHERE b.new_bsnss_btch_crt_dt >= DATEADD(DAY, -3, GETDATE())
              AND b.new_bsnss_btch_stts_cd <> 5                                    -- Exclude DELETED
              AND ISNULL(b.cnsmr_mrg_lnk_stts_cd, 0) NOT IN (3, 5, 6, 8, 10)     -- Exclude terminal merge statuses
            ORDER BY b.new_bsnss_btch_crt_dt DESC
"@
        
        # Active PMT batches - direct from DM source tables
        # Excludes: ACTIVE (1), POSTED (4), ARCHIVED (7), PROCESSED (29), PROCESSEDWITHSUSPENSE (31)
        # Keeps: FAILED (6), IMPORTFAILED (11), PARTIAL (5), REVERSALFAILED (27),
        #        ACTIVEWITHSUSPENSE (30), and all in-flight statuses visible
        $pmtBatches = Invoke-CRS5ReadQuery -Query @"
            SELECT
                'PMT' AS batch_type,
                b.cnsmr_pymnt_btch_id AS batch_id,
                b.cnsmr_pymnt_btch_nm AS batch_name,
                t.pymnt_btch_typ_val_txt AS pmt_batch_type,
                s.pymnt_btch_stts_val_txt AS batch_status,
                b.cnsmr_pymnt_btch_stts_cd AS batch_status_code,
                b.cnsmr_pymnt_btch_crt_dttm AS batch_created_dttm,
                DATEDIFF(MINUTE, b.cnsmr_pymnt_btch_crt_dttm, GETDATE()) AS age_minutes,
                b.cnsmr_pymnt_btch_actv_rec_cnt AS active_count,
                b.cnsmr_pymnt_btch_pstd_rec_cnt AS posted_count,
                j.journal_posted_count,
                j.journal_failed_count,
                b.cnsmr_pymnt_btch_extrnl_nm AS external_name
            FROM dbo.cnsmr_pymnt_btch b
            INNER JOIN dbo.ref_pymnt_btch_stts_cd s 
                ON b.cnsmr_pymnt_btch_stts_cd = s.pymnt_btch_stts_cd
            LEFT JOIN dbo.ref_pymnt_btch_typ_cd t 
                ON b.cnsmr_pymnt_btch_typ_cd = t.pymnt_btch_typ_cd
            OUTER APPLY (
                SELECT 
                    SUM(CASE WHEN pj.cnsmr_pymnt_stts_cd = 5 THEN 1 ELSE 0 END) AS journal_posted_count,
                    SUM(CASE WHEN pj.cnsmr_pymnt_stts_cd = 4 THEN 1 ELSE 0 END) AS journal_failed_count
                FROM dbo.cnsmr_pymnt_jrnl pj
                WHERE pj.cnsmr_pymnt_btch_id = b.cnsmr_pymnt_btch_id
            ) j
            WHERE b.cnsmr_pymnt_btch_crt_dttm >= DATEADD(DAY, -3, GETDATE())
              AND b.cnsmr_pymnt_btch_stts_cd NOT IN (1, 4, 7, 29, 31)    -- Exclude ACTIVE, POSTED, ARCHIVED, PROCESSED, PROCESSEDWITHSUSPENSE
            ORDER BY b.cnsmr_pymnt_btch_crt_dttm DESC
"@
        
        # Active BDL files - direct from DM source tables
        # BDL lifecycle: PROCESSING (2) -> STAGED (10) -> IMPORTED (12)
        # BDL status lives in bdl_log (no batch table with status column like NB/PMT).
        # CurrentStatus CTE finds the true latest file-level status from all log entries,
        # then the outer WHERE excludes files whose latest status is terminal.
        # Terminal: IMPORTED (12), DELETING (13), DELETED (14)
        # Keeps: PROCESSING (2), STAGED (10), STAGEFAILED (8), IMPORT_FAILED (11)
        # Uses file-level log entries (sub_entty_nm_txt IS NULL) for status,
        # partition-level entries (sub_entty_nm_txt IS NOT NULL) for progress
        $bdlBatches = Invoke-CRS5ReadQuery -Query @"
            ;WITH CurrentStatus AS (
                SELECT
                    bl.file_registry_id,
                    bl.bdl_prcss_stss_cd,
                    s.entty_async_stts_val_txt AS status_text,
                    bl.crtd_dttm AS status_dttm,
                    ROW_NUMBER() OVER (PARTITION BY bl.file_registry_id ORDER BY bl.crtd_dttm DESC) AS rn
                FROM dbo.bdl_log bl
                INNER JOIN dbo.ref_entty_async_stts_cd s ON bl.bdl_prcss_stss_cd = s.entty_async_stts_cd
                WHERE bl.sub_entty_nm_txt IS NULL
                  AND bl.crtd_dttm >= DATEADD(DAY, -3, GETDATE())
            ),
            EntityType AS (
                SELECT file_registry_id, sub_entty_nm_txt,
                    ROW_NUMBER() OVER (PARTITION BY file_registry_id ORDER BY bdl_log_id) AS rn
                FROM dbo.bdl_log
                WHERE sub_entty_nm_txt IS NOT NULL
                  AND crtd_dttm >= DATEADD(DAY, -3, GETDATE())
            ),
            PartitionProgress AS (
                SELECT bl.file_registry_id,
                    COUNT(DISTINCT bl.bdl_prttn_nmbr) AS partition_count,
                    SUM(CASE WHEN bl.bdl_prcss_stss_cd IN (3, 7) AND bl.bdl_prcssd_cnt IS NOT NULL THEN 1 ELSE 0 END) AS partitions_completed
                FROM dbo.bdl_log bl
                WHERE bl.sub_entty_nm_txt IS NOT NULL
                  AND bl.crtd_dttm >= DATEADD(DAY, -3, GETDATE())
                GROUP BY bl.file_registry_id
            )
            SELECT
                'BDL' AS batch_type,
                cs.file_registry_id AS batch_id,
                fr.file_name_full_txt AS batch_name,
                cs.status_text AS batch_status,
                cs.bdl_prcss_stss_cd AS file_status_code,
                fr.file_crt_dttm AS batch_created_dttm,
                DATEDIFF(MINUTE, fr.file_crt_dttm, GETDATE()) AS age_minutes,
                frd.file_rgstry_dtl_rec_ttl_cnt AS total_record_count,
                et.sub_entty_nm_txt AS entity_type,
                pp.partition_count,
                pp.partitions_completed
            FROM CurrentStatus cs
            INNER JOIN dbo.File_Registry fr ON cs.file_registry_id = fr.File_registry_id
            LEFT JOIN dbo.file_rgstry_dtl frd ON cs.file_registry_id = frd.file_registry_id
            LEFT JOIN EntityType et ON cs.file_registry_id = et.file_registry_id AND et.rn = 1
            LEFT JOIN PartitionProgress pp ON cs.file_registry_id = pp.file_registry_id
            WHERE cs.rn = 1
              AND cs.bdl_prcss_stss_cd NOT IN (12, 13, 14)    -- Exclude terminal: IMPORTED, DELETING, DELETED
            ORDER BY fr.file_crt_dttm DESC
"@
        
        Write-PodeJsonResponse -Value @{
            nb = $nbBatches
            pmt = $pmtBatches
            bdl = $bdlBatches
            nb_count = @($nbBatches).Count
            pmt_count = @($pmtBatches).Count
            bdl_count = @($bdlBatches).Count
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# Daily Summary - Today's batch activity at a glance
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/batch-monitoring/daily-summary' -Authentication 'ADLogin' -ScriptBlock {
    try {
        # NB batches created today
        # Success = merge-complete statuses; Failed = everything else complete
        $nbToday = Invoke-XFActsQuery -Query @"
            SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN is_complete = 1 AND completed_status IN (
                    'POST_RELEASE_MERGE_COMPLETE', 'POST_RELEASE_PRTL_MRGD_WTH_ERS',
                    'POST_RELEASE_MERGE_CMPLT_WTH_ERS', 'POST_RELEASE_PARTIAL_MERGED',
                    'POST_RELEASE_LINK_COMPLETE'
                ) THEN 1 ELSE 0 END) AS completed,
                SUM(CASE WHEN is_complete = 1 AND completed_status NOT IN (
                    'POST_RELEASE_MERGE_COMPLETE', 'POST_RELEASE_PRTL_MRGD_WTH_ERS',
                    'POST_RELEASE_MERGE_CMPLT_WTH_ERS', 'POST_RELEASE_PARTIAL_MERGED',
                    'POST_RELEASE_LINK_COMPLETE'
                ) THEN 1 ELSE 0 END) AS failed,
                SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
                SUM(ISNULL(account_count, 0)) AS total_accounts
            FROM BatchOps.NB_BatchTracking
            WHERE CAST(batch_created_dttm AS DATE) = CAST(GETDATE() AS DATE)
"@
        
        # PMT batches created today
        # Success = POSTED; Failed = everything else complete
        # Excludes REAPPLY, BALANCE_ADJUSTMENT, VIRTUAL, CONSUMER_CHECK from headline counts
        $pmtToday = Invoke-XFActsQuery -Query @"
            SELECT
                SUM(CASE WHEN batch_type NOT IN ('REAPPLY', 'BALANCE_ADJUSTMENT', 'VIRTUAL', 'CONSUMER_CHECK') THEN 1 ELSE 0 END) AS total,
                SUM(CASE WHEN batch_type NOT IN ('REAPPLY', 'BALANCE_ADJUSTMENT', 'VIRTUAL', 'CONSUMER_CHECK') AND is_complete = 1 AND completed_status = 'POSTED' THEN 1 ELSE 0 END) AS completed,
                SUM(CASE WHEN batch_type NOT IN ('REAPPLY', 'BALANCE_ADJUSTMENT', 'VIRTUAL', 'CONSUMER_CHECK') AND is_complete = 1 AND completed_status <> 'POSTED' THEN 1 ELSE 0 END) AS failed,
                SUM(CASE WHEN batch_type NOT IN ('REAPPLY', 'BALANCE_ADJUSTMENT', 'VIRTUAL', 'CONSUMER_CHECK') AND is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
                SUM(CASE WHEN batch_type NOT IN ('REAPPLY', 'BALANCE_ADJUSTMENT', 'VIRTUAL', 'CONSUMER_CHECK') THEN ISNULL(active_count, 0) ELSE 0 END) AS total_payments,
                SUM(CASE WHEN batch_type = 'REAPPLY' THEN 1 ELSE 0 END) AS reapply_count,
                SUM(CASE WHEN batch_type IN ('BALANCE_ADJUSTMENT', 'VIRTUAL', 'CONSUMER_CHECK') THEN 1 ELSE 0 END) AS other_count
            FROM BatchOps.PMT_BatchTracking
            WHERE CAST(batch_created_dttm AS DATE) = CAST(GETDATE() AS DATE)
"@
        
        # BDL files created today
        # Success = IMPORTED; Failed = STAGEFAILED or IMPORT_FAILED
        $bdlToday = Invoke-XFActsQuery -Query @"
            SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN is_complete = 1 AND completed_status = 'IMPORTED' THEN 1 ELSE 0 END) AS completed,
                SUM(CASE WHEN is_complete = 1 AND completed_status IN ('STAGEFAILED', 'IMPORT_FAILED') THEN 1 ELSE 0 END) AS failed,
                SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
                SUM(ISNULL(total_record_count, 0)) AS total_records
            FROM BatchOps.BDL_BatchTracking
            WHERE CAST(file_created_dttm AS DATE) = CAST(GETDATE() AS DATE)
"@
        
        Write-PodeJsonResponse -Value @{
            nb = if ($nbToday.Count -gt 0) { $nbToday[0] } else { @{ total = 0; completed = 0; failed = 0; in_flight = 0; total_accounts = 0 } }
            pmt = if ($pmtToday.Count -gt 0) { $pmtToday[0] } else { @{ total = 0; completed = 0; failed = 0; in_flight = 0; total_payments = 0; reapply_count = 0; other_count = 0 } }
            bdl = if ($bdlToday.Count -gt 0) { $bdlToday[0] } else { @{ total = 0; completed = 0; failed = 0; in_flight = 0; total_records = 0 } }
        }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# History - Year/Month rollup for tree navigation
# Query parameter: ?type=ALL|NB|PMT|BDL (default ALL)
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/batch-monitoring/history' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $typeFilter = $WebEvent.Query['type']
        if (-not $typeFilter) { $typeFilter = 'ALL' }
        
        $years = @()
        
        # NB history rollup
        if ($typeFilter -eq 'ALL' -or $typeFilter -eq 'NB') {
            $nbYears = Invoke-XFActsQuery -Query @"
                SELECT
                    'NB' AS batch_type,
                    YEAR(batch_created_dttm) AS [year],
                    MONTH(batch_created_dttm) AS [month],
                    COUNT(*) AS total_batches,
                    SUM(CASE WHEN is_complete = 1 AND completed_status IN (
                        'POST_RELEASE_MERGE_COMPLETE', 'POST_RELEASE_PRTL_MRGD_WTH_ERS',
                        'POST_RELEASE_MERGE_CMPLT_WTH_ERS', 'POST_RELEASE_PARTIAL_MERGED',
                        'POST_RELEASE_LINK_COMPLETE'
                    ) THEN 1 ELSE 0 END) AS completed,
                    SUM(CASE WHEN is_complete = 1 AND completed_status NOT IN (
                        'POST_RELEASE_MERGE_COMPLETE', 'POST_RELEASE_PRTL_MRGD_WTH_ERS',
                        'POST_RELEASE_MERGE_CMPLT_WTH_ERS', 'POST_RELEASE_PARTIAL_MERGED',
                        'POST_RELEASE_LINK_COMPLETE'
                    ) THEN 1 ELSE 0 END) AS failed,
                    SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
                    SUM(ISNULL(account_count, 0)) AS total_records,
                    AVG(CASE WHEN completed_dttm IS NOT NULL THEN DATEDIFF(MINUTE, batch_created_dttm, completed_dttm) END) AS avg_total_minutes
                FROM BatchOps.NB_BatchTracking
                GROUP BY YEAR(batch_created_dttm), MONTH(batch_created_dttm)
                ORDER BY [year] DESC, [month] DESC
"@
            $years += $nbYears
        }
        
        # PMT history rollup
        if ($typeFilter -eq 'ALL' -or $typeFilter -eq 'PMT') {
            $pmtYears = Invoke-XFActsQuery -Query @"
                SELECT
                    'PMT' AS batch_type,
                    YEAR(batch_created_dttm) AS [year],
                    MONTH(batch_created_dttm) AS [month],
                    COUNT(*) AS total_batches,
                    SUM(CASE WHEN is_complete = 1 AND completed_status = 'POSTED' THEN 1 ELSE 0 END) AS completed,
                    SUM(CASE WHEN is_complete = 1 AND completed_status <> 'POSTED' THEN 1 ELSE 0 END) AS failed,
                    SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
                    SUM(ISNULL(active_count, 0)) AS total_records,
                    AVG(CASE WHEN completed_dttm IS NOT NULL THEN DATEDIFF(MINUTE, batch_created_dttm, completed_dttm) END) AS avg_total_minutes
                FROM BatchOps.PMT_BatchTracking
                WHERE batch_type NOT IN ('REAPPLY', 'BALANCE_ADJUSTMENT', 'VIRTUAL', 'CONSUMER_CHECK')
                GROUP BY YEAR(batch_created_dttm), MONTH(batch_created_dttm)
                ORDER BY [year] DESC, [month] DESC
"@
            $years += $pmtYears
        }
        
        # BDL history rollup
        if ($typeFilter -eq 'ALL' -or $typeFilter -eq 'BDL') {
            $bdlYears = Invoke-XFActsQuery -Query @"
                SELECT
                    'BDL' AS batch_type,
                    YEAR(file_created_dttm) AS [year],
                    MONTH(file_created_dttm) AS [month],
                    COUNT(*) AS total_batches,
                    SUM(CASE WHEN is_complete = 1 AND completed_status = 'IMPORTED' THEN 1 ELSE 0 END) AS completed,
                    SUM(CASE WHEN is_complete = 1 AND completed_status IN ('STAGEFAILED', 'IMPORT_FAILED') THEN 1 ELSE 0 END) AS failed,
                    SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
                    SUM(ISNULL(total_record_count, 0)) AS total_records,
                    AVG(CASE WHEN completed_dttm IS NOT NULL THEN DATEDIFF(MINUTE, file_created_dttm, completed_dttm) END) AS avg_total_minutes
                FROM BatchOps.BDL_BatchTracking
                GROUP BY YEAR(file_created_dttm), MONTH(file_created_dttm)
                ORDER BY [year] DESC, [month] DESC
"@
            $years += $bdlYears
        }
        
        Write-PodeJsonResponse -Value @{ data = $years }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# History Month Detail - Day-level rows for a given year/month
# Query parameters: ?year=YYYY&month=MM&type=ALL|NB|PMT|BDL
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/batch-monitoring/history-month' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $year = [int]$WebEvent.Query['year']
        $month = [int]$WebEvent.Query['month']
        $typeFilter = $WebEvent.Query['type']
        if (-not $typeFilter) { $typeFilter = 'ALL' }
        
        $days = @()
        
        if ($typeFilter -eq 'ALL' -or $typeFilter -eq 'NB') {
            $nbDays = Invoke-XFActsQuery -Query @"
                SELECT
                    'NB' AS batch_type,
                    CAST(batch_created_dttm AS DATE) AS batch_date,
                    COUNT(*) AS total_batches,
                    SUM(CASE WHEN is_complete = 1 AND completed_status IN (
                        'POST_RELEASE_MERGE_COMPLETE', 'POST_RELEASE_PRTL_MRGD_WTH_ERS',
                        'POST_RELEASE_MERGE_CMPLT_WTH_ERS', 'POST_RELEASE_PARTIAL_MERGED',
                        'POST_RELEASE_LINK_COMPLETE'
                    ) THEN 1 ELSE 0 END) AS completed,
                    SUM(CASE WHEN is_complete = 1 AND completed_status NOT IN (
                        'POST_RELEASE_MERGE_COMPLETE', 'POST_RELEASE_PRTL_MRGD_WTH_ERS',
                        'POST_RELEASE_MERGE_CMPLT_WTH_ERS', 'POST_RELEASE_PARTIAL_MERGED',
                        'POST_RELEASE_LINK_COMPLETE'
                    ) THEN 1 ELSE 0 END) AS failed,
                    SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
                    SUM(ISNULL(account_count, 0)) AS total_records,
                    AVG(DATEDIFF(MINUTE, batch_created_dttm, release_completed_dttm)) AS avg_upload_to_release_min,
                    AVG(DATEDIFF(MINUTE, release_completed_dttm, merge_started_dttm)) AS avg_release_to_merge_min,
                    AVG(DATEDIFF(MINUTE, merge_started_dttm, merge_completed_dttm)) AS avg_merge_duration_min,
                    AVG(CASE WHEN completed_dttm IS NOT NULL THEN DATEDIFF(MINUTE, batch_created_dttm, completed_dttm) END) AS avg_total_min
                FROM BatchOps.NB_BatchTracking
                WHERE YEAR(batch_created_dttm) = @year
                  AND MONTH(batch_created_dttm) = @month
                GROUP BY CAST(batch_created_dttm AS DATE)
                ORDER BY batch_date DESC
"@ -Parameters @{ year = $year; month = $month }
            $days += $nbDays
        }
        
        if ($typeFilter -eq 'ALL' -or $typeFilter -eq 'PMT') {
            $pmtDays = Invoke-XFActsQuery -Query @"
                SELECT
                    'PMT' AS batch_type,
                    CAST(batch_created_dttm AS DATE) AS batch_date,
                    COUNT(*) AS total_batches,
                    SUM(CASE WHEN is_complete = 1 AND completed_status = 'POSTED' THEN 1 ELSE 0 END) AS completed,
                    SUM(CASE WHEN is_complete = 1 AND completed_status <> 'POSTED' THEN 1 ELSE 0 END) AS failed,
                    SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
                    SUM(ISNULL(active_count, 0)) AS total_records,
                    AVG(DATEDIFF(MINUTE, batch_created_dttm, released_dttm)) AS avg_created_to_release_min,
                    AVG(DATEDIFF(MINUTE, released_dttm, processed_dttm)) AS avg_release_to_processed_min,
                    NULL AS avg_merge_duration_min,
                    AVG(CASE WHEN completed_dttm IS NOT NULL THEN DATEDIFF(MINUTE, batch_created_dttm, completed_dttm) END) AS avg_total_min
                FROM BatchOps.PMT_BatchTracking
                WHERE YEAR(batch_created_dttm) = @year
                  AND MONTH(batch_created_dttm) = @month
                  AND batch_type NOT IN ('REAPPLY', 'BALANCE_ADJUSTMENT', 'VIRTUAL', 'CONSUMER_CHECK')
                GROUP BY CAST(batch_created_dttm AS DATE)
                ORDER BY batch_date DESC
"@ -Parameters @{ year = $year; month = $month }
            $days += $pmtDays
        }
        
        if ($typeFilter -eq 'ALL' -or $typeFilter -eq 'BDL') {
            $bdlDays = Invoke-XFActsQuery -Query @"
                SELECT
                    'BDL' AS batch_type,
                    CAST(file_created_dttm AS DATE) AS batch_date,
                    COUNT(*) AS total_batches,
                    SUM(CASE WHEN is_complete = 1 AND completed_status = 'IMPORTED' THEN 1 ELSE 0 END) AS completed,
                    SUM(CASE WHEN is_complete = 1 AND completed_status IN ('STAGEFAILED', 'IMPORT_FAILED') THEN 1 ELSE 0 END) AS failed,
                    SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
                    SUM(ISNULL(total_record_count, 0)) AS total_records,
                    AVG(DATEDIFF(MINUTE, file_created_dttm, staged_dttm)) AS avg_upload_to_release_min,
                    AVG(DATEDIFF(MINUTE, staged_dttm, imported_dttm)) AS avg_release_to_processed_min,
                    NULL AS avg_merge_duration_min,
                    AVG(CASE WHEN completed_dttm IS NOT NULL THEN DATEDIFF(MINUTE, file_created_dttm, completed_dttm) END) AS avg_total_min
                FROM BatchOps.BDL_BatchTracking
                WHERE YEAR(file_created_dttm) = @year
                  AND MONTH(file_created_dttm) = @month
                GROUP BY CAST(file_created_dttm AS DATE)
                ORDER BY batch_date DESC
"@ -Parameters @{ year = $year; month = $month }
            $days += $bdlDays
        }
        
        Write-PodeJsonResponse -Value @{ data = $days }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# History Day Detail - Individual batches for a given day
# Query parameters: ?date=YYYY-MM-DD&type=ALL|NB|PMT|BDL
# ============================================================================
Add-PodeRoute -Method Get -Path '/api/batch-monitoring/history-day' -Authentication 'ADLogin' -ScriptBlock {
    try {
        $date = $WebEvent.Query['date']
        $typeFilter = $WebEvent.Query['type']
        if (-not $typeFilter) { $typeFilter = 'ALL' }
        
        $batches = @()
        
        if ($typeFilter -eq 'ALL' -or $typeFilter -eq 'NB') {
            $nbBatches = Invoke-XFActsQuery -Query @"
                SELECT
                    'NB' AS batch_type,
                    batch_id,
                    batch_name,
                    upload_filename,
                    batch_status,
                    merge_status,
                    is_complete,
                    completed_status,
                    batch_created_dttm,
                    release_started_dttm,
                    release_completed_dttm,
                    merge_started_dttm,
                    merge_completed_dttm,
                    completed_dttm,
                    DATEDIFF(MINUTE, batch_created_dttm, release_completed_dttm) AS upload_to_release_min,
                    DATEDIFF(MINUTE, release_completed_dttm, merge_started_dttm) AS release_to_merge_min,
                    DATEDIFF(MINUTE, merge_started_dttm, merge_completed_dttm) AS merge_duration_min,
                    DATEDIFF(MINUTE, batch_created_dttm, completed_dttm) AS total_min,
                    consumer_count,
                    account_count,
                    posted_account_count,
                    total_balance_amt,
                    alert_count,
                    stall_poll_count,
                    is_auto_merge,
                    is_manual_upload
                FROM BatchOps.NB_BatchTracking
                WHERE CAST(batch_created_dttm AS DATE) = @date
                ORDER BY batch_created_dttm DESC
"@ -Parameters @{ date = $date }
            $batches += $nbBatches
        }
        
        if ($typeFilter -eq 'ALL' -or $typeFilter -eq 'PMT') {
            $pmtBatches = Invoke-XFActsQuery -Query @"
                SELECT
                    'PMT' AS batch_type,
                    batch_id,
                    batch_name,
                    external_name,
                    batch_type AS pmt_batch_type,
                    batch_status,
                    is_complete,
                    completed_status,
                    batch_created_dttm,
                    released_dttm,
                    processed_dttm,
                    completed_dttm,
                    DATEDIFF(MINUTE, batch_created_dttm, released_dttm) AS created_to_release_min,
                    DATEDIFF(MINUTE, released_dttm, processed_dttm) AS release_to_processed_min,
                    DATEDIFF(MINUTE, batch_created_dttm, completed_dttm) AS total_min,
                    active_count,
                    posted_count,
                    journal_posted_count,
                    journal_failed_count,
                    alert_count,
                    stall_poll_count,
                    is_auto_post
                FROM BatchOps.PMT_BatchTracking
                WHERE CAST(batch_created_dttm AS DATE) = @date
                ORDER BY batch_created_dttm DESC
"@ -Parameters @{ date = $date }
            $batches += $pmtBatches
        }
        
        if ($typeFilter -eq 'ALL' -or $typeFilter -eq 'BDL') {
            $bdlBatches = Invoke-XFActsQuery -Query @"
                SELECT
                    'BDL' AS batch_type,
                    file_registry_id AS batch_id,
                    filename AS batch_name,
                    entity_type,
                    file_status AS batch_status,
                    file_status_code,
                    is_complete,
                    completed_status,
                    file_created_dttm AS batch_created_dttm,
                    processing_started_dttm,
                    staged_dttm,
                    imported_dttm,
                    completed_dttm,
                    DATEDIFF(MINUTE, file_created_dttm, staged_dttm) AS created_to_staged_min,
                    DATEDIFF(MINUTE, staged_dttm, imported_dttm) AS staged_to_imported_min,
                    DATEDIFF(MINUTE, file_created_dttm, completed_dttm) AS total_min,
                    total_record_count,
                    staging_success_count,
                    staging_failed_count,
                    import_processed_count,
                    import_success_count,
                    import_failed_count,
                    partition_count,
                    partitions_completed,
                    error_message,
                    alert_count,
                    stall_poll_count
                FROM BatchOps.BDL_BatchTracking
                WHERE CAST(file_created_dttm AS DATE) = @date
                ORDER BY file_created_dttm DESC
"@ -Parameters @{ date = $date }
            $batches += $bdlBatches
        }
        
        Write-PodeJsonResponse -Value @{ data = $batches }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = $_.Exception.Message } -StatusCode 500
    }
}

# ============================================================================
# ============================================================================
# ENGINE STATUS — REMOVED
# ============================================================================
# The /api/batch-monitoring/engine-status endpoint (~80 lines) was removed.
# Engine indicator cards (NB, PMT, Summary) are now driven by the shared
# engine-events.js WebSocket module via real-time PROCESS_STARTED/COMPLETED events.
# See: RealTime_Engine_Events_Architecture.md
# ============================================================================
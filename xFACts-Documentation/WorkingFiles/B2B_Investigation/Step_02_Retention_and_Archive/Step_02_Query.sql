-- ============================================================================
-- B2B INVESTIGATION — Step 2: Retention and Archive Truth
-- Purpose: Determine actual data horizon across live + _RESTORE tables
--          Answer: "How far back can we see workflow history in b2bi?"
-- ============================================================================

USE b2bi;
GO

-- ----------------------------------------------------------------------------
-- 2.1 WF_INST_S — live workflow instances: date range
-- ----------------------------------------------------------------------------
SELECT
    'WF_INST_S (live)' AS source,
    COUNT(*) AS row_count,
    MIN(START_TIME) AS oldest_start,
    MAX(START_TIME) AS newest_start,
    DATEDIFF(HOUR, MIN(START_TIME), MAX(START_TIME)) AS span_hours,
    DATEDIFF(DAY, MIN(START_TIME), MAX(START_TIME)) AS span_days
FROM WF_INST_S;

-- ----------------------------------------------------------------------------
-- 2.2 WF_INST_S_RESTORE — archived workflow instances: date range
-- ----------------------------------------------------------------------------
SELECT
    'WF_INST_S_RESTORE (archived)' AS source,
    COUNT(*) AS row_count,
    MIN(START_TIME) AS oldest_start,
    MAX(START_TIME) AS newest_start,
    DATEDIFF(HOUR, MIN(START_TIME), MAX(START_TIME)) AS span_hours,
    DATEDIFF(DAY, MIN(START_TIME), MAX(START_TIME)) AS span_days
FROM WF_INST_S_RESTORE;

-- ----------------------------------------------------------------------------
-- 2.3 Overlap check: do live and RESTORE share any WORKFLOW_IDs?
--     Expected: NO (they should be disjoint if archive truly moves rows)
-- ----------------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM WF_INST_S) AS live_count,
    (SELECT COUNT(*) FROM WF_INST_S_RESTORE) AS restore_count,
    (SELECT COUNT(*) FROM WF_INST_S w
     INNER JOIN WF_INST_S_RESTORE r ON w.WORKFLOW_ID = r.WORKFLOW_ID) AS overlap_count;

-- ----------------------------------------------------------------------------
-- 2.4 Daily volume across live + RESTORE combined (last 30 days)
--     Shows if archive rolloff is visible as daily-volume dropoff
-- ----------------------------------------------------------------------------
SELECT
    CAST(START_TIME AS DATE) AS start_date,
    SUM(CASE WHEN source = 'LIVE' THEN 1 ELSE 0 END) AS live_rows,
    SUM(CASE WHEN source = 'RESTORE' THEN 1 ELSE 0 END) AS restore_rows,
    COUNT(*) AS total_rows
FROM (
    SELECT START_TIME, 'LIVE' AS source FROM WF_INST_S
    UNION ALL
    SELECT START_TIME, 'RESTORE' AS source FROM WF_INST_S_RESTORE
) combined
WHERE START_TIME >= DATEADD(DAY, -30, GETDATE())
GROUP BY CAST(START_TIME AS DATE)
ORDER BY start_date DESC;

-- ----------------------------------------------------------------------------
-- 2.5 WORKFLOW_CONTEXT / WFC_S_RESTORE — same retention question for step data
-- ----------------------------------------------------------------------------
SELECT
    'WORKFLOW_CONTEXT (live)' AS source,
    COUNT(*) AS row_count,
    MIN(START_TIME) AS oldest,
    MAX(START_TIME) AS newest,
    DATEDIFF(HOUR, MIN(START_TIME), MAX(START_TIME)) AS span_hours
FROM WORKFLOW_CONTEXT
UNION ALL
SELECT
    'WFC_S_RESTORE (archived)' AS source,
    COUNT(*) AS row_count,
    MIN(START_TIME) AS oldest,
    MAX(START_TIME) AS newest,
    DATEDIFF(HOUR, MIN(START_TIME), MAX(START_TIME)) AS span_hours
FROM WFC_S_RESTORE;

-- ============================================================================
-- 2.6 (revised) TRANS_DATA retention — live by CREATION_DATE,
--               archived by joining to WF_INST_S_RESTORE.START_TIME
-- ============================================================================

-- 2.6a Live TRANS_DATA — direct from CREATION_DATE
SELECT
    'TRANS_DATA (live)' AS source,
    COUNT(*) AS row_count,
    MIN(CREATION_DATE) AS oldest,
    MAX(CREATION_DATE) AS newest,
    DATEDIFF(HOUR, MIN(CREATION_DATE), MAX(CREATION_DATE)) AS span_hours
FROM TRANS_DATA;

-- 2.6b Archived TRANS_DATA — infer age via WF_INST_S_RESTORE
-- NOTE: This only covers archived payloads whose parent workflow
--       ALSO got archived. If TRANS_DATA archives at a different cadence
--       than WF_INST_S, we may miss some and overcount others.
SELECT
    'TRANS_DATA_RESTORE (archived, via WF_INST_S_RESTORE join)' AS source,
    COUNT(*) AS matched_row_count,
    MIN(w.START_TIME) AS oldest_inferred,
    MAX(w.START_TIME) AS newest_inferred,
    DATEDIFF(HOUR, MIN(w.START_TIME), MAX(w.START_TIME)) AS span_hours
FROM TRANS_DATA_RESTORE t
INNER JOIN WF_INST_S_RESTORE w ON t.WF_ID = w.WORKFLOW_ID;

-- 2.6c How many TRANS_DATA_RESTORE rows have NO matching WF_INST_S_RESTORE?
-- If this is significant, the join above underrepresents the archive
SELECT
    COUNT(*) AS trans_data_restore_total,
    SUM(CASE WHEN w.WORKFLOW_ID IS NULL THEN 1 ELSE 0 END) AS orphan_count,
    SUM(CASE WHEN w.WORKFLOW_ID IS NOT NULL THEN 1 ELSE 0 END) AS matched_count
FROM TRANS_DATA_RESTORE t
LEFT JOIN WF_INST_S_RESTORE w ON t.WF_ID = w.WORKFLOW_ID;

-- ----------------------------------------------------------------------------
-- 2.7 ARCHIVE_INFO — what does Sterling's archive driver actually hold?
-- ----------------------------------------------------------------------------
SELECT TOP 20 *
FROM ARCHIVE_INFO
ORDER BY ARCHIVE_DATE DESC;

-- ----------------------------------------------------------------------------
-- 2.8 ARCHIVE_INFO column structure + date range
-- ----------------------------------------------------------------------------
SELECT
    c.name AS column_name,
    t.name AS data_type,
    c.max_length,
    c.is_nullable
FROM sys.columns c
INNER JOIN sys.types t ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID('ARCHIVE_INFO')
ORDER BY c.column_id;

SELECT
    COUNT(*) AS row_count,
    MIN(ARCHIVE_DATE) AS oldest_archive,
    MAX(ARCHIVE_DATE) AS newest_archive,
    COUNT(DISTINCT ARCHIVE_FLAG) AS distinct_flags
FROM ARCHIVE_INFO;

-- ----------------------------------------------------------------------------
-- 2.9 ARCHIVE_INFO.ARCHIVE_FLAG distribution
--     Per IBM docs, this flag drives what happens to a row during purge
-- ----------------------------------------------------------------------------
SELECT
    ARCHIVE_FLAG,
    COUNT(*) AS row_count,
    MIN(ARCHIVE_DATE) AS oldest,
    MAX(ARCHIVE_DATE) AS newest
FROM ARCHIVE_INFO
GROUP BY ARCHIVE_FLAG
ORDER BY ARCHIVE_FLAG;


-- ----------------------------------------------------------------------------
-- STEP 2 ADDENDUM
-- ----------------------------------------------------------------------------

-- 2.A.1 WORKFLOW_CONTEXT date distribution: real or orphan?
SELECT
    CASE
        WHEN START_TIME >= DATEADD(DAY, -7, GETDATE()) THEN '1_LAST_7_DAYS'
        WHEN START_TIME >= DATEADD(DAY, -30, GETDATE()) THEN '2_LAST_30_DAYS'
        WHEN START_TIME >= DATEADD(DAY, -90, GETDATE()) THEN '3_LAST_90_DAYS'
        WHEN START_TIME >= DATEADD(DAY, -180, GETDATE()) THEN '4_LAST_180_DAYS'
        WHEN START_TIME >= DATEADD(DAY, -365, GETDATE()) THEN '5_LAST_365_DAYS'
        ELSE '6_OLDER_THAN_365'
    END AS age_bucket,
    COUNT(*) AS row_count,
    MIN(START_TIME) AS oldest,
    MAX(START_TIME) AS newest
FROM WORKFLOW_CONTEXT
GROUP BY
    CASE
        WHEN START_TIME >= DATEADD(DAY, -7, GETDATE()) THEN '1_LAST_7_DAYS'
        WHEN START_TIME >= DATEADD(DAY, -30, GETDATE()) THEN '2_LAST_30_DAYS'
        WHEN START_TIME >= DATEADD(DAY, -90, GETDATE()) THEN '3_LAST_90_DAYS'
        WHEN START_TIME >= DATEADD(DAY, -180, GETDATE()) THEN '4_LAST_180_DAYS'
        WHEN START_TIME >= DATEADD(DAY, -365, GETDATE()) THEN '5_LAST_365_DAYS'
        ELSE '6_OLDER_THAN_365'
    END
ORDER BY age_bucket;

-- 2.A.2 Same for TRANS_DATA
SELECT
    CASE
        WHEN CREATION_DATE >= DATEADD(DAY, -7, GETDATE()) THEN '1_LAST_7_DAYS'
        WHEN CREATION_DATE >= DATEADD(DAY, -30, GETDATE()) THEN '2_LAST_30_DAYS'
        WHEN CREATION_DATE >= DATEADD(DAY, -90, GETDATE()) THEN '3_LAST_90_DAYS'
        WHEN CREATION_DATE >= DATEADD(DAY, -180, GETDATE()) THEN '4_LAST_180_DAYS'
        WHEN CREATION_DATE >= DATEADD(DAY, -365, GETDATE()) THEN '5_LAST_365_DAYS'
        ELSE '6_OLDER_THAN_365'
    END AS age_bucket,
    COUNT(*) AS row_count,
    MIN(CREATION_DATE) AS oldest,
    MAX(CREATION_DATE) AS newest
FROM TRANS_DATA
GROUP BY
    CASE
        WHEN CREATION_DATE >= DATEADD(DAY, -7, GETDATE()) THEN '1_LAST_7_DAYS'
        WHEN CREATION_DATE >= DATEADD(DAY, -30, GETDATE()) THEN '2_LAST_30_DAYS'
        WHEN CREATION_DATE >= DATEADD(DAY, -90, GETDATE()) THEN '3_LAST_90_DAYS'
        WHEN CREATION_DATE >= DATEADD(DAY, -180, GETDATE()) THEN '4_LAST_180_DAYS'
        WHEN CREATION_DATE >= DATEADD(DAY, -365, GETDATE()) THEN '5_LAST_365_DAYS'
        ELSE '6_OLDER_THAN_365'
    END
ORDER BY age_bucket;

-- 2.A.3 ARCHIVE_INFO GROUP_ID distribution
SELECT
    GROUP_ID,
    ARCHIVE_FLAG,
    COUNT(*) AS row_count,
    MIN(ARCHIVE_DATE) AS oldest,
    MAX(ARCHIVE_DATE) AS newest
FROM ARCHIVE_INFO
GROUP BY GROUP_ID, ARCHIVE_FLAG
ORDER BY GROUP_ID, ARCHIVE_FLAG;

-- 2.A.4 Are ARCHIVE_FLAG=-1 rows correlated to WF_INACTIVE?
SELECT
    CASE WHEN wi.WF_ID IS NOT NULL THEN 'IN_WF_INACTIVE' ELSE 'NOT_IN_WF_INACTIVE' END AS inactive_status,
    COUNT(*) AS row_count
FROM ARCHIVE_INFO ai
LEFT JOIN WF_INACTIVE wi ON ai.WF_ID = wi.WF_ID
WHERE ai.ARCHIVE_FLAG = -1
GROUP BY CASE WHEN wi.WF_ID IS NOT NULL THEN 'IN_WF_INACTIVE' ELSE 'NOT_IN_WF_INACTIVE' END;

-- 2.A.5 For ARCHIVE_FLAG=-1 rows, can we find matching WF_INST_S rows?
-- (tells us whether they're all in-flight)
SELECT
    CASE
        WHEN w.WORKFLOW_ID IS NOT NULL THEN 'LIVE_WF_INST_S'
        WHEN r.WORKFLOW_ID IS NOT NULL THEN 'ARCHIVED_WF_INST_S'
        ELSE 'NEITHER'
    END AS workflow_status,
    COUNT(*) AS row_count
FROM ARCHIVE_INFO ai
LEFT JOIN WF_INST_S w ON ai.WF_ID = w.WORKFLOW_ID
LEFT JOIN WF_INST_S_RESTORE r ON ai.WF_ID = r.WORKFLOW_ID
WHERE ai.ARCHIVE_FLAG = -1
GROUP BY
    CASE
        WHEN w.WORKFLOW_ID IS NOT NULL THEN 'LIVE_WF_INST_S'
        WHEN r.WORKFLOW_ID IS NOT NULL THEN 'ARCHIVED_WF_INST_S'
        ELSE 'NEITHER'
    END;
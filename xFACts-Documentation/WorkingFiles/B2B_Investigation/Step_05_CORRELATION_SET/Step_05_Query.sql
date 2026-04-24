-- ============================================================================
-- B2B INVESTIGATION — Step 5: CORRELATION_SET
-- Purpose: Characterize Sterling's key-value tracking layer. Determine
--          whether it contains operationally meaningful workflow metadata
--          that we're currently missing.
-- ============================================================================

USE b2bi;
GO

-- ----------------------------------------------------------------------------
-- 5.1 CORRELATION_SET structure
-- ----------------------------------------------------------------------------
SELECT
    c.name AS column_name,
    t.name AS data_type,
    c.max_length,
    c.is_nullable,
    c.column_id
FROM sys.columns c
INNER JOIN sys.types t ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID('CORRELATION_SET')
ORDER BY c.column_id;

-- Also check the restore table structure (may differ like TRANS_DATA_RESTORE did)
SELECT
    c.name AS column_name,
    t.name AS data_type,
    c.max_length,
    c.is_nullable,
    c.column_id
FROM sys.columns c
INNER JOIN sys.types t ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID('CORREL_SET_RESTORE')
ORDER BY c.column_id;

-- ----------------------------------------------------------------------------
-- 5.2 Sample data — see what actual rows look like
-- ----------------------------------------------------------------------------
SELECT TOP 20 * FROM CORRELATION_SET;

-- ----------------------------------------------------------------------------
-- 5.3 Distinct keys — what kinds of metadata does Sterling track?
--     (assumes a column NAME or KEY or similar exists; we'll adjust based on 5.1)
--     I'm using column_id positions as placeholders; we'll refine after 5.1
-- ----------------------------------------------------------------------------
-- Placeholder: after 5.1, we'll know the actual key-column name.
-- Likely candidate names based on Sterling docs: NAME, ATTR_NAME, CORR_NAME
-- Run after 5.1 is verified and this query is adjusted if needed:
--
-- SELECT [key_column_name] AS correlation_key, COUNT(*) AS row_count
-- FROM CORRELATION_SET
-- GROUP BY [key_column_name]
-- ORDER BY row_count DESC;

-- ----------------------------------------------------------------------------
-- 5.4 How does CORRELATION_SET link to workflows?
--     Likely column: WORKFLOW_ID or OBJECT_ID (again, verify from 5.1)
--     
--     Can't write this query definitively until we see 5.1. Placeholder:
--     Once we know the workflow-linking column, we'll count:
--     - How many distinct workflows have correlation rows?
--     - How many rows per workflow on average?
-- ----------------------------------------------------------------------------

-- ============================================================================
-- Step 5 Continued: CORRELATION_SET depth analysis
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 5.3 Full NAME vocabulary — what metadata keys does Sterling capture?
-- ----------------------------------------------------------------------------
SELECT
    NAME AS correlation_key,
    COUNT(*) AS row_count,
    COUNT(DISTINCT WF_ID) AS distinct_workflows
FROM CORRELATION_SET
GROUP BY NAME
ORDER BY row_count DESC;

-- ----------------------------------------------------------------------------
-- 5.4 TYPE distribution — is it always DOCUMENT, or are there others?
-- ----------------------------------------------------------------------------
SELECT
    TYPE,
    COUNT(*) AS row_count
FROM CORRELATION_SET
GROUP BY TYPE
ORDER BY row_count DESC;

-- ----------------------------------------------------------------------------
-- 5.5 ARCHIVE_FLAG distribution (same pattern as ARCHIVE_INFO?)
-- ----------------------------------------------------------------------------
SELECT
    ARCHIVE_FLAG,
    COUNT(*) AS row_count,
    MIN(ARCHIVE_DATE) AS oldest_archive_date,
    MAX(ARCHIVE_DATE) AS newest_archive_date,
    MIN(REC_TIME) AS oldest_rec,
    MAX(REC_TIME) AS newest_rec
FROM CORRELATION_SET
GROUP BY ARCHIVE_FLAG
ORDER BY ARCHIVE_FLAG;

-- ----------------------------------------------------------------------------
-- 5.6 Correlation retention — age distribution by REC_TIME
--     (compare to WF_INST_S 30-day horizon)
-- ----------------------------------------------------------------------------
SELECT
    CASE
        WHEN REC_TIME >= DATEADD(DAY, -7, GETDATE()) THEN '1_LAST_7_DAYS'
        WHEN REC_TIME >= DATEADD(DAY, -30, GETDATE()) THEN '2_LAST_30_DAYS'
        WHEN REC_TIME >= DATEADD(DAY, -90, GETDATE()) THEN '3_LAST_90_DAYS'
        WHEN REC_TIME >= DATEADD(DAY, -180, GETDATE()) THEN '4_LAST_180_DAYS'
        WHEN REC_TIME >= DATEADD(DAY, -365, GETDATE()) THEN '5_LAST_365_DAYS'
        ELSE '6_OLDER_THAN_365'
    END AS age_bucket,
    COUNT(*) AS row_count,
    COUNT(DISTINCT WF_ID) AS distinct_workflows
FROM CORRELATION_SET
GROUP BY
    CASE
        WHEN REC_TIME >= DATEADD(DAY, -7, GETDATE()) THEN '1_LAST_7_DAYS'
        WHEN REC_TIME >= DATEADD(DAY, -30, GETDATE()) THEN '2_LAST_30_DAYS'
        WHEN REC_TIME >= DATEADD(DAY, -90, GETDATE()) THEN '3_LAST_90_DAYS'
        WHEN REC_TIME >= DATEADD(DAY, -180, GETDATE()) THEN '4_LAST_180_DAYS'
        WHEN REC_TIME >= DATEADD(DAY, -365, GETDATE()) THEN '5_LAST_365_DAYS'
        ELSE '6_OLDER_THAN_365'
    END
ORDER BY age_bucket;

-- ----------------------------------------------------------------------------
-- 5.7 Which workflow families produce correlation rows?
--     Join WF_ID -> WF_INST_S -> WFD for the families actively tracked
--     (within the 7-day live window, where joins will work)
-- ----------------------------------------------------------------------------
WITH wfd_names AS (
    SELECT WFD_ID, MIN(NAME) AS NAME
    FROM WFD
    GROUP BY WFD_ID
),
recent_workflows AS (
    SELECT WORKFLOW_ID, WFD_ID FROM WF_INST_S
    UNION ALL
    SELECT WORKFLOW_ID, WFD_ID FROM WF_INST_S_RESTORE
)
SELECT
    n.NAME AS workflow_name,
    rw.WFD_ID,
    COUNT(DISTINCT cs.WF_ID) AS distinct_workflows,
    COUNT(*) AS total_correlation_rows,
    AVG(CAST(correlation_count AS FLOAT)) AS avg_correlations_per_workflow
FROM CORRELATION_SET cs
INNER JOIN recent_workflows rw ON cs.WF_ID = rw.WORKFLOW_ID
LEFT JOIN wfd_names n ON rw.WFD_ID = n.WFD_ID
CROSS APPLY (
    SELECT COUNT(*) AS correlation_count
    FROM CORRELATION_SET cs2
    WHERE cs2.WF_ID = cs.WF_ID
) ac
GROUP BY n.NAME, rw.WFD_ID
ORDER BY total_correlation_rows DESC;

-- ----------------------------------------------------------------------------
-- 5.8 Correlation orphan rate — are most rows tied to live/archived workflows?
-- ----------------------------------------------------------------------------
SELECT
    CASE
        WHEN w.WORKFLOW_ID IS NOT NULL THEN 'LIVE_WF_INST_S'
        WHEN r.WORKFLOW_ID IS NOT NULL THEN 'ARCHIVED_WF_INST_S'
        ELSE 'ORPHAN (neither)'
    END AS workflow_status,
    COUNT(*) AS correlation_row_count,
    COUNT(DISTINCT cs.WF_ID) AS distinct_workflows
FROM CORRELATION_SET cs
LEFT JOIN WF_INST_S w ON cs.WF_ID = w.WORKFLOW_ID
LEFT JOIN WF_INST_S_RESTORE r ON cs.WF_ID = r.WORKFLOW_ID
GROUP BY
    CASE
        WHEN w.WORKFLOW_ID IS NOT NULL THEN 'LIVE_WF_INST_S'
        WHEN r.WORKFLOW_ID IS NOT NULL THEN 'ARCHIVED_WF_INST_S'
        ELSE 'ORPHAN (neither)'
    END;
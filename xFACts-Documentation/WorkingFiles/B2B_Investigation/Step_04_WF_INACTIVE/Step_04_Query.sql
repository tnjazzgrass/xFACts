-- ============================================================================
-- B2B INVESTIGATION — Step 4: WF_INACTIVE
-- Purpose: Characterize Sterling's "halted workflow" table. Understand what
--          workflows are parked there, how old, and whether they represent
--          stuck work worth surfacing in monitoring.
-- ============================================================================

USE b2bi;
GO

-- ----------------------------------------------------------------------------
-- 4.1 WF_INACTIVE structure — confirm column names and types
-- ----------------------------------------------------------------------------
SELECT
    c.name AS column_name,
    t.name AS data_type,
    c.max_length,
    c.is_nullable,
    c.column_id
FROM sys.columns c
INNER JOIN sys.types t ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID('WF_INACTIVE')
ORDER BY c.column_id;

-- ----------------------------------------------------------------------------
-- 4.2 Sample rows — understand what content actually looks like
-- ----------------------------------------------------------------------------
SELECT TOP 10 * FROM WF_INACTIVE;

-- ----------------------------------------------------------------------------
-- 4.3 Does every WF_INACTIVE row correspond to a workflow in WF_INST_S 
--     (live or restore)? Or are they orphans?
--
--     This join uses WF_ID (WF_INACTIVE) to WORKFLOW_ID (WF_INST_S)
--     Presumed mapping — we'll verify via the query.
--     If WF_ID is the wrong column name, 4.1 output will tell us and we 
--     can rerun with the correct one.
-- ----------------------------------------------------------------------------
SELECT
    CASE
        WHEN w.WORKFLOW_ID IS NOT NULL THEN 'LIVE_WF_INST_S'
        WHEN r.WORKFLOW_ID IS NOT NULL THEN 'ARCHIVED_WF_INST_S'
        ELSE 'ORPHAN (neither)'
    END AS workflow_status,
    COUNT(*) AS row_count
FROM WF_INACTIVE wi
LEFT JOIN WF_INST_S w ON wi.WF_ID = w.WORKFLOW_ID
LEFT JOIN WF_INST_S_RESTORE r ON wi.WF_ID = r.WORKFLOW_ID
GROUP BY
    CASE
        WHEN w.WORKFLOW_ID IS NOT NULL THEN 'LIVE_WF_INST_S'
        WHEN r.WORKFLOW_ID IS NOT NULL THEN 'ARCHIVED_WF_INST_S'
        ELSE 'ORPHAN (neither)'
    END;

-- ----------------------------------------------------------------------------
-- 4.4 For WF_INACTIVE rows where a workflow match exists, what workflows 
--     are they? Group by workflow name.
-- ----------------------------------------------------------------------------
WITH all_workflows AS (
    SELECT WORKFLOW_ID, WFD_ID, START_TIME FROM WF_INST_S
    UNION ALL
    SELECT WORKFLOW_ID, WFD_ID, START_TIME FROM WF_INST_S_RESTORE
),
wfd_names AS (
    SELECT WFD_ID, MIN(NAME) AS NAME
    FROM WFD
    GROUP BY WFD_ID
)
SELECT
    n.NAME AS workflow_name,
    aw.WFD_ID,
    COUNT(*) AS halted_count,
    MIN(aw.START_TIME) AS oldest_start_time,
    MAX(aw.START_TIME) AS newest_start_time
FROM WF_INACTIVE wi
INNER JOIN all_workflows aw ON wi.WF_ID = aw.WORKFLOW_ID
LEFT JOIN wfd_names n ON aw.WFD_ID = n.WFD_ID
GROUP BY n.NAME, aw.WFD_ID
ORDER BY halted_count DESC;

-- ----------------------------------------------------------------------------
-- 4.5 Age distribution of halted workflows (for those we can match)
-- ----------------------------------------------------------------------------
WITH all_workflows AS (
    SELECT WORKFLOW_ID, START_TIME FROM WF_INST_S
    UNION ALL
    SELECT WORKFLOW_ID, START_TIME FROM WF_INST_S_RESTORE
)
SELECT
    CASE
        WHEN aw.START_TIME >= DATEADD(DAY, -1, GETDATE()) THEN '1_LAST_DAY'
        WHEN aw.START_TIME >= DATEADD(DAY, -7, GETDATE()) THEN '2_LAST_7_DAYS'
        WHEN aw.START_TIME >= DATEADD(DAY, -30, GETDATE()) THEN '3_LAST_30_DAYS'
        WHEN aw.START_TIME IS NULL THEN '9_NO_MATCH_IN_WF_INST_S'
        ELSE '4_OLDER_THAN_30_DAYS'
    END AS age_bucket,
    COUNT(*) AS halted_count
FROM WF_INACTIVE wi
LEFT JOIN all_workflows aw ON wi.WF_ID = aw.WORKFLOW_ID
GROUP BY
    CASE
        WHEN aw.START_TIME >= DATEADD(DAY, -1, GETDATE()) THEN '1_LAST_DAY'
        WHEN aw.START_TIME >= DATEADD(DAY, -7, GETDATE()) THEN '2_LAST_7_DAYS'
        WHEN aw.START_TIME >= DATEADD(DAY, -30, GETDATE()) THEN '3_LAST_30_DAYS'
        WHEN aw.START_TIME IS NULL THEN '9_NO_MATCH_IN_WF_INST_S'
        ELSE '4_OLDER_THAN_30_DAYS'
    END
ORDER BY age_bucket;

-- ============================================================================
-- Step 4 Addendum: REASON distribution and date clustering
-- ============================================================================

-- 4.A.1 Distribution of REASON codes
SELECT
    REASON,
    COUNT(*) AS row_count,
    MIN(WF_DATE) AS oldest,
    MAX(WF_DATE) AS newest
FROM WF_INACTIVE
GROUP BY REASON
ORDER BY row_count DESC;

-- 4.A.2 Age distribution / clustering by day
--      Is this "one big event" or "steady trickle"?
SELECT
    CAST(WF_DATE AS DATE) AS halt_date,
    COUNT(*) AS row_count
FROM WF_INACTIVE
GROUP BY CAST(WF_DATE AS DATE)
ORDER BY halt_date DESC;
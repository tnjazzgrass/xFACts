-- ============================================================================
-- B2B INVESTIGATION — Step 3: Workflow Definition Catalog + Active Inventory
-- Purpose: Enumerate all workflow definitions; cross-reference with 48-hour 
--          instance activity to see what's actually running
-- ============================================================================

USE b2bi;
GO

-- ----------------------------------------------------------------------------
-- 3.1 WFD structure — discover columns before querying
-- ----------------------------------------------------------------------------
SELECT
    c.name AS column_name,
    t.name AS data_type,
    c.max_length,
    c.is_nullable,
    c.column_id
FROM sys.columns c
INNER JOIN sys.types t ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID('WFD')
ORDER BY c.column_id;

-- ----------------------------------------------------------------------------
-- 3.2 WFD column sample — get a feel for what's in there before bulk querying
-- ----------------------------------------------------------------------------
SELECT TOP 5 *
FROM WFD
ORDER BY WFD_ID;

-- ----------------------------------------------------------------------------
-- 3.3 WFD name-pattern distribution
--     Classify by prefix to see family taxonomy at a glance
-- ----------------------------------------------------------------------------
SELECT
    CASE
        WHEN NAME LIKE 'FA\_%' ESCAPE '\' THEN 'FA_*'
        WHEN NAME LIKE 'Schedule\_%' ESCAPE '\' THEN 'Schedule_*'
        WHEN NAME LIKE 'BPExpirator%' OR NAME LIKE 'Index%' OR NAME LIKE 'Purge%' 
             OR NAME LIKE 'Archive%' OR NAME LIKE 'DBMonitor%'
             OR NAME LIKE 'DocumentNurs%' OR NAME LIKE 'Linkage%' THEN 'Housekeeping'
        WHEN NAME LIKE 'CEB\_%' ESCAPE '\' THEN 'CEB_*'
        WHEN NAME LIKE 'YFS\_%' ESCAPE '\' THEN 'YFS_*'
        WHEN NAME LIKE 'FG\_%' ESCAPE '\' OR NAME LIKE 'AFT\_%' ESCAPE '\' THEN 'File Gateway'
        WHEN NAME LIKE 'EDIINT%' OR NAME LIKE 'AS2%' OR NAME LIKE 'AS3%' THEN 'EDIINT/AS2/AS3'
        WHEN NAME LIKE 'MBX\_%' ESCAPE '\' OR NAME LIKE 'Mailbox%' THEN 'Mailbox'
        WHEN NAME LIKE 'System%' THEN 'System_*'
        WHEN LEFT(NAME, 1) = '_' OR LEFT(NAME, 1) = '.' THEN 'Underscore/dot prefix'
        ELSE 'OTHER'
    END AS family,
    COUNT(*) AS wfd_count
FROM WFD
GROUP BY 
    CASE
        WHEN NAME LIKE 'FA\_%' ESCAPE '\' THEN 'FA_*'
        WHEN NAME LIKE 'Schedule\_%' ESCAPE '\' THEN 'Schedule_*'
        WHEN NAME LIKE 'BPExpirator%' OR NAME LIKE 'Index%' OR NAME LIKE 'Purge%' 
             OR NAME LIKE 'Archive%' OR NAME LIKE 'DBMonitor%'
             OR NAME LIKE 'DocumentNurs%' OR NAME LIKE 'Linkage%' THEN 'Housekeeping'
        WHEN NAME LIKE 'CEB\_%' ESCAPE '\' THEN 'CEB_*'
        WHEN NAME LIKE 'YFS\_%' ESCAPE '\' THEN 'YFS_*'
        WHEN NAME LIKE 'FG\_%' ESCAPE '\' OR NAME LIKE 'AFT\_%' ESCAPE '\' THEN 'File Gateway'
        WHEN NAME LIKE 'EDIINT%' OR NAME LIKE 'AS2%' OR NAME LIKE 'AS3%' THEN 'EDIINT/AS2/AS3'
        WHEN NAME LIKE 'MBX\_%' ESCAPE '\' OR NAME LIKE 'Mailbox%' THEN 'Mailbox'
        WHEN NAME LIKE 'System%' THEN 'System_*'
        WHEN LEFT(NAME, 1) = '_' OR LEFT(NAME, 1) = '.' THEN 'Underscore/dot prefix'
        ELSE 'OTHER'
    END
ORDER BY wfd_count DESC;

-- ----------------------------------------------------------------------------
-- 3.4 Workflow instances run in the last 48 hours, grouped by workflow name
--     Combined view across live + restore
--     Tells us what's actually RUNNING
-- ----------------------------------------------------------------------------
WITH all_instances AS (
    SELECT WFD_ID, WORKFLOW_ID, START_TIME
    FROM WF_INST_S
    WHERE START_TIME >= DATEADD(HOUR, -48, GETDATE())
    UNION ALL
    SELECT WFD_ID, WORKFLOW_ID, START_TIME
    FROM WF_INST_S_RESTORE
    WHERE START_TIME >= DATEADD(HOUR, -48, GETDATE())
)
SELECT
    w.NAME AS workflow_name,
    i.WFD_ID,
    COUNT(*) AS instance_count,
    MIN(i.START_TIME) AS oldest,
    MAX(i.START_TIME) AS newest
FROM all_instances i
LEFT JOIN WFD w ON i.WFD_ID = w.WFD_ID
GROUP BY w.NAME, i.WFD_ID
ORDER BY instance_count DESC;

-- ----------------------------------------------------------------------------
-- 3.5 Same as 3.4, but rolled up by name-pattern family
--     Gives us: "FA_* = 2400 instances, Schedule_* = 3200 instances, ..."
-- ----------------------------------------------------------------------------
WITH all_instances AS (
    SELECT WFD_ID, WORKFLOW_ID, START_TIME
    FROM WF_INST_S
    WHERE START_TIME >= DATEADD(HOUR, -48, GETDATE())
    UNION ALL
    SELECT WFD_ID, WORKFLOW_ID, START_TIME
    FROM WF_INST_S_RESTORE
    WHERE START_TIME >= DATEADD(HOUR, -48, GETDATE())
)
SELECT
    CASE
        WHEN w.NAME LIKE 'FA\_%' ESCAPE '\' THEN 'FA_*'
        WHEN w.NAME LIKE 'Schedule\_%' ESCAPE '\' THEN 'Schedule_*'
        WHEN w.NAME LIKE 'BPExpirator%' OR w.NAME LIKE 'Index%' OR w.NAME LIKE 'Purge%' 
             OR w.NAME LIKE 'Archive%' OR w.NAME LIKE 'DBMonitor%'
             OR w.NAME LIKE 'DocumentNurs%' OR w.NAME LIKE 'Linkage%' THEN 'Housekeeping'
        WHEN w.NAME LIKE 'CEB\_%' ESCAPE '\' THEN 'CEB_*'
        WHEN w.NAME LIKE 'YFS\_%' ESCAPE '\' THEN 'YFS_*'
        WHEN w.NAME LIKE 'FG\_%' ESCAPE '\' OR w.NAME LIKE 'AFT\_%' ESCAPE '\' THEN 'File Gateway'
        WHEN w.NAME LIKE 'EDIINT%' OR w.NAME LIKE 'AS2%' OR w.NAME LIKE 'AS3%' THEN 'EDIINT/AS2/AS3'
        WHEN w.NAME LIKE 'MBX\_%' ESCAPE '\' OR w.NAME LIKE 'Mailbox%' THEN 'Mailbox'
        WHEN w.NAME LIKE 'System%' THEN 'System_*'
        WHEN LEFT(w.NAME, 1) = '_' OR LEFT(w.NAME, 1) = '.' THEN 'Underscore/dot prefix'
        WHEN w.NAME IS NULL THEN '(WFD_ID not found in WFD)'
        ELSE 'OTHER'
    END AS family,
    COUNT(*) AS instance_count,
    COUNT(DISTINCT w.NAME) AS distinct_workflow_names
FROM all_instances i
LEFT JOIN WFD w ON i.WFD_ID = w.WFD_ID
GROUP BY 
    CASE
        WHEN w.NAME LIKE 'FA\_%' ESCAPE '\' THEN 'FA_*'
        WHEN w.NAME LIKE 'Schedule\_%' ESCAPE '\' THEN 'Schedule_*'
        WHEN w.NAME LIKE 'BPExpirator%' OR w.NAME LIKE 'Index%' OR w.NAME LIKE 'Purge%' 
             OR w.NAME LIKE 'Archive%' OR w.NAME LIKE 'DBMonitor%'
             OR w.NAME LIKE 'DocumentNurs%' OR w.NAME LIKE 'Linkage%' THEN 'Housekeeping'
        WHEN w.NAME LIKE 'CEB\_%' ESCAPE '\' THEN 'CEB_*'
        WHEN w.NAME LIKE 'YFS\_%' ESCAPE '\' THEN 'YFS_*'
        WHEN w.NAME LIKE 'FG\_%' ESCAPE '\' OR w.NAME LIKE 'AFT\_%' ESCAPE '\' THEN 'File Gateway'
        WHEN w.NAME LIKE 'EDIINT%' OR w.NAME LIKE 'AS2%' OR w.NAME LIKE 'AS3%' THEN 'EDIINT/AS2/AS3'
        WHEN w.NAME LIKE 'MBX\_%' ESCAPE '\' OR w.NAME LIKE 'Mailbox%' THEN 'Mailbox'
        WHEN w.NAME LIKE 'System%' THEN 'System_*'
        WHEN LEFT(w.NAME, 1) = '_' OR LEFT(w.NAME, 1) = '.' THEN 'Underscore/dot prefix'
        WHEN w.NAME IS NULL THEN '(WFD_ID not found in WFD)'
        ELSE 'OTHER'
    END
ORDER BY instance_count DESC;

-- ----------------------------------------------------------------------------
-- 3.6 Active vs dormant: which WFDs have instances in last 48hr vs none?
--     Expected: most WFDs are dormant (only a subset is actively scheduled)
-- ----------------------------------------------------------------------------
WITH active_wfds AS (
    SELECT DISTINCT WFD_ID FROM WF_INST_S WHERE START_TIME >= DATEADD(HOUR, -48, GETDATE())
    UNION
    SELECT DISTINCT WFD_ID FROM WF_INST_S_RESTORE WHERE START_TIME >= DATEADD(HOUR, -48, GETDATE())
)
SELECT
    CASE WHEN aw.WFD_ID IS NOT NULL THEN 'ACTIVE (ran in last 48h)' ELSE 'DORMANT (no activity)' END AS status,
    COUNT(*) AS wfd_count
FROM WFD w
LEFT JOIN active_wfds aw ON w.WFD_ID = aw.WFD_ID
GROUP BY CASE WHEN aw.WFD_ID IS NOT NULL THEN 'ACTIVE (ran in last 48h)' ELSE 'DORMANT (no activity)' END;

-- ----------------------------------------------------------------------------
-- STEP 3 CORRECTIONS
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- Precheck: confirm WF_INST_S has a WFD_VERSION column
-- ----------------------------------------------------------------------------
SELECT
    c.name AS column_name,
    t.name AS data_type,
    c.is_nullable,
    c.column_id
FROM sys.columns c
INNER JOIN sys.types t ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID('WF_INST_S')
ORDER BY c.column_id;

-- ----------------------------------------------------------------------------
-- 3.3 (corrected) Distinct workflow NAMES by family (not WFD rows)
-- ----------------------------------------------------------------------------
WITH distinct_workflows AS (
    SELECT DISTINCT NAME FROM WFD
)
SELECT
    CASE
        WHEN NAME LIKE 'FA\_%' ESCAPE '\' THEN 'FA_*'
        WHEN NAME LIKE 'Schedule\_%' ESCAPE '\' THEN 'Schedule_*'
        WHEN NAME LIKE 'BPExpirator%' OR NAME LIKE 'Index%' OR NAME LIKE 'Purge%' 
             OR NAME LIKE 'Archive%' OR NAME LIKE 'DBMonitor%'
             OR NAME LIKE 'DocumentNurs%' OR NAME LIKE 'Linkage%' THEN 'Housekeeping'
        WHEN NAME LIKE 'CEB\_%' ESCAPE '\' THEN 'CEB_*'
        WHEN NAME LIKE 'YFS\_%' ESCAPE '\' THEN 'YFS_*'
        WHEN NAME LIKE 'FG\_%' ESCAPE '\' OR NAME LIKE 'AFT\_%' ESCAPE '\' THEN 'File Gateway'
        WHEN NAME LIKE 'EDIINT%' OR NAME LIKE 'AS2%' OR NAME LIKE 'AS3%' THEN 'EDIINT/AS2/AS3'
        WHEN NAME LIKE 'MBX\_%' ESCAPE '\' OR NAME LIKE 'Mailbox%' THEN 'Mailbox'
        WHEN NAME LIKE 'System%' THEN 'System_*'
        WHEN LEFT(NAME, 1) = '_' OR LEFT(NAME, 1) = '.' THEN 'Underscore/dot prefix'
        ELSE 'OTHER'
    END AS family,
    COUNT(*) AS distinct_workflow_count
FROM distinct_workflows
GROUP BY
    CASE
        WHEN NAME LIKE 'FA\_%' ESCAPE '\' THEN 'FA_*'
        WHEN NAME LIKE 'Schedule\_%' ESCAPE '\' THEN 'Schedule_*'
        WHEN NAME LIKE 'BPExpirator%' OR NAME LIKE 'Index%' OR NAME LIKE 'Purge%' 
             OR NAME LIKE 'Archive%' OR NAME LIKE 'DBMonitor%'
             OR NAME LIKE 'DocumentNurs%' OR NAME LIKE 'Linkage%' THEN 'Housekeeping'
        WHEN NAME LIKE 'CEB\_%' ESCAPE '\' THEN 'CEB_*'
        WHEN NAME LIKE 'YFS\_%' ESCAPE '\' THEN 'YFS_*'
        WHEN NAME LIKE 'FG\_%' ESCAPE '\' OR NAME LIKE 'AFT\_%' ESCAPE '\' THEN 'File Gateway'
        WHEN NAME LIKE 'EDIINT%' OR NAME LIKE 'AS2%' OR NAME LIKE 'AS3%' THEN 'EDIINT/AS2/AS3'
        WHEN NAME LIKE 'MBX\_%' ESCAPE '\' OR NAME LIKE 'Mailbox%' THEN 'Mailbox'
        WHEN NAME LIKE 'System%' THEN 'System_*'
        WHEN LEFT(NAME, 1) = '_' OR LEFT(NAME, 1) = '.' THEN 'Underscore/dot prefix'
        ELSE 'OTHER'
    END
ORDER BY distinct_workflow_count DESC;

-- ----------------------------------------------------------------------------
-- 3.4 (corrected) Instance counts per workflow NAME in last 48 hours
--     Strategy: use DISTINCT NAME via a lookup subquery to avoid any
--               WFD_VERSION-related multiplication regardless of whether
--               WF_INST_S has WFD_VERSION
-- ----------------------------------------------------------------------------
WITH all_instances AS (
    SELECT WFD_ID, WORKFLOW_ID, START_TIME
    FROM WF_INST_S
    WHERE START_TIME >= DATEADD(HOUR, -48, GETDATE())
    UNION ALL
    SELECT WFD_ID, WORKFLOW_ID, START_TIME
    FROM WF_INST_S_RESTORE
    WHERE START_TIME >= DATEADD(HOUR, -48, GETDATE())
),
wfd_names AS (
    -- One row per WFD_ID, picking any NAME (all versions share the same NAME)
    SELECT WFD_ID, MIN(NAME) AS NAME
    FROM WFD
    GROUP BY WFD_ID
)
SELECT
    n.NAME AS workflow_name,
    i.WFD_ID,
    COUNT(*) AS instance_count,
    MIN(i.START_TIME) AS oldest,
    MAX(i.START_TIME) AS newest
FROM all_instances i
LEFT JOIN wfd_names n ON i.WFD_ID = n.WFD_ID
GROUP BY n.NAME, i.WFD_ID
ORDER BY instance_count DESC;

-- ----------------------------------------------------------------------------
-- 3.5 (corrected) Same instance rollup but grouped by family
-- ----------------------------------------------------------------------------
WITH all_instances AS (
    SELECT WFD_ID, WORKFLOW_ID, START_TIME
    FROM WF_INST_S
    WHERE START_TIME >= DATEADD(HOUR, -48, GETDATE())
    UNION ALL
    SELECT WFD_ID, WORKFLOW_ID, START_TIME
    FROM WF_INST_S_RESTORE
    WHERE START_TIME >= DATEADD(HOUR, -48, GETDATE())
),
wfd_names AS (
    SELECT WFD_ID, MIN(NAME) AS NAME
    FROM WFD
    GROUP BY WFD_ID
)
SELECT
    CASE
        WHEN n.NAME LIKE 'FA\_%' ESCAPE '\' THEN 'FA_*'
        WHEN n.NAME LIKE 'Schedule\_%' ESCAPE '\' THEN 'Schedule_*'
        WHEN n.NAME LIKE 'BPExpirator%' OR n.NAME LIKE 'Index%' OR n.NAME LIKE 'Purge%' 
             OR n.NAME LIKE 'Archive%' OR n.NAME LIKE 'DBMonitor%'
             OR n.NAME LIKE 'DocumentNurs%' OR n.NAME LIKE 'Linkage%' THEN 'Housekeeping'
        WHEN n.NAME LIKE 'CEB\_%' ESCAPE '\' THEN 'CEB_*'
        WHEN n.NAME LIKE 'YFS\_%' ESCAPE '\' THEN 'YFS_*'
        WHEN n.NAME LIKE 'FG\_%' ESCAPE '\' OR n.NAME LIKE 'AFT\_%' ESCAPE '\' THEN 'File Gateway'
        WHEN n.NAME LIKE 'EDIINT%' OR n.NAME LIKE 'AS2%' OR n.NAME LIKE 'AS3%' THEN 'EDIINT/AS2/AS3'
        WHEN n.NAME LIKE 'MBX\_%' ESCAPE '\' OR n.NAME LIKE 'Mailbox%' THEN 'Mailbox'
        WHEN n.NAME LIKE 'System%' THEN 'System_*'
        WHEN LEFT(n.NAME, 1) = '_' OR LEFT(n.NAME, 1) = '.' THEN 'Underscore/dot prefix'
        WHEN n.NAME IS NULL THEN '(WFD_ID not found in WFD)'
        ELSE 'OTHER'
    END AS family,
    COUNT(*) AS instance_count,
    COUNT(DISTINCT n.NAME) AS distinct_workflow_names
FROM all_instances i
LEFT JOIN wfd_names n ON i.WFD_ID = n.WFD_ID
GROUP BY 
    CASE
        WHEN n.NAME LIKE 'FA\_%' ESCAPE '\' THEN 'FA_*'
        WHEN n.NAME LIKE 'Schedule\_%' ESCAPE '\' THEN 'Schedule_*'
        WHEN n.NAME LIKE 'BPExpirator%' OR n.NAME LIKE 'Index%' OR n.NAME LIKE 'Purge%' 
             OR n.NAME LIKE 'Archive%' OR n.NAME LIKE 'DBMonitor%'
             OR n.NAME LIKE 'DocumentNurs%' OR n.NAME LIKE 'Linkage%' THEN 'Housekeeping'
        WHEN n.NAME LIKE 'CEB\_%' ESCAPE '\' THEN 'CEB_*'
        WHEN n.NAME LIKE 'YFS\_%' ESCAPE '\' THEN 'YFS_*'
        WHEN n.NAME LIKE 'FG\_%' ESCAPE '\' OR n.NAME LIKE 'AFT\_%' ESCAPE '\' THEN 'File Gateway'
        WHEN n.NAME LIKE 'EDIINT%' OR n.NAME LIKE 'AS2%' OR n.NAME LIKE 'AS3%' THEN 'EDIINT/AS2/AS3'
        WHEN n.NAME LIKE 'MBX\_%' ESCAPE '\' OR n.NAME LIKE 'Mailbox%' THEN 'Mailbox'
        WHEN n.NAME LIKE 'System%' THEN 'System_*'
        WHEN LEFT(n.NAME, 1) = '_' OR LEFT(n.NAME, 1) = '.' THEN 'Underscore/dot prefix'
        WHEN n.NAME IS NULL THEN '(WFD_ID not found in WFD)'
        ELSE 'OTHER'
    END
ORDER BY instance_count DESC;
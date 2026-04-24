/*
================================================================================
Step 6A — Active Workflow Catalog
================================================================================
Purpose : Produce a complete catalog of every workflow definition in b2bi,
          classified by family, suffix, and direction, with 48h / 7d / 30d
          instance counts across WF_INST_S (live) + WF_INST_S_RESTORE.

          This is the "universe" for subsequent BPML extraction in Step 6B.

Target  : b2bi database (FA-INT-DBP), read-only
Runtime : estimated <5 seconds; light aggregations, no blob decompression
Output  : one row per distinct WFD NAME (latest version), ~1,433 rows expected

Notes:
- WFD is keyed on (WFD_ID, WFD_VERSION); every workflow edit increments version.
  CTE wfd_latest collapses to one row per WFD_ID using the max WFD_VERSION.
  Joins from activity tables use (WFD_ID, WFD_VERSION) to respect the
  composite PK, then we dedupe at NAME level on output.
- Activity is the UNION ALL of WF_INST_S + WF_INST_S_RESTORE across the 30-day
  combined retention horizon. 48h and 7d windows are subsets of live only.
- Family classification is pattern-based from NAME. Any name not matching a
  known pattern falls into 'OTHER'. Sterling-native workflows (FileGateway*,
  TimeoutEvent, Alert, Schedule_*, etc.) are intentionally included per the
  Step 6A scope decision — we catalog everything that runs.
- STATUS / STATE / TYPE columns are captured raw without interpretation.
  Steps 6C-6E will verify what their values mean.
================================================================================
*/

WITH wfd_latest AS (
    -- Collapse WFD to one row per WFD_ID using the latest WFD_VERSION
    SELECT
        w.WFD_ID,
        w.WFD_VERSION  AS latest_WFD_VERSION,
        w.NAME,
        w.DESCRIPTION,
        w.EDITED_BY,
        w.STATUS       AS wfd_status,
        w.TYPE         AS wfd_type,
        w.MOD_DATE,
        w.PERSISTENCE_LEVEL,
        w.RECOVERY_LEVEL,
        w.ONFAULT,
        w.DOCTRACKING,
        w.EVENT_LEVEL,
        w.CATEGORY,
        w.ENCODING,
        w.LIFE_SPAN,
        w.REMOVAL_METHOD
    FROM b2bi.dbo.WFD w
    INNER JOIN (
        SELECT WFD_ID, MAX(WFD_VERSION) AS max_version
        FROM b2bi.dbo.WFD
        GROUP BY WFD_ID
    ) latest
      ON latest.WFD_ID = w.WFD_ID
     AND latest.max_version = w.WFD_VERSION
),
wfd_version_counts AS (
    -- Count of versions ever saved per WFD_ID (indicates edit frequency)
    SELECT WFD_ID, COUNT(*) AS version_count
    FROM b2bi.dbo.WFD
    GROUP BY WFD_ID
),
activity_live AS (
    -- Live workflow instance activity (~7 days per Step 2)
    SELECT
        WFD_ID,
        WFD_VERSION,
        WORKFLOW_ID,
        START_TIME,
        END_TIME,
        STATUS,
        STATE,
        NODEEXECUTED,
        CAST(1 AS BIT) AS is_live
    FROM b2bi.dbo.WF_INST_S
    WHERE START_TIME >= DATEADD(DAY, -30, GETDATE())
),
activity_restore AS (
    -- Archived workflow instance activity (~22 days per Step 2)
    SELECT
        WFD_ID,
        WFD_VERSION,
        WORKFLOW_ID,
        START_TIME,
        END_TIME,
        STATUS,
        STATE,
        NODEEXECUTED,
        CAST(0 AS BIT) AS is_live
    FROM b2bi.dbo.WF_INST_S_RESTORE
    WHERE START_TIME >= DATEADD(DAY, -30, GETDATE())
),
activity_combined AS (
    SELECT * FROM activity_live
    UNION ALL
    SELECT * FROM activity_restore
),
activity_per_wfd_id AS (
    -- Aggregate to per-WFD_ID regardless of which version of the WFD was running.
    -- (A long-lived workflow has many WFD_VERSIONs but the same WFD_ID — the
    -- user experience is the same workflow name across versions.)
    SELECT
        WFD_ID,
        COUNT(*) AS instances_30d,
        SUM(CASE WHEN is_live = 1 THEN 1 ELSE 0 END) AS instances_live,
        SUM(CASE WHEN is_live = 0 THEN 1 ELSE 0 END) AS instances_restore,
        SUM(CASE WHEN START_TIME >= DATEADD(DAY, -7,  GETDATE()) THEN 1 ELSE 0 END) AS instances_7d,
        SUM(CASE WHEN START_TIME >= DATEADD(HOUR, -48, GETDATE()) THEN 1 ELSE 0 END) AS instances_48h,
        SUM(CASE WHEN STATUS = 0 THEN 1 ELSE 0 END) AS runs_status_0,
        SUM(CASE WHEN STATUS = 1 THEN 1 ELSE 0 END) AS runs_status_1,
        SUM(CASE WHEN STATUS NOT IN (0, 1) THEN 1 ELSE 0 END) AS runs_status_other,
        COUNT(DISTINCT WFD_VERSION) AS distinct_versions_seen_running,
        COUNT(DISTINCT NODEEXECUTED) AS distinct_nodes_seen,
        MIN(START_TIME) AS earliest_start_30d,
        MAX(START_TIME) AS latest_start_30d,
        AVG(DATEDIFF(SECOND, START_TIME, END_TIME) * 1.0) AS avg_duration_seconds,
        MAX(DATEDIFF(SECOND, START_TIME, END_TIME))       AS max_duration_seconds
    FROM activity_combined
    GROUP BY WFD_ID
)
SELECT
    -- Identity
    wl.WFD_ID,
    wl.NAME,
    wl.latest_WFD_VERSION,
    vc.version_count,
    wl.MOD_DATE                                                      AS latest_version_mod_date,
    wl.EDITED_BY                                                     AS latest_version_edited_by,
    wl.DESCRIPTION,

    -- Family classification (pattern-based on NAME)
    CASE
        WHEN wl.NAME LIKE 'FA\_CLIENTS\_%' ESCAPE '\'        THEN 'FA_CLIENTS'
        WHEN wl.NAME LIKE 'FA\_FROM\_%'    ESCAPE '\'        THEN 'FA_FROM'
        WHEN wl.NAME LIKE 'FA\_TO\_%'      ESCAPE '\'        THEN 'FA_TO'
        WHEN wl.NAME LIKE 'FA\_DM\_%'      ESCAPE '\'        THEN 'FA_DM'
        WHEN wl.NAME LIKE 'FA\_B2B\_%'     ESCAPE '\'        THEN 'FA_B2B'
        WHEN wl.NAME LIKE 'FA\_INTEGRATION\_%' ESCAPE '\'    THEN 'FA_INTEGRATION'
        WHEN wl.NAME LIKE 'FA\_CUSTOM\_%'  ESCAPE '\'        THEN 'FA_CUSTOM'
        WHEN wl.NAME LIKE 'FA\_CLA\_%'     ESCAPE '\'        THEN 'FA_CLA'
        WHEN wl.NAME LIKE 'FA\_%'          ESCAPE '\'        THEN 'FA_OTHER'
        WHEN wl.NAME LIKE 'Schedule\_%'    ESCAPE '\'        THEN 'Schedule'
        WHEN wl.NAME LIKE 'FileGateway%'                     THEN 'FileGateway'
        WHEN wl.NAME LIKE 'Mailbox%'                         THEN 'Mailbox'
        WHEN wl.NAME IN ('AS2Send','AS2Receive')             THEN 'AS2'
        WHEN wl.NAME LIKE 'AS3%'                             THEN 'AS3'
        WHEN wl.NAME LIKE 'EDIINT%'                          THEN 'EDIINT'
        WHEN wl.NAME IN (
            'TimeoutEvent','Alert','AlertNotification',
            'EmailOnError','Recover.bpml'
        )                                                     THEN 'Sterling_Infra'
        WHEN wl.NAME LIKE 'Check%'                           THEN 'Sterling_Infra'
        WHEN wl.NAME LIKE 'Housekeep%'                       THEN 'Housekeeping'
        WHEN wl.NAME LIKE 'AFT%'                             THEN 'AFT'
        WHEN wl.NAME LIKE 'FILE\_REMOVE\_%' ESCAPE '\'       THEN 'FILE_REMOVE'
        ELSE 'OTHER'
    END AS family,

    -- Suffix code extraction for FA_FROM / FA_TO workflows.
    -- Strategy: strip the FA_FROM_ or FA_TO_ prefix, then extract the
    -- final _XX token. Only attempts this for FA_FROM/FA_TO families.
    CASE
        WHEN wl.NAME LIKE 'FA\_FROM\_%' ESCAPE '\' OR wl.NAME LIKE 'FA\_TO\_%' ESCAPE '\'
        THEN REVERSE(LEFT(REVERSE(wl.NAME),
                          CHARINDEX('_', REVERSE(wl.NAME) + '_') - 1))
        ELSE NULL
    END AS suffix_code,

    -- Direction inference from family
    CASE
        WHEN wl.NAME LIKE 'FA\_FROM\_%' ESCAPE '\' THEN 'inbound'
        WHEN wl.NAME LIKE 'FA\_TO\_%'   ESCAPE '\' THEN 'outbound'
        ELSE NULL
    END AS direction,

    -- Activity metrics
    COALESCE(a.instances_30d,     0) AS instances_30d,
    COALESCE(a.instances_7d,      0) AS instances_7d,
    COALESCE(a.instances_48h,     0) AS instances_48h,
    COALESCE(a.instances_live,    0) AS instances_live,
    COALESCE(a.instances_restore, 0) AS instances_restore,
    COALESCE(a.runs_status_0,     0) AS runs_status_0,
    COALESCE(a.runs_status_1,     0) AS runs_status_1,
    COALESCE(a.runs_status_other, 0) AS runs_status_other,
    CAST(CASE WHEN COALESCE(a.instances_30d, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS is_active_30d,
    a.distinct_versions_seen_running,
    a.distinct_nodes_seen,
    a.earliest_start_30d,
    a.latest_start_30d,
    a.avg_duration_seconds,
    a.max_duration_seconds,

    -- Velocity tier (Step 3 definitions, per-30d instead of per-48h)
    CASE
        WHEN COALESCE(a.instances_30d, 0) = 0        THEN 'Dormant'
        WHEN COALESCE(a.instances_30d, 0) >= 10000   THEN 'Tier 1 (high-volume sub-workflow)'
        WHEN COALESCE(a.instances_30d, 0) >= 1000    THEN 'Tier 2 (infrastructure/dispatcher)'
        WHEN COALESCE(a.instances_30d, 0) >= 100     THEN 'Tier 3 (scheduled puller/pusher)'
        ELSE                                              'Tier 4 (daily/weekly)'
    END AS velocity_tier,

    -- WFD metadata — raw, uninterpreted
    wl.wfd_status,
    wl.wfd_type,
    wl.PERSISTENCE_LEVEL,
    wl.RECOVERY_LEVEL,
    wl.ONFAULT,
    wl.DOCTRACKING,
    wl.EVENT_LEVEL,
    wl.CATEGORY,
    wl.ENCODING,
    wl.LIFE_SPAN,
    wl.REMOVAL_METHOD

FROM wfd_latest wl
LEFT JOIN wfd_version_counts vc
       ON vc.WFD_ID = wl.WFD_ID
LEFT JOIN activity_per_wfd_id a
       ON a.WFD_ID = wl.WFD_ID
ORDER BY
    CASE WHEN COALESCE(a.instances_30d, 0) > 0 THEN 0 ELSE 1 END,  -- active first
    COALESCE(a.instances_30d, 0) DESC,
    wl.NAME;
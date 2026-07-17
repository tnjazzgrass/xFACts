/* ============================================================================
   Step 08 -- Fault Report Content: where does the full report live?
   Read-only, no writes anywhere. Sections 1-4 run against b2bi (FA-INT-DBP);
   Section 5 runs against the xFACts database (AG listener). Step through.

   Background (run 8608465, FA_CLIENTS_MAIN, 2026-07-16 10:14):
     Step 60  Translation                          SUCCESS  RPT 93062152  CONTENT 93062153
     Step 62  BPExceptionService                   ERROR    RPT NULL      CONTENT NULL
     Step 63  InlineInvokeBusinessProcessService   ERROR    RPT 93062195  CONTENT 93062204
   The map succeeded with a warning-bearing report; the BPML raised the
   exception. The collector's error-step filter therefore captures step 63's
   STATUS_RPT (a one-line MESSAGE), while the full Translation Report lives
   on the successful step 60's STATUS_RPT and embedded as <StatusReport>
   CDATA inside step 63's CONTENT (per Melissa's Instance Data path).
   ============================================================================ */

/* ============================================================================
   SECTION 1 -- Resolve the four run-8608465 handles (run against b2bi)
   Where does each handle land (TRANS_DATA vs DATA_TABLE), how many pages,
   how many bytes, and what format (gzip vs Java-serialized vs other)?
   ============================================================================ */

WITH Handles (handle_role, handle) AS (
    SELECT 'Step 60 Translation STATUS_RPT (success)', 'FA-INT-APPP:node1:19ec26870bc:93062152' UNION ALL
    SELECT 'Step 60 Translation CONTENT (success)',    'FA-INT-APPP:node1:19ec26870bc:93062153' UNION ALL
    SELECT 'Step 63 InlineInvoke STATUS_RPT (error)',  'FA-INT-APPP:node1:19ec26870bc:93062195' UNION ALL
    SELECT 'Step 63 InlineInvoke CONTENT (error)',     'FA-INT-APPP:node1:19ec26870bc:93062204'
)
SELECT h.handle_role,
       'TRANS_DATA' AS blob_table,
       td.PAGE_INDEX,
       DATALENGTH(td.DATA_OBJECT) AS byte_length,
       CASE
           WHEN SUBSTRING(td.DATA_OBJECT, 1, 2) = 0x1F8B THEN 'GZIP'
           WHEN SUBSTRING(td.DATA_OBJECT, 1, 2) = 0xACED THEN 'JAVA_SERIALIZED'
           ELSE 'OTHER: ' + CONVERT(VARCHAR(12), SUBSTRING(td.DATA_OBJECT, 1, 4), 1)
       END AS blob_format
FROM Handles h
INNER JOIN dbo.TRANS_DATA td WITH (NOLOCK)
        ON td.DATA_ID = h.handle
ORDER BY h.handle_role, td.PAGE_INDEX;

-- Fallback: any of the four handles landing in DATA_TABLE instead.
WITH Handles (handle_role, handle) AS (
    SELECT 'Step 60 Translation STATUS_RPT (success)', 'FA-INT-APPP:node1:19ec26870bc:93062152' UNION ALL
    SELECT 'Step 60 Translation CONTENT (success)',    'FA-INT-APPP:node1:19ec26870bc:93062153' UNION ALL
    SELECT 'Step 63 InlineInvoke STATUS_RPT (error)',  'FA-INT-APPP:node1:19ec26870bc:93062195' UNION ALL
    SELECT 'Step 63 InlineInvoke CONTENT (error)',     'FA-INT-APPP:node1:19ec26870bc:93062204'
)
SELECT h.handle_role,
       'DATA_TABLE' AS blob_table,
       DATALENGTH(dt.DATA_OBJECT) AS byte_length,
       CASE
           WHEN SUBSTRING(dt.DATA_OBJECT, 1, 2) = 0x1F8B THEN 'GZIP'
           WHEN SUBSTRING(dt.DATA_OBJECT, 1, 2) = 0xACED THEN 'JAVA_SERIALIZED'
           ELSE 'OTHER: ' + CONVERT(VARCHAR(12), SUBSTRING(dt.DATA_OBJECT, 1, 4), 1)
       END AS blob_format
FROM Handles h
INNER JOIN dbo.DATA_TABLE dt WITH (NOLOCK)
        ON dt.DATA_ID = h.handle
ORDER BY h.handle_role;

/* ============================================================================
   SECTION 2 -- Pagination risk census (run against b2bi)
   The collector reads PAGE_INDEX = 0 only. Across the blobs referenced by
   recent error steps, how often does a handle carry more than one page?
   Split by handle kind (STATUS_RPT vs CONTENT).
   ============================================================================ */

WITH ErrHandles AS (
    SELECT STATUS_RPT AS handle, 'STATUS_RPT' AS handle_kind
    FROM dbo.WORKFLOW_CONTEXT WITH (NOLOCK)
    WHERE BASIC_STATUS <> 0
      AND STATUS_RPT IS NOT NULL
      AND START_TIME >= DATEADD(DAY, -2, GETDATE())
    UNION
    SELECT CONTENT, 'CONTENT'
    FROM dbo.WORKFLOW_CONTEXT WITH (NOLOCK)
    WHERE BASIC_STATUS <> 0
      AND CONTENT IS NOT NULL
      AND START_TIME >= DATEADD(DAY, -2, GETDATE())
)
SELECT eh.handle_kind,
       COUNT(DISTINCT eh.handle)                                            AS handles,
       COUNT(DISTINCT CASE WHEN td.PAGE_INDEX > 0 THEN eh.handle END)       AS multi_page_handles,
       MAX(td.PAGE_INDEX)                                                   AS max_page_index,
       MAX(DATALENGTH(td.DATA_OBJECT))                                      AS max_page_bytes
FROM ErrHandles eh
INNER JOIN dbo.TRANS_DATA td WITH (NOLOCK)
        ON td.DATA_ID = eh.handle
GROUP BY eh.handle_kind
ORDER BY eh.handle_kind;

/* ============================================================================
   SECTION 3 -- Error-step report/content coverage by service (run against b2bi)
   Tests "the error info is always on the System Inline Invoke BP Service
   step": which services error, and which of them carry a STATUS_RPT and/or
   a CONTENT handle when they do?
   ============================================================================ */

SELECT SERVICE_NAME,
       COUNT(*)                                                     AS error_steps,
       SUM(CASE WHEN STATUS_RPT IS NOT NULL THEN 1 ELSE 0 END)      AS with_status_rpt,
       SUM(CASE WHEN CONTENT IS NOT NULL THEN 1 ELSE 0 END)         AS with_content,
       SUM(CASE WHEN STATUS_RPT IS NOT NULL
                 AND CONTENT IS NOT NULL THEN 1 ELSE 0 END)         AS with_both,
       SUM(CASE WHEN STATUS_RPT IS NULL
                 AND CONTENT IS NULL THEN 1 ELSE 0 END)             AS with_neither
FROM dbo.WORKFLOW_CONTEXT WITH (NOLOCK)
WHERE BASIC_STATUS <> 0
  AND START_TIME >= DATEADD(DAY, -2, GETDATE())
GROUP BY SERVICE_NAME
ORDER BY COUNT(*) DESC;

/* ============================================================================
   SECTION 4 -- Per-run pattern census (run against b2bi)
   For each workflow with any error step in the window: does the run carry a
   report on an error step, a report on a SUCCESSFUL Translation step, and/or
   CONTENT on an error step? Sizes the two candidate capture paths.
   ============================================================================ */

WITH RunRollup AS (
    SELECT WORKFLOW_ID,
           MAX(CASE WHEN BASIC_STATUS <> 0 AND STATUS_RPT IS NOT NULL THEN 1 ELSE 0 END) AS err_step_rpt,
           MAX(CASE WHEN BASIC_STATUS <> 0 AND CONTENT IS NOT NULL THEN 1 ELSE 0 END)    AS err_step_content,
           MAX(CASE WHEN BASIC_STATUS = 0 AND SERVICE_NAME = 'Translation'
                     AND STATUS_RPT IS NOT NULL THEN 1 ELSE 0 END)                       AS ok_translation_rpt
    FROM dbo.WORKFLOW_CONTEXT WITH (NOLOCK)
    WHERE START_TIME >= DATEADD(DAY, -2, GETDATE())
    GROUP BY WORKFLOW_ID
    HAVING MAX(CASE WHEN BASIC_STATUS <> 0 THEN 1 ELSE 0 END) = 1
)
SELECT COUNT(*)                                                                   AS runs_with_error_steps,
       SUM(err_step_rpt)                                                          AS runs_err_step_has_report,
       SUM(err_step_content)                                                      AS runs_err_step_has_content,
       SUM(ok_translation_rpt)                                                    AS runs_have_ok_translation_report,
       SUM(CASE WHEN err_step_rpt = 0 AND ok_translation_rpt = 1 THEN 1 ELSE 0 END) AS runs_report_only_on_ok_translation,
       SUM(CASE WHEN err_step_rpt = 0 AND err_step_content = 0
                 AND ok_translation_rpt = 0 THEN 1 ELSE 0 END)                    AS runs_no_report_anywhere
FROM RunRollup;

/* ============================================================================
   SECTION 5 -- Recent MESSAGE captures (run against the xFACts database)
   The one-liner population Melissa flagged: what do the captured messages
   actually say, and which recent run_ids are still inside b2bi retention as
   probe candidates?
   ============================================================================ */

SELECT fr.run_id,
       fr.captured_dttm,
       LEFT(fr.raw_report_text, 200) AS message_head
FROM B2B.SI_FaultReport fr
WHERE fr.fault_report_type = 'MESSAGE'
  AND fr.captured_dttm >= DATEADD(DAY, -3, GETDATE())
ORDER BY fr.captured_dttm DESC;

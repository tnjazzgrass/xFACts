/* ============================================================================
   Object_Metadata Audit and Trim - Teams schema
   Target: dbo.Object_Metadata (xFACts on AVG-PROD-LSNR)
   Purpose: Correct Teams documentation content that predates the Send-TeamsAlert
            dedup rework, and align the color-defaulting notes with current code.
   Run in SSMS step by step. Each UPDATE is keyed by metadata_id (primary key).
   Verification SELECTs follow each batch. Nothing here is commented out.

   ----------------------------------------------------------------------------
   SUMMARY OF CHANGES
   ----------------------------------------------------------------------------
   Rows touched: 11  (11 UPDATE, 0 INSERT, 0 retire)

     Corrections (no longer match current code):        7
       - 890   AlertQueue.retry_count description
                 (pre-rework "new row inserts" -> set in place = attempt-1)
       - 1790  AlertQueue.data_flow
                 (entry path: PS via Send-TeamsAlert w/ dual dedup incl.
                  -CardJson; T-SQL via sp_QueueAlert; dropped the stale
                  "direct INSERT from Send-DiskHealthSummary" claim)
       - 1822  RequestLog.data_flow
                 (dedup performed by Send-TeamsAlert / T-SQL caller, not
                  "calling modules")
       - 1825  RequestLog.design_note "Deduplication Source"  (same reframe)
       - 1830  sp_QueueAlert.data_flow
                 (dropped stale caller list; noted PS uses Send-TeamsAlert)
       - 1832  sp_QueueAlert.relationship_note
                 (rich cards now via Send-TeamsAlert -CardJson, not direct INSERT)
       - 1874  RequestLog.query "Standard deduplication pattern" (description)
                 (framed as the T-SQL-path pattern)
     Approved clarifications (Q2 - color defaulting):   4
       - 885   AlertQueue.color description
       - 1798  AlertQueue.alert_category status_value CRITICAL
       - 1799  AlertQueue.alert_category status_value WARNING
       - 1800  AlertQueue.alert_category status_value INFO
                 (each: sp_QueueAlert category-maps color on the T-SQL path;
                  Send-TeamsAlert defaults every category to attention)

   Rows reviewed and left as-is (already conformant): all remaining Teams rows -
     category/module tags, WebhookConfig/WebhookSubscription content, remaining
     queries, status_values, trigger/routing notes, and the terse column
     descriptions not listed above.

   ----------------------------------------------------------------------------
   DECISIONS APPLIED (from first-pass report; Dirk approved 2026-07-22)
   ----------------------------------------------------------------------------
   Q1. The inline retry delay is a genuine fixed value (Process-TeamsAlertQueue.ps1
       hardcodes Start-Sleep -Seconds 2; the old configurable teams_retry_delay_
       minutes was removed 2026-02-21). Per the no-hardcoded-cadence exemption for
       real fixed values, "2-second delays" is KEPT verbatim in 1790.

   Q2. Color notes (885/1798/1799/1800) gain the Send-TeamsAlert clause: on the
       T-SQL path sp_QueueAlert maps color from the alert category when none is
       supplied; Send-TeamsAlert defaults every category to attention unless the
       caller passes a color.

   Q3. sp_QueueAlert has no current callers - not xFACts (the PS caller base
       migrated to Send-TeamsAlert 2026-04-28) and none known external (verified
       2026-07-22 via sys.sql_expression_dependencies, sys.sql_modules text
       search, and SQL Agent job steps). It was deliberately designed as a T-SQL
       entry surface for external, non-xFACts processes, so it is an available-
       but-unused API, NOT an orphan and NOT deprecated. The metadata documents
       it as that available T-SQL entry point; its fate is tracked as backlog
       B-108, not decided here.

   Q4/Q5. Doc-page-only decisions (arch Deduplication rewrite; "resets daily"
       softened). Applied in teams.html / teams-arch.html, not in this script.
   ============================================================================ */


/* ============================================================================
   SECTION 0 - BEFORE snapshot (optional; run to capture current text)
   ============================================================================ */
SELECT metadata_id, object_name, column_name, property_type, title,
       description, content, is_active
FROM dbo.Object_Metadata
WHERE schema_name = 'Teams'
  AND metadata_id IN (890, 1790, 885, 1798, 1799, 1800, 1830, 1832, 1822, 1825, 1874)
ORDER BY object_name, metadata_id;


/* ============================================================================
   SECTION 1 - AlertQueue (Table)
   ============================================================================ */

-- 890  retry_count description  (CORRECTION: pre-rework "new row inserts" ->
--       the processor sets retry_count in place = attempt - 1.)
UPDATE dbo.Object_Metadata
SET content = 'Number of retry attempts beyond the first delivery, set in place on the original row by Process-TeamsAlertQueue.ps1; 0 when the first attempt succeeds.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 890;

-- 1790  data_flow  (CORRECTION: PowerShell enters via the shared Send-TeamsAlert
--        function with dual dedup at queue time, including -CardJson for rich
--        layouts; T-SQL enters via sp_QueueAlert. Dropped the stale direct-INSERT
--        claim. The 2-second delay is kept per Q1.)
UPDATE dbo.Object_Metadata
SET content = 'PowerShell callers queue alerts through the shared Send-TeamsAlert function, which deduplicates before inserting: it skips the alert when RequestLog already shows a successful delivery for the same trigger_type/trigger_value, and its guarded insert also collapses a same-run burst of the same trigger to a single Pending row. T-SQL callers use Teams.sp_QueueAlert. Rich layouts are queued by passing pre-built Adaptive Card JSON in card_json (Send-TeamsAlert -CardJson). TR_Teams_AlertQueue_QueueDepth fires on INSERT, incrementing running_count in Orchestrator.ProcessRegistry to signal the orchestrator. Process-TeamsAlertQueue.ps1 claims Pending rows, joins through WebhookSubscription and WebhookConfig to find matching webhook URLs, delivers via HTTP POST, then updates status to Success or Failed and sets processed_dttm. Each webhook delivery attempt is also logged to Teams.RequestLog. Failed deliveries are retried inline up to a configurable maximum (teams_retry_max_attempts in GlobalConfig) with 2-second delays between attempts. Failed alerts that exhaust all retries can be manually resent from the Admin page Alert Failures card, which inserts a new Pending row with original_queue_id referencing the original failed alert. The resend follows the normal queue processing path - routing is re-resolved through WebhookSubscription at delivery time.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1790;

-- 885  color description  (Q2: color defaulting differs by path.)
UPDATE dbo.Object_Metadata
SET content = 'Adaptive Card accent color. On the T-SQL path sp_QueueAlert sets it from the alert category when not supplied; Send-TeamsAlert defaults it to attention unless the caller passes a color.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 885;

-- 1798  alert_category status_value CRITICAL  (Q2)
UPDATE dbo.Object_Metadata
SET content = 'System failures, stalls, and urgent issues requiring immediate attention. On the T-SQL path sp_QueueAlert auto-colors this attention (red) when no explicit color is given; Send-TeamsAlert defaults every category to attention unless the caller passes a color.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1798;

-- 1799  alert_category status_value WARNING  (Q2)
UPDATE dbo.Object_Metadata
SET content = 'Potential issues, thresholds approaching, and items needing review. On the T-SQL path sp_QueueAlert auto-colors this warning (yellow) when no explicit color is given; Send-TeamsAlert defaults to attention unless the caller passes a color.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1799;

-- 1800  alert_category status_value INFO  (Q2)
UPDATE dbo.Object_Metadata
SET content = 'Informational messages, successful completions, and status updates. On the T-SQL path sp_QueueAlert auto-colors this good (green) when no explicit color is given; Send-TeamsAlert defaults to attention unless the caller passes a color.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1800;

-- Verify Section 1
SELECT metadata_id, column_name, property_type, title, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Teams' AND object_name = 'AlertQueue'
  AND metadata_id IN (890, 1790, 885, 1798, 1799, 1800)
ORDER BY metadata_id;


/* ============================================================================
   SECTION 2 - sp_QueueAlert (Procedure)
   ============================================================================ */

-- 1830  data_flow  (CORRECTION: dropped the stale caller list - Monitor-JobFlow
--        and Scan-SFTPFiles migrated to Send-TeamsAlert, and the sp_Backup_Monitor
--        call was removed. Framed as the T-SQL entry surface available to
--        external/in-database callers; xFACts PS scripts use Send-TeamsAlert.
--        Available-but-unused, not deprecated - see backlog B-108.)
UPDATE dbo.Object_Metadata
SET content = 'The T-SQL entry point for queuing a Teams alert, available to external or in-database callers: it inserts one row into Teams.AlertQueue with Pending status, applying default category-based coloring when no color is supplied. The INSERT fires TR_Teams_AlertQueue_QueueDepth, which signals the orchestrator to launch the processor. xFACts PowerShell scripts do not use this proc - they queue through the shared Send-TeamsAlert function - so it is an available entry surface rather than a deprecated one.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1830;

-- 1832  relationship_note Teams.AlertQueue  (CORRECTION: rich-card PowerShell
--        scripts now use Send-TeamsAlert -CardJson, not a direct INSERT.)
UPDATE dbo.Object_Metadata
SET content = 'Inserts directly into AlertQueue. This is the T-SQL entry point for queuing Teams alerts, available to external or in-database callers. xFACts PowerShell scripts queue through the shared Send-TeamsAlert function instead, including rich Adaptive Card layouts via its -CardJson parameter.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1832;

-- Verify Section 2
SELECT metadata_id, property_type, title, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Teams' AND object_name = 'sp_QueueAlert'
  AND metadata_id IN (1830, 1832)
ORDER BY metadata_id;


/* ============================================================================
   SECTION 3 - RequestLog (Table)
   ============================================================================ */

-- 1822  data_flow  (CORRECTION: cross-run dedup is performed by Send-TeamsAlert
--        for PS callers and by the T-SQL caller before sp_QueueAlert - not by
--        "calling modules" generically.)
UPDATE dbo.Object_Metadata
SET content = 'Process-TeamsAlertQueue.ps1 inserts one row per webhook delivery attempt, including retries. Each row captures the HTTP status_code and response_text from the webhook call. This table is the cross-run deduplication source: Send-TeamsAlert checks it (trigger_type and trigger_value with status_code = 200) before queuing a PowerShell-originated alert, and T-SQL callers perform the same check before sp_QueueAlert, so a condition already delivered is not re-sent across orchestrator cycles.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1822;

-- 1825  design_note "Deduplication Source"  (CORRECTION: same reframe - the
--        check is centralized in Send-TeamsAlert on the PS path.)
UPDATE dbo.Object_Metadata
SET content = 'Before an alert is queued, RequestLog is checked for an existing successful delivery (status_code = 200) with the same trigger_type and trigger_value. Send-TeamsAlert performs this check centrally for PowerShell callers; T-SQL callers perform it before sp_QueueAlert. This prevents duplicate notifications when the same condition is detected across multiple orchestrator cycles.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1825;

-- 1874  query "Standard deduplication pattern" (description)  (CORRECTION: this
--        caller-side NOT EXISTS + EXEC sp_QueueAlert example is the T-SQL-path
--        pattern; the PowerShell path performs the check inside Send-TeamsAlert.
--        Query body left unchanged - still valid for T-SQL callers.)
UPDATE dbo.Object_Metadata
SET description = 'Cross-run dedup check used on the T-SQL path before sp_QueueAlert; the PowerShell path performs this check inside Send-TeamsAlert.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1874;

-- Verify Section 3
SELECT metadata_id, property_type, title, description, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Teams' AND object_name = 'RequestLog'
  AND metadata_id IN (1822, 1825, 1874)
ORDER BY metadata_id;


/* ============================================================================
   SECTION 4 - Final verification (all touched rows in one result set)
   ============================================================================ */
SELECT metadata_id, object_name, column_name, property_type, sort_order,
       title, description, content, is_active, modified_dttm
FROM dbo.Object_Metadata
WHERE schema_name = 'Teams'
  AND metadata_id IN (890, 1790, 885, 1798, 1799, 1800, 1830, 1832, 1822, 1825, 1874)
ORDER BY object_name, property_type, sort_order, metadata_id;

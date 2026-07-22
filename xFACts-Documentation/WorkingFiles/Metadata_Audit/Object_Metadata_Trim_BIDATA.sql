/* ============================================================================
   Object_Metadata Audit and Trim - Pilot: BIDATA schema
   Target: dbo.Object_Metadata (xFACts on AVG-PROD-LSNR)
   Purpose: Streamline BIDATA documentation content and correct stale claims.
   Run in SSMS step by step. Each UPDATE is keyed by metadata_id (primary key).
   Verification SELECTs follow each batch. Nothing here is commented out.

   ----------------------------------------------------------------------------
   SUMMARY OF CHANGES
   ----------------------------------------------------------------------------
   Rows touched: 12  (11 UPDATE, 1 INSERT)

     Corrections (no longer match current code):        4
       - 1926  BuildExecution.data_flow    (sp_QueueAlert -> Send-TeamsAlert)
       - 1962  Monitor script.data_flow    (sp_QueueAlert -> Send-TeamsAlert)
       - 1971  Monitor script.relationship_note
                 (title + severities: ERROR/ERROR -> CRITICAL/WARNING)
       - 151   BuildExecution.notified_dttm (sent -> queued precision)
     Trims (verbosity, no factual change):              5
       - 34    BuildExecution object description
       - 140   BuildExecution.job_name (removed rationale -> see P1 below)
       - 1959  Monitor script object description
       - 38    StepExecution object description
       - 1946  StepExecution.data_flow
     Decisions folded in from the first-pass report:    3
       - R1a  1930  retire design_note "Historical Backfill Flag" (is_active=0)
       - R1b  152   is_backfill column desc rewritten to "reserved/unused"
       - P1   INSERT new BuildExecution design_note for job_name free text

   Rows reviewed and left as-is (already conformant): all remaining BIDATA
     rows - category/module tags, remaining design_notes, queries,
     status_values, and the terse column descriptions not listed above.

   ----------------------------------------------------------------------------
   DECISIONS APPLIED (from first-pass report; Dirk approved)
   ----------------------------------------------------------------------------
   R1. is_backfill is DEAD / inert relative to current code. Both INSERT paths
       in Monitor-BIDATABuild.ps1 hardcode is_backfill = 0 (lines ~620, ~779);
       no code sets it to 1, and neither the BIDATA API route nor
       bidata-monitoring.js reads or filters on it. Decision: retire
       design_note 1930 (soft delete, is_active = 0) and rewrite column
       description 152 to state the column is reserved/unused. No schema change.

   R2. relationship_note 1971 retitled Teams.sp_QueueAlert -> Send-TeamsAlert
       and severities corrected. The BIDATA monitor no longer calls that proc
       (only a changelog comment in Monitor-BIDATABuild.ps1 references the
       2026-04-28 switch to the shared Send-TeamsAlert, which queues into
       Teams.AlertQueue). Teams.sp_QueueAlert still EXISTS as a proc; it is
       simply no longer called from BIDATA.

   P1. job_name rationale ("supports multiple job name versions") was trimmed
       from column description 140 and promoted to a new BuildExecution
       design_note (INSERT below), per decision.
   ============================================================================ */


/* ============================================================================
   SECTION 0 - BEFORE snapshot (optional; run to capture current text)
   ============================================================================ */
SELECT metadata_id, object_name, column_name, property_type, title, content, is_active
FROM dbo.Object_Metadata
WHERE schema_name = 'BIDATA'
  AND metadata_id IN (1926, 1962, 1971, 151, 152, 1930, 34, 140, 1959, 38, 1946)
ORDER BY metadata_id;


/* ============================================================================
   SECTION 1 - BuildExecution (Table)
   ============================================================================ */

-- 1926  data_flow  (CORRECTION: notification now queued via Send-TeamsAlert;
--        dropped the unverifiable "every 5 minutes" interval - the schedule is
--        orchestrator-configurable; generalized the hardcoded source server.)
UPDATE dbo.Object_Metadata
SET content = 'Monitor-BIDATABuild.ps1 polls the configured source server''s msdb.dbo.sysjobhistory over a direct PowerShell connection and writes one row per execution attempt, keyed by instance_id. Status is set to IN_PROGRESS on first detection and updated to COMPLETED or FAILED when the job outcome row appears; a NOT_STARTED row is created when the build has not started within the configured grace period. notified_dttm is stamped after the Teams notification is queued via Send-TeamsAlert. The Control Center BIDATA Monitoring page reads this table for build status and duration display.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1926;

-- 34  object description  (TRIM: removed duplicated "tracking".)
UPDATE dbo.Object_Metadata
SET content = 'Primary tracking table for BIDATA Daily Build executions, holding per-attempt timing, status, and notification state.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 34;

-- 140  job_name column description  (TRIM: removed rationale clause - see P1.)
UPDATE dbo.Object_Metadata
SET content = 'SQL Agent job name.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 140;

-- 151  notified_dttm column description  (CORRECTION: value is stamped when the
--        notification is QUEUED, not when delivered.)
UPDATE dbo.Object_Metadata
SET content = 'When the Teams build notification was queued; NULL until notified.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 151;

-- 152  is_backfill column description  (R1b: column is reserved/unused.)
UPDATE dbo.Object_Metadata
SET content = 'Reserved and currently unused; always 0, with no code path that sets or reads it.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 152;

-- 1930  design_note "Historical Backfill Flag"  (R1a: retire via soft delete.)
UPDATE dbo.Object_Metadata
SET is_active = 0,
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1930;

-- P1  new BuildExecution design_note for the job_name free-text rationale.
--      Natural key: (BIDATA, BuildExecution, Table, '', design_note, 5).
--      Existing design_notes use sort_order 1-4; 5 is free and avoids any
--      collision with the slot vacated by the 1930 retire above.
INSERT INTO dbo.Object_Metadata (
    schema_name, object_name, object_type, column_name,
    property_type, sort_order, title, description, content, is_active
)
VALUES (
    'BIDATA', 'BuildExecution', 'Table', NULL,
    'design_note', 5, 'Job Name Stored as Free Text', NULL,
    'job_name is stored as free text because the SQL Agent job name has changed across design generations; Control Center history reflects all variants.',
    1
);

-- Verify Section 1
SELECT metadata_id, column_name, property_type, sort_order, title, content, is_active
FROM dbo.Object_Metadata
WHERE schema_name = 'BIDATA' AND object_name = 'BuildExecution'
  AND (metadata_id IN (1926, 34, 140, 151, 152, 1930)
       OR (property_type = 'design_note' AND sort_order = 5))
ORDER BY property_type, sort_order, metadata_id;


/* ============================================================================
   SECTION 2 - Monitor-BIDATABuild.ps1 (Script)
   ============================================================================ */

-- 1962  data_flow  (CORRECTION: calls shared Send-TeamsAlert, not
--        Teams.sp_QueueAlert; dropped "every 5 minutes"; generalized source
--        server.)
UPDATE dbo.Object_Metadata
SET content = 'Runs as a queue-driven orchestrator process. Reads configuration from dbo.GlobalConfig (job name, source server, grace period), then queries the configured source server''s msdb (sysjobhistory and schedule tables) over a direct PowerShell connection for job execution and schedule data. Creates and updates BIDATA.BuildExecution rows for build-level tracking and inserts BIDATA.StepExecution rows as steps complete. Calls the shared Send-TeamsAlert function to queue completion, failure, and NOT_STARTED notifications, using an instance_id-based TriggerValue for deduplication.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1962;

-- 1959  object description  (TRIM: 4 sentences -> 3; "sends" -> "queues".)
UPDATE dbo.Object_Metadata
SET content = 'Monitors the BIDATA Daily Build SQL Agent job over a direct connection to the source server, capturing build start, incremental step completions, and final status. Creates NOT_STARTED records when the build has not started within the configured grace period. Queues Teams notifications on completion, failure, and not-started conditions.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1959;

-- 1971  relationship_note  (CORRECTION: retitled Teams.sp_QueueAlert ->
--        Send-TeamsAlert; severities ERROR/ERROR -> CRITICAL/WARNING to match
--        the current Send-bid_BuildNotification mapping. See R2.)
UPDATE dbo.Object_Metadata
SET title = 'Send-TeamsAlert',
    content = 'Called through the local Send-bid_BuildNotification wrapper to queue notifications on build completion (INFO), failure (CRITICAL), and not-started conditions (WARNING). Passes BuildStatus as TriggerType with the instance_id or date in TriggerValue for deduplication.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1971;

-- Verify Section 2
SELECT metadata_id, property_type, title, content
FROM dbo.Object_Metadata
WHERE schema_name = 'BIDATA' AND object_name = 'Monitor-BIDATABuild.ps1'
  AND metadata_id IN (1962, 1959, 1971)
ORDER BY metadata_id;


/* ============================================================================
   SECTION 3 - StepExecution (Table)
   ============================================================================ */

-- 38  object description  (TRIM: removed downstream-usage clause "enabling
--        performance analysis and bottleneck identification".)
UPDATE dbo.Object_Metadata
SET content = 'Step-level execution detail for the BIDATA Daily Build, one row per SQL Agent job step per build attempt.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 38;

-- 1946  data_flow  (TRIM: generalized hardcoded source server; tightened.)
UPDATE dbo.Object_Metadata
SET content = 'Monitor-BIDATABuild.ps1 captures step completions incrementally from the source server''s msdb.dbo.sysjobhistory as each step finishes. Each row records the step name, duration, and run_status for one step of one build attempt. The Control Center BIDATA Monitoring page joins this table to BuildExecution for step-level progress and historical duration analysis.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1946;

-- Verify Section 3
SELECT metadata_id, column_name, property_type, content
FROM dbo.Object_Metadata
WHERE schema_name = 'BIDATA' AND object_name = 'StepExecution'
  AND metadata_id IN (38, 1946)
ORDER BY metadata_id;


/* ============================================================================
   SECTION 4 - Final verification (all touched rows in one result set)
   ============================================================================ */
-- Edited rows by metadata_id, plus the newly inserted job_name design_note.
SELECT metadata_id, object_name, column_name, property_type, sort_order,
       title, content, is_active, modified_dttm
FROM dbo.Object_Metadata
WHERE schema_name = 'BIDATA'
  AND (metadata_id IN (1926, 1962, 1971, 151, 152, 1930, 34, 140, 1959, 38, 1946)
       OR (object_name = 'BuildExecution' AND property_type = 'design_note'
           AND title = 'Job Name Stored as Free Text'))
ORDER BY object_name, property_type, sort_order, metadata_id;

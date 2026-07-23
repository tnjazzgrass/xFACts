/* ============================================================================
   Object_Metadata Audit and Trim - Module: ServerOps.DBCC component
   Target: dbo.Object_Metadata (xFACts on AVG-PROD-LSNR)
   Purpose: Streamline DBCC documentation content, correct stale claims, apply
            the enum-description rules (no value lists/glosses in a description;
            migrate stripped glosses into status_value rows), and resolve the
            two audit forks (CHECKTABLE/CHECKFILEGROUP; NO_WORK).
   Scope:   Component-scoped. Only the DBCC-component objects are touched:
              - DBCC_ExecutionLog   (Table)
              - DBCC_ScheduleConfig (Table)
              - Execute-DBCC.ps1    (Script)
   Run in SSMS step by step. Each statement is keyed by metadata_id (PK), except
   the status_value INSERTs (new rows). Verification SELECTs follow each section.
   Nothing here is commented out.

   ----------------------------------------------------------------------------
   RULES APPLIED (see Metadata_Audit_Rules.md for the full ruleset)
   ----------------------------------------------------------------------------
   R1  Column/object descriptions carry PURPOSE only - no value lists, no
       per-value glosses, no "see status values" pointer text. The status_value
       rows + CHECK constraint are the sole domain authority.
   R2  When stripping enum content, verify the column has status_value rows for
       those values; if missing, CREATE them from the stripped glosses (relocate,
       never destroy). DBCC_ScheduleConfig.check_mode and .replica_override had
       none - status_value INSERTs are in Section 2, verified against the live
       CHECK constraints CK_DBCC_ScheduleConfig_check_mode
       (NONE/PHYSICAL_ONLY/FULL) and CK_DBCC_ScheduleConfig_replica_override
       (NULL/PRIMARY/SECONDARY).
   Fresh-eyes trim: non-enum descriptions cut to one-sentence purpose - stripped
       "parsed from...", "useful for...", "avoids joins", downstream chains, and
       example names.

   ----------------------------------------------------------------------------
   FORK RESOLUTIONS
   ----------------------------------------------------------------------------
   Fork A (CHECKTABLE / CHECKFILEGROUP not implemented): soft-retire the two
     operation status_value rows (3576, 3577; is_active = 0), strip the operation
     enum lists to the four real operations via R1, and mark target_object (3569)
     reserved/unused. The live CHECK constraint still permits all six operations;
     the arch page carries a one-line reserved-capability note, and the retired
     rows remain (is_active = 0) so the domain history is not destroyed.
   Fork B (NO_WORK): the script does NOT emit NO_WORK - it reports SUCCESS with a
     "No operations due" output. design_note 3625 is corrected to match the code
     this pass. A backlog item (B-113, ServerOps.DBCC / Enhance / Low) tracks the
     optional code change to emit NO_WORK for parity with the Index scripts.
     NOTE: the Execute-DBCC.ps1 comment-based-help header (.DESCRIPTION) also
     says "exits NO_WORK" - that is a permanent-object edit, flagged in the
     report, not changed here.

   ----------------------------------------------------------------------------
   SUMMARY OF CHANGES
   ----------------------------------------------------------------------------
   Rows touched: 49 UPDATE + 5 INSERT (status_value migration) = 54

     DBCC_ExecutionLog ....... 36 UPDATE
       Enum-description strips (R1): 3539 status, 3567 operation, 3568 check_mode
       Corrections: 3543, 3586, 3582, 3535, 3537, 3531, 3547, 3549
       Trims (fresh-eyes): 3524, 3587, 3643, 3585, 3534, 3540, 3530, 3528, 3536,
         3632, 3538, 3542, 3634, 3635, 3636, 3637, 3638, 3639, 3640, 3641, 3642,
         3664
       Fork A: 3569 (target_object reserved/unused), 3576 + 3577 (soft-retire)
     DBCC_ScheduleConfig ..... 11 UPDATE + 5 INSERT
       Enum-description strips (R1) + migration: 3665 check_mode, 3663
         replica_override; INSERT status_values (check_mode NONE/PHYSICAL_ONLY/
         FULL; replica_override PRIMARY/SECONDARY)
       Trims: 3590, 3616, 3618, 3598, 3599, 3600, 3610, 3594, 3595
     Execute-DBCC.ps1 ........ 2 UPDATE
       3631 (correction: check_mode per-database), 3625 (Fork B: NO_WORK)
   ============================================================================ */


/* ============================================================================
   SECTION 0 - BEFORE snapshot (optional; run to capture current text)
   ============================================================================ */
SELECT metadata_id, object_name, column_name, property_type, sort_order, title, description, content, is_active
FROM dbo.Object_Metadata
WHERE schema_name = 'ServerOps'
  AND metadata_id IN (
        3524, 3543, 3586, 3587, 3643, 3585, 3582, 3539, 3567, 3568, 3534, 3540,
        3535, 3537, 3531, 3530, 3528, 3536, 3632, 3538, 3542, 3634, 3635, 3636,
        3637, 3638, 3639, 3640, 3641, 3642, 3664, 3569, 3547, 3549, 3576, 3577,
        3590, 3616, 3618, 3663, 3665, 3598, 3599, 3600, 3610, 3594, 3595,
        3631, 3625
      )
ORDER BY object_name, property_type, sort_order, metadata_id;


/* ============================================================================
   SECTION 1 - DBCC_ExecutionLog (Table)
   ============================================================================ */

-- ---- Object + design notes / data flow / relationships --------------------

-- 3524  object description  (TRIM: dropped the operation enum sentence - the
--        operation status_values are the domain authority.)
UPDATE dbo.Object_Metadata
SET content = 'Execution history for DBCC integrity operations. One row per database per operation per execution; a single script invocation processes databases sequentially and produces multiple rows grouped by run_id.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3524;

-- 3543  data_flow  (CORRECTION: a Jira ticket is queued only on CHECKDB
--        corruption, not on every non-SUCCESS; Teams fires on any non-SUCCESS.)
UPDATE dbo.Object_Metadata
SET content = 'Execute-DBCC.ps1 inserts a PENDING row at claim time, transitions to IN_PROGRESS with the resolved physical server at execution start, and updates with final status, duration, error details, and DBCC output metrics on completion. One row per database per operation per run, grouped by run_id. CHECKDB and CHECKALLOC populate allocation_errors, consistency_errors, repaired_errors, dbcc_elapsed_seconds, LSN values, and buffer pool scan metrics from the DBCC summary output. CHECKCONSTRAINTS stores an aggregated violation summary in error_details. The Control Center DBCC Operations page reads this table for live progress, execution history, and duration trending. A Teams alert is queued on any non-SUCCESS result; a Jira ticket is queued on CHECKDB corruption (ERRORS_FOUND).',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3543;

-- 3586  design_note #1 "Self-Documenting Options"  (CORRECTION + TRIM:
--        check_mode and operation come from the per-database schedule, not
--        GlobalConfig; trimmed the cross-reference rationale.)
UPDATE dbo.Object_Metadata
SET content = 'operation, check_mode, max_dop, and extended_logical_checks are captured on every row. operation and check_mode come from the per-database schedule (DBCC_ScheduleConfig); max_dop and extended_logical_checks come from GlobalConfig. Capturing them per row records exactly what options each execution used, even if the configuration changes between runs.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3586;

-- 3587  design_note #2 "AG Listener vs Physical Server"  (TRIM / no-naming:
--        removed the example server names.)
UPDATE dbo.Object_Metadata
SET content = 'server_name and server_id capture the ServerRegistry entry that triggered the run - the AG listener for AG databases. executed_on_server captures the physical server where DBCC actually ran - the resolved replica for AG databases. For non-AG servers both values are identical. The distinction matters for I/O contention analysis and troubleshooting.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3587;

-- 3643  design_note #4 "DBCC Output Metric Capture"  (TRIM: removed rationale
--        verbosity.)
UPDATE dbo.Object_Metadata
SET content = 'DBCC summary-output metrics are captured per row for historical trending. CHECKDB and CHECKALLOC populate the metric columns; CHECKCATALOG and CHECKCONSTRAINTS leave them NULL, since those operations produce different output. NULL means the metric does not apply to that operation type, not that it was missed. NO_INFOMSGS stays enabled to suppress per-object informational messages while still capturing the summary line the metrics are parsed from.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3643;

-- 3585  query #3 "CHECKDB duration trending"  (no-naming: genericized the named
--        database to a placeholder in both the hint and the SQL body.)
UPDATE dbo.Object_Metadata
SET description = 'Shows CHECKDB execution durations over time for a specific database. Useful for detecting drift in execution times.',
    content = 'SELECT
    started_dttm, duration_seconds,
    duration_seconds / 3600 AS duration_hours,
    check_mode, executed_on_server, status
FROM ServerOps.DBCC_ExecutionLog
WHERE operation = ''CHECKDB''
  AND database_name = ''<database_name>''
ORDER BY started_dttm DESC;',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3585;

-- 3582  relationship_note #3 "GlobalConfig"  (CORRECTION: check_mode is read per
--        database from the schedule table, not GlobalConfig.)
UPDATE dbo.Object_Metadata
SET content = 'Execution options (max_dop, extended_logical_checks, alerting_enabled) are read from dbo.GlobalConfig at script startup under module ServerOps, category DBCC. check_mode is read per database from DBCC_ScheduleConfig. Captured options are stored per row in the log for historical accuracy.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3582;

-- ---- Enum-column descriptions stripped to purpose (R1) ---------------------
-- These columns already have status_value rows covering their domain, so the
-- descriptions strip outright (no migration needed).

-- 3539  status  (R1: strip enum; the old text listed 4 values while 5 exist -
--        the exact rot R1 prevents. status_values PENDING/IN_PROGRESS/SUCCESS/
--        FAILED/ERRORS_FOUND are the authority.)
UPDATE dbo.Object_Metadata
SET content = 'Execution result.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3539;

-- 3567  operation  (R1: strip enum. Also drops the unbuilt CHECKTABLE/
--        CHECKFILEGROUP per Fork A.)
UPDATE dbo.Object_Metadata
SET content = 'Which DBCC command was executed.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3567;

-- 3568  check_mode  (R1: strip the PHYSICAL_ONLY/FULL glosses and operation
--        lists; status_values PHYSICAL_ONLY/FULL are the authority.)
UPDATE dbo.Object_Metadata
SET content = 'DBCC check mode used by CHECKDB; NULL for operations that have no check mode.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3568;

-- ---- Column-description corrections and trims ------------------------------

-- 3534  max_dop  (TRIM: dropped "captured per-row for historical accuracy".)
UPDATE dbo.Object_Metadata
SET content = 'MAXDOP value used for this execution.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3534;

-- 3540  error_count  (TRIM: dropped parse-source and the pre-calculated
--        rationale; kept the 0-for-FAILED semantics.)
UPDATE dbo.Object_Metadata
SET content = 'Number of errors reported by DBCC - the sum of allocation_errors and consistency_errors. 0 for SUCCESS, and 0 for FAILED (script-level errors produce no DBCC error count).',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3540;

-- 3535  extended_logical_checks  (CORRECTION: check_type -> check_mode.)
UPDATE dbo.Object_Metadata
SET content = 'Whether EXTENDED_LOGICAL_CHECKS was enabled for this execution. Only meaningful when check_mode is FULL.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3535;

-- 3537  completed_dttm  (CORRECTION: applies to every DBCC operation.)
UPDATE dbo.Object_Metadata
SET content = 'When the DBCC operation completed. NULL while still running.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3537;

-- 3531  executed_on_server  (CORRECTION: the resolved replica may be primary,
--        not only the secondary.)
UPDATE dbo.Object_Metadata
SET content = 'Physical server where DBCC actually ran. For AG databases, the resolved replica; for non-AG servers, matches server_name.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3531;

-- 3530  server_name  (no-naming: removed the example listener name.)
UPDATE dbo.Object_Metadata
SET content = 'Denormalized from ServerRegistry; the server_name of the entry that triggered the run (the listener for AG databases).',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3530;

-- 3528  run_id  (TRIM: dropped the MAX+1 implementation detail.)
UPDATE dbo.Object_Metadata
SET content = 'Groups all rows produced by one script invocation.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3528;

-- 3536  started_dttm  (TRIM: kept the NULL and duration semantics.)
UPDATE dbo.Object_Metadata
SET content = 'When the DBCC operation began executing; NULL while PENDING. Duration is measured from this timestamp, not queued_dttm.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3536;

-- 3632  queued_dttm  (TRIM.)
UPDATE dbo.Object_Metadata
SET content = 'When the operation was claimed and inserted as PENDING; its gap from started_dttm is time spent waiting in queue.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3632;

-- 3538  duration_seconds  (TRIM: dropped "at the PowerShell level".)
UPDATE dbo.Object_Metadata
SET content = 'Total elapsed seconds, measured around the DBCC command invocation.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3538;

-- 3542  executed_by  (TRIM.)
UPDATE dbo.Object_Metadata
SET content = 'Windows account that ran the script; defaults to SUSER_SNAME().',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3542;

-- 3634  allocation_errors  (TRIM: dropped parse-source, op list, downstream.)
UPDATE dbo.Object_Metadata
SET content = 'Number of allocation errors reported by DBCC; NULL when the operation does not report allocation errors.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3634;

-- 3635  consistency_errors  (TRIM.)
UPDATE dbo.Object_Metadata
SET content = 'Number of consistency errors reported by DBCC; NULL when the operation does not report consistency errors.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3635;

-- 3636  repaired_errors  (TRIM.)
UPDATE dbo.Object_Metadata
SET content = 'Number of errors DBCC repaired during execution; typically 0, NULL when the operation does not report a repair count.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3636;

-- 3637  dbcc_elapsed_seconds  (TRIM: kept the distinction from duration_seconds.)
UPDATE dbo.Object_Metadata
SET content = 'DBCC''s own reported elapsed time, distinct from duration_seconds; NULL when the operation does not report it.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3637;

-- 3638  split_point_lsn  (TRIM.)
UPDATE dbo.Object_Metadata
SET content = 'Internal database snapshot split-point LSN used by DBCC; NULL when the operation creates no internal snapshot.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3638;

-- 3639  first_lsn  (TRIM.)
UPDATE dbo.Object_Metadata
SET content = 'First LSN of the internal database snapshot DBCC used; NULL when the operation creates no internal snapshot.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3639;

-- 3640  buffer_pool_scan_seconds  (TRIM.)
UPDATE dbo.Object_Metadata
SET content = 'Duration in seconds of the buffer pool scan at the start of DBCC execution; NULL when the operation performs no buffer pool scan.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3640;

-- 3641  pages_scanned  (TRIM.)
UPDATE dbo.Object_Metadata
SET content = 'Number of database pages (buffers) DBCC scanned during the buffer pool scan phase; NULL when the operation reports no page count.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3641;

-- 3642  pages_iterated  (TRIM.)
UPDATE dbo.Object_Metadata
SET content = 'Total buffers iterated during the buffer pool scan phase; NULL when the operation reports no page count.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3642;

-- 3664  dbcc_summary_output  (TRIM: calibration exemplar; kept source + NULL.)
UPDATE dbo.Object_Metadata
SET content = 'Raw DBCC summary text captured from the SQL Server error log; the source the parsed metric columns are derived from. NULL when the operation produces no error-log summary or the error-log query fails.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3664;

-- 3569  target_object  (Fork A: reserved/unused - no current operation
--        populates it.)
UPDATE dbo.Object_Metadata
SET content = 'Reserved for object-scoped operations; unused today - no current operation populates it, so it is NULL on every row.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3569;

-- ---- status_value corrections (light) -------------------------------------

-- 3547  status_value SUCCESS  (CORRECTION: applies to all operations.)
UPDATE dbo.Object_Metadata
SET content = 'The DBCC operation completed with no errors reported. Integrity verified for the checked scope.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3547;

-- 3549  status_value ERRORS_FOUND  (CORRECTION: applies to all operations; a
--        Jira ticket is queued only for CHECKDB corruption.)
UPDATE dbo.Object_Metadata
SET content = 'The DBCC operation completed but reported problems - corruption for the integrity checks, or constraint violations for CHECKCONSTRAINTS. error_count has the total and error_details has the full output. A Teams alert is sent; CHECKDB corruption also queues a Jira ticket.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3549;

-- ---- Fork A: soft-retire the unbuilt operation status_values --------------

-- 3576  status_value operation CHECKTABLE  (soft delete.)
UPDATE dbo.Object_Metadata
SET is_active = 0, modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3576;

-- 3577  status_value operation CHECKFILEGROUP  (soft delete.)
UPDATE dbo.Object_Metadata
SET is_active = 0, modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3577;

-- Verify Section 1
SELECT metadata_id, column_name, property_type, sort_order, title, description, content, is_active
FROM dbo.Object_Metadata
WHERE schema_name = 'ServerOps' AND object_name = 'DBCC_ExecutionLog'
  AND metadata_id IN (3524, 3543, 3586, 3587, 3643, 3585, 3582, 3539, 3567, 3568,
                      3534, 3540, 3535, 3537, 3531, 3530, 3528, 3536, 3632, 3538,
                      3542, 3634, 3635, 3636, 3637, 3638, 3639, 3640, 3641, 3642,
                      3664, 3569, 3547, 3549, 3576, 3577)
ORDER BY property_type, sort_order, metadata_id;


/* ============================================================================
   SECTION 2 - DBCC_ScheduleConfig (Table)
   ============================================================================ */

-- 3590  object description  (TRIM: dropped the operation enum list and the
--        CHECKTABLE/CHECKFILEGROUP sentence.)
UPDATE dbo.Object_Metadata
SET content = 'Per-database scheduling configuration for DBCC integrity operations. One row per database with independent enabled/day/time settings per operation type. The row-level is_enabled flag combines with serverops_dbcc_enabled on ServerRegistry for two-tier control.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3590;

-- 3616  design_note #1 "Per-Database Granularity"  (TRIM: removed the size/day
--        example.)
UPDATE dbo.Object_Metadata
SET content = 'Each database gets its own schedule row with independent settings per operation. This allows staggering heavy operations like CHECKDB across different days while running lightweight operations together, so a large database''s full check and smaller databases'' checks need not share a window.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3616;

-- 3618  design_note #3 "Hour-Based Schedule Matching"  (TRIM: removed the fixed
--        time example.)
UPDATE dbo.Object_Metadata
SET content = 'The script matches the hour component of run_time against the current hour, so an operation becomes due once the script fires during its scheduled hour. Combined with the already-executed-today check on DBCC_ExecutionLog, this prevents duplicate execution when the script fires multiple times within the same hour.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3618;

-- 3665  check_mode  (R1: strip the NONE/PHYSICAL_ONLY/FULL glosses; the new
--        status_value rows below carry them. Kept purpose + default.)
UPDATE dbo.Object_Metadata
SET content = 'DBCC check mode used by CHECKDB scheduling; other operations ignore it. Defaults to NONE.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3665;

-- 3663  replica_override  (R1 + TRIM: removed the per-value PRIMARY/SECONDARY
--        glosses - now status_values below - and the use-case list; kept the
--        NULL/default routing including the load-bearing CHECKCATALOG exception,
--        and generalized the configurable source replica.)
UPDATE dbo.Object_Metadata
SET content = 'Per-database replica routing override for AG listener databases. NULL uses the default routing: the configured source replica (typically SECONDARY) for all operations except CHECKCATALOG, which always routes to PRIMARY. A non-null value pins this database''s operations to the chosen replica. Persists until manually cleared. Non-AG servers ignore this column.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3663;

-- ---- Column-description trims ----------------------------------------------

-- 3598  checkdb_enabled  (TRIM: dropped obvious BIT gloss and cross-ref.)
UPDATE dbo.Object_Metadata
SET content = 'Whether CHECKDB is scheduled for this database.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3598;

-- 3599  checkdb_run_day  (TRIM: kept the 1-7 encoding, dropped DATEPART note.)
UPDATE dbo.Object_Metadata
SET content = 'Day of week for CHECKDB execution (1=Sunday through 7=Saturday). NULL when disabled.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3599;

-- 3600  checkdb_run_time  (TRIM: hour-match behavior lives in design_note #3.)
UPDATE dbo.Object_Metadata
SET content = 'Time of day for CHECKDB execution. NULL when disabled.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3600;

-- 3610  is_enabled  (TRIM: two-tier detail lives in design_note #2.)
UPDATE dbo.Object_Metadata
SET content = 'Row-level master switch; when 0, no operations run for this database regardless of per-operation settings.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3610;

-- 3594  server_id  (TRIM: dropped the query/join rationale.)
UPDATE dbo.Object_Metadata
SET content = 'FK to ServerRegistry, denormalized from DatabaseRegistry.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3594;

-- 3595  server_name  (TRIM: dropped the "avoids joins" rationale.)
UPDATE dbo.Object_Metadata
SET content = 'Denormalized server name from ServerRegistry.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3595;

-- ---- R2 migration: new status_value rows for check_mode --------------------
-- Domain from CK_DBCC_ScheduleConfig_check_mode (NONE/PHYSICAL_ONLY/FULL).
-- Natural key: (ServerOps, DBCC_ScheduleConfig, Table, check_mode, status_value,
-- sort_order). No existing status_value rows for this column.

INSERT INTO dbo.Object_Metadata
    (schema_name, object_name, object_type, column_name, property_type, sort_order, title, description, content, is_active)
VALUES
    ('ServerOps', 'DBCC_ScheduleConfig', 'Table', 'check_mode', 'status_value', 1, 'NONE', NULL,
     'No check mode configured. CHECKDB cannot be enabled while check_mode is NONE, and check_mode cannot be set to NONE while CHECKDB is enabled.', 1),
    ('ServerOps', 'DBCC_ScheduleConfig', 'Table', 'check_mode', 'status_value', 2, 'PHYSICAL_ONLY', NULL,
     'Physical structure checks only - page checksums, torn pages, physical page integrity. Significantly faster than FULL.', 1),
    ('ServerOps', 'DBCC_ScheduleConfig', 'Table', 'check_mode', 'status_value', 3, 'FULL', NULL,
     'Complete logical and physical integrity check. Includes all PHYSICAL_ONLY checks plus cross-object logical consistency validation.', 1);

-- ---- R2 migration: new status_value rows for replica_override --------------
-- Domain from CK_DBCC_ScheduleConfig_replica_override (NULL/PRIMARY/SECONDARY).
-- NULL is the default (described on the column); PRIMARY/SECONDARY get rows.

INSERT INTO dbo.Object_Metadata
    (schema_name, object_name, object_type, column_name, property_type, sort_order, title, description, content, is_active)
VALUES
    ('ServerOps', 'DBCC_ScheduleConfig', 'Table', 'replica_override', 'status_value', 1, 'PRIMARY', NULL,
     'Pins this database''s DBCC operations to the primary replica, overriding the default routing.', 1),
    ('ServerOps', 'DBCC_ScheduleConfig', 'Table', 'replica_override', 'status_value', 2, 'SECONDARY', NULL,
     'Pins this database''s DBCC operations to the secondary replica, overriding the default routing.', 1);

-- Verify Section 2 (edits + new status_value rows)
SELECT metadata_id, column_name, property_type, sort_order, title, content, is_active
FROM dbo.Object_Metadata
WHERE schema_name = 'ServerOps' AND object_name = 'DBCC_ScheduleConfig'
  AND (metadata_id IN (3590, 3616, 3618, 3665, 3663, 3598, 3599, 3600, 3610, 3594, 3595)
       OR (property_type = 'status_value' AND column_name IN ('check_mode', 'replica_override')))
ORDER BY property_type, column_name, sort_order, metadata_id;


/* ============================================================================
   SECTION 3 - Execute-DBCC.ps1 (Script)
   ============================================================================ */

-- 3631  relationship_note #3 "GlobalConfig"  (CORRECTION: check_mode is read per
--        database from DBCC_ScheduleConfig, not GlobalConfig.)
UPDATE dbo.Object_Metadata
SET content = 'Reads DBCC execution options at startup: max_dop, extended_logical_checks, alerting_enabled. AG topology settings (AGName, SourceReplica) are also loaded from GlobalConfig. check_mode is read per database from DBCC_ScheduleConfig, not GlobalConfig.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3631;

-- 3625  design_note #1 "Schedule-Driven Execution"  (Fork B CORRECTION: the
--        script reports SUCCESS with a no-work result; it does not emit NO_WORK.)
UPDATE dbo.Object_Metadata
SET content = 'The script runs on a configurable interval via ProcessRegistry. Each invocation queries DBCC_ScheduleConfig for operations whose run_day matches today and whose run_time hour has arrived. If nothing is due, it reports success with a no-work result and exits. The ExecutionLog is checked before each operation to prevent duplicate execution within the same day.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3625;

-- Verify Section 3
SELECT metadata_id, column_name, property_type, sort_order, title, content, is_active
FROM dbo.Object_Metadata
WHERE schema_name = 'ServerOps' AND object_name = 'Execute-DBCC.ps1'
  AND metadata_id IN (3631, 3625)
ORDER BY property_type, sort_order, metadata_id;

/* ============================================================================
   Object_Metadata Re-Audit - Modules: BIDATA, Jira, Teams
   Target: dbo.Object_Metadata (xFACts on AVG-PROD-LSNR)
   Purpose: Re-audit all Object_Metadata content for the three schemas against
            the CURRENT ruleset. These modules were audited before RULE 1,
            RULE 2, and the pattern-not-instances refinement landed, so they
            carry content the original audits blessed.
   Scope:   Schemas BIDATA, Jira, Teams only. Every property_type, object-level
            and column-level, was read. Nothing outside these three schemas is
            touched.

   Run in SSMS step by step. Every UPDATE is keyed by metadata_id (PK); the
   status_value INSERTs are new rows placed by natural key and guarded by
   NOT EXISTS so re-running is safe. Verification SELECTs follow each section.
   Nothing here is commented out.

   ----------------------------------------------------------------------------
   RULES APPLIED (see Metadata_Audit_Rules.md for the full ruleset)
   ----------------------------------------------------------------------------
   R1  Column/object descriptions carry PURPOSE only - no value lists, no
       per-value glosses. The status_value rows are the domain authority.
   R2  Before stripping enum content, verify the column has status_value rows
       covering every glossed value. Coverage was checked per value (Section 0
       preview queries prove it). Two genuine gaps found and migrated by INSERT.
   R4  Pattern-not-instances: module/consumer/step/server names used as examples
       are removed; where the FORMAT is informative it becomes a placeholder.
   R2.5 status_value / query accuracy: corrected claims contradicted by code;
       query literals swapped for placeholders.
   ASCII Object_Metadata content carrying em dashes (U+2014) is normalized to
       " - ". See RULE GAP note below.

   ----------------------------------------------------------------------------
   R2 COVERAGE RESULT (per value, not per column)
   ----------------------------------------------------------------------------
   Verified complete - strip outright, no migration needed:
     BIDATA.BuildExecution.status ..... 5 glossed / 5 rows (COMPLETED, FAILED,
                                        IN_PROGRESS, NOT_STARTED, SUPERSEDED)
     BIDATA.BuildExecution.run_status . 2 glossed (0,1) / 4 rows (0,1,2,3)
     BIDATA.StepExecution.run_status .. 2 glossed (0,1) / 4 rows (0,1,2,3)
     Jira.RequestLog.StatusCode ....... 5 glossed (201,400,401,500,-99) / rows
                                        201,400,401,403,404,500+,-99
     Jira.TicketQueue.TicketStatus .... 4 glossed / 4 rows
     Jira.TicketQueue.TicketPriority .. 5 glossed / 5 rows
     Teams.AlertQueue.alert_category .. 3 glossed / 3 rows
     Teams.AlertQueue.status .......... 3 glossed / 3 rows
     Teams.RequestLog.status_code ..... 1 glossed (200) / rows 200,400,401,404,
                                        429,500+
     Teams.WebhookConfig.alert_category 4 glossed / 4 rows

   Gaps found against CODE (values the code emits that have no status_value row)
   - migrated by INSERT in Section 4:
     Teams.RequestLog.status_code ..... 0 missing. Process-TeamsAlertQueue.ps1
                                        Send-LegacyCard/Send-PrebuiltCard return
                                        StatusCode = 0 when the exception has no
                                        Response object.
     Jira.RequestLog.StatusCode ....... 0, 408, 429 missing. Invoke-JiraAPI
                                        returns 0 when the WebException has no
                                        Response; the burst loop in
                                        Process-JiraTicketQueue.ps1 treats
                                        0/408/429/5xx as transient by name.

   Gap NOT migrated (flagged for decision, see FLAGS):
     Teams.RequestLog.alert_category .. bare value list, no status_value rows.
     Jira.TicketQueue.StatusCode ...... no status_value rows at all.

   ----------------------------------------------------------------------------
   SUMMARY OF CHANGES
   ----------------------------------------------------------------------------
   Rows touched: 62 UPDATE + 4 INSERT = 66. Section 5's conditional UPDATE
   (metadata_id 1891) is NOT applied: query 0.3 returned a sentinel count of 2,
   so historical 'Email' rows exist and the documented dedup filter still
   matches real rows (flag F2, resolved).

     BIDATA .... 15 UPDATE
       R1 strips ........ 147 status, 148 run_status (BuildExecution),
                          214 run_status (StepExecution)
       Value literals ... 141 instance_id, 149 failed_step_id
       Corrections ...... 152 is_backfill (it IS written, always 0)
       R4 ............... 1929, 1966 (dedup trigger examples), 1947, 1967
                          (named job steps), 1957 (query literal)
       Trim ............. 1963 (rationale + direction language)
       ASCII ............ 1940, 1942 (query descriptions), 1958

     Jira ...... 20 UPDATE + 3 INSERT (Section 5 conditional NOT applied)
       R1 strips ........ 493 StatusCode, 408 TicketStatus, 388 TicketPriority
       Corrections ...... 1899, 1905, 1906 (deterministic failure also ends the
                          row terminally, not only retry exhaustion),
                          409 RetryCount, 410 LastRetryDate
       R4 ............... 1893 (query full of real instance values),
                          1898, 1921 ("Same pattern as Teams:")
       Trim ............. 58 object description
       ASCII ............ 1881, 1882, 1883, 1884, 1885, 1886, 1887, 1890
       INSERT ........... RequestLog.StatusCode 0, 408, 429

     Teams ..... 27 UPDATE + 1 INSERT
       R1 strips ........ 882 alert_category, 887 status (AlertQueue),
                          1456 alert_category, 1459 status_code (RequestLog),
                          1392 alert_category (WebhookConfig)
       Corrections ...... 119 object description + 1392 (alert_category is a
                          descriptive label, NOT a routing filter - the
                          processor joins WebhookConfig on config_id and
                          is_active only), 1872 (429 retries inline in the same
                          run, not "on next processor run"), 1871,
                          1454 queue_id (no FK exists - softened from a
                          foreign-key claim to a plain reference; flag F5)
       R4 ............... 881, 1390, 1541 (module/webhook name examples),
                          888, 889 (dedup keys to pattern form), 1817
                          (Module-Level Routing illustration), 1860 (card
                          examples), 1875, 1876, 1877, 1819 (query literals)
       ASCII ............ 1809, 1868, 1869, 1870, 1873, 3116, 3117
       INSERT ........... RequestLog.status_code 0

   ----------------------------------------------------------------------------
   FLAGS - decisions for Dirk, NOT changed by this script
   ----------------------------------------------------------------------------
   F1  Denormalized copy columns and status_value ownership.
       Teams.RequestLog.alert_category and Jira.TicketQueue.StatusCode are
       copies of a value whose authoritative status_value set already lives on
       another column (Teams.AlertQueue.alert_category / Jira.RequestLog.
       StatusCode). R2 says relocate rather than destroy, but duplicating the
       sets onto the copy columns creates exactly the second sync point R1
       exists to prevent. This script strips both descriptions to purpose-only
       and does NOT create duplicate rows. If you want the copy columns to
       carry their own sets, say so and I will add them.

   F2  RESOLVED - Jira.RequestLog query 1891 filters "AND TicketKey != 'Email'".
       Query 0.3 returned a sentinel count of 2: historical rows DO carry the
       'Email' sentinel, so the documented dedup filter matches real rows and is
       not dead. Per the Section 5 gate, that UPDATE is NOT applied - query 1891
       is left exactly as authored. Section 5 is retained below as a note only,
       with no runnable statement.

   F3  Teams.AlertQueue status 'Sent' does not exist.
       Admin-API.ps1 (/api/admin/alert-failures and its count endpoint) filters
       "r.status IN ('Success', 'Sent', 'Pending')". No writer ever sets 'Sent';
       the processor sets Pending/Success/Failed only. Metadata query 3118
       faithfully mirrors the live route, so it is left alone. Recommend a
       backlog item to drop 'Sent' from the route, after which query 3118 gets
       updated to match. Code change, not an audit change.

   F4  Jira.TicketQueue.ProcessedDate and .LastRetryDate are redundant.
       Update-QueueStatus sets both to GETDATE() in the same statement on every
       outcome, so they can never differ. One is a retirement candidate.
       Reported, not changed.

   F5  RESOLVED - Teams.RequestLog.queue_id was described as "Foreign key to
       AlertQueue". Query 0.4 confirmed no FK exists on the column. The UPDATE in
       Section 3 (metadata_id 1454) softens the false foreign-key claim to a
       plain reference, matching the Jira RequestLog.QueueID wording.

   F6  Teams.AlertQueue.color (885) states the default value 'attention' inline.
       A single fixed default reads as column semantics rather than an enum
       list, and the column has no status_value rows, so it is left as authored.
       Raising it only so the judgment is visible.

   ----------------------------------------------------------------------------
   RULE GAP - for Metadata_Audit_Rules.md, not worked around here
   ----------------------------------------------------------------------------
   G1  Byte discipline for Object_Metadata CONTENT is unruled.
       Section 10 of the rules covers delivered xFACts files. It does not cover
       the text stored in dbo.Object_Metadata - yet that text is emitted into
       the generated per-schema metadata .md files and into the doc site, so
       non-ASCII in a metadata row lands as non-ASCII in a repo file.
       All three schemas carry
       em dashes today (20 rows, all fixed here). Recommend the rules doc state
       that Object_Metadata content is pure ASCII, and that other schemas be
       swept in their own audits.
   ============================================================================ */


/* ============================================================================
   SECTION 0 - BEFORE snapshot and evidence queries
   ============================================================================ */

-- 0.1  BEFORE snapshot of every row this script changes.
SELECT metadata_id, schema_name, object_name, column_name, property_type,
       sort_order, title, description, content, is_active
FROM dbo.Object_Metadata
WHERE metadata_id IN (
        -- BIDATA
        141, 147, 148, 149, 152, 214, 1929, 1940, 1942, 1947, 1957, 1958,
        1963, 1966, 1967,
        -- Jira
        58, 388, 408, 409, 410, 493, 1881, 1882, 1883, 1884, 1885, 1886,
        1887, 1890, 1893, 1898, 1899, 1905, 1906, 1921,
        -- Teams
        119, 881, 882, 887, 888, 889, 1390, 1392, 1454, 1456, 1459, 1541,
        1809, 1817, 1819, 1860, 1868, 1869, 1870, 1871, 1872, 1873, 1875,
        1876, 1877, 3116, 3117
      )
ORDER BY schema_name, object_name, property_type, column_name, sort_order;

-- 0.2  R2 coverage proof: every status_value row on the columns being stripped.
--      Compare against the glossed values listed in the header.
SELECT schema_name, object_name, column_name, sort_order, title, content, is_active
FROM dbo.Object_Metadata
WHERE property_type = 'status_value'
  AND ( (schema_name = 'BIDATA' AND column_name IN ('status', 'run_status'))
     OR (schema_name = 'Jira'   AND column_name IN ('StatusCode', 'TicketStatus',
                                                    'TicketPriority', 'TicketKey'))
     OR (schema_name = 'Teams'  AND column_name IN ('alert_category', 'status',
                                                    'status_code')) )
ORDER BY schema_name, object_name, column_name, sort_order;

-- 0.3  F2 evidence: does any historical RequestLog row carry the 'Email'
--      sentinel?  ANSWERED: this returned 2. Historical rows carry it, so the
--      dedup filter is live and Section 5 is NOT applied (query 1891 unchanged).
SELECT COUNT(*) AS email_sentinel_rows
FROM Jira.RequestLog
WHERE TicketKey = 'Email';

-- 0.4  F5 evidence: does Teams.RequestLog.queue_id actually have an FK?
--      ANSWERED: no row - no FK exists. The Section 3 UPDATE to 1454 softens the
--      false foreign-key claim to a plain reference.
SELECT fk.name AS fk_name,
       OBJECT_NAME(fk.parent_object_id)     AS parent_table,
       OBJECT_NAME(fk.referenced_object_id) AS referenced_table
FROM sys.foreign_keys fk
WHERE fk.parent_object_id = OBJECT_ID('Teams.RequestLog');

-- 0.5  Non-ASCII sweep across the three schemas (G1). Should return 20 rows
--      before this script and 0 rows after.
SELECT metadata_id, schema_name, object_name, column_name, property_type, sort_order
FROM dbo.Object_Metadata
WHERE schema_name IN ('BIDATA', 'Jira', 'Teams')
  AND is_active = 1
  AND ( content     COLLATE Latin1_General_BIN LIKE '%' + NCHAR(8212) + '%'
     OR description COLLATE Latin1_General_BIN LIKE '%' + NCHAR(8212) + '%'
     OR title       COLLATE Latin1_General_BIN LIKE '%' + NCHAR(8212) + '%' )
ORDER BY schema_name, object_name, property_type, sort_order;


/* ============================================================================
   SECTION 1 - BIDATA
   ============================================================================ */

-- ---- BuildExecution (Table) ------------------------------------------------

-- 147  description / status  (R1: dropped the five-value list. The status
--       status_value rows are the domain authority.)
UPDATE dbo.Object_Metadata
SET content = 'Current state of this build execution attempt.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 147;

-- 148  description / run_status  (R1: dropped "1=Success, 0=Failed". NULL
--       semantics are non-obvious and stay: run_status is NULL while the build
--       is still IN_PROGRESS - Monitor-BIDATABuild.ps1 writes NULL until the
--       job outcome row appears.)
UPDATE dbo.Object_Metadata
SET content = 'SQL Agent job outcome code captured from job history. NULL while the build is still running.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 148;

-- 141  description / instance_id  (R4: dropped the NOT_STARTED value literal;
--       the conditional-population semantics stay, phrased by condition.)
UPDATE dbo.Object_Metadata
SET content = 'SQL Agent instance identifier from job history. NULL when the record was created without any job history.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 141;

-- 149  description / failed_step_id  (R4: dropped the "status = FAILED" value
--       literal; kept the conditional-population semantics.)
UPDATE dbo.Object_Metadata
SET content = 'Step number that caused the build to fail. NULL when no step failed.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 149;

-- 152  description / is_backfill  (CORRECTION: the column IS written -
--       Monitor-BIDATABuild.ps1 supplies a literal 0 in both BuildExecution
--       INSERTs. Nothing reads it.)
UPDATE dbo.Object_Metadata
SET content = 'Reserved and currently unused; always written as 0 and never read.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 152;

-- 1929  design_note #3 "Instance-Based Deduplication"  (R4: replaced the
--        COMPLETED-12345 instance with the pattern it illustrates.)
UPDATE dbo.Object_Metadata
SET content = 'The notification trigger value combines the build status with the execution attempt identifier, so each attempt can only trigger one alert regardless of how many monitoring cycles observe the same state.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1929;

-- 1940  query #1 description  (ASCII: em dash.)
UPDATE dbo.Object_Metadata
SET description = 'Daily check - shows all build records for today including status and notification state.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1940;

-- 1942  query #3 description  (ASCII: em dash.)
UPDATE dbo.Object_Metadata
SET description = 'Identifies dates with more than one execution attempt - indicates failures and restarts.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1942;

-- ---- StepExecution (Table) -------------------------------------------------

-- 214  description / run_status  (R1: dropped "1=Success, 0=Failed".)
UPDATE dbo.Object_Metadata
SET content = 'SQL Agent outcome code for this step, captured from job history.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 214;

-- 1947  design_note #1 "Complete Step Capture"  (R4: removed the named job
--        steps. The step names are instance detail of one job.)
UPDATE dbo.Object_Metadata
SET content = 'All SQL Agent job steps are captured, including the infrastructure and legacy notification steps that are excluded from the Teams notification message. This preserves full execution history for analysis.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1947;

-- 1957  query #5 content  (R2.5 / R4: swapped the named step literal for a
--        placeholder and dropped the trailing instruction comment, which the
--        query description already carries.)
UPDATE dbo.Object_Metadata
SET content = 'SELECT
    b.build_date,
    s.duration_seconds,
    s.duration_formatted
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE s.step_name = ''<step_name>''
  AND s.run_status = 1
ORDER BY b.build_date;',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1957;

-- 1958  relationship_note #1 "BuildExecution"  (ASCII: em dash.)
UPDATE dbo.Object_Metadata
SET content = 'Each StepExecution row belongs to one BuildExecution record via the build_id foreign key. Step data only has meaning in the context of its parent build - the build_date, status, and instance_id come from the parent row.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1958;

-- ---- Monitor-BIDATABuild.ps1 (Script) --------------------------------------

-- 1963  design_note #1 "Direct Connection vs Linked Server"  (TRIM: dropped the
--        rationale tail. "aligns with the platform direction of unified
--        PowerShell orchestration" is direction language, not current state.)
UPDATE dbo.Object_Metadata
SET content = 'Queries the source server over a direct PowerShell connection rather than through a linked server. This removes the linked server dependency and enables step capture while the build is still running.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1963;

-- 1966  design_note #4 "Instance-Based Deduplication"  (R4: replaced both
--        instance examples with the pattern.)
UPDATE dbo.Object_Metadata
SET content = 'The notification trigger value combines the build status with either the execution attempt identifier or the build date, so each build attempt or not-started condition can only trigger one alert regardless of how many monitoring cycles observe the same state.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1966;

-- 1967  design_note #5 "Notification Step Filtering"  (R4 + CORRECTION: removed
--        the named job steps, and stated the real mechanism - the script
--        excludes by step number from a fixed ExcludedStepIds list, not by
--        matching step names.)
UPDATE dbo.Object_Metadata
SET content = 'Infrastructure and legacy notification steps are excluded from the Teams message body by step number, keeping notifications focused on data processing steps. The excluded steps are still captured in StepExecution for historical completeness.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1967;

-- Verify Section 1
SELECT metadata_id, object_name, column_name, property_type, sort_order,
       title, description, content
FROM dbo.Object_Metadata
WHERE schema_name = 'BIDATA'
  AND metadata_id IN (141, 147, 148, 149, 152, 214, 1929, 1940, 1942, 1947,
                      1957, 1958, 1963, 1966, 1967)
ORDER BY object_name, property_type, column_name, sort_order;


/* ============================================================================
   SECTION 2 - Jira
   ============================================================================ */

-- ---- RequestLog (Table) ----------------------------------------------------

-- 58  object description  (TRIM: dropped the trailing category list.)
UPDATE dbo.Object_Metadata
SET content = 'Permanent audit log of every Jira API interaction, and of queue inserts that failed before an API call was made.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 58;

-- 493  description / StatusCode  (R1: dropped "201=success, 400/401/500=errors,
--       -99=queue failure". Coverage verified in Section 0; the three missing
--       transient codes are INSERTed in Section 4.)
UPDATE dbo.Object_Metadata
SET content = 'Outcome code recorded for this logged interaction.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 493;

-- 1921  design_note #3 "Deduplication Source"  (R4: dropped "Same pattern as
--        Teams:" - a cross-module name-drop.)
UPDATE dbo.Object_Metadata
SET content = 'Calling modules query RequestLog before queuing a ticket to check whether a successful creation already exists for the same trigger type and trigger value. Prevents duplicate Jira tickets across orchestrator cycles.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1921;

-- 1881..1887  status_value / StatusCode  (ASCII: em dash to " - ".)
UPDATE dbo.Object_Metadata
SET content = 'Created - ticket exists in Jira.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1881;

UPDATE dbo.Object_Metadata
SET content = 'Bad Request - check custom field IDs and required fields.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1882;

UPDATE dbo.Object_Metadata
SET content = 'Unauthorized - verify credentials in dbo.Credentials.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1883;

UPDATE dbo.Object_Metadata
SET content = 'Forbidden - check user permissions on the Jira project.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1884;

UPDATE dbo.Object_Metadata
SET content = 'Not Found - verify the project key and issue type exist in Jira.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1885;

UPDATE dbo.Object_Metadata
SET content = 'Server Error - Jira-side failure. Treated as transient and retried.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1886;

UPDATE dbo.Object_Metadata
SET content = 'Queue insert failed - sp_QueueTicket could not write the queue row. The error text is in ResponseMessage.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1887;

-- 1890  status_value / TicketKey "NULL"  (ASCII: em dash.)
UPDATE dbo.Object_Metadata
SET content = 'No ticket was created - the API call failed, or the queue insert itself failed.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1890;

-- ---- TicketQueue (Table) ---------------------------------------------------

-- 408  description / TicketStatus  (R1: dropped the four-value list.)
UPDATE dbo.Object_Metadata
SET content = 'Current processing state of this queue entry.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 408;

-- 388  description / TicketPriority  (R1: dropped the five-value list.)
UPDATE dbo.Object_Metadata
SET content = 'Jira priority requested for the ticket.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 388;

-- 409  description / RetryCount  (CORRECTION: this counts processor TURNS, not
--       individual attempts. The in-cycle burst makes several API attempts
--       without touching RetryCount; only a whole failed turn increments it.)
UPDATE dbo.Object_Metadata
SET content = 'Number of processor turns in which this entry failed and was left for a later cycle.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 409;

-- 410  description / LastRetryDate  (CORRECTION: set on every outcome including
--       success, not only on retries. See flag F4.)
UPDATE dbo.Object_Metadata
SET content = 'When the processor last acted on this entry.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 410;

-- 1898  design_note #1 "Queue-Based Decoupling"  (R4: dropped "Same pattern as
--        Teams:".)
UPDATE dbo.Object_Metadata
SET content = 'Calling modules insert and continue without waiting for Jira API responses. Ticket creation latency does not affect the calling process execution time.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1898;

-- 1899  design_note #2 "Email Fallback"  (CORRECTION: retry exhaustion is not
--        the only path. A deterministic failure - auth, not-found, bad-request -
--        stops the burst and goes straight to the fallback.)
UPDATE dbo.Object_Metadata
SET content = 'When ticket creation cannot succeed - either retries are exhausted or the failure is deterministic - the script sends a fallback email via Database Mail containing the ticket details for manual creation. Requires EmailRecipients to be populated on the queue row. TicketStatus is set to EmailSent as a terminal status.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1899;

-- 1905  status_value / TicketStatus "Failed"  (CORRECTION: RetryCount does not
--        have to reach MaxRetries - a deterministic failure lands here on the
--        first turn when EmailRecipients is empty.)
UPDATE dbo.Object_Metadata
SET content = 'Ticket creation failed terminally and no fallback email was sent because EmailRecipients was not populated. ResponseMessage holds the last error. Terminal status.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1905;

-- 1906  status_value / TicketStatus "EmailSent"  (CORRECTION: same - not only
--        max-retries.)
UPDATE dbo.Object_Metadata
SET content = 'Ticket creation failed terminally and a fallback email was sent via Database Mail. Terminal status indicating the ticket must be created manually from the email.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1906;

-- ---- sp_QueueTicket (Procedure) --------------------------------------------

-- 1893  query #2 "Full example with custom fields"  (R4: every value in this
--        example was a real instance - source module, project key, a live
--        summary, a real recipient address, four real custom field IDs, a real
--        field value, and a real trigger pair. All replaced with placeholders;
--        the parameter set and shape are unchanged.)
UPDATE dbo.Object_Metadata
SET content = 'EXEC Jira.sp_QueueTicket
    @SourceModule               = ''<source module>'',
    @ProjectKey                 = ''<project key>'',
    @Summary                    = ''<ticket summary>'',
    @Description                = @ticket_description,
    @IssueType                  = ''<issue type>'',
    @Priority                   = ''<priority>'',
    @EmailRecipients            = ''<semicolon-separated recipients>'',
    @CascadingField_ID          = ''<cascading field id>'',
    @CascadingField_ParentValue = ''<parent value>'',
    @CascadingField_ChildValue  = ''<child value>'',
    @CustomField_ID             = ''<custom field id>'',
    @CustomField_Value          = ''<custom field value>'',
    @CustomField2_ID            = ''<custom field id>'',
    @CustomField2_Value         = ''<custom field value>'',
    @DueDate                    = @DueDate,
    @TriggerType                = ''<Module>_<Condition>'',
    @TriggerValue               = ''<instance value>'';',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1893;

-- Verify Section 2
SELECT metadata_id, object_name, column_name, property_type, sort_order,
       title, description, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira'
  AND metadata_id IN (58, 388, 408, 409, 410, 493, 1881, 1882, 1883, 1884,
                      1885, 1886, 1887, 1890, 1893, 1898, 1899, 1905, 1906, 1921)
ORDER BY object_name, property_type, column_name, sort_order;


/* ============================================================================
   SECTION 3 - Teams
   ============================================================================ */

-- ---- AlertQueue (Table) ----------------------------------------------------

-- 882  description / alert_category  (R1: dropped the three-value list.)
UPDATE dbo.Object_Metadata
SET content = 'Severity category assigned by the caller.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 882;

-- 887  description / status  (R1: dropped the three-value list.)
UPDATE dbo.Object_Metadata
SET content = 'Current delivery state of this queued alert.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 887;

-- 881  description / source_module  (R4: dropped the three named modules.)
UPDATE dbo.Object_Metadata
SET content = 'Module that queued the alert.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 881;

-- 888  description / trigger_type  (R4: the named trigger examples become the
--       pattern they illustrate, matching the Jira wording.)
UPDATE dbo.Object_Metadata
SET content = 'Category used for deduplication; typically a <Module>_<Condition> pattern.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 888;

-- 889  description / trigger_value  (R4: dropped "(e.g., date)".)
UPDATE dbo.Object_Metadata
SET content = 'Specific instance value that pairs with the trigger category to form the deduplication key.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 889;

-- 3117  design_note #5 "Manual Resend via original_queue_id"  (ASCII: em dash.)
UPDATE dbo.Object_Metadata
SET content = 'Failed alerts can be resent from the Admin page Alert Failures card. Resend inserts a new Pending row copying the original alert content (source_module, alert_category, title, message, color, card_json, trigger_type, trigger_value) with original_queue_id set to the failed row''s queue_id. This is a soft self-reference with no FK constraint, used only by the Admin page display query. The NOT EXISTS filter hides failed alerts that have a successful or pending resend, so the original disappears from the failure list once its resend succeeds. If the resend also fails, the original reappears. Routing is re-resolved at delivery time through WebhookSubscription rather than capturing the original delivery target, so subscription changes between failure and resend are respected.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3117;

-- 3116  description / original_queue_id  (ASCII: em dash.)
UPDATE dbo.Object_Metadata
SET content = 'References the queue_id of the original failed alert. NULL for normal alerts. Populated only on manually resent copies created via the Admin page Alert Failures resend action. Soft reference with no FK constraint. Used by the NOT EXISTS display query to filter out failed alerts that have a successful or pending resend.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 3116;

-- ---- RequestLog (Table) ----------------------------------------------------

-- 1456  description / alert_category  (R1: dropped the three-value list. This
--        column is a copy of AlertQueue.alert_category, which owns the
--        status_value set - see flag F1.)
UPDATE dbo.Object_Metadata
SET content = 'Severity category carried through from the queued alert.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1456;

-- 1459  description / status_code  (R1: dropped "200=success".)
UPDATE dbo.Object_Metadata
SET content = 'HTTP status code returned by the webhook for this delivery attempt.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1459;

-- 1454  description / queue_id  (CORRECTION, flag F5: query 0.4 confirmed no FK
--        exists on this column. Softened the false "Foreign key" claim to a
--        plain reference, matching the Jira RequestLog.QueueID wording.)
UPDATE dbo.Object_Metadata
SET content = 'Links this log entry to its AlertQueue row; no FK constraint, the column is present for tracing.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1454;

-- 1868..1873  status_value / status_code  (ASCII: em dash. 1871 and 1872 also
--        corrected - see below.)
UPDATE dbo.Object_Metadata
SET content = 'Success - the alert was delivered to the webhook.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1868;

UPDATE dbo.Object_Metadata
SET content = 'Bad Request - check the Adaptive Card JSON structure.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1869;

UPDATE dbo.Object_Metadata
SET content = 'Unauthorized - verify the webhook URL in WebhookConfig.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1870;

-- 1871  (CORRECTION + ASCII: stated as a cause rather than an instruction.)
UPDATE dbo.Object_Metadata
SET content = 'Not Found - the webhook no longer exists in Teams and must be recreated.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1871;

-- 1872  (CORRECTION: "will retry on next processor run" is wrong. Retries are
--        inline within the same run, and the row is set Failed once the
--        attempts are exhausted - there is no requeue.)
UPDATE dbo.Object_Metadata
SET content = 'Rate Limited - Teams throttled the delivery. The processor retries inline within the same run and the alert is marked Failed once attempts are exhausted.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1872;

UPDATE dbo.Object_Metadata
SET content = 'Server Error - Teams-side failure. Retried inline within the same run.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1873;

-- ---- WebhookConfig (Table) -------------------------------------------------

-- 119  object description  (CORRECTION: the table holds no routing settings.
--       The processor joins WebhookConfig on config_id and is_active only;
--       routing lives entirely in WebhookSubscription.)
UPDATE dbo.Object_Metadata
SET content = 'Configuration table holding the Teams webhook endpoints that alerts can be delivered to.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 119;

-- 1392  description / alert_category  (R1 + CORRECTION: dropped the four-value
--        list, and dropped "filter" - the column is never evaluated in routing,
--        which its own status_value rows already say.)
UPDATE dbo.Object_Metadata
SET content = 'Descriptive label for the alert type this webhook is intended to carry. Not evaluated during routing.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1392;

-- 1809  status_value / alert_category "ALL"  (ASCII: em dash.)
UPDATE dbo.Object_Metadata
SET content = 'Descriptive label indicating this webhook is intended for all alert types. Not used in routing logic - routing is controlled entirely by WebhookSubscription.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1809;

-- 1390  description / webhook_name  (R4: dropped the two real webhook names.)
UPDATE dbo.Object_Metadata
SET content = 'Human-readable name for this webhook.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1390;

-- ---- WebhookSubscription (Table) -------------------------------------------

-- 1541  description / source_module  (R4: dropped the two named modules.)
UPDATE dbo.Object_Metadata
SET content = 'Module name to match.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1541;

-- 1817  design_note #2 "Module-Level Routing"  (R4: the entire note was an
--        instance illustration - two named modules routed to two named team
--        channels. Rewritten to the pattern it demonstrates.)
UPDATE dbo.Object_Metadata
SET content = 'Subscriptions are keyed on source module, so each module''s alerts can be directed to the channel that owns them without requiring separate webhook infrastructure per team.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1817;

-- 1819  query #2 "Routing simulation"  (R2.5 / R4: the three DECLARE literals
--        were a real module, category, and trigger type. Placeholders now.)
UPDATE dbo.Object_Metadata
SET content = 'DECLARE @Module VARCHAR(50) = ''<source module>'';
DECLARE @Category VARCHAR(50) = ''<alert category>'';
DECLARE @Trigger VARCHAR(50) = ''<trigger type>'';

SELECT DISTINCT
    s.channel_name,
    w.webhook_name
FROM Teams.WebhookSubscription s
INNER JOIN Teams.WebhookConfig w ON s.config_id = w.config_id
WHERE s.source_module = @Module
  AND s.is_active = 1
  AND w.is_active = 1
  AND (s.alert_category IS NULL OR s.alert_category = @Category)
  AND (s.trigger_type IS NULL OR s.trigger_type = @Trigger);',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1819;

-- ---- Process-TeamsAlertQueue.ps1 (Script) ----------------------------------

-- 1860  design_note #2 "Two Card Build Paths"  (R4: dropped the two named
--        consumer card types.)
UPDATE dbo.Object_Metadata
SET content = 'Legacy alerts with title/message/color fields have Adaptive Cards built at send time using a standard template. Alerts with pre-built card_json are sent as-is after emoji placeholder resolution. The pre-built path enables rich multi-section layouts that cannot be expressed with the legacy fields.',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1860;

-- ---- sp_QueueAlert (Procedure) ---------------------------------------------

-- 1875  query #1 "Basic info alert"  (R4: real module, real title, a real
--        completion message with a wall-clock time and duration, a real trigger
--        pair including a date. Placeholders now; the category literal stays -
--        it is the module's own vocabulary and the point of the example.)
UPDATE dbo.Object_Metadata
SET content = 'EXEC Teams.sp_QueueAlert
    @SourceModule  = ''<source module>'',
    @AlertCategory = ''INFO'',
    @Title         = ''<alert title>'',
    @Message       = ''<alert message>'',
    @TriggerType   = ''<Module>_<Condition>'',
    @TriggerValue  = ''<instance value>'';',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1875;

-- 1876  query #2 "Warning alert"  (R4: same treatment.)
UPDATE dbo.Object_Metadata
SET content = 'EXEC Teams.sp_QueueAlert
    @SourceModule  = ''<source module>'',
    @AlertCategory = ''WARNING'',
    @Title         = ''<alert title>'',
    @Message       = @message_body,
    @TriggerType   = ''<Module>_<Condition>'',
    @TriggerValue  = ''<instance value>'';',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1876;

-- 1877  query #3 "Critical alert"  (R4: same treatment.)
UPDATE dbo.Object_Metadata
SET content = 'EXEC Teams.sp_QueueAlert
    @SourceModule  = ''<source module>'',
    @AlertCategory = ''CRITICAL'',
    @Title         = ''<alert title>'',
    @Message       = ''<alert message>'',
    @TriggerType   = ''<Module>_<Condition>'',
    @TriggerValue  = ''<instance value>'';',
    modified_dttm = GETDATE(), modified_by = SUSER_SNAME()
WHERE metadata_id = 1877;

-- Verify Section 3
SELECT metadata_id, object_name, column_name, property_type, sort_order,
       title, description, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Teams'
  AND metadata_id IN (119, 881, 882, 887, 888, 889, 1390, 1392, 1454, 1456,
                      1459, 1541, 1809, 1817, 1819, 1860, 1868, 1869, 1870,
                      1871, 1872, 1873, 1875, 1876, 1877, 3116, 3117)
ORDER BY object_name, property_type, column_name, sort_order;


/* ============================================================================
   SECTION 4 - R2 migration: status_value rows for codes the code emits
   ----------------------------------------------------------------------------
   These are not stripped glosses - they are domain values the code produces
   that were never documented, found while proving R2 coverage. Each INSERT is
   guarded by NOT EXISTS on the natural key so re-running is harmless.
   sort_order appends to each column's existing sequence.
   ============================================================================ */

-- Teams.RequestLog.status_code = 0
-- Source: Process-TeamsAlertQueue.ps1, Send-LegacyCard / Send-PrebuiltCard.
-- Both catch blocks initialize $statusCode = 0 and only overwrite it when
-- $_.Exception.Response exists, so 0 is written whenever the POST never got an
-- HTTP reply. Existing sort_orders on this column: 10..15.
INSERT INTO dbo.Object_Metadata
    (schema_name, object_name, object_type, column_name, property_type, sort_order, title, description, content, is_active)
SELECT 'Teams', 'RequestLog', 'Table', 'status_code', 'status_value', 16, '0', NULL,
       'No HTTP response - the delivery attempt failed before the webhook replied.', 1
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Object_Metadata
    WHERE schema_name = 'Teams' AND object_name = 'RequestLog'
      AND column_name = 'status_code' AND property_type = 'status_value'
      AND title = '0' AND is_active = 1
);

-- Jira.RequestLog.StatusCode = 0, 408, 429
-- Source: Process-JiraTicketQueue.ps1. Invoke-JiraAPI returns StatusCode 0 when
-- the WebException carries no Response. The burst loop names 0, 408, 429 and
-- >= 500 as the transient set; everything else is deterministic and stops the
-- burst immediately. Existing sort_orders on this column: 10..16.
INSERT INTO dbo.Object_Metadata
    (schema_name, object_name, object_type, column_name, property_type, sort_order, title, description, content, is_active)
SELECT 'Jira', 'RequestLog', 'Table', 'StatusCode', 'status_value', 17, '0', NULL,
       'No HTTP response - the request failed before Jira replied. Treated as transient and retried.', 1
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Object_Metadata
    WHERE schema_name = 'Jira' AND object_name = 'RequestLog'
      AND column_name = 'StatusCode' AND property_type = 'status_value'
      AND title = '0' AND is_active = 1
);

INSERT INTO dbo.Object_Metadata
    (schema_name, object_name, object_type, column_name, property_type, sort_order, title, description, content, is_active)
SELECT 'Jira', 'RequestLog', 'Table', 'StatusCode', 'status_value', 18, '408', NULL,
       'Request Timeout - Jira did not respond in time. Treated as transient and retried.', 1
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Object_Metadata
    WHERE schema_name = 'Jira' AND object_name = 'RequestLog'
      AND column_name = 'StatusCode' AND property_type = 'status_value'
      AND title = '408' AND is_active = 1
);

INSERT INTO dbo.Object_Metadata
    (schema_name, object_name, object_type, column_name, property_type, sort_order, title, description, content, is_active)
SELECT 'Jira', 'RequestLog', 'Table', 'StatusCode', 'status_value', 19, '429', NULL,
       'Rate Limited - Jira throttled the request. Treated as transient and retried, honoring the Retry-After header when Jira supplies one.', 1
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Object_Metadata
    WHERE schema_name = 'Jira' AND object_name = 'RequestLog'
      AND column_name = 'StatusCode' AND property_type = 'status_value'
      AND title = '429' AND is_active = 1
);

-- Verify Section 4 - the two status-code domains, full active set.
SELECT schema_name, object_name, column_name, sort_order, title, content, is_active
FROM dbo.Object_Metadata
WHERE property_type = 'status_value'
  AND ( (schema_name = 'Teams' AND object_name = 'RequestLog' AND column_name = 'status_code')
     OR (schema_name = 'Jira'  AND object_name = 'RequestLog' AND column_name = 'StatusCode') )
ORDER BY schema_name, column_name, sort_order;


/* ============================================================================
   SECTION 5 - DECISION section (F2) - RESOLVED, NOT APPLIED.
   ----------------------------------------------------------------------------
   This section originally held a conditional UPDATE to remove the
   "AND TicketKey != 'Email'" filter from the documented dedup pattern (query
   1891), gated on query 0.3 returning 0. Query 0.3 returned 2: historical
   Jira.RequestLog rows carry the 'Email' sentinel, so the filter matches real
   rows and is not dead. Per the gate, the UPDATE is NOT applied and has been
   removed - query 1891 is left exactly as authored. No statement runs here.
   The SELECT below is read-only, confirming 1891's content is untouched.
   ============================================================================ */

-- Confirm query 1891 is unchanged (read-only; nothing is modified in Section 5).
SELECT metadata_id, object_name, property_type, sort_order, title, content
FROM dbo.Object_Metadata
WHERE metadata_id = 1891;


/* ============================================================================
   SECTION 6 - Final verification
   ============================================================================ */

-- 6.1  No non-ASCII left in the three schemas. Expect zero rows.
SELECT metadata_id, schema_name, object_name, column_name, property_type, sort_order,
       title, description, content
FROM dbo.Object_Metadata
WHERE schema_name IN ('BIDATA', 'Jira', 'Teams')
  AND is_active = 1
  AND ( content     COLLATE Latin1_General_BIN LIKE '%' + NCHAR(8212) + '%'
     OR description COLLATE Latin1_General_BIN LIKE '%' + NCHAR(8212) + '%'
     OR title       COLLATE Latin1_General_BIN LIKE '%' + NCHAR(8212) + '%' )
ORDER BY schema_name, object_name;

-- 6.2  R1 sweep: any remaining description carrying an equals-gloss or a
--       "Current status:" / "Category:" style list. Expect zero rows.
SELECT metadata_id, schema_name, object_name, column_name, sort_order, content
FROM dbo.Object_Metadata
WHERE schema_name IN ('BIDATA', 'Jira', 'Teams')
  AND property_type = 'description'
  AND column_name IS NOT NULL
  AND is_active = 1
  AND ( content LIKE '%=Success%' OR content LIKE '%=success%'
     OR content LIKE '%=Failed%'  OR content LIKE '%=error%'
     OR content LIKE 'Current status:%'
     OR content LIKE 'Category:%'
     OR content LIKE 'Priority:%'
     OR content LIKE '%Build status:%' )
ORDER BY schema_name, object_name, sort_order;

-- 6.3  R4 sweep: any remaining "(e.g." / "such as" / ", etc" in the three
--       schemas. Exactly one hit is expected and is deliberate: metadata_id
--       1849 (Jira, Process-JiraTicketQueue.ps1, design_note "Email Fallback on
--       API Failure") says "a deterministic failure such as bad credentials or
--       an invalid field". Those are kinds of failure, not instance names, and
--       they are what makes "deterministic" legible. Left as authored. Any
--       other hit is drift.
SELECT metadata_id, schema_name, object_name, column_name, property_type,
       sort_order, title, content
FROM dbo.Object_Metadata
WHERE schema_name IN ('BIDATA', 'Jira', 'Teams')
  AND is_active = 1
  AND ( content LIKE '%(e.g.%' OR content LIKE '%such as %' OR content LIKE '%, etc%'
     OR content LIKE '%For example%' OR content LIKE '%for example%' )
ORDER BY schema_name, object_name, property_type, sort_order;

-- 6.4  Change audit: everything stamped by this run.
SELECT metadata_id, schema_name, object_name, column_name, property_type,
       sort_order, title, modified_dttm, modified_by
FROM dbo.Object_Metadata
WHERE schema_name IN ('BIDATA', 'Jira', 'Teams')
  AND modified_dttm >= CAST(GETDATE() AS DATE)
ORDER BY schema_name, object_name, property_type, sort_order;

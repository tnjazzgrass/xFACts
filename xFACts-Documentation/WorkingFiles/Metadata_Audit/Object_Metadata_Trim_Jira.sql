/* ============================================================================
   Object_Metadata Audit and Trim - Jira schema
   Target: dbo.Object_Metadata (xFACts on AVG-PROD-LSNR)
   Purpose: Correct Jira documentation content that no longer matches current
            code, apply the no-naming rule (strip module/consumer names and
            e.g. examples), and align the retry/fallback status_values with the
            intended design (the 'Failed'-on-retryable-failure defect is tracked
            in backlog B-111, not fixed here).
   Run in SSMS step by step. Each UPDATE is keyed by metadata_id (primary key).
   Verification SELECTs follow each section. Nothing here is commented out.

   ----------------------------------------------------------------------------
   SUMMARY OF CHANGES
   ----------------------------------------------------------------------------
   Rows touched: 28  (27 UPDATE, 1 retire via is_active = 0)

     Factual corrections (no longer match current code):
       - 1854  Script GlobalConfig relationship_note
                 (dropped "Also used for retry configuration" - no such Jira
                  config exists; only the master passphrase is read)
       - 489   RequestLog.RequestType description
                 (CreateTicket is never written; the code writes the caller's
                  trigger type, or QueueInsertFailed on queue-insert failure)
       - 492   RequestLog.TicketKey description
                 (dropped the "'Email' if fallback used" clause - the code
                  writes NULL, never the literal 'Email')
       - 1888  RequestLog.TicketKey status_value (was titled "SD-12345 (example)")
                 (retitled generic; example key removed)
       - 408   TicketQueue.TicketStatus description
                 (was "Pending, Success, Failed" - added EmailSent)
       - 1904  TicketQueue.TicketStatus status_value Success (e.g. key removed)
       - 1905  TicketQueue.TicketStatus status_value Failed  (see Decision R)
       - 1903  TicketQueue.TicketStatus status_value Pending (see Decision R)
       - 1835  sp_QueueTicket.data_flow  (external entry surface - Decision C)
       - 1838  sp_QueueTicket.relationship_note TicketQueue (external - Decision C)

     Retire (dead enum - code never produces this value):
       - 1889  RequestLog.TicketKey status_value 'Email'  (is_active = 0)
                 (fallback path writes TicketKey NULL, not 'Email'; the dedup
                  query guard TicketKey != 'Email' is harmless and LEFT AS-IS)

     No-naming rule (strip module/consumer names and e.g. examples):
       - 487   RequestLog.SourceModule    (stripped e.g. module names)
       - 488   RequestLog.ServiceName     (tightened: always 'Jira')
       - 490   RequestLog.ProjectKey      (stripped e.g. key)
       - 497   RequestLog.Trigger_Type    (pattern form - Decision N)
       - 498   RequestLog.Trigger_Value   (generic form - Decision N)
       - 383   TicketQueue.SourceModule   (stripped e.g. module names)
       - 384   TicketQueue.ProjectKey     (stripped e.g. key)
       - 387   TicketQueue.IssueType      (stripped value list)
       - 390   TicketQueue.CascadingField_ID (stripped e.g. field id)
       - 400   TicketQueue.TriggerType    (pattern form - Decision N)
       - 401   TicketQueue.TriggerValue   (generic form - Decision N)
       - 405   TicketQueue.TicketKey      (stripped e.g. key)
       - 406   TicketQueue.StatusCode     (trimmed parenthetical)
       - 1900  TicketQueue.design_note "Generic Custom Field Support" (e.g. id)
       - 1897  TicketQueue.data_flow      (dropped "(from T-SQL callers)")
       - 1892  sp_QueueTicket.query "Basic ticket" (placeholders, Decision N)
       - 1893  sp_QueueTicket.query "Full example..." (placeholders, Decision N)

   Rows reviewed and left as-is (already conformant): category/module tags;
     all data_flow/design_note/description/relationship/query rows not listed
     above; the StatusCode/TicketPriority status_value sets (controlled enums);
     the terse column descriptions not listed; the dedup query body 1891.

   ----------------------------------------------------------------------------
   DECISIONS APPLIED (from the audit report; Dirk approved 2026-07-22)
   ----------------------------------------------------------------------------
   R. Retry finding = code bug (B-111). Cross-cycle retry + email fallback is
      the intended design; the 'Failed' stamp on a retryable failure is the
      defect. The doc pages keep the retry/fallback narrative as intended
      behavior. For metadata consistency, the TicketStatus status_values are
      reframed to the intended design: Pending (1903) also covers a retryable
      failure returning for the next cycle; Failed (1905) is the TERMINAL state
      after retries are exhausted with no fallback email - the prior sentence
      "Failed rows are not automatically re-picked up..." (which rationalized the
      defect as design) is removed. These two rows describe intended-not-yet-
      current behavior on purpose, matching the docs; the gap is tracked in
      B-111. If you prefer metadata to describe current (buggy) behavior instead,
      skip the 1903 and 1905 UPDATEs.

   C. sp_QueueTicket is an open T-SQL entry point with live external, non-xFACts
      callers. Metadata now describes it as an open surface callable by any
      process with EXECUTE permission, including external callers (1835, 1838) -
      no specific caller names, per the no-naming rule.

   N. No-naming rule (saved as a standing audit rule). Strip all module/consumer
      names and e.g./such-as/etc examples. Format-informative fields
      (Trigger_Type/Trigger_Value) get a generic pattern rather than deletion.
      Call-syntax query blocks keep their shape but use placeholders. Closed,
      module-controlled enums (TicketStatus, StatusCode, TicketPriority, the
      'Jira' service identity, the QueueInsertFailed / -99 sentinels) are KEPT.

   Flagged, NOT changed here (need your call - see report):
     - Teams cross-references in metadata design_notes 1898 and 1921
       ("Same pattern as Teams") and throughout both doc pages. Sibling-module
       cross-refs, not caller examples; left in place pending your decision on
       whether the no-naming rule extends to sibling-doc cross-references.
   ============================================================================ */


/* ============================================================================
   SECTION 0 - BEFORE snapshot (optional; run to capture current text)
   ============================================================================ */
SELECT metadata_id, object_name, column_name, property_type, title,
       description, content, is_active
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira'
  AND metadata_id IN (1854, 487, 488, 489, 490, 492, 497, 498, 1888, 1889,
                      1835, 1838, 1892, 1893, 383, 384, 387, 390, 400, 401,
                      405, 406, 408, 1897, 1900, 1903, 1904, 1905)
ORDER BY object_name, property_type, sort_order, metadata_id;


/* ============================================================================
   SECTION 1 - Process-JiraTicketQueue.ps1 (Script)
   ============================================================================ */

-- 1854  GlobalConfig relationship_note  (CORRECTION: no Jira retry config exists
--        in GlobalConfig; the only value read is the master passphrase used for
--        credential decryption.)
UPDATE dbo.Object_Metadata
SET content = 'Reads the master passphrase used for credential decryption.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1854;

-- Verify Section 1
SELECT metadata_id, object_name, property_type, title, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira' AND metadata_id = 1854;


/* ============================================================================
   SECTION 2 - sp_QueueTicket (Procedure)
   ============================================================================ */

-- 1835  data_flow  (Decision C: open entry point with external, non-xFACts
--        callers; no caller names.)
UPDATE dbo.Object_Metadata
SET content = 'Open entry point that any process with EXECUTE permission can call to queue a Jira ticket request, including external, non-xFACts callers. Inserts one row into Jira.TicketQueue with Pending status. The INSERT fires TR_Jira_TicketQueue_QueueDepth, which signals the orchestrator to launch the processor. On INSERT failure, catches the error and logs directly to Jira.RequestLog with StatusCode = -99 and RequestType = ''QueueInsertFailed''.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1835;

-- 1838  relationship_note Jira.TicketQueue  (Decision C: main entry point, open
--        surface, no caller names.)
UPDATE dbo.Object_Metadata
SET content = 'Primary INSERT target. This is the main entry point for queuing Jira ticket requests, open to any process with EXECUTE permission, including external, non-xFACts callers.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1838;

-- 1892  query "Basic ticket"  (Decision N: placeholders replace named values.)
UPDATE dbo.Object_Metadata
SET content = 'EXEC Jira.sp_QueueTicket
    @SourceModule = ''<source module>'',
    @ProjectKey   = ''<project key>'',
    @Summary      = ''<ticket summary>'',
    @Description  = ''<ticket description>'';',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1892;

-- 1893  query "Full example with custom fields"  (Decision N: placeholders
--        replace named values.)
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
    @TriggerType                = ''<trigger category>'',
    @TriggerValue               = ''<trigger value>'';',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1893;

-- Verify Section 2
SELECT metadata_id, property_type, title, description, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira' AND object_name = 'sp_QueueTicket'
  AND metadata_id IN (1835, 1838, 1892, 1893)
ORDER BY metadata_id;


/* ============================================================================
   SECTION 3 - TicketQueue (Table)
   ============================================================================ */

-- 383  SourceModule description  (no-naming: stripped e.g. module names.)
UPDATE dbo.Object_Metadata
SET content = 'Module that queued the ticket.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 383;

-- 384  ProjectKey description  (no-naming: stripped e.g. key.)
UPDATE dbo.Object_Metadata
SET content = 'Jira project key.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 384;

-- 387  IssueType description  (no-naming: stripped the value list.)
UPDATE dbo.Object_Metadata
SET content = 'Jira issue type.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 387;

-- 390  CascadingField_ID description  (no-naming: stripped e.g. field id.)
UPDATE dbo.Object_Metadata
SET content = 'Field ID for the cascading select.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 390;

-- 400  TriggerType description  (Decision N: generic pattern form.)
UPDATE dbo.Object_Metadata
SET content = 'Category used for deduplication; typically a <Module>_<Condition> pattern.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 400;

-- 401  TriggerValue description  (Decision N: generic form.)
UPDATE dbo.Object_Metadata
SET content = 'Specific instance value that pairs with the trigger category to form the deduplication key.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 401;

-- 405  TicketKey description  (no-naming: stripped e.g. key.)
UPDATE dbo.Object_Metadata
SET content = 'Jira ticket key assigned when the ticket is created.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 405;

-- 406  StatusCode description  (no-naming: trimmed parenthetical.)
UPDATE dbo.Object_Metadata
SET content = 'HTTP status code returned by the Jira API.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 406;

-- 408  TicketStatus description  (CORRECTION: add EmailSent to the value list.)
UPDATE dbo.Object_Metadata
SET content = 'Current status: Pending, Success, Failed, EmailSent.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 408;

-- 1897  data_flow  (no-naming: dropped the "(from T-SQL callers)" parenthetical;
--        the open-surface description lives on the proc.)
UPDATE dbo.Object_Metadata
SET content = 'Tickets enter via Jira.sp_QueueTicket or by direct INSERT. TR_Jira_TicketQueue_QueueDepth fires on INSERT, incrementing running_count in Orchestrator.ProcessRegistry to signal the orchestrator. Process-JiraTicketQueue.ps1 claims Pending rows (TicketStatus = ''Pending'' AND RetryCount < MaxRetries), retrieves Jira credentials from dbo.Credentials via two-tier passphrase decryption (master passphrase from GlobalConfig), creates tickets via Jira REST API, and updates TicketStatus to Success or Failed with the returned TicketKey. On success the script performs a GET to retrieve the assigned user. Each API interaction is logged to Jira.RequestLog. When max retries are exhausted and EmailRecipients is populated, the script sends a fallback email via Database Mail and sets TicketStatus to EmailSent.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1897;

-- 1900  design_note "Generic Custom Field Support"  (no-naming: stripped the
--        e.g. field id.)
UPDATE dbo.Object_Metadata
SET content = 'Up to three arbitrary Jira custom fields plus one cascading select field can be specified per ticket. Field IDs and values are stored in the queue and mapped into the Jira API payload at creation time. This avoids hardcoding Jira field schemas into the table structure.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1900;

-- 1903  status_value TicketStatus Pending  (Decision R: intended design - a
--        retryable failure also returns the row here for the next cycle.)
UPDATE dbo.Object_Metadata
SET content = 'Waiting for processor pickup. Set on INSERT as the default value, and a retryable failure returns the row to this status for the next processor cycle.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1903;

-- 1904  status_value TicketStatus Success  (no-naming: stripped e.g. key.)
UPDATE dbo.Object_Metadata
SET content = 'Jira ticket created successfully; TicketKey is populated with the returned Jira issue key.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1904;

-- 1905  status_value TicketStatus Failed  (Decision R: intended design - Failed
--        is the TERMINAL state after retries are exhausted with no fallback
--        email; removed the sentence rationalizing the defect as design.)
UPDATE dbo.Object_Metadata
SET content = 'Jira API call failed and all retry attempts have been exhausted with no fallback email sent (EmailRecipients not populated). RetryCount has reached MaxRetries and ResponseMessage holds the last error. Terminal status.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1905;

-- Verify Section 3
SELECT metadata_id, column_name, property_type, title, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira' AND object_name = 'TicketQueue'
  AND metadata_id IN (383, 384, 387, 390, 400, 401, 405, 406, 408,
                      1897, 1900, 1903, 1904, 1905)
ORDER BY property_type, sort_order, metadata_id;


/* ============================================================================
   SECTION 4 - RequestLog (Table)
   ============================================================================ */

-- 487  SourceModule description  (no-naming: stripped e.g. module names.)
UPDATE dbo.Object_Metadata
SET content = 'Module that originated the request.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 487;

-- 488  ServiceName description  (no-naming/CORRECTION: always 'Jira'.)
UPDATE dbo.Object_Metadata
SET content = 'Service name; always ''Jira'' for this module.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 488;

-- 489  RequestType description  (CORRECTION: CreateTicket is never written; the
--        code writes the caller-supplied trigger type, or QueueInsertFailed on a
--        queue-insert failure.)
UPDATE dbo.Object_Metadata
SET content = 'Request category. Mirrors the caller-supplied trigger type on a logged API interaction, or QueueInsertFailed when the queue insert fails.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 489;

-- 490  ProjectKey description  (no-naming: stripped e.g. key.)
UPDATE dbo.Object_Metadata
SET content = 'Jira project key.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 490;

-- 492  TicketKey description  (CORRECTION + no-naming: the fallback path writes
--        NULL, not 'Email'; stripped the e.g. key and the dead 'Email' clause.)
UPDATE dbo.Object_Metadata
SET content = 'Jira ticket key returned when the ticket is created; NULL when no ticket was created.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 492;

-- 497  Trigger_Type description  (Decision N: generic pattern form.)
UPDATE dbo.Object_Metadata
SET content = 'Category used for deduplication lookups; typically a <Module>_<Condition> pattern.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 497;

-- 498  Trigger_Value description  (Decision N: generic form.)
UPDATE dbo.Object_Metadata
SET content = 'Specific instance value that pairs with the trigger category to form the deduplication key.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 498;

-- 1888  status_value TicketKey (was titled "SD-12345 (example)")  (no-naming:
--        retitled generic, example key removed.)
UPDATE dbo.Object_Metadata
SET title = 'Actual Jira ticket key',
    content = 'Ticket created successfully in Jira; the column holds the returned Jira ticket key.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1888;

-- 1889  status_value TicketKey 'Email'  (RETIRE: the code writes NULL on the
--        fallback path, never the literal 'Email'. Soft-delete via is_active = 0.
--        The dedup query guard TicketKey != 'Email' is harmless and LEFT AS-IS.)
UPDATE dbo.Object_Metadata
SET is_active = 0,
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1889;

-- Verify Section 4
SELECT metadata_id, column_name, property_type, title, content, is_active
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira' AND object_name = 'RequestLog'
  AND metadata_id IN (487, 488, 489, 490, 492, 497, 498, 1888, 1889)
ORDER BY property_type, sort_order, metadata_id;


/* ============================================================================
   SECTION 5 - Final verification (all touched rows in one result set)
   ============================================================================ */
SELECT metadata_id, object_name, column_name, property_type, sort_order,
       title, content, is_active, modified_dttm
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira'
  AND metadata_id IN (1854, 487, 488, 489, 490, 492, 497, 498, 1888, 1889,
                      1835, 1838, 1892, 1893, 383, 384, 387, 390, 400, 401,
                      405, 406, 408, 1897, 1900, 1903, 1904, 1905)
ORDER BY object_name, property_type, sort_order, metadata_id;

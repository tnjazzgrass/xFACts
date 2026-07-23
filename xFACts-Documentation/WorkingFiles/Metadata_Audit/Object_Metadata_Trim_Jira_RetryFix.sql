/* ============================================================================
   Object_Metadata Follow-up - Jira retry-ladder fix (B-111)
   Target: dbo.Object_Metadata (xFACts on AVG-PROD-LSNR)
   Purpose: Bring the retry-related metadata in step with the Process-
            JiraTicketQueue.ps1 fix that added an in-cycle burst and made
            retryable failures leave the row Pending across cycles (Failed and
            EmailSent are now terminal-only). Run AFTER Object_Metadata_Trim_
            Jira.sql (this rewrites 1897 to the fully-current text, so order does
            not matter, but keep the two together).
   Run in SSMS step by step. Each UPDATE is keyed by metadata_id (primary key).

   ----------------------------------------------------------------------------
   SUMMARY OF CHANGES
   ----------------------------------------------------------------------------
   Rows touched: 3  (3 UPDATE)

     - 1845  Process-JiraTicketQueue.ps1 data_flow
               (replaced "On failure ... sets TicketStatus to Failed" with the
                in-cycle burst + cross-cycle ladder + deterministic fast-fail)
     - 1897  TicketQueue data_flow
               (Success / Pending-for-retry / terminal-at-exhaustion, not
                "Success or Failed"; also carries the earlier no-naming trim)
     - 1849  Process-JiraTicketQueue.ps1 design_note "Email Fallback on API
               Failure" (fires at retry exhaustion OR immediately on a
                deterministic failure)

   Not changed (verified still true after the fix):
     - 1854  GlobalConfig relationship_note stays "master passphrase for
               credential decryption" - retry tuning lives in the script
               parameters (-MaxRetries / -BurstAttempts / -BurstDelaySeconds),
               supplied by the orchestrator via ProcessRegistry, NOT in
               GlobalConfig. No retry config key exists to document.
     - The TicketStatus status_values (1903 Pending, 1905 Failed, 1906
               EmailSent) already describe the intended design and are now
               current with the shipped code.
   ============================================================================ */


/* ============================================================================
   SECTION 0 - BEFORE snapshot (optional)
   ============================================================================ */
SELECT metadata_id, object_name, property_type, title, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira' AND metadata_id IN (1845, 1897, 1849)
ORDER BY object_name, metadata_id;


/* ============================================================================
   SECTION 1 - Process-JiraTicketQueue.ps1 (Script)
   ============================================================================ */

-- 1845  data_flow  (retry ladder: in-cycle burst, then Pending across cycles,
--        deterministic fast-fail, email at exhaustion.)
UPDATE dbo.Object_Metadata
SET content = 'Launched by the orchestrator when TR_Jira_TicketQueue_QueueDepth signals queue depth > 0. Retrieves master passphrase from dbo.GlobalConfig, uses two-tier decryption against dbo.Credentials to obtain Jira URL, username, and password. Reads Pending tickets from Jira.TicketQueue (TicketStatus = ''Pending'' AND RetryCount < MaxRetries), builds JSON payload mapping queue columns to Jira REST API fields (including custom fields and cascading selects), and creates tickets via POST to /rest/api/2/issue. On success, performs a GET to retrieve the actual assignee, updates TicketQueue with TicketKey and Success status, and logs to Jira.RequestLog. Each transient failure is retried in-cycle up to BurstAttempts times; if the whole turn still fails, RetryCount is incremented and the row is left Pending for a later cycle, up to MaxRetries turns. Deterministic failures (auth, not-found, bad-request) skip retries. When retries are exhausted or a deterministic failure occurs, and EmailRecipients is populated, sends a fallback email via Database Mail and sets TicketStatus to EmailSent (or Failed when no recipients).',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1845;

-- 1849  design_note "Email Fallback on API Failure"  (also fires immediately on
--        a deterministic failure, not only at retry exhaustion.)
UPDATE dbo.Object_Metadata
SET content = 'When Jira API calls fail after all retry attempts, or immediately on a deterministic failure such as bad credentials or an invalid field, the script can send a fallback email via Database Mail containing the ticket summary, description, and error details. This ensures the request is not silently lost even when the ticket cannot be created. Requires EmailRecipients to be populated on the queue row.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1849;

-- Verify Section 1
SELECT metadata_id, property_type, title, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira' AND metadata_id IN (1845, 1849)
ORDER BY metadata_id;


/* ============================================================================
   SECTION 2 - TicketQueue (Table)
   ============================================================================ */

-- 1897  data_flow  (Success / Pending-for-retry / terminal-at-exhaustion;
--        includes the earlier no-naming trim of the "(from T-SQL callers)"
--        parenthetical so this is the fully-current text.)
UPDATE dbo.Object_Metadata
SET content = 'Tickets enter via Jira.sp_QueueTicket or by direct INSERT. TR_Jira_TicketQueue_QueueDepth fires on INSERT, incrementing running_count in Orchestrator.ProcessRegistry to signal the orchestrator. Process-JiraTicketQueue.ps1 claims Pending rows (TicketStatus = ''Pending'' AND RetryCount < MaxRetries), retrieves Jira credentials from dbo.Credentials via two-tier passphrase decryption (master passphrase from GlobalConfig), creates tickets via Jira REST API, and sets TicketStatus to Success with the returned TicketKey, leaves it Pending for a later cycle on a transient failure, or sets a terminal status once retries are exhausted or a deterministic failure occurs. On success the script performs a GET to retrieve the assigned user. Each API interaction is logged to Jira.RequestLog. When retries are exhausted or a deterministic failure occurs and EmailRecipients is populated, the script sends a fallback email via Database Mail and sets TicketStatus to EmailSent.',
    modified_dttm = GETDATE(),
    modified_by = SUSER_SNAME()
WHERE metadata_id = 1897;

-- Verify Section 2
SELECT metadata_id, property_type, title, content
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira' AND metadata_id = 1897;


/* ============================================================================
   SECTION 3 - Final verification
   ============================================================================ */
SELECT metadata_id, object_name, property_type, title, content, modified_dttm
FROM dbo.Object_Metadata
WHERE schema_name = 'Jira' AND metadata_id IN (1845, 1849, 1897)
ORDER BY object_name, metadata_id;

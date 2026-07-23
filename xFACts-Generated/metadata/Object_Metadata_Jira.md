# Object_Metadata: Jira
Source: dbo.Object_Metadata
Generated: 2026-07-22 19:01:32

## Process-JiraTicketQueue.ps1 (Script)

### category #0  [metadata_id: 1844]

Jira

### data_flow #0  [metadata_id: 1845]

Launched by the orchestrator when TR_Jira_TicketQueue_QueueDepth signals queue depth > 0. Retrieves master passphrase from dbo.GlobalConfig, uses two-tier decryption against dbo.Credentials to obtain Jira URL, username, and password. Reads Pending tickets from Jira.TicketQueue (TicketStatus = 'Pending' AND RetryCount < MaxRetries), builds JSON payload mapping queue columns to Jira REST API fields (including custom fields and cascading selects), and creates tickets via POST to /rest/api/2/issue. On success, performs a GET to retrieve the actual assignee, updates TicketQueue with TicketKey and Success status, and logs to Jira.RequestLog. On failure, increments RetryCount and sets TicketStatus to Failed. When max retries are exhausted and EmailRecipients is populated, sends a fallback email via Database Mail and sets TicketStatus to EmailSent.

### description #0  [metadata_id: 1842]

Queue processor that creates Jira tickets via REST API. Claims Pending tickets from TicketQueue, authenticates using encrypted credentials from dbo.Credentials, creates tickets in Jira, retrieves assignee information, updates queue status, and logs results to RequestLog. Sends email fallback via Database Mail when API calls fail after all retry attempts.

### design_note #1  [metadata_id: 1846]
Title: Queue-Driven Execution

Runs as a queue-driven process (run_mode = 2) in the orchestrator. Only launched when tickets are waiting, not on a fixed polling schedule.

### design_note #2  [metadata_id: 1847]
Title: HttpWebRequest for Auth Bypass

Uses System.Net.HttpWebRequest instead of Invoke-RestMethod because Jira returns WWW-Authenticate: Negotiate in the response headers. PowerShell Invoke-RestMethod interprets this as a request for Windows integrated auth and attempts Negotiate authentication instead of using the explicitly provided Basic auth header. HttpWebRequest with PreAuthenticate = true forces Basic auth on the first request.

### design_note #3  [metadata_id: 1848]
Title: Two-Tier Credential Decryption

Credentials are stored encrypted in dbo.Credentials. The master passphrase (from GlobalConfig) decrypts a service-specific passphrase, which in turn decrypts the actual Jira URL, username, and password. No secrets are stored in the script or on disk.

### design_note #4  [metadata_id: 1849]
Title: Email Fallback on API Failure

When Jira API calls fail after all retry attempts, the script can send a fallback email via Database Mail containing the ticket summary, description, and error details. This ensures the request is not silently lost even when the Jira API is unreachable. Requires EmailRecipients to be populated on the queue row.

### design_note #5  [metadata_id: 1850]
Title: Orchestrator v2 Integration

Accepts TaskId and ProcessId parameters from the orchestrator engine. Calls Complete-OrchestratorTask on completion with status, duration, and a summary of processed/created/failed/email counts. Supports -Execute safeguard (preview mode by default).

### module #0  [metadata_id: 1843]

Jira Integration

### relationship_note #1  [metadata_id: 1851]
Title: Jira.TicketQueue

Primary data source. Reads Pending rows, updates TicketStatus, TicketKey, StatusCode, ResponseMessage, RetryCount, ProcessedDate, and LastRetryDate after each API interaction.

### relationship_note #2  [metadata_id: 1852]
Title: Jira.RequestLog

Write target. Inserts one row per API interaction (success or failure) for complete audit trail.

### relationship_note #3  [metadata_id: 1853]
Title: dbo.Credentials

Reads encrypted Jira API credentials (URL, username, password) using two-tier passphrase decryption.

### relationship_note #4  [metadata_id: 1854]
Title: dbo.GlobalConfig

Reads the master passphrase used for credential decryption.

## RequestLog (Table)

### category #0  [metadata_id: 1699]

Jira

### data_flow #0  [metadata_id: 1918]

Process-JiraTicketQueue.ps1 inserts one row per Jira API interaction (both successes and failures). sp_QueueTicket also writes directly to RequestLog when a queue INSERT fails (RequestType = 'QueueInsertFailed', StatusCode = -99). Calling modules query this table for deduplication before queuing new tickets, checking Trigger_Type and Trigger_Value with a successful StatusCode to avoid creating duplicate Jira tickets for the same condition.

### description #0  [metadata_id: 58]

Permanent audit log of all Jira API interactions including successful ticket creations, failures, and queue insert errors.

### design_note #1  [metadata_id: 1919]
Title: Append-Only Audit Trail

Rows are never updated or deleted. Each API interaction generates a separate entry for complete ticket creation history.

### design_note #2  [metadata_id: 1920]
Title: Queue Failure Logging

sp_QueueTicket catches INSERT failures and logs them directly to RequestLog with StatusCode = -99 and RequestType = 'QueueInsertFailed'. This ensures visibility even when the queue INSERT itself fails.

### design_note #3  [metadata_id: 1921]
Title: Deduplication Source

Same pattern as Teams: calling modules query RequestLog before queuing tickets to check if a successful creation already exists for the same Trigger_Type and Trigger_Value combination. Prevents duplicate Jira tickets across orchestrator cycles.

### module #0  [metadata_id: 1595]

Jira

### query #1  [metadata_id: 1922]
Title: Recent activity
Description: Last 20 API interactions showing source module, ticket key, status code, and timestamp.

SELECT TOP 20
    SourceModule,
    RequestType,
    ProjectKey,
    Summary,
    TicketKey,
    StatusCode,
    CreatedDate
FROM Jira.RequestLog
ORDER BY CreatedDate DESC;

### query #2  [metadata_id: 1923]
Title: Failed API calls
Description: All entries with non-success status codes for troubleshooting.

SELECT 
    LogID,
    SourceModule,
    RequestType,
    ProjectKey,
    Summary,
    StatusCode,
    ResponseMessage,
    CreatedDate
FROM Jira.RequestLog
WHERE StatusCode NOT IN (200, 201) OR StatusCode IS NULL
ORDER BY CreatedDate DESC;

### query #3  [metadata_id: 1924]
Title: Volume by module
Description: Thirty-day ticket creation counts with success/failure breakdown per source module.

SELECT 
    SourceModule,
    COUNT(*) AS total_requests,
    SUM(CASE WHEN StatusCode IN (200, 201) THEN 1 ELSE 0 END) AS successful,
    SUM(CASE WHEN StatusCode NOT IN (200, 201) OR StatusCode IS NULL THEN 1 ELSE 0 END) AS failed
FROM Jira.RequestLog
WHERE CreatedDate >= DATEADD(DAY, -30, GETDATE())
GROUP BY SourceModule
ORDER BY total_requests DESC;

### query #10  [metadata_id: 1891]
Title: Standard deduplication pattern
Description: Calling modules should check this table before queuing to prevent duplicate tickets

IF NOT EXISTS (
    SELECT 1 FROM Jira.RequestLog
    WHERE Trigger_Type = @TriggerType
      AND Trigger_Value = @TriggerValue
      AND StatusCode = 201
      AND TicketKey IS NOT NULL
      AND TicketKey != 'Email'
)
BEGIN
    EXEC Jira.sp_QueueTicket ...
END

### relationship_note #1  [metadata_id: 1925]
Title: Jira.TicketQueue

QueueID links log entries back to the original queue row. No FK constraint exists but the column is present for tracing. Multiple RequestLog rows may reference the same QueueID when retries generate additional API calls.

### description / CreatedBy #11  [metadata_id: 496]

Process or user that created this log entry

### description / CreatedDate #10  [metadata_id: 495]

When this log entry was created

### description / Jira_Assignee #14  [metadata_id: 499]

Assigned user if specified

### description / LogID #1  [metadata_id: 486]

Unique identifier for this log entry

### description / ProjectKey #5  [metadata_id: 490]

Jira project key.

### description / RequestType #4  [metadata_id: 489]

Request category. Mirrors the caller-supplied trigger type on a logged API interaction, or QueueInsertFailed when the queue insert fails.

### description / ResponseMessage #9  [metadata_id: 494]

Full API response or error message

### description / ServiceName #3  [metadata_id: 488]

Service name; always 'Jira' for this module.

### description / SourceModule #2  [metadata_id: 487]

Module that originated the request.

### description / StatusCode #8  [metadata_id: 493]

HTTP status code: 201=success, 400/401/500=errors, -99=queue failure

### status_value / StatusCode #10  [metadata_id: 1881]
Title: 201

Created — ticket exists in Jira

### status_value / StatusCode #11  [metadata_id: 1882]
Title: 400

Bad Request — check custom field IDs and required fields

### status_value / StatusCode #12  [metadata_id: 1883]
Title: 401

Unauthorized — verify credentials in dbo.Credentials

### status_value / StatusCode #13  [metadata_id: 1884]
Title: 403

Forbidden — check user permissions in Jira project

### status_value / StatusCode #14  [metadata_id: 1885]
Title: 404

Not Found — verify ProjectKey and IssueType exist in Jira

### status_value / StatusCode #15  [metadata_id: 1886]
Title: 500+

Server Error — Jira-side issue, retry later

### status_value / StatusCode #16  [metadata_id: 1887]
Title: -99

Queue insert failed — check sp_QueueTicket error in ResponseMessage

### description / Summary #6  [metadata_id: 491]

Ticket summary/title

### description / TicketKey #7  [metadata_id: 492]

Jira ticket key returned when the ticket is created; NULL when no ticket was created.

### status_value / TicketKey #20  [metadata_id: 1888]
Title: Actual Jira ticket key

Ticket created successfully in Jira; the column holds the returned Jira ticket key.

### status_value / TicketKey #22  [metadata_id: 1890]
Title: NULL

API call failed — no ticket or email created

### description / Trigger_Type #12  [metadata_id: 497]

Category used for deduplication lookups; typically a <Module>_<Condition> pattern.

### description / Trigger_Value #13  [metadata_id: 498]

Specific instance value that pairs with the trigger category to form the deduplication key.

## sp_QueueTicket (Procedure)

### category #0  [metadata_id: 1700]

Jira

### data_flow #0  [metadata_id: 1835]

Open entry point that any process with EXECUTE permission can call to queue a Jira ticket request, including external, non-xFACts callers. Inserts one row into Jira.TicketQueue with Pending status. The INSERT fires TR_Jira_TicketQueue_QueueDepth, which signals the orchestrator to launch the processor. On INSERT failure, catches the error and logs directly to Jira.RequestLog with StatusCode = -99 and RequestType = 'QueueInsertFailed'.

### description #0  [metadata_id: 64]

Queue procedure that inserts Jira ticket requests into TicketQueue for asynchronous processing by the PowerShell processor.

### design_note #1  [metadata_id: 1836]
Title: Error-Resilient Queuing

Wraps the queue INSERT in TRY/CATCH. On failure, logs the error to Jira.RequestLog so there is always a trace of the attempt even when the queue INSERT itself fails. The CATCH block has its own nested TRY/CATCH to handle the unlikely case where the RequestLog INSERT also fails.

### design_note #2  [metadata_id: 1837]
Title: Generic Custom Field Mapping

Accepts up to three custom fields and one cascading select field via ID/value parameter pairs. This enables callers to target any Jira custom field by ID without requiring schema changes to the queue table when new Jira fields are introduced.

### module #0  [metadata_id: 1596]

Jira

### query #1  [metadata_id: 1892]
Title: Basic ticket
Description: Minimal required parameters

EXEC Jira.sp_QueueTicket
    @SourceModule = '<source module>',
    @ProjectKey   = '<project key>',
    @Summary      = '<ticket summary>',
    @Description  = '<ticket description>';

### query #2  [metadata_id: 1893]
Title: Full example with custom fields
Description: All parameters including cascading select and custom fields

EXEC Jira.sp_QueueTicket
    @SourceModule              = 'BatchOps',
    @ProjectKey                = 'SD',
    @Summary                   = 'New Business Batch Upload Failed: ABC123',
    @Description               = @ticket_description,
    @IssueType                 = 'Issue',
    @Priority                  = 'Highest',
    @EmailRecipients           = 'ops-team@example.com',
    @CascadingField_ID         = 'customfield_18401',
    @CascadingField_ParentValue = 'File Processing',
    @CascadingField_ChildValue = 'Upload Failure',
    @CustomField_ID            = 'customfield_10305',
    @CustomField_Value         = 'FAC INFORMATION TECHNOLOGY',
    @CustomField2_ID           = 'customfield_10009',
    @CustomField2_Value        = 'sd/1b77b626-3ad4-4bee-8727-abc18b68c5fa',
    @DueDate                   = @DueDate,
    @TriggerType               = 'NB_UploadFailed',
    @TriggerValue              = '45678';

### relationship_note #1  [metadata_id: 1838]
Title: Jira.TicketQueue

Primary INSERT target. This is the main entry point for queuing Jira ticket requests, open to any process with EXECUTE permission, including external, non-xFACts callers.

### relationship_note #2  [metadata_id: 1839]
Title: Jira.RequestLog

Fallback write target on INSERT failure. Logs queue failures directly with StatusCode = -99 so failed attempts are always visible.

## TicketQueue (Table)

### category #0  [metadata_id: 1701]

Jira

### data_flow #0  [metadata_id: 1897]

Tickets enter via Jira.sp_QueueTicket or by direct INSERT. TR_Jira_TicketQueue_QueueDepth fires on INSERT, incrementing running_count in Orchestrator.ProcessRegistry to signal the orchestrator. Process-JiraTicketQueue.ps1 claims Pending rows (TicketStatus = 'Pending' AND RetryCount < MaxRetries), retrieves Jira credentials from dbo.Credentials via two-tier passphrase decryption (master passphrase from GlobalConfig), creates tickets via Jira REST API, and updates TicketStatus to Success or Failed with the returned TicketKey. On success the script performs a GET to retrieve the assigned user. Each API interaction is logged to Jira.RequestLog. When max retries are exhausted and EmailRecipients is populated, the script sends a fallback email via Database Mail and sets TicketStatus to EmailSent.

### description #0  [metadata_id: 52]

Queue table for pending ticket requests awaiting PowerShell processing. Records remain after processing for audit and troubleshooting.

### design_note #1  [metadata_id: 1898]
Title: Queue-Based Decoupling

Same pattern as Teams: calling modules insert and continue without waiting for Jira API responses. Ticket creation latency does not affect the calling process execution time.

### design_note #2  [metadata_id: 1899]
Title: Email Fallback

When Jira API calls fail after all retry attempts, the script sends a fallback email via Database Mail containing the ticket details for manual creation. Requires EmailRecipients to be populated on the queue row. TicketStatus is set to EmailSent as a terminal status.

### design_note #3  [metadata_id: 1900]
Title: Generic Custom Field Support

Up to three arbitrary Jira custom fields plus one cascading select field can be specified per ticket. Field IDs and values are stored in the queue and mapped into the Jira API payload at creation time. This avoids hardcoding Jira field schemas into the table structure.

### design_note #4  [metadata_id: 1901]
Title: Assignee Retrieval

After successful ticket creation, the script performs a separate GET request to retrieve the assignee display name from Jira. This captures the actual assignee (which may differ from the requested assignee due to Jira automation rules) and logs it to RequestLog.

### design_note #5  [metadata_id: 1902]
Title: HttpWebRequest for Auth Bypass

Uses System.Net.HttpWebRequest instead of Invoke-RestMethod because Jira returns WWW-Authenticate: Negotiate, causing PowerShell to attempt Windows integrated auth instead of honoring the Basic auth header.

### module #0  [metadata_id: 1597]

Jira

### query #1  [metadata_id: 1912]
Title: Pending tickets
Description: Shows tickets awaiting processing with wait time, source module, and retry count.

SELECT 
    QueueID,
    SourceModule,
    ProjectKey,
    Summary,
    TicketPriority,
    RetryCount,
    RequestedDate,
    DATEDIFF(MINUTE, RequestedDate, GETDATE()) AS minutes_waiting
FROM Jira.TicketQueue
WHERE TicketStatus = 'Pending'
ORDER BY RequestedDate;

### query #2  [metadata_id: 1913]
Title: Failed tickets
Description: Shows failed tickets with error details and retry counts for troubleshooting.

SELECT 
    QueueID,
    SourceModule,
    ProjectKey,
    Summary,
    TicketStatus,
    RetryCount,
    StatusCode,
    ResponseMessage,
    RequestedDate,
    ProcessedDate
FROM Jira.TicketQueue
WHERE TicketStatus IN ('Failed', 'EmailSent')
ORDER BY ProcessedDate DESC;

### query #3  [metadata_id: 1914]
Title: Recent processing results
Description: Last 20 processed tickets showing source, status, ticket key, and timing.

SELECT TOP 20
    QueueID,
    SourceModule,
    Summary,
    TicketStatus,
    TicketKey,
    RequestedDate,
    ProcessedDate
FROM Jira.TicketQueue
WHERE ProcessedDate IS NOT NULL
ORDER BY ProcessedDate DESC;

### relationship_note #1  [metadata_id: 1915]
Title: Jira.RequestLog

Each API interaction (success or failure) creates a RequestLog entry. No FK constraint but QueueID is stored in RequestLog for tracing back to the original queue row.

### relationship_note #2  [metadata_id: 1916]
Title: Orchestrator.ProcessRegistry

TR_Jira_TicketQueue_QueueDepth increments running_count on INSERT, signaling the orchestrator engine to launch Process-JiraTicketQueue.ps1 on its next heartbeat.

### relationship_note #3  [metadata_id: 1917]
Title: dbo.Credentials

The processor retrieves Jira API credentials (URL, username, password) from dbo.Credentials using two-tier passphrase decryption. The master passphrase is stored in dbo.GlobalConfig.

### description / Assignee #8  [metadata_id: 389]

Jira username to assign ticket to

### description / CascadingField_ChildValue #11  [metadata_id: 392]

Child value for cascading select

### description / CascadingField_ID #9  [metadata_id: 390]

Field ID for the cascading select.

### description / CascadingField_ParentValue #10  [metadata_id: 391]

Parent value for cascading select

### description / CustomField_ID #12  [metadata_id: 393]

First generic custom field ID

### description / CustomField_Value #13  [metadata_id: 394]

First generic custom field value

### description / CustomField2_ID #14  [metadata_id: 395]

Second generic custom field ID

### description / CustomField2_Value #15  [metadata_id: 396]

Second generic custom field value

### description / CustomField3_ID #16  [metadata_id: 397]

Third generic custom field ID

### description / CustomField3_Value #17  [metadata_id: 398]

Third generic custom field value

### description / DueDate #18  [metadata_id: 399]

Ticket due date

### description / EmailRecipients #21  [metadata_id: 402]

Semicolon-separated email addresses for fallback if API fails

### description / IssueType #6  [metadata_id: 387]

Jira issue type.

### description / LastRetryDate #29  [metadata_id: 410]

When last retry was attempted

### description / ProcessedDate #23  [metadata_id: 404]

When PowerShell processed this entry

### description / ProjectKey #3  [metadata_id: 384]

Jira project key.

### description / QueueID #1  [metadata_id: 382]

Unique identifier for this queue entry

### description / RequestedDate #22  [metadata_id: 403]

When ticket was queued

### description / ResponseMessage #26  [metadata_id: 407]

API response or error message

### description / RetryCount #28  [metadata_id: 409]

Number of retry attempts

### description / SourceModule #2  [metadata_id: 383]

Module that queued the ticket.

### description / StatusCode #25  [metadata_id: 406]

HTTP status code returned by the Jira API.

### description / Summary #4  [metadata_id: 385]

Ticket title/summary

### description / TicketDescription #5  [metadata_id: 386]

Full ticket description body

### description / TicketKey #24  [metadata_id: 405]

Jira ticket key assigned when the ticket is created.

### description / TicketPriority #7  [metadata_id: 388]

Priority: Highest, High, Medium, Low, Lowest

### status_value / TicketPriority #1  [metadata_id: 1907]
Title: Highest

Most urgent tickets requiring immediate attention.

### status_value / TicketPriority #2  [metadata_id: 1908]
Title: High

Default priority set by sp_QueueTicket. Used for most automated ticket creation.

### status_value / TicketPriority #3  [metadata_id: 1909]
Title: Medium

Standard priority.

### status_value / TicketPriority #4  [metadata_id: 1910]
Title: Low

Lower priority items.

### status_value / TicketPriority #5  [metadata_id: 1911]
Title: Lowest

Least urgent tickets.

### description / TicketStatus #27  [metadata_id: 408]

Current status: Pending, Success, Failed, EmailSent.

### status_value / TicketStatus #1  [metadata_id: 1903]
Title: Pending

Waiting for processor pickup. Set on INSERT as the default value, and a retryable failure returns the row to this status for the next processor cycle.

### status_value / TicketStatus #2  [metadata_id: 1904]
Title: Success

Jira ticket created successfully; TicketKey is populated with the returned Jira issue key.

### status_value / TicketStatus #3  [metadata_id: 1905]
Title: Failed

Jira API call failed and all retry attempts have been exhausted with no fallback email sent (EmailRecipients not populated). RetryCount has reached MaxRetries and ResponseMessage holds the last error. Terminal status.

### status_value / TicketStatus #4  [metadata_id: 1906]
Title: EmailSent

Max retries exhausted and fallback email sent via Database Mail. Terminal status indicating the ticket must be created manually from the email.

### description / TriggerType #19  [metadata_id: 400]

Category used for deduplication; typically a <Module>_<Condition> pattern.

### description / TriggerValue #20  [metadata_id: 401]

Specific instance value that pairs with the trigger category to form the deduplication key.

## TR_Jira_TicketQueue_QueueDepth (Trigger)

### category #0  [metadata_id: 1702]

Jira

### description #0  [metadata_id: 55]

INSERT trigger on Jira.TicketQueue that signals the Orchestrator v2 engine when tickets are ready for processing. Enables queue-driven execution of Process-JiraTicketQueue.

### design_note #1  [metadata_id: 1840]
Title: Queue-Driven Orchestrator Signal

INSERT trigger that increments running_count in Orchestrator.ProcessRegistry for Process-JiraTicketQueue. Only updates rows where run_mode = 2 (queue-driven), enabling the orchestrator to launch the processor on-demand rather than on a fixed polling schedule. Counts the number of inserted rows to accurately track queue depth across multi-row inserts.

### module #0  [metadata_id: 1598]

Jira

### query #1  [metadata_id: 1894]
Title: Verify trigger is enabled
Description: Check if the trigger is active

SELECT name, is_disabled
FROM sys.triggers
WHERE name = 'TR_Jira_TicketQueue_QueueDepth';

### query #2  [metadata_id: 1895]
Title: Verify ProcessRegistry entry
Description: Confirm the orchestrator entry exists and check run mode

SELECT process_name, run_mode, running_count
FROM Orchestrator.ProcessRegistry
WHERE process_name = 'Process-JiraTicketQueue';

### query #3  [metadata_id: 1896]
Title: Re-sync running_count
Description: After re-enabling a disabled trigger, manually set running_count for any pending items

UPDATE Orchestrator.ProcessRegistry
SET running_count = (SELECT COUNT(*) FROM Jira.TicketQueue WHERE TicketStatus = 'Pending')
WHERE process_name = 'Process-JiraTicketQueue';

### relationship_note #1  [metadata_id: 1841]
Title: Orchestrator.ProcessRegistry

Directly updates ProcessRegistry.running_count to signal queue depth. The orchestrator engine checks running_count on each heartbeat and launches the processor when count > 0.

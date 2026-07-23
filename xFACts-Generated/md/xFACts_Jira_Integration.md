# Jira Integration

*Turning “something happened” into “SD-12345 is assigned to you, due Friday”*

Jira Integration is the sibling to Teams Integration. Where Teams tells you something happened, Jira makes sure someone *owns* it. Same queue-driven architecture, same open-door policy — any process that can call a stored procedure can create a Jira ticket. Teams is the megaphone. Jira is the clipboard with your name on it.






The Problem

Notifications are great. You saw the alert. You acknowledged it mentally. You maybe even said “I should look into that” out loud, which as we all know is the professional equivalent of “this will never get done.”

The gap between *knowing* about an issue and *tracking* it is where things disappear. Alerts don’t have due dates. They don’t have assignees. They don’t show up in sprint reviews. They exist for about three seconds in your consciousness before getting buried under the next message about someone’s lunch plans.

Jira Integration closes that gap. When something needs human intervention *and* a paper trail, it creates an actual ticket — assigned, prioritized, tracked, and impossible to pretend you didn’t see.






How It Works



Module Detects
an Issue
→
Ticket Gets
Queued
→
Processor
Wakes Up
→
Jira Ticket
Created
→
Someone
Owns It Now

From detection to ticket assignment — queue-driven, same pattern as Teams


If you’ve read the Teams Integration page, this should feel familiar. The pattern is identical: a module detects an issue, drops a ticket request into a queue, and moves on. A dedicated processor picks it up, creates the ticket in Jira via the REST API, and writes the resulting ticket key back for tracking. The calling process never waits for API calls or worries about whether Jira is feeling responsive today.

The ticket comes out the other end fully formed — project, summary, description, priority, assignee. It shows up in sprint boards and standup reports. There’s no pretending it doesn’t exist.






Who Uses It

Like Teams, the Jira service is an open door. Any process that can execute a stored procedure can create a ticket. The common thread: automation can’t fix it, someone needs to own it, and there needs to be proof that someone did.

The conditions that earn a ticket share a shape: persistent stalls that need investigation, file delivery or escalation issues that need a human to chase them, batch upload failures, and newly detected configuration that needs setting up. Some callers live outside xFACts entirely — the service doesn’t care who is knocking, only that the caller can execute the stored procedure.






Teams vs. Jira: When to Use Which

Both are shared services. Both use the same queue-driven pattern. Both accept requests from any process. So when do you use one versus the other?



Teams Is For...
Awareness. Something happened and people should know about it. Status updates, health summaries, early warnings. The audience glances at it, acknowledges the situation, and decides whether to act. Most of the time, no action is needed.


Jira Is For...
Accountability. Something happened and someone needs to *do something about it*. The ticket has an assignee, a priority, a due date. It shows up in sprint boards. It doesn’t go away until someone closes it.



Some events trigger both. A critical failure might send a Teams alert for immediate awareness *and* create a Jira ticket for tracking the resolution. The alert says “this is happening right now.” The ticket says “and someone needs to fix it by Friday.”






Safety Nets

Because a missed ticket means work that doesn’t get tracked, which means work that might not get done, the system has layers of protection.

**Deduplication** prevents the same issue from creating five tickets across five monitoring cycles. The condition was reported. One ticket is enough.

**Retry logic** handles transient API failures. If Jira is briefly unreachable, the request is retried right away in a short burst, and if it still won’t go through it stays in the queue and is tried again on later cycles. Failures that retrying can’t fix — bad credentials, a missing project, a malformed field — skip the retries and go straight to the email fallback.

**Email fallback** is the backup parachute. If all retry attempts are exhausted and the ticket still can’t be created, an email goes out with the full ticket details. The ticket might not exist in Jira, but someone knows about the underlying problem. Work doesn’t vanish just because an API had a bad day.






The Bottom Line

Jira Integration turns detection into accountability. The monitoring modules find the problems. Teams tells people about them. Jira makes sure someone *owns* them.

The queue keeps calling processes fast. The deduplication keeps ticket counts sane. The retry logic handles API hiccups. The email fallback makes sure nothing important disappears. And the whole thing is an open service — if your process can call a stored procedure, it can create a tracked, assigned, prioritized ticket without knowing anything about REST APIs or Jira authentication.

Work that gets tracked gets done. Work that doesn’t… well, that’s how things fall through cracks. This module keeps the cracks closed.

---

## Architecture
# Jira Integration Architecture

The narrative page tells you *what* Jira Integration does and *why*. This page tells you *how*. Two tables, one stored procedure, one trigger, and a PowerShell script that wrestles Jira's REST API so your monitoring code doesn't have to.



Schema Overview

Jira Integration is the leanest schema in xFACts. Two tables do all the work — one for the queue, one for the audit trail. The simplicity is deliberate. Jira's API is complex enough; the plumbing on our side doesn't need to be.



The data model is a straight pipeline. `TicketQueue` holds pending and processed ticket requests. `RequestLog` records every API call attempt. Unlike Teams (which has a routing layer), Jira tickets go to one place: the configured Jira project. No routing decisions needed.

| Table | Role | Cardinality |
| --- | --- | --- |
| `TicketQueue` | Ticket request queue | One per ticket request |
| `RequestLog` | API call audit trail | One per API attempt (retries create additional rows) |



Why no routing layer like Teams? Teams alerts go to potentially many channels based on module and category. Jira tickets go to one project with one set of fields. The routing decision was already made when the module chose to queue a ticket instead of (or in addition to) a Teams alert. There's nothing to route — just build and send.







The Queue Lifecycle

The queue lifecycle mirrors Teams Integration almost exactly. Same pattern, same trigger mechanism, same separation of concerns. The module that detects a problem queues the ticket and walks away. PowerShell handles the API paperwork.





sp_QueueTicket
INSERT into
TicketQueue (Pending)

→

Trigger Fires
running_count++
in ProcessRegistry

→

Build Payload
Queue fields →
Jira JSON structure

→

POST to Jira
REST API create
Ticket key returned

→

Log & Update
RequestLog entry
Queue → Success/Failed


Queue-driven execution. On failure, retries span subsequent processor cycles. After max retries, email fallback fires if configured.


Step 1: Ticket Enters the Queue

A caller invokes `Jira.sp_QueueTicket` with the project key, issue type, priority, summary, description, and optional fields like assignee and custom field values. The procedure INSERTs into `TicketQueue` with status **Pending** and returns immediately.

The stored procedure inserts the request with defaults for any optional fields left unspecified — issue type defaults to Task and priority to High. The project key, summary, and description are required; the caller provides those and the proc fills in the rest.

Step 2: The Trigger Signals Demand

`TR_Jira_TicketQueue_QueueDepth` fires on INSERT and increments `running_count` on the Jira processor's `Orchestrator.ProcessRegistry` entry. Identical mechanism to Teams — queue-driven processing with no wasted polling cycles.

Step 3: Build, Send, Record

`Process-JiraTicketQueue.ps1` picks up Pending rows and constructs a Jira-compliant JSON payload for each one. This is where most of the complexity lives — Jira's REST API has specific expectations about field formats, custom field IDs, and cascading select values.

The script POSTs to the Jira issue creation endpoint. On success, the response includes the new ticket key, which is written back to the `TicketKey` column in TicketQueue. The row status updates to **Success**.

Every API call — successful or not — is logged to `RequestLog` with the full request payload, response payload, HTTP status code, and timing.


The ticket key is the receipt. Once `TicketKey` is populated, there's a traceable link from the monitoring event through the queue to a real Jira ticket. Other modules can check this field to know whether a ticket was actually created, not just requested.







Ticket Construction

Jira's API is particular about its JSON format. The PowerShell script translates the flat fields in TicketQueue into the nested JSON structure that Jira expects.

| Queue Field | Jira JSON Path | Notes |
| --- | --- | --- |
| `ProjectKey` | `fields.project.key` | Jira project key |
| `IssueType` | `fields.issuetype.name` | Issue type name |
| `TicketPriority` | `fields.priority.name` | Priority name |
| `Summary` | `fields.summary` | Ticket title |
| `TicketDescription` | `fields.description` | Body text |
| `CascadingField_*` | `fields.customfield_*` | Cascading select: parent + child values |


The cascading select field is the most complex piece. Jira requires a specific nested structure with `value` and `child.value` properties. The queue stores parent and child values separately; the script assembles the correct nesting at build time.


Custom field IDs are environment-specific. The custom field ID for the cascading select is supplied by the caller as a parameter to `sp_QueueTicket` and stored on the queue row, not hardcoded in the script. If Jira's field configuration changes — which happens during upgrades or project reconfigurations — the caller passes the new field ID, with no code change.







Retry & Fallback

A missed Teams alert is annoying. A missed Jira ticket means work doesn't get tracked, which means it might not get done. The retry logic reflects this difference.

When the API call fails, the script increments `RetryCount` and records the failure details in `ResponseMessage`. Each turn first makes a short in-cycle burst — a configurable number of attempts a configurable delay apart; if the whole turn still fails on a transient error, the row stays in **Pending** status for the next processor run. So Jira retries at two levels: a quick burst within one run, then again across processor runs, giving the Jira server time to recover from transient issues.

After the configured number of retry turns (the processor's `MaxRetries` setting) is exhausted — or immediately, when the failure is deterministic, like bad credentials or an invalid field — the row becomes terminal. But that's not the end of the safety net.

Email Fallback

When all retries fail and email recipients are configured, the script sends a fallback email with the ticket details. The ticket doesn't exist in Jira, but someone knows about the underlying problem. The work doesn't vanish just because an API had a bad day.


Two levels of retry. Within a single run, Jira retries a transient failure in a quick burst — the same inline pattern Teams uses. Unlike Teams, Jira then also carries an unresolved ticket across processor runs, because Jira failures are often service-level issues like maintenance or restarts that need longer to clear than a burst allows. Deterministic failures — bad credentials, a missing project, a malformed field — skip retries entirely and go straight to the email fallback, since retrying an identical bad request only delays the alert.







Credential Flow

Jira requires authenticated API access. The script retrieves credentials at startup using the same two-tier encryption pattern as every other xFACts integration.





GlobalConfig
Read master
passphrase

→

Credentials
Decrypt service
passphrase

→

Decrypt Secrets
URL + username
+ API token

→

API Calls
Basic auth header
for all requests

→

Dispose
Credentials fall
out of scope


Two-tier decryption. Nothing cached to disk. Credentials exist in memory only for the duration of the processing batch.


Decrypted credentials exist only in memory for the duration of the processing run. The script retrieves them once at startup, uses them for all API calls in that batch, and lets them fall out of scope when execution completes. Nothing is cached to disk.


Authentication method: HTTP Basic. The Jira Server REST API uses Basic authentication with a username and password (or API token). The credentials are base64-encoded in the Authorization header for each request. This is standard for Jira Server and doesn't require OAuth setup.







Troubleshooting

**“Tickets aren’t being created.”**
Check `Jira.TicketQueue`. Is the request even there? If not, the module never queued it. If it’s stuck in Pending, the processor might not be running — check that `TR_Jira_TicketQueue_QueueDepth` is enabled and verify the processor’s `running_count` in ProcessRegistry.

**“Getting 400 errors.”**
Jira is rejecting the payload. Usually means a custom field ID is wrong, a required field is missing, or a dropdown value doesn’t exist in the allowed list. Jira is very particular. Check the `ResponseMessage` column in RequestLog — Jira’s error messages are actually helpful once you get past the JSON formatting.

**“Getting 401/403 errors.”**
Authentication failed. The API token probably expired. Check `dbo.Credentials` and verify the Jira credentials are still valid. API tokens are like milk, not honey — they expire.

**“Email fallback fired unexpectedly.”**
That means all retry attempts failed across multiple processor runs. The good news: someone got notified. The bad news: the ticket doesn’t exist in Jira. Check the TicketQueue row for error details, fix the underlying issue, and create the ticket manually if it still needs tracking.

**“A ticket was created but has no assignee.”**
The processor does a follow-up GET to Jira to retrieve the assignee after creation. If that call failed, the ticket exists but the assignee field in RequestLog will be NULL. The ticket in Jira may still have an assignee via project auto-assignment rules — xFACts just doesn’t know about it.






How Everything Connects

Like Teams Integration, Jira Integration is a pure service module. It doesn't detect or decide — it creates tickets when asked and reports whether it succeeded.

Internal Flow

| From | To | Relationship |
| --- | --- | --- |
| `TicketQueue` | `RequestLog` | One ticket request → one or more API attempts; `QueueID` is stored for tracing (no FK constraint) |
| `sp_QueueTicket` | `TicketQueue` | Stored procedure INSERTs requests as Pending |
| `TR_Jira_TicketQueue_QueueDepth` | `Orchestrator.ProcessRegistry` | Trigger signals the orchestrator on INSERT |


External Dependencies

| Dependency | Module | Purpose |
| --- | --- | --- |
| `Orchestrator.ProcessRegistry` | Orchestrator | Schedules Process-JiraTicketQueue.ps1 (run_mode = 2, queue-driven) |
| `dbo.GlobalConfig` | Shared Infrastructure | Master passphrase for credential decryption |
| `dbo.Credentials` | Shared Infrastructure | Encrypted Jira API credentials |
| Jira Server | External | REST API ticket creation target |


Who Calls Jira Integration

Jira Integration is an open service. Any process with EXECUTE permission on `sp_QueueTicket` can queue a ticket — xFACts modules and external, non-xFACts processes alike. The triggers share a shape: a condition automation can’t resolve that needs tracked ownership — persistent stalls needing investigation, file delivery or escalation follow-ups, batch upload failures, and newly detected configuration that needs setting up.

---

## Reference

### RequestLog

Permanent audit log of all Jira API interactions including successful ticket creations, failures, and queue insert errors.

**Data Flow:** Process-JiraTicketQueue.ps1 inserts one row per Jira API interaction (both successes and failures). sp_QueueTicket also writes directly to RequestLog when a queue INSERT fails (RequestType = 'QueueInsertFailed', StatusCode = -99). Calling modules query this table for deduplication before queuing new tickets, checking Trigger_Type and Trigger_Value with a successful StatusCode to avoid creating duplicate Jira tickets for the same condition.

**Append-Only Audit Trail:** [sort:1] Rows are never updated or deleted. Each API interaction generates a separate entry for complete ticket creation history.

**Queue Failure Logging:** [sort:2] sp_QueueTicket catches INSERT failures and logs them directly to RequestLog with StatusCode = -99 and RequestType = 'QueueInsertFailed'. This ensures visibility even when the queue INSERT itself fails.

**Deduplication Source:** [sort:3] Same pattern as Teams: calling modules query RequestLog before queuing tickets to check if a successful creation already exists for the same Trigger_Type and Trigger_Value combination. Prevents duplicate Jira tickets across orchestrator cycles.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| LogID (IDENTITY) | int | No | IDENTITY | Unique identifier for this log entry |
| SourceModule | varchar(50) | Yes | — | Module that originated the request. |
| ServiceName | varchar(50) | Yes | — | Service name; always 'Jira' for this module. |
| RequestType | varchar(50) | Yes | — | Request category. Mirrors the caller-supplied trigger type on a logged API interaction, or QueueInsertFailed when the queue insert fails. |
| ProjectKey | varchar(20) | Yes | — | Jira project key. |
| Summary | nvarchar(1000) | Yes | — | Ticket summary/title |
| TicketKey | varchar(50) | Yes | — | Jira ticket key returned when the ticket is created; NULL when no ticket was created. |
| StatusCode | int | Yes | — | HTTP status code: 201=success, 400/401/500=errors, -99=queue failure |
| ResponseMessage | nvarchar(MAX) | Yes | — | Full API response or error message |
| CreatedDate | datetime | Yes | getdate() | When this log entry was created |
| CreatedBy | varchar(100) | Yes | — | Process or user that created this log entry |
| Trigger_Type | varchar(50) | Yes | — | Category used for deduplication lookups; typically a <Module>_<Condition> pattern. |
| Trigger_Value | varchar(200) | Yes | — | Specific instance value that pairs with the trigger category to form the deduplication key. |
| Jira_Assignee | varchar(100) | Yes | — | Assigned user if specified |

  - **PK_Jira_RequestLog** (CLUSTERED): LogID -- PRIMARY KEY
  - **IX_Jira_RequestLog_CreatedDate** (NONCLUSTERED): CreatedDate [includes: ServiceName, TicketKey, StatusCode]
  - **IX_Jira_RequestLog_SourceModule** (NONCLUSTERED): SourceModule, CreatedDate [includes: TicketKey, StatusCode]
  - **IX_Jira_RequestLog_TriggerType_TriggerValue** (NONCLUSTERED): Trigger_Type, Trigger_Value [includes: StatusCode, TicketKey]

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| StatusCode | 201 | Created — ticket exists in Jira | 10 |
| StatusCode | 400 | Bad Request — check custom field IDs and required fields | 11 |
| StatusCode | 401 | Unauthorized — verify credentials in dbo.Credentials | 12 |
| StatusCode | 403 | Forbidden — check user permissions in Jira project | 13 |
| StatusCode | 404 | Not Found — verify ProjectKey and IssueType exist in Jira | 14 |
| StatusCode | 500+ | Server Error — Jira-side issue, retry later | 15 |
| StatusCode | -99 | Queue insert failed — check sp_QueueTicket error in ResponseMessage | 16 |
| TicketKey | Actual Jira ticket key | Ticket created successfully in Jira; the column holds the returned Jira ticket key. | 20 |
| TicketKey | NULL | API call failed — no ticket or email created | 22 |

**Recent activity** [sort:1] -- Last 20 API interactions showing source module, ticket key, status code, and timestamp.

```sql
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
```

**Failed API calls** [sort:2] -- All entries with non-success status codes for troubleshooting.

```sql
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
```

**Volume by module** [sort:3] -- Thirty-day ticket creation counts with success/failure breakdown per source module.

```sql
SELECT 
    SourceModule,
    COUNT(*) AS total_requests,
    SUM(CASE WHEN StatusCode IN (200, 201) THEN 1 ELSE 0 END) AS successful,
    SUM(CASE WHEN StatusCode NOT IN (200, 201) OR StatusCode IS NULL THEN 1 ELSE 0 END) AS failed
FROM Jira.RequestLog
WHERE CreatedDate >= DATEADD(DAY, -30, GETDATE())
GROUP BY SourceModule
ORDER BY total_requests DESC;
```

**Standard deduplication pattern** [sort:10] -- Calling modules should check this table before queuing to prevent duplicate tickets

```sql
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
```

  - **Jira.TicketQueue**: [sort:1] QueueID links log entries back to the original queue row. No FK constraint exists but the column is present for tracing. Multiple RequestLog rows may reference the same QueueID when retries generate additional API calls.


### TicketQueue

Queue table for pending ticket requests awaiting PowerShell processing. Records remain after processing for audit and troubleshooting.

**Data Flow:** Tickets enter via Jira.sp_QueueTicket or by direct INSERT. TR_Jira_TicketQueue_QueueDepth fires on INSERT, incrementing running_count in Orchestrator.ProcessRegistry to signal the orchestrator. Process-JiraTicketQueue.ps1 claims Pending rows (TicketStatus = 'Pending' AND RetryCount < MaxRetries), retrieves Jira credentials from dbo.Credentials via two-tier passphrase decryption (master passphrase from GlobalConfig), creates tickets via Jira REST API, and sets TicketStatus to Success with the returned TicketKey, leaves it Pending for a later cycle on a transient failure, or sets a terminal status once retries are exhausted or a deterministic failure occurs. On success the script performs a GET to retrieve the assigned user. Each API interaction is logged to Jira.RequestLog. When retries are exhausted or a deterministic failure occurs and EmailRecipients is populated, the script sends a fallback email via Database Mail and sets TicketStatus to EmailSent.

**Queue-Based Decoupling:** [sort:1] Same pattern as Teams: calling modules insert and continue without waiting for Jira API responses. Ticket creation latency does not affect the calling process execution time.

**Email Fallback:** [sort:2] When Jira API calls fail after all retry attempts, the script sends a fallback email via Database Mail containing the ticket details for manual creation. Requires EmailRecipients to be populated on the queue row. TicketStatus is set to EmailSent as a terminal status.

**Generic Custom Field Support:** [sort:3] Up to three arbitrary Jira custom fields plus one cascading select field can be specified per ticket. Field IDs and values are stored in the queue and mapped into the Jira API payload at creation time. This avoids hardcoding Jira field schemas into the table structure.

**Assignee Retrieval:** [sort:4] After successful ticket creation, the script performs a separate GET request to retrieve the assignee display name from Jira. This captures the actual assignee (which may differ from the requested assignee due to Jira automation rules) and logs it to RequestLog.

**HttpWebRequest for Auth Bypass:** [sort:5] Uses System.Net.HttpWebRequest instead of Invoke-RestMethod because Jira returns WWW-Authenticate: Negotiate, causing PowerShell to attempt Windows integrated auth instead of honoring the Basic auth header.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| QueueID (IDENTITY) | int | No | IDENTITY | Unique identifier for this queue entry |
| SourceModule | varchar(50) | No | — | Module that queued the ticket. |
| ProjectKey | varchar(20) | No | — | Jira project key. |
| Summary | nvarchar(1000) | No | — | Ticket title/summary |
| TicketDescription | nvarchar(MAX) | No | — | Full ticket description body |
| IssueType | varchar(50) | Yes | 'Task' | Jira issue type. |
| TicketPriority | varchar(20) | Yes | 'High' | Priority: Highest, High, Medium, Low, Lowest |
| Assignee | varchar(100) | Yes | — | Jira username to assign ticket to |
| CascadingField_ID | varchar(50) | Yes | — | Field ID for the cascading select. |
| CascadingField_ParentValue | varchar(500) | Yes | — | Parent value for cascading select |
| CascadingField_ChildValue | varchar(500) | Yes | — | Child value for cascading select |
| CustomField_ID | varchar(50) | Yes | — | First generic custom field ID |
| CustomField_Value | varchar(500) | Yes | — | First generic custom field value |
| CustomField2_ID | varchar(50) | Yes | — | Second generic custom field ID |
| CustomField2_Value | varchar(500) | Yes | — | Second generic custom field value |
| CustomField3_ID | varchar(50) | Yes | — | Third generic custom field ID |
| CustomField3_Value | varchar(500) | Yes | — | Third generic custom field value |
| DueDate | date | Yes | — | Ticket due date |
| TriggerType | varchar(50) | Yes | — | Category used for deduplication; typically a <Module>_<Condition> pattern. |
| TriggerValue | varchar(200) | Yes | — | Specific instance value that pairs with the trigger category to form the deduplication key. |
| EmailRecipients | varchar(4000) | Yes | — | Semicolon-separated email addresses for fallback if API fails |
| RequestedDate | datetime | Yes | getdate() | When ticket was queued |
| ProcessedDate | datetime | Yes | — | When PowerShell processed this entry |
| TicketKey | varchar(50) | Yes | — | Jira ticket key assigned when the ticket is created. |
| StatusCode | int | Yes | — | HTTP status code returned by the Jira API. |
| ResponseMessage | nvarchar(MAX) | Yes | — | API response or error message |
| TicketStatus | varchar(20) | Yes | 'Pending' | Current status: Pending, Success, Failed, EmailSent. |
| RetryCount | int | Yes | 0 | Number of retry attempts |
| LastRetryDate | datetime | Yes | — | When last retry was attempted |

  - **PK_Jira_TicketQueue** (CLUSTERED): QueueID -- PRIMARY KEY
  - **IX_Jira_TicketQueue_SourceModule** (NONCLUSTERED): SourceModule, RequestedDate [includes: TicketStatus, TicketKey]
  - **IX_Jira_TicketQueue_Status_RequestedDate** (NONCLUSTERED): TicketStatus, RequestedDate
  - **IX_Jira_TicketQueue_TriggerType_TriggerValue** (NONCLUSTERED): TriggerType, TriggerValue [includes: TicketStatus, TicketKey]

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| TicketStatus | Pending | Waiting for processor pickup. Set on INSERT as the default value, and a retryable failure returns the row to this status for the next processor cycle. | 1 |
| TicketPriority | Highest | Most urgent tickets requiring immediate attention. | 1 |
| TicketPriority | High | Default priority set by sp_QueueTicket. Used for most automated ticket creation. | 2 |
| TicketStatus | Success | Jira ticket created successfully; TicketKey is populated with the returned Jira issue key. | 2 |
| TicketStatus | Failed | Jira API call failed and all retry attempts have been exhausted with no fallback email sent (EmailRecipients not populated). RetryCount has reached MaxRetries and ResponseMessage holds the last error. Terminal status. | 3 |
| TicketPriority | Medium | Standard priority. | 3 |
| TicketPriority | Low | Lower priority items. | 4 |
| TicketStatus | EmailSent | Max retries exhausted and fallback email sent via Database Mail. Terminal status indicating the ticket must be created manually from the email. | 4 |
| TicketPriority | Lowest | Least urgent tickets. | 5 |

**Pending tickets** [sort:1] -- Shows tickets awaiting processing with wait time, source module, and retry count.

```sql
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
```

**Failed tickets** [sort:2] -- Shows failed tickets with error details and retry counts for troubleshooting.

```sql
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
```

**Recent processing results** [sort:3] -- Last 20 processed tickets showing source, status, ticket key, and timing.

```sql
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
```

  - **Jira.RequestLog**: [sort:1] Each API interaction (success or failure) creates a RequestLog entry. No FK constraint but QueueID is stored in RequestLog for tracing back to the original queue row.
  - **Orchestrator.ProcessRegistry**: [sort:2] TR_Jira_TicketQueue_QueueDepth increments running_count on INSERT, signaling the orchestrator engine to launch Process-JiraTicketQueue.ps1 on its next heartbeat.
  - **dbo.Credentials**: [sort:3] The processor retrieves Jira API credentials (URL, username, password) from dbo.Credentials using two-tier passphrase decryption. The master passphrase is stored in dbo.GlobalConfig.


### sp_QueueTicket

Queue procedure that inserts Jira ticket requests into TicketQueue for asynchronous processing by the PowerShell processor.

**Data Flow:** Open entry point that any process with EXECUTE permission can call to queue a Jira ticket request, including external, non-xFACts callers. Inserts one row into Jira.TicketQueue with Pending status. The INSERT fires TR_Jira_TicketQueue_QueueDepth, which signals the orchestrator to launch the processor. On INSERT failure, catches the error and logs directly to Jira.RequestLog with StatusCode = -99 and RequestType = 'QueueInsertFailed'.

**Error-Resilient Queuing:** [sort:1] Wraps the queue INSERT in TRY/CATCH. On failure, logs the error to Jira.RequestLog so there is always a trace of the attempt even when the queue INSERT itself fails. The CATCH block has its own nested TRY/CATCH to handle the unlikely case where the RequestLog INSERT also fails.

**Generic Custom Field Mapping:** [sort:2] Accepts up to three custom fields and one cascading select field via ID/value parameter pairs. This enables callers to target any Jira custom field by ID without requiring schema changes to the queue table when new Jira fields are introduced.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @SourceModule | varchar(50) | IN |  |  |
| @ProjectKey | varchar(20) | IN |  |  |
| @Summary | nvarchar(1000) | IN |  |  |
| @Description | nvarchar(MAX) | IN |  |  |
| @IssueType | varchar(50) | IN |  |  |
| @Priority | varchar(20) | IN |  |  |
| @Assignee | varchar(100) | IN |  |  |
| @EmailRecipients | varchar(4000) | IN |  |  |
| @CascadingField_ID | varchar(50) | IN |  |  |
| @CascadingField_ParentValue | varchar(500) | IN |  |  |
| @CascadingField_ChildValue | varchar(500) | IN |  |  |
| @CustomField_ID | varchar(50) | IN |  |  |
| @CustomField_Value | varchar(500) | IN |  |  |
| @CustomField2_ID | varchar(50) | IN |  |  |
| @CustomField2_Value | varchar(500) | IN |  |  |
| @CustomField3_ID | varchar(50) | IN |  |  |
| @CustomField3_Value | varchar(500) | IN |  |  |
| @DueDate | date | IN |  |  |
| @TriggerType | varchar(50) | IN |  |  |
| @TriggerValue | varchar(200) | IN |  |  |

  - **Jira.TicketQueue**: [sort:1] Primary INSERT target. This is the main entry point for queuing Jira ticket requests, open to any process with EXECUTE permission, including external, non-xFACts callers.
  - **Jira.RequestLog**: [sort:2] Fallback write target on INSERT failure. Logs queue failures directly with StatusCode = -99 so failed attempts are always visible.


### TR_Jira_TicketQueue_QueueDepth

INSERT trigger on Jira.TicketQueue that signals the Orchestrator v2 engine when tickets are ready for processing. Enables queue-driven execution of Process-JiraTicketQueue.

**Queue-Driven Orchestrator Signal:** [sort:1] INSERT trigger that increments running_count in Orchestrator.ProcessRegistry for Process-JiraTicketQueue. Only updates rows where run_mode = 2 (queue-driven), enabling the orchestrator to launch the processor on-demand rather than on a fixed polling schedule. Counts the number of inserted rows to accurately track queue depth across multi-row inserts.

  - **Orchestrator.ProcessRegistry**: [sort:1] Directly updates ProcessRegistry.running_count to signal queue depth. The orchestrator engine checks running_count on each heartbeat and launches the processor when count > 0.


### Process-JiraTicketQueue.ps1

Queue processor that creates Jira tickets via REST API. Claims Pending tickets from TicketQueue, authenticates using encrypted credentials from dbo.Credentials, creates tickets in Jira, retrieves assignee information, updates queue status, and logs results to RequestLog. Sends email fallback via Database Mail when API calls fail after all retry attempts.

**Data Flow:** Launched by the orchestrator when TR_Jira_TicketQueue_QueueDepth signals queue depth > 0. Retrieves master passphrase from dbo.GlobalConfig, uses two-tier decryption against dbo.Credentials to obtain Jira URL, username, and password. Reads Pending tickets from Jira.TicketQueue (TicketStatus = 'Pending' AND RetryCount < MaxRetries), builds JSON payload mapping queue columns to Jira REST API fields (including custom fields and cascading selects), and creates tickets via POST to /rest/api/2/issue. On success, performs a GET to retrieve the actual assignee, updates TicketQueue with TicketKey and Success status, and logs to Jira.RequestLog. Each transient failure is retried in-cycle up to BurstAttempts times; if the whole turn still fails, RetryCount is incremented and the row is left Pending for a later cycle, up to MaxRetries turns. Deterministic failures (auth, not-found, bad-request) skip retries. When retries are exhausted or a deterministic failure occurs, and EmailRecipients is populated, sends a fallback email via Database Mail and sets TicketStatus to EmailSent (or Failed when no recipients).

**Queue-Driven Execution:** [sort:1] Runs as a queue-driven process (run_mode = 2) in the orchestrator. Only launched when tickets are waiting, not on a fixed polling schedule.

**HttpWebRequest for Auth Bypass:** [sort:2] Uses System.Net.HttpWebRequest instead of Invoke-RestMethod because Jira returns WWW-Authenticate: Negotiate in the response headers. PowerShell Invoke-RestMethod interprets this as a request for Windows integrated auth and attempts Negotiate authentication instead of using the explicitly provided Basic auth header. HttpWebRequest with PreAuthenticate = true forces Basic auth on the first request.

**Two-Tier Credential Decryption:** [sort:3] Credentials are stored encrypted in dbo.Credentials. The master passphrase (from GlobalConfig) decrypts a service-specific passphrase, which in turn decrypts the actual Jira URL, username, and password. No secrets are stored in the script or on disk.

**Email Fallback on API Failure:** [sort:4] When Jira API calls fail after all retry attempts, or immediately on a deterministic failure such as bad credentials or an invalid field, the script can send a fallback email via Database Mail containing the ticket summary, description, and error details. This ensures the request is not silently lost even when the ticket cannot be created. Requires EmailRecipients to be populated on the queue row.

**Orchestrator v2 Integration:** [sort:5] Accepts TaskId and ProcessId parameters from the orchestrator engine. Calls Complete-OrchestratorTask on completion with status, duration, and a summary of processed/created/failed/email counts. Supports -Execute safeguard (preview mode by default).

  - **Jira.TicketQueue**: [sort:1] Primary data source. Reads Pending rows, updates TicketStatus, TicketKey, StatusCode, ResponseMessage, RetryCount, ProcessedDate, and LastRetryDate after each API interaction.
  - **Jira.RequestLog**: [sort:2] Write target. Inserts one row per API interaction (success or failure) for complete audit trail.
  - **dbo.Credentials**: [sort:3] Reads encrypted Jira API credentials (URL, username, password) using two-tier passphrase decryption.
  - **dbo.GlobalConfig**: [sort:4] Reads the master passphrase used for credential decryption.



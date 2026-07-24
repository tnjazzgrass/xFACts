# Teams Integration

*The part that actually tells you when something happens*

Teams Integration is a shared service used by every module in xFACts that needs to tell someone about something. It’s not a monitoring module itself — it’s the delivery system. Modules detect problems; Teams delivers the news. Whether you mute the channel is between you and your dog.






The Problem

SQL Server is *amazing* at noticing things. Jobs failing. Disks filling up. Processes stalling at 1:30 AM while you’re blissfully asleep dreaming about being literally anywhere else.

What SQL Server is *terrible* at? Telling anyone about it. It’s like having a smoke detector that just… takes notes. “Yep, definitely fire. Very hot. Anyway.”

That’s where Teams Integration comes in. It delivers notifications through Microsoft Teams, which everyone already has open. The notification shows up right where you’re already looking. Or where you’re ignoring messages. Either way, the platform did its job.






How It Works



Something
Happens
→
Alert Gets
Queued
→
Processor
Wakes Up
→
Card Gets
Delivered
→
Everyone Pretends
They Saw It

From detection to notification — queue-driven, no polling, no waiting


A monitoring module detects an issue and drops a row into a queue table. That’s it. No waiting for HTTP calls, no worrying about whether Teams is having a good day. Just a quick “hey, someone should know about this” and back to work.

A dedicated processor picks up the queued alert, figures out which Teams channels should receive it based on subscription rules, formats it as a color-coded card, and delivers it. The whole thing is queue-driven — if nothing is queued, nothing runs. If ten alerts arrive at once, they’re all handled in a single batch.

And it’s not exclusive to xFACts modules. Any process that can queue a row — a PowerShell script through the shared alert function, or T-SQL through the queue procedure — can raise an alert. We don’t discriminate against outsiders.






The Color Code

Every alert has a category that determines how it looks in Teams. Think of it as the alert’s way of saying “how much should you care about this?”

| Category | Color | Translation |
| --- | --- | --- |
| **CRITICAL** | Red | Stop what you’re doing. Yes, even that. |
| **WARNING** | Amber | Not an emergency, but maybe don’t ignore me? |
| **INFO** | Green | Just keeping you posted. No action needed. Probably. |


These categories aren’t just cosmetic — they drive routing. You can configure critical alerts to go to an on-call channel while info alerts go to a general channel. The color-coding makes it possible to glance at your Teams feed and instantly know if you need to care.






Smart Delivery

Not every alert needs to go everywhere, and nobody needs the same alert 47 times. The system handles both.

**Routing** controls which alerts end up in which channels. You can send all alerts from one module to one team’s channel, only critical alerts to another channel, or mix and match however you need. A single alert can go to multiple channels. Which is how Matt ends up getting 25 notifications at 1:45 AM. The system is working exactly as designed. Muting your general IT channel at bedtime is a life skill.

**Deduplication** prevents alert storms. When a condition persists across multiple monitoring cycles, only the first alert gets delivered. The problem was reported. Once is enough. Most alerts carry the date in their dedup key, so a recurring issue still gets flagged the next day — just not every cycle.

**Retry logic** handles the inevitable. When Teams has a moment, the processor retries delivery automatically. If it still can’t get through, the alert is marked as failed for investigation rather than silently lost.






The Bottom Line

Teams Integration is the megaphone. Every module in xFACts that detects something worth reporting funnels through this service to get the word out. The queue keeps modules fast. The routing keeps channels focused. The deduplication keeps noise down. The retry logic keeps alerts from getting lost.

It’s not glamorous work. But when your phone buzzes with a clear, color-coded card that says exactly what went wrong and where to look — that’s this module doing its job.

The smoke detector that actually tells you about the fire. That’s Teams Integration.

---

## Architecture
# Teams Integration Architecture

The narrative page tells you *what* Teams Integration does and *why*. This page tells you *how*. Four tables, one stored procedure, one trigger, and one PowerShell script that turns "something happened" into a color-coded card in your channel — usually within seconds.



Schema Overview

The Teams schema is built around a routing pattern. Alerts don't go directly to a webhook — they pass through a subscription layer that decides which webhooks should receive which alerts. This indirection is what makes the whole system flexible.



The data model has a clean flow from left to right. `WebhookConfig` defines where messages can go. `WebhookSubscription` defines rules for which alerts go where. `AlertQueue` holds the pending and processed alerts. `RequestLog` records every delivery attempt.

| Table | Role | Cardinality |
| --- | --- | --- |
| `WebhookConfig` | Webhook URL registry | One per Teams channel webhook |
| `WebhookSubscription` | Alert routing rules | Many per webhook (module + category combos) |
| `AlertQueue` | Alert processing queue | Many per subscription over time |
| `RequestLog` | HTTP delivery audit trail | One per delivery attempt |



Why separate WebhookConfig and WebhookSubscription? A single webhook URL can serve many routing rules. The Apps team channel might receive all JobFlow alerts, all BIDATA alerts, and only CRITICAL ServerOps alerts. That's three subscription rows pointing at one webhook. If the webhook URL changes (Teams rotates them periodically), you update one row in WebhookConfig instead of every subscription.







The Queue Lifecycle

Every alert passes through the same lifecycle, regardless of which module generated it or how urgent it is. The queue is the great equalizer.





Queue Alert
Send-TeamsAlert or
sp_QueueAlert → Pending

→

Trigger Fires
running_count++
in ProcessRegistry

→

Match Subs
Module + category
→ webhook(s)

→

POST Card
Adaptive Card
to Teams webhook

→

Log & Update
RequestLog entry
Queue → Success/Failed


Queue-driven execution — no wasted cycles polling an empty queue. One alert can route to multiple channels.


Step 1: Alert Enters the Queue

Most alerts originate in PowerShell, which queues them through the shared `Send-TeamsAlert` function; T-SQL callers use `Teams.sp_QueueAlert`. Either way a row lands in `AlertQueue` with status **Pending** and the caller returns immediately — it never waits for delivery. Both paths carry a source module, alert category (CRITICAL/WARNING/INFO), title, message body, and an optional deduplication trigger.

Some alerts need richer layouts than the standard template — `Send-DiskHealthSummary.ps1` is one. Those callers pass a pre-built Adaptive Card in the `card_json` column via `Send-TeamsAlert -CardJson`. The queue doesn’t care how the row got there.

Step 2: The Trigger Signals Demand

`TR_Teams_AlertQueue_QueueDepth` fires on every INSERT. It increments `running_count` on the queue processor's `Orchestrator.ProcessRegistry` entry. This is the signal that work is waiting. The orchestrator sees the positive count on its next heartbeat and launches the processor.


Queue-driven, not timer-driven. The processor is `run_mode = 2` in ProcessRegistry, meaning it only runs when signaled. No polling an empty queue on a timer. If nothing is queued, nothing runs. If 10 alerts arrive between heartbeats, the trigger increments the count 10 times, but the processor handles them all in a single batch.


Step 3: Claim, Match, Deliver

`Process-TeamsAlertQueue.ps1` picks up all Pending rows and processes them in order. For each alert:

The script joins through `WebhookSubscription` to find which webhooks should receive this alert, matching on `source_module`, `alert_category`, and `trigger_type` (NULL fields act as wildcards). An alert can match multiple subscriptions — one alert, many channels.

For each matched webhook, the script either uses the pre-built `card_json` (if provided) or constructs a standard Adaptive Card with the alert's title, message, category color coding, and timestamp. The card is POSTed to the webhook URL from `WebhookConfig`.

Each delivery attempt is logged to `RequestLog` with the HTTP status code, response body, and timing. The AlertQueue row is then updated to **Success** or **Failed** with a `processed_dttm` timestamp.






Routing & Subscriptions

The subscription model is deliberately simple: a subscription says "alerts from this module with this category should go to this webhook." The power comes from combining multiple subscriptions.

| Subscription Pattern | Example | Effect |
| --- | --- | --- |
| Module + Category | JobFlow + CRITICAL | Only critical JobFlow alerts to this channel |
| Module + wildcard | BIDATA + all categories | All BIDATA alerts to this channel |
| Multiple subscriptions | JobFlow CRITICAL + ServerOps CRITICAL | All critical alerts from two modules to same channel |


The key insight is that routing decisions are made at delivery time, not at queue time. The alert sits in the queue with its module and category. The processor evaluates subscriptions when it picks up the alert. This means you can change routing rules without touching anything in the queue — the next alert will follow the new rules automatically.


Active flags at every level. `WebhookConfig.is_active` disables a webhook entirely (maybe it expired). `WebhookSubscription.is_active` disables a specific routing rule. Both are checked at delivery time. You can surgically disable one subscription without affecting any other routing to that same webhook.







Deduplication

Without deduplication, a persistent problem generates a new alert every monitoring cycle. A stalled job detected on every cycle means hundreds of alerts per day. That’s not alerting, that’s harassment.

Deduplication keys on two fields, `trigger_type` and `trigger_value`, which together identify a condition, and it works on two levels. **Cross-run:** before an alert is queued, `RequestLog` is checked for an already-successful delivery (status_code 200) of the same trigger — `Send-TeamsAlert` does this for PowerShell callers, and T-SQL callers do it before `sp_QueueAlert` — so a condition already reported is not re-sent on the next cycle. **Same-run:** the `Send-TeamsAlert` insert is itself guarded, so a burst of the same trigger within one run (a failover flapping hundreds of times, or two collectors racing the same trigger) collapses to a single queued alert.

| Example | trigger_type | trigger_value |
| --- | --- | --- |
| JobFlow stall on Jan 18 | JOBFLOW_STALL | 2026-01-18 |
| Disk D low space | DISK_LOW | DM-PROD-DB_D |
| File not detected | FILE_ESCALATION | PaymentFile_2026-01-18 |


By convention, most callers put the date in the `trigger_value`, so a new day yields a new key and the alert fires again — Monday’s stall alert won’t suppress Tuesday’s. The dedup check itself has no time window; the daily cadence comes entirely from that caller convention, which is the right behavior — a recurring problem deserves a daily notification, not just the first one.


Deduplication isn’t optional. On the PowerShell path, `Send-TeamsAlert` requires a trigger type and value on every call — there is no opt-out. For a genuinely one-off notification (a build completion, say), the caller simply passes a value that will not recur, such as the date or a run id, so each event keys uniquely.







Retry & Failure Handling

Teams webhooks are generally reliable, but they're an external dependency. Network blips, service outages, and webhook URL rotations all happen. The retry logic is simple and inline.

When a POST fails, the script retries immediately, with a fixed 2-second delay between attempts. The maximum number of attempts is configured in `dbo.GlobalConfig` (`teams_retry_max_attempts`). Each attempt is logged to `RequestLog` with its status code and response.

If all retries are exhausted, the AlertQueue row is marked **Failed**. Failed alerts remain in the queue for troubleshooting but are not automatically retried on subsequent processor runs. The assumption is that if it failed after multiple retries, the problem is structural (expired webhook, wrong URL) and needs human attention.


Inline retries, not requeue. The script retries within a single execution rather than putting the alert back in the queue for the next cycle. This keeps retry behavior predictable and prevents retry storms. A failed alert is a known state that can be investigated, not a perpetually bouncing message.







Troubleshooting

**“An alert isn’t showing up in Teams.”**
Check `Teams.AlertQueue` for the alert. Is the status Pending (not yet processed), Failed (delivery failed), or Success (delivered but maybe to a different channel than expected)? If Failed, the `error_message` column tells you why.

**“Alerts are stuck in Pending.”**
The processor might not be running. Check that `TR_Teams_AlertQueue_QueueDepth` is enabled — it’s what wakes the processor. Also check `running_count` in ProcessRegistry for the Teams processor. If it’s 0 despite pending alerts, the trigger may be disabled.

**“The same alert went to the wrong channel.”**
Check subscriptions: `Teams.WebhookSubscription` joined to `Teams.WebhookConfig`. The routing is driven by source_module, alert_category, and trigger_type matching. NULL fields act as wildcards — a subscription with NULL alert_category matches everything.

**“Emoji are showing up as question marks.”**
The script is probably putting emoji directly in the hashtable before ConvertTo-Json. Use the placeholder pattern (`{{FIRE}}`, `{{CHECK}}`, `{{WARN}}`) instead. The processor resolves them at send time.

**“I need to retry a failed alert.”**
The simplest path is the Admin page Alert Failures card, which resends a failed alert in one click (it queues a fresh Pending copy linked by `original_queue_id`). To do it by hand: reset the queue row’s status to Pending, clear the error_message and processed_dttm, then bump the processor’s `running_count` in ProcessRegistry. The processor will pick it up on the next heartbeat.






How Everything Connects

Teams Integration is a pure service module — it doesn't detect anything or make any decisions. It just delivers what other modules tell it to deliver. This isolation is what makes it reliable.

Internal Flow

| From | To | Relationship |
| --- | --- | --- |
| `WebhookConfig` | `WebhookSubscription` | One webhook → many subscriptions (FK on `config_id`) |
| `WebhookSubscription` | `AlertQueue` | Subscription matches alerts at delivery time (joined by module, category, and trigger type, NULL as wildcard) |
| `AlertQueue` | `RequestLog` | One alert → one or more delivery attempts (FK on `queue_id`) |


External Dependencies

| Dependency | Module | Purpose |
| --- | --- | --- |
| `Orchestrator.ProcessRegistry` | Orchestrator | Schedules Process-TeamsAlertQueue.ps1 (run_mode = 2, queue-driven) |
| `dbo.GlobalConfig` | Shared Infrastructure | Retry settings, feature toggles |
| Microsoft Teams | External | Webhook POST delivery target |


Who Calls Teams Integration

| Caller | Method | Alert Types |
| --- | --- | --- |
| JobFlow (Monitor-JobFlow.ps1) | `Send-TeamsAlert` | Stalls, failures, recoveries |
| ServerOps (Process-BackupNetworkCopy.ps1 / Process-BackupAWSUpload.ps1) | `Send-TeamsAlert` | Retry exhaustion alerts for failed copies/uploads |
| FileOps (Scan-SFTPFiles.ps1) | `Send-TeamsAlert` | File detected, escalation |
| BIDATA (Monitor-BIDATABuild.ps1) | `Send-TeamsAlert` | Build complete, not started |
| ServerOps (Send-DiskHealthSummary.ps1) | `Send-TeamsAlert -CardJson` | Pre-built disk summary card |

---

## Reference

### AlertQueue

Queue table for pending Teams notifications awaiting PowerShell processing. Records remain after processing for audit and troubleshooting.

**Data Flow:** PowerShell callers queue alerts through the shared Send-TeamsAlert function, which deduplicates before inserting: it skips the alert when RequestLog already shows a successful delivery for the same trigger_type/trigger_value, and its guarded insert also collapses a same-run burst of the same trigger to a single Pending row. T-SQL callers use Teams.sp_QueueAlert. Rich layouts are queued by passing pre-built Adaptive Card JSON in card_json (Send-TeamsAlert -CardJson). TR_Teams_AlertQueue_QueueDepth fires on INSERT, incrementing running_count in Orchestrator.ProcessRegistry to signal the orchestrator. Process-TeamsAlertQueue.ps1 claims Pending rows, joins through WebhookSubscription and WebhookConfig to find matching webhook URLs, delivers via HTTP POST, then updates status to Success or Failed and sets processed_dttm. Each webhook delivery attempt is also logged to Teams.RequestLog. Failed deliveries are retried inline up to a configurable maximum (teams_retry_max_attempts in GlobalConfig) with 2-second delays between attempts. Failed alerts that exhaust all retries can be manually resent from the Admin page Alert Failures card, which inserts a new Pending row with original_queue_id referencing the original failed alert. The resend follows the normal queue processing path - routing is re-resolved through WebhookSubscription at delivery time.

**Queue-Based Decoupling:** [sort:1] Calling modules insert and continue without waiting for webhook responses. Alerting latency does not affect the calling process execution time. The orchestrator launches the processor asynchronously based on queue depth signaling.

**Retained After Processing:** [sort:2] Rows are updated (not deleted) when processed. This provides an audit trail and enables troubleshooting of failed deliveries without requiring a separate history table.

**Two Card Paths:** [sort:3] Alerts queued with simple title/message/color fields have Adaptive Cards built by the processor at send time. Alerts with card_json populated are sent as-is after emoji placeholder resolution. The card_json path enables rich layouts with multiple sections, columns, and icons that go beyond what the legacy builder supports.

**Inline Retry:** [sort:4] On failure, the processor retries immediately with 2-second sleep between attempts rather than reinserting a new Pending row. retry_count is updated in place on the original row and each attempt is individually logged to RequestLog. This eliminates orphaned Pending rows from trigger/running_count timing gaps that the earlier reinsert approach caused.

**Manual Resend via original_queue_id:** [sort:5] Failed alerts can be resent from the Admin page Alert Failures card. Resend inserts a new Pending row copying the original alert content (source_module, alert_category, title, message, color, card_json, trigger_type, trigger_value) with original_queue_id set to the failed row's queue_id. This is a soft self-reference with no FK constraint, used only by the Admin page display query. The NOT EXISTS filter hides failed alerts that have a successful or pending resend, so the original disappears from the failure list once its resend succeeds. If the resend also fails, the original reappears. Routing is re-resolved at delivery time through WebhookSubscription rather than capturing the original delivery target, so subscription changes between failure and resend are respected.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| queue_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this queue entry |
| source_module | varchar(50) | No | — | Module that queued the alert. |
| alert_category | varchar(50) | No | — | Severity category assigned by the caller. |
| title | varchar(255) | No | — | Alert title displayed in Teams |
| message | nvarchar(MAX) | No | — | Full alert message body. Supports markdown. Used as plain text audit trail when card_json is populated |
| color | varchar(20) | Yes | — | Adaptive Card accent color. On the T-SQL path sp_QueueAlert sets it from the alert category when not supplied; Send-TeamsAlert defaults it to attention unless the caller passes a color. |
| card_json | nvarchar(MAX) | Yes | — | Pre-built Adaptive Card JSON payload. When populated, the processor sends this directly instead of building a card from title/message/color. May contain emoji placeholders resolved at send time |
| status | varchar(20) | Yes | 'Pending' | Current delivery state of this queued alert. |
| trigger_type | varchar(50) | Yes | — | Category used for deduplication; typically a <Module>_<Condition> pattern. |
| trigger_value | varchar(100) | Yes | — | Specific instance value that pairs with the trigger category to form the deduplication key. |
| retry_count | int | No | 0 | Number of retry attempts beyond the first delivery, set in place on the original row by Process-TeamsAlertQueue.ps1; 0 when the first attempt succeeds. |
| created_dttm | datetime | Yes | getdate() | When alert was queued |
| processed_dttm | datetime | Yes | — | When PowerShell processed this entry |
| error_message | nvarchar(MAX) | Yes | — | Error details if processing failed |
| original_queue_id | int | Yes | — | References the queue_id of the original failed alert. NULL for normal alerts. Populated only on manually resent copies created via the Admin page Alert Failures resend action. Soft reference with no FK constraint. Used by the NOT EXISTS display query to filter out failed alerts that have a successful or pending resend. |

  - **PK_Teams_AlertQueue** (CLUSTERED): queue_id -- PRIMARY KEY

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| alert_category | CRITICAL | System failures, stalls, and urgent issues requiring immediate attention. On the T-SQL path sp_QueueAlert auto-colors this attention (red) when no explicit color is given; Send-TeamsAlert defaults every category to attention unless the caller passes a color. | 1 |
| alert_category | WARNING | Potential issues, thresholds approaching, and items needing review. On the T-SQL path sp_QueueAlert auto-colors this warning (yellow) when no explicit color is given; Send-TeamsAlert defaults to attention unless the caller passes a color. | 2 |
| alert_category | INFO | Informational messages, successful completions, and status updates. On the T-SQL path sp_QueueAlert auto-colors this good (green) when no explicit color is given; Send-TeamsAlert defaults to attention unless the caller passes a color. | 3 |
| status | Pending | Waiting for processor pickup. Set on INSERT as the default value. Rows remaining in Pending for more than a few minutes indicate the processor may not be running. | 1 |
| status | Success | Delivered to all matching webhooks. Set by Process-TeamsAlertQueue.ps1 after receiving HTTP 200 responses. | 2 |
| status | Failed | Webhook delivery failed after all retry attempts exhausted. Set by the processor with error details in error_message. | 3 |

**Pending alerts** [sort:1] -- Shows alerts waiting for processing with wait time and card path type.

```sql
SELECT 
    queue_id, 
    source_module, 
    alert_category,
    title,
    CASE WHEN card_json IS NOT NULL THEN 'Pre-built' ELSE 'Legacy' END AS card_path,
    created_dttm,
    DATEDIFF(MINUTE, created_dttm, GETDATE()) AS minutes_waiting
FROM Teams.AlertQueue
WHERE status = 'Pending'
ORDER BY created_dttm;
```

**Failed alerts** [sort:2] -- Shows failed deliveries with error messages for troubleshooting.

```sql
SELECT 
    queue_id,
    source_module,
    alert_category,
    title,
    error_message,
    retry_count,
    created_dttm
FROM Teams.AlertQueue
WHERE status = 'Failed'
ORDER BY created_dttm DESC;
```

**Queue volume by module** [sort:3] -- Seven-day alert counts grouped by source module, category, and status.

```sql
SELECT 
    source_module,
    alert_category,
    status,
    COUNT(*) AS alert_count
FROM Teams.AlertQueue
WHERE created_dttm >= DATEADD(DAY, -7, GETDATE())
GROUP BY source_module, alert_category, status
ORDER BY source_module, alert_category, status;
```

**Unresolved alert failures** [sort:4] -- Failed alerts within the lookback window that have not been successfully resent. Used by the Admin page Alert Failures card.

```sql
DECLARE @lookback INT = 3;  -- or read from GlobalConfig: Teams / alert_failure_lookback_days
 
 SELECT f.queue_id, f.source_module, f.alert_category, f.title,
        f.error_message, f.retry_count, f.created_dttm
 FROM Teams.AlertQueue f
 WHERE f.status = 'Failed'
   AND f.created_dttm >= DATEADD(DAY, -@lookback, GETDATE())
   AND NOT EXISTS (
     SELECT 1 FROM Teams.AlertQueue r
     WHERE r.original_queue_id = f.queue_id
       AND r.status IN ('Success', 'Sent', 'Pending')
   )
 ORDER BY f.created_dttm DESC;
```

  - **Teams.WebhookSubscription**: [sort:1] The processor joins AlertQueue to WebhookSubscription on source_module with NULL-as-wildcard matching on alert_category and trigger_type to determine which webhooks receive each alert.
  - **Teams.RequestLog**: [sort:2] Each webhook delivery attempt (success or failure, including retries) creates a RequestLog entry linked back via queue_id. Provides the permanent audit trail for alert delivery.
  - **Orchestrator.ProcessRegistry**: [sort:3] TR_Teams_AlertQueue_QueueDepth increments running_count on INSERT, signaling the orchestrator engine to launch Process-TeamsAlertQueue.ps1 on its next heartbeat.


### RequestLog

Permanent audit log of all Teams webhook interactions including successful deliveries and failures.

**Data Flow:** Process-TeamsAlertQueue.ps1 inserts one row per webhook delivery attempt, including retries. Each row captures the HTTP status_code and response_text from the webhook call. This table is the cross-run deduplication source: Send-TeamsAlert checks it (trigger_type and trigger_value with status_code = 200) before queuing a PowerShell-originated alert, and T-SQL callers perform the same check before sp_QueueAlert, so a condition already delivered is not re-sent across orchestrator cycles.

**Append-Only Audit Trail:** [sort:1] Rows are never updated or deleted. Each webhook call, including individual retry attempts, generates a separate entry. This provides complete delivery history for compliance and troubleshooting.

**Per-Webhook Granularity:** [sort:2] If an alert routes to multiple webhooks via subscription matching, each webhook delivery gets its own log entry with independent status tracking. Enables per-channel troubleshooting when one webhook fails but others succeed.

**Deduplication Source:** [sort:3] Before an alert is queued, RequestLog is checked for an existing successful delivery (status_code = 200) with the same trigger_type and trigger_value. Send-TeamsAlert performs this check centrally for PowerShell callers; T-SQL callers perform it before sp_QueueAlert. This prevents duplicate notifications when the same condition is detected across multiple orchestrator cycles.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| log_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this log entry |
| queue_id | int | Yes | — | Links this log entry to its AlertQueue row; no FK constraint, the column is present for tracing. |
| source_module | varchar(50) | No | — | Module that originated the alert |
| alert_category | varchar(50) | No | — | Severity category carried through from the queued alert. |
| webhook_name | varchar(50) | No | — | Name of the webhook this was sent to |
| title | varchar(255) | No | — | Alert title |
| status_code | int | Yes | — | HTTP status code returned by the webhook for this delivery attempt. |
| response_text | nvarchar(MAX) | Yes | — | Response body or error message |
| trigger_type | varchar(50) | Yes | — | Category for deduplication lookup |
| trigger_value | varchar(100) | Yes | — | Specific identifier for deduplication |
| created_dttm | datetime | Yes | getdate() | When this log entry was created |

  - **PK_Teams_RequestLog** (CLUSTERED): log_id -- PRIMARY KEY

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| status_code | 200 | Success - the alert was delivered to the webhook. | 10 |
| status_code | 400 | Bad Request - check the Adaptive Card JSON structure. | 11 |
| status_code | 401 | Unauthorized - verify the webhook URL in WebhookConfig. | 12 |
| status_code | 404 | Not Found - the webhook no longer exists in Teams and must be recreated. | 13 |
| status_code | 429 | Rate Limited - Teams throttled the delivery. The processor retries inline within the same run and the alert is marked Failed once attempts are exhausted. | 14 |
| status_code | 500+ | Server Error - Teams-side failure. Retried inline within the same run. | 15 |
| status_code | 0 | No HTTP response - the delivery attempt failed before the webhook replied. | 16 |

**Recent activity** [sort:1] -- Last 20 deliveries showing module, category, webhook, and status.

```sql
SELECT TOP 20 
    source_module,
    alert_category,
    webhook_name,
    title,
    status_code,
    created_dttm
FROM Teams.RequestLog
ORDER BY created_dttm DESC;
```

**Failed deliveries** [sort:2] -- All entries with non-200 status codes showing response text for troubleshooting.

```sql
SELECT 
    queue_id,
    source_module,
    webhook_name,
    title,
    status_code,
    response_text,
    created_dttm
FROM Teams.RequestLog
WHERE status_code != 200 OR status_code IS NULL
ORDER BY created_dttm DESC;
```

**Volume by module and webhook** [sort:3] -- Thirty-day delivery counts with success/failure breakdown per module and webhook.

```sql
SELECT 
    source_module,
    webhook_name,
    COUNT(*) AS total_alerts,
    SUM(CASE WHEN status_code = 200 THEN 1 ELSE 0 END) AS successful,
    SUM(CASE WHEN status_code != 200 OR status_code IS NULL THEN 1 ELSE 0 END) AS failed
FROM Teams.RequestLog
WHERE created_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY source_module, webhook_name
ORDER BY total_alerts DESC;
```

**Standard deduplication pattern** [sort:10] -- Cross-run dedup check used on the T-SQL path before sp_QueueAlert; the PowerShell path performs this check inside Send-TeamsAlert.

```sql
IF NOT EXISTS (
    SELECT 1 FROM Teams.RequestLog
    WHERE trigger_type = @TriggerType
      AND trigger_value = @TriggerValue
      AND status_code = 200
)
BEGIN
    EXEC Teams.sp_QueueAlert ...
END
```

  - **Teams.AlertQueue**: [sort:1] queue_id links each log entry back to the original queued alert. Multiple RequestLog rows may reference the same queue_id when an alert routes to multiple webhooks or when retries generate additional delivery attempts.


### WebhookConfig

Configuration table holding the Teams webhook endpoints that alerts can be delivered to.

**Data Flow:** Rows are manually configured when setting up Teams webhook endpoints. Process-TeamsAlertQueue.ps1 reads webhook_name, webhook_url, and is_active during alert routing, joined through WebhookSubscription via config_id. Only webhooks with is_active = 1 are included in routing.

**Active Flag for Maintenance:** [sort:1] The is_active flag allows disabling a webhook without deleting the configuration. Supports maintenance windows and testing scenarios without losing the webhook URL and associated subscriptions.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| config_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this webhook configuration |
| webhook_name | varchar(50) | No | — | Human-readable name for this webhook. |
| webhook_url | varchar(500) | No | — | Full Teams incoming webhook URL |
| alert_category | varchar(50) | No | — | Descriptive label for the alert type this webhook is intended to carry. Not evaluated during routing. |
| description | varchar(255) | Yes | — | Description of this webhook's purpose |
| is_active | bit | Yes | 1 | Whether this webhook is active. Inactive webhooks are skipped |
| created_dttm | datetime | Yes | getdate() | When this configuration was created |
| modified_dttm | datetime | Yes | getdate() | When this configuration was last modified |

  - **PK_Teams_WebhookConfig** (CLUSTERED): config_id -- PRIMARY KEY

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| alert_category | ALL | Descriptive label indicating this webhook is intended for all alert types. Not used in routing logic - routing is controlled entirely by WebhookSubscription. | 1 |
| alert_category | CRITICAL | Descriptive label indicating this webhook is intended for critical alerts. Not used in routing logic. | 2 |
| alert_category | WARNING | Descriptive label indicating this webhook is intended for warning alerts. Not used in routing logic. | 3 |
| alert_category | INFO | Descriptive label indicating this webhook is intended for informational alerts. Not used in routing logic. | 4 |

**Active webhook overview** [sort:1] -- Shows all active webhooks with names, intended categories, and descriptions.

```sql
SELECT 
    config_id,
    webhook_name,
    alert_category,
    is_active,
    description
FROM Teams.WebhookConfig
WHERE is_active = 1
ORDER BY webhook_name;
```

  - **Teams.WebhookSubscription**: [sort:1] WebhookSubscription references WebhookConfig via config_id FK. WebhookConfig defines where alerts can go (the webhook URLs). WebhookSubscription defines which alerts go there (the routing rules based on source module, category, and trigger type).


### WebhookSubscription

Subscription routing table that controls which alerts are delivered to which Teams channels based on source module, category, and trigger type.

**Data Flow:** Rows are manually configured to define alert routing rules. Process-TeamsAlertQueue.ps1 reads this table during every processing cycle, joining AlertQueue to WebhookSubscription on source_module with NULL-as-wildcard matching on alert_category and trigger_type, then joining to WebhookConfig for the webhook URL. Only subscriptions with is_active = 1 are evaluated.

**NULL-as-Wildcard Pattern:** [sort:1] NULL values in alert_category and trigger_type act as wildcards, matching all values for that field. This allows broad subscriptions (all alerts from a module) and narrow subscriptions (specific trigger types only) using the same table structure without requiring separate wildcard rows.

**Module-Level Routing:** [sort:2] Subscriptions are keyed on source module, so each module's alerts can be directed to the channel that owns them without requiring separate webhook infrastructure per team.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| subscription_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this subscription |
| config_id | int | No | — | Foreign key to WebhookConfig. Links to the webhook URL |
| channel_name | varchar(100) | No | — | Human-readable name of the Teams channel (for documentation) |
| source_module | varchar(50) | No | — | Module name to match. |
| alert_category | varchar(50) | Yes | — | Category filter. NULL = match all categories |
| trigger_type | varchar(50) | Yes | — | Trigger type filter. NULL = match all trigger types |
| is_active | bit | No | 1 | Whether this subscription is active |
| description | varchar(255) | Yes | — | Description of this subscription's purpose |
| created_dttm | datetime | No | getdate() | When this subscription was created |
| modified_dttm | datetime | Yes | — | When this subscription was last modified |

  - **PK_Teams_WebhookSubscription** (CLUSTERED): subscription_id -- PRIMARY KEY
  - **IX_Teams_WebhookSubscription_config_id** (NONCLUSTERED): config_id
  - **IX_Teams_WebhookSubscription_source_module** (NONCLUSTERED): source_module

**Foreign Keys:**

  - **FK_Teams_WebhookSubscription_WebhookConfig**: config_id -> Teams.WebhookConfig.config_id

**Subscription overview** [sort:1] -- All subscriptions with webhook names showing channel routing and filter criteria.

```sql
SELECT 
    s.subscription_id,
    s.channel_name,
    w.webhook_name,
    s.source_module,
    s.alert_category,
    s.trigger_type,
    s.is_active
FROM Teams.WebhookSubscription s
INNER JOIN Teams.WebhookConfig w ON s.config_id = w.config_id
ORDER BY s.channel_name, s.source_module;
```

**Routing simulation** [sort:2] -- Shows which channels and webhooks would receive an alert for a given module, category, and trigger type. Replace the parameter values to test routing.

```sql
DECLARE @Module VARCHAR(50) = '<source module>';
DECLARE @Category VARCHAR(50) = '<alert category>';
DECLARE @Trigger VARCHAR(50) = '<trigger type>';

SELECT DISTINCT
    s.channel_name,
    w.webhook_name
FROM Teams.WebhookSubscription s
INNER JOIN Teams.WebhookConfig w ON s.config_id = w.config_id
WHERE s.source_module = @Module
  AND s.is_active = 1
  AND w.is_active = 1
  AND (s.alert_category IS NULL OR s.alert_category = @Category)
  AND (s.trigger_type IS NULL OR s.trigger_type = @Trigger);
```

  - **Teams.WebhookConfig**: [sort:1] FK on config_id. Each subscription points to exactly one webhook URL. Multiple subscriptions can point to the same webhook, allowing a single channel to receive alerts from different modules with different filter criteria.
  - **Teams.AlertQueue**: [sort:2] No foreign key, but the processor joins these tables during routing. AlertQueue.source_module, alert_category, and trigger_type are matched against subscription filter columns with NULL-as-wildcard logic. This is the core operational relationship that drives alert delivery.


### sp_QueueAlert

Queue procedure that inserts Teams notification requests into AlertQueue for asynchronous processing by the PowerShell processor.

**Data Flow:** The T-SQL entry point for queuing a Teams alert, available to external or in-database callers: it inserts one row into Teams.AlertQueue with Pending status, applying default category-based coloring when no color is supplied. The INSERT fires TR_Teams_AlertQueue_QueueDepth, which signals the orchestrator to launch the processor. xFACts PowerShell scripts do not use this proc - they queue through the shared Send-TeamsAlert function - so it is an available entry surface rather than a deprecated one.

**Default Color Mapping:** [sort:1] Automatically assigns Adaptive Card accent colors based on alert category when @Color is not provided: CRITICAL maps to attention (red), WARNING to warning (yellow), INFO to good (green). Callers do not need to know Adaptive Card color names.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @SourceModule | varchar(50) | IN |  |  |
| @AlertCategory | varchar(50) | IN |  |  |
| @Title | varchar(255) | IN |  |  |
| @Message | nvarchar(MAX) | IN |  |  |
| @Color | varchar(20) | IN |  |  |
| @TriggerType | varchar(50) | IN |  |  |
| @TriggerValue | varchar(100) | IN |  |  |

**Basic info alert** [sort:1] -- Simple informational notification

```sql
EXEC Teams.sp_QueueAlert
    @SourceModule  = '<source module>',
    @AlertCategory = 'INFO',
    @Title         = '<alert title>',
    @Message       = '<alert message>',
    @TriggerType   = '<Module>_<Condition>',
    @TriggerValue  = '<instance value>';
```

**Warning alert** [sort:2] -- Warning with deduplication context

```sql
EXEC Teams.sp_QueueAlert
    @SourceModule  = '<source module>',
    @AlertCategory = 'WARNING',
    @Title         = '<alert title>',
    @Message       = @message_body,
    @TriggerType   = '<Module>_<Condition>',
    @TriggerValue  = '<instance value>';
```

**Critical alert** [sort:3] -- High-priority alert for system issues

```sql
EXEC Teams.sp_QueueAlert
    @SourceModule  = '<source module>',
    @AlertCategory = 'CRITICAL',
    @Title         = '<alert title>',
    @Message       = '<alert message>',
    @TriggerType   = '<Module>_<Condition>',
    @TriggerValue  = '<instance value>';
```

  - **Teams.AlertQueue**: [sort:1] Inserts directly into AlertQueue. This is the T-SQL entry point for queuing Teams alerts, available to external or in-database callers. xFACts PowerShell scripts queue through the shared Send-TeamsAlert function instead, including rich Adaptive Card layouts via its -CardJson parameter.


### TR_Teams_AlertQueue_QueueDepth

INSERT trigger on Teams.AlertQueue that signals the Orchestrator v2 engine when alerts are ready for processing. Enables queue-driven execution of Process-TeamsAlertQueue.

**Queue-Driven Orchestrator Signal:** [sort:1] INSERT trigger that increments running_count in Orchestrator.ProcessRegistry for Process-TeamsAlertQueue. Only updates rows where run_mode = 2 (queue-driven), enabling the orchestrator to launch the processor on-demand rather than on a fixed polling schedule. Counts the number of inserted rows to accurately track queue depth across multi-row inserts.

**Verify trigger is enabled** [sort:1] -- Check if the trigger is active

```sql
SELECT name, is_disabled
FROM sys.triggers
WHERE name = 'TR_Teams_AlertQueue_QueueDepth';
```

**Verify ProcessRegistry entry** [sort:2] -- Confirm the orchestrator entry exists and check run mode

```sql
SELECT process_name, run_mode, running_count
FROM Orchestrator.ProcessRegistry
WHERE process_name = 'Process-TeamsAlertQueue';
```

**Re-sync running_count** [sort:3] -- After re-enabling a disabled trigger, manually set running_count for any pending items

```sql
UPDATE Orchestrator.ProcessRegistry
SET running_count = (SELECT COUNT(*) FROM Teams.AlertQueue WHERE status = 'Pending')
WHERE process_name = 'Process-TeamsAlertQueue';
```

  - **Orchestrator.ProcessRegistry**: [sort:1] Directly updates ProcessRegistry.running_count to signal queue depth. The orchestrator engine checks running_count on each heartbeat and launches the processor when count > 0.


### Process-TeamsAlertQueue.ps1

Queue processor that delivers Teams notifications via webhook. Claims Pending alerts from AlertQueue, resolves routing through WebhookSubscription and WebhookConfig, builds or passes through Adaptive Cards, delivers via HTTP POST, and logs results to RequestLog.

**Data Flow:** Launched by the orchestrator when TR_Teams_AlertQueue_QueueDepth signals queue depth > 0. Reads Pending alerts from Teams.AlertQueue, joins through WebhookSubscription (source_module, alert_category, trigger_type with NULL-as-wildcard matching) and WebhookConfig (is_active filter) to determine delivery targets. For alerts without card_json, builds an Adaptive Card from title/message/color fields with emoji placeholder resolution. For alerts with card_json, resolves emoji placeholders and sends the pre-built card as-is. Delivers via HTTP POST to each matched webhook URL, updates AlertQueue status to Success or Failed, and inserts a row into Teams.RequestLog for each delivery attempt. Failed deliveries are retried inline up to teams_retry_max_attempts (from GlobalConfig) with 2-second delays between attempts.

**Queue-Driven Execution:** [sort:1] Runs as a queue-driven process (run_mode = 2) in the orchestrator. Only launched when alerts are waiting, not on a fixed polling schedule. This minimizes resource usage during quiet periods while ensuring near-real-time delivery when alerts are queued.

**Two Card Build Paths:** [sort:2] Legacy alerts with title/message/color fields have Adaptive Cards built at send time using a standard template. Alerts with pre-built card_json are sent as-is after emoji placeholder resolution. The pre-built path enables rich multi-section layouts that cannot be expressed with the legacy fields.

**Inline Retry with Per-Attempt Logging:** [sort:3] On webhook delivery failure, retries immediately with 2-second sleep between attempts rather than requeueing. Each attempt (including retries) generates a separate RequestLog entry. retry_count on AlertQueue is updated in place. This eliminates orphaned Pending rows from trigger/running_count timing gaps that the earlier requeue approach caused.

**Orchestrator v2 Integration:** [sort:4] Accepts TaskId and ProcessId parameters from the orchestrator engine. Calls Complete-OrchestratorTask on completion with status, duration, and a summary of processed/success/failed counts. Supports -Execute safeguard (preview mode by default).

  - **Teams.AlertQueue**: [sort:1] Primary data source. Reads Pending rows, updates status to Success or Failed after delivery, and sets processed_dttm and error_message.
  - **Teams.WebhookSubscription**: [sort:2] Joined during routing to determine which webhooks receive each alert. Subscription matching uses source_module with NULL-as-wildcard on alert_category and trigger_type.
  - **Teams.WebhookConfig**: [sort:3] Joined during routing to get webhook URL and is_active status. Only active webhooks are included in delivery targets.
  - **Teams.RequestLog**: [sort:4] Write target. Inserts one row per webhook delivery attempt including retries for complete audit trail.
  - **dbo.GlobalConfig**: [sort:5] Reads teams_retry_max_attempts to control inline retry behavior.



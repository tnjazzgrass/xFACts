# Object_Metadata: Teams
Source: dbo.Object_Metadata
Generated: 2026-07-23 08:09:17

## AlertQueue (Table)

### category #0  [metadata_id: 1763]

Teams

### data_flow #0  [metadata_id: 1790]

PowerShell callers queue alerts through the shared Send-TeamsAlert function, which deduplicates before inserting: it skips the alert when RequestLog already shows a successful delivery for the same trigger_type/trigger_value, and its guarded insert also collapses a same-run burst of the same trigger to a single Pending row. T-SQL callers use Teams.sp_QueueAlert. Rich layouts are queued by passing pre-built Adaptive Card JSON in card_json (Send-TeamsAlert -CardJson). TR_Teams_AlertQueue_QueueDepth fires on INSERT, incrementing running_count in Orchestrator.ProcessRegistry to signal the orchestrator. Process-TeamsAlertQueue.ps1 claims Pending rows, joins through WebhookSubscription and WebhookConfig to find matching webhook URLs, delivers via HTTP POST, then updates status to Success or Failed and sets processed_dttm. Each webhook delivery attempt is also logged to Teams.RequestLog. Failed deliveries are retried inline up to a configurable maximum (teams_retry_max_attempts in GlobalConfig) with 2-second delays between attempts. Failed alerts that exhaust all retries can be manually resent from the Admin page Alert Failures card, which inserts a new Pending row with original_queue_id referencing the original failed alert. The resend follows the normal queue processing path - routing is re-resolved through WebhookSubscription at delivery time.

### description #0  [metadata_id: 83]

Queue table for pending Teams notifications awaiting PowerShell processing. Records remain after processing for audit and troubleshooting.

### design_note #1  [metadata_id: 1791]
Title: Queue-Based Decoupling

Calling modules insert and continue without waiting for webhook responses. Alerting latency does not affect the calling process execution time. The orchestrator launches the processor asynchronously based on queue depth signaling.

### design_note #2  [metadata_id: 1792]
Title: Retained After Processing

Rows are updated (not deleted) when processed. This provides an audit trail and enables troubleshooting of failed deliveries without requiring a separate history table.

### design_note #3  [metadata_id: 1793]
Title: Two Card Paths

Alerts queued with simple title/message/color fields have Adaptive Cards built by the processor at send time. Alerts with card_json populated are sent as-is after emoji placeholder resolution. The card_json path enables rich layouts with multiple sections, columns, and icons that go beyond what the legacy builder supports.

### design_note #4  [metadata_id: 1794]
Title: Inline Retry

On failure, the processor retries immediately with 2-second sleep between attempts rather than reinserting a new Pending row. retry_count is updated in place on the original row and each attempt is individually logged to RequestLog. This eliminates orphaned Pending rows from trigger/running_count timing gaps that the earlier reinsert approach caused.

### design_note #5  [metadata_id: 3117]
Title: Manual Resend via original_queue_id

Failed alerts can be resent from the Admin page Alert Failures card. Resend inserts a new Pending row copying the original alert content (source_module, alert_category, title, message, color, card_json, trigger_type, trigger_value) with original_queue_id set to the failed row's queue_id. This is a soft self-reference with no FK constraint — used only by the Admin page display query. The NOT EXISTS filter hides failed alerts that have a successful or pending resend, so the original disappears from the failure list once its resend succeeds. If the resend also fails, the original reappears. Routing is re-resolved at delivery time through WebhookSubscription rather than capturing the original delivery target, so subscription changes between failure and resend are respected.

### module #0  [metadata_id: 1659]

Teams

### query #1  [metadata_id: 1801]
Title: Pending alerts
Description: Shows alerts waiting for processing with wait time and card path type.

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

### query #2  [metadata_id: 1802]
Title: Failed alerts
Description: Shows failed deliveries with error messages for troubleshooting.

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

### query #3  [metadata_id: 1803]
Title: Queue volume by module
Description: Seven-day alert counts grouped by source module, category, and status.

SELECT 
    source_module,
    alert_category,
    status,
    COUNT(*) AS alert_count
FROM Teams.AlertQueue
WHERE created_dttm >= DATEADD(DAY, -7, GETDATE())
GROUP BY source_module, alert_category, status
ORDER BY source_module, alert_category, status;

### query #4  [metadata_id: 3118]
Title: Unresolved alert failures
Description: Failed alerts within the lookback window that have not been successfully resent. Used by the Admin page Alert Failures card.

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

### relationship_note #1  [metadata_id: 1804]
Title: Teams.WebhookSubscription

The processor joins AlertQueue to WebhookSubscription on source_module with NULL-as-wildcard matching on alert_category and trigger_type to determine which webhooks receive each alert.

### relationship_note #2  [metadata_id: 1805]
Title: Teams.RequestLog

Each webhook delivery attempt (success or failure, including retries) creates a RequestLog entry linked back via queue_id. Provides the permanent audit trail for alert delivery.

### relationship_note #3  [metadata_id: 1806]
Title: Orchestrator.ProcessRegistry

TR_Teams_AlertQueue_QueueDepth increments running_count on INSERT, signaling the orchestrator engine to launch Process-TeamsAlertQueue.ps1 on its next heartbeat.

### description / alert_category #3  [metadata_id: 882]

Category: CRITICAL, WARNING, or INFO

### status_value / alert_category #1  [metadata_id: 1798]
Title: CRITICAL

System failures, stalls, and urgent issues requiring immediate attention. On the T-SQL path sp_QueueAlert auto-colors this attention (red) when no explicit color is given; Send-TeamsAlert defaults every category to attention unless the caller passes a color.

### status_value / alert_category #2  [metadata_id: 1799]
Title: WARNING

Potential issues, thresholds approaching, and items needing review. On the T-SQL path sp_QueueAlert auto-colors this warning (yellow) when no explicit color is given; Send-TeamsAlert defaults to attention unless the caller passes a color.

### status_value / alert_category #3  [metadata_id: 1800]
Title: INFO

Informational messages, successful completions, and status updates. On the T-SQL path sp_QueueAlert auto-colors this good (green) when no explicit color is given; Send-TeamsAlert defaults to attention unless the caller passes a color.

### description / card_json #7  [metadata_id: 886]

Pre-built Adaptive Card JSON payload. When populated, the processor sends this directly instead of building a card from title/message/color. May contain emoji placeholders resolved at send time

### description / color #6  [metadata_id: 885]

Adaptive Card accent color. On the T-SQL path sp_QueueAlert sets it from the alert category when not supplied; Send-TeamsAlert defaults it to attention unless the caller passes a color.

### description / created_dttm #12  [metadata_id: 891]

When alert was queued

### description / error_message #14  [metadata_id: 893]

Error details if processing failed

### description / message #5  [metadata_id: 884]

Full alert message body. Supports markdown. Used as plain text audit trail when card_json is populated

### description / original_queue_id #15  [metadata_id: 3116]

References the queue_id of the original failed alert. NULL for normal alerts. Populated only on manually resent copies created via the Admin page Alert Failures resend action. Soft reference — no FK constraint. Used by the NOT EXISTS display query to filter out failed alerts that have a successful or pending resend.

### description / processed_dttm #13  [metadata_id: 892]

When PowerShell processed this entry

### description / queue_id #1  [metadata_id: 880]

Unique identifier for this queue entry

### description / retry_count #11  [metadata_id: 890]

Number of retry attempts beyond the first delivery, set in place on the original row by Process-TeamsAlertQueue.ps1; 0 when the first attempt succeeds.

### description / source_module #2  [metadata_id: 881]

Module that queued the alert (e.g., JobFlow, ServerOps, BIDATA)

### description / status #8  [metadata_id: 887]

Current status: Pending, Success, Failed

### status_value / status #1  [metadata_id: 1795]
Title: Pending

Waiting for processor pickup. Set on INSERT as the default value. Rows remaining in Pending for more than a few minutes indicate the processor may not be running.

### status_value / status #2  [metadata_id: 1796]
Title: Success

Delivered to all matching webhooks. Set by Process-TeamsAlertQueue.ps1 after receiving HTTP 200 responses.

### status_value / status #3  [metadata_id: 1797]
Title: Failed

Webhook delivery failed after all retry attempts exhausted. Set by the processor with error details in error_message.

### description / title #4  [metadata_id: 883]

Alert title displayed in Teams

### description / trigger_type #9  [metadata_id: 888]

Category for deduplication (e.g., JobFlow_Stall, DiskHealthSummary)

### description / trigger_value #10  [metadata_id: 889]

Specific value for deduplication (e.g., date)

## Process-TeamsAlertQueue.ps1 (Script)

### category #0  [metadata_id: 1857]

Teams

### data_flow #0  [metadata_id: 1858]

Launched by the orchestrator when TR_Teams_AlertQueue_QueueDepth signals queue depth > 0. Reads Pending alerts from Teams.AlertQueue, joins through WebhookSubscription (source_module, alert_category, trigger_type with NULL-as-wildcard matching) and WebhookConfig (is_active filter) to determine delivery targets. For alerts without card_json, builds an Adaptive Card from title/message/color fields with emoji placeholder resolution. For alerts with card_json, resolves emoji placeholders and sends the pre-built card as-is. Delivers via HTTP POST to each matched webhook URL, updates AlertQueue status to Success or Failed, and inserts a row into Teams.RequestLog for each delivery attempt. Failed deliveries are retried inline up to teams_retry_max_attempts (from GlobalConfig) with 2-second delays between attempts.

### description #0  [metadata_id: 1855]

Queue processor that delivers Teams notifications via webhook. Claims Pending alerts from AlertQueue, resolves routing through WebhookSubscription and WebhookConfig, builds or passes through Adaptive Cards, delivers via HTTP POST, and logs results to RequestLog.

### design_note #1  [metadata_id: 1859]
Title: Queue-Driven Execution

Runs as a queue-driven process (run_mode = 2) in the orchestrator. Only launched when alerts are waiting, not on a fixed polling schedule. This minimizes resource usage during quiet periods while ensuring near-real-time delivery when alerts are queued.

### design_note #2  [metadata_id: 1860]
Title: Two Card Build Paths

Legacy alerts with title/message/color fields have Adaptive Cards built at send time using a standard template. Alerts with pre-built card_json are sent as-is after emoji placeholder resolution. The pre-built path enables rich multi-section layouts (like disk summaries and batch status reports) that cannot be expressed with the legacy fields.

### design_note #3  [metadata_id: 1861]
Title: Inline Retry with Per-Attempt Logging

On webhook delivery failure, retries immediately with 2-second sleep between attempts rather than requeueing. Each attempt (including retries) generates a separate RequestLog entry. retry_count on AlertQueue is updated in place. This eliminates orphaned Pending rows from trigger/running_count timing gaps that the earlier requeue approach caused.

### design_note #4  [metadata_id: 1862]
Title: Orchestrator v2 Integration

Accepts TaskId and ProcessId parameters from the orchestrator engine. Calls Complete-OrchestratorTask on completion with status, duration, and a summary of processed/success/failed counts. Supports -Execute safeguard (preview mode by default).

### module #0  [metadata_id: 1856]

Teams Integration

### relationship_note #1  [metadata_id: 1863]
Title: Teams.AlertQueue

Primary data source. Reads Pending rows, updates status to Success or Failed after delivery, and sets processed_dttm and error_message.

### relationship_note #2  [metadata_id: 1864]
Title: Teams.WebhookSubscription

Joined during routing to determine which webhooks receive each alert. Subscription matching uses source_module with NULL-as-wildcard on alert_category and trigger_type.

### relationship_note #3  [metadata_id: 1865]
Title: Teams.WebhookConfig

Joined during routing to get webhook URL and is_active status. Only active webhooks are included in delivery targets.

### relationship_note #4  [metadata_id: 1866]
Title: Teams.RequestLog

Write target. Inserts one row per webhook delivery attempt including retries for complete audit trail.

### relationship_note #5  [metadata_id: 1867]
Title: dbo.GlobalConfig

Reads teams_retry_max_attempts to control inline retry behavior.

## RequestLog (Table)

### category #0  [metadata_id: 1764]

Teams

### data_flow #0  [metadata_id: 1822]

Process-TeamsAlertQueue.ps1 inserts one row per webhook delivery attempt, including retries. Each row captures the HTTP status_code and response_text from the webhook call. This table is the cross-run deduplication source: Send-TeamsAlert checks it (trigger_type and trigger_value with status_code = 200) before queuing a PowerShell-originated alert, and T-SQL callers perform the same check before sp_QueueAlert, so a condition already delivered is not re-sent across orchestrator cycles.

### description #0  [metadata_id: 124]

Permanent audit log of all Teams webhook interactions including successful deliveries and failures.

### design_note #1  [metadata_id: 1823]
Title: Append-Only Audit Trail

Rows are never updated or deleted. Each webhook call, including individual retry attempts, generates a separate entry. This provides complete delivery history for compliance and troubleshooting.

### design_note #2  [metadata_id: 1824]
Title: Per-Webhook Granularity

If an alert routes to multiple webhooks via subscription matching, each webhook delivery gets its own log entry with independent status tracking. Enables per-channel troubleshooting when one webhook fails but others succeed.

### design_note #3  [metadata_id: 1825]
Title: Deduplication Source

Before an alert is queued, RequestLog is checked for an existing successful delivery (status_code = 200) with the same trigger_type and trigger_value. Send-TeamsAlert performs this check centrally for PowerShell callers; T-SQL callers perform it before sp_QueueAlert. This prevents duplicate notifications when the same condition is detected across multiple orchestrator cycles.

### module #0  [metadata_id: 1660]

Teams

### query #1  [metadata_id: 1826]
Title: Recent activity
Description: Last 20 deliveries showing module, category, webhook, and status.

SELECT TOP 20 
    source_module,
    alert_category,
    webhook_name,
    title,
    status_code,
    created_dttm
FROM Teams.RequestLog
ORDER BY created_dttm DESC;

### query #2  [metadata_id: 1827]
Title: Failed deliveries
Description: All entries with non-200 status codes showing response text for troubleshooting.

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

### query #3  [metadata_id: 1828]
Title: Volume by module and webhook
Description: Thirty-day delivery counts with success/failure breakdown per module and webhook.

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

### query #10  [metadata_id: 1874]
Title: Standard deduplication pattern
Description: Cross-run dedup check used on the T-SQL path before sp_QueueAlert; the PowerShell path performs this check inside Send-TeamsAlert.

IF NOT EXISTS (
    SELECT 1 FROM Teams.RequestLog
    WHERE trigger_type = @TriggerType
      AND trigger_value = @TriggerValue
      AND status_code = 200
)
BEGIN
    EXEC Teams.sp_QueueAlert ...
END

### relationship_note #1  [metadata_id: 1829]
Title: Teams.AlertQueue

queue_id links each log entry back to the original queued alert. Multiple RequestLog rows may reference the same queue_id when an alert routes to multiple webhooks or when retries generate additional delivery attempts.

### description / alert_category #4  [metadata_id: 1456]

Alert category: CRITICAL, WARNING, INFO

### description / created_dttm #11  [metadata_id: 1463]

When this log entry was created

### description / log_id #1  [metadata_id: 1453]

Unique identifier for this log entry

### description / queue_id #2  [metadata_id: 1454]

Foreign key to AlertQueue. Links to the original queued alert

### description / response_text #8  [metadata_id: 1460]

Response body or error message

### description / source_module #3  [metadata_id: 1455]

Module that originated the alert

### description / status_code #7  [metadata_id: 1459]

HTTP status code from webhook: 200=success

### status_value / status_code #10  [metadata_id: 1868]
Title: 200

Success — alert delivered to webhook

### status_value / status_code #11  [metadata_id: 1869]
Title: 400

Bad Request — check Adaptive Card JSON structure

### status_value / status_code #12  [metadata_id: 1870]
Title: 401

Unauthorized — verify webhook URL in WebhookConfig

### status_value / status_code #13  [metadata_id: 1871]
Title: 404

Not Found — webhook deleted in Teams, recreate it

### status_value / status_code #14  [metadata_id: 1872]
Title: 429

Rate Limited — will retry on next processor run

### status_value / status_code #15  [metadata_id: 1873]
Title: 500+

Server Error — Teams-side issue, retry later

### description / title #6  [metadata_id: 1458]

Alert title

### description / trigger_type #9  [metadata_id: 1461]

Category for deduplication lookup

### description / trigger_value #10  [metadata_id: 1462]

Specific identifier for deduplication

### description / webhook_name #5  [metadata_id: 1457]

Name of the webhook this was sent to

## sp_QueueAlert (Procedure)

### category #0  [metadata_id: 1765]

Teams

### data_flow #0  [metadata_id: 1830]

The T-SQL entry point for queuing a Teams alert, available to external or in-database callers: it inserts one row into Teams.AlertQueue with Pending status, applying default category-based coloring when no color is supplied. The INSERT fires TR_Teams_AlertQueue_QueueDepth, which signals the orchestrator to launch the processor. xFACts PowerShell scripts do not use this proc - they queue through the shared Send-TeamsAlert function - so it is an available entry surface rather than a deprecated one.

### description #0  [metadata_id: 126]

Queue procedure that inserts Teams notification requests into AlertQueue for asynchronous processing by the PowerShell processor.

### design_note #1  [metadata_id: 1831]
Title: Default Color Mapping

Automatically assigns Adaptive Card accent colors based on alert category when @Color is not provided: CRITICAL maps to attention (red), WARNING to warning (yellow), INFO to good (green). Callers do not need to know Adaptive Card color names.

### module #0  [metadata_id: 1661]

Teams

### query #1  [metadata_id: 1875]
Title: Basic info alert
Description: Simple informational notification

EXEC Teams.sp_QueueAlert
    @SourceModule  = 'BIDATA',
    @AlertCategory = 'INFO',
    @Title         = 'BIDATA Daily Build Complete',
    @Message       = 'Completed: 6:45 AM | Total Duration: 01:15:07',
    @TriggerType   = 'DailyCompletion',
    @TriggerValue  = '2025-12-20';

### query #2  [metadata_id: 1876]
Title: Warning alert
Description: Warning with deduplication context

EXEC Teams.sp_QueueAlert
    @SourceModule  = 'BatchOps',
    @AlertCategory = 'WARNING',
    @Title         = '3 Batch(es) In Progress - Review Before Restart',
    @Message       = @batch_details,
    @TriggerType   = 'DM_OpenBatchCheck',
    @TriggerValue  = '2025-12-20';

### query #3  [metadata_id: 1877]
Title: Critical alert
Description: High-priority alert for system issues

EXEC Teams.sp_QueueAlert
    @SourceModule  = 'JobFlow',
    @AlertCategory = 'CRITICAL',
    @Title         = 'System Stall Detected',
    @Message       = 'No job progress detected for 30+ minutes.',
    @TriggerType   = 'SystemStall',
    @TriggerValue  = '2025-12-20';

### relationship_note #1  [metadata_id: 1832]
Title: Teams.AlertQueue

Inserts directly into AlertQueue. This is the T-SQL entry point for queuing Teams alerts, available to external or in-database callers. xFACts PowerShell scripts queue through the shared Send-TeamsAlert function instead, including rich Adaptive Card layouts via its -CardJson parameter.

## TR_Teams_AlertQueue_QueueDepth (Trigger)

### category #0  [metadata_id: 1766]

Teams

### description #0  [metadata_id: 89]

INSERT trigger on Teams.AlertQueue that signals the Orchestrator v2 engine when alerts are ready for processing. Enables queue-driven execution of Process-TeamsAlertQueue.

### design_note #1  [metadata_id: 1833]
Title: Queue-Driven Orchestrator Signal

INSERT trigger that increments running_count in Orchestrator.ProcessRegistry for Process-TeamsAlertQueue. Only updates rows where run_mode = 2 (queue-driven), enabling the orchestrator to launch the processor on-demand rather than on a fixed polling schedule. Counts the number of inserted rows to accurately track queue depth across multi-row inserts.

### module #0  [metadata_id: 1662]

Teams

### query #1  [metadata_id: 1878]
Title: Verify trigger is enabled
Description: Check if the trigger is active

SELECT name, is_disabled
FROM sys.triggers
WHERE name = 'TR_Teams_AlertQueue_QueueDepth';

### query #2  [metadata_id: 1879]
Title: Verify ProcessRegistry entry
Description: Confirm the orchestrator entry exists and check run mode

SELECT process_name, run_mode, running_count
FROM Orchestrator.ProcessRegistry
WHERE process_name = 'Process-TeamsAlertQueue';

### query #3  [metadata_id: 1880]
Title: Re-sync running_count
Description: After re-enabling a disabled trigger, manually set running_count for any pending items

UPDATE Orchestrator.ProcessRegistry
SET running_count = (SELECT COUNT(*) FROM Teams.AlertQueue WHERE status = 'Pending')
WHERE process_name = 'Process-TeamsAlertQueue';

### relationship_note #1  [metadata_id: 1834]
Title: Orchestrator.ProcessRegistry

Directly updates ProcessRegistry.running_count to signal queue depth. The orchestrator engine checks running_count on each heartbeat and launches the processor when count > 0.

## WebhookConfig (Table)

### category #0  [metadata_id: 1767]

Teams

### data_flow #0  [metadata_id: 1807]

Rows are manually configured when setting up Teams webhook endpoints. Process-TeamsAlertQueue.ps1 reads webhook_name, webhook_url, and is_active during alert routing, joined through WebhookSubscription via config_id. Only webhooks with is_active = 1 are included in routing.

### description #0  [metadata_id: 119]

Configuration table storing Teams webhook URLs and their category routing settings.

### design_note #1  [metadata_id: 1808]
Title: Active Flag for Maintenance

The is_active flag allows disabling a webhook without deleting the configuration. Supports maintenance windows and testing scenarios without losing the webhook URL and associated subscriptions.

### module #0  [metadata_id: 1663]

Teams

### query #1  [metadata_id: 1813]
Title: Active webhook overview
Description: Shows all active webhooks with names, intended categories, and descriptions.

SELECT 
    config_id,
    webhook_name,
    alert_category,
    is_active,
    description
FROM Teams.WebhookConfig
WHERE is_active = 1
ORDER BY webhook_name;

### relationship_note #1  [metadata_id: 1814]
Title: Teams.WebhookSubscription

WebhookSubscription references WebhookConfig via config_id FK. WebhookConfig defines where alerts can go (the webhook URLs). WebhookSubscription defines which alerts go there (the routing rules based on source module, category, and trigger type).

### description / alert_category #4  [metadata_id: 1392]

Category filter: ALL, CRITICAL, WARNING, or INFO

### status_value / alert_category #1  [metadata_id: 1809]
Title: ALL

Descriptive label indicating this webhook is intended for all alert types. Not used in routing logic — routing is controlled entirely by WebhookSubscription.

### status_value / alert_category #2  [metadata_id: 1810]
Title: CRITICAL

Descriptive label indicating this webhook is intended for critical alerts. Not used in routing logic.

### status_value / alert_category #3  [metadata_id: 1811]
Title: WARNING

Descriptive label indicating this webhook is intended for warning alerts. Not used in routing logic.

### status_value / alert_category #4  [metadata_id: 1812]
Title: INFO

Descriptive label indicating this webhook is intended for informational alerts. Not used in routing logic.

### description / config_id #1  [metadata_id: 1389]

Unique identifier for this webhook configuration

### description / created_dttm #7  [metadata_id: 1395]

When this configuration was created

### description / description #5  [metadata_id: 1393]

Description of this webhook's purpose

### description / is_active #6  [metadata_id: 1394]

Whether this webhook is active. Inactive webhooks are skipped

### description / modified_dttm #8  [metadata_id: 1396]

When this configuration was last modified

### description / webhook_name #2  [metadata_id: 1390]

Human-readable name for this webhook (e.g., "Apps-Critical", "General-Alerts")

### description / webhook_url #3  [metadata_id: 1391]

Full Teams incoming webhook URL

## WebhookSubscription (Table)

### category #0  [metadata_id: 1768]

Teams

### data_flow #0  [metadata_id: 1815]

Rows are manually configured to define alert routing rules. Process-TeamsAlertQueue.ps1 reads this table during every processing cycle, joining AlertQueue to WebhookSubscription on source_module with NULL-as-wildcard matching on alert_category and trigger_type, then joining to WebhookConfig for the webhook URL. Only subscriptions with is_active = 1 are evaluated.

### description #0  [metadata_id: 136]

Subscription routing table that controls which alerts are delivered to which Teams channels based on source module, category, and trigger type.

### design_note #1  [metadata_id: 1816]
Title: NULL-as-Wildcard Pattern

NULL values in alert_category and trigger_type act as wildcards, matching all values for that field. This allows broad subscriptions (all alerts from a module) and narrow subscriptions (specific trigger types only) using the same table structure without requiring separate wildcard rows.

### design_note #2  [metadata_id: 1817]
Title: Module-Level Routing

Different modules route to different channels, supporting organizational boundaries. For example, JobFlow alerts go to the Apps team channel while BIDATA alerts go to the BI team channel, without requiring separate webhook infrastructure per team.

### module #0  [metadata_id: 1664]

Teams

### query #1  [metadata_id: 1818]
Title: Subscription overview
Description: All subscriptions with webhook names showing channel routing and filter criteria.

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

### query #2  [metadata_id: 1819]
Title: Routing simulation
Description: Shows which channels and webhooks would receive an alert for a given module, category, and trigger type. Replace the parameter values to test routing.

DECLARE @Module VARCHAR(50) = 'JobFlow';
DECLARE @Category VARCHAR(50) = 'CRITICAL';
DECLARE @Trigger VARCHAR(50) = 'JobFlow_Stall';

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

### relationship_note #1  [metadata_id: 1820]
Title: Teams.WebhookConfig

FK on config_id. Each subscription points to exactly one webhook URL. Multiple subscriptions can point to the same webhook, allowing a single channel to receive alerts from different modules with different filter criteria.

### relationship_note #2  [metadata_id: 1821]
Title: Teams.AlertQueue

No foreign key, but the processor joins these tables during routing. AlertQueue.source_module, alert_category, and trigger_type are matched against subscription filter columns with NULL-as-wildcard logic. This is the core operational relationship that drives alert delivery.

### description / alert_category #5  [metadata_id: 1542]

Category filter. NULL = match all categories

### description / channel_name #3  [metadata_id: 1540]

Human-readable name of the Teams channel (for documentation)

### description / config_id #2  [metadata_id: 1539]

Foreign key to WebhookConfig. Links to the webhook URL

### description / created_dttm #9  [metadata_id: 1546]

When this subscription was created

### description / description #8  [metadata_id: 1545]

Description of this subscription's purpose

### description / is_active #7  [metadata_id: 1544]

Whether this subscription is active

### description / modified_dttm #10  [metadata_id: 1547]

When this subscription was last modified

### description / source_module #4  [metadata_id: 1541]

Module name to match (e.g., JobFlow, BIDATA)

### description / subscription_id #1  [metadata_id: 1538]

Unique identifier for this subscription

### description / trigger_type #6  [metadata_id: 1543]

Trigger type filter. NULL = match all trigger types

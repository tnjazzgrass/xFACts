# Object_Metadata: FileOps
Source: dbo.Object_Metadata
Generated: 2026-07-24 04:56:18

## MonitorConfig (Table)

### category #0  [metadata_id: 1694]

FileOps

### data_flow #0  [metadata_id: 2244]

Rows are created via sp_AddNewMonitorConfig or the Control Center UI. Scan-SFTPFiles.ps1 queries active configurations each cycle, filtering by is_enabled, current day-of-week flags, and whether the current time falls within the check_start_time to check_end_time window. MonitorConfig is read-only during monitoring — the script never modifies configuration rows. The Control Center FileOps page reads this table for configuration display and management.

### description #0  [metadata_id: 78]

Configuration table defining files to monitor, including SFTP paths, file patterns, check schedules, and escalation settings.

### design_note #1  [metadata_id: 2249]
Title: Three Time Points

Each config defines check_start_time, escalation_time, and check_end_time as separate values. This allows monitoring to continue after escalation to catch late-arriving files rather than giving up at the escalation threshold.

### design_note #2  [metadata_id: 2250]
Title: Individual Day Columns

Seven separate BIT columns (check_sunday through check_saturday) replace a single weekday/weekend flag. This supports any schedule pattern — weekdays only, daily, specific days, or weekly — without requiring a separate schedule table or bitmask logic.

### design_note #3  [metadata_id: 2251]
Title: Wildcard Pattern Matching

The file_pattern field uses * and ? wildcards rather than regex. Scan-SFTPFiles.ps1 converts these to regex at runtime. Wildcards are easier for non-developers to write when adding new monitors and less error-prone than raw regex patterns.

### module #0  [metadata_id: 1590]

FileOps

### query #1  [metadata_id: 2272]
Title: Active configurations with schedule
Description: Shows all enabled monitors with their time windows and day-of-week schedule.

SELECT
    mc.config_name,
    sc.server_name,
    mc.sftp_path,
    mc.file_pattern,
    mc.check_start_time,
    mc.escalation_time,
    mc.check_end_time,
    CASE WHEN mc.check_monday = 1 THEN 'M' ELSE '-' END +
    CASE WHEN mc.check_tuesday = 1 THEN 'T' ELSE '-' END +
    CASE WHEN mc.check_wednesday = 1 THEN 'W' ELSE '-' END +
    CASE WHEN mc.check_thursday = 1 THEN 'R' ELSE '-' END +
    CASE WHEN mc.check_friday = 1 THEN 'F' ELSE '-' END +
    CASE WHEN mc.check_saturday = 1 THEN 'S' ELSE '-' END +
    CASE WHEN mc.check_sunday = 1 THEN 'U' ELSE '-' END AS schedule_days,
    mc.default_priority
FROM FileOps.MonitorConfig mc
JOIN FileOps.ServerConfig sc ON mc.server_id = sc.server_id
WHERE mc.is_enabled = 1
ORDER BY mc.check_start_time, mc.config_name;

### relationship_note #1  [metadata_id: 2275]
Title: ServerConfig

Each config references exactly one SFTP server via server_id. The server provides connection details while the config defines what to look for and when.

### relationship_note #2  [metadata_id: 2276]
Title: MonitorStatus

Each enabled config has exactly one corresponding MonitorStatus row showing current-day state. The status row is reset daily and deleted when the config is disabled.

### relationship_note #3  [metadata_id: 2277]
Title: MonitorLog

Each config generates MonitorLog entries over time — one per detection or escalation event. The log provides the historical view while MonitorStatus provides the real-time view.

### description / check_end_time #7  [metadata_id: 823]

When to stop checking entirely (hard stop)

### description / check_friday #14  [metadata_id: 830]

Check on Friday

### description / check_holidays #18  [metadata_id: 832]

Check on holidays (future enhancement)

### description / check_monday #10  [metadata_id: 826]

Check on Monday

### description / check_saturday #15  [metadata_id: 831]

Check on Saturday

### description / check_start_time #6  [metadata_id: 822]

When to begin checking for the file

### description / check_sunday #9  [metadata_id: 825]

Check on Sunday

### description / check_thursday #13  [metadata_id: 829]

Check on Thursday

### description / check_tuesday #11  [metadata_id: 827]

Check on Tuesday

### description / check_wednesday #12  [metadata_id: 828]

Check on Wednesday

### description / config_id #1  [metadata_id: 817]

Unique identifier for the monitor configuration

### description / config_name #3  [metadata_id: 819]

Friendly name for this monitor (e.g., Instream Daily)

### description / create_jira_on_escalation #22  [metadata_id: 836]

Create Jira ticket when escalation time is reached without file

### description / created_dttm #24  [metadata_id: 838]

When the record was created

### description / default_priority #23  [metadata_id: 837]

Jira ticket priority: Highest, High, Medium, Low

### description / escalation_time #8  [metadata_id: 824]

When to escalate if file not found (Teams + Jira)

### description / file_pattern #5  [metadata_id: 821]

Wildcard pattern to match files (e.g., instream.CRSFrostArnet*txt*)

### description / is_enabled #19  [metadata_id: 833]

Whether this monitor is active

### description / modified_dttm #25  [metadata_id: 839]

When the record was last modified

### description / notify_on_detection #20  [metadata_id: 834]

Send Teams alert when file is detected

### description / notify_on_escalation #21  [metadata_id: 835]

Send Teams alert when escalation time is reached without file

### description / server_id #2  [metadata_id: 818]

FK to [FileOps - ServerConfig] for SFTP connection details

### description / sftp_path #4  [metadata_id: 820]

Directory path on SFTP server (e.g., /Instream/)

## MonitorLog (Table)

### category #0  [metadata_id: 1695]

FileOps

### data_flow #0  [metadata_id: 2246]

Scan-SFTPFiles.ps1 inserts a row whenever a meaningful event occurs: file detection, escalation, or late detection. Each row captures the event context including config details, detected filename, timestamp, and whether Teams and Jira integrations were triggered. This is an append-only audit trail — rows are never updated or deleted. Used for historical analysis of on-time rates, escalation frequency, and late arrival patterns.

### description #0  [metadata_id: 118]

Historical log of file detection and escalation events. Records only meaningful outcomes (Detected, Escalated, LateDetected) without the noise of routine monitoring checks.

### design_note #1  [metadata_id: 2255]
Title: Events Only

Only meaningful outcomes are logged — Detected, Escalated, and LateDetected. Routine monitoring checks that find nothing are not recorded. This keeps the table focused and queryable for operational analysis without filling it with noise.

### design_note #2  [metadata_id: 2256]
Title: Denormalized Context

config_name and sftp_path are copied from MonitorConfig at event time. This allows standalone querying without joins and preserves the values as they were when the event occurred, even if the config is later modified.

### module #0  [metadata_id: 1591]

FileOps

### query #1  [metadata_id: 2270]
Title: Recent events
Description: Shows the last 7 days of file monitoring events with integration status.

SELECT
    config_name,
    log_date,
    event_type,
    file_detected_name,
    event_dttm,
    teams_alert_queued,
    jira_ticket_queued
FROM FileOps.MonitorLog
WHERE log_date >= DATEADD(DAY, -7, CAST(GETDATE() AS DATE))
ORDER BY event_dttm DESC;

### query #2  [metadata_id: 2271]
Title: Escalation frequency by config
Description: Shows how often each monitor escalates over the last 30 days for identifying chronic late files.

SELECT
    config_name,
    COUNT(*) AS escalation_count,
    MIN(event_dttm) AS first_escalation,
    MAX(event_dttm) AS last_escalation
FROM FileOps.MonitorLog
WHERE event_type = 'Escalated'
    AND log_date >= DATEADD(DAY, -30, CAST(GETDATE() AS DATE))
GROUP BY config_name
ORDER BY escalation_count DESC;

### relationship_note #1  [metadata_id: 2280]
Title: MonitorConfig

Each log entry references its source config via config_id. Denormalized config_name and sftp_path allow standalone querying without requiring the config to still exist.

### relationship_note #2  [metadata_id: 2281]
Title: Teams.AlertQueue

When teams_alert_queued = 1, a corresponding row was inserted into Teams.AlertQueue via sp_QueueAlert at the same time as the log entry. The Teams integration processes the alert asynchronously.

### relationship_note #3  [metadata_id: 2282]
Title: Jira.TicketQueue

When jira_ticket_queued = 1, a corresponding row was inserted into Jira.TicketQueue via sp_QueueTicket at the same time as the log entry. The Jira integration processes the ticket asynchronously.

### description / config_id #2  [metadata_id: 1379]

FK to [FileOps - MonitorConfig]

### description / config_name #3  [metadata_id: 1380]

Denormalized from MonitorConfig

### description / created_dttm #11  [metadata_id: 1388]

When the log entry was created

### description / event_dttm #8  [metadata_id: 1385]

Exact timestamp of the event

### description / event_type #6  [metadata_id: 1383]

Type of event: Detected, Escalated, or LateDetected

### status_value / event_type #1  [metadata_id: 2263]
Title: Detected

File matching the configured pattern was found during the normal monitoring window before escalation time.

### status_value / event_type #2  [metadata_id: 2264]
Title: Escalated

Escalation time passed without file detection. Teams WARNING alert queued and Jira ticket created if configured.

### status_value / event_type #3  [metadata_id: 2265]
Title: LateDetected

File arrived after escalation had already occurred. Logged as a separate event to record the late arrival without undoing the escalation record.

### description / file_detected_name #7  [metadata_id: 1384]

Filename that was detected (if applicable)

### description / jira_ticket_queued #10  [metadata_id: 1387]

Whether a Jira ticket was queued for this event

### description / log_date #5  [metadata_id: 1382]

Calendar date of the event

### description / log_id #1  [metadata_id: 1378]

Unique identifier for this log entry

### description / sftp_path #4  [metadata_id: 1381]

Denormalized from MonitorConfig

### description / teams_alert_queued #9  [metadata_id: 1386]

Whether a Teams alert was queued for this event

## MonitorStatus (Table)

### category #0  [metadata_id: 1696]

FileOps

### data_flow #0  [metadata_id: 2245]

Scan-SFTPFiles.ps1 creates or resets one row per active config at the start of each monitoring window, setting last_status to Monitoring. During each scan cycle the script updates last_scanned_dttm, and transitions last_status to Detected or Escalated based on file presence and escalation time. Late-arriving files populate file_detected_dttm while last_status remains Escalated. Rows for disabled configs are automatically deleted during cleanup. The Control Center FileOps dashboard reads this table for real-time status display.

### description #0  [metadata_id: 35]

Dashboard table showing current monitoring state for each active file configuration. Displays the last known status and scan time, with automatic daily reset at the start of each monitoring window.

### design_note #1  [metadata_id: 2252]
Title: Dashboard Model

One row per config via the unique constraint on config_id. This is a real-time dashboard, not a historical record. The row is reset at the start of each monitoring window rather than creating new rows per day.

### design_note #2  [metadata_id: 2253]
Title: Escalation Persistence

Once last_status transitions to Escalated, it remains Escalated even if the file arrives late. The late arrival is recorded in file_detected_dttm to provide the full picture without masking the fact that an escalation occurred.

### design_note #3  [metadata_id: 2254]
Title: Naming Convention: last_status

The column is named last_status rather than status to reflect that it shows the state as of the most recent scan. After the monitoring window closes, the value persists as a historical snapshot until the next window resets it.

### module #0  [metadata_id: 1592]

FileOps

### query #1  [metadata_id: 2269]
Title: Current monitoring dashboard
Description: Shows the real-time status of all active file monitors with timing details.

SELECT
    ms.config_name,
    ms.sftp_path,
    ms.last_status,
    ms.last_scanned_dttm,
    ms.file_detected_name,
    ms.file_detected_dttm,
    ms.escalated_dttm,
    mc.check_start_time,
    mc.escalation_time,
    mc.check_end_time
FROM FileOps.MonitorStatus ms
JOIN FileOps.MonitorConfig mc ON ms.config_id = mc.config_id
ORDER BY ms.last_status DESC, ms.config_name;

### relationship_note #1  [metadata_id: 2278]
Title: MonitorConfig

One status row per enabled config via the unique constraint on config_id. The config defines the monitoring rules; the status row tracks execution against those rules for the current day.

### relationship_note #2  [metadata_id: 2279]
Title: MonitorLog

Status and Log serve complementary roles. MonitorStatus is the real-time dashboard (one row, constantly updated). MonitorLog is the audit trail (many rows, append-only). A single escalation event updates MonitorStatus and inserts into MonitorLog simultaneously.

### description / config_id #2  [metadata_id: 155]

FK to [FileOps - MonitorConfig]

### description / config_name #3  [metadata_id: 156]

Denormalized from MonitorConfig for easy querying

### description / escalated_dttm #10  [metadata_id: 162]

When escalation occurred (if applicable)

### description / file_detected_dttm #9  [metadata_id: 161]

When the file was detected

### description / file_detected_name #8  [metadata_id: 160]

Actual filename that matched the pattern

### description / last_scanned_dttm #7  [metadata_id: 159]

When this config was last scanned by the monitor script

### description / last_status #6  [metadata_id: 158]

Status as of last scan: Monitoring, Detected, Escalated

### status_value / last_status #1  [metadata_id: 2266]
Title: Monitoring

Active monitoring in progress. Set when the monitoring window opens each day and on every scan cycle where the file has not yet been detected or escalated.

### status_value / last_status #2  [metadata_id: 2267]
Title: Detected

File matching the configured pattern was found. Terminal state for the day — scanning continues but status will not change.

### status_value / last_status #3  [metadata_id: 2268]
Title: Escalated

Escalation time passed without detection. Transitions to LateDetected if the file arrives after escalation. The escalated_dttm is recorded when this status is first set.

### status_value / last_status #4  [metadata_id: 2288]
Title: LateDetected

File arrived after escalation had already occurred. Transitions from Escalated to prevent re-detection alerts on subsequent scan cycles. The escalated_dttm is preserved to retain the full timeline.

### description / sftp_path #4  [metadata_id: 157]

Denormalized from MonitorConfig for easy querying

### description / status_id #1  [metadata_id: 154]

Unique identifier for this status record

## Scan-SFTPFiles.ps1 (Script)

### category #0  [metadata_id: 2242]

FileOps

### data_flow #0  [metadata_id: 2248]

Reads MonitorConfig joined to ServerConfig for active configurations within the current check window. Retrieves encrypted SFTP credentials from dbo.Credentials via the master passphrase in dbo.GlobalConfig. Connects to SFTP servers using WinSCP .NET assembly, scans directories for pattern-matched files, then writes results to MonitorStatus (upsert) and MonitorLog (insert). Queues Teams alerts via Teams.sp_QueueAlert and Jira tickets via Jira.sp_QueueTicket based on per-config notification settings.

### description #0  [metadata_id: 2240]

Execution engine for FileOps. Scans configured SFTP locations for expected files on a scheduled interval, manages detection and escalation state in MonitorStatus, logs events to MonitorLog, and queues Teams alerts and Jira tickets through the integration modules.

### design_note #1  [metadata_id: 2258]
Title: All Logic in PowerShell

Unlike other xFACts modules that split logic between stored procedures and scripts, FileOps puts all business logic in the PowerShell script. This simplifies the architecture for a module whose primary operation is external I/O (SFTP scanning) rather than data processing.

### design_note #2  [metadata_id: 2259]
Title: Grouped SFTP Connections

Configurations are grouped by server before scanning. All configs sharing a server use a single credential retrieval and SFTP session, minimizing connection overhead and credential lookups when multiple file monitors target the same server.

### design_note #3  [metadata_id: 2260]
Title: Daily Window Reset

The script detects a new monitoring window by comparing last_scanned_dttm to the current date. When the dates differ, MonitorStatus is reset to Monitoring with cleared detection and escalation fields. This eliminates the need for a separate scheduled reset job.

### module #0  [metadata_id: 2241]

FileOps

### relationship_note #1  [metadata_id: 2283]
Title: MonitorConfig + ServerConfig

The script joins these two tables to build its work list each cycle. MonitorConfig provides monitoring rules and day/time filters. ServerConfig provides SFTP connection details and credential references.

### relationship_note #2  [metadata_id: 2284]
Title: MonitorStatus + MonitorLog

Both are written by the script during each cycle. MonitorStatus is upserted for real-time dashboard state. MonitorLog receives insert-only event records for audit trail. Both writes happen in the same logical operation.

### relationship_note #3  [metadata_id: 2285]
Title: Teams + Jira Integration

Alert and ticket creation is delegated to Teams.sp_QueueAlert and Jira.sp_QueueTicket. The script queues requests based on per-config notification flags (notify_on_detection, notify_on_escalation, create_jira_on_escalation) and never calls the APIs directly.

## ServerConfig (Table)

### category #0  [metadata_id: 1697]

FileOps

### data_flow #0  [metadata_id: 2243]

Rows are created manually or via sp_AddNewMonitorConfig when establishing a new SFTP server connection. Scan-SFTPFiles.ps1 reads ServerConfig joined to MonitorConfig to resolve SFTP connection details and credential references for each monitoring cycle. The credential_service_name links to dbo.Credentials for encrypted username/password retrieval at runtime.

### description #0  [metadata_id: 94]

Configuration table defining SFTP servers and their credential references for file monitoring operations.

### design_note #1  [metadata_id: 2257]
Title: Credential Separation

ServerConfig stores connection metadata (host, port) but references credentials indirectly via credential_service_name linking to dbo.Credentials. This keeps sensitive authentication data in a single secure location with encryption rather than duplicating secrets across tables.

### module #0  [metadata_id: 1593]

FileOps

### relationship_note #1  [metadata_id: 2273]
Title: MonitorConfig

One server supports many monitor configurations. All configs referencing the same server share a single SFTP connection during each scan cycle.

### relationship_note #2  [metadata_id: 2274]
Title: dbo.Credentials

The credential_service_name column references a ServiceName in dbo.Credentials, not a direct foreign key. Scan-SFTPFiles.ps1 decrypts credentials at runtime using the master passphrase from dbo.GlobalConfig.

### description / created_dttm #7  [metadata_id: 1033]

When the record was created

### description / credential_service_name #5  [metadata_id: 1031]

ServiceName in [Core - Credentials] for authentication

### description / is_enabled #6  [metadata_id: 1032]

Whether this server is active for monitoring

### description / modified_dttm #8  [metadata_id: 1034]

When the record was last modified

### description / server_id #1  [metadata_id: 1027]

Unique identifier for the server configuration

### description / server_name #2  [metadata_id: 1028]

Friendly name for the server (e.g., Joker)

### description / sftp_host #3  [metadata_id: 1029]

Hostname or IP address of the SFTP server

### description / sftp_port #4  [metadata_id: 1030]

SFTP port number

## sp_AddNewMonitorConfig (Procedure)

### category #0  [metadata_id: 1698]

FileOps

### data_flow #0  [metadata_id: 2247]

Accepts configuration parameters, validates against ServerConfig for server existence, checks for duplicate config names and file patterns in MonitorConfig, validates time window logic and priority values, then inserts a new row into MonitorConfig. Preview mode (default) shows what would be created without committing. Returns the new config_id on success.

### description #0  [metadata_id: 42]

Stored procedure for adding new file monitor configurations with built-in validation and preview mode.

### design_note #1  [metadata_id: 2261]
Title: Preview Mode Default

The @PreviewOnly parameter defaults to true (1), requiring an explicit opt-in to commit changes. This prevents accidental configuration creation and lets operators review exactly what will be inserted before committing.

### design_note #2  [metadata_id: 2262]
Title: Legacy Convenience Procedure

This procedure predates the Control Center UI. The Control Center now provides the primary interface for adding file monitors, making this procedure a backup option for direct SQL-based configuration when needed.

### module #0  [metadata_id: 1594]

FileOps

### relationship_note #1  [metadata_id: 2286]
Title: ServerConfig

Validates that the specified @ServerID exists and is enabled in ServerConfig before allowing configuration creation. A disabled or missing server rejects the insert.

### relationship_note #2  [metadata_id: 2287]
Title: MonitorConfig

Target table for the insert. The procedure validates against existing rows for duplicate config names and overlapping file patterns before creating the new configuration.

## TR_FileOps_MonitorLog_DisableETL_OneGI (Trigger)

### category #0  [metadata_id: 5143]

FileOps

### data_flow #0  [metadata_id: 5144]

Fires when File Monitoring writes an escalation row (event_type = 'Escalated') to FileOps.MonitorLog for one of the four OneGI monitored files (config_id 77, 78, 79, 80). When any such row is inserted, the trigger performs a same-instance cross-database update to Integration.etl.tbl_B2B_CLIENTS_FILES, setting ACTIVE_FLAG = 0 for CLIENT_ID 10678, SEQ_ID 1 through 6, which turns off the IBM/B2B scheduler automation for those six process rows.

### description #0  [metadata_id: 5141]

AFTER INSERT trigger on FileOps.MonitorLog that disables the IBM/B2B ETL automation for the OneGI client's process rows when any of its four monitored escalation files logs an escalation.

### design_note #1  [metadata_id: 5145]
Title: Cross-Database Write

This trigger runs a cross-database write inside the MonitorLog insert transaction. The escalation check is set-based (EXISTS against the inserted rows) so it fires correctly whether one or up to four files escalate in a single insert, and the UPDATE is idempotent via WHERE ACTIVE_FLAG = 1.

### module #0  [metadata_id: 5142]

FileOps

### query #1  [metadata_id: 5147]
Title: Verify trigger is enabled
Description: Check if the trigger is active

SELECT name, is_disabled
FROM sys.triggers
WHERE name = 'TR_FileOps_MonitorLog_DisableETL_OneGI';

### relationship_note #1  [metadata_id: 5146]
Title: Integration.etl.tbl_B2B_CLIENTS_FILES

Updates ACTIVE_FLAG on the six OneGI process rows (CLIENT_ID 10678, SEQ_ID 1-6) in the Integration database's B2B client-files table. Setting ACTIVE_FLAG = 0 stops the IBM/B2B scheduler from automatically triggering those processes. The trigger only reaches this table when a OneGI escalation (config_id 77-80) is logged to FileOps.MonitorLog.

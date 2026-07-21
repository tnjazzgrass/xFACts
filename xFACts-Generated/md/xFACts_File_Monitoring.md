# File Monitoring

*Because “has anyone checked if the file showed up?” is not a monitoring strategy*

FileOps is xFACts' early warning system for incoming files. It watches SFTP directories on a schedule, sends a friendly heads-up when files arrive, and raises the alarm when they don't. It's the difference between "we caught it with two hours to spare" and "so, about yesterday's payments…"






The Problem With Files

Files are like pizza delivery. When they show up on time, nobody thinks twice. When they don't show up, suddenly everyone's hangry and looking for someone to blame.

We receive files from clients every day. Some of them are mildly important. Others feed directly into payment processing, batch jobs, and operations with hard deadlines and zero sense of humor about tardiness. Miss the file, miss the deadline. Miss the deadline, and suddenly there's frantic scrambling, apologetic emails, and that particular kind of stress that makes people forget they ever liked their jobs.

The old way of handling this? Someone would notice. Eventually. Maybe at 3pm when processing was supposed to start at noon. Maybe the next morning. Maybe when a client called asking why their payments didn't go through.

Not ideal.






Enter FileOps

FileOps is the very attentive receptionist who's been told exactly which packages to expect and when. Package arrives? *"Your delivery is here!"* Package late? *"Um, that thing you were waiting for? It's not here and you said it was important, so I'm letting everyone know."*

It watches the SFTP server like a hawk with a clipboard, checking for expected files on a configurable schedule. When a file arrives, FileOps logs it and sends a Teams notification. When a file *doesn’t* arrive by deadline, FileOps sounds the alarm — Teams alert, Jira ticket, all hands on deck.



Wake Up
→
Check Configs
→
Scan SFTP
→
Log & Alert
→
Sleep

On a configurable schedule, forever. FileOps doesn’t take days off.


The whole thing is configuration-driven. Want to monitor a new file? Add a row. Want to change the escalation time? Update a value. Want to stop monitoring something? Flip a bit. No code changes, no deployments, no bothering anyone on the Applications team (well, maybe a thank-you email).






A Day in the Life

Let's follow the Instream Daily file through a typical day.

**8:00 AM** — FileOps wakes up. Well, it was already awake — it never sleeps. It checks the config: *"Instream Daily, check /Instream/ folder, look for files matching the pattern, weekdays only."* Today's Monday, so we're on. Status: **Monitoring**.

**8:05 AM** — First scan. No file yet. FileOps shrugs (metaphorically) and waits.

**8:10, 8:15, 8:20…** — Same story. Scan, no file, wait. FileOps is patient. FileOps has nowhere else to be.

**9:47 AM** — Wait, what's this? A file! It matches the pattern! FileOps updates the status to **Detected**, logs the event, and fires off a Teams message: *"File Detected — Instream Daily."* Someone in the channel sees it, nods approvingly, goes back to their coffee.

**For the rest of the day** — FileOps moves on. That config is handled for today. Tomorrow, we do it all again.


This is the happy path. Most days look like this. File arrives, we note it, everyone's happy, life goes on. But the reason FileOps exists isn't for the good days. It's for the other kind.







When Things Go Wrong

Same file. Different day. This time the universe has other plans.

**8:00 AM** — FileOps starts monitoring. Status: **Monitoring**.

**9:00, 10:00, 11:00, 12:00…** — No file. FileOps keeps checking. If FileOps had feelings, it would be getting concerned. But it doesn't. Because it's code.

**1:00 PM** — Escalation time. The config says if there's no file by 1pm, we have a problem. FileOps springs into action:

| Action | Detail |
| --- | --- |
| Status update | **Escalated** |
| Teams alert | WARNING — "File Not Detected — Instream Daily" |
| Jira ticket | "Critical Payment Process Check — Instream Daily" |


Now humans are involved. The ticket gets assigned, someone investigates, hopefully the file gets retrieved manually before the 3pm deadline.

**1:23 PM** — Plot twist! The file finally shows up. FileOps notices on its next scan. It can't undo the escalation — the ticket's already out there — but it updates the status to **LateDetected** and sends an INFO alert: *"File Detected (Late) — Instream Daily."* Now the dashboard shows the complete story: yes, we escalated, and yes, the file eventually made it.


**Why a separate status?** LateDetected is its own state, not a return to Detected. It tells you two things at a glance: escalation happened, *and* the file arrived. It also prevents FileOps from re-alerting on every subsequent scan cycle — once you're LateDetected, you're done for the day.







The Night Shift

Not all files keep business hours. The PnS files (Pay-n-Seconds, for the curious) arrive in the wee hours:

**2:30 AM** — FileOps starts watching the /paynseconds/ folder for two files: ACH and CC.

**2:45 AM** — An automated process tries to pull these files from the client. If they're there, great. If not, nothing gets pulled.

**3:30 AM** — Escalation time. If either file is missing, Teams alert and Jira ticket. This gives someone about 25 minutes to manually retrieve the files before processing kicks off at 3:55 AM.

**4:00 AM** — FileOps stops checking. What's done is done. Either the files made it or they didn't.

And yes, this runs 7 days a week. Files don't take weekends off, and neither does FileOps.






The Cast of Characters



Joker
No, not that Joker. This is our internal SFTP server where client files land. Joker holds the files; FileOps watches for them. They have a good working relationship. Joker doesn’t say much (being a server and all), but FileOps checks in regularly to see what’s new.


The Configs
Each file we monitor gets its own configuration entry. The config says what server to check, what folder to look in, what the file looks like, when to start looking, when to panic if it's not there, and when to stop looking entirely. It's a complete description of the anxiety cycle, in database form.



| Object | Type | What It Does |
| --- | --- | --- |
| `ServerConfig` | Table | SFTP servers and their credential references (currently just Joker) |
| `MonitorConfig` | Table | What files to watch, when to watch, when to panic |
| `MonitorStatus` | Table | Today's real-time status — Monitoring, Detected, Escalated, or LateDetected |
| `MonitorLog` | Table | Historical record of detections and escalations |
| `sp_AddNewMonitorConfig` | Procedure | Validated way to add new monitors (backup to Control Center UI) |
| `Scan-SFTPFiles.ps1` | Script | The execution engine — connects, scans, evaluates, alerts |


For the end-to-end data flows, process lifecycle, and technical details, see the File Monitoring Architecture page.






Why This Matters

Before FileOps, discovering a missing file was reactive. Someone would notice, usually too late, usually in a panic. The process to recover involved frantic emails, phone calls, and hoping there was still time.

Now? FileOps gives a 25-minute to 2-hour warning window depending on the file. That's the difference between *"we can fix this"* and *"we're explaining to a client why their payments didn't process."*

It's not glamorous work. Watching folders, matching patterns, sending alerts. But it's the kind of work that, when done well, means other people don't have to have bad days.

And that's worth waking up at 2:30 AM for. Even if you're code.

---

# File Monitoring — Control Center Guide

---

## Architecture
# File Monitoring Architecture

The narrative page tells you *what* FileOps does and *why*. This page tells you *how*. One script, four tables, one stored procedure, and a surprisingly elegant state machine that turns "is the file here yet?" into a fully automated monitoring pipeline.



Schema Overview

FileOps is one of the smallest schemas in xFACts, which is part of its charm. Four tables, one procedure, one script. Everything has a clear job and nothing is trying to be clever.



The data model follows a clean hierarchy. `ServerConfig` defines where to connect. `MonitorConfig` defines what to look for and when. `MonitorStatus` tracks today's state. `MonitorLog` records history. The separation between real-time state and historical events is the most important design decision in the schema — it keeps the dashboard fast and the audit trail complete.

| Table | Role | Cardinality |
| --- | --- | --- |
| `ServerConfig` | SFTP server definitions | One per server (currently 1) |
| `MonitorConfig` | Monitoring rules | Many per server |
| `MonitorStatus` | Real-time dashboard state | One per enabled config (unique on config_id) |
| `MonitorLog` | Event audit trail | Many per config over time |



Why two output tables? MonitorStatus is a dashboard — one row per config, constantly overwritten, answers "what's happening right now?" MonitorLog is a ledger — append-only, never modified, answers "what happened and when?" Trying to serve both purposes with one table would mean either a noisy dashboard or a lossy audit trail. Neither is acceptable.







The Scan Lifecycle

`Scan-SFTPFiles.ps1` is the only moving part. Everything else is data. Here's what happens every time the orchestrator says "your turn."





Build Work List
Active configs
in today’s window

→

Get Credentials
Group by server
One session per server

→

Scan SFTP
List directory
Match file pattern

→

Evaluate
Found? Escalation due?
Already detected?

→

Update & Alert
Status + Log
+ Teams/Jira


Per server group, per cycle. Daily window reset happens automatically on the first scan of each new day.


Step 1: Build the Work List

The script queries `MonitorConfig` joined to `ServerConfig`, filtering for configs that are enabled, scheduled for today's day of the week, and within the current check window (between `check_start_time` and `check_end_time`). Outside the window? Nothing to do.

Step 2: Group by Server

Configs are grouped by `credential_service_name` so that all monitors targeting the same SFTP server share a single credential retrieval and connection. If you've got six files on Joker, that's one SFTP session, not six.

Step 3: Daily Window Reset

For each config, the script checks whether `MonitorStatus.last_scanned_dttm` is from a previous date. If so, it's a new monitoring day — the status row gets reset to **Monitoring** with cleared detection and escalation fields. This eliminates the need for a separate scheduled reset job.

Step 4: Scan and Evaluate

The script connects via WinSCP, lists the directory, and matches files against the configured pattern (wildcards converted to regex at runtime). The result falls into exactly one of four cases:

| Condition | Action | Status |
| --- | --- | --- |
| Already Detected or LateDetected today | Update `last_scanned_dttm` only | No change |
| File found, not yet escalated | Log Detected, queue Teams INFO | → **Detected** |
| File found, already escalated | Log LateDetected, queue Teams INFO | → **LateDetected** |
| No file, past escalation time | Log Escalated, queue Teams WARNING + Jira | → **Escalated** |
| No file, still within window | Update `last_scanned_dttm` only | Stays **Monitoring** |



Already Detected or LateDetected = skip scan. Once a file is detected (or detected late), the script doesn't bother connecting to SFTP again for that config. It just updates the timestamp and moves on. No wasted connections, no redundant alerts.



Client Data Archive fallback. When the SFTP scan finds nothing, the script checks the Client Data Archive as a secondary source. This catches files that were consumed by another process between scan cycles — the file existed on SFTP briefly but was picked up before FileOps could see it. The CDA path is configured via `GlobalConfig` and gracefully disables when the setting is absent.







The Status Machine

`MonitorStatus.last_status` has exactly four valid values. The transitions between them tell the full story of a file's monitoring day.





Monitoring
Window open
Scanning each cycle

→

Found?

Detected
Escalated


→

LateDetected
File arrives
after escalation


Detected and LateDetected are both terminal for the day. Resets automatically on the first scan of the next monitoring window.


| Status | Meaning | Transitions To |
| --- | --- | --- |
| **Monitoring** | Window is open, actively scanning, file not yet found | Detected *or* Escalated |
| **Detected** | File found before escalation time | Terminal for the day |
| **Escalated** | Escalation time passed without detection | LateDetected (if file arrives) |
| **LateDetected** | File arrived after escalation occurred | Terminal for the day |


Key design point: Detected and LateDetected are both terminal states. Once you're there, you stay there until the next morning's window reset. This prevents alert storms, status flickering, and general confusion about what actually happened. LateDetected also serves a practical purpose — it stops the script from re-alerting on every subsequent scan cycle by marking the late arrival as handled.


Why "last_status" and not "status"? Because after the monitoring window closes, the value persists as a snapshot of the last known state. Calling it `last_status` makes it clear that you're looking at "the status as of the last scan" rather than "the current live status" — an important distinction when you're reading it at 5pm and the window closed at 3pm.







Alert Integration

FileOps never talks to Teams or Jira directly. It queues requests through the platform's integration modules and lets them handle delivery. This is the same pattern used by every other module in xFACts — FileOps just decides *what* to say, not *how* to say it.

Teams Alerts

| Event | Category | Title Pattern |
| --- | --- | --- |
| File detected | INFO | xFACts: File Detected — {ConfigName} — {Date} |
| File detected late | INFO | xFACTs: File Detected (Late) — {ConfigName} — {Date} |
| Escalation | WARNING | xFACTs: File Not Detected — {ConfigName} — {Date} |


Alerts are queued via `Teams.sp_QueueAlert` and picked up by `Process-TeamsAlertQueue.ps1` within seconds. The per-config `notify_on_detection` and `notify_on_escalation` flags control which events generate alerts.


Late detection notification logic: Late detections use a broader rule than normal detections. The script queues a Teams alert if *either* `notify_on_detection` or `notify_on_escalation` is enabled. The reasoning: if you cared enough to be notified about the escalation, you also want to know the file eventually showed up. This means teams subscribed only to escalation alerts (like Operations) will still receive the "File Detected (Late)" notification even though they wouldn't receive a normal detection alert. The category is INFO (not WARNING), so the card renders as informational rather than urgent.


Jira Tickets

Escalations can optionally create Jira tickets. When `create_jira_on_escalation = 1`, the script queues a ticket via `Jira.sp_QueueTicket` with:

| Field | Value |
| --- | --- |
| Project | SD |
| Issue Type | Issue |
| Priority | From `MonitorConfig.default_priority` |
| Summary | Critical Payment Process Check — {ConfigName} — {Date} |
| Cascading Field | File Processing → Payment File Issue |



Integration tracking: When a Teams alert or Jira ticket is queued, the corresponding `MonitorLog` entry records `teams_alert_queued = 1` or `jira_ticket_queued = 1`. This creates a traceable link between the monitoring event and the downstream notification, even though the actual delivery happens asynchronously.







How To: Add a New File Monitor

The Control Center’s File Monitoring page provides a built-in interface for adding new monitors. This is the recommended approach — it validates inputs, handles the database writes, and lets you configure everything in a single view.



**Open the File Monitoring page** in Control Center and click the add monitor button.
The slide-up modal provides all configuration fields in one view.


**Select the SFTP server** from the available servers defined in `ServerConfig`.
Currently only Joker is configured. New servers need a `ServerConfig` row and corresponding credentials in `dbo.Credentials`.


**Set the monitor identity:** config name (descriptive label), SFTP path (directory to scan), and file pattern (wildcard match like `instream.CRSFrostArnet*txt*`).


**Configure the schedule:** which days of the week to monitor, the check window start and end times, and the escalation time (when to alert if the file hasn’t arrived).


**Set alert preferences:** toggle detection notifications, escalation notifications, and Jira ticket creation independently. Set the default Jira priority for escalation tickets.


**Save and verify.** The new monitor will be picked up on the next scan cycle that falls within the configured window. Check `MonitorStatus` for a row with status **Monitoring** to confirm.



**Direct SQL alternative:** `FileOps.sp_AddNewMonitorConfig` provides the same functionality via stored procedure for scripted or bulk configuration. It performs the same validation as the UI and creates both the `MonitorConfig` and initial `MonitorStatus` rows.







Credential Flow

FileOps never stores credentials directly. `ServerConfig` holds a `credential_service_name` that points to the encrypted credentials in `dbo.Credentials`. At runtime, the script decrypts them using a two-layer encryption hierarchy:





GlobalConfig
Read master
passphrase

→

Credentials
Decrypt service
passphrase

→

Decrypt Secrets
SFTP username
+ password

→

SFTP Session
WinSCP connection
per server group

→

Dispose
Session closed
Credentials released


Two-tier decryption. Nothing cached to disk. WinSCP sessions explicitly disposed after each server group.


Decrypted credentials exist only in memory for the duration of the SFTP session. Nothing is written to disk, nothing is logged, and WinSCP sessions are explicitly disposed after each server group completes. If the master passphrase is wrong or missing, the script fails loudly rather than silently connecting to nothing.






Troubleshooting

**“A file arrived but no notification was sent.”**
Check `MonitorConfig` — is `notify_on_detection` enabled for that config? Also verify the file matched the configured pattern. Check `MonitorLog` for a Detected entry — if it’s there, the detection worked but notification may have been suppressed by the flag.

**“The monitor didn’t scan today.”**
Check three things: is the config enabled (`is_active = 1`)? Is today in the schedule (`check_days_of_week`)? Is the current time within the check window? Also verify the orchestrator is running and the FileOps process is active in ProcessRegistry.

**“SFTP connection failures.”**
Check `dbo.Credentials` for the service referenced by `ServerConfig.credential_service_name`. Verify the master passphrase in GlobalConfig is correct. WinSCP connection failures are logged in the orchestrator TaskLog with error details.

**“Escalation fired but the file was there.”**
The file may have arrived after the escalation time but before the next scan. Also check the file pattern — a slight naming variation (date format, extra suffix) can cause a mismatch. The CDA fallback can catch files consumed between cycles, but only if the GlobalConfig path is configured.

**“A config shows Monitoring but the window has passed.”**
If the file never arrived and the escalation time wasn’t reached before the check window ended, the status stays at Monitoring. This is by design — no escalation is triggered if the window closes before the escalation deadline. Review whether the escalation time should be before the window end.






How Everything Connects

FileOps is a self-contained module with three external dependencies: the orchestrator (for scheduling), the credential system (for SFTP authentication), and the Teams/Jira integration modules (for notifications). Everything else is internal to the FileOps schema.

Internal Flow

| From | To | Relationship |
| --- | --- | --- |
| `ServerConfig` | `MonitorConfig` | One server → many configs (FK on `server_id`) |
| `MonitorConfig` | `MonitorStatus` | One config → one status (unique constraint on `config_id`) |
| `MonitorConfig` | `MonitorLog` | One config → many events over time (FK on `config_id`) |
| `Scan-SFTPFiles.ps1` | All tables | Reads configs, writes status + log |


External Dependencies

| Dependency | Module | Purpose |
| --- | --- | --- |
| `Orchestrator.ProcessRegistry` | Orchestrator | Schedules Scan-SFTPFiles.ps1 execution |
| `dbo.Credentials` | Shared Infrastructure | Encrypted SFTP credentials |
| `dbo.GlobalConfig` | Shared Infrastructure | Master passphrase for credential decryption; CDA base path for fallback file detection (gracefully disables when absent) |
| `Teams.sp_QueueAlert` | Teams Integration | Alert delivery |
| `Jira.sp_QueueTicket` | Jira Integration | Ticket creation |

---

## Reference

### MonitorConfig

Configuration table defining files to monitor, including SFTP paths, file patterns, check schedules, and escalation settings.

**Data Flow:** Rows are created via sp_AddNewMonitorConfig or the Control Center UI. Scan-SFTPFiles.ps1 queries active configurations each cycle, filtering by is_enabled, current day-of-week flags, and whether the current time falls within the check_start_time to check_end_time window. MonitorConfig is read-only during monitoring — the script never modifies configuration rows. The Control Center FileOps page reads this table for configuration display and management.

**Three Time Points:** [sort:1] Each config defines check_start_time, escalation_time, and check_end_time as separate values. This allows monitoring to continue after escalation to catch late-arriving files rather than giving up at the escalation threshold.

**Individual Day Columns:** [sort:2] Seven separate BIT columns (check_sunday through check_saturday) replace a single weekday/weekend flag. This supports any schedule pattern — weekdays only, daily, specific days, or weekly — without requiring a separate schedule table or bitmask logic.

**Wildcard Pattern Matching:** [sort:3] The file_pattern field uses * and ? wildcards rather than regex. Scan-SFTPFiles.ps1 converts these to regex at runtime. Wildcards are easier for non-developers to write when adding new monitors and less error-prone than raw regex patterns.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| config_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the monitor configuration |
| server_id | int | No | — | FK to [FileOps - ServerConfig] for SFTP connection details |
| config_name | varchar(100) | No | — | Friendly name for this monitor (e.g., Instream Daily) |
| sftp_path | varchar(500) | No | — | Directory path on SFTP server (e.g., /Instream/) |
| file_pattern | varchar(255) | No | — | Wildcard pattern to match files (e.g., instream.CRSFrostArnet*txt*) |
| check_start_time | time | No | — | When to begin checking for the file |
| check_end_time | time | No | — | When to stop checking entirely (hard stop) |
| escalation_time | time | No | — | When to escalate if file not found (Teams + Jira) |
| check_sunday | bit | No | 0 | Check on Sunday |
| check_monday | bit | No | 1 | Check on Monday |
| check_tuesday | bit | No | 1 | Check on Tuesday |
| check_wednesday | bit | No | 1 | Check on Wednesday |
| check_thursday | bit | No | 1 | Check on Thursday |
| check_friday | bit | No | 1 | Check on Friday |
| check_saturday | bit | No | 0 | Check on Saturday |
| check_holidays | bit | No | 0 | Check on holidays (future enhancement) |
| is_enabled | bit | No | 1 | Whether this monitor is active |
| notify_on_detection | bit | No | 0 | Send Teams alert when file is detected |
| notify_on_escalation | bit | No | 1 | Send Teams alert when escalation time is reached without file |
| create_jira_on_escalation | bit | No | 1 | Create Jira ticket when escalation time is reached without file |
| default_priority | varchar(20) | No | 'High' | Jira ticket priority: Highest, High, Medium, Low |
| created_dttm | datetime | No | getdate() | When the record was created |
| modified_dttm | datetime | Yes | — | When the record was last modified |

  - **PK_MonitorConfig** (CLUSTERED): config_id -- PRIMARY KEY
  - **UQ_MonitorConfig_config_name** (NONCLUSTERED): config_name

**Foreign Keys:**

  - **FK_MonitorConfig_ServerConfig**: server_id -> FileOps.ServerConfig.server_id

**Active configurations with schedule** [sort:1] -- Shows all enabled monitors with their time windows and day-of-week schedule.

```sql
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
```

  - **ServerConfig**: [sort:1] Each config references exactly one SFTP server via server_id. The server provides connection details while the config defines what to look for and when.
  - **MonitorStatus**: [sort:2] Each enabled config has exactly one corresponding MonitorStatus row showing current-day state. The status row is reset daily and deleted when the config is disabled.
  - **MonitorLog**: [sort:3] Each config generates MonitorLog entries over time — one per detection or escalation event. The log provides the historical view while MonitorStatus provides the real-time view.


### MonitorLog

Historical log of file detection and escalation events. Records only meaningful outcomes (Detected, Escalated, LateDetected) without the noise of routine monitoring checks.

**Data Flow:** Scan-SFTPFiles.ps1 inserts a row whenever a meaningful event occurs: file detection, escalation, or late detection. Each row captures the event context including config details, detected filename, timestamp, and whether Teams and Jira integrations were triggered. This is an append-only audit trail — rows are never updated or deleted. Used for historical analysis of on-time rates, escalation frequency, and late arrival patterns.

**Events Only:** [sort:1] Only meaningful outcomes are logged — Detected, Escalated, and LateDetected. Routine monitoring checks that find nothing are not recorded. This keeps the table focused and queryable for operational analysis without filling it with noise.

**Denormalized Context:** [sort:2] config_name and sftp_path are copied from MonitorConfig at event time. This allows standalone querying without joins and preserves the values as they were when the event occurred, even if the config is later modified.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| log_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this log entry |
| config_id | int | No | — | FK to [FileOps - MonitorConfig] |
| config_name | varchar(100) | No | — | Denormalized from MonitorConfig |
| sftp_path | varchar(500) | No | — | Denormalized from MonitorConfig |
| log_date | date | No | — | Calendar date of the event |
| event_type | varchar(20) | No | — | Type of event: Detected, Escalated, or LateDetected |
| file_detected_name | varchar(500) | Yes | — | Filename that was detected (if applicable) |
| event_dttm | datetime | No | — | Exact timestamp of the event |
| teams_alert_queued | bit | No | 0 | Whether a Teams alert was queued for this event |
| jira_ticket_queued | bit | No | 0 | Whether a Jira ticket was queued for this event |
| created_dttm | datetime | No | getdate() | When the log entry was created |

  - **PK_MonitorLog** (CLUSTERED): log_id -- PRIMARY KEY

**Check Constraints:**

  - **CK_MonitorLog_event_type**: `([event_type]='LateDetected' OR [event_type]='Escalated' OR [event_type]='Detected')`

**Foreign Keys:**

  - **FK_MonitorLog_MonitorConfig**: config_id -> FileOps.MonitorConfig.config_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| event_type | Detected | File matching the configured pattern was found during the normal monitoring window before escalation time. | 1 |
| event_type | Escalated | Escalation time passed without file detection. Teams WARNING alert queued and Jira ticket created if configured. | 2 |
| event_type | LateDetected | File arrived after escalation had already occurred. Logged as a separate event to record the late arrival without undoing the escalation record. | 3 |

**Recent events** [sort:1] -- Shows the last 7 days of file monitoring events with integration status.

```sql
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
```

**Escalation frequency by config** [sort:2] -- Shows how often each monitor escalates over the last 30 days for identifying chronic late files.

```sql
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
```

  - **MonitorConfig**: [sort:1] Each log entry references its source config via config_id. Denormalized config_name and sftp_path allow standalone querying without requiring the config to still exist.
  - **Teams.AlertQueue**: [sort:2] When teams_alert_queued = 1, a corresponding row was inserted into Teams.AlertQueue via sp_QueueAlert at the same time as the log entry. The Teams integration processes the alert asynchronously.
  - **Jira.TicketQueue**: [sort:3] When jira_ticket_queued = 1, a corresponding row was inserted into Jira.TicketQueue via sp_QueueTicket at the same time as the log entry. The Jira integration processes the ticket asynchronously.


### MonitorStatus

Dashboard table showing current monitoring state for each active file configuration. Displays the last known status and scan time, with automatic daily reset at the start of each monitoring window.

**Data Flow:** Scan-SFTPFiles.ps1 creates or resets one row per active config at the start of each monitoring window, setting last_status to Monitoring. During each scan cycle the script updates last_scanned_dttm, and transitions last_status to Detected or Escalated based on file presence and escalation time. Late-arriving files populate file_detected_dttm while last_status remains Escalated. Rows for disabled configs are automatically deleted during cleanup. The Control Center FileOps dashboard reads this table for real-time status display.

**Dashboard Model:** [sort:1] One row per config via the unique constraint on config_id. This is a real-time dashboard, not a historical record. The row is reset at the start of each monitoring window rather than creating new rows per day.

**Escalation Persistence:** [sort:2] Once last_status transitions to Escalated, it remains Escalated even if the file arrives late. The late arrival is recorded in file_detected_dttm to provide the full picture without masking the fact that an escalation occurred.

**Naming Convention: last_status:** [sort:3] The column is named last_status rather than status to reflect that it shows the state as of the most recent scan. After the monitoring window closes, the value persists as a historical snapshot until the next window resets it.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| status_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this status record |
| config_id | int | No | — | FK to [FileOps - MonitorConfig] |
| config_name | varchar(100) | No | — | Denormalized from MonitorConfig for easy querying |
| sftp_path | varchar(500) | No | — | Denormalized from MonitorConfig for easy querying |
| last_status | varchar(20) | No | 'Monitoring' | Status as of last scan: Monitoring, Detected, Escalated |
| last_scanned_dttm | datetime | Yes | — | When this config was last scanned by the monitor script |
| file_detected_name | varchar(500) | Yes | — | Actual filename that matched the pattern |
| file_detected_dttm | datetime | Yes | — | When the file was detected |
| escalated_dttm | datetime | Yes | — | When escalation occurred (if applicable) |

  - **PK_MonitorStatus** (CLUSTERED): status_id -- PRIMARY KEY
  - **UQ_MonitorStatus_config_id** (NONCLUSTERED): config_id

**Check Constraints:**

  - **CK_MonitorStatus_last_status**: `([last_status]='Escalated' OR [last_status]='Detected' OR [last_status]='LateDetected' OR [last_status]='Monitoring')`

**Foreign Keys:**

  - **FK_MonitorStatus_MonitorConfig**: config_id -> FileOps.MonitorConfig.config_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| last_status | Monitoring | Active monitoring in progress. Set when the monitoring window opens each day and on every scan cycle where the file has not yet been detected or escalated. | 1 |
| last_status | Detected | File matching the configured pattern was found. Terminal state for the day — scanning continues but status will not change. | 2 |
| last_status | Escalated | Escalation time passed without detection. Transitions to LateDetected if the file arrives after escalation. The escalated_dttm is recorded when this status is first set. | 3 |
| last_status | LateDetected | File arrived after escalation had already occurred. Transitions from Escalated to prevent re-detection alerts on subsequent scan cycles. The escalated_dttm is preserved to retain the full timeline. | 4 |

**Current monitoring dashboard** [sort:1] -- Shows the real-time status of all active file monitors with timing details.

```sql
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
```

  - **MonitorConfig**: [sort:1] One status row per enabled config via the unique constraint on config_id. The config defines the monitoring rules; the status row tracks execution against those rules for the current day.
  - **MonitorLog**: [sort:2] Status and Log serve complementary roles. MonitorStatus is the real-time dashboard (one row, constantly updated). MonitorLog is the audit trail (many rows, append-only). A single escalation event updates MonitorStatus and inserts into MonitorLog simultaneously.


### ServerConfig

Configuration table defining SFTP servers and their credential references for file monitoring operations.

**Data Flow:** Rows are created manually or via sp_AddNewMonitorConfig when establishing a new SFTP server connection. Scan-SFTPFiles.ps1 reads ServerConfig joined to MonitorConfig to resolve SFTP connection details and credential references for each monitoring cycle. The credential_service_name links to dbo.Credentials for encrypted username/password retrieval at runtime.

**Credential Separation:** [sort:1] ServerConfig stores connection metadata (host, port) but references credentials indirectly via credential_service_name linking to dbo.Credentials. This keeps sensitive authentication data in a single secure location with encryption rather than duplicating secrets across tables.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| server_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the server configuration |
| server_name | varchar(100) | No | — | Friendly name for the server (e.g., Joker) |
| sftp_host | varchar(255) | No | — | Hostname or IP address of the SFTP server |
| sftp_port | int | No | 22 | SFTP port number |
| credential_service_name | varchar(50) | No | — | ServiceName in [Core - Credentials] for authentication |
| is_enabled | bit | No | 1 | Whether this server is active for monitoring |
| created_dttm | datetime | No | getdate() | When the record was created |
| modified_dttm | datetime | Yes | — | When the record was last modified |

  - **PK_ServerConfig** (CLUSTERED): server_id -- PRIMARY KEY

  - **MonitorConfig**: [sort:1] One server supports many monitor configurations. All configs referencing the same server share a single SFTP connection during each scan cycle.
  - **dbo.Credentials**: [sort:2] The credential_service_name column references a ServiceName in dbo.Credentials, not a direct foreign key. Scan-SFTPFiles.ps1 decrypts credentials at runtime using the master passphrase from dbo.GlobalConfig.


### sp_AddNewMonitorConfig

Stored procedure for adding new file monitor configurations with built-in validation and preview mode.

**Data Flow:** Accepts configuration parameters, validates against ServerConfig for server existence, checks for duplicate config names and file patterns in MonitorConfig, validates time window logic and priority values, then inserts a new row into MonitorConfig. Preview mode (default) shows what would be created without committing. Returns the new config_id on success.

**Preview Mode Default:** [sort:1] The @PreviewOnly parameter defaults to true (1), requiring an explicit opt-in to commit changes. This prevents accidental configuration creation and lets operators review exactly what will be inserted before committing.

**Legacy Convenience Procedure:** [sort:2] This procedure predates the Control Center UI. The Control Center now provides the primary interface for adding file monitors, making this procedure a backup option for direct SQL-based configuration when needed.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @ServerID | int | IN |  |  |
| @ConfigName | varchar(100) | IN |  |  |
| @SftpPath | varchar(500) | IN |  |  |
| @FilePattern | varchar(255) | IN |  |  |
| @CheckStartTime | time | IN |  |  |
| @CheckEndTime | time | IN |  |  |
| @EscalationTime | time | IN |  |  |
| @CheckWeekdays | bit | IN |  |  |
| @CheckWeekends | bit | IN |  |  |
| @CheckHolidays | bit | IN |  |  |
| @NotifyOnDetection | bit | IN |  |  |
| @NotifyOnEscalation | bit | IN |  |  |
| @CreateJiraOnEscalation | bit | IN |  |  |
| @DefaultPriority | varchar(20) | IN |  |  |
| @IsEnabled | bit | IN |  |  |
| @PreviewOnly | bit | IN |  |  |

  - **ServerConfig**: [sort:1] Validates that the specified @ServerID exists and is enabled in ServerConfig before allowing configuration creation. A disabled or missing server rejects the insert.
  - **MonitorConfig**: [sort:2] Target table for the insert. The procedure validates against existing rows for duplicate config names and overlapping file patterns before creating the new configuration.


### TR_FileOps_MonitorLog_DisableETL_OneGI

AFTER INSERT trigger on FileOps.MonitorLog that disables the IBM/B2B ETL automation for the OneGI client's process rows when any of its four monitored escalation files logs an escalation.

**Cross-Database Write:** [sort:1] This trigger runs a cross-database write inside the MonitorLog insert transaction. The escalation check is set-based (EXISTS against the inserted rows) so it fires correctly whether one or up to four files escalate in a single insert, and the UPDATE is idempotent via WHERE ACTIVE_FLAG = 1.

  - **Integration.etl.tbl_B2B_CLIENTS_FILES**: [sort:1] Updates ACTIVE_FLAG on the six OneGI process rows (CLIENT_ID 10678, SEQ_ID 1-6) in the Integration database's B2B client-files table. Setting ACTIVE_FLAG = 0 stops the IBM/B2B scheduler from automatically triggering those processes. The trigger only reaches this table when a OneGI escalation (config_id 77-80) is logged to FileOps.MonitorLog.


### Scan-SFTPFiles.ps1

Execution engine for FileOps. Scans configured SFTP locations for expected files on a scheduled interval, manages detection and escalation state in MonitorStatus, logs events to MonitorLog, and queues Teams alerts and Jira tickets through the integration modules.

**Data Flow:** Reads MonitorConfig joined to ServerConfig for active configurations within the current check window. Retrieves encrypted SFTP credentials from dbo.Credentials via the master passphrase in dbo.GlobalConfig. Connects to SFTP servers using WinSCP .NET assembly, scans directories for pattern-matched files, then writes results to MonitorStatus (upsert) and MonitorLog (insert). Queues Teams alerts via Teams.sp_QueueAlert and Jira tickets via Jira.sp_QueueTicket based on per-config notification settings.

**All Logic in PowerShell:** [sort:1] Unlike other xFACts modules that split logic between stored procedures and scripts, FileOps puts all business logic in the PowerShell script. This simplifies the architecture for a module whose primary operation is external I/O (SFTP scanning) rather than data processing.

**Grouped SFTP Connections:** [sort:2] Configurations are grouped by server before scanning. All configs sharing a server use a single credential retrieval and SFTP session, minimizing connection overhead and credential lookups when multiple file monitors target the same server.

**Daily Window Reset:** [sort:3] The script detects a new monitoring window by comparing last_scanned_dttm to the current date. When the dates differ, MonitorStatus is reset to Monitoring with cleared detection and escalation fields. This eliminates the need for a separate scheduled reset job.

  - **MonitorConfig + ServerConfig**: [sort:1] The script joins these two tables to build its work list each cycle. MonitorConfig provides monitoring rules and day/time filters. ServerConfig provides SFTP connection details and credential references.
  - **MonitorStatus + MonitorLog**: [sort:2] Both are written by the script during each cycle. MonitorStatus is upserted for real-time dashboard state. MonitorLog receives insert-only event records for audit trail. Both writes happen in the same logical operation.
  - **Teams + Jira Integration**: [sort:3] Alert and ticket creation is delegated to Teams.sp_QueueAlert and Jira.sp_QueueTicket. The script queues requests based on per-config notification flags (notify_on_detection, notify_on_escalation, create_jira_on_escalation) and never calls the APIs directly.



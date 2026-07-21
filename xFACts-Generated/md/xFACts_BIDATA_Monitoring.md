# BIDATA Monitoring

*Watching the warehouse rebuild so you don’t have to*

Every night, a SQL Agent job rebuilds the reporting data warehouse. This module tracks its progress in real-time and tells you when it’s done. Not “check every 10 minutes and send an email saying it’s still not done.” Real-time. As each step completes, we know. One Teams message when it finishes. That’s it.






A Brief History of Pain

The BIDATA warehouse has been the reporting backbone for nearly 20 years. It started life as flat file extracts from a non-SQL database, dropped into a SQL 2008 R2 instance. Ten tables, 2-3 hours to load, simple.

Then came a platform migration. Then came organic growth. Then came a developer who enthusiastically implemented every optimization and cool “time-saver” he learned along the way — massive views meant to be “one-stop shops” for developers, nested views calling other views, assemblies, functions everywhere.

The result: 60 million records, views joining 30 million and 60 million row tables, with secondary views and functions nested throughout. It was never meant to scale.

By 2020, the nightly build took 8 hours. Then 10. Then there were days it couldn’t finish at all. A heroic rearchitecting effort got it back to 7-8 hours. Then it crept. And crept. 9-10 hours became normal.

A recent rebuild effort brought it down to a consistent 5-5.5 hours.

The scars remain. There’s a “BIDATA build time” item permanently on the weekly operations meeting agenda. Nobody discusses it. Nobody dares remove it. We leave it there to appease the angry gods.

This module exists partly to monitor the build, and partly to help everyone gradually accept that yes, it really does finish reliably now.






How It Works



Build Starts
Overnight
→
Monitor
Detects It
→
Steps Captured
in Real-Time
→
Build
Completes
→
One Clean
Notification

From first step to final notification — every step tracked as it happens


A monitor runs every few minutes during the overnight window. When it detects that the build has started, it begins capturing each step as it completes — step name, duration, status. The Control Center dashboard shows this live, so you can see exactly which step is running and how long each completed step took.

When the build finishes, a single Teams message goes out with the completion time, total duration, and a breakdown of step timings. One glance tells you everything you need to know.

It also watches for things going wrong. If the build doesn’t start when it should, you’ll hear about it. If it fails partway through and someone restarts it, both attempts are tracked separately so you can see the full picture. And every build’s timing data is preserved for historical trending — so when someone asks “has it always taken this long?” the answer is right there.






The Legacy Email Situation

There are still emails. Lots of emails. Every 10 minutes in the morning from 6 AM onward, telling people the build isn’t done yet. Then finally one that says it is — but thanks to valiant efforts, those emails no longer ring out into the 9 and 10 AM hours (or god forbid into the early afternoon).

This module was designed to replace all of that with a single, clean notification.

Nobody has turned the emails off.

It’s fine. We’re not here to judge. Change is hard. The emails can stay until everyone’s comfortable. The Teams notification will be there either way, providing a calmer alternative for those ready to embrace it.






The Bottom Line

This module answers one question: “Is BIDATA done?”

No more checking SQL Agent manually. No more parsing through dozens of emails. No more wondering. Just a Teams message when it’s ready, and real-time progress in Control Center while you wait.

The data warehouse may be a 20-year-old architectural marvel held together by views, functions, and sheer determination. But at least now we know exactly when it finishes, how long it took, and which steps contributed to that duration.

The weekly meeting agenda item can stay. We don’t anger the gods unnecessarily.

---

# BIDATA Monitoring — Control Center Guide

---

## Architecture
# BIDATA Monitoring Architecture

The narrative page tells you *what* BIDATA Monitoring does and *why* (and shares some war stories). This page tells you *how*. Two tables, one script, zero modifications to the data warehouse itself. The monitoring is entirely external — it reads `msdb` job history and records what it finds.



Schema Overview

BIDATA is the simplest schema in xFACts. Two tables, no procedures, no triggers. One script does all the work. This isn't laziness — it's a reflection of the fact that monitoring a SQL Agent job doesn't require much infrastructure when you design the data model right.



`BuildExecution` is the parent record — one row per nightly build. `StepExecution` captures the individual job steps as they complete. The relationship is simple: one build has many steps, and the steps are recorded in real-time as the job progresses.

| Table | Role | Cardinality |
| --- | --- | --- |
| `BuildExecution` | Build-level tracking | One per nightly build |
| `StepExecution` | Step-level timing details | Many per build (one per completed job step) |



No triggers, no stored procedures. Unlike Teams and Jira (which use triggers to signal the orchestrator), BIDATA monitoring runs on a scheduled interval via ProcessRegistry. There's nothing to signal demand — the monitor polls every cycle during the overnight window and does nothing if the build hasn't started.







The Monitoring Lifecycle

`Monitor-BIDATABuild.ps1` runs on a configurable schedule via the orchestrator. Its job is to observe the SQL Agent job without interfering with it. The script never modifies anything in the data warehouse or in `msdb` — it reads job history and records its observations in the BIDATA schema.





Check Today
BuildExecution
row for today?

→

Query msdb
Remote job history
on reporting server

→

Track Build
Create IN_PROGRESS
Capture new steps

→

Detect Finish
Job outcome row
in sysjobhistory

→

Notify
Teams alert with
step breakdown


Runs on a configurable schedule. If the build hasn’t started and the grace period has passed, a NOT_STARTED alert fires instead.


Step 1: Check Current State

The script first queries `BuildExecution` for today's date. Three outcomes are possible: no row exists (no build detected yet), a row exists with status IN_PROGRESS (build is being tracked), or a row exists with COMPLETED/FAILED (build finished, nothing to do).

Step 2: Detect Build Start

If no row exists for today, the script queries `msdb.dbo.sysjobhistory` on the target server via PowerShell's `Invoke-Sqlcmd`. It looks for any job step completions for the BIDATA rebuild job with a run date matching today. If it finds activity, the build has started — create a `BuildExecution` row with status **IN_PROGRESS** and start capturing steps.

Step 3: Capture Steps

On each subsequent cycle, the script queries `msdb` again for any step completions newer than the last captured step. New steps get INSERTed into `StepExecution` with their step name, duration, and completion time. The `BuildExecution` row gets updated with the latest step count.

Step 4: Detect Completion

The build is complete when `msdb` shows the overall job outcome (step 0 in `sysjobhistory`). The script updates `BuildExecution` with status **COMPLETED** (or **FAILED**), calculates total duration, formats a summary, and queues a Teams notification.


Remote query, local storage. The BIDATA job runs on the reporting server, not on the xFACts server. The script uses `Invoke-Sqlcmd` to query `msdb` remotely. This means xFACts monitors the build without requiring any changes to the reporting server — no linked servers, no stored procedures, no agent jobs. The monitoring is completely non-invasive.







The Status Machine

`BuildExecution.build_status` has four valid values. The transitions tell the full story of a build's lifecycle.





No Row
Build not yet
detected today

→

Detected?

IN_PROGRESS
NOT_STARTED


→

Outcome

COMPLETED
FAILED



NOT_STARTED transitions to SUPERSEDED if the build eventually starts. COMPLETED and FAILED are terminal for the day.


| Status | Meaning | Transitions To |
| --- | --- | --- |
| **NOT_STARTED** | Grace period passed without build activity | SUPERSEDED (if build eventually starts) |
| **IN_PROGRESS** | Build running, steps being captured | COMPLETED *or* FAILED |
| **COMPLETED** | Build finished successfully | Terminal for the day |
| **FAILED** | Build encountered an error | Terminal for the day |


The NOT_STARTED Edge Case

The build is scheduled to start overnight. A configurable grace period (from GlobalConfig) says “if the build hasn’t started by X, something’s wrong.” When the grace period expires with no activity, the script creates a `BuildExecution` row with status **NOT_STARTED** and queues a Teams alert.

If the build later starts (maybe it was delayed, not missing), the NOT_STARTED record gets marked **SUPERSEDED** and a new IN_PROGRESS record takes over tracking. This prevents false alarms from blocking real monitoring.


SUPERSEDED vs. overwritten. The NOT_STARTED row isn't deleted or updated to IN_PROGRESS. It stays as a historical record that the build started late, with its own `superseded_dttm` timestamp. A new row handles the actual build tracking. This preserves the timeline: "At 4:00 AM we noticed the build hadn't started. At 4:15 AM it started. It completed at 9:30 AM."







Step Capture

The BIDATA rebuild job has dozens of steps. Not all of them are interesting. The monitor captures all completed steps from `msdb` but the Teams notification filters out infrastructure steps to keep the summary focused.

| Step Type | Captured | In Notification | Examples |
| --- | --- | --- | --- |
| Data processing | Yes | Yes | Import Accounts, Build Balances, Process Letters |
| Infrastructure | Yes | No | Disable users, Enable replication, Legacy email steps |


Each `StepExecution` row records the step name, step number, duration in seconds, a formatted duration string, and the run status from `msdb`. The duration data is what makes historical analysis possible — you can spot when a specific step starts taking longer, often weeks before the overall build time crosses a threshold anyone notices.


Step timing comes from msdb, not from xFACts. The script reads `run_duration` from `sysjobhistory` and converts it from `msdb`'s HHMMSS integer format to seconds. xFACts doesn't time the steps itself — it trusts SQL Agent's own accounting. This means the step durations are always accurate to what SQL Agent recorded, with no clock skew between servers.







Notification

One build, one notification. When the build completes, the script builds an Adaptive Card with the completion time, total duration, and a step-by-step breakdown. It queues this through `Teams.sp_QueueAlert` and updates `BuildExecution.notified_dttm` to record that notification was sent.

The `notified_dttm` field serves double duty: it prevents duplicate notifications (if the next monitoring cycle runs before the Teams queue processes), and it provides an audit trail of exactly when the team was informed.

NOT_STARTED alerts also go through Teams, but as WARNING category rather than INFO. The build not starting is a more urgent problem than the build finishing successfully.


No Jira integration. BIDATA builds don't create Jira tickets on failure. The reasoning: a failed build needs immediate DBA attention, not a ticket that sits in a backlog. The Teams alert goes to the right channel; the response is expected to be immediate. If a build failure needs longer-term tracking, a ticket can be created manually with the build details.







How Everything Connects

BIDATA Monitoring is the most independent module in xFACts. It reads from an external source (`msdb` on the reporting server), writes to its own two tables, and pushes notifications through Teams. No other module reads BIDATA data, and BIDATA reads nothing from other xFACts modules except shared infrastructure.

Internal Flow

| From | To | Relationship |
| --- | --- | --- |
| `BuildExecution` | `StepExecution` | One build → many steps (FK on `build_id`) |
| `Monitor-BIDATABuild.ps1` | Both tables | Script creates and updates all rows |


External Dependencies

| Dependency | Module | Purpose |
| --- | --- | --- |
| `Orchestrator.ProcessRegistry` | Orchestrator | Schedules Monitor-BIDATABuild.ps1 on a configurable interval |
| `dbo.GlobalConfig` | Shared Infrastructure | Scheduled start time, grace period, notification settings |
| `Teams.sp_QueueAlert` | Teams Integration | Completion and NOT_STARTED notifications |
| `msdb.dbo.sysjobhistory` | Reporting Server | Source of job step data (read-only, remote query) |

---

## Reference

### BuildExecution

Primary tracking table for BIDATA Daily Build job executions with timing, status, and notification tracking.

**Data Flow:** Monitor-BIDATABuild.ps1 polls DM-PROD-REP.msdb.dbo.sysjobhistory every 5 minutes via direct PowerShell connection and creates one row per execution attempt, identified by instance_id. The script sets status to IN_PROGRESS on first detection, updates to COMPLETED or FAILED when the job outcome row appears, and creates NOT_STARTED records when the build fails to start within the configured grace period. The notified_dttm column is set after Teams.sp_QueueAlert delivers the completion or failure notification. The Control Center BIDATA Monitoring page reads this table for build status display and duration metrics.

**One Row Per Execution Attempt:** [sort:1] Each SQL Agent execution attempt gets its own row identified by instance_id. Multiple attempts on the same day (due to failures and restarts) result in multiple rows, preserving full attempt history.

**NOT_STARTED Detection:** [sort:2] When no job history exists within the configured grace period after the scheduled start time, a record is created with status NOT_STARTED to trigger alerting. If the build later starts, the NOT_STARTED record is marked SUPERSEDED.

**Instance-Based Deduplication:** [sort:3] Notification TriggerValue includes the instance_id (e.g., COMPLETED-12345) so each execution attempt can only trigger one alert regardless of how many monitoring cycles observe the completed state.

**Historical Backfill Flag:** [sort:4] The is_backfill flag distinguishes between real-time captured builds and historically backfilled data from sysjobhistory, allowing queries to filter for live-captured data only.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| build_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this build execution |
| build_date | date | No | — | Date of the build |
| job_name | varchar(128) | Yes | — | SQL Agent job name (supports multiple job name versions) |
| instance_id | int | Yes | — | SQL Agent instance_id from sysjobhistory. NULL for NOT_STARTED records |
| start_dttm | datetime | Yes | — | When the build started |
| end_dttm | datetime | Yes | — | When the build completed |
| total_duration_seconds | int | Yes | — | Total runtime in seconds |
| total_duration_formatted | varchar(10) | Yes | — | Runtime as HH:MM:SS string |
| step_count | int | Yes | — | Number of steps in the build |
| status | varchar(20) | No | — | Build status: COMPLETED, FAILED, IN_PROGRESS, NOT_STARTED, SUPERSEDED |
| run_status | int | Yes | — | SQL Agent run_status code (1=Success, 0=Failed) |
| failed_step_id | int | Yes | — | Step ID that failed (if status = FAILED) |
| failed_step_name | varchar(128) | Yes | — | Name of the failed step |
| notified_dttm | datetime | Yes | — | When Teams notification was sent. NULL = not yet notified |
| is_backfill | bit | No | 0 | 1 = Historically backfilled, 0 = Real-time captured |
| created_dttm | datetime | No | getdate() | When this record was created |

  - **PK_BIDATA_BuildExecution** (CLUSTERED): build_id -- PRIMARY KEY

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| status | IN_PROGRESS | Build is currently running. Set when first step is detected in sysjobhistory but job outcome row (step_id=0) has not appeared. | 1 |
| run_status | 0 | Failed. The SQL Agent job outcome indicates the build did not complete successfully. | 1 |
| run_status | 1 | Succeeded. The SQL Agent job outcome indicates the build completed successfully. | 2 |
| status | COMPLETED | Build finished successfully. Set when job outcome row shows run_status=1. | 2 |
| status | FAILED | Build encountered an error. Set when job outcome row shows run_status=0. The failed_step_id and failed_step_name columns identify the failing step. | 3 |
| run_status | 2 | Retry. The SQL Agent job is being retried. | 3 |
| run_status | 3 | Canceled. The SQL Agent job was canceled. | 4 |
| status | NOT_STARTED | Build did not start within the grace period after the scheduled start time. Created by NOT_STARTED detection logic when no sysjobhistory records exist for the target date. | 4 |
| status | SUPERSEDED | A NOT_STARTED record that was replaced when the build eventually started. The original NOT_STARTED alert was already sent. | 5 |

**Today's Build Status** [sort:1] -- Daily check — shows all build records for today including status and notification state.

```sql
SELECT build_id, build_date, instance_id, start_dttm, end_dttm, 
       total_duration_formatted, status, notified_dttm
FROM BIDATA.BuildExecution
WHERE build_date = CAST(GETDATE() AS DATE)
ORDER BY build_id;
```

**Recent Builds** [sort:2] -- Shows the last 20 completed or failed builds, excluding NOT_STARTED and SUPERSEDED noise.

```sql
SELECT TOP 20 
    build_id, build_date, job_name, instance_id, start_dttm, end_dttm,
    total_duration_formatted, step_count, status
FROM BIDATA.BuildExecution
WHERE status NOT IN ('NOT_STARTED', 'SUPERSEDED')
ORDER BY build_date DESC, start_dttm DESC;
```

**Days with Multiple Attempts** [sort:3] -- Identifies dates with more than one execution attempt — indicates failures and restarts.

```sql
SELECT build_date, COUNT(*) AS attempts
FROM BIDATA.BuildExecution
WHERE status IN ('COMPLETED', 'FAILED')
GROUP BY build_date
HAVING COUNT(*) > 1
ORDER BY build_date DESC;
```

**Failed Builds Summary** [sort:4] -- Lists all failed builds with the step that caused the failure.

```sql
SELECT 
    build_date, start_dttm, total_duration_formatted,
    failed_step_id, failed_step_name
FROM BIDATA.BuildExecution
WHERE status = 'FAILED'
ORDER BY build_date DESC;
```

**Build Duration Trend** [sort:5] -- Monthly aggregation of build duration for trending analysis.

```sql
SELECT 
    CONVERT(VARCHAR(7), build_date, 120) AS month,
    COUNT(*) AS builds,
    AVG(total_duration_seconds) / 3600.0 AS avg_hours,
    MIN(total_duration_seconds) / 3600.0 AS min_hours,
    MAX(total_duration_seconds) / 3600.0 AS max_hours
FROM BIDATA.BuildExecution
WHERE status = 'COMPLETED'
GROUP BY CONVERT(VARCHAR(7), build_date, 120)
ORDER BY month;
```

  - **StepExecution**: [sort:1] Each BuildExecution record is the parent for zero to many StepExecution rows containing step-level timing. Steps are captured incrementally as they complete during the build, enabling real-time progress display on the Control Center BIDATA Monitoring page.


### StepExecution

Step-level execution details for each BIDATA Daily Build, enabling performance analysis and bottleneck identification.

**Data Flow:** Monitor-BIDATABuild.ps1 captures step completions incrementally from DM-PROD-REP.msdb.dbo.sysjobhistory as each step finishes during the build. Each row records the step name, duration, and run_status for one step of one build attempt. The Control Center BIDATA Monitoring page joins this table to BuildExecution for step-level progress display and historical step duration analysis.

**Complete Step Capture:** [sort:1] All SQL Agent job steps are captured including infrastructure steps (disable users, enable replication) and legacy notification steps, even though some are excluded from the Teams notification message. This preserves full execution history for analysis.

**Incremental Capture:** [sort:2] Steps are inserted as they complete during the build rather than batch-inserted at the end. This enables real-time progress tracking on the Control Center BIDATA Monitoring dashboard.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| step_execution_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this step execution |
| build_id | int | No | — | Foreign key to BuildExecution |
| step_id | int | No | — | Step number within the job (1-based) |
| step_name | varchar(128) | No | — | Name of the step from SQL Agent |
| run_status | int | No | 1 | SQL Agent run_status: 1=Success, 0=Failed |
| run_time | int | Yes | — | Raw run_time value from sysjobhistory (HHMMSS format) |
| duration_seconds | int | No | — | Step duration in seconds |
| duration_formatted | varchar(10) | No | — | Duration as HH:MM:SS string |

  - **PK_BIDATA_StepExecution** (CLUSTERED): step_execution_id -- PRIMARY KEY
  - **IX_BIDATA_StepExecution_BuildId** (NONCLUSTERED): build_id

**Foreign Keys:**

  - **FK_BIDATA_StepExecution_Build**: build_id -> BIDATA.BuildExecution.build_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| run_status | 0 | Failed. The step encountered an error during execution. | 1 |
| run_status | 1 | Succeeded. The step completed normally. | 2 |
| run_status | 2 | Retry. The step is being retried by SQL Agent. | 3 |
| run_status | 3 | Canceled. The step was canceled. | 4 |

**Steps for Today's Build** [sort:1] -- Shows step-level progress for today's completed build.

```sql
SELECT 
    s.step_id,
    s.step_name,
    s.run_status,
    s.duration_formatted
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE b.build_date = CAST(GETDATE() AS DATE)
  AND b.status = 'COMPLETED'
ORDER BY s.step_id;
```

**Average Step Duration (30 Days)** [sort:2] -- Identifies bottleneck steps by average duration over the last 30 days.

```sql
SELECT 
    s.step_name,
    COUNT(*) AS executions,
    AVG(s.duration_seconds) AS avg_seconds,
    MIN(s.duration_seconds) AS min_seconds,
    MAX(s.duration_seconds) AS max_seconds
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE b.build_date >= DATEADD(DAY, -30, GETDATE())
  AND b.status = 'COMPLETED'
  AND s.run_status = 1
GROUP BY s.step_name
ORDER BY AVG(s.duration_seconds) DESC;
```

**Slowest Steps (All Time)** [sort:3] -- Top 10 longest individual step executions across all builds.

```sql
SELECT TOP 10
    b.build_date,
    s.step_name,
    s.duration_formatted,
    s.duration_seconds
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE s.run_status = 1
ORDER BY s.duration_seconds DESC;
```

**Failed Steps** [sort:4] -- Lists all step-level failures with build date context.

```sql
SELECT 
    b.build_date,
    s.step_id,
    s.step_name,
    s.duration_formatted
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE s.run_status = 0
ORDER BY b.build_date DESC;
```

**Step Duration Trend** [sort:5] -- Tracks a specific step's duration over time for performance trending. Replace the step_name filter with the target step.

```sql
SELECT 
    b.build_date,
    s.duration_seconds,
    s.duration_formatted
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE s.step_name = 'Build Table X'  -- Replace with actual step name
  AND s.run_status = 1
ORDER BY b.build_date;
```

  - **BuildExecution**: [sort:1] Each StepExecution row belongs to one BuildExecution record via the build_id foreign key. Step data only has meaning in the context of its parent build — the build_date, status, and instance_id come from the parent row.


### Monitor-BIDATABuild.ps1

Monitors the BIDATA Daily Build SQL Agent job via direct PowerShell connection to the source server. Captures build start, step completions incrementally, and final status. Creates NOT_STARTED records when the build fails to start within the configured grace period. Sends Teams notifications on completion, failure, or not-started conditions.

**Data Flow:** Runs as a queue-driven process in the orchestrator, executing every 5 minutes. Reads configuration from dbo.GlobalConfig (job name, source server, grace period). Queries DM-PROD-REP.msdb.dbo.sysjobhistory and related system tables via direct PowerShell connection for job execution data and schedule information. Creates and updates rows in BIDATA.BuildExecution for build-level tracking, inserts rows into BIDATA.StepExecution as steps complete incrementally. Calls Teams.sp_QueueAlert to send completion, failure, or NOT_STARTED notifications. Uses instance_id-based TriggerValue for notification deduplication.

**Direct Connection vs Linked Server:** [sort:1] Uses direct PowerShell connection to the source server via Invoke-Sqlcmd instead of linked server queries. This eliminates the linked server dependency, enables real-time step capture during build execution, and aligns with the platform direction of unified PowerShell orchestration.

**Incremental Step Capture:** [sort:2] Steps are captured as they complete during the build rather than batch-queried after the build finishes. Each monitoring cycle picks up newly completed steps and inserts them into StepExecution, enabling real-time progress display on the Control Center dashboard.

**NOT_STARTED Detection:** [sort:3] Queries the job schedule from msdb.dbo.sysschedules to determine the expected start time. If no job history exists for the target date and the current time exceeds the scheduled start plus the configured grace period, creates a NOT_STARTED record and fires an alert. If the build later starts, the NOT_STARTED record is marked SUPERSEDED.

**Instance-Based Deduplication:** [sort:4] Notification TriggerValue includes the instance_id or date (e.g., COMPLETED-12345, NOT_STARTED-2026-01-29) so each build attempt or not-started condition can only trigger one alert regardless of how many monitoring cycles observe the same state.

**Notification Step Filtering:** [sort:5] Infrastructure steps (disable users, enable replication) and legacy notification steps are excluded from the Teams message body to keep notifications focused on actual data processing steps. These steps are still captured in StepExecution for historical completeness.

  - **BIDATA.BuildExecution**: [sort:1] Primary write target. Creates new rows on first detection of a build attempt, updates status and timing as the build progresses, and sets notified_dttm after Teams notification is sent.
  - **BIDATA.StepExecution**: [sort:2] Write target for step-level data. Inserts rows incrementally as each step completes during the build, capturing step name, duration, and run_status.
  - **dbo.GlobalConfig**: [sort:3] Read source for configuration. Retrieves bidata_build_job_name, bidata_build_source_server, and bidata_build_start_grace_minutes at script startup.
  - **Teams.sp_QueueAlert**: [sort:4] Called to send notifications on build completion (INFO), failure (ERROR), and not-started conditions (ERROR). Uses BuildStatus as TriggerType with instance_id or date in TriggerValue for deduplication.



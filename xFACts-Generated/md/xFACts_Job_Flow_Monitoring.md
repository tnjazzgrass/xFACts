# Job/Flow Monitoring

*Catching overnight problems at 2:30 AM instead of 9 AM*

Every job that runs through Debt Manager's processing engine — whether it's part of the nightly flows or an ad-hoc execution during the day — is tracked by JobFlow. Several hundred jobs run overnight alone. Before JobFlow, a failure at 2 AM meant nobody found out until 9 AM. Now the detection window is minutes instead of hours. That's the difference between "minor inconvenience" and "all-hands emergency meeting with people who haven't had coffee yet."






The Problem

Every night, Debt Manager processes several hundred automated jobs organized into specific flows. These flows handle everything from requesting notices to updating account statuses to applying tags. Some finish in a few hours. Others can take considerably longer. (*JFDINT01*, I see you hiding back there. We need to talk.)

Before JobFlow existed, if something went wrong at 2 AM, nobody knew until morning. A stalled processing queue at midnight turns into a delayed inventory at 6 AM turns into an unhappy Operations department at 8 AM turns into an executive asking "so... did anyone notice the jobs didn't run?" by 9 AM. Nobody wants to be in that meeting.

JobFlow closes that gap. Instead of finding out about problems half a day later, we detect issues within minutes. That's enough time to investigate, intervene, and usually fix the problem before anyone with a corner office needs to know it happened.






How It Works



Config
Syncs
→
Flows
Detected
→
Jobs
Tracked
→
States
Managed
→
Problems
Flagged

A continuous cycle, all night long, every night


Think of it as a very attentive night shift worker who checks on everything every few minutes. One monitoring script runs the entire show: it keeps its configuration in sync with Debt Manager, detects when flows start, tracks each job as it progresses, watches for things that stop moving, and flags anything that doesn't look right.

When something goes wrong, you get notified. Teams message. Jira ticket. While you're still asleep maybe, but at least someone knows.






Flows and Jobs

Debt Manager's processing runs on two levels. A **job** is a single execution of one or more processing steps — "Assign Blue Strategy Tag," "Auto Return 365 Day." A **flow** is a container that groups related jobs into a scheduled sequence. The nightly overnight process is organized into about a dozen flows, each containing multiple jobs. Additional jobs run individually throughout the day as ad-hoc executions for reprocessing, cleanup, or one-off tasks.

JobFlow watches both levels, because problems at either one can have real business impact. A flow that doesn't trigger on schedule could mean sixty jobs that didn't execute — and some of those jobs are date-sensitive. If a job that says "send a letter on day 5" doesn't run that day, those consumers never get that letter. Tomorrow's run picks up the next batch, and yesterday's are lost. That's the kind of thing that can't be made up after the fact.

So whether it's a scheduled nightly flow or a one-off ad-hoc job, if it runs through Debt Manager's job engine, JobFlow is tracking it. Nothing escapes.






What It Catches

JobFlow watches for three categories of problems, each requiring a different kind of attention:

| Problem | What It Means |
| --- | --- |
| **Processing stalls** | Nothing is progressing anywhere in the system. The queue is frozen. This is the fire alarm — something fundamental has stopped working. |
| **Missing flows** | A flow that was scheduled to run hasn't started. Maybe someone disabled a trigger. Maybe a prerequisite failed. Maybe Mercury is in retrograde. Either way, we need to know. |
| **Hidden failures** | A flow "completed" but something went wrong underneath. Jobs that didn't run, jobs that failed silently, jobs where every record was rejected. The system looks green. Everything is *not* fine. |


Not all failures deserve a 2 AM wake-up call. If a notice request job rejected some accounts because they don't meet mailing criteria, that's expected business behavior — not a system problem. JobFlow distinguishes between genuine failures and business-as-usual rejections, so when you get paged, it's because something actually needs attention.






The Control Center View

The JobFlow page in the Control Center shows the pulse of overnight processing — which flows are currently active, how far along they are, and whether anything needs attention. Historical trend data shows processing patterns over time, so you can spot the nights that consistently run long before they become a problem.






The Bottom Line

JobFlow exists so that when something goes wrong at 2 AM, we find out at 2:30 AM instead of 9 AM. It watches everything happening in Debt Manager's job processing, flags when things aren't progressing, and alerts when scheduled work doesn't start.

The data it collects isn't just for alerting — it's valuable for understanding processing patterns over time. Which flows are consistently slow? Which jobs fail most often? Are there nights when processing takes longer? JobFlow has the receipts.

Because "I didn't know" is never a good answer when someone asks why the jobs didn't run.

---

# Job/Flow Monitoring — Control Center Guide

---

## Architecture
# Job/Flow Monitoring Architecture

The narrative page tells you *what* JobFlow does and *why*. This page tells you *how*. Eleven tables, one PowerShell script with eight processing steps, a state machine, snapshot-based stall detection, and a validation pipeline that distinguishes real failures from business-as-usual rejections.



Schema Overview

The JobFlow schema is organized around three functional groups: configuration (what to monitor), tracking (what's happening), and analysis (what happened). All processing logic lives in `Monitor-JobFlow.ps1` — there are no stored procedures or triggers in this schema.



| Group | Table | Role |
| --- | --- | --- |
| **Configuration** | `FlowConfig` | Per-flow monitoring settings and DM sync |
| `JobConfig` | Job-level criticality classification |
| `Schedule` | Expected execution windows |
| `ErrorCategory` | Error pattern classification rules |
| **Tracking** | `FlowExecutionTracking` | Core state machine — one row per execution |
| `JobExecutionLog` | Individual job completion history |
| `Status` | Step execution health and stall state |
| **Analysis** | `StallDetectionLog` | Stall detection event audit trail |
| `ValidationLog` | Post-completion validation results |
| `ValidationException` | Individual exception details |
| `JobStatus` | DM status code reference lookup |



No stored procedures or triggers. Unlike most xFACts modules, JobFlow has no server-side logic. All processing, state management, alerting, and validation runs in Monitor-JobFlow.ps1. This was a deliberate choice to eliminate cross-database dependencies and support future AG migration scenarios where the script can point at any replica.







The State Machine

`FlowExecutionTracking` is a state machine table. Each row represents a single flow execution instance, identified by `job_sqnc_log_id` from the DM source system. The `execution_state` column drives all processing logic.







(new)
Flow found in
source system

→

DETECTED
Execution registered
No jobs yet

→

EXECUTING
Jobs in progress
Counts updating

→

COMPLETE
All jobs finished
Awaiting validation

→

VALIDATED
Analysis complete
Terminal state






STALLED
No system-wide progress
&#x2194; returns to EXECUTING
on recovery

← bidirectional with EXECUTING



ABANDONED
Manual terminal state
No automatic path here




Happy path: DETECTED → EXECUTING → COMPLETE → VALIDATED. Stalls are bidirectional — recovery returns to EXECUTING. ABANDONED is manual only.


State Transitions

| From | To | Trigger | Step |
| --- | --- | --- | --- |
| (new) | DETECTED | Flow execution found in job_sqnc_log | Step 1: DetectFlows |
| DETECTED | EXECUTING | executing_job_count > 0 OR completed_job_count > 0 | Step 4: TransitionStates |
| EXECUTING | COMPLETE | executing = 0 AND pending = 0 AND (completed + failed + cancelled) > 0 | Step 4: TransitionStates |
| EXECUTING | STALLED | System-wide no-progress counter reaches threshold | Step 5: DetectStalls |
| STALLED | EXECUTING | System-wide progress resumes | Step 5: DetectStalls |
| COMPLETE | VALIDATED | Step-ValidateCompletedFlows processes the flow | Step 6: ValidateFlows |



Why job_sqnc_log_id? A flow can execute multiple times per day. Tracking by job_sqnc_id alone (the flow definition) would incorrectly merge separate daily runs into one record. The job_sqnc_log_id from `crs5_oltp.dbo.job_sqnc_log` uniquely identifies each execution instance. The `execution_sequence` column provides a human-friendly numbering (1st run, 2nd run, etc.) for each flow on a given date.


Job Counts

Each tracking row maintains real-time job counts updated every polling cycle:

| Column | Source | Drives |
| --- | --- | --- |
| `expected_job_count` | Flow definition at detection time | Validation: expected vs actual comparison |
| `executing_job_count` | Jobs with DM status 1 (Started) | State transition: 0 + pending = 0 triggers COMPLETE |
| `pending_job_count` | Jobs with DM status 6 (Pending) | State transition: part of COMPLETE condition |
| `completed_job_count` | Jobs with terminal success status | State transition: part of COMPLETE condition |
| `failed_job_count` | Jobs with DM status 2, zero records | Validation: failure classification |
| `cancelled_job_count` | Jobs with DM status 4 (Cancelled) | State transition: counted toward completion |







The Processing Pipeline

`Monitor-JobFlow.ps1` runs on a configurable orchestrator cycle but does not always execute all eight steps. After Step 0 (ConfigSync), the script queries `crs5_oltp.dbo.job_log` for any jobs in an active (status 1) or pending (status 6) state. If none are found, only Step 7 (DetectMissing) runs before the script exits. This early exit eliminates the heavy `job_entty_log` joins in Steps 2 and 3 during the majority of cycles when no flows are executing.

When job activity is detected, all eight steps run in sequence. Each step updates its own row in the `Status` table with timing, result count, and success/failure status.







Step 0
ConfigSync
Sync with DM

→

Early Exit?
Any active or
pending jobs?





Step 1
DetectFlows

→

Step 2
CaptureJobs

→

Step 3
UpdateProgress

→

Step 4
TransitionStates

→

Step 5
DetectStalls

→

Step 6
ValidateFlows





Step 7
DetectMissing
Always runs



Step 0 and Step 7 always run. Steps 1–6 only run when active or pending jobs exist in DM.


| Step | Name | Reads | Writes | Purpose |
| --- | --- | --- | --- | --- |
| 0 | ConfigSync | DM: job_sqnc | FlowConfig, Jira queue | Sync flow definitions with DM |
| 1 | DetectFlows | DM: job_sqnc_log | FlowExecutionTracking | Find new flow executions |
| 2 | CaptureJobs | DM: job_log, job_entty_log | JobExecutionLog | Record completed jobs with metrics |
| 3 | UpdateProgress | DM: job status counts | FlowExecutionTracking | Update flow job counts |
| 4 | TransitionStates | FlowExecutionTracking | FlowExecutionTracking | Manage state machine transitions |
| 5 | DetectStalls | DM: executing jobs, Status | Status, StallDetectionLog, alert queues | Snapshot comparison stall detection |
| 6 | ValidateFlows | FlowExecutionTracking, JobExecutionLog, ErrorCategory, JobConfig | ValidationLog, ValidationException, FlowExecutionTracking, alert queues | Post-completion flow analysis |
| 7 | DetectMissing | Schedule, FlowExecutionTracking | Jira queue, Teams queue | Check for no-show flows |



Step ordering matters. ConfigSync runs first to ensure FlowConfig is current before detection. DetectFlows runs before CaptureJobs because you need tracking records before you can attach job completions. UpdateProgress runs before TransitionStates because state decisions depend on current counts. DetectStalls runs after state transitions because it needs accurate executing/pending lists. Validation runs after everything else because it needs final state.


Why the early exit skips Steps 1–6 but always runs Step 7. Steps 1–6 are only meaningful when flows are executing — there is nothing to detect, capture, update, transition, stall-check, or validate if no jobs are running. Step 7 (DetectMissing) is the opposite: it specifically looks for flows that *should* have started but haven't, so it must run regardless of whether anything is currently active. ConfigSync (Step 0) also always runs because drift between DM and FlowConfig is independent of whether any jobs are executing at the moment.







Stall Detection

Stall detection operates at the system level. Individual flows may legitimately show no progress while other flows are processing — the JBoss JMS queue is non-FIFO and batch-oriented. A stall is only flagged when NO jobs across ALL flows show progress.

Snapshot Comparison Algorithm







Capture
XML snapshot of all
executing & pending
jobs with status +
record counts

→

Compare
Diff against previous
snapshot stored in
Status.stall_snapshot_xml

→

Changed?





Yes — progress detected

RESET
Counter → 0
Log to StallDetectionLog



No — nothing moved

INCREMENT
Counter + 1
Log to StallDetectionLog

→

At threshold?

→

ALERT
Jira ticket + Teams
Stall confirmed




Each poll captures and compares. Progress resets the counter. No progress increments it. Threshold triggers the alert.


Event Lifecycle

| Counter | Event Type | Action |
| --- | --- | --- |
| 0 → 1, 1 → 2, ... (n-1) → n | INCREMENT | Log to StallDetectionLog. Building toward threshold. |
| Reaches threshold | ALERT | Log + queue Jira ticket + queue Teams alert. Stall confirmed. |
| Above threshold | STALLED | Log only. Already alerted, no repeat notifications. |
| Any → 0 | RESET | Log. Progress detected, stall episode ended. |


Deduplication

Stall alerts are suppressed if there's an existing ALERT event today with no subsequent RESET. This means a stall-recovery-stall cycle generates two separate alerts (correct behavior), while a continuous stall generates only one alert at threshold (also correct).


XML snapshot format. The snapshot stores each job's `job_log_id`, `job_stts_cd`, and processed record count. Both "cross-poll progress" (job list changed between polls) and "within-poll progress" (record counts changed during snapshot capture) are tracked. This diagnostic data is preserved in StallDetectionLog for post-incident analysis.







Validation Pipeline

Step-ValidateCompletedFlows runs against flows in COMPLETE state with `is_validated` still NULL. It performs a multi-stage analysis:

Stage 1: Expected vs Actual

Compares `expected_jobs_json` (captured at flow detection time) against actual jobs in `JobExecutionLog` for this tracking_id. Identifies missing jobs, unexpected jobs, and order mismatches.

Stage 2: Failure Classification

For jobs with total failure (all records failed, none succeeded), the error message is extracted and matched against `ErrorCategory`. The `classification` determines whether the failure is alertable:

| Classification | alert_on_total_failure | Action |
| --- | --- | --- |
| TRUE_FAILURE | 1 | Generate Jira ticket if failure count ≥ min_failure_threshold |
| BUSINESS_REJECTION | 0 | Log in ValidationException, no alert |
| UNCLASSIFIED | 1 | Alert — new patterns need investigation |


Stage 3: Criticality Check

Missing or failed jobs are checked against `JobConfig.is_critical`. Critical jobs fall into two categories:

| Flag | Why It's Critical | Impact of Missing |
| --- | --- | --- |
| `has_fixed_date_logic` | Job uses date-specific criteria (e.g., "send letter on day 5") | Records are permanently missed — tomorrow's run picks up the next batch, not yesterday's |
| `is_business_critical` | Job is essential for daily operations | Downstream processes or departments are affected |


If any critical job is missing or failed, the validation status escalates to CRITICAL_FAILURE and the Jira ticket includes the `criticality_reason` from JobConfig.

Stage 4: Record Results

`ValidationLog` gets a summary row with counts and status. `ValidationException` gets one row per discrepant job. `FlowExecutionTracking` transitions to VALIDATED with `is_validated = 1` to prevent reprocessing.


Error pattern extraction. DM error messages follow two patterns. Action-based: "Failed to execute action: ActionName (ENTITY)..." where the action name is extracted (e.g., CallRuleSet, SendNotice). Non-action: matched by prefix (e.g., "Data is stale" → StaleData). Currently 16 error types are classified: 2 TRUE_FAILURE, 13 BUSINESS_REJECTION, 1 UNCLASSIFIED (OTHER).







Missing Flow Detection

Step 7 (DetectMissing) runs on every cycle regardless of whether any jobs are currently active. It compares the `Schedule` table against today's entries in `FlowExecutionTracking` to identify flows that should have started but haven't.

Each schedule entry defines an expected start time and a tolerance window — the buffer after the expected start before an alert fires. Tolerance is configurable per schedule: tighter for critical nightly flows, looser for weekly or maintenance-oriented flows.

| Scenario | Behavior |
| --- | --- |
| Flow started within tolerance | No action — normal operation |
| Flow not started, past tolerance | Jira ticket + Teams alert for the missing flow |
| Schedule inactive | Skipped — no evaluation |
| Flow marked UNCONFIGURED | Excluded — new flows from ConfigSync aren't evaluated until configured |



Schedule types. The `schedule_type` column supports different scheduling models: DAILY for every-night flows, WEEKLY for specific days, and DAY_OF_MONTH for monthly schedules. Each type is evaluated differently — a WEEKLY schedule only checks on its configured days, avoiding false alerts on off-days.







ConfigSync

Step 0 runs on every cycle to keep `FlowConfig` in sync with Debt Manager's flow definitions. It compares DM's current flow list against xFACts and handles three scenarios:

| Scenario | Action | Jira Ticket? |
| --- | --- | --- |
| **New flow in DM** | Insert config row with `is_monitored = 0`, `expected_schedule = UNCONFIGURED` | Yes — prompts configuration |
| **Flow deactivated** | Set `dm_is_active = 0` | Yes — awareness notification |
| **Flow reactivated** | Set `dm_is_active = 1` | No — back to normal, silent |



Why ConfigSync runs every cycle. Drift between DM and FlowConfig is independent of whether any jobs are executing. A flow could be added to DM while nothing is running overnight. ConfigSync ensures the configuration is always current before any other step evaluates it.







Status Translation

xFACts interprets DM job status codes differently than DM itself. The key insight: a job with failed records isn't necessarily a "failure" in the operational sense.

| DM Code | DM Status | xFACts Status | Condition |
| --- | --- | --- | --- |
| 1 | Started | EXECUTING | Job currently running |
| 2 | Failed | **PARTIAL** | succeeded_count > 0 (work was done) |
| 2 | Failed | **FAILED** | succeeded_count = 0 (true failure) |
| 3 | Complete | COMPLETED | Normal completion |
| 3 | Complete | **PARTIAL** | succeeded_count > 0 AND failed_count > 0 |
| 4 | Cancelled | CANCELLED | User-initiated cancellation |
| 5 | Pending Cancel | EXECUTING | Still in-progress (cancel pending) |
| 6 | Pending | PENDING | Queued, waiting to start |



Why this matters. A job that processes 9,999 records successfully and rejects 1 for a business rule shows DM status 2 (Failed). xFACts calls it PARTIAL — work was accomplished. This prevents false alarms on jobs that are working correctly but have expected rejections. Only jobs with zero successful records are TRUE failures.







Troubleshooting

**"The overnight jobs didn't complete."**
Start with `FlowExecutionTracking` — find the flow and check its `execution_state`. EXECUTING means it's still running (check DM for current progress). STALLED means processing froze (check `StallDetectionLog` for when and the diagnostic snapshots for why). COMPLETE means it finished but maybe with issues (check `ValidationLog`).

**"Jobs are failing."**
Check `JobExecutionLog` filtered by date. Look at `job_status`: FAILED means true technical failure. PARTIAL means some records succeeded but some were rejected. COMPLETED means the job is fine — look elsewhere. Check `total_records`, `succeeded_count`, and `failed_count` to understand the scope.

**"A scheduled flow didn't run."**
Verify the schedule in `Schedule` — is it active? Is the tolerance window reasonable? Then check `FlowExecutionTracking` for today's executions. If no execution exists and no alert was raised, the schedule might be inactive or the flow's `alert_on_missing` flag might be off.

**"The system was 'stalled' but nothing looks wrong."**
Review `StallDetectionLog` — the diagnostic XML snapshots show exactly what jobs were in flight during each poll. Sometimes a "stall" is actually just very slow processing of a massive job where the record count isn't changing visibly between polls. The snapshots help distinguish "truly frozen" from "legitimately slow but please be patient."

**"A new flow was detected but isn't being monitored."**
Expected behavior. ConfigSync inserts new flows with `is_monitored = 0` and `expected_schedule = UNCONFIGURED`. A Jira ticket was created to prompt configuration. Set the schedule, enable monitoring, and the flow enters the pipeline on the next cycle.

**"Monitor-JobFlow.ps1 isn't running."**
Check `Status` — if `completed_dttm` for any step is stale, the script may have stopped. Check the orchestrator logs and ProcessRegistry. Common causes: AG replica unavailable, credential issues, network connectivity.






How Everything Connects

JobFlow reads from one external system and writes to three xFACts subsystems. The data flow is strictly one-directional: read from DM, write to xFACts. No feedback loops, no write-backs.

Internal Relationships

| From | To | Relationship |
| --- | --- | --- |
| `FlowConfig` | `FlowExecutionTracking` | FK on job_sqnc_id — one config → many executions |
| `FlowConfig` | `Schedule` | FK on job_sqnc_id — one config → many schedules |
| `FlowExecutionTracking` | `JobExecutionLog` | FK on tracking_id — one execution → many jobs |
| `FlowExecutionTracking` | `ValidationLog` | FK on tracking_id — one execution → one validation |
| `ValidationLog` | `ValidationException` | FK on validation_id — one validation → many exceptions |


External Dependencies

| Dependency | Module | Purpose |
| --- | --- | --- |
| `Orchestrator.ProcessRegistry` | Orchestrator | Schedules Monitor-JobFlow.ps1 on a configurable interval |
| `dbo.GlobalConfig` | Shared Infrastructure | AG config (AGName, SourceReplica), StallThreshold |
| Debt Manager (crs5_oltp) | External | Source system — read-only via AG secondary replica |
| `Teams.AlertQueue` | Teams Integration | Stall alerts, missing flow alerts |
| `Jira.TicketQueue` | Jira Integration | Stall tickets, validation failures, missing flows, ConfigSync changes |


DM Source Tables

| DM Table | Used By Step | Purpose |
| --- | --- | --- |
| `job_sqnc` | ConfigSync (0) | Flow definitions and active status |
| `job_sqnc_log` | DetectFlows (1) | Flow execution instances |
| `job_sqnc_exctn_log` | CaptureJobs (2) | Flow-to-job execution linkage |
| `job_log` | Early Exit Check, CaptureJobs (2), DetectStalls (5) | Individual job execution records; active/pending count drives early exit |
| `job_entty_log` | CaptureJobs (2) | Record-level results (success/failure counts) |
| `job` | ConfigSync (0) | Job definitions |
| `usr` | CaptureJobs (2) | User identification for executed_by |

---

## Reference

### ErrorCategory

Classification reference table for job record-level error patterns, used by Monitor-JobFlow.ps1 to determine whether total job failures should trigger alerts or be suppressed as expected business behavior.

**Alert Suppression for Business Rejections:** [sort:1] DM marks a job as Failed when any record is rejected. Most rejections are expected business behavior — consumers that do not meet mailing criteria, stale data from concurrent access, etc. ErrorCategory classifies each error pattern so validation can distinguish TRUE_FAILURE (alert) from BUSINESS_REJECTION (log only). Only 2 of 16 error types generate alerts; 13 are suppressed as business rejections.

**Pattern Extraction:** [sort:2] DM error messages follow two patterns: action-based ("Failed to execute action: ActionName (ENTITY)") where the action name is extracted, and non-action patterns matched directly (e.g., "Data is stale" ? StaleData, "User with Id:" ? UserInitiated). The error_type column stores the extracted pattern for lookup.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| category_id (IDENTITY) | int | No | IDENTITY | PK |
| error_type | varchar(100) | No | — | Pattern identifier extracted from error message. For action-based errors, this is the action name (e.g., CallRuleSet, SendNotice). For non-action errors, this is a pattern key (e.g., StaleData, UserInitiated) |
| classification | varchar(50) | Yes | — | Category classification: TRUE_FAILURE, BUSINESS_REJECTION, or UNCLASSIFIED |
| alert_on_total_failure | bit | No | 1 | Whether to generate a Jira ticket when this error type causes a total job failure. 1 = alert, 0 = suppress |
| min_failure_threshold | int | No | 10 | Minimum number of failed records before alerting. Prevents noise from low-volume sporadic failures |
| description | varchar(255) | Yes | — | Human-readable description of the error type. Used in Jira ticket content to provide immediate context |
| created_dttm | datetime | Yes | getdate() | When this category was created |
| modified_dttm | datetime | Yes | — | When this category was last modified |

  - **PK_ErrorCategory** (CLUSTERED): category_id -- PRIMARY KEY
  - **UQ_ErrorCategory_ErrorType** (NONCLUSTERED): error_type

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| classification | TRUE_FAILURE | Genuine system or configuration error requiring investigation. Generates Jira ticket on total failure. | 1 |
| classification | BUSINESS_REJECTION | Records rejected due to expected business rule conditions. System is working correctly. No ticket generated. | 2 |
| classification | UNCLASSIFIED | Unknown error pattern. Alerts to ensure new patterns are investigated and classified. | 3 |

**Alertable Error Types** [sort:1] -- Shows error types that will generate a Jira ticket on total job failure.

```sql
SELECT error_type, description
FROM JobFlow.ErrorCategory
WHERE alert_on_total_failure = 1;
```

**Simulate Alert Decision** [sort:2] -- Tests the alert-vs-suppress logic for a given error type and failure count, matching what Monitor-JobFlow uses in Step-ValidateCompletedFlows.

```sql
DECLARE @error_type VARCHAR(100) = 'CallRuleSet';
DECLARE @failed_count INT = 15;

SELECT 
    error_type,
    classification,
    alert_on_total_failure,
    CASE 
        WHEN alert_on_total_failure = 1 
         AND @failed_count >= min_failure_threshold 
        THEN 'ALERT'
        ELSE 'SUPPRESS'
    END AS action
FROM JobFlow.ErrorCategory
WHERE error_type = @error_type;
```


### FlowConfig

Per-flow monitoring configuration including active status, scheduling expectations, alert settings, and synchronization with Debt Manager.

**Data Flow:** Monitor-JobFlow.ps1 Step-ConfigSync: INSERT new flows (is_monitored=0, expected_schedule=UNCONFIGURED) | UPDATE dm_is_active and dm_last_sync_dttm for existing flows | Queues Jira ticket for new/deactivated flows.

**ConfigSync Integration:** [sort:1] FlowConfig is automatically maintained by Monitor-JobFlow.ps1 Step-ConfigSync, which runs as the first step of every monitoring cycle. New flows detected in DM are inserted with is_monitored = 0 and expected_schedule = UNCONFIGURED, triggering a Jira ticket for configuration. Deactivated flows get dm_is_active set to 0 with a Jira ticket. Reactivated flows get dm_is_active reset to 1 silently. The dm_last_sync_dttm field tracks when each flow was last verified against DM.

**Effective Dating:** [sort:2] effective_start_date and effective_end_date support future-dated configuration changes. A configuration with an end date can be superseded by a new row with a later start date. NULL effective_end_date means no expiration. Check constraints enforce end_date >= start_date when end_date is populated.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| config_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this configuration row |
| job_sqnc_id | bigint | No | — | Flow ID from crs5_oltp.dbo.job_sqnc. Unique constraint |
| job_sqnc_shrt_nm | varchar(50) | No | — | Flow short name (e.g., JFDNEV). Denormalized for convenience |
| job_sqnc_nm | varchar(255) | Yes | — | Full flow name |
| dm_is_active | bit | Yes | — | Whether flow is active in DM (job_sqnc_actv_flg = 'Y'). NULL if never synced |
| dm_last_sync_dttm | datetime | Yes | — | When ConfigSync last verified this flow against DM |
| is_monitored | bit | No | 1 | Whether xFACts should monitor this flow. Set to 0 to exclude from processing |
| expected_schedule | varchar(50) | No | — | Human-readable schedule description (e.g., 'DAILY', 'WEEKDAYS', 'WEEKLY') |
| expected_max_duration_hours | int | Yes | — | Expected maximum runtime for duration alerting. Reserved for future use |
| alert_on_missing | bit | No | 1 | Generate alerts if flow doesn't start within expected window |
| alert_on_critical_failure | bit | No | 1 | Generate alerts if critical jobs fail within this flow |
| effective_start_date | date | No | CONVERT([date],getdate()) | When this configuration becomes active |
| effective_end_date | date | Yes | — | When this configuration expires. NULL = no expiration |
| created_dttm | datetime | No | getdate() | When this row was created |
| created_by | varchar(100) | No | suser_sname() | Who created this row |
| modified_dttm | datetime | Yes | — | Last modification timestamp |
| modified_by | varchar(100) | Yes | — | Who last modified this row |
| notes | varchar(1000) | Yes | — | Free-form notes about this flow configuration |

  - **PK_FlowConfig** (CLUSTERED): config_id -- PRIMARY KEY
  - **IX_FlowConfig_Active** (NONCLUSTERED): job_sqnc_id, effective_start_date, effective_end_date
  - **IX_FlowConfig_Schedule** (NONCLUSTERED): expected_schedule, is_monitored [includes: job_sqnc_shrt_nm, expected_max_duration_hours]
  - **UQ_FlowConfig_FlowEffDates** (NONCLUSTERED): job_sqnc_id, effective_start_date, effective_end_date
  - **UQ_FlowConfig_job_sqnc_id** (NONCLUSTERED): job_sqnc_id

**Check Constraints:**

  - **CK_FlowConfig_Duration**: `([expected_max_duration_hours] IS NULL OR [expected_max_duration_hours]>(0))`
  - **CK_FlowConfig_EffDates**: `([effective_end_date] IS NULL OR [effective_end_date]>=[effective_start_date])`
  - **CK_FlowConfig_ExpectedSchedule**: `([expected_schedule]='UNCONFIGURED' OR [expected_schedule]='ON-DEMAND' OR [expected_schedule]='VARIABLE' OR [expected_schedule]='EVERY_N_HOURS' OR [expected_schedule]='MONTHLY' OR [expected_schedule]='WEEKLY' OR [expected_schedule]='DAILY')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| expected_schedule | DAILY | Flow runs every day. | 1 |
| expected_schedule | WEEKDAYS | Flow runs Monday through Friday. | 2 |
| expected_schedule | WEEKLY | Flow runs on a specific day of the week. | 3 |
| expected_schedule | MONTHLY | Flow runs on a specific day of the month. | 4 |
| expected_schedule | EVERY_N_HOURS | Flow runs multiple times per day at a fixed interval. | 5 |
| expected_schedule | VARIABLE | Flow has a non-standard schedule. | 6 |
| expected_schedule | ON-DEMAND | Flow runs only when manually triggered. | 7 |
| expected_schedule | UNCONFIGURED | New flow detected by ConfigSync — awaiting schedule configuration. Not included in missing flow detection. | 8 |

**Active Monitored Flows** [sort:1] -- Lists all flows that are both monitored by xFACts and active in Debt Manager, with their alert settings.

```sql
SELECT 
    job_sqnc_shrt_nm AS flow_code,
    job_sqnc_nm AS flow_name,
    expected_schedule,
    alert_on_missing,
    alert_on_critical_failure
FROM JobFlow.FlowConfig
WHERE is_monitored = 1
  AND dm_is_active = 1
ORDER BY job_sqnc_shrt_nm;
```

**Sync Status Check** [sort:2] -- Shows when each flow was last verified against Debt Manager. Large hours_since_sync values indicate ConfigSync may not be running.

```sql
SELECT 
    job_sqnc_shrt_nm,
    dm_is_active,
    dm_last_sync_dttm,
    DATEDIFF(HOUR, dm_last_sync_dttm, GETDATE()) AS hours_since_sync
FROM JobFlow.FlowConfig
ORDER BY dm_last_sync_dttm DESC;
```

**Flows Not In DM** [sort:3] -- Finds flows that are deactivated or have never been synced with Debt Manager — useful for drift detection.

```sql
SELECT 
    job_sqnc_shrt_nm,
    dm_is_active,
    notes
FROM JobFlow.FlowConfig
WHERE dm_is_active = 0 OR dm_is_active IS NULL
ORDER BY job_sqnc_shrt_nm;
```

  - **Parent of FlowExecutionTracking**: [sort:1] FlowExecutionTracking.job_sqnc_id references FlowConfig.job_sqnc_id (UQ). Each flow config can have many execution tracking records over time — one per execution instance.
  - **Parent of Schedule**: [sort:2] Schedule.job_sqnc_id references FlowConfig.job_sqnc_id. A flow can have multiple schedule rows (e.g., weekday schedule + weekend schedule).
  - **Source: crs5_oltp.dbo.job_sqnc**: [sort:3] The job_sqnc_id and job_sqnc_shrt_nm columns originate from crs5_oltp.dbo.job_sqnc. ConfigSync queries DM for active flows (job_sqnc_actv_flg = Y) and synchronizes dm_is_active and dm_last_sync_dttm each cycle.


### FlowExecutionTracking

The core state machine table that tracks each flow execution instance from detection through completion.

**Data Flow:** Step-DetectFlows: INSERT new rows (state=DETECTED). Step-UpdateFlowProgress: UPDATE job counts. Step-TransitionFlowStates: UPDATE execution_state. Step-ValidateCompletedFlows: UPDATE is_validated and validation_dttm. Step-DetectStalls: UPDATE execution_state to STALLED or back to EXECUTING.

**Tracking via job_sqnc_log_id:** [sort:1] Each flow can execute multiple times per day. The job_sqnc_log_id from crs5_oltp.dbo.job_sqnc_log uniquely identifies each execution instance, preventing incorrect aggregation of multiple daily runs. Added in v1.1.0 after discovering that tracking by job_sqnc_id alone merged separate executions.

**State Machine:** [sort:2] States: DETECTED ? EXECUTING ? COMPLETE ? VALIDATED (happy path). EXECUTING can also transition to STALLED (no progress for 30+ minutes), which returns to EXECUTING when progress resumes. ABANDONED is a manual terminal state. State transitions are managed by Monitor-JobFlow.ps1 Step-TransitionFlowStates.

**Backfilled Records:** [sort:3] Records with tracking_id = 0 were backfilled from dm_history and represent executions that occurred before real-time monitoring began. These rows have NULL job_sqnc_log_id and may have incomplete job counts.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| tracking_id (IDENTITY) | bigint | No | IDENTITY | PK |
| job_sqnc_log_id | bigint | Yes | — | FK |
| job_sqnc_id | bigint | No | — | The flow definition ID from crs5_oltp.dbo.job_sqnc. Does not change between executions |
| job_sqnc_shrt_nm | varchar(50) | No | — | Flow short name (e.g., JFDNEV, JFD4HR). Denormalized for query convenience |
| execution_date | date | No | — | Calendar date of the execution. Used with execution_sequence for daily uniqueness |
| execution_sequence | int | No | 1 | Sequential run number for this flow on this date (1st run = 1, 2nd run = 2, etc.) |
| execution_state | varchar(20) | No | — | Current state: DETECTED, EXECUTING, COMPLETE, FAILED, CANCELLED |
| first_detected_dttm | datetime | No | getdate() | When sp_StateMonitor first detected this execution |
| last_activity_dttm | datetime | No | getdate() | Last time any change was recorded for this execution |
| completion_dttm | datetime | Yes | — | When execution_state transitioned to COMPLETE |
| validation_dttm | datetime | Yes | — | When post-completion validation was run (if applicable) |
| is_validated | bit | Yes | — | Set to 1 after Step-ValidateCompletedFlows processes the flow. Prevents duplicate validation |
| execution_window_start | datetime | Yes | — | When the flow execution began in the source system (from job_sqnc_exctn_dttm) |
| execution_window_end | datetime | Yes | — | When the last job in the flow completed |
| expected_job_count | int | Yes | — | Number of jobs defined in the flow at detection time |
| completed_job_count | int | No | 0 | Jobs with terminal success status |
| executing_job_count | int | No | 0 | Jobs currently running (job_stts_cd = 1) |
| pending_job_count | int | No | 0 | Jobs waiting to start (job_stts_cd = 6) |
| failed_job_count | int | No | 0 | Jobs that failed (job_stts_cd = 2 with zero records processed) |
| cancelled_job_count | int | No | 0 | Jobs that were cancelled |
| expected_jobs_json | nvarchar(MAX) | Yes | — | JSON array of expected jobs captured at detection time. Preserves flow definition even if it changes later |
| aggregate_completed_records | bigint | No | 0 | Total records processed across all completed jobs in this execution |
| last_poll_completed_records | bigint | Yes | — | Records completed as of the previous poll. Used to calculate throughput |
| created_dttm | datetime | No | getdate() | When this tracking record was created |
| modified_dttm | datetime | No | getdate() | Last modification timestamp. Updated on every poll that touches this row |

  - **PK_FlowExecutionTracking** (CLUSTERED): tracking_id -- PRIMARY KEY
  - **IX_FlowExecutionTracking_ActiveStates** (NONCLUSTERED): execution_state, last_activity_dttm
  - **IX_FlowExecutionTracking_ByFlow** (NONCLUSTERED): job_sqnc_id, execution_date [includes: execution_state, completion_dttm]
  - **IX_FlowExecutionTracking_JobSqncLogId** (NONCLUSTERED): job_sqnc_log_id
  - **IX_FlowExecutionTracking_Recent** (NONCLUSTERED): execution_date, job_sqnc_shrt_nm [includes: execution_state, execution_window_start, completion_dttm, completed_job_count, failed_job_count]
  - **UQ_FlowExecutionTracking_job_sqnc_log_id** (NONCLUSTERED): job_sqnc_log_id

**Check Constraints:**

  - **CK_FlowExecutionTracking_Counts**: `([completed_job_count]>=(0) AND [executing_job_count]>=(0) AND [pending_job_count]>=(0) AND [failed_job_count]>=(0) AND [cancelled_job_count]>=(0))`
  - **CK_FlowExecutionTracking_Sequence**: `([execution_sequence]>(0))`
  - **CK_FlowExecutionTracking_State**: `([execution_state]='HISTORICAL' OR [execution_state]='ABANDONED' OR [execution_state]='STALLED' OR [execution_state]='VALIDATED' OR [execution_state]='COMPLETE' OR [execution_state]='EXECUTING' OR [execution_state]='DETECTED')`

**Foreign Keys:**

  - **FK_FlowExecutionTracking_FlowConfig**: job_sqnc_id -> JobFlow.FlowConfig.job_sqnc_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| execution_state | DETECTED | Flow execution found in source system. Jobs not yet started. | 1 |
| execution_state | EXECUTING | At least one job has begun processing. | 2 |
| execution_state | COMPLETE | All expected jobs have finished. Awaiting validation. | 3 |
| execution_state | VALIDATED | Post-execution validation has run. Terminal state for happy path. | 4 |
| execution_state | STALLED | No system-wide progress detected for 30+ minutes. Returns to EXECUTING on recovery. | 5 |
| execution_state | ABANDONED | Flow manually abandoned. Terminal state. | 6 |

**Currently Executing Flows** [sort:1] -- Shows all flow executions currently in progress with job counts and start time.

```sql
SELECT 
    tracking_id,
    job_sqnc_shrt_nm AS flow_code,
    execution_state,
    executing_job_count,
    pending_job_count,
    completed_job_count,
    execution_window_start
FROM JobFlow.FlowExecutionTracking
WHERE execution_state IN ('DETECTED', 'EXECUTING')
ORDER BY execution_window_start;
```

**Today's Flow Summary** [sort:2] -- Daily overview of all flow executions with state, job counts, record totals, and duration.

```sql
SELECT 
    job_sqnc_shrt_nm AS flow_code,
    execution_sequence,
    execution_state,
    expected_job_count,
    completed_job_count,
    failed_job_count,
    aggregate_completed_records,
    DATEDIFF(MINUTE, execution_window_start, ISNULL(completion_dttm, GETDATE())) AS duration_minutes
FROM JobFlow.FlowExecutionTracking
WHERE execution_date = CAST(GETDATE() AS DATE)
ORDER BY execution_window_start;
```

**Flows With Multiple Daily Runs** [sort:3] -- Identifies flows that executed more than once on the same day over the past 30 days — useful for understanding scheduling patterns and detecting anomalies.

```sql
SELECT 
    job_sqnc_shrt_nm,
    execution_date,
    COUNT(*) AS run_count
FROM JobFlow.FlowExecutionTracking
WHERE execution_date >= DATEADD(DAY, -30, GETDATE())
GROUP BY job_sqnc_shrt_nm, execution_date
HAVING COUNT(*) > 1
ORDER BY execution_date DESC, run_count DESC;
```

**Flows Pending Validation** [sort:4] -- Finds completed flow executions that have not yet been validated — indicates Step-ValidateCompletedFlows may need attention.

```sql
SELECT 
    tracking_id,
    job_sqnc_shrt_nm,
    execution_date,
    completion_dttm
FROM JobFlow.FlowExecutionTracking
WHERE execution_state = 'COMPLETE'
  AND validation_dttm IS NULL
  AND completion_dttm IS NOT NULL
ORDER BY completion_dttm;
```

  - **Child of FlowConfig**: [sort:1] FlowExecutionTracking.job_sqnc_id references FlowConfig.job_sqnc_id. Many execution rows per flow config — one per execution instance.
  - **Parent of JobExecutionLog**: [sort:2] JobExecutionLog.tracking_id references FlowExecutionTracking.tracking_id. One execution can have many job completion records.
  - **Parent of ValidationLog**: [sort:3] ValidationLog.tracking_id references FlowExecutionTracking.tracking_id. One validation per completed execution.
  - **Source: crs5_oltp.dbo.job_sqnc_log**: [sort:4] The job_sqnc_log_id column links to crs5_oltp.dbo.job_sqnc_log. Step-DetectFlows queries this table for new execution instances not yet tracked in xFACts.


### JobConfig

Job-level configuration including DM synchronization, criticality classification, and fixed date logic detection for prioritized alerting.

**Dual Criticality Model:** [sort:1] has_fixed_date_logic flags jobs whose SQL filters use today-only date logic — records are permanently missed if the job does not run on schedule. is_business_critical flags jobs essential to daily operations regardless of date logic. The computed is_critical column (persisted) is 1 if either flag is set, simplifying queries while preserving the reason.

**Population and Maintenance:** [sort:2] Initial population from 313 historical jobs found in DM execution history. Criticality flags populated through team review of job filter logic and business requirements. ConfigSync maintains dm_is_active and dm_last_sync_dttm for drift detection.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| config_id (IDENTITY) | int | No | IDENTITY | PK |
| job_id | bigint | No | — | UQ |
| job_shrt_nm | varchar(50) | No | — | Job short name (e.g., NBIMPORT). Denormalized |
| job_nm | varchar(255) | Yes | — | Full job name |
| dm_is_active | bit | Yes | — | Whether job is active in DM. NULL if never synced |
| dm_last_sync_dttm | datetime | Yes | — | When last verified against DM |
| last_execution_dttm | datetime | Yes | — | When job last executed (from DM history) |
| criticality_reason | varchar(255) | Yes | — | Explanation of why job is marked critical |
| effective_start_date | date | No | CONVERT([date],getdate()) | When this configuration becomes active |
| effective_end_date | date | Yes | — | When this configuration expires. NULL = no expiration |
| created_dttm | datetime | No | getdate() | When this row was created |
| created_by | varchar(100) | No | suser_sname() | Who created this row |
| modified_dttm | datetime | Yes | — | Last modification timestamp |
| modified_by | varchar(100) | Yes | — | Who last modified this row |
| notes | varchar(500) | Yes | — | Free-form notes about this job configuration |
| has_fixed_date_logic | bit | No | 0 | Job filter uses fixed dates (e.g., WHERE date = TODAY). Records permanently lost if missed |
| is_business_critical | bit | No | 0 | Job is essential for daily operations regardless of date logic |
| is_critical | int | No | — | 1 if either flag is set, 0 otherwise. Computed persisted column |

  - **PK_JobConfig** (CLUSTERED): config_id -- PRIMARY KEY
  - **IX_JobConfig_Critical** (NONCLUSTERED): is_critical
  - **IX_JobConfig_ShortName** (NONCLUSTERED): job_shrt_nm
  - **UQ_JobConfig_job_id** (NONCLUSTERED): job_id

**Critical Jobs Summary** [sort:1] -- Lists all jobs marked critical (either fixed date logic or business critical) with their classification reason.

```sql
SELECT 
    job_shrt_nm,
    job_nm,
    has_fixed_date_logic,
    is_business_critical,
    criticality_reason
FROM JobFlow.JobConfig
WHERE is_critical = 1
ORDER BY job_shrt_nm;
```

**Jobs by Criticality Type** [sort:2] -- Distribution of jobs across criticality categories — helps assess alert coverage.

```sql
SELECT 
    CASE 
        WHEN has_fixed_date_logic = 1 AND is_business_critical = 1 THEN 'Both'
        WHEN has_fixed_date_logic = 1 THEN 'Fixed Date Logic'
        WHEN is_business_critical = 1 THEN 'Business Critical'
        ELSE 'Not Critical'
    END AS criticality_type,
    COUNT(*) AS job_count
FROM JobFlow.JobConfig
GROUP BY 
    CASE 
        WHEN has_fixed_date_logic = 1 AND is_business_critical = 1 THEN 'Both'
        WHEN has_fixed_date_logic = 1 THEN 'Fixed Date Logic'
        WHEN is_business_critical = 1 THEN 'Business Critical'
        ELSE 'Not Critical'
    END
ORDER BY job_count DESC;
```

**Jobs Not Recently Executed** [sort:3] -- Finds active jobs that haven't executed in 30+ days — may indicate deactivated or orphaned job definitions.

```sql
SELECT 
    job_shrt_nm,
    last_execution_dttm,
    DATEDIFF(DAY, last_execution_dttm, GETDATE()) AS days_since_execution
FROM JobFlow.JobConfig
WHERE dm_is_active = 1
  AND (last_execution_dttm IS NULL OR last_execution_dttm < DATEADD(DAY, -30, GETDATE()))
ORDER BY last_execution_dttm;
```

  - **Referenced by ValidationException**: [sort:1] Step-ValidateCompletedFlows joins JobConfig to determine if a missing or failed job is critical. The is_critical flag and criticality_reason drive alert severity and Jira ticket content.
  - **Source: crs5_oltp.dbo.job**: [sort:2] The job_id and job_shrt_nm columns originate from crs5_oltp.dbo.job. ConfigSync synchronizes dm_is_active status from DM.


### JobExecutionLog

Captures detailed execution history for individual jobs within flow executions, preserving metrics at the moment of completion.

**Data Flow:** Queries crs5_oltp.dbo.job_log for jobs with terminal status codes (2, 3, 4) not already in JobExecutionLog (dedup via NOT EXISTS on job_log_id). Calculates job_status using status translation rules, captures record counts, timing metrics, and error messages.

**Status Translation:** [sort:1] DM marks a job as Failed (status 2) if any record fails validation. xFACts uses PARTIAL when records were successfully processed despite some rejections, reserving FAILED for true technical failures where no work was done. This prevents false alarms on jobs that are working correctly but have expected business rule rejections.

**Capture Timing:** [sort:2] Rows are inserted when Monitor-JobFlow.ps1 Step-CaptureCompletedJobs detects a terminal status. captured_dttm is when xFACts recorded the event, not when the job actually finished. The job_reported_complete_dttm from DM is the actual completion time. The gap depends on polling interval (up to ~5 minutes).

**Data Volume:** [sort:3] Approximately 200-400 new rows per night during normal operations. Historical data spans back to June 2020 via backfill from dm_history. Records with tracking_id = 0 indicate pre-monitoring backfill.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| execution_detail_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for each job execution record |
| tracking_id | bigint | Yes | — | Links to FlowExecutionTracking. NULL or 0 for backfilled/orphaned records |
| job_log_id | bigint | No | — | Links to crs5_oltp.dbo.job_log. The source system execution ID |
| job_id | bigint | No | — | Job definition ID from crs5_oltp.dbo.job |
| job_shrt_nm | varchar(50) | No | — | Job short name (e.g., NBIMPORT, INTCALC). Denormalized for convenience |
| job_nm | varchar(255) | Yes | — | Full job name. May be NULL for older records |
| job_sqnc_id | bigint | Yes | — | Flow ID this job executed within. NULL if job ran outside a flow |
| job_sqnc_shrt_nm | varchar(50) | Yes | — | Flow short name. NULL if job ran outside a flow |
| execution_order_nmbr | int | Yes | — | Order position within the flow (1st job, 2nd job, etc.) |
| execution_type | varchar(20) | No | — | How the job was triggered: SCHEDULED or AD_HOC |
| executed_by | varchar(100) | No | — | Username that initiated the execution |
| execution_date | date | No | — | Calendar date of execution. Used for daily aggregations |
| job_exec_dttm | datetime | No | — | When the job execution was initiated (from job_log) |
| job_start_dttm | datetime | Yes | — | When the first record began processing |
| job_end_dttm | datetime | Yes | — | When the last record finished processing |
| job_reported_complete_dttm | datetime | No | — | When DM marked the job complete (status change timestamp) |
| total_records | int | Yes | — | Total records assigned to this job (job_entty_ttl_nmbr). NULL if job had no records |
| succeeded_count | int | Yes | — | Records that processed without errors |
| failed_count | int | Yes | — | Records that failed business rule validation |
| records_per_second | decimal(10,2) | Yes | — | Calculated throughput rate |
| execution_time_seconds | int | Yes | — | Total execution duration in seconds |
| job_status | varchar(20) | No | — | xFACts status: EXECUTING, PENDING, CANCELLED, CANCELLING, FAILED, COMPLETED, PARTIAL, UNKNOWN |
| job_stts_cd | int | No | — | Raw DM status code (1=Started, 2=Failed, 3=Complete, etc.) |
| error_message | varchar(MAX) | Yes | — | Error text from DM if job failed. Sanitized of PII |
| captured_dttm | datetime | No | getdate() | When xFACts captured this completion record |

  - **PK_JobExecutionLog** (CLUSTERED): execution_detail_id -- PRIMARY KEY
  - **IX_JobExecutionLog_AdHoc** (NONCLUSTERED): execution_date, executed_by
  - **IX_JobExecutionLog_ByDate** (NONCLUSTERED): execution_date, execution_type, executed_by [includes: job_sqnc_shrt_nm, job_shrt_nm, job_start_dttm, job_end_dttm, total_records, succeeded_count, failed_count, job_status]
  - **IX_JobExecutionLog_ByFlow** (NONCLUSTERED): job_sqnc_id, execution_date [includes: job_shrt_nm, job_status, execution_time_seconds]
  - **IX_JobExecutionLog_ByJob** (NONCLUSTERED): job_id, execution_date [includes: job_status, execution_time_seconds, total_records, succeeded_count, failed_count]
  - **IX_JobExecutionLog_ByJobName** (NONCLUSTERED): job_shrt_nm, execution_date
  - **IX_JobExecutionLog_Failures** (NONCLUSTERED): job_status, execution_date
  - **IX_JobExecutionLog_JobLogId** (NONCLUSTERED): job_log_id
  - **IX_JobExecutionLog_Tracking** (NONCLUSTERED): tracking_id, execution_order_nmbr
  - **UQ_JobExecutionLog_job_log_id** (NONCLUSTERED): job_log_id

**Check Constraints:**

  - **CK_JobExecutionLog_Counts**: `([total_records] IS NULL OR [total_records]>=(0) AND [succeeded_count]>=(0) AND [failed_count]>=(0))`
  - **CK_JobExecutionLog_Status**: `([job_status]='UNKNOWN' OR [job_status]='PARTIAL' OR [job_status]='COMPLETED' OR [job_status]='FAILED' OR [job_status]='CANCELLING' OR [job_status]='CANCELLED' OR [job_status]='PENDING' OR [job_status]='EXECUTING')`
  - **CK_JobExecutionLog_Type**: `([execution_type]='AD_HOC' OR [execution_type]='SCHEDULED')`

**Foreign Keys:**

  - **FK_JobExecutionLog_FlowExecutionTracking**: tracking_id -> JobFlow.FlowExecutionTracking.tracking_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| job_status | COMPLETED | Job completed successfully. All records processed or DM status 3 with no failures. | 1 |
| job_status | PARTIAL | Job processed some records but some failed business validation. DM status 2 or 3 with both succeeded and failed counts. | 2 |
| job_status | FAILED | True technical failure — DM status 2 with zero records successfully processed. | 3 |
| job_status | CANCELLED | Job cancelled by user. DM status 4. | 4 |
| job_status | EXECUTING | Job still running. DM status 1. Should not appear in completed job log under normal operation. | 5 |
| job_status | PENDING | Job queued, waiting to start. DM status 6. | 6 |
| job_status | UNKNOWN | Unmapped DM status code. Indicates a new status not yet added to translation logic. | 7 |

**Jobs Completed Today** [sort:1] -- All job completions for today with status, record counts, and duration.

```sql
SELECT 
    job_shrt_nm,
    job_sqnc_shrt_nm AS flow_code,
    job_status,
    total_records,
    succeeded_count,
    failed_count,
    execution_time_seconds
FROM JobFlow.JobExecutionLog
WHERE execution_date = CAST(GETDATE() AS DATE)
ORDER BY captured_dttm DESC;
```

**Failed Jobs in Date Range** [sort:2] -- Shows jobs with FAILED or PARTIAL status over the past 7 days with error messages for troubleshooting.

```sql
SELECT 
    execution_date,
    job_shrt_nm,
    job_sqnc_shrt_nm AS flow_code,
    job_status,
    error_message
FROM JobFlow.JobExecutionLog
WHERE job_status IN ('FAILED', 'PARTIAL')
  AND execution_date >= DATEADD(DAY, -7, GETDATE())
ORDER BY execution_date DESC, captured_dttm DESC;
```

**Job Execution Trends** [sort:3] -- Aggregated performance metrics per job over the past 30 days — execution count, average duration, throughput, and total records processed.

```sql
SELECT 
    job_shrt_nm,
    COUNT(*) AS execution_count,
    AVG(execution_time_seconds) AS avg_duration_sec,
    AVG(records_per_second) AS avg_throughput,
    SUM(succeeded_count) AS total_records_processed
FROM JobFlow.JobExecutionLog
WHERE execution_date >= DATEADD(DAY, -30, GETDATE())
GROUP BY job_shrt_nm
ORDER BY execution_count DESC;
```

  - **Child of FlowExecutionTracking**: [sort:1] JobExecutionLog.tracking_id references FlowExecutionTracking.tracking_id. NULL or 0 tracking_id indicates backfilled or orphaned records not captured by real-time monitoring.
  - **Source: crs5_oltp.dbo.job_log**: [sort:2] The job_log_id column links to crs5_oltp.dbo.job_log. Record counts come from job_entty_log aggregation. IX_JobExecutionLog_JobLogId supports NOT EXISTS deduplication during capture.


### JobStatus

Reference table mapping Debt Manager job status codes to human-readable descriptions and xFACts-effective status interpretations.

**Reference Lookup Table:** [sort:1] Static reference table with 6 rows — one per DM job_stts_cd value (1-6). The xfacts_effective_status column provides the xFACts interpretation which can differ from DM. For example, DM status 2 (Failed) maps to either PARTIAL or FAILED in xFACts depending on whether any records processed successfully. The is_terminal flag indicates final vs in-progress states.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| job_stts_cd | tinyint | No | — | Primary key. DM status code (1-6) |
| job_stts_val_txt | varchar(20) | No | — | Short status name from DM (e.g., 'Started', 'Failed') |
| job_stts_dscrptn_txt | varchar(100) | No | — | Full description of what this status means |
| xfacts_effective_status | varchar(20) | Yes | — | xFACts interpretation: COMPLETED, PARTIAL, FAILED, CANCELLED, EXECUTING, PENDING |
| is_terminal | bit | No | 0 | 1 if this is a final state, 0 if job is still in progress |

  - **PK_JobStatus** (CLUSTERED): job_stts_cd -- PRIMARY KEY


### Schedule

Expected execution schedules for job flows, used by missing flow detection to identify when flows should have started.

**Multiple Schedules Per Flow:** [sort:1] A flow can have multiple schedule rows. For example, a flow might run at 10 PM on weekdays and 8 AM on weekends. Each schedule row has its own tolerance window, active flag, and alert setting. The Schedule table supports DAILY, WEEKDAYS, WEEKLY, MONTHLY, and EVERY_N_HOURS schedule types.

**Tolerance Window:** [sort:2] start_time_tolerance_minutes provides buffer after the expected start time before a missing flow alert fires. Default is 60 minutes. Critical nightly flows might use 60 min, hourly flows 15 min. The detection logic evaluates: current time > expected_start_time + tolerance AND no execution exists for today.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| schedule_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this schedule row |
| job_sqnc_id | bigint | No | — | Flow ID from Config table |
| job_sqnc_shrt_nm | varchar(50) | No | — | Flow short name. Denormalized for convenience |
| schedule_type | varchar(50) | No | — | Type: DAILY, WEEKDAYS, WEEKLY, MONTHLY, EVERY_N_HOURS |
| schedule_frequency | int | Yes | — | For EVERY_N_HOURS: interval in hours |
| schedule_day_of_week | int | Yes | — | For WEEKLY: 1=Sunday through 7=Saturday |
| schedule_day_of_month | int | Yes | — | For MONTHLY: day of month (1-31) |
| schedule_week_of_month | int | Yes | — | For MONTHLY: week of month (1-5) |
| expected_start_time | time | No | — | Time of day the flow should start |
| start_time_tolerance_minutes | int | No | 60 | Minutes after expected time before alerting |
| is_active | bit | No | 1 | Whether this schedule is currently active |
| alert_on_missing | bit | No | 1 | Whether to alert if flow misses this schedule |
| effective_start_date | date | No | CONVERT([date],getdate()) | When this schedule becomes active |
| effective_end_date | date | Yes | — | When this schedule expires. NULL = no expiration |
| created_dttm | datetime | No | getdate() | When this row was created |
| created_by | varchar(100) | No | suser_sname() | Who created this row |
| modified_dttm | datetime | Yes | — | Last modification timestamp |
| modified_by | varchar(100) | Yes | — | Who last modified this row |
| notes | varchar(1000) | Yes | — | Free-form notes about this schedule |

  - **PK_Schedule** (CLUSTERED): schedule_id -- PRIMARY KEY
  - **IX_Schedule_Active** (NONCLUSTERED): is_active, schedule_type, expected_start_time
  - **IX_Schedule_Daily** (NONCLUSTERED): expected_start_time, start_time_tolerance_minutes
  - **UQ_Schedule_FlowEffDates** (NONCLUSTERED): job_sqnc_id, effective_start_date, effective_end_date

**Check Constraints:**

  - **CK_Schedule_DayOfMonth**: `([schedule_day_of_month] IS NULL OR [schedule_day_of_month]>=(1) AND [schedule_day_of_month]<=(31))`
  - **CK_Schedule_DayOfWeek**: `([schedule_day_of_week] IS NULL OR [schedule_day_of_week]>=(1) AND [schedule_day_of_week]<=(7))`
  - **CK_Schedule_EffDates**: `([effective_end_date] IS NULL OR [effective_end_date]>=[effective_start_date])`
  - **CK_Schedule_Tolerance**: `([start_time_tolerance_minutes]>=(0))`
  - **CK_Schedule_Type**: `([schedule_type]='CUSTOM' OR [schedule_type]='MONTHLY' OR [schedule_type]='EVERY_N_HOURS' OR [schedule_type]='WEEKLY' OR [schedule_type]='DAILY')`
  - **CK_Schedule_WeekOfMonth**: `([schedule_week_of_month] IS NULL OR [schedule_week_of_month]>=(1) AND [schedule_week_of_month]<=(5))`

**Foreign Keys:**

  - **FK_Schedule_FlowConfig**: job_sqnc_id -> JobFlow.FlowConfig.job_sqnc_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| schedule_type | DAILY | Runs every day at expected_start_time. | 1 |
| schedule_type | WEEKDAYS | Runs Monday through Friday at expected_start_time. | 2 |
| schedule_type | WEEKLY | Runs on schedule_day_of_week at expected_start_time. | 3 |
| schedule_type | MONTHLY | Runs on schedule_day_of_month at expected_start_time. | 4 |
| schedule_type | EVERY_N_HOURS | Runs every schedule_frequency hours starting at expected_start_time. | 5 |
| schedule_type | CUSTOM | Non-standard schedule requiring manual evaluation. | 6 |

**Active Schedules with Deadlines** [sort:1] -- All active schedules configured for missing flow alerts, with calculated deadline times.

```sql
SELECT 
    job_sqnc_shrt_nm AS flow_code,
    schedule_type,
    expected_start_time,
    start_time_tolerance_minutes,
    DATEADD(MINUTE, start_time_tolerance_minutes, 
            CAST(expected_start_time AS DATETIME)) AS deadline_time
FROM JobFlow.Schedule
WHERE is_active = 1
  AND alert_on_missing = 1
ORDER BY expected_start_time;
```

**Today's Expected Flows** [sort:2] -- Evaluates schedule types and day-of-week rules to show which flows should execute today.

```sql
DECLARE @today_dow INT = DATEPART(WEEKDAY, GETDATE());

SELECT 
    job_sqnc_shrt_nm AS flow_code,
    schedule_type,
    expected_start_time
FROM JobFlow.Schedule
WHERE is_active = 1
  AND (
      schedule_type = 'DAILY'
      OR (schedule_type = 'WEEKDAYS' AND @today_dow BETWEEN 2 AND 6)
      OR (schedule_type = 'WEEKLY' AND schedule_day_of_week = @today_dow)
      OR (schedule_type = 'MONTHLY' AND schedule_day_of_month = DAY(GETDATE()))
      OR schedule_type = 'EVERY_N_HOURS'
  )
ORDER BY expected_start_time;
```

**Flows Past Deadline** [sort:3] -- Identifies flows that should have started by now but have no execution recorded today — the same logic Step-DetectMissingFlows uses.

```sql
SELECT 
    s.job_sqnc_shrt_nm,
    s.expected_start_time,
    s.start_time_tolerance_minutes,
    DATEADD(MINUTE, s.start_time_tolerance_minutes, 
            CAST(CAST(GETDATE() AS DATE) AS DATETIME) + CAST(s.expected_start_time AS DATETIME)) AS deadline
FROM JobFlow.Schedule s
WHERE s.is_active = 1
  AND GETDATE() > DATEADD(MINUTE, s.start_time_tolerance_minutes, 
            CAST(CAST(GETDATE() AS DATE) AS DATETIME) + CAST(s.expected_start_time AS DATETIME))
  AND NOT EXISTS (
      SELECT 1 FROM JobFlow.FlowExecutionTracking t
      WHERE t.job_sqnc_id = s.job_sqnc_id
        AND t.execution_date = CAST(GETDATE() AS DATE)
  );
```

  - **Child of FlowConfig**: [sort:1] Schedule.job_sqnc_id references FlowConfig.job_sqnc_id. Multiple schedule rows per flow are supported. Only active schedules (is_active = 1) with alert_on_missing = 1 trigger missing flow detection.


### StallDetectionLog

Append-only audit log capturing stall detection events with diagnostic XML snapshots for troubleshooting and historical analysis.

**Append-Only Audit Trail:** [sort:1] Rows are never updated or deleted. Events are only logged when the counter changes (INCREMENT, RESET, ALERT, STALLED), not on every poll. This keeps the table manageable while capturing all meaningful stall detection activity. Normal nights produce 0-2 rows. Actual stall events produce 7+ rows.

**Deduplication Source (v1.8.0+):** [sort:2] Stall alerts are suppressed if an ALERT event exists today with no subsequent RESET. This allows multiple alerts per day when a stall-recovery-stall cycle occurs — a second stall after recovery generates a fresh ticket. Replaces the previous stall_alert_sent_dttm approach.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| log_id (IDENTITY) | int | No | IDENTITY | Unique identifier for each log entry |
| task_id | bigint | Yes | — | Links to Orchestrator_ExecutionDetail for the poll that generated this event |
| poll_dttm | datetime | No | — | When the poll occurred |
| counter_before | int | No | — | no_progress_poll_count value before this event |
| counter_after | int | No | — | no_progress_poll_count value after this event |
| stall_threshold | int | No | — | Configured threshold at time of event (typically 6) |
| threshold_reached | bit | No | — | 1 if counter_after >= stall_threshold |
| event_type | varchar(10) | No | — | Event classification: INCREMENT, ALERT, STALLED, RESET |
| snapshot_comparison_xml | xml | No | — | Full snapshot data including job lists, cross-poll comparison, and progress indicators |
| jira_queued | bit | Yes | — | 1 if a Jira ticket was queued for this event |
| teams_queued | bit | Yes | — | 1 if a Teams alert was queued for this event |
| created_dttm | datetime | No | getdate() | When this log entry was created |

  - **PK_StallDetectionLog** (CLUSTERED): log_id -- PRIMARY KEY
  - **IX_StallDetectionLog_EventType** (NONCLUSTERED): event_type
  - **IX_StallDetectionLog_PollDttm** (NONCLUSTERED): poll_dttm
  - **IX_StallDetectionLog_TaskId** (NONCLUSTERED): task_id

**Check Constraints:**

  - **CK_StallDetectionLog_EventType**: `([event_type]='RESET' OR [event_type]='STALLED' OR [event_type]='ALERT' OR [event_type]='INCREMENT')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| event_type | INCREMENT | No progress detected. Counter increased by 1. Building toward threshold. | 1 |
| event_type | ALERT | Counter reached threshold (default: 6). Stall confirmed. Jira ticket and Teams alert queued. | 2 |
| event_type | STALLED | Continuing stall after ALERT. Counter still incrementing. No additional alerts. | 3 |
| event_type | RESET | Progress detected. Counter reset to 0. Stall episode ended. | 4 |

**Today's Stall Events** [sort:1] -- All stall detection events for today — shows the counter progression and whether alerts were fired.

```sql
SELECT 
    poll_dttm,
    event_type,
    counter_before,
    counter_after,
    jira_queued,
    teams_queued
FROM JobFlow.StallDetectionLog
WHERE CAST(poll_dttm AS DATE) = CAST(GETDATE() AS DATE)
ORDER BY poll_dttm;
```

**Recent ALERT Events** [sort:2] -- Shows actual stall alerts fired in the past 7 days with diagnostic snapshot XML for investigation.

```sql
SELECT 
    poll_dttm,
    counter_before,
    counter_after,
    jira_queued,
    teams_queued,
    snapshot_comparison_xml
FROM JobFlow.StallDetectionLog
WHERE event_type = 'ALERT'
  AND poll_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY poll_dttm DESC;
```

**Check Active Stall Status** [sort:3] -- Determines whether there is an active stall right now (ALERT fired today with no subsequent RESET) — matches the deduplication logic in Monitor-JobFlow.

```sql
SELECT 
    CASE 
        WHEN EXISTS (
            SELECT 1 FROM JobFlow.StallDetectionLog sdl
            WHERE CAST(sdl.poll_dttm AS DATE) = CAST(GETDATE() AS DATE)
              AND sdl.event_type = 'ALERT'
              AND NOT EXISTS (
                  SELECT 1 FROM JobFlow.StallDetectionLog r
                  WHERE r.poll_dttm > sdl.poll_dttm
                    AND r.event_type = 'RESET'
              )
        )
        THEN 'Active stall - alerts suppressed'
        ELSE 'No active stall - new alert would fire'
    END AS stall_status;
```

**Extract Jobs from XML Snapshot** [sort:4] -- Shreds the diagnostic XML to show individual jobs that were executing/pending during a stall event. Replace @log_id with the target log entry.

```sql
SELECT 
    log_id,
    poll_dttm,
    event_type,
    j.value('@id', 'INT') AS job_log_id,
    j.value('@status', 'INT') AS job_status,
    j.value('@count', 'INT') AS processed_count
FROM JobFlow.StallDetectionLog
CROSS APPLY snapshot_comparison_xml.nodes('//Snapshot1/Job') AS t(j)
WHERE log_id = @log_id;
```

  - **Links to Orchestrator execution**: [sort:1] The detail_id column links to the Orchestrator execution detail for the monitoring cycle that detected the stall event. Enables correlation with orchestrator timing and other module activity during the same cycle.


### Status

Tracks execution state and health metrics for each step of the Monitor-JobFlow.ps1 script, including stall detection snapshots.

**Data Flow:** At step start: UPDATE started_dttm. At step end: UPDATE completed_dttm, last_status (SUCCESS/FAILED), last_result_count, last_error_message. DetectStalls additionally updates stall_snapshot_xml and stall_no_progress_count.

**Fixed Row Set:** [sort:1] The table contains exactly 8 rows corresponding to the processing steps in Monitor-JobFlow.ps1: ConfigSync (0), DetectFlows (1), CaptureJobs (2), UpdateProgress (3), TransitionStates (4), DetectStalls (5), ValidateFlows (6), DetectMissing (7). Rows are never inserted or deleted during normal operation — only updated.

**Stall State Storage:** [sort:2] The DetectStalls row stores stall_snapshot_xml (XML snapshot of executing/pending job_log_ids) and stall_no_progress_count (consecutive polls with no change). This state persists between Monitor-JobFlow.ps1 invocations, enabling cross-poll comparison without additional tables.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| status_id (IDENTITY) | int | No | IDENTITY | Unique identifier for each status row |
| process_name | varchar(50) | No | — | Step name: ConfigSync, DetectFlows, CaptureJobs, UpdateProgress, TransitionStates, DetectStalls, ValidateFlows, DetectMissing |
| started_dttm | datetime | Yes | — | When the step began execution |
| completed_dttm | datetime | Yes | — | When the step finished execution |
| last_status | varchar(20) | Yes | — | Result of last execution: SUCCESS or FAILED |
| last_result_count | int | Yes | — | Number of items processed (flows detected, jobs captured, etc.) |
| last_error_message | varchar(500) | Yes | — | Error details if last_status = FAILED |
| stall_no_progress_count | int | Yes | — | Counter of consecutive polls with no progress. Resets to 0 when progress detected |
| stall_last_progress_dttm | datetime | Yes | — | When meaningful progress was last detected during stall evaluation. Updated each poll cycle when the executing job snapshot differs from the previous cycle. Used with stall_no_progress_count to determine whether a flow has stalled. |
| stall_snapshot_xml | xml | Yes | — | XML snapshot of current executing/pending job_log_ids for comparison |
| created_dttm | datetime | No | getdate() | When the row was created |

  - **PK_Status** (CLUSTERED): status_id -- PRIMARY KEY
  - **UQ_JobFlow_Status_ProcessName** (NONCLUSTERED): process_name

**Check Constraints:**

  - **CK_Status_LastStatus**: `([last_status]='FAILED' OR [last_status]='PARTIAL' OR [last_status]='SUCCESS' OR [last_status]='IN_PROGRESS')`

**Current Step Status** [sort:1] -- Dashboard view of all eight processing steps — last status, result count, and minutes since last run.

```sql
SELECT 
    process_name,
    last_status,
    last_result_count,
    completed_dttm,
    DATEDIFF(MINUTE, completed_dttm, GETDATE()) AS minutes_ago
FROM JobFlow.Status
ORDER BY status_id;
```

**Recent Step Failures** [sort:2] -- Shows any processing steps that failed in the past 24 hours with error details.

```sql
SELECT 
    process_name,
    last_status,
    last_error_message,
    completed_dttm
FROM JobFlow.Status
WHERE last_status = 'FAILED'
  AND completed_dttm >= DATEADD(HOUR, -24, GETDATE());
```

**Stall Detection State** [sort:3] -- Quick check of the current stall counter and snapshot without digging into StallDetectionLog.

```sql
SELECT 
    stall_no_progress_count,
    stall_snapshot_xml,
    completed_dttm AS last_check
FROM JobFlow.Status
WHERE process_name = 'DetectStalls';
```

**Verify Script Is Running** [sort:4] -- Health check — if DetectFlows completed more than 10 minutes ago, Monitor-JobFlow may not be running.

```sql
SELECT 
    process_name,
    completed_dttm,
    DATEDIFF(MINUTE, completed_dttm, GETDATE()) AS minutes_since_last_run
FROM JobFlow.Status
WHERE process_name = 'DetectFlows'
  AND DATEDIFF(MINUTE, completed_dttm, GETDATE()) > 10;
```


### ValidationException

Detailed exception records for individual job-level issues found during flow execution validation, including missing jobs, failed jobs, and order discrepancies.

**Normalized Exception Detail:** [sort:1] Each exception is a separate row, enabling flexible querying and aggregation across flows and exception types. The is_critical flag is set based on JobConfig.is_critical for the referenced job_id. The job_exctn_msg_txt field preserves DM error messages sanitized of PII.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| exception_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for this exception record |
| validation_id | bigint | No | — | Links to parent ValidationLog record |
| job_id | bigint | No | — | Job definition ID from crs5_oltp.dbo.job |
| job_shrt_nm | varchar(50) | No | — | Job short name |
| job_nm | varchar(255) | Yes | — | Full job name |
| exception_type | varchar(50) | No | — | Type: MISSING, FAILED, UNEXPECTED, ORDER_MISMATCH, DUPLICATE |
| is_critical | bit | No | 0 | 1 if this job is marked critical in JobConfig |
| expected_order_nmbr | int | Yes | — | Expected position in flow execution order |
| actual_order_nmbr | int | Yes | — | Actual position if job executed |
| job_stts_cd | int | Yes | — | DM status code if job executed |
| job_exctn_msg_txt | varchar(MAX) | Yes | — | Error message from DM (sanitized of PII) |
| created_dttm | datetime | No | getdate() | When this exception was recorded |
| notes | varchar(1000) | Yes | — | Additional context or investigation notes |

  - **PK_ValidationException** (CLUSTERED): exception_id -- PRIMARY KEY
  - **IX_ValidationException_ByJob** (NONCLUSTERED): job_id, exception_type, created_dttm [includes: is_critical, job_shrt_nm]
  - **IX_ValidationException_ByValidation** (NONCLUSTERED): validation_id, exception_type [includes: job_shrt_nm, is_critical]
  - **IX_ValidationException_Critical** (NONCLUSTERED): is_critical, exception_type, created_dttm

**Check Constraints:**

  - **CK_ValidationException_Type**: `([exception_type]='UNKNOWN' OR [exception_type]='BUSINESS_REJECTION' OR [exception_type]='SYSTEM_FAILURE' OR [exception_type]='STUCK_JOB' OR [exception_type]='UNEXPECTED_JOB' OR [exception_type]='FAILED_JOB' OR [exception_type]='MISSING_JOB')`

**Foreign Keys:**

  - **FK_ValidationException_ValidationLog**: validation_id -> JobFlow.ValidationLog.validation_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| exception_type | MISSING_JOB | Job was expected from flow definition but did not execute. | 1 |
| exception_type | FAILED_JOB | Job executed but failed with zero records processed (true technical failure). | 2 |
| exception_type | UNEXPECTED_JOB | Job executed but was not in the expected job list from flow definition. | 3 |

**Recent Exceptions** [sort:1] -- All validation exceptions from the past 7 days with flow context from ValidationLog.

```sql
SELECT 
    vl.job_sqnc_shrt_nm AS flow_code,
    vl.execution_date,
    ve.exception_type,
    ve.job_shrt_nm,
    ve.is_critical,
    ve.job_exctn_msg_txt
FROM JobFlow.ValidationException ve
INNER JOIN JobFlow.ValidationLog vl ON vl.validation_id = ve.validation_id
WHERE ve.created_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY ve.created_dttm DESC;
```

**Critical Exceptions Only** [sort:2] -- Filtered view showing only exceptions on critical jobs — the ones that generate high-priority alerts.

```sql
SELECT 
    vl.job_sqnc_shrt_nm AS flow_code,
    vl.execution_date,
    ve.exception_type,
    ve.job_shrt_nm,
    ve.job_exctn_msg_txt
FROM JobFlow.ValidationException ve
INNER JOIN JobFlow.ValidationLog vl ON vl.validation_id = ve.validation_id
WHERE ve.is_critical = 1
ORDER BY ve.created_dttm DESC;
```

**Exception Counts by Type** [sort:3] -- Aggregated exception counts over the past 30 days by type — shows which categories of issues are most common.

```sql
SELECT 
    exception_type,
    COUNT(*) AS exception_count,
    SUM(CAST(is_critical AS INT)) AS critical_count
FROM JobFlow.ValidationException
WHERE created_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY exception_type
ORDER BY exception_count DESC;
```

**Frequently Failing Jobs** [sort:4] -- Identifies jobs with repeated FAILED exceptions over the past 30 days — pattern detection for recurring issues.

```sql
SELECT 
    job_shrt_nm,
    COUNT(*) AS failure_count,
    MAX(created_dttm) AS last_failure
FROM JobFlow.ValidationException
WHERE exception_type = 'FAILED'
  AND created_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY job_shrt_nm
ORDER BY failure_count DESC;
```

  - **Child of ValidationLog**: [sort:1] ValidationException.validation_id references ValidationLog.validation_id. Many exceptions per validation — one per discrepant job.


### ValidationLog

Post-execution validation results capturing job count verification, missing job detection, and Jira ticket references for completed flow executions.

**Post-Completion Validation:** [sort:1] Validation only runs after a flow reaches COMPLETE state (executing_job_count = 0, pending_job_count = 0). It compares expected_jobs_json from FlowExecutionTracking against actual job outcomes in JobExecutionLog. Missing, unexpected, and failed jobs are counted and classified. The flow then transitions to VALIDATED.

**Jira Integration:** [sort:2] When validation detects critical failures (critical_jobs_missing = 1 or critical_jobs_failed = 1), a Jira ticket is created. The ticket key and URL are stored in jira_ticket_key and jira_ticket_url for cross-reference.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| validation_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for this validation record |
| tracking_id | bigint | No | — | Links to FlowExecutionTracking for the validated execution |
| job_sqnc_id | bigint | No | — | Flow ID for direct queries without join |
| job_sqnc_shrt_nm | varchar(50) | No | — | Flow short name. Denormalized |
| execution_date | date | No | — | Date of the execution being validated |
| validation_dttm | datetime | No | getdate() | When validation was performed |
| validation_status | varchar(50) | No | — | Overall result: PASSED, FAILED, WARNING, PARTIAL |
| expected_job_count | int | No | — | Number of jobs expected from flow definition |
| actual_job_count | int | No | — | Number of jobs that actually executed |
| missing_job_count | int | No | 0 | Jobs expected but not executed |
| unexpected_job_count | int | No | 0 | Jobs executed but not in expected list |
| failed_job_count | int | No | 0 | Jobs that executed but failed |
| critical_jobs_missing | bit | No | 0 | 1 if any missing jobs are marked is_critical in JobConfig |
| critical_jobs_failed | bit | No | 0 | 1 if any failed jobs are marked is_critical in JobConfig |
| missing_jobs_json | nvarchar(MAX) | Yes | — | JSON array of missing job details |
| failed_jobs_json | nvarchar(MAX) | Yes | — | JSON array of failed job details with error messages |
| jira_ticket_key | varchar(50) | Yes | — | Ticket key if validation failure generated a ticket (e.g., SD-12345) |
| jira_ticket_url | varchar(500) | Yes | — | Full URL to the Jira ticket |
| jira_ticket_created_dttm | datetime | Yes | — | When the Jira ticket was created |
| created_dttm | datetime | No | getdate() | When this validation record was created |

  - **PK_ValidationLog** (CLUSTERED): validation_id -- PRIMARY KEY
  - **IX_ValidationLog_ByFlow** (NONCLUSTERED): job_sqnc_id, execution_date [includes: validation_status, missing_job_count, failed_job_count]
  - **IX_ValidationLog_Critical** (NONCLUSTERED): validation_dttm [includes: critical_jobs_missing, critical_jobs_failed, job_sqnc_shrt_nm, validation_status]
  - **IX_ValidationLog_Failures** (NONCLUSTERED): validation_status, validation_dttm
  - **IX_ValidationLog_Jira** (NONCLUSTERED): jira_ticket_key

**Check Constraints:**

  - **CK_ValidationLog_Counts**: `([expected_job_count]>=(0) AND [actual_job_count]>=(0) AND [missing_job_count]>=(0) AND [unexpected_job_count]>=(0) AND [failed_job_count]>=(0))`
  - **CK_ValidationLog_Status**: `([validation_status]='FLOW_NOT_RUN' OR [validation_status]='BUSINESS_REJECTION' OR [validation_status]='PARTIAL_FAILURE' OR [validation_status]='CRITICAL_FAILURE' OR [validation_status]='SYSTEM_FAILURE' OR [validation_status]='MISSING_JOBS' OR [validation_status]='SUCCESS')`

**Foreign Keys:**

  - **FK_ValidationLog_FlowExecutionTracking**: tracking_id -> JobFlow.FlowExecutionTracking.tracking_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| validation_status | SUCCESS | All expected jobs executed successfully. No discrepancies found. | 1 |
| validation_status | MISSING_JOBS | Expected jobs did not execute. May indicate cancelled flow or dependency failure. | 2 |
| validation_status | FLOW_NOT_RUN | Flow was detected but no jobs executed. | 3 |
| validation_status | PARTIAL_FAILURE | Some jobs had alertable failures but non-critical. | 4 |
| validation_status | CRITICAL_FAILURE | Critical jobs failed or were missing. Jira ticket generated. | 5 |

**Recent Validation Results** [sort:1] -- Validation outcomes for the past 7 days with job count comparisons and Jira ticket references.

```sql
SELECT 
    job_sqnc_shrt_nm AS flow_code,
    execution_date,
    validation_status,
    expected_job_count,
    actual_job_count,
    missing_job_count,
    failed_job_count,
    jira_ticket_key
FROM JobFlow.ValidationLog
WHERE validation_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY validation_dttm DESC;
```

**Failed Validations** [sort:2] -- Shows validations with FAILED or PARTIAL status including critical job flags and detail JSON for investigation.

```sql
SELECT 
    job_sqnc_shrt_nm,
    execution_date,
    validation_status,
    critical_jobs_missing,
    critical_jobs_failed,
    missing_jobs_json,
    failed_jobs_json
FROM JobFlow.ValidationLog
WHERE validation_status IN ('FAILED', 'PARTIAL')
ORDER BY validation_dttm DESC;
```

  - **Child of FlowExecutionTracking**: [sort:1] ValidationLog.tracking_id references FlowExecutionTracking.tracking_id. One validation per completed execution.
  - **Parent of ValidationException**: [sort:2] ValidationException.validation_id references ValidationLog.validation_id. One summary row can have many exception detail rows.


### Monitor-JobFlow.ps1

Core monitoring engine for Debt Manager job flows. Detects new flow executions, captures job completions, manages flow state transitions, detects system stalls, validates completed flows, and identifies missing scheduled flows. Runs every 5 minutes via the Orchestrator.

**Data Flow:** Reads: job_sqnc_log (flow executions), job_sqnc (flow definitions for ConfigSync), job_sqnc_exctn_log (flow-to-job linkage), job_log (job executions), job_entty_log (record-level results), job (job definitions), usr (user identification). All reads via AG secondary replica by default.

**Eight-Step Processing Pipeline:** [sort:1] Step 0: ConfigSync — synchronize FlowConfig with DM. Step 1: DetectFlows — find new executions. Step 2: CaptureJobs — record completed jobs. Step 3: UpdateProgress — update flow job counts. Step 4: TransitionStates — manage state machine. Step 5: DetectStalls — snapshot comparison. Step 6: ValidateFlows — analyze completed flows. Step 7: DetectMissing — check for no-show flows. Each step updates its own row in JobFlow.Status. Not all steps run on every cycle — see the Early Exit design note.

**AG-Aware Architecture:** [sort:2] Automatically detects AG replica roles at startup via the listener. Uses GlobalConfig SourceReplica setting to select read server (PRIMARY or SECONDARY). Always writes to the xFACts listener. ForceSourceServer parameter can override for testing. If replica is unavailable, the script logs the failure and exits — retried on next orchestrator cycle.

**Preview Mode:** [sort:3] Without the -Execute switch, the script runs in preview mode — reads all source data, evaluates all conditions, and displays what would happen without making any changes. Essential for testing and troubleshooting. The -Execute switch must be present for any writes to occur.

**Early Exit on No Job Activity:** [sort:4] After ConfigSync, the script queries crs5_oltp.dbo.job_log for jobs in status 1 (Started) or 6 (Pending). If none are found, Steps 1 through 6 are skipped and only Step 7 (DetectMissing) runs before exit. This eliminates the heavy join against dbo.job_entty_log in Step 2 — a table with hundreds of millions of rows that generated significant read load on the DM secondary replica on every cycle regardless of whether any flows were executing. ConfigSync always runs because flow definition drift is independent of job activity. DetectMissing always runs because it specifically targets flows that have not started — gating it on job activity would prevent it from ever alerting.

  - **Orchestrator.ProcessRegistry**: [sort:1] Registered as module_name=JobFlow, process_name=Monitor-JobFlow, execution_mode=FIRE_AND_FORGET, interval_seconds=300. Reports completion via Complete-OrchestratorTask callback using TaskId and ProcessId parameters.
  - **Reads: FlowConfig, JobConfig, Schedule, ErrorCategory, JobStatus**: [sort:2] FlowConfig controls which flows are monitored and alert settings. JobConfig provides criticality flags for validation. Schedule defines expected execution windows. ErrorCategory classifies error patterns for alert decisions. JobStatus maps DM codes to xFACts statuses.
  - **GlobalConfig settings**: [sort:3] Reads dbo.GlobalConfig for: AGName (AG identification), SourceReplica (which replica to read from), StallThreshold (polls before stall alert, default 6).



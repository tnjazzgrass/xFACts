# Replication Monitoring

*Because “is the data getting there?” shouldn’t require a PhD in distribution database archaeology*

SQL Server replication is the invisible plumbing that keeps data warehouses, reports, and downstream systems fed with current data. When it works, nobody notices. When it breaks, everyone notices. This module makes the invisible visible — continuously, automatically, and without requiring anyone to sit and stare at a monitor.






The Problem

Replication is one of those things that works beautifully until it doesn’t. And when it doesn’t, the first sign is usually someone asking why their numbers look wrong. Or a report showing yesterday’s data. Or an awkward silence in a meeting when someone says “according to the latest figures…”

The tools SQL Server provides for watching replication require you to be at your desk, actively looking at them, at the exact moment something goes wrong. That’s not monitoring. That’s hoping.






How It Works



Collector
Runs
→
Agent Health
Captured
→
Changes
Detected
→
Latency
Measured
→
Complete
Picture

One script, three monitoring layers, every 60 seconds


One script runs on a configurable schedule via the Orchestrator and captures everything in a single pass. No coordination headaches, no timing gaps, no “well, the second script should have run by now…”

It checks three things every cycle. First: **are the replication agents alive and working?** An agent can claim to be “Running” while thousands of changes pile up behind it, so we also check how fast data is actually flowing and how much is waiting in line. Second: **did anything change since last time?** If an agent was running and now it’s not, that’s noteworthy. Third: **how long does it actually take for a change to get from point A to point B?** Every five minutes, a tiny test marker is sent through the entire pipeline and timed.

Think of it like monitoring a highway. Agent health tells you if the road is open. The queue tells you how many cars are waiting. Speed tells you how fast traffic is moving. And the test marker tells you how long it actually takes to drive from one end to the other. Any single metric can be misleading. Together, they tell the whole story.






The Nightly Pause

Every night, the data warehouse build job needs a consistent snapshot of the data. To get that, it briefly stops the replication agents — like hitting pause on a conveyor belt so you can count what’s on it.

During this window, changes keep accumulating in the queue. When the agents start back up, everything drains through quickly. The monitoring system knows about this nightly routine and tags those agent stops as expected, so nobody gets a panicked alert at 1 AM about something that’s completely normal.






When Things Go Wrong

The value isn’t in watching replication work. It’s in catching the moment it stops working.

An agent that stops during the nightly build window? Expected. An agent that stops at noon with no explanation? That gets flagged. A queue that’s growing while the delivery speed drops to zero? Something is throttling the pipeline and it’s going to get worse before it gets better.

Every significant event is captured in an event log with timestamps, state transitions, and — when relevant — a note about what else was happening at the time. When someone asks “what happened to replication last Tuesday?” the answer is already there, waiting.






The Bottom Line

No more checking replication tools in SSMS. No more discovering at 9 AM that replication stopped at midnight. No more guessing whether a stopped agent is planned maintenance or an actual problem.

The data pipeline keeps doing its thing. We finally have a window into what that thing is.

---

# Replication Monitoring — Control Center Guide

---

## Architecture
# Replication Monitoring Architecture

The narrative page tells you *what* Replication Monitoring does and *why*. This page tells you *how*. One collector script runs four monitoring layers in a single pass: registry discovery, agent health snapshots, event detection, and tracer token latency measurement. All source data comes from the distribution database on DM-PROD-DB.



Schema Overview

The Replication component is compact and focused. Four tables, one script, no procedures, no triggers. The `PublicationRegistry` is the hub — every other table references it via FK. The three history tables are append-only stores capturing different dimensions of the same pipeline.



| Table | Role | Cardinality |
| --- | --- | --- |
| `Replication_PublicationRegistry` | Agent/publication catalog (hub) | One row per publication/subscriber/agent combination |
| `Replication_AgentHistory` | Health + queue + throughput snapshots | ~5,760 rows/day (4 agents × 60-sec cycles) |
| `Replication_EventLog` | State changes and errors | Change-driven — zero rows on quiet days |
| `Replication_LatencyHistory` | Tracer token latency measurements | ~864 rows/day (3 subscribers × 5-min intervals) |



No triggers, no stored procedures. Unlike Teams and Jira (which use triggers to signal the orchestrator), Replication runs on a standard 60-second schedule. The collector handles everything — discovery, snapshots, event detection, and tracer tokens — in a single script with conditional logic for the tracer token interval.







The Collection Cycle

`Collect-ReplicationHealth.ps1` runs on a configurable schedule via the orchestrator. All four monitoring layers execute in a single pass, in a deliberate order where each step depends on the results of the previous one.





Registry Sync
Discover agents from
distribution DB

→

Load Active
Filter to monitored,
non-dropped agents

→

Health Snapshot
Status + queue +
throughput per agent

→

Event Detection
Compare to previous
+ BIDATA correlation

→

Tracer Tokens
Post + measure
(every ~5 min)


Steps 1–4 run every cycle (~1 second). Step 5 runs every ~5 minutes and adds 15–45 seconds for token propagation.


| Step | Action | Target Table | Frequency |
| --- | --- | --- | --- |
| 1 | Registry Discovery | `Replication_PublicationRegistry` | Every cycle |
| 2 | Load Active Registry | *In-memory filter* | Every cycle |
| 3 | Agent Health + Queue + Throughput | `Replication_AgentHistory` | Every cycle |
| 4 | Event Detection | `Replication_EventLog` | Every cycle (change-driven) |
| 5 | Tracer Tokens | `Replication_LatencyHistory` | Every ~5 min (configurable) |



Two cycle profiles. Most cycles complete in under 1 second (Steps 1–4 only). Tracer token cycles take 15–45 seconds, dominated by the propagation wait time. The script checks `MAX(collected_dttm)` from `Replication_LatencyHistory` to decide whether to run Step 5.







Registry Discovery

Before monitoring can happen, the collector needs to know what to monitor. Rather than maintaining a manual list, it discovers this automatically each cycle by querying the distribution database.

Distribution Agent Discovery

The collector queries `distribution.dbo.MSdistribution_agents` joined with `MSsubscriber_info` (for registered subscriber names) and `MSpublications` (for publication metadata). Subscriber name resolution uses prefix matching against the agent name string because `subscriber_id` maps to linked server aliases in `master.sys.servers`, which can differ from the actual registered subscriber name.

Log Reader Discovery

Log Reader agents are discovered separately from `distribution.dbo.MSlogreader_agents`. They’re stored in the registry with `agent_type = 'LogReader'` and subscriber fields set to the publisher database name (the Log Reader has no subscriber — it reads the transaction log for all publications).

Sync Logic

| Scenario | Action |
| --- | --- |
| New agent not in registry | INSERT new row |
| Existing agent with changed metadata | UPDATE subscriber name, IDs, etc. |
| Previously dropped agent recreated | Reactivate: `is_dropped = 0`, clear `dropped_detected_dttm` |
| Agent in registry but not in distribution DB | Soft-delete: `is_dropped = 1`, set `dropped_detected_dttm` |



Soft delete preserves history. Dropping a registry row would orphan all FK references in AgentHistory, LatencyHistory, and EventLog. Soft-deleting with `is_dropped = 1` keeps historical data queryable. If the same publication is recreated later, the original row is reused rather than creating a duplicate.







Agent Health, Queue Depth & Throughput

For each active registry entry, the collector captures a combined snapshot every cycle. Three data sources feed one row in `Replication_AgentHistory`:

| Data | Source | What It Tells You |
| --- | --- | --- |
| Agent health (run_status, message) | `MSdistribution_history` / `MSlogreader_history` | Is the agent running? What’s it doing? |
| Queue depth (pending commands) | `sp_replmonitorsubscriptionpendingcmds` | How much work is waiting? |
| Throughput (delivery rate, cumulative counts) | `MSdistribution_history` / `MSlogreader_history` | How fast is data flowing? |


Why the System Procedure for Queue Depth

Queue depth comes from `sp_replmonitorsubscriptionpendingcmds` rather than aggregating `MSdistribution_status` directly. The system procedure returns instantly. The direct table join takes 90+ seconds on large distribution databases. Not a close call.

Log Reader: NULL Queue Depth

The Log Reader Agent reads the publisher’s transaction log and writes to the distribution database. Pending command count is a Distribution Agent concept — the Log Reader doesn’t deliver to subscribers. Queue depth columns are NULL for Log Reader entries by design.

The Stopped Detection Edge Case

SQL Server sometimes reports `run_status = 2` (Running) with a “The process was successfully stopped” agent message when an agent is stopped externally. The collector detects this pattern by checking both the status code and the message content, treating it as a Stopped state rather than Running.






Event Detection

Events are logged only when state changes. The collector compares each agent’s current `run_status` to the most recent `AgentHistory` snapshot from the previous cycle. If nothing changed, nothing is logged.

Event Types

| Event Type | Trigger | Description |
| --- | --- | --- |
| **STATE_CHANGE** | `run_status` changed | Generic transition event for any status change |
| **AGENT_START** | Transitioned to Running/Idle from Stopped/Failed | Agent began running (subset of STATE_CHANGE) |
| **AGENT_STOP** | Transitioned to Stopped, or “successfully stopped” message | Agent was stopped (subset of STATE_CHANGE) |
| **ERROR** | `error_id > 0` | Agent reported an error — can occur with or without state change |
| **RETRY** | Transitioned to Retrying | Agent hit an error and is attempting recovery |
| **INFO** | Collector discretion | Registry changes, configuration updates |


BIDATA Build Correlation

When an AGENT_STOP event is detected, the collector queries `BIDATA.BuildExecution` for an active or recently completed build. If one is found, `correlation_source` is set to `'BIDATA_BUILD'` — the stop was expected.

Events with `NULL` correlation are the interesting ones. An agent stop at noon with no known correlating process? That warrants investigation.

Errors Without State Change

ERROR events can be logged independently. If an agent reports `error_id > 0` but its `run_status` hasn’t changed, the error is still captured. This catches transient errors the agent recovers from without ever transitioning to Failed.


Cross-module dependency. The BIDATA build correlation is the only cross-module reference in the Replication component. It reads `BIDATA.BuildExecution` to determine if a build is active. This single JOIN eliminates the majority of false-positive agent stop alerts.







Tracer Tokens

Agent health tells you the machinery is running. Queue depth tells you work isn’t piling up. But neither tells you the most important thing: *how long does it actually take for a change to arrive at the subscriber?*

How They Work

Every 5 minutes, the collector posts a tracer token via `sp_posttracertoken` on the publisher database (`crs5_oltp`). A tiny marker is inserted into the transaction log. It flows through the entire replication pipeline — picked up by the Log Reader, written to the distribution database, delivered by the Distribution Agent, applied at the subscriber. Timestamps are recorded at each hop.

| Hop | Measurement | What Affects It |
| --- | --- | --- |
| Publisher → Distributor | `publisher_to_distributor_ms` | Log Reader Agent performance, transaction log size |
| Distributor → Subscriber | `distributor_to_subscriber_ms` | Distribution Agent throughput, network speed, subscriber load |


After waiting a configurable period (default 15 seconds), the collector retrieves results via `sp_helptracertokenhistory` and stores them in `Replication_LatencyHistory` — one row per subscriber. Tokens are cleaned up via `sp_deletetracertokenhistory` to prevent accumulation in the distribution database.

During Agent Downtime

Tracer tokens are posted regardless of agent state. When Distribution agents are stopped during the BIDATA build window, the Log Reader still picks up the token (`publisher_commit_dttm` and `distributor_commit_dttm` populate normally). But `subscriber_commit_dttm` stays NULL — the Distribution Agent isn’t running to deliver it. This is meaningful data: NULL confirms agents are stopped as expected.


Zero impact on the database. Tracer tokens are a single tiny transaction in the log. No user tables are touched. The replication pipeline doesn’t even notice them among the thousands of real transactions it’s already processing.







Current Landscape

Three publications, all transactional, all from `crs5_oltp` on DM-PROD-DB, plus one Log Reader agent feeding all three:

| Publication | Subscriber | Type | Purpose |
| --- | --- | --- | --- |
| Azure_BIDATA_Load | Azure SQL (fa-bidata) | Push | Independent Azure data warehouse build |
| BIDATA_Load_POC | DM-PROD-REP (FA-BI-DATA) | Pull | POC: testing BIDATA build off production secondary |
| BIDATALoad | DM-STAGE-DB (FA-BI-DATA) | Pull | Primary BIDATA data warehouse build |


The two pull subscriptions pause nightly during the BIDATA build (~1 AM – 5 AM). The Azure push runs continuously.


Log Reader is a single point of failure. One Log Reader Agent serves all three publications. If it stops, nothing gets fed to the distribution database, and all three subscribers go stale simultaneously. That’s why it gets its own entry in the monitoring registry and its own health snapshots every cycle.







Configuration

All thresholds and settings live in `dbo.GlobalConfig` under `module_name = 'ServerOps'`, `category = 'Replication'`. Everything is tunable without touching code.

| Setting | Default | What It Controls |
| --- | --- | --- |
| tracer_interval_minutes | 5 | How often tracer tokens are posted |
| tracer_wait_seconds | 15 | How long to wait for token results |
| queue_warning_threshold | 5,000 | Pending commands for warning |
| queue_critical_threshold | 50,000 | Pending commands for critical |
| latency_warning_ms | 30,000 | Latency warning (30 seconds) |
| latency_critical_ms | 120,000 | Latency critical (2 minutes) |
| alerting_enabled | 0 (off) | Master switch — off during baselining |



Alerting starts disabled on purpose. The monitor collects data from day one, but alerting waits until normal behavior has been baselined and thresholds tuned. You don’t want your first week of monitoring to be 47 false alarms about things that turn out to be perfectly normal.







How Everything Connects

Replication Monitoring is self-contained. One script reads from an external source (the distribution database on DM-PROD-DB), writes to four tables in the ServerOps schema, and crosses modules only once — to check BIDATA build status for event correlation.

Internal Flow

| From | To | Relationship |
| --- | --- | --- |
| `PublicationRegistry` | `AgentHistory` | FK parent — every snapshot references a registry entry |
| `PublicationRegistry` | `LatencyHistory` | FK parent — every latency measurement references a registry entry |
| `PublicationRegistry` | `EventLog` | FK parent — every event references a registry entry |
| `Collect-ReplicationHealth.ps1` | All four tables | Single script creates and updates all rows |


External Dependencies

| Dependency | Module | Purpose |
| --- | --- | --- |
| `Orchestrator.ProcessRegistry` | Orchestrator | Schedules collector (FIRE_AND_FORGET, 60-sec interval, group 10) |
| `dbo.GlobalConfig` | Shared Infrastructure | Tracer intervals, thresholds, alerting master switch |
| `BIDATA.BuildExecution` | BIDATA Monitoring | Correlation check for agent stop events |
| distribution database (DM-PROD-DB) | External | All source data: agent catalog, health, queue, tracer tokens |
| `crs5_oltp` (DM-PROD-DB) | External | Tracer token posting and result collection |

---

## Reference

### Replication_AgentHistory

Append-only periodic snapshots combining agent health status, queue depth, and throughput metrics for each monitored replication agent per collection cycle.

**Data Flow:** Append-only. Populated by Collect-ReplicationHealth.ps1 every 60 seconds. For each active registry entry, the collector queries MSdistribution_history (or MSlogreader_history for Log Reader agents) for the latest health/throughput snapshot, and calls sp_replmonitorsubscriptionpendingcmds for queue depth. One row inserted per agent per cycle. Also read internally by the collector for event detection — the previous cycle's snapshot is compared to the current state to detect state changes. Read by the Control Center Replication page for dashboards and trending.

**Combined Snapshot Design:** [sort:1] Agent health, queue depth, and throughput are collected in the same cycle and stored in the same row. This avoids join overhead for dashboard queries and ensures metrics are always time-aligned. One metric alone can mislead — an agent can report Running while 500,000 commands pile up. Three dimensions together tell the truth.

**Queue Depth via System Procedure:** [sort:2] Queue depth comes from sp_replmonitorsubscriptionpendingcmds rather than aggregating MSdistribution_status directly. The system procedure returns instantly while the direct table join takes 90+ seconds on large distribution databases.

**NULL Queue Depth for Log Reader:** [sort:3] The Log Reader Agent reads the publisher transaction log and writes to the distribution database. Pending command count is a Distribution Agent concept, so queue depth columns are NULL for LogReader entries. This is by design, not missing data.

**BIGINT Identity for Volume:** [sort:4] At one row per agent per 60-second cycle with 4 agents, this table accumulates approximately 5,760 rows per day (~172,800 per 30-day retention window). BIGINT identity accommodates long-term growth.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| agent_history_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for this snapshot row |
| publication_registry_id | int | No | — | FK to Replication_PublicationRegistry. Identifies which agent this snapshot is for |
| run_status | int | No | — | Agent run status code: 1=Started, 2=Running, 3=Idle, 4=Retrying, 5=Failed, 6=Stopped |
| agent_message | varchar(1000) | Yes | — | Agent comment at time of snapshot. Truncated from source nvarchar(max) to capture the meaningful portion |
| agent_action_dttm | datetime | Yes | — | When the agent last reported activity in the distribution database |
| error_id | int | Yes | — | Reference to MSrepl_errors in the distribution database. Zero or NULL indicates no error |
| pending_command_count | int | Yes | — | Number of commands waiting in the distribution database for delivery. NULL for Log Reader entries. Source: sp_replmonitorsubscriptionpendingcmds |
| estimated_processing_seconds | int | Yes | — | SQL Server's estimate of seconds needed to clear the pending queue. NULL for Log Reader entries. Source: sp_replmonitorsubscriptionpendingcmds |
| delivery_rate | float | Yes | — | Commands delivered per second. Source: MSdistribution_history.delivery_rate / MSlogreader_history.delivery_rate |
| delivered_transactions | int | Yes | — | Cumulative transactions delivered by this agent. Source: MSdistribution_history.delivered_transactions |
| delivered_commands | int | Yes | — | Cumulative commands delivered by this agent. Source: MSdistribution_history.delivered_commands |
| average_commands | int | Yes | — | Average commands per transaction. Source: MSdistribution_history.average_commands |
| delivery_latency | int | Yes | — | Delivery latency reported by the agent. Source: MSdistribution_history.delivery_latency |
| collected_dttm | datetime | No | getdate() | When this snapshot was captured by the collector |

  - **PK_Replication_AgentHistory** (CLUSTERED): agent_history_id -- PRIMARY KEY
  - **IX_Replication_AgentHistory_collected** (NONCLUSTERED): collected_dttm, publication_registry_id [includes: run_status, pending_command_count, delivery_rate]
  - **IX_Replication_AgentHistory_registry_collected** (NONCLUSTERED): publication_registry_id, collected_dttm [includes: run_status, pending_command_count, delivery_rate, delivered_commands]

**Check Constraints:**

  - **CK_Replication_AgentHistory_runstatus**: `([run_status]=(6) OR [run_status]=(5) OR [run_status]=(4) OR [run_status]=(3) OR [run_status]=(2) OR [run_status]=(1))`

**Foreign Keys:**

  - **FK_Replication_AgentHistory_PublicationRegistry**: publication_registry_id -> ServerOps.Replication_PublicationRegistry.publication_registry_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| run_status | 1 (Started) | Agent is initializing. | 1 |
| run_status | 2 (Running) | Agent is actively processing. Note: SQL Server sometimes reports run_status = 2 with a "successfully stopped" message when an agent is stopped externally. The collector detects this pattern. | 2 |
| run_status | 3 (Idle) | Agent is running but has no work to do. | 3 |
| run_status | 4 (Retrying) | Agent encountered an error and is retrying. | 4 |
| run_status | 5 (Failed) | Agent has stopped due to an error. | 5 |
| run_status | 6 (Stopped) | Agent has been stopped manually or by another process. | 6 |

**Current Status All Agents** [sort:1] -- Latest snapshot per agent showing health, queue depth, and throughput.

```sql
SELECT 
    r.publication_name,
    r.subscriber_name,
    r.agent_type,
    h.run_status,
    h.agent_message,
    h.pending_command_count,
    h.delivery_rate,
    h.collected_dttm
FROM ServerOps.Replication_AgentHistory h
JOIN ServerOps.Replication_PublicationRegistry r 
    ON h.publication_registry_id = r.publication_registry_id
WHERE h.collected_dttm = (
    SELECT MAX(collected_dttm) 
    FROM ServerOps.Replication_AgentHistory
)
ORDER BY r.agent_type, r.publication_name;
```

**Queue Depth Trend (24 Hours)** [sort:2] -- Distribution agent queue depth and delivery rate over the last 24 hours for trending.

```sql
SELECT 
    r.publication_name,
    h.collected_dttm,
    h.pending_command_count,
    h.delivery_rate
FROM ServerOps.Replication_AgentHistory h
JOIN ServerOps.Replication_PublicationRegistry r 
    ON h.publication_registry_id = r.publication_registry_id
WHERE r.agent_type = 'Distribution'
  AND h.collected_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY r.publication_name, h.collected_dttm;
```

**Throughput Averages by Publication (7 Days)** [sort:3] -- Average, max, and min delivery rates per publication over the last 7 days. Filters to Running/Idle states only.

```sql
SELECT 
    r.publication_name,
    r.agent_type,
    AVG(h.delivery_rate) AS avg_delivery_rate,
    MAX(h.delivery_rate) AS max_delivery_rate,
    MIN(h.delivery_rate) AS min_delivery_rate,
    COUNT(*) AS snapshot_count
FROM ServerOps.Replication_AgentHistory h
JOIN ServerOps.Replication_PublicationRegistry r 
    ON h.publication_registry_id = r.publication_registry_id
WHERE h.collected_dttm >= DATEADD(DAY, -7, GETDATE())
  AND h.run_status IN (2, 3)
GROUP BY r.publication_name, r.agent_type
ORDER BY r.publication_name;
```

**Agents Currently Down** [sort:4] -- Any agents reporting Failed or Stopped status in the most recent collection cycle.

```sql
SELECT 
    r.publication_name,
    r.subscriber_name,
    r.agent_type,
    h.run_status,
    CASE h.run_status 
        WHEN 5 THEN 'Failed' 
        WHEN 6 THEN 'Stopped' 
    END AS status_desc,
    h.agent_message,
    h.collected_dttm
FROM ServerOps.Replication_AgentHistory h
JOIN ServerOps.Replication_PublicationRegistry r 
    ON h.publication_registry_id = r.publication_registry_id
WHERE h.collected_dttm = (
    SELECT MAX(collected_dttm) 
    FROM ServerOps.Replication_AgentHistory
)
  AND h.run_status IN (5, 6);
```

  - **Replication_PublicationRegistry**: [sort:1] FK to registry. Each snapshot row references a registry entry to identify which agent it describes. The registry provides stable identification while the distribution database agent_ids may change.
  - **Replication_EventLog**: [sort:2] The collector uses the previous AgentHistory snapshot to detect state changes. If the current run_status differs from the most recent snapshot, a STATE_CHANGE event (and potentially AGENT_START/AGENT_STOP) is logged to the EventLog. These two tables work as a pair: AgentHistory captures continuous state, EventLog captures transitions.


### Replication_EventLog

Significant replication events including state transitions, errors, agent starts and stops, with correlation tracking to identify whether events are expected or require attention.

**Data Flow:** Append-only, change-driven. Populated by Collect-ReplicationHealth.ps1 during event detection (Step 4). Each cycle, the collector compares the current run_status to the previous AgentHistory snapshot. State changes generate events. Errors detected via error_id > 0 on the current history row generate ERROR events independently of state changes. Agent stops are correlated with BIDATA.BuildExecution to tag expected events. Read by the Control Center Replication page for event timeline display.

**Change Detection Not Polling:** [sort:1] Events are logged only when state changes — the collector compares current run_status to the previous AgentHistory snapshot each cycle. If nothing changed, nothing is logged. This filters out the enormous noise in SQL Server's distribution history tables (routine "delivered N transactions" messages every few seconds).

**BIDATA Build Correlation:** [sort:2] When an AGENT_STOP event is detected, the collector checks BIDATA.BuildExecution for an active or recently completed build. If found, correlation_source is set to 'BIDATA_BUILD', marking the stop as expected. NULL correlation_source means unexpected — these are the events that warrant investigation. Two of three Distribution agents are intentionally stopped during the nightly BIDATA build (~1 AM - 5 AM).

**Stopped Detection Edge Case:** [sort:3] SQL Server sometimes reports run_status = 2 (Running) with a "The process was successfully stopped" agent message when an agent is stopped externally. The collector detects this pattern by checking both the status code and the message content, and treats it as an AGENT_STOP event rather than a normal Running state.

**Error Events Without State Change:** [sort:4] ERROR events can be logged independently of state changes. If an agent reports error_id > 0 on the current history row but its run_status hasn't changed, the error is still captured. This catches transient errors that the agent recovers from without transitioning to a Failed state.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| event_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for this event |
| publication_registry_id | int | No | — | FK to Replication_PublicationRegistry. Identifies which agent this event pertains to |
| event_type | varchar(30) | No | — | Type of event: STATE_CHANGE, ERROR, AGENT_START, AGENT_STOP, RETRY, INFO |
| event_dttm | datetime | No | — | When the event occurred at the source (from distribution database, not collection time) |
| previous_state | int | Yes | — | Previous run_status code. NULL for non-state-change events |
| previous_state_desc | varchar(20) | Yes | — | Previous state description (Started, Running, Idle, Retrying, Failed, Stopped). NULL for non-state-change events |
| current_state | int | Yes | — | Current run_status code. NULL for non-state-change events |
| current_state_desc | varchar(20) | Yes | — | Current state description. NULL for non-state-change events |
| event_message | nvarchar(512) | Yes | — | Agent message or comment associated with this event from the distribution database |
| error_id | int | Yes | — | Reference to MSrepl_errors in the distribution database. NULL or zero if not an error event |
| error_detail | nvarchar(1000) | Yes | — | Error text captured from MSrepl_errors. Provides immediate context without distribution database lookup |
| correlation_source | varchar(50) | Yes | — | Known process that correlates with this event. NULL indicates an unexpected or unidentified event |
| collected_dttm | datetime | No | getdate() | When this event was detected and recorded by the collector |

  - **PK_Replication_EventLog** (CLUSTERED): event_id -- PRIMARY KEY
  - **IX_Replication_EventLog_registry_dttm** (NONCLUSTERED): publication_registry_id, event_dttm [includes: event_type, previous_state, current_state, correlation_source]
  - **IX_Replication_EventLog_type_dttm** (NONCLUSTERED): event_type, event_dttm [includes: publication_registry_id, event_message, correlation_source]

**Check Constraints:**

  - **CK_Replication_EventLog_event_type**: `([event_type]='INFO' OR [event_type]='RETRY' OR [event_type]='AGENT_STOP' OR [event_type]='AGENT_START' OR [event_type]='ERROR' OR [event_type]='STATE_CHANGE')`

**Foreign Keys:**

  - **FK_Replication_EventLog_PublicationRegistry**: publication_registry_id -> ServerOps.Replication_PublicationRegistry.publication_registry_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| event_type | STATE_CHANGE | Agent run_status changed between collection cycles. Generic transition event logged for any status change. | 1 |
| event_type | AGENT_START | Agent transitioned to Started, Running, or Idle from a non-running state. Subset of STATE_CHANGE for dashboard convenience. | 2 |
| event_type | AGENT_STOP | Agent transitioned to Stopped from a running state, or "successfully stopped" message detected. Subset of STATE_CHANGE for dashboard convenience. | 3 |
| event_type | ERROR | Agent reported an error (error_id > 0 on current distribution history row). Can occur with or without a state change. | 4 |
| event_type | RETRY | Agent entered retry state (run_status = 4). Indicates an error occurred but the agent is attempting recovery. | 5 |
| event_type | INFO | Informational event worth recording. Used for registry changes, configuration updates, and other non-error events at collector discretion. | 6 |
| correlation_source | BIDATA_BUILD | Event coincides with the nightly BIDATA data warehouse build. Detected by checking BIDATA.BuildExecution for an active or recently completed build. | 7 |
| correlation_source | NULL | No known correlating process identified. This is a signal — unexpected events with NULL correlation warrant investigation. | 8 |

**Recent Events (24 Hours)** [sort:1] -- All events in the last 24 hours with publication context and correlation status.

```sql
SELECT 
    r.publication_name,
    r.subscriber_name,
    r.agent_type,
    e.event_type,
    e.event_dttm,
    e.previous_state_desc,
    e.current_state_desc,
    e.event_message,
    e.correlation_source
FROM ServerOps.Replication_EventLog e
JOIN ServerOps.Replication_PublicationRegistry r 
    ON e.publication_registry_id = r.publication_registry_id
WHERE e.event_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY e.event_dttm DESC;
```

**Unexpected Events (7 Days)** [sort:2] -- Events with no correlation source — these are the ones that may need attention.

```sql
SELECT 
    r.publication_name,
    r.subscriber_name,
    e.event_type,
    e.event_dttm,
    e.previous_state_desc,
    e.current_state_desc,
    e.event_message,
    e.error_detail
FROM ServerOps.Replication_EventLog e
JOIN ServerOps.Replication_PublicationRegistry r 
    ON e.publication_registry_id = r.publication_registry_id
WHERE e.correlation_source IS NULL
  AND e.event_type IN ('STATE_CHANGE', 'ERROR', 'AGENT_STOP')
  AND e.event_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY e.event_dttm DESC;
```

**All Errors** [sort:3] -- Error events with full detail including distribution database error text.

```sql
SELECT 
    r.publication_name,
    r.subscriber_name,
    r.agent_type,
    e.event_dttm,
    e.event_message,
    e.error_id,
    e.error_detail
FROM ServerOps.Replication_EventLog e
JOIN ServerOps.Replication_PublicationRegistry r 
    ON e.publication_registry_id = r.publication_registry_id
WHERE e.event_type = 'ERROR'
ORDER BY e.event_dttm DESC;
```

**BIDATA Build Correlation History (30 Days)** [sort:4] -- Events correlated with the nightly BIDATA build. Useful for verifying the expected stop/start pattern.

```sql
SELECT 
    r.publication_name,
    e.event_type,
    e.event_dttm,
    e.previous_state_desc,
    e.current_state_desc,
    e.event_message
FROM ServerOps.Replication_EventLog e
JOIN ServerOps.Replication_PublicationRegistry r 
    ON e.publication_registry_id = r.publication_registry_id
WHERE e.correlation_source = 'BIDATA_BUILD'
  AND e.event_dttm >= DATEADD(DAY, -30, GETDATE())
ORDER BY e.event_dttm DESC;
```

**Event Summary by Type (30 Days)** [sort:5] -- Count of events by type and correlation status for operational overview.

```sql
SELECT 
    event_type,
    correlation_source,
    COUNT(*) AS event_count,
    MIN(event_dttm) AS earliest,
    MAX(event_dttm) AS latest
FROM ServerOps.Replication_EventLog
WHERE event_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY event_type, correlation_source
ORDER BY event_type, correlation_source;
```

  - **Replication_PublicationRegistry**: [sort:1] FK to registry. Each event references a registry entry identifying which agent experienced the state change or error.
  - **Replication_AgentHistory**: [sort:2] No direct FK, but operationally dependent. Event detection works by comparing the current agent state to the most recent AgentHistory snapshot. Without continuous AgentHistory collection, event detection would not function.
  - **BIDATA.BuildExecution**: [sort:3] Cross-module dependency for correlation. When an AGENT_STOP event is detected, the collector queries BIDATA.BuildExecution for an active or recently completed build to determine if the stop was expected. This is the only cross-module reference in the Replication component.


### Replication_LatencyHistory

Tracer token results measuring end-to-end replication latency from publisher through distributor to subscriber, with individual hop timing for bottleneck identification.

**Data Flow:** Append-only. Populated by Collect-ReplicationHealth.ps1 on a configurable interval (default every 5 minutes). The collector posts a tracer token via sp_posttracertoken on the publisher database, waits a configurable period (default 15 seconds), then collects results via sp_helptracertokenhistory. One row inserted per subscriber per token. After collection, the token is cleaned up from the distribution database via sp_deletetracertokenhistory. Also queried by the collector to determine elapsed time since the last token run. Read by the Control Center Replication page for latency dashboards.

**Three-Hop Latency Breakdown:** [sort:1] Each measurement breaks total latency into two segments: publisher-to-distributor (reflects Log Reader performance) and distributor-to-subscriber (reflects Distribution Agent and network performance). When total latency spikes, the breakdown immediately identifies which hop is the bottleneck.

**NULL Subscriber Commit as Signal:** [sort:2] When a tracer token never arrives at the subscriber (agent stopped, network issue), subscriber_commit_dttm and downstream latency values are NULL. This is meaningful data — it confirms the Distribution Agent is not delivering. During the nightly BIDATA build window, NULL subscriber commits are expected and prove agents are stopped as intended.

**Token Cleanup:** [sort:3] The collector calls sp_deletetracertokenhistory after collecting results to prevent accumulation of tracer token records in the distribution database. Tokens are lightweight but their metadata persists in system tables until explicitly removed.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| latency_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for this latency measurement row |
| publication_registry_id | int | No | — | FK to Replication_PublicationRegistry. Identifies which publication/subscriber pair this measurement is for |
| tracer_token_id | int | No | — | Token ID returned by sp_posttracertoken. Unique within the distribution database |
| publisher_commit_dttm | datetime | Yes | — | When the tracer token was committed at the publisher |
| distributor_commit_dttm | datetime | Yes | — | When the tracer token arrived at the distributor |
| subscriber_commit_dttm | datetime | Yes | — | When the tracer token arrived at the subscriber. NULL if token never arrived |
| publisher_to_distributor_ms | int | Yes | — | Milliseconds from publisher commit to distributor commit. Reflects Log Reader Agent performance |
| distributor_to_subscriber_ms | int | Yes | — | Milliseconds from distributor commit to subscriber commit. Reflects Distribution Agent and network performance. NULL if token never arrived |
| total_latency_ms | int | Yes | — | End-to-end milliseconds from publisher to subscriber. NULL if token did not complete the full journey |
| collected_dttm | datetime | No | getdate() | When these results were captured by the collector |

  - **PK_Replication_LatencyHistory** (CLUSTERED): latency_id -- PRIMARY KEY
  - **IX_Replication_LatencyHistory_registry_collected** (NONCLUSTERED): publication_registry_id, collected_dttm [includes: total_latency_ms, publisher_to_distributor_ms, distributor_to_subscriber_ms]

**Foreign Keys:**

  - **FK_Replication_LatencyHistory_PublicationRegistry**: publication_registry_id -> ServerOps.Replication_PublicationRegistry.publication_registry_id

**Latest Latency Per Publication** [sort:1] -- Most recent tracer token measurement for each publication/subscriber pair.

```sql
SELECT 
    r.publication_name,
    r.subscriber_name,
    l.publisher_commit_dttm,
    l.total_latency_ms,
    l.publisher_to_distributor_ms,
    l.distributor_to_subscriber_ms,
    l.collected_dttm
FROM ServerOps.Replication_LatencyHistory l
JOIN ServerOps.Replication_PublicationRegistry r 
    ON l.publication_registry_id = r.publication_registry_id
WHERE l.latency_id IN (
    SELECT MAX(latency_id) 
    FROM ServerOps.Replication_LatencyHistory 
    GROUP BY publication_registry_id
)
ORDER BY r.publication_name;
```

**Latency Trend (24 Hours)** [sort:2] -- All latency measurements over the last 24 hours for trending and BIDATA build window analysis.

```sql
SELECT 
    r.publication_name,
    r.subscriber_name,
    l.collected_dttm,
    l.total_latency_ms,
    l.publisher_to_distributor_ms,
    l.distributor_to_subscriber_ms
FROM ServerOps.Replication_LatencyHistory l
JOIN ServerOps.Replication_PublicationRegistry r 
    ON l.publication_registry_id = r.publication_registry_id
WHERE l.collected_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY r.publication_name, l.collected_dttm;
```

**Tokens That Never Arrived** [sort:3] -- Tracer tokens where the subscriber never received delivery. Expected during BIDATA build windows; unexpected at other times.

```sql
SELECT 
    r.publication_name,
    r.subscriber_name,
    l.tracer_token_id,
    l.publisher_commit_dttm,
    l.distributor_commit_dttm,
    l.collected_dttm
FROM ServerOps.Replication_LatencyHistory l
JOIN ServerOps.Replication_PublicationRegistry r 
    ON l.publication_registry_id = r.publication_registry_id
WHERE l.subscriber_commit_dttm IS NULL
  AND l.collected_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY l.collected_dttm DESC;
```

**Average Latency by Publication (30 Days)** [sort:4] -- Latency statistics per publication including failed token count. Useful for baselining normal behavior and tuning alert thresholds.

```sql
SELECT 
    r.publication_name,
    r.subscriber_name,
    AVG(l.total_latency_ms) AS avg_latency_ms,
    MAX(l.total_latency_ms) AS max_latency_ms,
    MIN(l.total_latency_ms) AS min_latency_ms,
    COUNT(*) AS token_count,
    SUM(CASE WHEN l.subscriber_commit_dttm IS NULL 
        THEN 1 ELSE 0 END) AS failed_tokens
FROM ServerOps.Replication_LatencyHistory l
JOIN ServerOps.Replication_PublicationRegistry r 
    ON l.publication_registry_id = r.publication_registry_id
WHERE l.collected_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY r.publication_name, r.subscriber_name
ORDER BY r.publication_name;
```

  - **Replication_PublicationRegistry**: [sort:1] FK to registry. Each latency measurement references a registry entry identifying the publication/subscriber pair. Only Distribution agents produce latency data — Log Reader entries never appear here.
  - **Replication_AgentHistory**: [sort:2] No direct FK, but operationally paired. AgentHistory shows whether agents are running; LatencyHistory measures what that means for actual data delivery timing. During BIDATA build windows, AgentHistory shows Stopped status while LatencyHistory shows NULL subscriber_commit — the two tables tell the same story from different angles.


### Replication_PublicationRegistry

Master catalog of monitored replication publications and subscribers, dynamically discovered from the distribution database with soft-delete support for dropped publications.

**Data Flow:** Populated by Collect-ReplicationHealth.ps1 via registry discovery. Each cycle, the collector queries distribution.dbo.MSdistribution_agents joined with MSsubscriber_info and MSpublications to discover Distribution agents, and MSlogreader_agents for the Log Reader. New agents are inserted automatically. Existing entries are refreshed (agent_id, agent_name, metadata IDs). Agents no longer found are soft-deleted (is_dropped = 1). Previously dropped agents that reappear are reactivated on their original row. Read by all subsequent collection steps as the authoritative list of what to monitor.

**Dynamic Discovery with Soft Delete:** [sort:1] No manual setup required when publications are created or dropped. The collector auto-discovers from the distribution database each cycle. Dropped publications are soft-deleted (is_dropped = 1) to preserve FK integrity with AgentHistory, LatencyHistory, and EventLog. If a dropped publication is recreated with the same natural key, the original row is reused rather than creating a duplicate.

**Subscriber Name Resolution:** [sort:2] subscriber_name stores the name from MSsubscriber_info in the distribution database, not the linked server alias from master.sys.servers. These can differ significantly (e.g., linked server "DM-TEST-APP" maps to subscriber "fa-bidata.database.windows.net"). The registered subscriber name is required for system procedure calls like sp_replmonitorsubscriptionpendingcmds. Resolution uses prefix matching against the agent name string.

**Log Reader as Registry Entry:** [sort:3] The Log Reader agent is stored as a registry entry with agent_type = 'LogReader' and subscriber fields set to the publisher_db name. This is a design convenience — the Log Reader has no subscriber, but storing it in the same registry table keeps all agent monitoring unified. The natural key uses publisher_db for publication_name, subscriber_name, and subscriber_db.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| publication_registry_id (IDENTITY) | int | No | IDENTITY | Unique identifier for this registry entry |
| publisher_id | smallint | Yes | — | publisher_id from distribution.dbo.MSpublications. Refreshed on discovery |
| publisher_db | nvarchar(128) | No | — | Published database name (e.g., crs5_oltp) |
| publication_id | int | Yes | — | publication_id from distribution.dbo.MSpublications. Refreshed on discovery |
| publication_name | nvarchar(128) | No | — | Publication name as defined in SQL Server replication |
| publication_type | int | Yes | — | 0 = Transactional, 1 = Snapshot, 2 = Merge |
| publication_type_desc | varchar(20) | Yes | — | Transactional, Snapshot, or Merge |
| subscriber_id | smallint | Yes | — | subscriber_id from MSdistribution_agents (maps to master.sys.servers). Refreshed on discovery |
| subscriber_name | nvarchar(128) | No | — | Subscriber name as registered in distribution.dbo.MSsubscriber_info |
| subscriber_db | nvarchar(128) | No | — | Subscriber database name |
| subscription_type | int | No | — | 0 = Push, 1 = Pull (matches SQL Server convention) |
| subscription_type_desc | varchar(10) | No | — | Push or Pull |
| agent_name | nvarchar(100) | Yes | — | Distribution or Log Reader agent name from distribution database |
| agent_id | int | Yes | — | Current agent_id from distribution database. Refreshed on discovery; may change if subscription is dropped and recreated |
| agent_type | varchar(20) | No | — | Distribution or LogReader |
| is_monitored | bit | No | 1 | User-controlled flag: whether this publication is included in health monitoring |
| tracer_tokens_enabled | bit | No | 1 | User-controlled flag: whether tracer tokens are posted for this publication |
| is_dropped | bit | No | 0 | Whether this publication no longer exists in the distribution database |
| dropped_detected_dttm | datetime | Yes | — | When the drop was first detected by the collector |
| created_dttm | datetime | No | getdate() | When this registry entry was first created |
| modified_dttm | datetime | Yes | — | When this entry was last modified by the collector |

  - **PK_Replication_PublicationRegistry** (CLUSTERED): publication_registry_id -- PRIMARY KEY
  - **UQ_Replication_PublicationRegistry_pub_sub** (NONCLUSTERED): publication_name, subscriber_name, subscriber_db, agent_type

**Check Constraints:**

  - **CK_Replication_PublicationRegistry_publication_type**: `([publication_type]=(2) OR [publication_type]=(1) OR [publication_type]=(0))`
  - **CK_Replication_PublicationRegistry_publication_type_desc**: `([publication_type_desc]='Merge' OR [publication_type_desc]='Snapshot' OR [publication_type_desc]='Transactional')`
  - **CK_Replication_PublicationRegistry_subscription_type**: `([subscription_type]=(1) OR [subscription_type]=(0))`
  - **CK_Replication_PublicationRegistry_subscription_type_desc**: `([subscription_type_desc]='Pull' OR [subscription_type_desc]='Push')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| agent_type | Distribution | Distribution Agent delivering commands from distributor to subscriber. One per publication/subscriber pair. Full monitoring: health, queue depth, throughput, tracer tokens. | 1 |
| agent_type | LogReader | Log Reader Agent reading the publisher transaction log and writing to the distribution database. One per published database. Health and throughput only — no queue depth or tracer tokens. Single point of failure for all publications from the same database. | 2 |
| subscription_type | 0 (Push) | Publisher-initiated delivery. The Distribution Agent runs at the distributor and pushes changes to the subscriber. | 3 |
| subscription_type | 1 (Pull) | Subscriber-initiated delivery. The Distribution Agent runs at the subscriber and pulls changes from the distributor. | 4 |
| publication_type | 0 (Transactional) | Transactional replication — continuous delivery of committed transactions. All current Frost-Arnett publications use this type. | 5 |
| publication_type | 1 (Snapshot) | Snapshot replication — periodic full data refresh. Not currently in use. | 6 |
| publication_type | 2 (Merge) | Merge replication — bidirectional sync with conflict resolution. Not currently in use. | 7 |

**Active Publications** [sort:1] -- All monitored publications with their subscription details.

```sql
SELECT 
    publication_registry_id,
    publication_name,
    publication_type_desc,
    subscriber_name,
    subscriber_db,
    subscription_type_desc,
    agent_type,
    is_monitored,
    tracer_tokens_enabled
FROM ServerOps.Replication_PublicationRegistry
WHERE is_dropped = 0
ORDER BY agent_type, publication_name;
```

**Dropped Publications** [sort:2] -- Publications no longer found in the distribution database.

```sql
SELECT 
    publication_name,
    subscriber_name,
    subscriber_db,
    agent_type,
    dropped_detected_dttm
FROM ServerOps.Replication_PublicationRegistry
WHERE is_dropped = 1
ORDER BY dropped_detected_dttm DESC;
```

**Current Landscape Summary** [sort:3] -- Agent count and monitoring status overview for active publications.

```sql
SELECT 
    agent_type,
    COUNT(*) AS agent_count,
    SUM(CAST(is_monitored AS INT)) AS monitored,
    SUM(CAST(tracer_tokens_enabled AS INT)) AS tracer_enabled
FROM ServerOps.Replication_PublicationRegistry
WHERE is_dropped = 0
GROUP BY agent_type;
```

  - **Replication_AgentHistory**: [sort:1] FK parent. Every agent health snapshot references a registry entry. The registry provides the stable identifier while distribution database agent_ids may change if subscriptions are dropped and recreated.
  - **Replication_LatencyHistory**: [sort:2] FK parent. Tracer token results are stored per publication/subscriber pair, linked back through the registry. Only Distribution agents generate latency data.
  - **Replication_EventLog**: [sort:3] FK parent. State change events reference the registry to identify which agent experienced the transition.
  - **Collect-ReplicationHealth.ps1**: [sort:4] The collector script performs registry discovery each cycle by querying the distribution database and syncing results into this table. All subsequent collection steps use this registry as the authoritative list of agents to monitor.


### Collect-ReplicationHealth.ps1

Single collection engine for replication monitoring. Handles registry discovery, agent health/queue/throughput snapshots, event detection with BIDATA build correlation, and tracer token latency measurement — all in a single orchestrated cycle running every 60 seconds via the xFACts Orchestrator.

**Data Flow:** Reads from: distribution.dbo.MSdistribution_agents, MSdistribution_history, MSlogreader_agents, MSlogreader_history, MSsubscriber_info, MSpublications (agent catalog and health); sp_replmonitorsubscriptionpendingcmds (queue depth); sp_posttracertoken, sp_helptracertokenhistory, sp_deletetracertokenhistory (tracer tokens) on DM-PROD-DB. Reads from: dbo.GlobalConfig (thresholds and intervals), ServerOps.Replication_PublicationRegistry (existing registry), ServerOps.Replication_AgentHistory (previous snapshot for event detection), BIDATA.BuildExecution (correlation check) on AVG-PROD-LSNR. Writes to: ServerOps.Replication_PublicationRegistry (registry sync), ServerOps.Replication_AgentHistory (snapshots), ServerOps.Replication_EventLog (state change events), ServerOps.Replication_LatencyHistory (tracer token results).

**Single Script, Multiple Layers:** [sort:1] All four monitoring layers (registry discovery, agent health, event detection, tracer tokens) run in a single script to eliminate coordination overhead. Discovery ensures the registry is fresh before collecting health data. Event detection uses the snapshot just collected. Tracer tokens run conditionally based on elapsed time. One script, one cycle, one clean pass.

**Conditional Tracer Token Execution:** [sort:2] Tracer tokens run on a separate interval (default 5 minutes) rather than every 60-second cycle. The script checks MAX(collected_dttm) from Replication_LatencyHistory to determine elapsed time. This avoids overwhelming the distribution database with token operations while still providing regular latency measurements. Most cycles complete in under 1 second; tracer token cycles take 15-45 seconds due to the propagation wait.

**Subscriber Name Prefix Matching:** [sort:3] The discovery query joins MSdistribution_agents with MSsubscriber_info using prefix matching against the agent name string. This is necessary because MSdistribution_agents.subscriber_id maps to linked server aliases in master.sys.servers, which may differ from the registered subscriber name in MSsubscriber_info (e.g., linked server "DM-TEST-APP" maps to subscriber "fa-bidata.database.windows.net").

**FIRE_AND_FORGET Orchestrator Integration:** [sort:4] Runs as a FIRE_AND_FORGET process in the orchestrator. On completion, calls Complete-OrchestratorTask to report success/failure and duration. The output message includes snapshot and event counts for operational visibility in TaskLog.

  - **Orchestrator.ProcessRegistry**: [sort:1] Registered as a FIRE_AND_FORGET process in dependency group 10 (collection tier) with a 60-second interval. Receives TaskId and ProcessId parameters from the orchestrator engine for completion callback.
  - **dbo.GlobalConfig**: [sort:2] Reads all configuration from GlobalConfig under module_name = 'ServerOps', category = 'Replication'. Settings include tracer_interval_minutes, tracer_wait_seconds, queue/latency warning/critical thresholds, and alerting_enabled master switch.
  - **BIDATA.BuildExecution**: [sort:3] Cross-module read during event detection. When an agent stop is detected, checks BuildExecution for an active or recently completed build to tag the event as expected (correlation_source = 'BIDATA_BUILD').
  - **distribution database (DM-PROD-DB)**: [sort:4] External dependency. All source data comes from the distribution database system tables and procedures. The service account running this script must have SQL access to both the distribution database and the publisher database (crs5_oltp) on DM-PROD-DB.



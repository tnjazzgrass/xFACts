# Server Health

*Because SQL Server has the memory of a goldfish and your disk drives won’t monitor themselves*

Server Health is the always-on surveillance system for your SQL Server fleet. Activity Monitoring captures what’s happening inside the database engine — long-running queries, blocking, deadlocks, memory pressure, connection health. Disk Monitoring watches the drives underneath. Together, they answer the question everyone eventually asks: “What happened to the server yesterday afternoon?”






The Problem

It’s 9 AM. Someone walks over to your desk. “The system was slow yesterday afternoon.”

You nod professionally while internally screaming. Because here’s the thing about SQL Server — it’s perfectly happy to tell you what’s happening *right now*, but ask about yesterday? Gone. The diagnostic data resets. Logs roll over. By the time someone reports a problem, the evidence has packed its bags and moved to Tahiti.

And then there’s disk space. Running out of it is completely preventable but somehow still catches people off guard. Every. Single. Time. A database grows faster than expected. Log files accumulate. Someone copies a massive backup to the wrong location. And suddenly production is down because the error message says “could not allocate space.”

Server Health fixes both problems. Activity Monitoring is the security camera system — constantly recording so you can answer with data instead of interpretive dance. Disk Monitoring is the early warning system — catching capacity problems before they become outages.






Activity Monitoring: The Security Cameras



SQL Server
Events & DMVs
→
Two
Collectors
→
Stored &
Correlated
→
Answers
When Asked

Extended Events + DMV Polling — two approaches, one complete picture


SQL Server provides two fundamentally different kinds of diagnostic data, so we use two collectors.

The first captures the **drama** — the database equivalent of car chases and fender benders. Long-running queries that hog resources like your coworker hogs the good conference room. Blocking chains where one slow process creates a traffic jam. Deadlocks where SQL Server coldly picks a victim and terminates them. Server traffic between linked servers that was previously invisible. All captured as discrete events with timestamps you can go back to.

The second captures the **vital signs** — continuous snapshots of how the server is feeling. Memory health (imagine a nightclub where the bouncer starts throwing people out every few seconds — that’s what low memory pressure looks like). Connection pool health, including zombie sessions that forgot to leave. Wait statistics, which tell you *why* the database is slow instead of just *that* it’s slow. Workload indicators that correlate with user reports.

Together, they’re like having a witness AND a medical examiner. Morbid? Maybe. Effective? Absolutely.

The smart part: when a metric crosses a threshold, the system automatically looks for concurrent events that might explain why. “Memory crashed at 2:47 PM” is useful. “Memory crashed at 2:47 PM and here are the three massive queries that were running” is actionable. There’s even a diagnostic tool that reads across all the data and produces a plain-English report with recommendations and pre-written text for communicating to users. No more translating database metrics into human.






Disk Monitoring: The Space Watcher



Collect
Disk Space
→
Check
Thresholds
→
Alert
If Needed
→
Auto-Resolve
On Recovery

Collect, evaluate, alert, resolve — all automatic


Disk monitoring is simpler, and it should be. Collect disk space from every server on a regular schedule. Check against thresholds. Alert if something’s low. Auto-resolve when it recovers. Send a color-coded summary card every morning. Done.

Each drive can have its own threshold because context matters. A 10TB data drive at 15% free still has 1.5TB available — probably fine. A 100GB system drive at 15% only has 15GB left — that’s getting uncomfortable.

You get **one alert per problem**, not a flood of repeated notifications. The system knows you’re already aware. It’s polite like that. And the daily summary card is color-coded for instant recognition. Green header means don’t even read the details. Yellow means at least one drive is approaching its threshold. Red means action needed. Servers sorted worst-first because when something’s on fire, you want to see the fire first.






The Bottom Line

SQL Server monitoring is like dental hygiene — not exciting, but skip it and you’ll regret it later. The diagnostic data is powerful but forgetful. Disk drives fill up in slow motion until they don’t.

Server Health does the boring work so you don’t have to. Events captured and stored. Metrics building history. Threshold crossings automatically correlated with likely causes. Disk space watched and reported before anyone has to ask.

When someone asks “what happened?” you can answer with data. And when a drive starts filling up, you’ll know about it before it becomes an outage. That’s the whole pitch.

---

# Server Health — Control Center Guide

---

## Architecture
# Server Health Architecture

Activity Monitoring Schema
The Activity component is the largest in xFACts by object count. Eighteen tables organized into four categories: DMV snapshots (point-in-time server metrics), XE event storage (discrete captured events), infrastructure (collection state, heartbeat), and incident management (threshold crossings with automated correlation).

| Category | Tables | Purpose |
| --- | --- | --- |
| DMV Snapshots | 6 | Point-in-time server metrics: memory, workload, connections, waits, I/O, self-monitoring |
| XE Events | 8 | Discrete captured events: long queries, blocking, deadlocks, linked server traffic, AG health, system health |
| Infrastructure | 2 | Collection state tracking and heartbeat summaries |
| Incidents | 2 | Threshold crossings with automated root cause correlation |


All Activity tables share a common pattern: `server_id` FK to `dbo.ServerRegistry` plus a denormalized `server_name` for query convenience. The denormalization is deliberate — most queries filter by server name, and the join would add overhead to every investigative query.



Dual Collection Architecture
Activity Monitoring uses two complementary collection approaches because SQL Server provides two fundamentally different types of diagnostic data. Extended Events capture discrete happenings (a query finished, a deadlock occurred). DMVs expose continuous state (current memory pressure, cumulative wait times).



SQL Server
XE sessions write .xel
DMVs expose state

→

Parallel

Collect-XEEvents
8 sessions → 8 tables
Collect-DMVMetrics
6 categories → 6 tables


→

Correlate
Threshold crossing
+ root cause matching

→

Heartbeat
Denormalized health
summary per cycle


Both collectors run on a configurable schedule. Per-metric error isolation ensures partial collection on any individual failure.

| Collector | Approach | Data Type | Tables Fed |
| --- | --- | --- | --- |
| `Collect-XEEvents.ps1` | File-based incremental read from .xel files | Discrete events | 8 XE tables + CollectionState |
| `Collect-DMVMetrics.ps1` | Point-in-time DMV queries | Cumulative counters & gauges | 6 DMV tables + Heartbeat + IncidentLog |


Per-metric error isolation. Both collectors wrap each individual metric/session collection in its own try/catch. A failure collecting wait stats doesn't prevent memory metrics from being captured. Partial collection is better than no collection.




Extended Events Sessions
Eight XE sessions run on each monitored server — six custom sessions deployed by xFACts and two built-in Microsoft sessions. Each writes to rolling .xel files which are collected incrementally by `Collect-XEEvents.ps1`.
Custom Sessions (xFACts-Deployed)
| Session | Captures | Threshold | Feeds |
| --- | --- | --- | --- |
| `xFACts_LongQueries` | sql_statement_completed, rpc_completed | Duration predicate in microseconds (default 30s) | Activity_XE_LRQ |
| `xFACts_BlockedProcess` | blocked_process_report | sp_configure threshold (server-level, default 60s) | Activity_XE_BlockedProcess |
| `xFACts_Deadlock` | xml_deadlock_report | None — captures all deadlocks | Activity_XE_Deadlock |
| `xFACts_LS_Inbound` | sql_statement_completed, rpc_completed | Predicate: linked server connections only | Activity_XE_LinkedServerIn |
| `xFACts_LS_Outbound` | sql_statement_completed, rpc_completed | Predicate excludes Redgate and SQLServerCEIP | Activity_XE_LinkedServerOut |
| `xFACts_Tracking` | sql_batch_completed | xFACts processes only; excludes collector to prevent feedback loop | Activity_XE_xFACts |

Built-In Sessions (Microsoft-Managed)
| Session | Captures | Notes | Feeds |
| --- | --- | --- | --- |
| `system_health` | Security errors, connectivity, diagnostics | Event list varies by SQL Server version; collected as-is | Activity_XE_SystemHealth |
| `AlwaysOn_health` | AG state changes, failovers, sync state | Only on AG servers; separate collection step | Activity_XE_AGHealth |

Incremental Collection
`Activity_XE_CollectionState` tracks the read position (file name + byte offset) for each session on each server. On each cycle, the collector reads from the last known position forward. New sessions are auto-enrolled via MERGE when first encountered.

Session-driven architecture. The collector iterates over sessions found on each server, not a hardcoded list. When a new XE session is deployed, collection begins automatically on the next cycle.



Deadlock pattern recognition. Common deadlock patterns to watch for: key-lookup deadlocks (missing covering indexes), page-lock escalation deadlocks (large scans competing with updates), and cascading FK deadlocks (parent-child operations in opposite order). The `deadlock_graph` XML in `Activity_XE_Deadlock` contains the complete resource and process details — if the same query pair keeps appearing, it’s a design issue to fix, not bad luck to accept.



DMV Snapshot Architecture
DMV tables store cumulative counters and point-in-time gauges. Most metrics are cumulative since SQL Server startup, meaning useful analysis requires calculating deltas between snapshots. A negative delta indicates a service restart (counters reset to zero).
| Table | Source DMVs | Key Metrics |
| --- | --- | --- |
| `Activity_DMV_Memory` | sys.dm_os_performance_counters | PLE, buffer cache hit ratio, memory grants pending, lazy writes |
| `Activity_DMV_Workload` | sys.dm_os_performance_counters, sys.dm_exec_requests | Connections, active requests, blocked sessions, batch requests/sec |
| `Activity_DMV_ConnectionHealth` | sys.dm_exec_sessions, sys.dm_exec_connections | Total sessions, zombie count, JDBC pool health, open transactions |
| `Activity_DMV_WaitStats` | sys.dm_os_wait_stats | Multiple rows per snapshot (one per wait type); cumulative counters |
| `Activity_DMV_IO_Stats` | sys.dm_io_virtual_file_stats | Read/write counts and stall times per database per file type |
| `Activity_DMV_xFACts` | sys.dm_exec_sessions (xFACts processes) | Per-session CPU, reads, writes for self-monitoring |


Cumulative counter pattern. Wait stats and I/O stats are cumulative since startup. To find activity in a time window, subtract the earlier snapshot from the later one. The common queries in the reference page demonstrate this delta calculation pattern.



I/O latency interpretation. Read latency under 10ms is generally healthy. 10–20ms is acceptable for most workloads. Above 20ms suggests storage pressure, and above 50ms usually means users are noticing. Write latency is typically lower than read; values above 5ms warrant investigation. These are guidelines, not absolutes — context matters.



Wait type quick reference. The most common actionable wait types: `PAGEIOLATCH_*` (disk I/O pressure), `LCK_M_*` (lock contention/blocking), `CXPACKET` (parallelism overhead), `WRITELOG` (transaction log throughput), `SOS_SCHEDULER_YIELD` (CPU pressure). Many wait types are benign — `WAITFOR`, `BROKER_RECEIVE_WAITFOR`, `LAZYWRITER_SLEEP`, and `SQLTRACE_BUFFER_FLUSH` are normal background activity and can be safely ignored when analyzing wait patterns.




Incident Correlation
When `Collect-DMVMetrics.ps1` detects a threshold crossing (e.g., PLE below minimum), it calls `sp_Activity_CorrelateIncidents` as a secondary operation. The procedure doesn't just log the crossing — it automatically queries `Activity_XE_LRQ` for concurrent long-running queries that might explain the symptom.


Threshold
Crossed
→
sp_Activity_
CorrelateIncidents
→
IncidentLog
+ Evidence

Symptom + likely cause, together, without manual investigation

| Component | Role |
| --- | --- |
| `Activity_IncidentType` | Reference table: incident types with code-based PKs, default severity, correlation target |
| `Activity_IncidentLog` | One row per threshold crossing with automated root cause evidence and optional HADR correlation |
| `sp_Activity_CorrelateIncidents` | Creates incident, queries correlation target for concurrent activity. Supports `@PreviewOnly = 1` |


AG partner determination. For HADR incidents, the procedure automatically identifies the AG partner server and checks for correlated events on both sides of the AG.



Heartbeat & Diagnosis
`Activity_Heartbeat` receives a summary row from `Collect-DMVMetrics.ps1` on each cycle with denormalized key metrics (PLE, zombie count, blocked sessions) and an overall health status. `sp_DiagnoseServerHealth` is the interactive diagnostic — an eight-section plain-English report with three detail levels. Section 8 includes pre-written user communication text.
| Detail Level | Audience | Content |
| --- | --- | --- |
| 0 (default) | Quick triage | Current state, obvious problems, recommendations |
| 1 | Investigation | Adds trending data, threshold history, correlation details |
| 2 | Deep dive | Full educational context with metric explanations |




Disk Monitoring Schema
The Disk component is compact by design. Four tables covering snapshots, thresholds, alerts, and health status. All logic lives in a stored procedure and two PowerShell scripts.

| Table | Role | Cardinality |
| --- | --- | --- |
| `Disk_Snapshot` | Hourly disk space snapshots | One row per server/drive per collection cycle |
| `Disk_ThresholdConfig` | Per-drive alerting thresholds | One row per server/drive (auto-created on discovery) |
| `Disk_AlertHistory` | Active and resolved disk alerts | One row per alert event (auto-resolves on recovery) |
| `Disk_Status` | Component execution health | One row per process |




Disk Monitoring Flow
Disk monitoring runs on a configurable schedule. Collection happens via WinRM (not SQL Server DMVs) which means it sees every fixed drive on the server, not just drives with database files.



WinRM Collect
All fixed drives
per enabled server

→

Store Snapshot
Disk_Snapshot
+ auto-create config

→

Evaluate
Per-drive threshold
from ThresholdConfig

→

Result

OK / Resolve
Alert via Teams



Runs on a configurable schedule. New drives auto-enrolled on first discovery. One alert per problem, auto-resolves on recovery.

Alert Lifecycle
Disk alerts have a clean lifecycle with automatic resolution. When a drive drops below its threshold, one alert is created and one Teams notification is sent. The alert stays active until the drive recovers, at which point it auto-resolves. No duplicate notifications.
Daily Health Summary
`Send-DiskHealthSummary.ps1` sends a color-coded Adaptive Card to Teams each morning. Green means all clear. Yellow means drives are approaching thresholds. Red means drives are below. Servers sorted worst-first for quick scanning.

Approaching threshold detection. The summary card uses a configurable warning buffer (default 2%) above the threshold to flag drives heading for trouble before they trigger an alert.



Snapshot retention. Disk snapshots accumulate over time and should be periodically trimmed. Retaining 90 days of snapshots provides sufficient trending data for capacity planning while keeping the table manageable. Snapshots older than the retention window can be safely archived or purged without affecting alerting or daily summaries, which only reference the most recent collection.



Troubleshooting

**“It was slow yesterday.”**
Check DMV Memory (PLE crashes) and Wait Stats (unusual patterns) for the time window. Then check XE tables for concurrent blocking or long-running queries. Or run `sp_DiagnoseServerHealth` with an appropriate lookback and let it do the work.

**“I’m getting timeouts.”**
Check Blocking Events and Connection Health. Long blocks plus zombie accumulation usually explains timeouts.

**“Transactions are failing randomly.”**
Check Deadlocks. If the same queries keep appearing, it’s a design issue, not bad luck.

**“A disk alert keeps firing and resolving.”**
The drive is hovering around its threshold. Either free up enough space for headroom, or adjust the threshold if the current level is acceptable. Investigate what’s consuming space cyclically — temp files? Log files? Someone’s “temporary” backup from 2019?

**“The daily summary shows stale data.”**
The summary checks data freshness before processing. If the collection script hasn’t run (orchestrator stopped, WinRM issues), you’ll see a warning. Check that the collectors are executing successfully in the Orchestrator TaskLog.



How Everything Connects
Activity — Internal Flow
| From | To | Relationship |
| --- | --- | --- |
| `Collect-XEEvents.ps1` | 8 XE tables | Parses .xel files, inserts events by session type |
| `Collect-XEEvents.ps1` | `Activity_XE_CollectionState` | Updates file offset after each collection |
| `Collect-DMVMetrics.ps1` | 6 DMV tables | Snapshots cumulative counters and gauges |
| `Collect-DMVMetrics.ps1` | `Activity_Heartbeat` | Writes denormalized health summary per cycle |
| `Collect-DMVMetrics.ps1` | `sp_Activity_CorrelateIncidents` | Calls correlation on threshold crossing |

Disk — Internal Flow
| From | To | Relationship |
| --- | --- | --- |
| `Collect-ServerHealth.ps1` | `Disk_Snapshot` | Stores disk space data via WinRM on each collection cycle |
| `Collect-ServerHealth.ps1` | `Disk_ThresholdConfig` | Auto-creates config for newly discovered drives |
| `Collect-ServerHealth.ps1` | `Disk_AlertHistory` | Creates alerts on threshold crossing, auto-resolves on recovery |
| `Send-DiskHealthSummary.ps1` | `Teams.AlertQueue` | Direct INSERT with pre-built Adaptive Card JSON |

Shared Dependencies
| Dependency | Module | Used By |
| --- | --- | --- |
| `Orchestrator.ProcessRegistry` | Orchestrator | Schedules all scripts |
| `dbo.ServerRegistry` | Shared Infrastructure | Enrollment flags: `serverops_activity_enabled`, `serverops_disk_enabled` |
| `dbo.GlobalConfig` | Shared Infrastructure | Thresholds, feature toggles, AG configuration |
| `Teams.AlertQueue` | Teams Integration | Alert delivery for Disk and Activity incidents |

---

## Reference

### Activity_DMV_ConnectionHealth

Stores point-in-time connection pool health snapshots collected via DMV polling, providing visibility into zombie connections, open transactions, and JDBC session breakdown.

**Data Flow:** Collect-DMVMetrics.ps1 queries sys.dm_exec_sessions with a CTE that classifies sessions as zombies based on configurable idle threshold from GlobalConfig (threshold_zombie_idle_minutes). Inserts one row per server per collection cycle. sp_Activity_CorrelateIncidents reads the latest zombie_count for threshold evaluation. sp_DiagnoseServerHealth reads this table for connection and zombie analysis (Section 6). The Control Center Server Health page reads this table for zombie trend charts and connection pool gauges.

**Zombie Connection Definition:** [sort:1] A session is classified as a zombie when ALL three conditions are met: status = sleeping, open_transaction_count = 0, and idle time exceeds the configurable threshold (GlobalConfig threshold_zombie_idle_minutes, default 60). This three-part test avoids false positives from legitimately sleeping sessions that are part of connection pools or have pending transactions.

**JDBC Session Tracking:** [sort:2] The jdbc_total, jdbc_sleeping, and jdbc_zombie columns track JDBC driver sessions separately because applications using Java connection pooling (JBoss, Tomcat) are the primary source of zombie connections. JDBC sessions are identified by program_name LIKE '%JDBC%'. Other application sessions are included in the overall session counts but not broken out individually.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| snapshot_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the snapshot |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| snapshot_dttm | datetime2 | No | — | When the snapshot was captured |
| total_sessions | int | Yes | — | All user sessions (session_id > 50) |
| sleeping_sessions | int | Yes | — | Sessions with status = 'sleeping' |
| running_sessions | int | Yes | — | Sessions with status = 'running' |
| zombie_count | int | Yes | — | Sessions meeting zombie criteria (sleeping, no open tran, idle > threshold) |
| oldest_zombie_idle_min | int | Yes | — | Minutes idle for the oldest zombie session |
| sessions_with_open_tran | int | Yes | — | Sessions with open_transaction_count > 0 |
| oldest_open_tran_min | int | Yes | — | Minutes since last request for oldest session with open transaction |
| jdbc_total | int | Yes | — | All JDBC driver sessions |
| jdbc_sleeping | int | Yes | — | Sleeping JDBC sessions |
| jdbc_zombie | int | Yes | — | JDBC sessions meeting zombie criteria |
| collected_dttm | datetime | No | getdate() | When the snapshot was imported into xFACts |

  - **PK_Activity_DMV_ConnectionHealth** (CLUSTERED): snapshot_id -- PRIMARY KEY
  - **IX_Activity_DMV_ConnectionHealth_ServerTimestamp** (NONCLUSTERED): server_id, snapshot_dttm

**Foreign Keys:**

  - **FK_Activity_DMV_ConnectionHealth_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Current Connection Health (All Servers)** [sort:1] -- Latest snapshot per server

```sql
-- Latest snapshot per server
SELECT 
    c.server_name,
    c.snapshot_dttm,
    c.total_sessions,
    c.zombie_count,
    c.oldest_zombie_idle_min,
    c.jdbc_total,
    c.jdbc_zombie
FROM ServerOps.Activity_DMV_ConnectionHealth c
INNER JOIN (
    SELECT server_id, MAX(snapshot_id) AS max_id
    FROM ServerOps.Activity_DMV_ConnectionHealth
    GROUP BY server_id
) latest ON c.snapshot_id = latest.max_id
ORDER BY c.server_name;
```

**Zombie Trend for Specific Server** [sort:2] -- Last 24 hours of zombie counts for DM-PROD-DB

```sql
-- Last 24 hours of zombie counts for DM-PROD-DB
SELECT 
    snapshot_dttm,
    total_sessions,
    zombie_count,
    jdbc_zombie,
    oldest_zombie_idle_min
FROM ServerOps.Activity_DMV_ConnectionHealth
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm;
```

**High Zombie Count Events** [sort:3] -- Snapshots where zombie count exceeded threshold

```sql
-- Snapshots where zombie count exceeded threshold
SELECT 
    server_name,
    snapshot_dttm,
    zombie_count,
    jdbc_zombie,
    oldest_zombie_idle_min,
    total_sessions
FROM ServerOps.Activity_DMV_ConnectionHealth
WHERE zombie_count >= 100
ORDER BY snapshot_dttm DESC;
```

**JDBC Pool Health Over Time** [sort:4] -- Track JDBC connection pool behavior

```sql
-- Track JDBC connection pool behavior
SELECT 
    snapshot_dttm,
    jdbc_total,
    jdbc_sleeping,
    jdbc_zombie,
    CAST(jdbc_zombie AS DECIMAL(5,2)) / NULLIF(jdbc_total, 0) * 100 AS jdbc_zombie_pct
FROM ServerOps.Activity_DMV_ConnectionHealth
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY snapshot_dttm;
```

**Open Transaction Monitoring** [sort:5] -- Sessions with long-running open transactions

```sql
-- Sessions with long-running open transactions
SELECT 
    server_name,
    snapshot_dttm,
    sessions_with_open_tran,
    oldest_open_tran_min
FROM ServerOps.Activity_DMV_ConnectionHealth
WHERE oldest_open_tran_min > 60
ORDER BY oldest_open_tran_min DESC;
```

**Zombie Accumulation Rate** [sort:6] -- How fast are zombies accumulating?

```sql
-- How fast are zombies accumulating?
SELECT 
    snapshot_dttm,
    zombie_count,
    zombie_count - LAG(zombie_count) OVER (ORDER BY snapshot_dttm) AS zombie_delta
FROM ServerOps.Activity_DMV_ConnectionHealth
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm;
```


### Activity_DMV_IO_Stats

Stores point-in-time I/O latency snapshots collected via DMV polling, providing visibility into storage performance and database file throughput across all monitored servers.

**Data Flow:** Collect-DMVMetrics.ps1 queries sys.dm_io_virtual_file_stats joined to sys.master_files on each monitored server, aggregating by database and file type (DATA or LOG). Inserts multiple rows per server per collection cycle (one per database/file-type combination). sp_DiagnoseServerHealth does not currently use this table directly. The Control Center Server Health page reads this table for I/O latency charts and database throughput analysis.

**Database/File-Type Aggregation:** [sort:1] Raw DMV data is per-file. The collection query aggregates to database + file type (DATA vs LOG) to reduce row volume while preserving the ability to distinguish data file I/O from transaction log I/O. Individual file-level detail is not captured. Like WaitStats, all numeric columns are cumulative since service startup and require delta calculation.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| snapshot_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the snapshot |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| snapshot_dttm | datetime2 | No | — | When the snapshot was captured |
| database_name | nvarchar(128) | No | — | Database name |
| file_type | varchar(4) | No | — | File type: DATA or LOG |
| num_of_reads | bigint | Yes | — | Cumulative read operations (since service start) |
| num_of_writes | bigint | Yes | — | Cumulative write operations (since service start) |
| num_of_bytes_read | bigint | Yes | — | Cumulative bytes read (since service start) |
| num_of_bytes_written | bigint | Yes | — | Cumulative bytes written (since service start) |
| io_stall_read_ms | bigint | Yes | — | Cumulative milliseconds waiting on reads (since service start) |
| io_stall_write_ms | bigint | Yes | — | Cumulative milliseconds waiting on writes (since service start) |
| collected_dttm | datetime | No | getdate() | When the snapshot was imported into xFACts |

  - **PK_Activity_DMV_IO_Stats** (CLUSTERED): snapshot_id -- PRIMARY KEY
  - **IX_Activity_DMV_IO_Stats_Database** (NONCLUSTERED): database_name, server_id, snapshot_dttm
  - **IX_Activity_DMV_IO_Stats_ServerTimestamp** (NONCLUSTERED): server_id, snapshot_dttm

**Foreign Keys:**

  - **FK_Activity_DMV_IO_Stats_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Current I/O State (All Databases)** [sort:1] -- Latest snapshot per server/database/file_type

```sql
-- Latest snapshot per server/database/file_type
SELECT 
    io.server_name,
    io.database_name,
    io.file_type,
    io.snapshot_dttm,
    io.num_of_reads,
    io.num_of_writes,
    io.io_stall_read_ms,
    io.io_stall_write_ms
FROM ServerOps.Activity_DMV_IO_Stats io
INNER JOIN (
    SELECT server_id, database_name, file_type, MAX(snapshot_id) AS max_id
    FROM ServerOps.Activity_DMV_IO_Stats
    GROUP BY server_id, database_name, file_type
) latest ON io.snapshot_id = latest.max_id
ORDER BY io.server_name, io.database_name, io.file_type;
```

**Average Read Latency by Database (Last 24 Hours)** [sort:2] -- Calculate average read latency per I/O operation

```sql
-- Calculate average read latency per I/O operation
WITH IODeltas AS (
    SELECT 
        server_name,
        database_name,
        file_type,
        snapshot_dttm,
        num_of_reads - LAG(num_of_reads) OVER (
            PARTITION BY server_id, database_name, file_type 
            ORDER BY snapshot_dttm
        ) AS reads_delta,
        io_stall_read_ms - LAG(io_stall_read_ms) OVER (
            PARTITION BY server_id, database_name, file_type 
            ORDER BY snapshot_dttm
        ) AS stall_delta
    FROM ServerOps.Activity_DMV_IO_Stats
    WHERE snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
)
SELECT 
    server_name,
    database_name,
    file_type,
    SUM(reads_delta) AS total_reads,
    SUM(stall_delta) AS total_stall_ms,
    CASE WHEN SUM(reads_delta) > 0 
         THEN CAST(SUM(stall_delta) * 1.0 / SUM(reads_delta) AS DECIMAL(10,2))
         ELSE 0 
    END AS avg_read_latency_ms
FROM IODeltas
WHERE reads_delta > 0
GROUP BY server_name, database_name, file_type
ORDER BY avg_read_latency_ms DESC;
```

**High Latency Events** [sort:3] -- Find intervals with high read latency (> 20ms average)

```sql
-- Find intervals with high read latency (> 20ms average)
WITH IODeltas AS (
    SELECT 
        server_name,
        database_name,
        file_type,
        snapshot_dttm,
        num_of_reads - LAG(num_of_reads) OVER (
            PARTITION BY server_id, database_name, file_type 
            ORDER BY snapshot_dttm
        ) AS reads_delta,
        io_stall_read_ms - LAG(io_stall_read_ms) OVER (
            PARTITION BY server_id, database_name, file_type 
            ORDER BY snapshot_dttm
        ) AS stall_delta
    FROM ServerOps.Activity_DMV_IO_Stats
    WHERE snapshot_dttm >= DATEADD(DAY, -7, GETDATE())
)
SELECT 
    server_name,
    database_name,
    file_type,
    snapshot_dttm,
    reads_delta AS reads_in_interval,
    stall_delta AS stall_ms_in_interval,
    CAST(stall_delta * 1.0 / NULLIF(reads_delta, 0) AS DECIMAL(10,2)) AS avg_latency_ms
FROM IODeltas
WHERE reads_delta > 0
  AND stall_delta * 1.0 / reads_delta > 20
ORDER BY snapshot_dttm DESC;
```


### Activity_DMV_Memory

Stores point-in-time memory health snapshots collected via DMV polling, providing visibility into Page Life Expectancy, buffer cache efficiency, and memory pressure indicators.

**Data Flow:** Collect-DMVMetrics.ps1 queries sys.dm_os_performance_counters (Buffer Manager and Memory Manager categories) on each monitored server and inserts one row per server per collection cycle. sp_Activity_CorrelateIncidents reads the latest snapshot per server to evaluate PLE thresholds and writes results to Activity_Heartbeat and Activity_IncidentLog. sp_DiagnoseServerHealth reads this table for memory health analysis (Section 2) including PLE trending, buffer cache hit ratio, and memory grants pending. The Control Center Server Health page reads this table for memory health gauges and trend charts.

**Performance Counter Sources:** [sort:1] PLE and buffer cache hit ratio come from the Buffer Manager performance counter object. Memory grants pending, target memory, and total memory come from the Memory Manager object. Free list stalls and lazy writes are cumulative counters from Buffer Manager — they reset on service restart and require delta calculation in queries to derive per-interval rates.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| snapshot_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the snapshot |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| snapshot_dttm | datetime2 | No | — | When the snapshot was captured |
| ple_seconds | int | Yes | — | Page Life Expectancy - seconds a page stays in buffer pool |
| buffer_cache_hit_ratio | decimal(5,2) | Yes | — | Percentage of pages found in buffer cache without disk read |
| memory_grants_pending | int | Yes | — | Number of queries waiting for memory grant |
| target_memory_mb | bigint | Yes | — | Maximum memory SQL Server can use (from max server memory) |
| total_memory_mb | bigint | Yes | — | Current memory committed to buffer pool |
| free_list_stalls | bigint | Yes | — | Cumulative stalls waiting for free buffer page (since service start) |
| lazy_writes | bigint | Yes | — | Cumulative pages flushed by lazy writer (since service start) |
| collected_dttm | datetime | No | getdate() | When the snapshot was imported into xFACts |

  - **PK_Activity_DMV_Memory** (CLUSTERED): snapshot_id -- PRIMARY KEY
  - **IX_Activity_DMV_Memory_ServerTimestamp** (NONCLUSTERED): server_id, snapshot_dttm

**Foreign Keys:**

  - **FK_Activity_DMV_Memory_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Current Memory State (All Servers)** [sort:1] -- Latest snapshot per server

```sql
-- Latest snapshot per server
SELECT 
    m.server_name,
    m.snapshot_dttm,
    m.ple_seconds,
    m.buffer_cache_hit_ratio,
    m.memory_grants_pending,
    m.total_memory_mb,
    m.target_memory_mb
FROM ServerOps.Activity_DMV_Memory m
INNER JOIN (
    SELECT server_id, MAX(snapshot_id) AS max_id
    FROM ServerOps.Activity_DMV_Memory
    GROUP BY server_id
) latest ON m.snapshot_id = latest.max_id
ORDER BY m.server_name;
```

**PLE Trend for Specific Server** [sort:2] -- Last 24 hours of PLE for DM-PROD-DB

```sql
-- Last 24 hours of PLE for DM-PROD-DB
SELECT 
    snapshot_dttm,
    ple_seconds,
    memory_grants_pending,
    buffer_cache_hit_ratio
FROM ServerOps.Activity_DMV_Memory
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm;
```

**Low PLE Events** [sort:3] -- Snapshots where PLE dropped below 300 seconds

```sql
-- Snapshots where PLE dropped below 300 seconds
SELECT 
    server_name,
    snapshot_dttm,
    ple_seconds,
    memory_grants_pending,
    total_memory_mb
FROM ServerOps.Activity_DMV_Memory
WHERE ple_seconds < 300
ORDER BY snapshot_dttm DESC;
```

**Lazy Writes Delta (Memory Pressure Indicator)** [sort:4] -- Calculate lazy writes per interval

```sql
-- Calculate lazy writes per interval
SELECT 
    server_name,
    snapshot_dttm,
    ple_seconds,
    lazy_writes,
    lazy_writes - LAG(lazy_writes) OVER (PARTITION BY server_id ORDER BY snapshot_dttm) AS lazy_writes_delta
FROM ServerOps.Activity_DMV_Memory
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm;
```


### Activity_DMV_WaitStats

Stores point-in-time wait statistics snapshots collected via DMV polling, providing visibility into what SQL Server is waiting on and enabling performance trend analysis.

**Data Flow:** Collect-DMVMetrics.ps1 queries sys.dm_os_wait_stats for all wait types with wait_time_ms > 0 on each monitored server. Inserts multiple rows per server per collection cycle (one per active wait type). sp_Activity_CorrelateIncidents reads HADR_SYNC_COMMIT wait deltas between consecutive snapshots for threshold evaluation. sp_DiagnoseServerHealth reads this table for wait category analysis (Section 3) and HADR health analysis (Section 4). The Control Center Server Health page reads this table for wait statistics breakdown charts.

**Multiple Rows Per Snapshot:** [sort:1] Unlike other DMV tables that store one row per server per cycle, WaitStats stores one row per wait type per server per cycle. This captures the full wait type breakdown without pre-aggregating into categories, enabling flexible analysis at query time. The volume is higher but the granularity supports ad-hoc investigation of any wait type.

**Cumulative Counters With Delta Analysis:** [sort:2] All three numeric columns (waiting_tasks_count, wait_time_ms, signal_wait_time_ms) are cumulative since SQL Server startup. Delta calculation between consecutive snapshots yields per-interval activity. A negative delta indicates a service restart. The signal_wait_time_ms component isolates CPU scheduling delays from resource wait time, helping distinguish CPU pressure from I/O or lock contention.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| snapshot_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the snapshot row |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| snapshot_dttm | datetime2 | No | — | When the snapshot was captured |
| wait_type | nvarchar(60) | No | — | SQL Server wait type name |
| waiting_tasks_count | bigint | Yes | — | Cumulative count of waits on this type (since service start) |
| wait_time_ms | bigint | Yes | — | Cumulative wait time in milliseconds (since service start) |
| signal_wait_time_ms | bigint | Yes | — | Cumulative signal wait time in milliseconds (since service start) |
| collected_dttm | datetime | No | getdate() | When the snapshot was imported into xFACts |

  - **PK_Activity_DMV_WaitStats** (CLUSTERED): snapshot_id -- PRIMARY KEY
  - **IX_Activity_DMV_WaitStats_ServerTimestamp** (NONCLUSTERED): server_id, snapshot_dttm
  - **IX_Activity_DMV_WaitStats_WaitType** (NONCLUSTERED): wait_type, server_id, snapshot_dttm

**Foreign Keys:**

  - **FK_Activity_DMV_WaitStats_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Current Top Waits (All Servers)** [sort:1] -- Top wait types by cumulative time per server (latest snapshot)

```sql
-- Top wait types by cumulative time per server (latest snapshot)
WITH LatestSnapshot AS (
    SELECT server_id, MAX(snapshot_dttm) AS max_dttm
    FROM ServerOps.Activity_DMV_WaitStats
    GROUP BY server_id
)
SELECT 
    w.server_name,
    w.wait_type,
    w.wait_time_ms / 1000 / 60 AS wait_minutes,
    w.waiting_tasks_count
FROM ServerOps.Activity_DMV_WaitStats w
INNER JOIN LatestSnapshot ls ON w.server_id = ls.server_id AND w.snapshot_dttm = ls.max_dttm
WHERE w.wait_type NOT IN ('WAITFOR', 'BROKER_TASK_STOP', 'CLR_AUTO_EVENT', 
    'HADR_WORK_QUEUE', 'SLEEP_TASK', 'SP_SERVER_DIAGNOSTICS_SLEEP')
ORDER BY w.server_name, w.wait_time_ms DESC;
```

**Wait Deltas Over Time (Specific Wait Type)** [sort:2] -- PAGEIOLATCH_SH trend for last 24 hours

```sql
-- PAGEIOLATCH_SH trend for last 24 hours
SELECT 
    snapshot_dttm,
    wait_time_ms,
    wait_time_ms - LAG(wait_time_ms) OVER (ORDER BY snapshot_dttm) AS wait_delta_ms,
    waiting_tasks_count - LAG(waiting_tasks_count) OVER (ORDER BY snapshot_dttm) AS tasks_delta
FROM ServerOps.Activity_DMV_WaitStats
WHERE server_name = 'DM-PROD-DB'
  AND wait_type = 'PAGEIOLATCH_SH'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm;
```

**Top Waits in Last Hour (Delta-Based)** [sort:3] -- What did we wait on most in the last hour?

```sql
-- What did we wait on most in the last hour?
WITH Snapshots AS (
    SELECT 
        server_name,
        wait_type,
        snapshot_dttm,
        wait_time_ms,
        LAG(wait_time_ms) OVER (PARTITION BY server_id, wait_type ORDER BY snapshot_dttm) AS prev_wait_time_ms
    FROM ServerOps.Activity_DMV_WaitStats
    WHERE server_name = 'DM-PROD-DB'
      AND snapshot_dttm >= DATEADD(HOUR, -1, GETDATE())
)
SELECT 
    wait_type,
    SUM(wait_time_ms - prev_wait_time_ms) / 1000 AS wait_seconds_last_hour
FROM Snapshots
WHERE prev_wait_time_ms IS NOT NULL
  AND wait_time_ms >= prev_wait_time_ms
GROUP BY wait_type
HAVING SUM(wait_time_ms - prev_wait_time_ms) > 0
ORDER BY wait_seconds_last_hour DESC;
```

**Detect Service Restarts** [sort:4] -- Find snapshots where counters reset (service restarted)

```sql
-- Find snapshots where counters reset (service restarted)
WITH WaitDeltas AS (
    SELECT 
        server_name,
        wait_type,
        snapshot_dttm,
        wait_time_ms,
        LAG(wait_time_ms) OVER (PARTITION BY server_id, wait_type ORDER BY snapshot_dttm) AS prev_value
    FROM ServerOps.Activity_DMV_WaitStats
    WHERE wait_type = 'PAGEIOLATCH_SH'
      AND snapshot_dttm >= DATEADD(DAY, -7, GETDATE())
)
SELECT server_name, snapshot_dttm, wait_time_ms, prev_value
FROM WaitDeltas
WHERE prev_value IS NOT NULL
  AND wait_time_ms < prev_value;
```


### Activity_DMV_Workload

Stores point-in-time workload health snapshots collected via DMV polling, providing visibility into connection counts, blocking, active requests, and query compilation rates.

**Data Flow:** Collect-DMVMetrics.ps1 queries sys.dm_os_performance_counters (General Statistics and SQL Statistics categories), sys.dm_exec_requests for blocked/active counts, and @@CPU_BUSY/@@IO_BUSY for server-level utilization on each monitored server. Inserts one row per server per collection cycle. sp_DiagnoseServerHealth reads this table for workload context. The Control Center Server Health page reads this table for connection count and batch throughput charts.

**Cumulative Counters Require Delta Calculation:** [sort:1] batch_requests, sql_compilations, sql_recompilations, cpu_busy_ms, and io_busy_ms are cumulative counters that reset on service restart. Raw values are stored; delta calculation between consecutive snapshots is performed in queries. A negative delta indicates a service restart occurred between snapshots.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| snapshot_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the snapshot |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| snapshot_dttm | datetime2 | No | — | When the snapshot was captured |
| user_connections | int | Yes | — | Current number of user connections |
| blocked_session_count | int | Yes | — | Number of sessions currently blocked by another session |
| active_request_count | int | Yes | — | Number of requests in running, runnable, or suspended state |
| batch_requests | bigint | Yes | — | Cumulative batch requests received (since service start) |
| sql_compilations | bigint | Yes | — | Cumulative SQL compilations (since service start) |
| sql_recompilations | bigint | Yes | — | Cumulative SQL recompilations (since service start) |
| collected_dttm | datetime | No | getdate() | When the snapshot was imported into xFACts |
| cpu_busy_ms | bigint | Yes | — | Cumulative CPU busy time in milliseconds (@@CPU_BUSY * @@TIMETICKS / 1000 since service start) |
| io_busy_ms | bigint | Yes | — | Cumulative I/O busy time in milliseconds (@@IO_BUSY * @@TIMETICKS / 1000 since service start) |

  - **PK_Activity_DMV_Workload** (CLUSTERED): snapshot_id -- PRIMARY KEY
  - **IX_Activity_DMV_Workload_ServerTimestamp** (NONCLUSTERED): server_id, snapshot_dttm

**Foreign Keys:**

  - **FK_Activity_DMV_Workload_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Current Workload State (All Servers)** [sort:1] -- Latest snapshot per server

```sql
-- Latest snapshot per server
SELECT 
    w.server_name,
    w.snapshot_dttm,
    w.user_connections,
    w.blocked_session_count,
    w.active_request_count
FROM ServerOps.Activity_DMV_Workload w
INNER JOIN (
    SELECT server_id, MAX(snapshot_id) AS max_id
    FROM ServerOps.Activity_DMV_Workload
    GROUP BY server_id
) latest ON w.snapshot_id = latest.max_id
ORDER BY w.server_name;
```

**Connection Trend for Specific Server** [sort:2] -- Last 24 hours of connections for DM-PROD-DB

```sql
-- Last 24 hours of connections for DM-PROD-DB
SELECT 
    snapshot_dttm,
    user_connections,
    blocked_session_count,
    active_request_count
FROM ServerOps.Activity_DMV_Workload
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm;
```

**Blocking Events Over Time** [sort:3] -- Snapshots where blocking was occurring

```sql
-- Snapshots where blocking was occurring
SELECT 
    server_name,
    snapshot_dttm,
    blocked_session_count,
    user_connections,
    active_request_count
FROM ServerOps.Activity_DMV_Workload
WHERE blocked_session_count > 0
ORDER BY snapshot_dttm DESC;
```

**Batch Requests Per Interval (Throughput)** [sort:4] -- Calculate batch requests per interval

```sql
-- Calculate batch requests per interval
SELECT 
    server_name,
    snapshot_dttm,
    batch_requests,
    batch_requests - LAG(batch_requests) OVER (PARTITION BY server_id ORDER BY snapshot_dttm) AS batch_requests_delta,
    user_connections
FROM ServerOps.Activity_DMV_Workload
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm;
```

**Compilation Rate Analysis** [sort:5] -- Identify periods of high compilation/recompilation

```sql
-- Identify periods of high compilation/recompilation
SELECT 
    server_name,
    snapshot_dttm,
    sql_compilations - LAG(sql_compilations) OVER (PARTITION BY server_id ORDER BY snapshot_dttm) AS compilations_delta,
    sql_recompilations - LAG(sql_recompilations) OVER (PARTITION BY server_id ORDER BY snapshot_dttm) AS recompilations_delta
FROM ServerOps.Activity_DMV_Workload
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm;
```

**CPU Utilization Between Snapshots** [sort:6] -- Calculate server CPU busy percentage between snapshots

```sql
-- Calculate server CPU busy percentage between snapshots
-- Requires two consecutive snapshots with non-null cpu_busy_ms
SELECT 
    server_name,
    snapshot_dttm,
    cpu_busy_ms,
    cpu_busy_ms - LAG(cpu_busy_ms) OVER (PARTITION BY server_id ORDER BY snapshot_dttm) AS cpu_delta_ms,
    DATEDIFF(MILLISECOND,
        LAG(snapshot_dttm) OVER (PARTITION BY server_id ORDER BY snapshot_dttm),
        snapshot_dttm) AS interval_ms,
    CASE 
        WHEN LAG(cpu_busy_ms) OVER (PARTITION BY server_id ORDER BY snapshot_dttm) IS NOT NULL
        THEN CAST(
            100.0 * (cpu_busy_ms - LAG(cpu_busy_ms) OVER (PARTITION BY server_id ORDER BY snapshot_dttm))
            / NULLIF(DATEDIFF(MILLISECOND,
                LAG(snapshot_dttm) OVER (PARTITION BY server_id ORDER BY snapshot_dttm),
                snapshot_dttm), 0)
        AS DECIMAL(5,1))
    END AS cpu_busy_pct
FROM ServerOps.Activity_DMV_Workload
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm;
```


### Activity_DMV_xFACts

Stores point-in-time snapshots of active xFACts sessions on each monitored server, capturing cumulative resource counters for impact analysis.

**Data Flow:** Collect-DMVMetrics.ps1 queries sys.dm_exec_sessions filtered to program_name LIKE 'xFACts%' on each monitored server. Inserts one row per active xFACts session per server per collection cycle. sp_DiagnoseServerHealth reads this table for monitoring overhead analysis (Section 5). Provides self-monitoring capability: xFACts tracking its own resource impact on the servers it monitors.

**Self-Monitoring Footprint:** [sort:1] Captures cumulative resource counters (cpu_time_ms, reads, logical_reads, writes, memory_usage_pages) for every active xFACts session on each monitored server. This allows detection of scenarios where xFACts monitoring itself is contributing to server load — particularly the XE collection script reading large event files. The program_name filter matches the ApplicationName parameter set by all xFACts PowerShell scripts.

**Per-Session Granularity:** [sort:2] Unlike other DMV tables that aggregate to one row per server, this table stores one row per xFACts session per server. A server may have multiple concurrent xFACts sessions (collection scripts, diagnostic queries). Each session's individual resource consumption is tracked to identify which specific xFACts process is the heaviest consumer.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| snapshot_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the snapshot |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| snapshot_dttm | datetime2 | No | — | When the snapshot was captured |
| session_id | int | No | — | SQL Server session ID (SPID) |
| program_name | varchar(128) | No | — | xFACts component name from connection string ApplicationName |
| login_name | varchar(128) | Yes | — | Login that owns the session |
| status | varchar(30) | Yes | — | Session status (running, sleeping, etc.) |
| cpu_time_ms | bigint | Yes | — | Cumulative CPU time in milliseconds since session connect |
| reads | bigint | Yes | — | Cumulative physical disk reads since session connect |
| logical_reads | bigint | Yes | — | Cumulative buffer cache reads since session connect |
| writes | bigint | Yes | — | Cumulative writes since session connect |
| last_request_start | datetime | Yes | — | When the session last started a request |
| last_request_end | datetime | Yes | — | When the session last completed a request |
| open_transaction_count | int | Yes | — | Number of open transactions (should be 0 for well-behaved sessions) |
| memory_usage_pages | int | Yes | — | Number of 8KB pages used by the session |
| collected_dttm | datetime | No | getdate() | When the snapshot was imported into xFACts |

  - **PK_Activity_DMV_xFACts** (CLUSTERED): snapshot_id -- PRIMARY KEY
  - **IX_Activity_DMV_xFACts_ProgramTimestamp** (NONCLUSTERED): program_name, snapshot_dttm
  - **IX_Activity_DMV_xFACts_ServerTimestamp** (NONCLUSTERED): server_id, snapshot_dttm

**Foreign Keys:**

  - **FK_Activity_DMV_xFACts_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Current xFACts Connection Footprint** [sort:1] -- Latest snapshot of all xFACts sessions per server

```sql
-- Latest snapshot of all xFACts sessions per server
SELECT 
    x.server_name,
    x.program_name,
    x.session_id,
    x.status,
    x.cpu_time_ms,
    x.logical_reads,
    x.writes,
    x.open_transaction_count,
    x.last_request_start,
    x.last_request_end
FROM ServerOps.Activity_DMV_xFACts x
WHERE x.snapshot_dttm = (
    SELECT MAX(snapshot_dttm) FROM ServerOps.Activity_DMV_xFACts
)
ORDER BY x.server_name, x.program_name;
```

**Session Count by Server Over Time** [sort:2] -- How many xFACts sessions per server per snapshot

```sql
-- How many xFACts sessions per server per snapshot
SELECT 
    server_name,
    snapshot_dttm,
    COUNT(*) AS session_count,
    SUM(ISNULL(logical_reads, 0)) AS total_logical_reads
FROM ServerOps.Activity_DMV_xFACts
WHERE snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
GROUP BY server_name, snapshot_dttm
ORDER BY server_name, snapshot_dttm;
```

**Control Center Resource Delta** [sort:3] -- Track Control Center resource consumption between snapshots

```sql
-- Track Control Center resource consumption between snapshots
-- Uses session_id to correlate the same persistent connection
SELECT 
    server_name,
    snapshot_dttm,
    session_id,
    logical_reads,
    logical_reads - LAG(logical_reads) OVER (
        PARTITION BY server_id, session_id ORDER BY snapshot_dttm
    ) AS reads_delta,
    cpu_time_ms - LAG(cpu_time_ms) OVER (
        PARTITION BY server_id, session_id ORDER BY snapshot_dttm
    ) AS cpu_delta_ms
FROM ServerOps.Activity_DMV_xFACts
WHERE program_name = 'xFACts Control Center'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY server_name, snapshot_dttm;
```

**Processes by Resource Consumption** [sort:4] -- Which xFACts components use the most resources (latest snapshot)

```sql
-- Which xFACts components use the most resources (latest snapshot)
SELECT 
    server_name,
    program_name,
    COUNT(*) AS session_count,
    SUM(ISNULL(cpu_time_ms, 0)) AS total_cpu_ms,
    SUM(ISNULL(logical_reads, 0)) AS total_logical_reads,
    SUM(ISNULL(writes, 0)) AS total_writes
FROM ServerOps.Activity_DMV_xFACts
WHERE snapshot_dttm = (
    SELECT MAX(snapshot_dttm) FROM ServerOps.Activity_DMV_xFACts
)
GROUP BY server_name, program_name
ORDER BY total_logical_reads DESC;
```


### Activity_Heartbeat

Per-cycle health pulse recording overall status and key metrics for each monitored server, providing a foundation for daily health reporting and trend analysis.

**Data Flow:** sp_Activity_CorrelateIncidents writes one row per server per collection cycle after evaluating all thresholds. The overall_status reflects the worst condition detected across all threshold checks. Key metrics (PLE, HADR delta, zombie count, cache hit) are denormalized from the DMV tables for efficient dashboard queries. Activity_IncidentLog rows created in the same cycle are back-linked via heartbeat_id. The Control Center Server Health page reads this table for the health status timeline and health summary statistics.

**Denormalized Key Metrics:** [sort:1] PLE, HADR delta, zombie count, and buffer cache hit ratio are copied from the latest DMV snapshots rather than requiring joins back to Activity_DMV_Memory, Activity_DMV_WaitStats, and Activity_DMV_ConnectionHealth. This trades storage for query simplicity and supports efficient dashboard aggregation (e.g., "240 healthy, 20 warning, 22 critical cycles yesterday").

**Duplicate Prevention on Re-Run:** [sort:2] sp_Activity_CorrelateIncidents checks for an existing heartbeat with the same server_name and snapshot_dttm before inserting. This prevents duplicate heartbeats if the procedure is called multiple times for the same collection cycle (e.g., during testing or recovery). Incidents from the cycle are linked to the heartbeat via heartbeat_id using SCOPE_IDENTITY after the heartbeat insert.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| heartbeat_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the heartbeat record |
| server_name | varchar(128) | No | — | Server this heartbeat is for |
| snapshot_dttm | datetime2 | No | — | Timestamp of the DMV collection cycle |
| overall_status | varchar(20) | No | — | HEALTHY, WARNING, or CRITICAL |
| incidents_logged | tinyint | No | 0 | Number of incidents logged during this cycle |
| ple_seconds | int | Yes | — | Page Life Expectancy at this snapshot |
| hadr_sync_delta_ms | bigint | Yes | — | HADR_SYNC_COMMIT wait delta since previous snapshot (AG servers only) |
| zombie_count | int | Yes | — | Number of zombie connections detected |
| buffer_cache_hit_pct | decimal(5,2) | Yes | — | Buffer cache hit ratio percentage |
| created_dttm | datetime | No | getdate() | When the heartbeat was recorded |

  - **PK_Activity_Heartbeat** (CLUSTERED): heartbeat_id -- PRIMARY KEY
  - **IX_Activity_Heartbeat_ServerTime** (NONCLUSTERED): server_name, snapshot_dttm
  - **IX_Activity_Heartbeat_Status** (NONCLUSTERED): overall_status, snapshot_dttm [includes: server_name, incidents_logged]

**Check Constraints:**

  - **CK_Activity_Heartbeat_Status**: `([overall_status]='CRITICAL' OR [overall_status]='WARNING' OR [overall_status]='HEALTHY')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| overall_status | HEALTHY | No threshold crossings detected for this server in this collection cycle. All monitored metrics are within acceptable ranges. | 1 |
| overall_status | WARNING | One or more metrics crossed warning thresholds but none reached critical. Examples: PLE below warning threshold, HADR delta above warning but below critical, memory grants pending above threshold. | 2 |
| overall_status | CRITICAL | One or more metrics crossed critical thresholds. Examples: PLE below critical threshold (PLE_CRISIS), HADR delta above critical threshold (HADR_SPIKE_CRITICAL). Critical status takes precedence over warning in the same cycle. | 3 |

**Daily Health Summary by Server** [sort:1]

```sql
SELECT 
    server_name,
    CAST(snapshot_dttm AS DATE) AS day,
    COUNT(*) AS total_cycles,
    SUM(CASE WHEN overall_status = 'HEALTHY' THEN 1 ELSE 0 END) AS healthy,
    SUM(CASE WHEN overall_status = 'WARNING' THEN 1 ELSE 0 END) AS warning,
    SUM(CASE WHEN overall_status = 'CRITICAL' THEN 1 ELSE 0 END) AS critical,
    SUM(incidents_logged) AS total_incidents
FROM ServerOps.Activity_Heartbeat
GROUP BY server_name, CAST(snapshot_dttm AS DATE)
ORDER BY day DESC, server_name;
```

**Problem Periods (Last 24 Hours)** [sort:2]

```sql
SELECT 
    server_name,
    snapshot_dttm,
    overall_status,
    ple_seconds,
    hadr_sync_delta_ms / 1000 AS hadr_delta_sec,
    incidents_logged
FROM ServerOps.Activity_Heartbeat
WHERE overall_status <> 'HEALTHY'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm DESC;
```

**Hourly Health Pattern** [sort:3]

```sql
SELECT 
    DATEPART(HOUR, snapshot_dttm) AS hour_of_day,
    COUNT(*) AS total_cycles,
    SUM(CASE WHEN overall_status = 'CRITICAL' THEN 1 ELSE 0 END) AS critical_count,
    AVG(ple_seconds) AS avg_ple
FROM ServerOps.Activity_Heartbeat
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(DAY, -7, GETDATE())
GROUP BY DATEPART(HOUR, snapshot_dttm)
ORDER BY hour_of_day;
```

**Server Comparison** [sort:4]

```sql
SELECT 
    server_name,
    COUNT(*) AS total_heartbeats,
    AVG(ple_seconds) AS avg_ple,
    MIN(ple_seconds) AS min_ple,
    SUM(incidents_logged) AS total_incidents
FROM ServerOps.Activity_Heartbeat
WHERE snapshot_dttm >= DATEADD(DAY, -1, GETDATE())
GROUP BY server_name
ORDER BY total_incidents DESC;
```


### Activity_IncidentLog

Detailed incident records capturing threshold crossings with correlated concurrent activity, providing automated root cause evidence for performance issues.

**Data Flow:** sp_Activity_CorrelateIncidents writes one row per threshold crossing detected during each collection cycle. Each row includes the triggering metric, its value, the correlation window searched, and any concurrent activity found in Activity_XE_LRQ. The heartbeat_id column is back-filled after the Activity_Heartbeat row is created for the same cycle. The Control Center Server Health page reads this table for the incident timeline and root cause analysis display.

**Automated Root Cause Evidence:** [sort:1] The correlated_* columns (source, query, user, database, duration_sec, count) capture the top concurrent long-running query and total LRQ count within the correlation window. The correlated_source field identifies known process patterns: Redgate Monitoring, xFACts XE Collection, Azure Data Sync, BIDATA Builds, PROCESSES Jobs. This transforms a threshold alert from "PLE crashed" into "PLE crashed and here are the three queries that were running" without manual investigation.

**Cross-Server HADR Correlation:** [sort:2] For HADR incidents, the secondary_server column identifies the AG partner, and the correlated_* columns contain activity from that secondary server — not the primary where the wait was detected. This reflects the causal relationship: heavy workload on the secondary causes synchronous commit delays on the primary. The AG partner is dynamically determined from ServerRegistry using the ag_cluster_name field.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| incident_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the incident |
| incident_type_code | varchar(30) | No | — | FK to Activity_IncidentType (e.g., PLE_CRISIS, HADR_SPIKE) |
| detected_dttm | datetime2 | No | — | When the incident was detected (matches snapshot_dttm) |
| severity | varchar(20) | No | — | WARNING or CRITICAL |
| primary_server | varchar(128) | No | — | Server where the threshold was crossed |
| primary_metric_name | varchar(100) | No | — | Metric that crossed threshold (e.g., ple_seconds, hadr_sync_commit_delta_ms) |
| primary_metric_value | varchar(50) | No | — | Value that crossed the threshold |
| secondary_server | varchar(128) | Yes | — | AG partner server (for HADR incidents) or NULL |
| correlation_window_start | datetime2 | Yes | — | Start of the time window searched for correlated activity |
| correlation_window_end | datetime2 | Yes | — | End of the correlation window (typically = detected_dttm) |
| correlated_source | varchar(100) | Yes | — | Identified source pattern (e.g., Azure Data Sync, Redgate Monitoring) |
| correlated_query | varchar(MAX) | Yes | — | Text of the top correlated query (truncated) |
| correlated_user | varchar(128) | Yes | — | Username running the correlated query |
| correlated_database | varchar(128) | Yes | — | Database context of the correlated query |
| correlated_duration_sec | int | Yes | — | Duration of the top correlated query in seconds |
| correlated_count | int | Yes | — | Total number of LRQs found in the correlation window |
| summary | varchar(1000) | Yes | — | Auto-generated human-readable summary of the incident |
| acknowledged_by | varchar(128) | Yes | — | Who reviewed this incident |
| acknowledged_dttm | datetime2 | Yes | — | When the incident was reviewed |
| notes | varchar(1000) | Yes | — | Manual notes about the incident |
| heartbeat_id | bigint | Yes | — | FK to Activity_Heartbeat linking incident to its collection cycle |
| created_dttm | datetime | No | getdate() | When the incident was logged |

  - **PK_Activity_IncidentLog** (CLUSTERED): incident_id -- PRIMARY KEY
  - **IX_Activity_IncidentLog_ServerTime** (NONCLUSTERED): primary_server, detected_dttm
  - **IX_Activity_IncidentLog_Type** (NONCLUSTERED): incident_type_code, detected_dttm [includes: severity, primary_server, correlated_source]
  - **IX_Activity_IncidentLog_Unacknowledged** (NONCLUSTERED): acknowledged_dttm

**Check Constraints:**

  - **CK_Activity_IncidentLog_Severity**: `([severity]='CRITICAL' OR [severity]='WARNING')`

**Foreign Keys:**

  - **FK_Activity_IncidentLog_IncidentType**: incident_type_code -> ServerOps.Activity_IncidentType.incident_type_code

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| severity | WARNING | Threshold crossing at warning level. Logged for PLE_WARNING, HADR_SPIKE, MEMORY_GRANTS_PENDING. Indicates the metric is outside normal range but not at crisis level. | 1 |
| severity | CRITICAL | Threshold crossing at critical level. Logged for PLE_CRISIS, HADR_SPIKE_CRITICAL. Indicates immediate attention may be needed. | 2 |

**Recent Incidents** [sort:1]

```sql
SELECT 
    detected_dttm,
    incident_type_code,
    severity,
    primary_server,
    correlated_source,
    summary
FROM ServerOps.Activity_IncidentLog
WHERE detected_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY detected_dttm DESC;
```

**Incidents by Correlated Source** [sort:2]

```sql
SELECT 
    correlated_source,
    COUNT(*) AS incident_count,
    SUM(CASE WHEN severity = 'CRITICAL' THEN 1 ELSE 0 END) AS critical_count,
    MIN(detected_dttm) AS first_incident,
    MAX(detected_dttm) AS last_incident
FROM ServerOps.Activity_IncidentLog
WHERE correlated_source IS NOT NULL
GROUP BY correlated_source
ORDER BY incident_count DESC;
```

**Incident Timeline for Specific Server** [sort:3]

```sql
SELECT 
    detected_dttm,
    incident_type_code,
    primary_metric_name,
    primary_metric_value,
    correlated_source,
    correlated_count AS lrqs_in_window
FROM ServerOps.Activity_IncidentLog
WHERE primary_server = 'DM-PROD-DB'
  AND detected_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY detected_dttm DESC;
```

**HADR Incidents with Secondary Correlation** [sort:4]

```sql
SELECT 
    detected_dttm,
    primary_server,
    secondary_server,
    CAST(primary_metric_value AS BIGINT) / 1000 AS hadr_delta_sec,
    correlated_source,
    correlated_user,
    correlated_database,
    correlated_duration_sec,
    correlated_count AS total_lrqs
FROM ServerOps.Activity_IncidentLog
WHERE incident_type_code LIKE 'HADR%'
ORDER BY detected_dttm DESC;
```

**Daily Incident Summary** [sort:5]

```sql
SELECT 
    CAST(detected_dttm AS DATE) AS day,
    incident_type_code,
    COUNT(*) AS count,
    COUNT(DISTINCT primary_server) AS servers_affected
FROM ServerOps.Activity_IncidentLog
GROUP BY CAST(detected_dttm AS DATE), incident_type_code
ORDER BY day DESC, count DESC;
```


### Activity_IncidentType

Reference table defining incident types with default severity levels, correlation windows, and correlation targets for the incident detection system.

**Data Flow:** Pre-populated reference table. sp_Activity_CorrelateIncidents reads this table to get the correlation_window_min for each incident type when performing concurrent activity lookups. The incident_type_code values are used as foreign key references in Activity_IncidentLog. New incident types require both a row in this table and corresponding detection logic in the procedure.

**Code-Based Primary Key:** [sort:1] Uses incident_type_code (e.g., PLE_CRISIS, HADR_SPIKE) as the primary key rather than an identity column. This makes Activity_IncidentLog entries self-documenting — the incident_type_code value conveys meaning without requiring a join to this reference table for basic queries.

**Correlation Target Controls Cross-Server Lookup:** [sort:2] The correlation_target column (SELF, SECONDARY, or NULL) tells sp_Activity_CorrelateIncidents where to search for concurrent long-running queries. SELF searches Activity_XE_LRQ on the same server (used for PLE issues caused by local queries). SECONDARY searches the AG partner (used for HADR spikes caused by workload on the secondary). NULL skips correlation entirely.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| incident_type_code | varchar(30) | No | — | Unique code identifying the incident type (e.g., PLE_CRISIS, HADR_SPIKE) |
| incident_type_name | varchar(100) | No | — | Human-readable name for display |
| description | varchar(500) | Yes | — | Detailed explanation of what this incident type represents |
| default_severity | varchar(20) | No | — | Default severity level: WARNING or CRITICAL |
| correlation_window_min | int | No | 5 | Minutes to look back when correlating concurrent activity |
| correlation_target | varchar(20) | Yes | — | Where to look for correlated activity: SELF, SECONDARY, or NULL |
| is_active | bit | No | 1 | Whether this incident type is currently being detected |
| created_dttm | datetime | No | getdate() | When the incident type was created |

  - **PK_Activity_IncidentType** (CLUSTERED): incident_type_code -- PRIMARY KEY

**Check Constraints:**

  - **CK_Activity_IncidentType_Severity**: `([default_severity]='CRITICAL' OR [default_severity]='WARNING')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| default_severity | WARNING | Threshold crossing at warning level. Indicates a metric is outside normal range but not at crisis level. Used for PLE_WARNING, HADR_SPIKE, MEMORY_GRANTS_PENDING. | 1 |
| default_severity | CRITICAL | Threshold crossing at critical level. Indicates immediate attention may be needed. Used for PLE_CRISIS, HADR_SPIKE_CRITICAL. | 2 |


### Activity_XE_AGHealth

Stores events from the AlwaysOn_health Extended Events session, capturing availability group state changes, replica health transitions, and synchronization events for AG monitoring.

**Data Flow:** Collect-XEEvents.ps1 reads events from the AlwaysOn_health XE session on AG servers only (collected in a separate Step 4 loop targeting only DM-PROD-DB and DM-PROD-REP). Parses via Parse-AGHealthEvent and inserts individual events. The raw XML is optionally retained based on GlobalConfig aghealth_retain_raw_xml. The Control Center Server Health page reads this table for AG state change history and failover timeline.

**Separate Collection Step for AG Servers:** [sort:1] AlwaysOn_health is collected in Step 4 of Collect-XEEvents.ps1, separate from the Step 3 loop that processes custom xFACts sessions. This is because AlwaysOn_health is a Microsoft built-in session that only exists on servers participating in an Availability Group. The server list for Step 4 is queried separately, targeting only the known AG servers.

**Configurable Raw XML Retention:** [sort:2] Same pattern as Activity_XE_BlockedProcess. The raw_event_xml column is populated based on GlobalConfig aghealth_retain_raw_xml. Parsed fields cover the common AG state change attributes; raw XML is needed only for unusual event types or deep-dive analysis.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| event_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the event |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| event_timestamp | datetime2 | No | — | When the event occurred |
| event_type | varchar(50) | No | — | Event name from AlwaysOn_health |
| session_name | varchar(128) | No | — | Source XE session name |
| previous_state | varchar(50) | Yes | — | Previous state before transition |
| current_state | varchar(50) | Yes | — | Current state after transition |
| availability_group_name | varchar(128) | Yes | — | Availability group name |
| availability_replica_name | varchar(128) | Yes | — | Replica server name |
| database_name | sysname | Yes | — | Database name (for database-level events) |
| error_number | bigint | Yes | — | SQL Server error number |
| error_severity | int | Yes | — | Error severity level |
| error_message | nvarchar(MAX) | Yes | — | Full error message text |
| ddl_action | varchar(50) | Yes | — | DDL action performed (CREATE, ALTER, DROP) |
| ddl_phase | varchar(50) | Yes | — | DDL phase (START, COMMIT, ROLLBACK) |
| ddl_statement | nvarchar(MAX) | Yes | — | Full DDL statement text |
| raw_event_xml | xml | Yes | — | Complete event XML for forensic analysis |
| collected_dttm | datetime | No | getdate() | When the event was imported into xFACts |
| source_file | varchar(500) | Yes | — | XE file the event was read from |
| source_offset | bigint | Yes | — | Byte offset within the source file |
| alert_sent | bit | No | 0 | Whether an alert has been sent for this event |
| alert_sent_dttm | datetime | Yes | — | When the alert was sent |

  - **PK_Activity_XE_AGHealth** (CLUSTERED): event_id -- PRIMARY KEY
  - **IX_Activity_XE_AGHealth_AlertPending** (NONCLUSTERED): alert_sent, event_timestamp
  - **IX_Activity_XE_AGHealth_ErrorNumber** (NONCLUSTERED): error_number, event_timestamp
  - **IX_Activity_XE_AGHealth_EventType** (NONCLUSTERED): event_type, event_timestamp
  - **IX_Activity_XE_AGHealth_Timestamp** (NONCLUSTERED): server_id, event_timestamp

**Foreign Keys:**

  - **FK_Activity_XE_AGHealth_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Recent AG State Changes** [sort:1]

```sql
SELECT 
    server_name,
    event_timestamp,
    event_type,
    ag_name,
    replica_name,
    previous_state,
    current_state
FROM ServerOps.Activity_XE_AGHealth
WHERE event_type = 'availability_replica_state_change'
  AND event_timestamp >= DATEADD(DAY, -7, GETDATE())
ORDER BY event_timestamp DESC;
```

**Failover Events** [sort:2]

```sql
SELECT 
    server_name,
    event_timestamp,
    event_type,
    ag_name,
    replica_name,
    raw_event_xml
FROM ServerOps.Activity_XE_AGHealth
WHERE event_type IN ('availability_group_lease_expired', 
                     'availability_replica_automatic_failover_validation')
  AND event_timestamp >= DATEADD(DAY, -30, GETDATE())
ORDER BY event_timestamp DESC;
```

**AG Event Summary by Type** [sort:3]

```sql
SELECT 
    event_type,
    COUNT(*) AS event_count,
    MIN(event_timestamp) AS first_occurrence,
    MAX(event_timestamp) AS last_occurrence
FROM ServerOps.Activity_XE_AGHealth
WHERE event_timestamp >= DATEADD(DAY, -30, GETDATE())
GROUP BY event_type
ORDER BY event_count DESC;
```


### Activity_XE_BlockedProcess

Stores blocked_process_report events collected from Extended Events sessions, capturing both the blocked process (victim) and blocking process (culprit) details for blocking analysis.

**Data Flow:** Collect-XEEvents.ps1 reads events from the xFACts_BlockedProcess XE session on each monitored server, parses the XML event data via Parse-BlockedProcessEvent, and inserts individual events. The raw XML is optionally retained based on GlobalConfig blocked_process_retain_raw_xml setting. The Control Center Server Health page reads this table for blocking event timelines and blocker/blocked session detail.

**Configurable Raw XML Retention:** [sort:1] The raw_event_xml column is populated or set to NULL based on the GlobalConfig setting blocked_process_retain_raw_xml. Parsing extracts the key fields (blocking/blocked session IDs, wait time, resources, query text) into typed columns for efficient querying. The raw XML is only needed for deep-dive analysis of complex blocking scenarios and consumes significant storage, so retention is configurable.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| event_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the event |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| event_timestamp | datetime2 | No | — | When the blocking event occurred |
| event_type | varchar(50) | No | — | Always 'blocked_process_report' |
| session_name | varchar(128) | No | — | Always 'xFACts_BlockedProcess' |
| blocked_spid | int | Yes | — | Session ID of the blocked process |
| blocked_database | sysname | Yes | — | Database context of blocked process |
| blocked_login | nvarchar(128) | Yes | — | Login name of blocked process |
| blocked_client_app | nvarchar(256) | Yes | — | Application name from connection string |
| blocked_host_name | nvarchar(128) | Yes | — | Client machine name |
| blocked_wait_time_ms | bigint | Yes | — | How long the process has been blocked (milliseconds) |
| blocked_wait_type | nvarchar(60) | Yes | — | Type of wait (e.g., LCK_M_X, LCK_M_S) |
| blocked_wait_resource | nvarchar(256) | Yes | — | Resource being waited on |
| blocked_query_text | nvarchar(MAX) | Yes | — | Query text of the blocked process |
| blocked_by_spid | int | Yes | — | Session ID of the blocking process |
| blocked_by_database | sysname | Yes | — | Database context of blocking process |
| blocked_by_login | nvarchar(128) | Yes | — | Login name of blocking process |
| blocked_by_client_app | nvarchar(256) | Yes | — | Application name from connection string |
| blocked_by_host_name | nvarchar(128) | Yes | — | Client machine name |
| blocked_by_status | nvarchar(30) | Yes | — | Status of blocking process (running, sleeping, suspended) |
| blocked_by_query_text | nvarchar(MAX) | Yes | — | Query text of the blocking process |
| raw_event_xml | xml | Yes | — | Complete event XML for forensic analysis (controlled by config) |
| collected_dttm | datetime | No | getdate() | When the event was imported into xFACts |
| source_file | varchar(500) | Yes | — | XE file the event was read from |
| source_offset | bigint | Yes | — | Byte offset within the source file |
| alert_sent | bit | No | 0 | Whether an alert has been sent for this event |
| alert_sent_dttm | datetime | Yes | — | When the alert was sent |

  - **PK_Activity_XE_BlockedProcess** (CLUSTERED): event_id -- PRIMARY KEY
  - **IX_Activity_XE_BlockedProcess_AlertPending** (NONCLUSTERED): alert_sent, event_timestamp
  - **IX_Activity_XE_BlockedProcess_BlockedBySPID** (NONCLUSTERED): blocked_by_spid, event_timestamp
  - **IX_Activity_XE_BlockedProcess_Timestamp** (NONCLUSTERED): server_id, event_timestamp [includes: server_name, blocked_database, blocked_wait_time_ms]

**Foreign Keys:**

  - **FK_Activity_XE_BlockedProcess_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Recent Blocking Events** [sort:1] -- Last 24 hours of blocking events

```sql
-- Last 24 hours of blocking events
SELECT 
    server_name,
    event_timestamp,
    blocked_spid,
    blocked_login,
    blocked_wait_time_ms / 1000 AS wait_seconds,
    blocked_by_spid,
    blocked_by_login,
    blocked_by_status,
    LEFT(blocked_query_text, 100) AS blocked_query_preview,
    LEFT(blocked_by_query_text, 100) AS blocker_query_preview
FROM ServerOps.Activity_XE_BlockedProcess
WHERE event_timestamp >= DATEADD(HOUR, -24, GETDATE())
ORDER BY event_timestamp DESC;
```

**Blocking Summary by Blocker** [sort:2] -- Who causes the most blocking?

```sql
-- Who causes the most blocking?
SELECT 
    server_name,
    blocked_by_login,
    blocked_by_client_app,
    COUNT(*) AS blocking_events,
    AVG(blocked_wait_time_ms) / 1000 AS avg_wait_seconds,
    MAX(blocked_wait_time_ms) / 1000 AS max_wait_seconds
FROM ServerOps.Activity_XE_BlockedProcess
WHERE event_timestamp >= DATEADD(DAY, -7, GETDATE())
GROUP BY server_name, blocked_by_login, blocked_by_client_app
ORDER BY blocking_events DESC;
```

**Longest Blocking Events** [sort:3] -- Top 10 longest blocking events

```sql
-- Top 10 longest blocking events
SELECT TOP 10
    server_name,
    event_timestamp,
    blocked_wait_time_ms / 1000 AS wait_seconds,
    blocked_login,
    blocked_by_login,
    blocked_query_text,
    blocked_by_query_text
FROM ServerOps.Activity_XE_BlockedProcess
ORDER BY blocked_wait_time_ms DESC;
```


### Activity_XE_CollectionState

Tracks Extended Events collection progress for each server/session combination, enabling incremental event collection and preventing duplicate imports.

**Data Flow:** Collect-XEEvents.ps1 reads this table at the start of each session collection to get the last file_offset, then updates it via MERGE after processing events. One row per server/session combination. The MERGE pattern auto-creates rows for newly enrolled servers or sessions. The Control Center Server Health page reads this table for collection health indicators showing per-session status and event counts.

**Incremental Collection via File Offset:** [sort:1] XE sessions write to rolling .xel files. The last_file_name and last_file_offset columns track exactly where the previous collection stopped. sys.fn_xe_file_target_read_file accepts these as parameters to return only events after that position. This makes each collection cycle incremental — no duplicate detection needed, no full file re-reads. A NULL offset triggers a full initial collection.

**MERGE for Auto-Enrollment:** [sort:2] The script uses MERGE (not INSERT/UPDATE) when updating collection state. This automatically creates a new row when a server or session is encountered for the first time, eliminating the need for a separate enrollment step. When a new server is added to ServerRegistry with serverops_activity_enabled = 1, collection state rows are created on the first collection cycle.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| state_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the state record |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| session_name | varchar(128) | No | — | XE session name (e.g., xFACts_LongQueries, xFACts_BlockedProcess) |
| last_file_name | varchar(500) | Yes | — | Full path of the last .xel file processed |
| first_file_offset | bigint | Yes | — | Byte offset at start of most recent collection |
| last_file_offset | bigint | Yes | — | Byte offset at end of most recent collection |
| last_collection_dttm | datetime | Yes | — | When the last collection completed |
| last_collection_status | varchar(20) | Yes | — | Result: SUCCESS, FAILED, PARTIAL, NO_DATA |
| events_collected | int | Yes | — | Number of events imported in last collection |
| created_dttm | datetime | No | getdate() | When the state record was created |
| created_by | varchar(100) | No | suser_sname() | Who created the record |
| modified_dttm | datetime | Yes | — | When the record was last updated |
| modified_by | varchar(100) | Yes | — | Who last updated the record |

  - **PK_Activity_XE_CollectionState** (CLUSTERED): state_id -- PRIMARY KEY
  - **IX_Activity_XE_CollectionState_ServerID** (NONCLUSTERED): server_id [includes: session_name, last_collection_dttm, last_collection_status]
  - **UQ_Activity_XE_CollectionState_ServerSession** (NONCLUSTERED): server_id, session_name

**Check Constraints:**

  - **CK_Activity_XE_CollectionState_Status**: `([last_collection_status]='NO_DATA' OR [last_collection_status]='PARTIAL' OR [last_collection_status]='FAILED' OR [last_collection_status]='SUCCESS')`

**Foreign Keys:**

  - **FK_Activity_XE_CollectionState_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| last_collection_status | SUCCESS | Events were found and successfully processed. The file offset was advanced. | 1 |
| last_collection_status | NO_DATA | Collection executed successfully but no new events were found since the last offset. The file offset remains unchanged. This is normal during quiet periods. | 2 |
| last_collection_status | FAILED | Collection encountered an error. Possible causes: server unreachable, XE session not running, file path resolution failure, or permission issue. The file offset remains unchanged so the next cycle will retry from the same position. | 3 |
| last_collection_status | PARTIAL | Reserved for future use. Intended for scenarios where some events were processed but collection was interrupted before completion. | 4 |

**View Current State for All Servers** [sort:1]

```sql
SELECT 
    sr.server_name,
    cs.session_name,
    cs.last_collection_dttm,
    cs.last_collection_status,
    cs.events_collected,
    cs.last_file_offset
FROM ServerOps.Activity_XE_CollectionState cs
JOIN dbo.ServerRegistry sr ON cs.server_id = sr.server_id
ORDER BY sr.server_name, cs.session_name;
```

**Find Servers Not Collecting** [sort:2] -- Servers with no collection in last hour

```sql
-- Servers with no collection in last hour
SELECT 
    sr.server_name,
    cs.session_name,
    cs.last_collection_dttm,
    DATEDIFF(MINUTE, cs.last_collection_dttm, GETDATE()) AS minutes_since_collection
FROM ServerOps.Activity_XE_CollectionState cs
JOIN dbo.ServerRegistry sr ON cs.server_id = sr.server_id
WHERE cs.last_collection_dttm < DATEADD(HOUR, -1, GETDATE())
   OR cs.last_collection_dttm IS NULL
ORDER BY cs.last_collection_dttm;
```

**Find Failed Collections** [sort:3]

```sql
SELECT 
    sr.server_name,
    cs.session_name,
    cs.last_collection_dttm,
    cs.last_collection_status
FROM ServerOps.Activity_XE_CollectionState cs
JOIN dbo.ServerRegistry sr ON cs.server_id = sr.server_id
WHERE cs.last_collection_status = 'FAILED'
ORDER BY cs.last_collection_dttm DESC;
```


### Activity_XE_Deadlock

Stores xml_deadlock_report events collected from Extended Events sessions, capturing both the victim (killed process) and survivor (winning process) details for deadlock analysis.

**Data Flow:** Collect-XEEvents.ps1 reads events from the xFACts_Deadlock XE session on each monitored server, parses the XML deadlock graph via Parse-DeadlockEvent, and inserts individual events. The full deadlock graph XML is always retained for analysis. The Control Center Server Health page reads this table for deadlock event history and victim/survivor details.

**Deadlock Graph Parsing:** [sort:1] The parse function extracts both sides of the deadlock (victim and survivor) into separate column sets: process IDs, query text, login names, application names, lock resources, and wait types. The full deadlock graph XML is always stored in raw_event_xml because deadlock analysis often requires examining the complete resource dependency chain, which cannot be fully represented in flat columns.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| event_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the event |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| event_timestamp | datetime2 | No | — | When the deadlock was detected |
| event_type | varchar(50) | No | — | Always 'xml_deadlock_report' |
| session_name | varchar(128) | No | — | Always 'xFACts_Deadlock' |
| process_count | int | Yes | — | Total number of processes involved in the deadlock |
| victim_count | int | Yes | — | Number of victims (processes killed). Values > 1 indicate complex/parallel deadlocks |
| deadlock_category | varchar(20) | Yes | — | STANDARD (single victim) or COMPLEX (multi-victim) |
| victim_spid | int | Yes | — | Session ID of the process that was killed |
| victim_database | sysname | Yes | — | Database context of victim process |
| victim_login | nvarchar(128) | Yes | — | Login name of victim process |
| victim_client_app | nvarchar(256) | Yes | — | Application name from connection string |
| victim_host_name | nvarchar(128) | Yes | — | Client machine name |
| victim_query_text | nvarchar(MAX) | Yes | — | Query text that was killed |
| survivor_spid | int | Yes | — | Session ID of the process that survived |
| survivor_database | sysname | Yes | — | Database context of survivor process |
| survivor_login | nvarchar(128) | Yes | — | Login name of survivor process |
| survivor_client_app | nvarchar(256) | Yes | — | Application name from connection string |
| survivor_host_name | nvarchar(128) | Yes | — | Client machine name |
| survivor_query_text | nvarchar(MAX) | Yes | — | Query text that completed |
| raw_deadlock_xml | xml | Yes | — | Complete deadlock graph for forensic analysis |
| collected_dttm | datetime | No | getdate() | When the event was imported into xFACts |
| source_file | varchar(500) | Yes | — | XE file the event was read from |
| source_offset | bigint | Yes | — | Byte offset within the source file |
| alert_sent | bit | No | 0 | Whether an alert has been sent for this event |
| alert_sent_dttm | datetime | Yes | — | When the alert was sent |

  - **PK_Activity_XE_Deadlock** (CLUSTERED): event_id -- PRIMARY KEY
  - **IX_Activity_XE_Deadlock_AlertPending** (NONCLUSTERED): alert_sent, event_timestamp
  - **IX_Activity_XE_Deadlock_Timestamp** (NONCLUSTERED): server_id, event_timestamp
  - **IX_Activity_XE_Deadlock_VictimLogin** (NONCLUSTERED): victim_login, event_timestamp

**Foreign Keys:**

  - **FK_Activity_XE_Deadlock_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Recent Deadlocks** [sort:1] -- Last 30 days of deadlocks

```sql
-- Last 30 days of deadlocks
SELECT 
    server_name,
    event_timestamp,
    victim_spid,
    victim_login,
    victim_database,
    survivor_spid,
    survivor_login,
    process_count,
    LEFT(victim_query_text, 100) AS victim_query_preview,
    LEFT(survivor_query_text, 100) AS survivor_query_preview
FROM ServerOps.Activity_XE_Deadlock
WHERE event_timestamp >= DATEADD(DAY, -30, GETDATE())
ORDER BY event_timestamp DESC;
```

**Deadlock Frequency by Database** [sort:2] -- Which databases have the most deadlocks?

```sql
-- Which databases have the most deadlocks?
SELECT 
    server_name,
    victim_database,
    COUNT(*) AS deadlock_count,
    MIN(event_timestamp) AS first_deadlock,
    MAX(event_timestamp) AS last_deadlock
FROM ServerOps.Activity_XE_Deadlock
WHERE event_timestamp >= DATEADD(DAY, -30, GETDATE())
GROUP BY server_name, victim_database
ORDER BY deadlock_count DESC;
```

**View Full Deadlock Graph** [sort:3] -- Get complete deadlock XML for analysis

```sql
-- Get complete deadlock XML for analysis
SELECT 
    event_id,
    event_timestamp,
    victim_login,
    survivor_login,
    raw_deadlock_xml
FROM ServerOps.Activity_XE_Deadlock
WHERE event_id = @EventID;
```


### Activity_XE_LinkedServerIn

Aggregated storage for inbound linked server queries captured from Extended Events sessions, tracking queries received FROM other servers via linked server connections. Similar queries are grouped and metrics accumulated for efficient storage and analysis.

**Data Flow:** Collect-XEEvents.ps1 reads events from the xFACts_LS_Inbound XE session on each monitored server, parses via Parse-LSInboundEvent, aggregates via Aggregate-LSEvents, and inserts aggregated records via Insert-LSInboundEventAggregated. The Control Center Server Health page reads this table for inbound linked server traffic analysis.

**Event Aggregation:** [sort:1] Unlike other XE tables that store individual events, linked server events are aggregated before insertion. The Aggregate-LSEvents function groups parsed events by server, source server, database, and time window, then stores execution count, total/min/max/avg duration, and total rows. This reduces storage volume significantly for high-frequency linked server traffic while preserving the metrics needed for performance analysis.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| event_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the aggregated event group |
| server_id | int | No | — | FK to dbo.ServerRegistry (local server receiving query) |
| server_name | varchar(128) | No | — | Local server name receiving the query |
| session_id | int | Yes | — | Local session ID (SPID) |
| client_pid | int | Yes | — | Client process ID |
| client_hostname | varchar(128) | Yes | — | Client machine name initiating the linked server query |
| client_app_name | varchar(256) | Yes | — | Application name from connection string |
| database_name | varchar(128) | Yes | — | Database where query executed |
| username | varchar(128) | Yes | — | Login executing the query |
| nt_username | varchar(128) | Yes | — | Windows username |
| sql_text | nvarchar(MAX) | Yes | — | Query text received (from most recent execution) |
| query_hash | varchar(128) | Yes | — | Hash identifying query shape (ignores literals) |
| query_plan_hash | varchar(128) | Yes | — | Hash identifying execution plan |
| execution_count | int | No | 1 | Number of executions aggregated into this row |
| first_event_timestamp | datetime2 | No | — | Timestamp of first execution in aggregation window |
| last_event_timestamp | datetime2 | No | — | Timestamp of most recent execution |
| total_duration_ms | bigint | No | 0 | Sum of duration across all executions |
| max_duration_ms | bigint | No | 0 | Maximum duration of any single execution |
| total_cpu_time_ms | bigint | Yes | — | Sum of CPU time across all executions |
| total_logical_reads | bigint | Yes | — | Sum of logical reads across all executions |
| total_physical_reads | bigint | Yes | — | Sum of physical reads across all executions |
| total_writes | bigint | Yes | — | Sum of writes across all executions |
| total_row_count | bigint | Yes | — | Sum of rows affected across all executions |
| session_name | varchar(128) | No | — | Source XE session name (xFACts_LS_Inbound) |
| collected_dttm | datetime | No | getdate() | When the row was created or last updated |

  - **PK_Activity_XE_LinkedServerIn** (CLUSTERED): event_id -- PRIMARY KEY
  - **IX_Activity_XE_LinkedServerIn_ClientHostname** (NONCLUSTERED): client_hostname, first_event_timestamp
  - **IX_Activity_XE_LinkedServerIn_CollectedDttm** (NONCLUSTERED): collected_dttm
  - **IX_Activity_XE_LinkedServerIn_ServerTimestamp** (NONCLUSTERED): server_id, first_event_timestamp
  - **IX_Activity_XE_LinkedServerIn_SessionId** (NONCLUSTERED): session_id, server_id

**Foreign Keys:**

  - **FK_Activity_XE_LinkedServerIn_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Recent Inbound Linked Server Activity** [sort:1]

```sql
SELECT 
    server_name AS local_server,
    client_hostname AS source_client,
    last_event_timestamp,
    execution_count,
    database_name,
    total_duration_ms / 1000.0 AS total_duration_sec,
    max_duration_ms / 1000.0 AS max_duration_sec,
    LEFT(sql_text, 200) AS sql_preview
FROM ServerOps.Activity_XE_LinkedServerIn
WHERE last_event_timestamp >= DATEADD(HOUR, -24, GETDATE())
ORDER BY last_event_timestamp DESC;
```

**Inbound Query Volume by Client Host** [sort:2]

```sql
SELECT 
    server_name AS local_server,
    client_hostname AS source_client,
    SUM(execution_count) AS total_executions,
    COUNT(*) AS unique_query_patterns,
    SUM(total_duration_ms) / 1000.0 AS total_duration_sec,
    MAX(max_duration_ms) / 1000.0 AS slowest_execution_sec,
    SUM(total_logical_reads) AS total_logical_reads
FROM ServerOps.Activity_XE_LinkedServerIn
WHERE last_event_timestamp >= DATEADD(DAY, -7, GETDATE())
GROUP BY server_name, client_hostname
ORDER BY total_executions DESC;
```

**Slowest Inbound Query Patterns** [sort:3]

```sql
SELECT TOP 20
    server_name AS local_server,
    client_hostname AS source_client,
    execution_count,
    max_duration_ms / 1000.0 AS max_duration_sec,
    total_duration_ms / execution_count / 1000.0 AS avg_duration_sec,
    database_name,
    LEFT(sql_text, 500) AS sql_text
FROM ServerOps.Activity_XE_LinkedServerIn
ORDER BY max_duration_ms DESC;
```

**High-Frequency Query Patterns** [sort:4] -- Find queries executing many times (potential optimization targets)

```sql
-- Find queries executing many times (potential optimization targets)
SELECT TOP 20
    server_name,
    client_hostname,
    execution_count,
    total_duration_ms / execution_count / 1000.0 AS avg_duration_sec,
    total_logical_reads / execution_count AS avg_reads,
    first_event_timestamp,
    last_event_timestamp,
    LEFT(sql_text, 300) AS sql_preview
FROM ServerOps.Activity_XE_LinkedServerIn
WHERE execution_count > 10
ORDER BY execution_count DESC;
```


### Activity_XE_LinkedServerOut

Aggregated storage for outbound linked server queries captured from Extended Events sessions, tracking queries sent TO other servers via linked server connections. Similar queries are grouped and metrics accumulated for efficient storage and analysis.

**Data Flow:** Collect-XEEvents.ps1 reads events from the xFACts_LS_Outbound XE session on each monitored server, parses via Parse-LSOutboundEvent, aggregates via Aggregate-LSEvents, and inserts aggregated records via Insert-LSOutboundEventAggregated. The Control Center Server Health page reads this table for outbound linked server traffic analysis.

**Event Aggregation:** [sort:1] Same aggregation pattern as Activity_XE_LinkedServerIn. Outbound events capture queries that this server sends to other servers via linked server connections (four-part naming, OPENQUERY, OPENROWSET). The aggregation groups by target server, database, and time window.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| event_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the aggregated event group |
| server_id | int | No | — | FK to dbo.ServerRegistry (local server sending query) |
| server_name | varchar(128) | No | — | Local server name sending the query |
| session_id | int | Yes | — | Local session ID (SPID) |
| client_pid | int | Yes | — | Client process ID |
| client_hostname | varchar(128) | Yes | — | Client machine name |
| client_app_name | varchar(256) | Yes | — | Application name from connection string |
| database_name | varchar(128) | Yes | — | Local database where query originated |
| username | varchar(128) | Yes | — | Login executing the query |
| nt_username | varchar(128) | Yes | — | Windows username |
| sql_text | nvarchar(MAX) | Yes | — | Query text sent to remote server (from most recent execution) |
| query_hash | varchar(128) | Yes | — | Hash identifying query shape (ignores literals) |
| query_plan_hash | varchar(128) | Yes | — | Hash identifying execution plan |
| execution_count | int | No | 1 | Number of executions aggregated into this row |
| first_event_timestamp | datetime2 | No | — | Timestamp of first execution in aggregation window |
| last_event_timestamp | datetime2 | No | — | Timestamp of most recent execution |
| total_duration_ms | bigint | No | 0 | Sum of duration across all executions (includes network latency) |
| max_duration_ms | bigint | No | 0 | Maximum duration of any single execution |
| total_cpu_time_ms | bigint | Yes | — | Sum of CPU time across all executions |
| total_logical_reads | bigint | Yes | — | Sum of logical reads across all executions |
| total_physical_reads | bigint | Yes | — | Sum of physical reads across all executions |
| total_writes | bigint | Yes | — | Sum of writes across all executions |
| total_row_count | bigint | Yes | — | Sum of rows affected across all executions |
| session_name | varchar(128) | No | — | Source XE session name (xFACts_LS_Outbound) |
| collected_dttm | datetime | No | getdate() | When the row was created or last updated |

  - **PK_Activity_XE_LinkedServerOut** (CLUSTERED): event_id -- PRIMARY KEY
  - **IX_Activity_XE_LinkedServerOut_CollectedDttm** (NONCLUSTERED): collected_dttm
  - **IX_Activity_XE_LinkedServerOut_ServerTimestamp** (NONCLUSTERED): server_id, first_event_timestamp
  - **IX_Activity_XE_LinkedServerOut_SessionId** (NONCLUSTERED): session_id, server_id
  - **IX_Activity_XE_LinkedServerOut_Username** (NONCLUSTERED): username, first_event_timestamp

**Foreign Keys:**

  - **FK_Activity_XE_LinkedServerOut_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Recent Outbound Linked Server Activity** [sort:1]

```sql
SELECT 
    server_name AS local_server,
    client_hostname,
    client_app_name,
    last_event_timestamp,
    execution_count,
    database_name,
    total_duration_ms / 1000.0 AS total_duration_sec,
    max_duration_ms / 1000.0 AS max_duration_sec,
    LEFT(sql_text, 200) AS sql_preview
FROM ServerOps.Activity_XE_LinkedServerOut
WHERE last_event_timestamp >= DATEADD(HOUR, -24, GETDATE())
ORDER BY last_event_timestamp DESC;
```

**Outbound Query Volume by Application** [sort:2]

```sql
SELECT 
    server_name AS local_server,
    client_app_name,
    SUM(execution_count) AS total_executions,
    COUNT(*) AS unique_query_patterns,
    SUM(total_duration_ms) / 1000.0 AS total_duration_sec,
    MAX(max_duration_ms) / 1000.0 AS slowest_execution_sec,
    SUM(total_logical_reads) AS total_logical_reads
FROM ServerOps.Activity_XE_LinkedServerOut
WHERE last_event_timestamp >= DATEADD(DAY, -7, GETDATE())
GROUP BY server_name, client_app_name
ORDER BY total_executions DESC;
```

**Slowest Outbound Query Patterns** [sort:3]

```sql
SELECT TOP 20
    server_name AS local_server,
    username,
    client_app_name,
    execution_count,
    max_duration_ms / 1000.0 AS max_duration_sec,
    total_duration_ms / execution_count / 1000.0 AS avg_duration_sec,
    database_name,
    LEFT(sql_text, 500) AS sql_text
FROM ServerOps.Activity_XE_LinkedServerOut
ORDER BY max_duration_ms DESC;
```

**High-Frequency Query Patterns** [sort:4] -- Find queries executing many times (potential optimization targets)

```sql
-- Find queries executing many times (potential optimization targets)
SELECT TOP 20
    server_name,
    client_app_name,
    execution_count,
    total_duration_ms / execution_count / 1000.0 AS avg_duration_sec,
    total_logical_reads / NULLIF(execution_count, 0) AS avg_reads,
    first_event_timestamp,
    last_event_timestamp,
    LEFT(sql_text, 300) AS sql_preview
FROM ServerOps.Activity_XE_LinkedServerOut
WHERE execution_count > 10
ORDER BY execution_count DESC;
```

**Outbound Activity by User** [sort:5]

```sql
SELECT 
    server_name,
    username,
    nt_username,
    SUM(execution_count) AS total_executions,
    SUM(total_duration_ms) / 1000.0 AS total_duration_sec,
    MAX(max_duration_ms) / 1000.0 AS slowest_execution_sec
FROM ServerOps.Activity_XE_LinkedServerOut
WHERE last_event_timestamp >= DATEADD(DAY, -7, GETDATE())
GROUP BY server_name, username, nt_username
ORDER BY total_executions DESC;
```


### Activity_XE_LRQ

Central repository for long-running queries (LRQ) exceeding the configured duration threshold, captured from Extended Events sessions across all monitored servers.

**Data Flow:** Collect-XEEvents.ps1 reads events from the xFACts_LongQueries XE session on each monitored server, parses the XML event data via Parse-LRQEvent, and inserts individual events via Insert-LRQEvent. sp_Activity_CorrelateIncidents reads this table within configurable time windows to find concurrent long-running queries when PLE or HADR threshold crossings are detected — providing automated root cause correlation. sp_DiagnoseServerHealth reads this table for manual investigation. The Control Center Server Health page displays recent long-running queries with duration, database, and user details.

**Primary Correlation Target:** [sort:1] This is the most important table for incident correlation. When sp_Activity_CorrelateIncidents detects a PLE crisis, it searches this table on the same server for heavy queries within the correlation window. When it detects a HADR spike, it searches this table on the AG secondary server — because secondary workload (reporting queries, BIDATA builds, Azure Data Sync) causes HADR_SYNC_COMMIT waits on the primary. The correlation logic identifies known process patterns (Redgate monitoring, xFACts XE collection, Azure Data Sync, BIDATA builds) to provide actionable source attribution.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| event_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the event |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| event_timestamp | datetime2 | No | — | When the query completed (from XE event) |
| event_type | varchar(50) | No | — | XE event type: sql_statement_completed, sql_batch_completed, rpc_completed |
| session_name | varchar(128) | No | — | Source XE session name |
| database_name | varchar(128) | Yes | — | Database where query executed |
| username | varchar(128) | Yes | — | Login that executed the query |
| client_hostname | varchar(128) | Yes | — | Client machine name |
| client_app_name | varchar(256) | Yes | — | Application name from connection string |
| session_id | int | Yes | — | SQL Server session ID (SPID) |
| duration_ms | bigint | No | — | Total duration in milliseconds |
| cpu_time_ms | bigint | Yes | — | CPU time consumed in milliseconds |
| logical_reads | bigint | Yes | — | Pages read from buffer cache |
| physical_reads | bigint | Yes | — | Pages read from disk |
| writes | bigint | Yes | — | Pages written |
| row_count | bigint | Yes | — | Rows affected or returned |
| sql_text | nvarchar(MAX) | Yes | — | Full query text |
| query_hash | varbinary(8) | Yes | — | Hash identifying query shape (ignores literals) |
| query_plan_hash | varbinary(8) | Yes | — | Hash identifying execution plan |
| collected_dttm | datetime | No | getdate() | When the event was imported to xFACts |
| source_file | varchar(500) | Yes | — | XE file path the event was read from |
| source_offset | bigint | Yes | — | Byte offset in source file |
| alert_sent | bit | No | 0 | Whether a Teams alert was sent for this event |
| alert_sent_dttm | datetime | Yes | — | When the alert was sent |

  - **PK_ServerOps_Activity_XE_LRQ** (CLUSTERED): event_id -- PRIMARY KEY
  - **IX_Activity_XE_LRQ_AlertPending** (NONCLUSTERED): alert_sent, duration_ms
  - **IX_Activity_XE_LRQ_CollectedDttm** (NONCLUSTERED): collected_dttm
  - **IX_Activity_XE_LRQ_Duration** (NONCLUSTERED): duration_ms [includes: server_id, event_timestamp, database_name]
  - **IX_Activity_XE_LRQ_QueryHash** (NONCLUSTERED): query_hash, server_id
  - **IX_Activity_XE_LRQ_ServerTimestamp** (NONCLUSTERED): server_id, event_timestamp [includes: database_name, duration_ms, username]

**Foreign Keys:**

  - **FK_Activity_XE_LRQ_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Recent Long-Running Queries by Server** [sort:1]

```sql
SELECT 
    server_name,
    event_timestamp,
    database_name,
    duration_ms / 1000.0 AS duration_seconds,
    cpu_time_ms / 1000.0 AS cpu_seconds,
    logical_reads,
    username,
    LEFT(sql_text, 200) AS sql_preview
FROM ServerOps.Activity_XE_LRQ
WHERE event_timestamp >= DATEADD(HOUR, -24, GETDATE())
ORDER BY duration_ms DESC;
```

**Top 10 Slowest Queries Today** [sort:2]

```sql
SELECT TOP 10
    server_name,
    event_timestamp,
    database_name,
    duration_ms / 60000.0 AS duration_minutes,
    username,
    client_app_name,
    LEFT(sql_text, 500) AS sql_preview
FROM ServerOps.Activity_XE_LRQ
WHERE CAST(event_timestamp AS DATE) = CAST(GETDATE() AS DATE)
ORDER BY duration_ms DESC;
```

**Query Pattern Analysis (by Hash)** [sort:3] -- Find recurring slow query patterns

```sql
-- Find recurring slow query patterns
SELECT 
    query_hash,
    COUNT(*) AS execution_count,
    AVG(duration_ms) / 1000.0 AS avg_duration_seconds,
    MAX(duration_ms) / 1000.0 AS max_duration_seconds,
    SUM(duration_ms) / 1000.0 AS total_duration_seconds,
    MIN(event_timestamp) AS first_seen,
    MAX(event_timestamp) AS last_seen
FROM ServerOps.Activity_XE_LRQ
WHERE query_hash IS NOT NULL
  AND event_timestamp >= DATEADD(DAY, -7, GETDATE())
GROUP BY query_hash
HAVING COUNT(*) > 5
ORDER BY SUM(duration_ms) DESC;
```

**Find Queries by User** [sort:4]

```sql
SELECT 
    event_timestamp,
    server_name,
    database_name,
    duration_ms / 1000.0 AS duration_seconds,
    LEFT(sql_text, 300) AS sql_preview
FROM ServerOps.Activity_XE_LRQ
WHERE username = 'crsuser'
  AND event_timestamp >= DATEADD(DAY, -1, GETDATE())
ORDER BY event_timestamp DESC;
```


### Activity_XE_SystemHealth

Stores events from the system_health Extended Events session, capturing security errors, connectivity issues, wait statistics, scheduler health, server diagnostics, and deadlock reports for centralized system health monitoring.

**Data Flow:** Collect-XEEvents.ps1 reads events from the system_health XE session (a Microsoft built-in session) on each monitored server, parses via Parse-SystemHealthEvent, and inserts individual events. This session is processed in the same Step 3 loop as custom sessions. The Control Center Server Health page reads this table for system-level health event history.

**Microsoft Built-In Session:** [sort:1] system_health is a SQL Server built-in XE session that runs by default on every instance. It captures a broad range of system-level events (connectivity issues, scheduler problems, errors). The session file path is resolved differently than custom sessions — via Get-SystemHealthFilePath which queries the default LOG directory rather than looking up a custom session path.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| event_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the event |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| event_timestamp | datetime2 | No | — | When the event occurred |
| event_type | varchar(100) | No | — | Event name from system_health (discriminator) |
| session_id | int | Yes | — | SPID associated with the event (when applicable) |
| error_code | int | Yes | — | Error number for security_error and connectivity events |
| calling_api_name | varchar(128) | Yes | — | API that triggered security errors |
| client_hostname | varchar(128) | Yes | — | Remote host for connectivity events |
| client_app_name | varchar(256) | Yes | — | Application name from connection string |
| os_error | int | Yes | — | OS-level error code |
| login_time_ms | int | Yes | — | Total login time in milliseconds |
| wait_type | varchar(100) | Yes | — | Wait type for wait_info events |
| duration_ms | bigint | Yes | — | Wait duration or component duration in milliseconds |
| signal_duration_ms | bigint | Yes | — | Signal wait portion for wait_info events |
| component_type | varchar(50) | Yes | — | Component for sp_server_diagnostics |
| component_state | varchar(20) | Yes | — | Component state (clean, warning, error) |
| raw_event_xml | xml | No | — | Complete event XML - always stored for system_health |
| source_file | varchar(500) | Yes | — | XE file the event was read from |
| source_offset | bigint | Yes | — | Byte offset within the source file |
| collected_dttm | datetime | No | getdate() | When the event was imported into xFACts |

  - **PK_Activity_XE_SystemHealth** (CLUSTERED): event_id -- PRIMARY KEY
  - **IX_SystemHealth_ClientHost** (NONCLUSTERED): client_hostname, event_timestamp [includes: server_name, error_code, os_error]
  - **IX_SystemHealth_ComponentState** (NONCLUSTERED): component_type, component_state, event_timestamp [includes: server_name]
  - **IX_SystemHealth_ErrorCode** (NONCLUSTERED): error_code, event_timestamp [includes: server_name, event_type, calling_api_name]
  - **IX_SystemHealth_EventType_Timestamp** (NONCLUSTERED): event_type, event_timestamp [includes: server_name, error_code, wait_type]
  - **IX_SystemHealth_Server_Timestamp** (NONCLUSTERED): server_id, event_timestamp [includes: event_type]
  - **IX_SystemHealth_Timestamp** (NONCLUSTERED): event_timestamp [includes: server_name, event_type]
  - **IX_SystemHealth_WaitType** (NONCLUSTERED): wait_type, event_timestamp [includes: server_name, duration_ms, signal_duration_ms]

**Foreign Keys:**

  - **FK_Activity_XE_SystemHealth_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Connectivity Issues** [sort:1]

```sql
SELECT 
    server_name,
    event_timestamp,
    client_hostname,
    error_code,
    os_error
FROM ServerOps.Activity_XE_SystemHealth
WHERE event_type = 'connectivity_ring_buffer_recorded'
  AND event_timestamp >= DATEADD(DAY, -7, GETDATE())
ORDER BY event_timestamp DESC;
```

**Component Health Summary** [sort:2]

```sql
SELECT 
    server_name,
    component_type,
    component_state,
    COUNT(*) AS occurrence_count,
    MAX(event_timestamp) AS last_occurrence
FROM ServerOps.Activity_XE_SystemHealth
WHERE event_type = 'sp_server_diagnostics_component_result'
  AND event_timestamp >= DATEADD(DAY, -1, GETDATE())
GROUP BY server_name, component_type, component_state
ORDER BY server_name, component_type;
```

**Recent Security Errors** [sort:3]

```sql
SELECT 
    server_name,
    event_timestamp,
    error_code,
    calling_api_name,
    session_id
FROM ServerOps.Activity_XE_SystemHealth
WHERE event_type = 'security_error'
  AND event_timestamp >= DATEADD(HOUR, -24, GETDATE())
ORDER BY event_timestamp DESC;
```


### Activity_XE_xFACts

Central repository for all completed query executions from xFACts processes, captured from the xFACts_Tracking Extended Events session across all monitored servers.

**Data Flow:** Collect-XEEvents.ps1 reads events from the xFACts_Tracking XE session on each monitored server, parses via Parse-xFACtsEvent, and inserts individual events. Captures all completed query executions from xFACts processes, complementing the DMV-based footprint snapshots in Activity_DMV_xFACts with event-level detail including actual query text and execution metrics.

**XE vs DMV Self-Monitoring:** [sort:1] Activity_DMV_xFACts captures point-in-time session state (cumulative counters) while Activity_XE_xFACts captures individual completed query events. Together they provide two complementary views of xFACts impact: the DMV table answers "how much total resource has this session used?" while the XE table answers "what specific queries did xFACts run and how long did each take?"

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| event_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the event |
| server_id | int | No | — | FK to dbo.ServerRegistry |
| server_name | varchar(128) | No | — | Denormalized server name for easier querying |
| event_timestamp | datetime2 | No | — | When the query completed (from XE event) |
| event_type | varchar(50) | No | — | XE event type (sql_batch_completed) |
| session_name | varchar(128) | No | — | Source XE session name (xFACts_Tracking) |
| database_name | varchar(128) | Yes | — | Database where query executed |
| username | varchar(128) | Yes | — | Login that executed the query |
| client_app_name | varchar(256) | Yes | — | xFACts component name from connection string ApplicationName |
| session_id | int | Yes | — | SQL Server session ID (SPID) |
| duration_ms | bigint | No | — | Total duration in milliseconds |
| cpu_time_ms | bigint | Yes | — | CPU time consumed in milliseconds (NULL when below resolution threshold) |
| logical_reads | bigint | Yes | — | Pages read from buffer cache |
| physical_reads | bigint | Yes | — | Pages read from disk (typically NULL — xFACts tables stay in cache) |
| writes | bigint | Yes | — | Pages written (NULL for read-only queries) |
| row_count | bigint | Yes | — | Rows affected or returned |
| sql_text | nvarchar(MAX) | Yes | — | Full query text |
| collected_dttm | datetime | No | getdate() | When the event was imported to xFACts |
| source_file | varchar(500) | Yes | — | XE file path the event was read from |
| source_offset | bigint | Yes | — | Byte offset in source file |

  - **PK_Activity_XE_xFACts** (CLUSTERED): event_id -- PRIMARY KEY
  - **IX_Activity_XE_xFACts_AppTimestamp** (NONCLUSTERED): client_app_name, event_timestamp
  - **IX_Activity_XE_xFACts_CollectedDttm** (NONCLUSTERED): collected_dttm
  - **IX_Activity_XE_xFACts_ServerTimestamp** (NONCLUSTERED): server_id, event_timestamp

**Foreign Keys:**

  - **FK_Activity_XE_xFACts_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Query Volume by Process (Last Hour)** [sort:1] -- How many queries did each xFACts component run?

```sql
-- How many queries did each xFACts component run?
SELECT 
    server_name,
    client_app_name,
    COUNT(*) AS query_count,
    SUM(duration_ms) AS total_duration_ms,
    SUM(ISNULL(cpu_time_ms, 0)) AS total_cpu_ms,
    SUM(ISNULL(logical_reads, 0)) AS total_logical_reads,
    SUM(ISNULL(writes, 0)) AS total_writes
FROM ServerOps.Activity_XE_xFACts
WHERE event_timestamp >= DATEADD(HOUR, -1, GETDATE())
GROUP BY server_name, client_app_name
ORDER BY total_logical_reads DESC;
```

**Total xFACts Footprint Per Server (Last 24 Hours)** [sort:2] -- Aggregate impact per server

```sql
-- Aggregate impact per server
SELECT 
    server_name,
    COUNT(*) AS total_queries,
    SUM(duration_ms) AS total_duration_ms,
    SUM(ISNULL(cpu_time_ms, 0)) AS total_cpu_ms,
    SUM(ISNULL(logical_reads, 0)) AS total_logical_reads,
    SUM(ISNULL(physical_reads, 0)) AS total_physical_reads,
    SUM(ISNULL(writes, 0)) AS total_writes
FROM ServerOps.Activity_XE_xFACts
WHERE event_timestamp >= DATEADD(HOUR, -24, GETDATE())
GROUP BY server_name
ORDER BY server_name;
```

**Heaviest Individual Queries** [sort:3] -- Top queries by logical reads

```sql
-- Top queries by logical reads
SELECT TOP 20
    server_name,
    client_app_name,
    event_timestamp,
    duration_ms,
    cpu_time_ms,
    logical_reads,
    LEFT(sql_text, 200) AS sql_preview
FROM ServerOps.Activity_XE_xFACts
WHERE event_timestamp >= DATEADD(HOUR, -24, GETDATE())
ORDER BY logical_reads DESC;
```

**xFACts vs LRQ Crossover** [sort:4] -- How many long-running queries were from xFACts?

```sql
-- How many long-running queries were from xFACts?
SELECT 
    'xFACts' AS source,
    COUNT(*) AS lrq_count,
    AVG(duration_ms) AS avg_duration_ms
FROM ServerOps.Activity_XE_LRQ
WHERE client_app_name LIKE 'xFACts%'
  AND event_timestamp >= DATEADD(HOUR, -24, GETDATE())
UNION ALL
SELECT 
    'Other',
    COUNT(*),
    AVG(duration_ms)
FROM ServerOps.Activity_XE_LRQ
WHERE (client_app_name NOT LIKE 'xFACts%' OR client_app_name IS NULL)
  AND event_timestamp >= DATEADD(HOUR, -24, GETDATE());
```


### Disk_AlertHistory

Audit trail and deduplication table for disk space alerts, tracking when alerts were detected, sent, and resolved.

**Data Flow:** Collect-ServerHealth.ps1 inserts new alert rows when a drive breaches its threshold and no active (is_resolved = 0) alert exists for that server/drive. The script then queues a Jira ticket via Jira.TicketQueue and updates the alert with alerted_dttm and alert_method. When a drive recovers above the resolution threshold (threshold + warning_buffer_pct), the same script sets is_resolved = 1, resolved_dttm, and resolved_by. The Control Center Server Health page reads active alerts for display.

**Two-Level Deduplication:** [sort:1] Alert deduplication operates at two levels. First, Collect-ServerHealth.ps1 checks for an existing active (is_resolved = 0) alert before creating a new one for the same server/drive. Second, the Jira ticket insert uses TriggerType/TriggerValue (ServerOps_DiskSpace / ServerName_DriveLetter) for deduplication at the ticket queue level. A drive can remain below threshold across multiple poll cycles without generating duplicate alerts or tickets.

**Resolution Hysteresis:** [sort:2] Alerts are not auto-resolved the moment a drive crosses back above its threshold. The drive must reach threshold_pct + warning_buffer_pct (from GlobalConfig) before resolution occurs. This prevents alert flapping when drives hover near the threshold. A drive between the threshold and resolution point is in a HOLDING state — the active alert remains but no new alerts are created.

**Automated Space Request Calculation:** [sort:3] When a breach is detected, Collect-ServerHealth.ps1 calculates the disk space needed to bring the drive above threshold_pct + space_request_buffer_pct (from GlobalConfig). The result is rounded up to the nearest 10 GB with a minimum of 10 GB. This calculated value is included in the Jira ticket summary and description, giving IT Ops a specific actionable request rather than a vague alert.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| alert_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the alert |
| server_id | int | No | — | FK to ServerRegistry.server_id |
| alert_type | varchar(30) | No | — | Type of alert (e.g., DISK_SPACE_LOW) |
| alert_key | varchar(100) | No | — | Identifier within alert type (drive letter for disk) |
| alert_details | varchar(500) | Yes | — | Human-readable alert description |
| threshold_value | decimal(10,2) | Yes | — | Threshold that was breached |
| actual_value | decimal(10,2) | Yes | — | Actual value when alert was created |
| detected_dttm | datetime | No | getdate() | When condition was first detected |
| alerted_dttm | datetime | Yes | — | When notification was sent |
| alert_method | varchar(20) | Yes | — | How notification was sent (TEAMS, JIRA) |
| is_resolved | bit | No | 0 | Whether alert condition has cleared |
| resolved_dttm | datetime | Yes | — | When condition cleared |
| resolved_by | varchar(100) | Yes | — | Who/what resolved the alert |

  - **PK_Disk_AlertHistory** (CLUSTERED): alert_id -- PRIMARY KEY
  - **IX_Disk_AlertHistory_Dedup** (NONCLUSTERED): server_id, alert_type, alert_key, is_resolved [includes: detected_dttm, alerted_dttm]
  - **IX_Disk_AlertHistory_Recent** (NONCLUSTERED): detected_dttm [includes: server_id, alert_type, is_resolved]

**Check Constraints:**

  - **CK_Disk_AlertHistory_Method**: `([alert_method] IS NULL OR ([alert_method]='EMAIL' OR [alert_method]='JIRA' OR [alert_method]='TEAMS'))`
  - **CK_Disk_AlertHistory_Type**: `([alert_type]='LONG_RUNNING_QUERY' OR [alert_type]='ERROR_LOG_CRITICAL' OR [alert_type]='DB_OFFLINE' OR [alert_type]='JOB_FAILED' OR [alert_type]='BACKUP_MISSED' OR [alert_type]='DISK_SPACE_LOW')`

**Foreign Keys:**

  - **FK_Disk_AlertHistory_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| alert_type | DISK_SPACE_LOW | Drive free space has fallen below its configured threshold in Disk_ThresholdConfig. This is the only alert type currently used by the Disk component. The check constraint allows additional types (BACKUP_MISSED, JOB_FAILED, DB_OFFLINE, ERROR_LOG_CRITICAL, LONG_RUNNING_QUERY) for future expansion. | 1 |
| alert_method | JIRA | Alert was delivered by creating a Jira ticket via Jira.TicketQueue. This is the primary notification method for disk space breaches — Jira tickets create actionable work items for IT Ops to add storage. | 1 |
| alert_method | TEAMS | Alert was delivered via Teams webhook notification. Not currently used by the Disk component for breach alerts (those use Jira), but available for future use. | 2 |
| alert_method | EMAIL | Alert was delivered via email. Not currently used but allowed by the check constraint for future expansion. | 3 |

**Current Active Alerts** [sort:1]

```sql
SELECT 
    s.server_name,
    a.alert_type,
    a.alert_key,
    a.alert_details,
    a.detected_dttm,
    a.alerted_dttm,
    DATEDIFF(HOUR, a.detected_dttm, GETDATE()) AS hours_active
FROM ServerOps.Disk_AlertHistory a
INNER JOIN dbo.ServerRegistry s ON a.server_id = s.server_id
WHERE a.is_resolved = 0
ORDER BY a.detected_dttm;
```

**Alert History for a Server** [sort:2]

```sql
SELECT 
    alert_type,
    alert_key,
    detected_dttm,
    resolved_dttm,
    DATEDIFF(HOUR, detected_dttm, ISNULL(resolved_dttm, GETDATE())) AS duration_hours,
    resolved_by
FROM ServerOps.Disk_AlertHistory a
INNER JOIN dbo.ServerRegistry s ON a.server_id = s.server_id
WHERE s.server_name = 'DM-PROD-DB'
ORDER BY detected_dttm DESC;
```

**Alert Statistics (Last 30 Days)** [sort:3]

```sql
SELECT 
    s.server_name,
    a.alert_type,
    COUNT(*) AS alert_count,
    AVG(DATEDIFF(HOUR, a.detected_dttm, ISNULL(a.resolved_dttm, GETDATE()))) AS avg_duration_hours
FROM ServerOps.Disk_AlertHistory a
INNER JOIN dbo.ServerRegistry s ON a.server_id = s.server_id
WHERE a.detected_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY s.server_name, a.alert_type
ORDER BY alert_count DESC;
```

  - **Jira Integration for Space Requests**: [sort:1] New breach alerts trigger a direct INSERT into Jira.TicketQueue with project SD, issue type Issue, priority High. The Jira ticket includes calculated space requirements and server/drive details. TriggerType ServerOps_DiskSpace and TriggerValue ServerName_DriveLetter provide deduplication at the Jira queue level.


### Disk_Snapshot

Hourly disk space snapshots from all monitored servers, collected by PowerShell and used for threshold monitoring and historical trending.

**Data Flow:** Collect-ServerHealth.ps1 connects to each monitored server via WinRM/CIM (Win32_LogicalDisk, DriveType=3) and inserts one row per fixed drive per collection cycle. The script evaluates thresholds against in-memory collection data immediately after insert, checking Disk_ThresholdConfig and Disk_AlertHistory for breach detection and auto-resolution. Send-DiskHealthSummary.ps1 reads the latest snapshot per server/drive joined to Disk_ThresholdConfig to build the daily Adaptive Card. The Control Center Server Health page reads this table for current disk status display and historical trend charts.

**PowerShell Collection Over SQL DMVs:** [sort:1] SQL Server DMVs (sys.dm_os_volume_stats) only see drives containing database files. PowerShell via WinRM queries Win32_LogicalDisk which sees all fixed drives on the server, including drives used for backups, logs, or application data that have no database files.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| snapshot_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the snapshot |
| server_id | int | No | — | FK to ServerRegistry.server_id |
| drive_letter | char(1) | No | — | Drive letter (C, D, E, etc.) |
| volume_label | varchar(50) | Yes | — | Windows volume label (if set) |
| total_size_mb | bigint | No | — | Total drive capacity in megabytes |
| free_space_mb | bigint | No | — | Current free space in megabytes |
| percent_free | decimal(5,2) | No | — | Percentage of drive that is free |
| snapshot_dttm | datetime | No | getdate() | When the snapshot was collected |

  - **PK_Disk_Snapshot** (CLUSTERED): snapshot_id -- PRIMARY KEY
  - **IX_Disk_Snapshot_DateTime** (NONCLUSTERED): snapshot_dttm [includes: server_id, drive_letter, percent_free]
  - **IX_Disk_Snapshot_ServerDrive** (NONCLUSTERED): server_id, drive_letter, snapshot_dttm [includes: percent_free, free_space_mb]

**Foreign Keys:**

  - **FK_Disk_Snapshot_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Current Disk Status (Latest Snapshot)** [sort:1]

```sql
SELECT 
    s.server_name,
    d.drive_letter,
    d.volume_label,
    d.total_size_mb / 1024 AS total_gb,
    d.free_space_mb / 1024 AS free_gb,
    d.percent_free,
    t.threshold_pct,
    CASE WHEN d.percent_free < t.threshold_pct THEN 'BELOW' ELSE 'OK' END AS status
FROM ServerOps.Disk_Snapshot d
INNER JOIN dbo.ServerRegistry s ON d.server_id = s.server_id
LEFT JOIN ServerOps.Disk_ThresholdConfig t ON d.server_id = t.server_id AND d.drive_letter = t.drive_letter
WHERE d.snapshot_id IN (
    SELECT MAX(snapshot_id) 
    FROM ServerOps.Disk_Snapshot 
    GROUP BY server_id, drive_letter
)
ORDER BY s.server_name, d.drive_letter;
```

**7-Day Trend for a Specific Drive** [sort:2]

```sql
SELECT 
    CAST(snapshot_dttm AS DATE) AS snapshot_date,
    AVG(percent_free) AS avg_pct_free,
    MIN(percent_free) AS min_pct_free,
    MAX(percent_free) AS max_pct_free
FROM ServerOps.Disk_Snapshot d
INNER JOIN dbo.ServerRegistry s ON d.server_id = s.server_id
WHERE s.server_name = 'DM-PROD-DB'
  AND d.drive_letter = 'D'
  AND d.snapshot_dttm >= DATEADD(DAY, -7, GETDATE())
GROUP BY CAST(snapshot_dttm AS DATE)
ORDER BY snapshot_date;
```

**Find Drives with Declining Free Space** [sort:3] -- Compare today vs 7 days ago

```sql
-- Compare today vs 7 days ago
WITH CurrentSnapshot AS (
    SELECT server_id, drive_letter, percent_free
    FROM ServerOps.Disk_Snapshot
    WHERE snapshot_id IN (
        SELECT MAX(snapshot_id) FROM ServerOps.Disk_Snapshot GROUP BY server_id, drive_letter
    )
),
WeekAgoSnapshot AS (
    SELECT server_id, drive_letter, AVG(percent_free) AS avg_pct_free
    FROM ServerOps.Disk_Snapshot
    WHERE snapshot_dttm BETWEEN DATEADD(DAY, -8, GETDATE()) AND DATEADD(DAY, -7, GETDATE())
    GROUP BY server_id, drive_letter
)
SELECT 
    s.server_name,
    c.drive_letter,
    w.avg_pct_free AS week_ago_pct,
    c.percent_free AS current_pct,
    c.percent_free - w.avg_pct_free AS change_pct
FROM CurrentSnapshot c
INNER JOIN WeekAgoSnapshot w ON c.server_id = w.server_id AND c.drive_letter = w.drive_letter
INNER JOIN dbo.ServerRegistry s ON c.server_id = s.server_id
WHERE c.percent_free < w.avg_pct_free - 2  -- Declined by more than 2%
ORDER BY change_pct;
```

  - **ServerRegistry Enrollment**: [sort:1] server_id references dbo.ServerRegistry. Only servers with is_active = 1 and serverops_disk_enabled = 1 are collected. Server enrollment is the single control point for adding or removing servers from disk monitoring.


### Disk_Status

Single-row dashboard and status tracking table providing at-a-glance disk monitoring health information and poll metrics.

**Data Flow:** Collect-ServerHealth.ps1 updates this table twice per execution cycle: once after disk collection (last_collection_dttm) and once after threshold evaluation (last_poll_dttm, last_poll_status, poll metrics, and daily counters). Send-DiskHealthSummary.ps1 updates last_health_check_dttm and last_health_check_status after generating the daily summary. The Control Center Server Health page reads this table for the Disk component health indicator and script execution gauges.

**Single-Row Status Pattern:** [sort:1] CK_Disk_Status_SingleRow constrains status_id to exactly 1, ensuring only one row exists. This simplifies dashboard queries (no WHERE clause needed beyond the constant) and guarantees consistent state. Both scripts update the same row with their respective timestamps and metrics.

**Separate Collection and Poll Tracking:** [sort:2] last_collection_dttm and last_poll_dttm are updated at different points in the Collect-ServerHealth.ps1 execution. Collection (Steps 1-4) updates first when disk data is gathered. Poll evaluation (Steps 5-10) updates after threshold analysis completes. If collection succeeds but threshold evaluation fails, the timestamps diverge — this distinction helps isolate which phase had the problem.

**Daily Counter Reset:** [sort:3] alerts_detected_today and alerts_sent_today reset when the date portion of last_poll_dttm differs from the current date. Collect-ServerHealth.ps1 checks this at the start of the poll metrics update and resets counters to 0 before adding the current cycle counts. This provides day-over-day comparison without requiring a separate scheduled reset process.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| status_id | int | No | 1 | Fixed identifier - always 1 |
| last_collection_dttm | datetime | Yes | — | When PowerShell last collected disk data |
| last_poll_dttm | datetime | Yes | — | When Collect-ServerHealth.ps1 last evaluated thresholds |
| last_poll_duration_ms | int | Yes | — | Duration of last poll in milliseconds |
| last_poll_status | varchar(20) | Yes | — | Result of last poll (SUCCESS, NO_DATA, etc.) |
| servers_monitored | int | No | 0 | Count of active servers in last poll |
| drives_monitored | int | No | 0 | Count of drives checked in last poll |
| drives_below_threshold | int | No | 0 | Count of drives currently below threshold |
| alerts_detected_today | int | No | 0 | New alerts detected today (resets at midnight) |
| alerts_sent_today | int | No | 0 | Notifications sent today (resets at midnight) |
| last_health_check_dttm | datetime | Yes | — | When Send-DiskHealthSummary.ps1 last ran |
| last_health_check_status | varchar(20) | Yes | — | Result of last health check |
| modified_dttm | datetime | No | getdate() | When status was last updated |

  - **PK_Disk_Status** (CLUSTERED): status_id -- PRIMARY KEY

**Check Constraints:**

  - **CK_Disk_Status_PollStatus**: `([last_poll_status] IS NULL OR ([last_poll_status]='SKIPPED' OR [last_poll_status]='FAILED' OR [last_poll_status]='SUCCESS'))`
  - **CK_Disk_Status_SingleRow**: `([status_id]=(1))`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| last_poll_status | SUCCESS | Threshold evaluation completed normally. All collected drives were evaluated against their thresholds, alerts were created or resolved as needed, and poll metrics were updated. | 1 |
| last_poll_status | FAILED | Threshold evaluation encountered an error. The try/catch wrapper around Steps 5-10 in Collect-ServerHealth.ps1 catches the failure and records it here. Disk collection data from Steps 1-4 is already committed and unaffected. | 2 |
| last_poll_status | SKIPPED | Threshold evaluation was skipped because no drives were collected in the current cycle. This occurs when all servers are unreachable or no servers have serverops_disk_enabled = 1. | 3 |

**Component Health Check** [sort:1]

```sql
SELECT 
    last_collection_dttm,
    DATEDIFF(MINUTE, last_collection_dttm, GETDATE()) AS collection_minutes_ago,
    last_poll_dttm,
    DATEDIFF(MINUTE, last_poll_dttm, GETDATE()) AS poll_minutes_ago,
    last_poll_status,
    servers_monitored,
    drives_monitored,
    drives_below_threshold
FROM ServerOps.Disk_Status
WHERE status_id = 1;
```

**Dashboard Summary** [sort:2]

```sql
SELECT 
    'ServerOps.Disk' AS component,
    CASE 
        WHEN last_poll_status = 'SUCCESS' 
             AND DATEDIFF(MINUTE, last_poll_dttm, GETDATE()) <= 90 
        THEN 'HEALTHY'
        WHEN DATEDIFF(MINUTE, last_poll_dttm, GETDATE()) > 90 
        THEN 'STALE'
        ELSE last_poll_status
    END AS status,
    servers_monitored AS servers,
    drives_monitored AS drives,
    drives_below_threshold AS alerts,
    last_poll_dttm AS last_check
FROM ServerOps.Disk_Status
WHERE status_id = 1;
```

**Today's Alert Activity** [sort:3]

```sql
SELECT 
    alerts_detected_today,
    alerts_sent_today,
    CAST(last_poll_dttm AS DATE) AS last_poll_date
FROM ServerOps.Disk_Status
WHERE status_id = 1;
```


### Disk_ThresholdConfig

Per-drive threshold configuration for disk space monitoring, allowing different alert thresholds for each drive on each server.

**Data Flow:** Collect-ServerHealth.ps1 auto-creates rows for newly discovered drives using the default_threshold_pct from GlobalConfig (ServerOps/Disk), with created_by set to Collect-ServerHealth.ps1. Manual adjustments are made directly by administrators. Send-DiskHealthSummary.ps1 reads threshold_pct for drive classification (BELOW, APPROACHING, OK). Collect-ServerHealth.ps1 reads threshold_pct and alert_enabled during threshold evaluation to determine breach detection and alert eligibility.

**Auto-Creation for New Drives:** [sort:1] When Collect-ServerHealth.ps1 discovers a drive in collection data that has no matching ThresholdConfig row, it automatically creates one using the default threshold from GlobalConfig. The new config is added to an in-memory lookup immediately so threshold evaluation can use it in the same cycle. This ensures new drives are monitored from their first appearance without manual intervention.

**Per-Drive Alerting Control:** [sort:2] The alert_enabled flag allows suppressing alerts for individual drives without changing the threshold or removing the configuration. A drive with alert_enabled = 0 still appears in snapshots and the daily summary but will not trigger Jira tickets. Useful for drives being decommissioned, intentionally kept full, or under separate management.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| threshold_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the threshold config |
| server_id | int | No | — | FK to ServerRegistry.server_id |
| drive_letter | char(1) | No | — | Drive letter (C, D, E, etc.) |
| threshold_pct | decimal(5,2) | No | 20.00 | Minimum percent free before alerting |
| alert_enabled | bit | No | 1 | Whether to generate alerts for this drive |
| description | varchar(200) | Yes | — | Optional description of the drive purpose |
| created_dttm | datetime | No | getdate() | When threshold was configured |
| created_by | varchar(100) | No | suser_sname() | Who created the configuration |
| modified_dttm | datetime | No | getdate() | When threshold was last changed |
| modified_by | varchar(100) | No | suser_sname() | Who last changed the threshold |

  - **PK_Disk_ThresholdConfig** (CLUSTERED): threshold_id -- PRIMARY KEY
  - **IX_Disk_ThresholdConfig_Server** (NONCLUSTERED): server_id [includes: drive_letter, threshold_pct, alert_enabled]
  - **UQ_Disk_ThresholdConfig_ServerDrive** (NONCLUSTERED): server_id, drive_letter

**Check Constraints:**

  - **CK_Disk_ThresholdConfig_Pct**: `([threshold_pct]>=(0) AND [threshold_pct]<=(100))`

**Foreign Keys:**

  - **FK_Disk_ThresholdConfig_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**List All Threshold Configurations** [sort:1]

```sql
SELECT 
    s.server_name,
    t.drive_letter,
    t.threshold_pct,
    t.alert_enabled,
    t.modified_dttm,
    t.modified_by
FROM ServerOps.Disk_ThresholdConfig t
INNER JOIN dbo.ServerRegistry s ON t.server_id = s.server_id
WHERE s.is_active = 1
ORDER BY s.server_name, t.drive_letter;
```

**Find Non-Standard Thresholds** [sort:2] -- Find drives with thresholds different from default 20%

```sql
-- Find drives with thresholds different from default 20%
SELECT 
    s.server_name,
    t.drive_letter,
    t.threshold_pct,
    t.modified_by
FROM ServerOps.Disk_ThresholdConfig t
INNER JOIN dbo.ServerRegistry s ON t.server_id = s.server_id
WHERE t.threshold_pct <> 20.00
ORDER BY t.threshold_pct, s.server_name;
```

  - **One Threshold Per Drive**: [sort:1] UQ_Disk_ThresholdConfig_ServerDrive enforces one configuration row per server_id + drive_letter combination. This ensures unambiguous threshold lookup during evaluation and prevents conflicting configurations for the same drive.


### sp_Activity_CorrelateIncidents

Analyzes collected DMV metrics for all monitored servers, detects threshold crossings, correlates with concurrent activity, and logs heartbeats and incidents.

**Data Flow:** Called by Collect-DMVMetrics.ps1 at the end of each collection cycle (Step 4). Reads the latest snapshot from Activity_DMV_Memory (PLE, buffer cache, memory grants), Activity_DMV_ConnectionHealth (zombie count), and Activity_DMV_WaitStats (HADR_SYNC_COMMIT delta). Reads Activity_IncidentType for correlation window configuration. Reads Activity_XE_LRQ for concurrent query correlation. Writes to Activity_Heartbeat (one row per server) and Activity_IncidentLog (one row per threshold crossing). Also reads dbo.GlobalConfig (ServerOps/Activity_DMV) for threshold values and dbo.ServerRegistry for AG partner determination.

**Preview Mode:** [sort:1] The @preview_only parameter (default 1) enables safe execution: the procedure evaluates all thresholds and prints results via PRINT statements without writing any data to Heartbeat or IncidentLog. Collect-DMVMetrics.ps1 calls it with @preview_only = 0. Manual execution defaults to preview mode, making it safe to run interactively for diagnostics.

**Configurable Thresholds via GlobalConfig:** [sort:2] Six thresholds are loaded from GlobalConfig (module ServerOps, category Activity_DMV): incident_ple_warning_threshold (default 300), incident_ple_critical_threshold (default 100), incident_hadr_spike_warning_ms (default 500000), incident_hadr_spike_critical_ms (default 5000000), incident_zombie_warning_threshold (default 500), incident_memory_grants_threshold (default 5). All have fallback defaults if config rows are missing.

**AG Partner Determination:** [sort:3] The AG partner (secondary server) is determined dynamically from ServerRegistry by matching ag_cluster_name between two SQL_SERVER type servers. This avoids hardcoding server names and adapts automatically if the AG configuration changes. The partner is used for HADR spike correlation — searching Activity_XE_LRQ on the secondary to identify workload causing synchronous commit delays on the primary.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @preview_only | bit | IN |  |  |

  - **Collect-DMVMetrics.ps1**: [sort:1] Called at Step 4 of Collect-DMVMetrics.ps1 after all DMV data has been committed. The call is wrapped in try/catch so correlation failure does not affect the collection data already committed. A correlation failure is logged as a warning but does not fail the overall script execution.


### sp_DiagnoseServerHealth

Guided diagnostic procedure that analyzes server health metrics and provides educational interpretation of results for team members with varying SQL expertise levels.

**Data Flow:** Interactive diagnostic procedure intended for manual execution. Reads Activity_DMV_Memory, Activity_DMV_WaitStats, Activity_DMV_ConnectionHealth, Activity_DMV_Workload, and Activity_XE_LRQ for the specified server within the lookback window. Also queries sys.dm_hadr_availability_replica_states and sys.dm_hadr_database_replica_states for live AG status. Outputs analysis via PRINT statements in 8 numbered sections. Does not write to any tables.

**Three Detail Levels:** [sort:1] The @detail_level parameter controls output verbosity: 0 = Technical (metrics only), 1 = Standard (metrics with interpretation), 2 = Educational (metrics with explanations of what each metric means and why it matters). The educational mode is designed for team members who are learning SQL Server performance concepts.

**Pre-Written User Communication:** [sort:2] Section 8 (Summary and Recommendations) includes a "What to Tell Users" subsection that generates pre-written communication text based on the overall server health status. This provides ready-to-send responses for common user complaints like "the system is slow" — translating technical findings into plain language without requiring the DBA to compose the message.

**Eight-Section Diagnostic Report:** [sort:3] Sections: 0-Data Availability Check, 1-AG Health, 2-Memory Health Analysis, 3-Wait Category Analysis, 4-HADR Health and Secondary Correlation, 5-Monitoring Overhead Analysis, 6-Connection and Zombie Analysis, 7-Manual Investigation Queries, 8-Summary and Recommendations. Each section contributes a component status (HEALTHY, ELEVATED, WARNING, CRITICAL) to the overall assessment.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @server_name | varchar(128) | IN |  |  |
| @lookback_minutes | int | IN |  |  |
| @detail_level | tinyint | IN |  |  |
| @include_recommendations | bit | IN |  |  |
| @output_format | varchar(20) | IN |  |  |


### Collect-DMVMetrics.ps1

Collects point-in-time DMV metrics from all monitored SQL Server instances and runs incident correlation. Captures memory health, workload indicators, connection pool health, wait statistics, I/O statistics, and xFACts session footprint. After collection, calls sp_Activity_CorrelateIncidents to evaluate thresholds and log heartbeats and incidents. Runs on a configurable Orchestrator schedule.

**Data Flow:** Reads dbo.ServerRegistry for servers with serverops_activity_enabled = 1 and server_type = SQL_SERVER. Reads dbo.GlobalConfig for zombie idle threshold. Connects to each server and queries sys.dm_os_performance_counters, sys.dm_exec_sessions, sys.dm_exec_requests, sys.dm_os_wait_stats, sys.dm_io_virtual_file_stats, and sys.master_files. Writes to Activity_DMV_Memory, Activity_DMV_Workload, Activity_DMV_ConnectionHealth, Activity_DMV_WaitStats, Activity_DMV_IO_Stats, and Activity_DMV_xFACts. Calls sp_Activity_CorrelateIncidents at Step 4 which writes to Activity_Heartbeat and Activity_IncidentLog.

**Per-Metric Error Isolation:** [sort:1] Each of the six metric categories (memory, workload, connection health, wait stats, I/O stats, xFACts footprint) is collected and inserted in its own try/catch block within the server loop. If one metric category fails on a server (e.g., a permission issue querying dm_io_virtual_file_stats), the other five categories still succeed for that server. The server is counted as successful if at least one metric category succeeds.

**Correlation as Secondary Operation:** [sort:2] The sp_Activity_CorrelateIncidents call at Step 4 is wrapped in its own try/catch with a warning-level log on failure. A correlation failure does not affect the exit status of the script or the already-committed DMV data. This follows the principle that data collection should never be blocked by analysis logic.

  - **Orchestrator ProcessRegistry**: [sort:1] Registered in Orchestrator.ProcessRegistry with standard parameters (-Execute, -TaskId, -ProcessId). Task completion callback reports server success/total count. Supports preview mode (without -Execute flag) for testing.


### Collect-ServerHealth.ps1

Collects disk space metrics from all monitored servers via WinRM/CIM and inserts into Disk_Snapshot. Also captures SQL Server service start times from sys.dm_os_sys_info for DMV freshness context. After collection, performs inline threshold evaluation: auto-creates threshold configs for new drives, detects breaches, creates Jira tickets for space requests with calculated GB needed, and auto-resolves alerts when drives recover above the resolution threshold. Runs on a configurable Orchestrator schedule.

**Data Flow:** Reads dbo.ServerRegistry for the list of monitored servers (is_active = 1, serverops_disk_enabled = 1). Connects to each server via CIM session over WinRM to query Win32_LogicalDisk (DriveType=3). Inserts disk metrics into ServerOps.Disk_Snapshot. For SQL_SERVER type servers, queries sys.dm_os_sys_info and updates dbo.ServerRegistry with service start times. Reads dbo.GlobalConfig (ServerOps/Disk) for default_threshold_pct, space_request_buffer_pct, and warning_buffer_pct. Reads and writes ServerOps.Disk_ThresholdConfig for auto-creation and threshold lookup. Reads and writes ServerOps.Disk_AlertHistory for breach detection and auto-resolution. Inserts into Jira.TicketQueue for new breach tickets. Updates ServerOps.Disk_Status with collection and poll timestamps.

**In-Memory Threshold Evaluation:** [sort:1] Threshold evaluation runs inline against the in-memory collection data rather than re-querying from the database. This eliminates any timing gap between collection and evaluation and ensures the evaluation always uses the freshest data. The evaluation block (Steps 5-10) is wrapped in try/catch so that a threshold evaluation failure does not affect already-committed collection data.

**Error Isolation Between Collection and Evaluation:** [sort:2] The script is structured in two major phases. Steps 1-4 (collection) commit disk snapshot data and update the collection timestamp. Steps 5-10 (threshold evaluation) are wrapped in a separate try/catch. If threshold evaluation fails, collection data is preserved and the Disk_Status table records the failure in last_poll_status. This prevents a monitoring logic error from blocking data collection.

**Calculated Space Request:** [sort:3] For each new breach, the script calculates the disk space needed to bring the drive above threshold_pct + space_request_buffer_pct using the actual total drive size. The result is rounded up to the nearest 10 GB with a minimum of 10 GB. This goes directly into the Jira ticket summary as a specific, actionable request — no guesswork required from IT Ops.

  - **Activity Component Cross-Reference**: [sort:1] In addition to disk collection, this script captures SQL Server service start times from sys.dm_os_sys_info and updates dbo.ServerRegistry.last_service_start_dttm. This data provides DMV freshness context for the Activity monitoring component — DMV statistics reset on service restart, so knowing the last restart time helps interpret DMV metrics accurately.
  - **Orchestrator Registration**: [sort:2] Registered in Orchestrator.ProcessRegistry with standard parameters (-Execute, -TaskId, -ProcessId). Supports preview mode (without -Execute flag) for testing — queries and evaluates thresholds but does not write to any tables. Task completion callback reports server count, drive count, and breach/approaching counts.


### Collect-XEEvents.ps1

Collects Extended Events from all monitored SQL Server instances using incremental file offset tracking. Processes seven custom xFACts XE sessions (LongQueries, BlockedProcess, Deadlock, LS_Inbound, LS_Outbound, Tracking, system_health) in a unified loop, plus AlwaysOn_health from AG servers in a separate step. Parses XML event data into typed columns and inserts into corresponding Activity_XE_* tables. Runs on a configurable Orchestrator schedule.

**Data Flow:** Reads dbo.ServerRegistry for servers with serverops_activity_enabled = 1. Reads dbo.GlobalConfig for XML retention settings (blocked_process_retain_raw_xml, aghealth_retain_raw_xml). Reads and writes ServerOps.Activity_XE_CollectionState for incremental offset tracking (via MERGE). Connects to each server and calls sys.fn_xe_file_target_read_file with offset parameters. Writes to Activity_XE_LRQ, Activity_XE_BlockedProcess, Activity_XE_Deadlock, Activity_XE_LinkedServerIn, Activity_XE_LinkedServerOut, Activity_XE_xFACts, Activity_XE_SystemHealth, and Activity_XE_AGHealth.

**Session-Driven Architecture:** [sort:1] The $XESessions array defines the mapping between XE session names, target tables, parse functions, and insert functions. The main loop iterates this array for each server, providing a uniform collection pattern. Adding a new XE session type requires: creating the XE session DDL, adding a target table, writing parse/insert functions, and adding an entry to $XESessions. The loop handles offset tracking, error handling, and collection state updates generically.

**Aggregated vs Individual Event Storage:** [sort:2] Most XE sessions store individual events (one row per event). Linked server sessions (xFACts_LS_Inbound, xFACts_LS_Outbound) are marked IsAggregated = $true in the session definition. For these, all events in a collection cycle are parsed first, then the Aggregate-LSEvents function groups them by server, source/target, database, and time window before insertion. This reduces storage volume for high-frequency linked server traffic.

**Separate AG Health Collection:** [sort:3] AlwaysOn_health is collected in Step 4, separate from the Step 3 loop that processes custom sessions. Step 3 iterates all activity-enabled servers and all sessions in $XESessions. Step 4 queries only AG servers (currently DM-PROD-DB and DM-PROD-REP) and processes only the AlwaysOn_health session. This separation exists because AlwaysOn_health is a Microsoft built-in session only present on AG-participating servers.

  - **Orchestrator ProcessRegistry**: [sort:1] Registered in Orchestrator.ProcessRegistry with standard parameters (-Execute, -TaskId, -ProcessId). Task completion callback reports server success/total count and total events collected. Supports preview mode (without -Execute flag) for testing.


### Send-DiskHealthSummary.ps1

Generates a disk health summary and delivers it as a color-coded Adaptive Card to Teams. Queries the latest Disk_Snapshot per server/drive, classifies drives against Disk_ThresholdConfig thresholds, and builds a rich card with inline drive details for problem servers. Inserts directly into Teams.AlertQueue with pre-built card_json. Runs on a configurable Orchestrator schedule.

**Data Flow:** Reads dbo.GlobalConfig (ServerOps/Disk) for warning_buffer_pct. Queries the latest Disk_Snapshot per server/drive joined to dbo.ServerRegistry (serverops_disk_enabled = 1) and Disk_ThresholdConfig. Classifies each drive as BELOW, APPROACHING, or OK and determines overall card severity. Builds complete Adaptive Card JSON and inserts directly into Teams.AlertQueue with card_json populated, bypassing sp_QueueAlert. Updates ServerOps.Disk_Status with last_health_check_dttm and last_health_check_status.

**Direct AlertQueue Insert with Pre-Built Card JSON:** [sort:1] This script inserts directly into Teams.AlertQueue rather than calling sp_QueueAlert because it provides a complete pre-built Adaptive Card via the card_json field. The sp_QueueAlert procedure builds a standard card from title/message/color fields, but the disk health summary requires custom layout with server grouping, inline drive details, and color-coded text that cannot be expressed through the standard fields.

**Three-Tier Card Severity:** [sort:2] The card background color communicates overall fleet health at a glance: green (good) when all drives are above threshold + buffer, yellow (warning) when any drive is approaching but none are below, red (attention) when any drive is below threshold. Servers are sorted worst-first within the card so problems are immediately visible without scrolling.

**Emoji Placeholder Pattern:** [sort:3] Uses placeholder tokens ({{FIRE}}, {{WARN}}, {{CHECK}}) instead of direct Unicode emoji characters due to PowerShell 5.1 ConvertTo-Json encoding limitations. Process-TeamsAlertQueue.ps1 resolves these placeholders to actual Unicode characters at delivery time.

  - **Teams Delivery Chain**: [sort:1] The card is inserted into Teams.AlertQueue with trigger_type DiskHealthSummary and trigger_value set to the current date (YYYY-MM-DD). The TR_Teams_AlertQueue_QueueDepth trigger fires on insert, signaling the processor. Process-TeamsAlertQueue.ps1 picks up the row and delivers to Teams via the webhook configured in Teams.WebhookSubscription for source_module ServerOps.
  - **Dependency on Collection Freshness**: [sort:2] This script depends on Collect-ServerHealth.ps1 having run recently to populate current Disk_Snapshot data. If collection has not run, the query returns no drive data and the script exits with a warning. The daily summary reflects whatever the latest snapshot shows — there is no separate freshness check beyond the snapshot existence.


### AlwaysOn_health

Microsoft built-in XE session that captures AlwaysOn Availability Group health events including state changes, failovers, and errors. Only present on servers participating in an AG. xFACts collects from this session on AG servers only.

**AG-Only Collection:** [sort:1] Collected in a separate Step 4 of Collect-XEEvents.ps1 rather than in the main Step 3 session loop. The server list for this step is queried independently, targeting only servers known to participate in an AG. This session does not exist on standalone SQL Server instances.

**Captured Events (Microsoft-Managed):** [sort:2] Microsoft built-in session capturing AG health events. Key events: availability_replica_state_change (failovers and role changes - always investigate), availability_replica_state (state snapshots), availability_replica_manager_state_change (internal state machine transitions - usually normal), hadr_db_partner_set_sync_state (database sync state updates - monitor for stuck states). Only present on servers participating in an AG. xFACts does not modify this session - it collects from it as-is.

**Check Session Status** [sort:1] -- Verify the session is running on an AG server (should always be running)

```sql
SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'AlwaysOn_health';
```

  - **Activity_XE_AGHealth**: [sort:1] Events from this session are parsed by Parse-AGHealthEvent and stored in Activity_XE_AGHealth. Raw XML retention is configurable via GlobalConfig aghealth_retain_raw_xml.


### system_health

Microsoft built-in XE session that runs by default on every SQL Server instance. Captures broad system-level events including connectivity issues, scheduler problems, and errors. xFACts collects from this session for centralized health monitoring.

**Built-In Session With Custom File Path Resolution:** [sort:1] Unlike custom xFACts sessions that store files in a known directory, system_health uses the SQL Server default LOG directory. The collection script uses Get-SystemHealthFilePath to determine the correct file path pattern, which differs from the Get-XEFilePath function used for custom sessions.

**Captured Events (Microsoft-Managed):** [sort:2] Microsoft built-in session capturing a broad range of system events. Key events include: sp_server_diagnostics_component_result (component health assessments), error_reported (errors with severity >= 20), connectivity_ring_buffer_recorded (connectivity issues), scheduler_monitor_system_health_ring_buffer_recorded (scheduler problems). The event list is defined by Microsoft and varies by SQL Server version. xFACts does not modify this session - it collects from it as-is.

**Check Session Status** [sort:1] -- Verify the session is running (should always be running as it is a SQL Server default)

```sql
SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'system_health';
```

  - **Activity_XE_SystemHealth**: [sort:1] Events from this session are parsed by Parse-SystemHealthEvent and stored in Activity_XE_SystemHealth.


### xFACts_BlockedProcess

Captures blocked_process_report events triggered by the SQL Server blocked process threshold configuration. Provides the raw data for Activity_XE_BlockedProcess.

**Server-Level Prerequisite:** [sort:1] This session requires the sp_configure 'blocked process threshold' to be set on each monitored server. SQL Server only generates blocked_process_report events when blocking exceeds this threshold. The XE session captures the event; the server configuration controls when events are generated.

**Captured Events and Actions:** [sort:2] Captures blocked_process_report events. Unlike other XE sessions, this event is triggered by the SQL Server sp_configure 'blocked process threshold' setting, not by an XE predicate. The session simply captures all events that SQL Server generates. Actions collected: database_name, session_id, client_hostname, client_app_name, username. Most blocking details (both blocked and blocking sides) come from the event XML payload, not actions. Target: rolling .xel files (5 files x 50 MB = 250 MB max) at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

**Check Session Status and Threshold** [sort:1] -- Shows session status and the sp_configure blocked process threshold

```sql
-- Session status
SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_BlockedProcess';

-- sp_configure threshold (controls when SQL Server generates events)
SELECT 
    name,
    CAST(value_in_use AS INT) AS threshold_seconds
FROM sys.configurations
WHERE name = 'blocked process threshold';
```

  - **Activity_XE_BlockedProcess**: [sort:1] Events from this session are parsed by Parse-BlockedProcessEvent and stored in Activity_XE_BlockedProcess.


### xFACts_Deadlock

Captures xml_deadlock_report events containing the full deadlock graph. Provides the raw data for Activity_XE_Deadlock.

**Captured Events:** [sort:1] Captures xml_deadlock_report events with no predicate filter - all deadlocks are captured. This provides the complete deadlock graph XML including both victim and survivor process details, lock resources, and full query text. The built-in system_health session also captures deadlocks, but xFACts_Deadlock provides a dedicated, isolated capture. Target: rolling .xel files (5 files x 50 MB = 250 MB max) at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

**Check Session Status** [sort:1] -- Verify the session is running on a monitored server

```sql
SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_Deadlock';
```

  - **Activity_XE_Deadlock**: [sort:1] Events from this session are parsed by Parse-DeadlockEvent and stored in Activity_XE_Deadlock. The full deadlock graph XML is always retained.


### xFACts_LongQueries

Captures sql_batch_completed and rpc_completed events that exceed a configurable duration threshold. Provides the raw data for Activity_XE_LRQ and serves as the primary correlation source for incident detection.

**Captured Events and Actions:** [sort:1] Captures sql_statement_completed and rpc_completed events exceeding the configured duration threshold. Two event types ensure coverage of all query execution paths: sql_statement_completed fires for ad-hoc SQL and statements within batches; rpc_completed fires for parameterized queries from applications (sp_executesql, ORM-generated queries). Actions collected: sql_text, database_name, username, client_hostname, client_app_name, session_id, query_hash, query_plan_hash. Target: rolling .xel files (5 files x 50 MB = 250 MB max per server) at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

**Duration Threshold in Microseconds:** [sort:2] The duration predicate is specified in microseconds (not milliseconds). 1 second = 1,000,000 microseconds. The threshold is set in the XE session DDL predicate, not in GlobalConfig. Changing it requires redeploying the session on each server. The deployment script is idempotent - it stops and drops any existing session before creating a new one.

**Check Session Status** [sort:1] -- Verify the session is running on a monitored server

```sql
SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_LongQueries';
```

**View Current Threshold** [sort:2] -- Shows the duration predicate value configured in the session

```sql
SELECT 
    ses.name AS event_name,
    ses.predicate
FROM sys.server_event_session_events ses
JOIN sys.server_event_sessions s 
    ON ses.event_session_id = s.event_session_id
WHERE s.name = 'xFACts_LongQueries';
```

  - **Activity_XE_LRQ**: [sort:1] Events from this session are parsed by Parse-LRQEvent and stored in Activity_XE_LRQ. The duration threshold is configured in the XE session CREATE EVENT SESSION DDL on each monitored server.


### xFACts_LS_Inbound

Captures inbound linked server query events — queries received from other servers via linked server connections. Provides the raw data for Activity_XE_LinkedServerIn after aggregation.

**Captured Events and Predicate:** [sort:1] Captures sql_statement_completed and rpc_completed events filtered to linked server connections (client_app_name = 'Microsoft SQL Server', which is the signature of linked server connections). Actions collected: sql_text. The predicate ensures only inbound linked server traffic is captured, avoiding all local query activity. Target: rolling .xel files at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

**Check Session Status** [sort:1] -- Verify the session is running on a monitored server

```sql
SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_LS_Inbound';
```

  - **Activity_XE_LinkedServerIn**: [sort:1] Events from this session are parsed by Parse-LSInboundEvent, aggregated by Aggregate-LSEvents, and stored in Activity_XE_LinkedServerIn. High-frequency linked server traffic is aggregated before storage to manage data volume.


### xFACts_LS_Outbound

Captures outbound linked server query events — queries sent to other servers via four-part naming, OPENQUERY, or OPENROWSET. Provides the raw data for Activity_XE_LinkedServerOut after aggregation.

**Captured Events and Predicate Exclusions:** [sort:1] Captures sql_statement_completed and rpc_completed events for queries targeting linked servers (four-part naming, OPENQUERY, OPENROWSET). Actions collected: sql_text. The predicate excludes known noisy sources at the XE engine level: Redgate monitoring tools and SQLServerCEIP telemetry. This predicate-level exclusion means zero overhead for excluded sources - events never allocate memory or write to the buffer. Target: rolling .xel files at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

**Check Session Status** [sort:1] -- Verify the session is running on a monitored server

```sql
SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_LS_Outbound';
```

  - **Activity_XE_LinkedServerOut**: [sort:1] Events from this session are parsed by Parse-LSOutboundEvent, aggregated by Aggregate-LSEvents, and stored in Activity_XE_LinkedServerOut. Same aggregation pattern as xFACts_LS_Inbound.


### xFACts_Tracking

Captures all completed query executions from xFACts processes on each monitored server. Filters to sessions with application name matching xFACts patterns. Provides the raw data for Activity_XE_xFACts.

**Self-Monitoring Complement to DMV Footprint:** [sort:1] This XE session captures event-level detail (individual queries with text and execution metrics) while Activity_DMV_xFACts captures point-in-time session state (cumulative counters). Together they provide complete self-monitoring: the DMV table shows total resource impact and the XE table shows what specific queries xFACts ran.

**Captured Events and Actions:** [sort:2] Captures sql_batch_completed events from xFACts processes only (filtered by client_app_name LIKE 'xFACts%'). No duration threshold - captures all completed batches regardless of duration for comprehensive impact tracking. Actions collected: sql_text. Target: rolling .xel files at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

**Collector Self-Exclusion Predicate:** [sort:3] The predicate explicitly excludes client_app_name = 'xFACts Collect-XEEvents'. Without this exclusion, the collector's INSERT statements into Activity_XE_xFACts would be captured as events, collected on the next cycle, inserted again, and captured again - creating a feedback amplification loop. The collector's own impact is tracked via Orchestrator.TaskLog duration and Activity_DMV_xFACts instead.

**Check Session Status** [sort:1] -- Verify the session is running on a monitored server

```sql
SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_Tracking';
```

  - **Activity_XE_xFACts**: [sort:1] Events from this session are parsed by Parse-xFACtsEvent and stored in Activity_XE_xFACts.



# JBoss Monitoring

*Cracking open the JBoss black box — because “have you tried restarting it?” is not a monitoring strategy*

Debt Manager runs on JBoss. JBoss runs on three application servers. When one of those servers decides to take an unscheduled nap, nobody knows until users start complaining and the database starts screaming. This module watches the application servers directly — not the database symptoms, but the actual engines that run DM.






The Black Box

Here’s a fun fact: the team responsible for keeping Debt Manager running has never had any real visibility into the application servers that host it.

We know SQL Server inside and out. We can diagnose blocking chains and trace wait statistics in our sleep. But when the problem isn’t the database — when the *application layer* freezes and the database is just the innocent bystander — we’ve historically had one diagnostic tool: someone says “DM is slow” and someone else says “let me restart JBoss.”

JBoss has a management interface. It was clearly designed by people who enjoy reading XML recreationally. It has hundreds of metrics organized in a tree structure that makes perfect sense if you already know exactly what you’re looking for, and is completely impenetrable if you don’t. Think of it as a filing cabinet where every drawer is labeled in a language you almost speak.

This module translates all of that into something a human being would actually want to look at.






What We’re Watching



Is It
Alive?
→
Is the Engine
Running?
→
How Is It
Feeling?
→
Are the Queues
Flowing?
→
Did Anything
Change?

Five questions, three servers, every 60 seconds


On each scheduled execution the script reaches out to all three DM application servers and asks a series of increasingly nosy questions.

**Are you alive?** A simple web request to the DM splash page. If the server responds, the front door is open. If it doesn’t, the server may be frozen, crashed, or just ignoring us. This is the fastest, most direct freeze detection possible — no waiting for database-side symptoms to build up.

**Is the engine running?** A check on the Windows service that hosts JBoss. Here’s the insidious thing about JBoss freezes: the Windows service happily reports “Running” even when the application inside is completely locked up. The process is alive but nobody’s home. It’s the IT equivalent of the lights being on with nobody answering the door.

**How is it feeling?** This is where it gets interesting. Through the JBoss Management API, we pull metrics that were previously invisible: how much memory JBoss is chewing through, how many threads are active, how fast the database connection pool is being consumed, how many transactions are committing versus timing out.

**Are the queues flowing?** JBoss processes work through internal message queues. When queues back up, it’s like a traffic jam that hasn’t reached the highway yet — users haven’t noticed, but they’re about to.

**Did anything change?** Configuration values like pool sizes and thread counts are tracked. If someone changed a setting on Tuesday, and performance tanks on Wednesday, we can connect those dots instead of staring at each other in a meeting.






Three Servers, Three Personalities

The DM environment runs across three application servers, and they are not created equal.

**APP** is essentially the internal operations manager. It houses the Debt Manager domain controller that coordinates the other two, handles scheduled DM system processes, and generally keeps the trains running. It also handles the mail, because apparently the operations manager always gets stuck with the mail.

**APP2** is where the end users live. The link everyone clicks to open Debt Manager in Sharepoint points here. It handles the heaviest interactive load and is historically the server most likely to have a bad day. If JBoss is going to freeze somewhere, the smart money is on APP2.

**APP3** handles the heavy lifting — file uploads, rules engine processing, data loading. The stuff that would make APP2 even more miserable if it had to do it alongside serving users.

Each server runs its own independent JBoss instance. They don’t share memory, threads, or connection pools. When one server freezes, the other two keep going, blissfully unaware. That’s why we monitor each one separately — the health of one tells you absolutely nothing about the others.






The Control Center View

The monitoring page shows all three servers side by side. Each server card is a self-contained health dashboard: status badges across the top for quick pass/fail, then a stack of metric cards showing what’s happening inside the engine.

Every metric card has a **?** button that explains what you’re looking at in plain English. We built this for ourselves as much as anyone — because half of understanding JBoss is learning what “heuristic transaction” means and then realizing you didn’t need to know.

Admins can also redirect which server the DM SharePoint link points to, right from the dashboard. When a server needs a restart, redirecting users is one click instead of a manual SharePoint edit.






The Bottom Line

For years, the application servers were the one part of the Debt Manager stack we couldn’t see into. The database? Monitored to the millisecond. The batch pipeline? Tracked through every status change. The app servers? “Restart them and hope for the best.”

This module opens the hood. Memory, threads, connections, transactions, work queues — all the things JBoss knows about itself but never bothered to tell us in a useful format. Now it tells us every 60 seconds, in a language that doesn’t require a JBoss certification to understand.

We’re still learning what “normal” looks like for these servers. The patterns will get clearer over time. But we can already see things we’ve never seen before — and the first time we catch a freeze forming before users notice, the entire module will have paid for itself.

---

# JBoss Monitoring — Control Center Guide

---

## Architecture
# JBoss Monitoring Architecture

The narrative page explains *what* DM Monitoring does and *why* the JBoss layer was a blind spot. This page explains *how* the collector works: the five independent data sources, the composite API calls to the JBoss domain controller, the config change detection pattern, and how it all fits together. One script, three tables, sixty seconds per cycle.



Schema Overview

The JBoss schema has three tables, no stored procedures, and no triggers. All logic lives in `Collect-JBossMetrics.ps1`. The tables are append-only — the collector writes, the Control Center reads, nothing ever updates or deletes.



| Table | Role | Rows Per Cycle |
| --- | --- | --- |
| `Snapshot` | Server health metrics — HTTP, CIM, JVM, transactions, connections, HTTP server | 3 (one per server) |
| `QueueSnapshot` | Per-queue JMS stats — pending, delivering, consumers, throughput | ~54 (18 queues × 3 servers) |
| `ConfigHistory` | JBoss configuration change detection — write-on-change only | 0 (typically) or N (on change) |



No stored procedures, no triggers. This is deliberate. All collection logic runs in PowerShell on the xFACts server, reaching out to the app servers remotely. If the app servers are down or unreachable, the collector fails gracefully and tries again next cycle. There are no database-side dependencies on the monitored servers.







The Collection Sequence

The collector runs on a configurable schedule via the orchestrator. Each cycle, it loops through all JBoss-enabled APP_SERVER entries in `ServerRegistry` and performs five independent collection steps per server.





HTTP Check
DM splash page
Status + response time

→

CIM Session
Service state
Process memory/threads
Server uptime

→

Health API
JVM + pool + threads
+ transactions + HTTP
(7-step composite)

→

Queue API
18 queues per server
pending + delivering
+ consumers + throughput

→

Config API
9 settings per server
Write-on-change only


Per server, per cycle. HTTP and CIM work even when JBoss is frozen. API steps fail gracefully to NULLs.


The key design principle: **every step is independent.** If the Management API is unreachable (firewall issue, JBoss down), the HTTP and CIM data still gets collected and written. If the queue composite fails, the health snapshot is still inserted. Each data source has its own try/catch block, and partial failures produce partial snapshots rather than losing an entire cycle.

Total time per cycle: roughly 1–2 seconds for all three servers, 9 API calls to JBoss, 3 HTTP checks, 3 CIM sessions, and approximately 60 database inserts.






Five Data Source Layers

Each server is queried from five independent sources. They're listed in the order the collector executes them.

| Layer | Method | What It Captures |
| --- | --- | --- |
| **1. HTTP** | `Invoke-WebRequest` to DM splash page | Responsiveness (status code + response time). Primary freeze detection — direct, fast, unambiguous. |
| **2. CIM** | Remote CIM session (Win32_Service, Win32_Process, Win32_OperatingSystem) | Windows service state, JBoss process memory/threads/handles, server uptime. OS-level view independent of JBoss itself. |
| **3. Health Composite** | JBoss Management API (composite REST POST, 7 steps) | Server state, JVM heap/non-heap, thread count/peak, datasource pool stats, Undertow HTTP stats, transaction counts, IO worker pool. |
| **4. Queue Composite** | JBoss Management API (composite REST POST, 18 steps) | Per-queue JMS metrics: pending messages, delivering count, consumer count, cumulative messages added. |
| **5. Config Composite** | JBoss Management API (composite REST POST, 9 steps) | Current JBoss configuration values: thread pools, connection pool sizing, heap max, transaction timeout, messaging config. |


Layers 1 and 2 work even when JBoss is completely frozen — they operate at the OS level. Layers 3–5 require the JBoss Management API, which runs on a separate port from the application. In testing, the Management API has remained responsive even during application-level issues, but if it goes down, the collector gracefully records NULL for all API columns and keeps the HTTP and CIM data.


CIM process identification. Each DM app server runs multiple `java.exe` processes in a tiered tree: service wrapper, JBoss bootstrap, management layer, and the main application server. The collector identifies the main JBoss process by selecting the `java.exe` with the largest `WorkingSetSize` (~9–10 GB), which reliably distinguishes it from the smaller bootstrap and management processes.







Composite API Design

The JBoss Management API is a REST interface on port 9990. Rather than making individual calls for each metric (which would mean dozens of HTTP requests per cycle), the collector batches multiple reads into a single `"operation": "composite"` POST with a `"steps"` array. One round trip, all the data.

The domain controller on APP is the single entry point. Even though the three servers run independent JBoss instances, the domain controller can query any server by including the target host and server instance in the address path. One API endpoint on APP fans out to all three servers internally.

Health Composite (7 steps per server)

| Step | Target Subsystem | Metrics |
| --- | --- | --- |
| Server State | Server root | `server-state` (running, stopped, reload-required) |
| JVM Memory | platform-mbean / memory | Heap used/max, non-heap used |
| JVM Threads | platform-mbean / threading | Thread count, peak thread count |
| Datasource Pool | datasources / dataSource / pool | Active, in-use, idle, wait, max-used, timed-out, avg get time, max wait time |
| Undertow HTTP | undertow / default-server / http | Request count, error count, bytes sent, processing time, max processing time |
| Transactions | transactions | Committed, in-flight, timed out, rollbacks, aborted, heuristics |
| IO Worker | io / worker / default | Queue size (requests waiting for a worker thread) |



Hand-built JSON. PowerShell 5.1's `ConvertTo-Json` doesn't reliably serialize the nested array-of-objects address format that JBoss requires. The collector builds the composite JSON strings directly using string concatenation. Not elegant, but it works every time — which is more than can be said for the alternative.


Server Instance Addressing

Each composite step targets a specific server instance using an address path like:

`{"host":"dm-prod-app2"},{"server":"dm-prod-app2-inst1"}`

JBoss uses lowercase hostnames in its address paths while `ServerRegistry` stores uppercase. The script applies `ToLower()` when building API paths and preserves the original name for database writes. Server instances follow the pattern `{hostname}-inst1`.






Config Change Detection

JBoss configuration values — pool sizes, thread counts, timeouts — don't change often, but when they do, you want to know. A pool size reduction on Tuesday could explain a performance dip on Wednesday. Without a record of what changed and when, those dots are impossible to connect.

`ConfigHistory` is a write-on-change table. At script startup, the most recent recorded value per server per setting is loaded into a hashtable cache. Each cycle reads the current values via the config composite and compares against the cache. If a value differs, a row is written with both the old and new values. If nothing changed, nothing is written.

| Setting | Source Level | What It Controls |
| --- | --- | --- |
| `worker_max_threads` | Server instance | Maximum worker threads in the IO subsystem |
| `io_thread_count` | Server instance | IO thread count (typically matches CPU cores) |
| `datasource_min_pool` | Profile (full-ha) | Minimum connections in the main database pool |
| `datasource_max_pool` | Profile (full-ha) | Maximum connections in the main database pool |
| `jvm_heap_max_mb` | Server instance | JVM maximum heap size |
| `transaction_timeout` | Server instance | Transaction timeout in seconds (currently 900 / 15 min) |
| `messaging_min_pool` | Profile (full-ha) | Minimum connections for JMS messaging |
| `messaging_max_pool` | Profile (full-ha) | Maximum connections for JMS messaging |
| `messaging_thread_pool` | Profile (full-ha) | Thread pool size for JMS messaging |



Profile-level vs. server-level. Some settings (like datasource pool sizes) are configured at the JBoss *profile* level and apply to all three servers equally. Others (like heap max and worker threads) are configured per server instance. The config composite reads both, but profile-level settings are recorded per server anyway so the data is self-contained — you can query a single server's configuration at any point in time without needing to know which settings came from the profile.


The typical lifecycle: 27 baseline rows on first collection (9 settings × 3 servers), then silence until someone actually changes a configuration. The table stays small and every row is meaningful.






Queue Monitoring

Each DM app server has 65 JMS queues configured. Most are dormant. The collector monitors the 18 queues that have shown actual throughput (messages added > 0 at any point). This keeps the data volume manageable while ensuring every operationally relevant queue is watched.

Key metrics per queue per server per cycle:

| Metric | What It Means |
| --- | --- |
| `message_count` | Pending messages waiting to be processed. Zero is healthy. |
| `delivering_count` | Messages currently being delivered to consumers. These are in flight. |
| `consumer_count` | Active listeners on this queue. Zero on an active queue = nobody processing work. |
| `messages_added` | Cumulative total since JBoss start. The delta between snapshots shows throughput. |


The queues are **independent per server**. They are not clustered or shared despite cluster configuration existing in JBoss. When APP2 freezes, all messages queued on APP2 stop processing. APP and APP3 cannot pick up that work. This is why the Control Center displays queues per server rather than in aggregate.

Queue activity correlates with server role. User-driven queues (cache requests, document generation) concentrate on APP2 where users connect via SharePoint. Batch job queues (NB release, payment posting) concentrate on APP and APP3 where Task Scheduler scripts direct work.






How Everything Connects

| Component | Role |
| --- | --- |
| `dbo.ServerRegistry` | Server list — `jboss_enabled = 1` and `server_type = 'APP_SERVER'` controls which servers are monitored. `is_domain_controller` identifies the Management API endpoint. |
| `dbo.GlobalConfig` | Runtime settings — HTTP base path, timeout values, Management API URL. Module JBoss, categories App and Admin. |
| `dbo.Credentials` | JBoss Management API authentication — `JBossManagement` service with `JBossUser` and `JBossPassword` keys. Two-tier encrypted passphrase model. |
| `Orchestrator.ProcessRegistry` | Schedules the collector on a 60-second cycle in FIRE_AND_FORGET mode. |
| Control Center page | Reads `Snapshot` (latest per server) and `QueueSnapshot` (latest cycle per server) via API endpoints. Displays all three servers side by side with real-time metrics. |

---

## Reference

### ConfigHistory

Change detection log for JBoss configuration settings on DM application servers. Each collection cycle reads current configuration values from the Management API and compares against the most recent recorded value per server per setting. A row is written only when a value differs from the previously recorded value, or on first capture when no prior record exists. Provides historical context for interpreting performance metrics — configuration at any point in time can be determined by finding the most recent row per setting before that timestamp.

**Data Flow:** Collect-JBossMetrics.ps1 reads JBoss configuration values via the Management API each collection cycle and compares them against the most recent recorded values in this table. Rows are only written when a value changes or on first capture. Settings tracked include IO worker pool sizing, datasource pool min/max, JVM heap max, transaction timeout, and messaging pool configuration. The Control Center JBoss Monitoring page can reference this table to provide configuration context alongside performance metrics.

**Write on Change Only:** [sort:1] The collector reads configuration values every cycle but only writes to this table when a value differs from the most recently recorded value for that server and setting. This keeps the table extremely small — typically one initial baseline row per setting per server, with additional rows only when someone changes a JBoss configuration. The comparison is done in the script against cached values, so no database write occurs on the vast majority of cycles.

**Point-in-Time Config Lookup:** [sort:2] To determine what configuration was in effect at a specific time, query the most recent row per server per setting where collected_dttm is less than or equal to the target timestamp. This enables correlation between metric anomalies and configuration changes — if a pool size was changed Tuesday and performance degraded Wednesday, the timeline is visible in the data.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| config_history_id (IDENTITY) | int | No | IDENTITY | Auto-incrementing primary key. |
| server_id | int | No | — | FK to dbo.ServerRegistry. Identifies which DM application server this configuration observation is from. |
| server_name | varchar(128) | No | — | Server hostname denormalized from ServerRegistry for direct querying without joins. |
| setting_name | varchar(128) | No | — | Configuration setting identifier using a descriptive key name (e.g., worker_max_threads, datasource_max_pool, jvm_heap_max_mb, transaction_timeout_seconds). Consistent naming across servers enables cross-server comparison. |
| setting_value | varchar(256) | No | — | Observed value of the setting stored as a string for flexibility across different data types (integers, booleans, strings). The collector reads the current value from the JBoss Management API each cycle. |
| previous_value | varchar(256) | Yes | — | The previously recorded value for this server and setting. NULL on the first capture when no prior record exists. Populated on subsequent rows so that each change record is self-contained — the old and new values are visible in a single row without needing to look at the prior record. |
| collected_dttm | datetime | No | getdate() | When the change was detected. This is the detection time, not necessarily the exact time the configuration was modified — the actual change could have occurred at any point since the previous collection cycle. Defaults to GETDATE() at insert time. |

  - **PK_ConfigHistory** (CLUSTERED): config_history_id -- PRIMARY KEY
  - **IX_ConfigHistory_ServerSetting** (NONCLUSTERED): server_id, setting_name, collected_dttm [includes: setting_value]

**Foreign Keys:**

  - **FK_ConfigHistory_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Current Configuration Per Server** [sort:1] -- Most recent value for each tracked setting on each server. Shows the configuration currently in effect.

```sql
SELECT
    server_name,
    setting_name,
    setting_value,
    collected_dttm               AS effective_since
FROM (
    SELECT server_name, setting_name, setting_value, collected_dttm,
           ROW_NUMBER() OVER (
               PARTITION BY server_id, setting_name
               ORDER BY collected_dttm DESC
           ) AS rn
    FROM JBoss.ConfigHistory
) ranked
WHERE rn = 1
ORDER BY server_name, setting_name;
```

**Configuration Differences Across Servers** [sort:2] -- Compares current settings between servers to identify configuration drift. Settings with identical values across all servers are excluded.

```sql
WITH CurrentConfig AS (
    SELECT server_name, setting_name, setting_value,
           ROW_NUMBER() OVER (
               PARTITION BY server_id, setting_name
               ORDER BY collected_dttm DESC
           ) AS rn
    FROM JBoss.ConfigHistory
)
SELECT setting_name,
       MAX(CASE WHEN server_name = 'DM-PROD-APP'  THEN setting_value END) AS APP,
       MAX(CASE WHEN server_name = 'DM-PROD-APP2' THEN setting_value END) AS APP2,
       MAX(CASE WHEN server_name = 'DM-PROD-APP3' THEN setting_value END) AS APP3
FROM CurrentConfig
WHERE rn = 1
GROUP BY setting_name
HAVING COUNT(DISTINCT setting_value) > 1
ORDER BY setting_name;
```

  - **Snapshot**: [sort:1] Configuration changes recorded here provide context for Snapshot metric trends. A change in datasource pool sizing, worker thread count, or transaction timeout may correlate with shifts in the health metrics captured in Snapshot.
  - **QueueSnapshot**: [sort:2] Messaging configuration changes (thread pool sizes, connection factory settings) tracked here may explain shifts in queue processing patterns observed in QueueSnapshot.


### QueueSnapshot

Per-queue JMS metrics for DM application servers. Each collection cycle produces one row per active queue per monitored server, capturing pending message count, delivery state, consumer count, and cumulative throughput. Used for queue backlog detection, dead consumer alerting, and workload distribution analysis across servers.

**Data Flow:** Collect-JBossMetrics.ps1 reads JMS queue metrics via composite REST operations to the JBoss Management API domain controller. For each server, one composite call retrieves all active queue stats. Only queues with historical throughput (messages-added > 0 at any point) are collected — approximately 12-15 queues per server out of 65 total. The Control Center JBoss Monitoring page reads this table for queue health display and backlog detection. Retention is managed alongside Snapshot by snapshot_retention_days in GlobalConfig.

**Active Queue Filtering:** [sort:1] Each DM app server has 65 JMS queues configured, but only 12-15 have meaningful throughput. The collector maintains an active queue list based on observed messages-added > 0 and only collects metrics for those queues. This keeps row volume manageable (~45 rows per cycle across 3 servers) while ensuring all operationally relevant queues are monitored.

**Queues Are Independent Per Server:** [sort:2] JMS queues operate independently on each server — they are not clustered despite cluster configuration existing. When a server freezes, all messages in its queues stop processing. Other servers cannot pick up the work. This means queue health must be monitored per-server, not in aggregate.

**Workload Distribution Pattern:** [sort:3] Queue activity correlates with server role: user-driven queues (fixedFeeEventQueue, documentOutputRequestQueue, consumerCacheRequestQueue) concentrate on APP2 where users connect via SharePoint. Batch job queues (jobBatchQueue, nbReleaseQueue, paymentsImportPartitionQueue) concentrate on APP and APP3 where Task Scheduler scripts direct work. Cross-server comparison of messages-added deltas reveals workload balance.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| queue_snapshot_id (IDENTITY) | int | No | IDENTITY | Auto-incrementing primary key. |
| server_id | int | No | — | FK to dbo.ServerRegistry. Identifies which DM application server this queue snapshot is from. |
| server_name | varchar(128) | No | — | Server hostname denormalized from ServerRegistry for direct querying without joins. |
| queue_name | varchar(128) | No | — | JMS queue name as reported by the JBoss Management API (e.g., jobBatchQueue, requestQueue, fixedFeeEventQueue). Only active queues with historical message throughput are collected — idle queues with zero messages-added are excluded. |
| message_count | int | No | — | Pending messages in the queue waiting to be processed. Zero is healthy. A sustained non-zero value indicates the queue is backing up — consumers are not keeping pace with producers. This is the primary queue health indicator. |
| delivering_count | int | No | — | Messages currently being delivered to consumers. These are in-flight — picked up by a consumer but not yet acknowledged. High delivering_count with stable message_count indicates normal processing. High delivering_count with rising message_count indicates consumers are stuck. |
| consumer_count | int | No | — | Number of active consumers listening on this queue. Zero consumers on a queue that normally has throughput indicates a dead queue — no processing will occur regardless of message volume. Consumer counts vary by queue: requestQueue typically has 67-70, most others have 1-6. |
| messages_added | bigint | No | — | Cumulative messages added to the queue since JVM start. The delta between consecutive snapshots indicates queue throughput per interval. Resets on JBoss restart. Used for workload distribution analysis across servers. |
| collected_dttm | datetime | No | getdate() | When this queue snapshot was collected. Defaults to GETDATE() at insert time. Aligns with the corresponding Snapshot.collected_dttm for the same collection cycle. |

  - **PK_QueueSnapshot** (CLUSTERED): queue_snapshot_id -- PRIMARY KEY
  - **IX_QueueSnapshot_Retention** (NONCLUSTERED): collected_dttm
  - **IX_QueueSnapshot_ServerQueue** (NONCLUSTERED): server_id, queue_name, collected_dttm [includes: message_count, delivering_count, consumer_count, messages_added]

**Foreign Keys:**

  - **FK_QueueSnapshot_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Sustained Queue Backlog** [sort:1] -- Queues with pending messages in consecutive snapshots — indicates consumers are not keeping pace. Uses a self-join to find queues that stayed backed up across two collection cycles.

```sql
WITH Consecutive AS (
    SELECT
        q1.server_name,
        q1.queue_name,
        q1.collected_dttm            AS first_seen,
        q2.collected_dttm            AS still_pending,
        q1.message_count             AS first_pending,
        q2.message_count             AS later_pending,
        q1.consumer_count,
        q1.delivering_count
    FROM JBoss.QueueSnapshot q1
    JOIN JBoss.QueueSnapshot q2
        ON q2.server_id = q1.server_id
       AND q2.queue_name = q1.queue_name
       AND q2.collected_dttm = (
            SELECT MIN(collected_dttm)
            FROM JBoss.QueueSnapshot
            WHERE server_id = q1.server_id
              AND queue_name = q1.queue_name
              AND collected_dttm > q1.collected_dttm
       )
    WHERE q1.message_count > 0
      AND q2.message_count > 0
      AND q1.collected_dttm >= DATEADD(HOUR, -24, GETDATE())
)
SELECT server_name, queue_name,
       MIN(first_seen)               AS backlog_started,
       MAX(still_pending)            AS last_observed,
       MAX(later_pending)            AS peak_pending,
       MIN(consumer_count)           AS min_consumers
FROM Consecutive
GROUP BY server_name, queue_name
ORDER BY peak_pending DESC;
```

**Hourly Queue Throughput by Server** [sort:2] -- Messages processed per queue per server per hour using messages_added deltas. Shows workload distribution patterns and identifies peak activity periods.

```sql
WITH Hourly AS (
    SELECT
        server_name,
        queue_name,
        DATEADD(HOUR, DATEDIFF(HOUR, 0, collected_dttm), 0) AS hour_bucket,
        MIN(messages_added)          AS start_added,
        MAX(messages_added)          AS end_added
    FROM JBoss.QueueSnapshot
    WHERE collected_dttm >= DATEADD(HOUR, -24, GETDATE())
    GROUP BY server_name, queue_name,
             DATEADD(HOUR, DATEDIFF(HOUR, 0, collected_dttm), 0)
)
SELECT server_name, queue_name, hour_bucket,
       end_added - start_added       AS messages_this_hour
FROM Hourly
WHERE end_added - start_added > 0
ORDER BY server_name, queue_name, hour_bucket;
```

**Dead Consumer Detection** [sort:3] -- Queues where messages are being added but no consumers are listening. Work is being queued with nobody to process it.

```sql
SELECT
    server_name,
    queue_name,
    collected_dttm,
    message_count,
    delivering_count,
    consumer_count,
    messages_added
FROM JBoss.QueueSnapshot
WHERE consumer_count = 0
  AND messages_added > 0
  AND collected_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY collected_dttm DESC, server_name, queue_name;
```

**Busiest Queues (Last Hour)** [sort:4] -- Top queues ranked by throughput in the last hour. Identifies which queues are carrying the heaviest workload and which servers they run on.

```sql
WITH Recent AS (
    SELECT
        server_name,
        queue_name,
        MIN(messages_added)          AS start_added,
        MAX(messages_added)          AS end_added
    FROM JBoss.QueueSnapshot
    WHERE collected_dttm >= DATEADD(HOUR, -1, GETDATE())
    GROUP BY server_name, queue_name
)
SELECT server_name, queue_name,
       end_added - start_added       AS messages_last_hour
FROM Recent
WHERE end_added - start_added > 0
ORDER BY messages_last_hour DESC;
```

  - **Snapshot**: [sort:1] Queue snapshots are collected in the same cycle as the parent Snapshot row. The server_id and collected_dttm values align between the two tables, enabling correlated analysis of server health and queue state at the same point in time.
  - **ConfigHistory**: [sort:2] ConfigHistory tracks messaging pool configuration (thread pool sizes, connection pool sizes) that affects queue processing capacity. Changes to these settings may explain shifts in queue throughput or backlog patterns.


### Snapshot

Append-only point-in-time snapshots for DM application servers. Each collection cycle produces one row per monitored server capturing HTTP responsiveness, CIM service state, JBoss process metrics, server uptime, and JBoss Management API metrics including JVM memory, threading, Undertow HTTP statistics, transaction health, IO worker pool state, and main datasource connection pool utilization. Used for freeze detection, response time trending, performance diagnosis, and service availability history.

**Data Flow:** Collect-JBossMetrics.ps1 inserts one row per JBoss-enabled APP_SERVER in ServerRegistry per collection cycle. Five data sources feed each row: (1) HTTP responsiveness via Invoke-WebRequest to the DM splash page, (2) CIM service state via Win32_Service for DebtManager-Host, (3) CIM process metrics via Win32_Process for the main JBoss java.exe, (4) CIM server uptime via Win32_OperatingSystem, and (5) JBoss Management API via composite REST operations to the domain controller for JVM memory, threading, Undertow HTTP stats, transactions, IO worker pool, and main datasource pool metrics. The Control Center JBoss Monitoring page reads this table for current status display, health indicators, and performance trending. Retention is managed by snapshot_retention_days in GlobalConfig.

**JBoss Process Identification:** [sort:1] Each DM app server runs multiple java.exe processes in a tiered tree: service wrapper, JBoss bootstrap, management layer, and the main application server. The collector identifies the main JBoss process by selecting the java.exe with the largest WorkingSetSize (~9-10 GB), which reliably distinguishes it from the smaller bootstrap and management processes.

**Partial Snapshot on Failure:** [sort:2] If one data source fails (e.g., CIM timeout but HTTP succeeds), the snapshot is still inserted with NULL values for the failed source. This preserves whatever data was successfully collected rather than discarding an entire cycle. Every collection cycle produces exactly one row per server regardless of partial failures.

**Composite API Collection:** [sort:3] Management API metrics are collected via composite REST operations to the JBoss domain controller on APP. One composite call per server retrieves server state, JVM memory, JVM threads, datasource pool stats, Undertow HTTP stats, transaction stats, and IO worker pool state in a single round trip (~65ms per server). This minimizes API call count to 3 per collection cycle for all health metrics. The domain controller fans out queries to APP2 and APP3 internally. All API columns are nullable — they remain NULL when the Management API is unreachable, preserving HTTP and CIM data collection independently.

**DS Pool Alert Episode Tracking:** [sort:4] Alert detection uses two consecutive snapshots with ds_in_use_count at or above the per-server threshold from ServerRegistry.jboss_ds_alert_threshold. A single spike is ignored to avoid false positives from normal batch workload variations. Episode tracking via ds_alert_fired prevents duplicate alerts during an ongoing event. Recovery requires two consecutive snapshots where all three conditions are met simultaneously: HTTP status 200 (server reachable), ds_in_use_count below threshold (pool healthy), and positive undertow_processing_ms delta (application processing work). NULL undertow delta does not count as recovery — this handles the JVM restart scenario where cumulative counters reset and no prior value exists for comparison. The three-metric recovery condition prevents premature episode closure during the death spiral phase where connections bleed off via transaction timeouts but the server remains unresponsive.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| snapshot_id (IDENTITY) | int | No | IDENTITY | Auto-incrementing primary key. |
| server_id | int | No | — | FK to dbo.ServerRegistry. Identifies which DM application server this snapshot is for. |
| server_name | varchar(128) | No | — | Server hostname denormalized from ServerRegistry for direct querying without joins. |
| collected_dttm | datetime | No | getdate() | When this snapshot was collected. Defaults to GETDATE() at insert time. |
| http_status_code | int | Yes | — | HTTP response status code from the responsiveness request. 200 indicates a responding server. NULL if the request timed out or failed to connect. |
| http_response_ms | int | Yes | — | HTTP response time in milliseconds. Measures total round-trip time for the responsiveness request. |
| http_error_message | varchar(500) | Yes | — | Error message captured when the HTTP request fails (timeout, connection refused, DNS failure, etc.). NULL on successful requests. |
| service_name | varchar(100) | Yes | — | Windows service name queried via CIM (DebtManager-Controller on APP, DebtManager-Host on all three servers). |
| service_state | varchar(50) | Yes | — | Windows service state from CIM: Running, Stopped, StartPending, StopPending, etc. |
| service_start_mode | varchar(50) | Yes | — | Service startup configuration: Auto, Manual, Disabled. |
| jboss_process_id | int | Yes | — | Windows process ID of the main JBoss java.exe process (the large grandchild in the process tree). |
| jboss_working_set_mb | int | Yes | — | JBoss java.exe working set memory in megabytes. |
| jboss_thread_count | int | Yes | — | Thread count of the main JBoss java.exe process. |
| jboss_handle_count | int | Yes | — | Handle count of the main JBoss java.exe process. |
| server_uptime_hours | decimal(10,1) | Yes | — | Server uptime in hours calculated from Win32_OperatingSystem.LastBootUpTime. |
| api_server_state | varchar(30) | Yes | — | JBoss server state from the Management API. Values: running, stopped, reload-required, restart-required. NULL when Management API is unreachable. |
| jvm_heap_used_mb | int | Yes | — | Current JVM heap memory usage in megabytes from the Management API. Compare against jvm_heap_max_mb to calculate utilization percentage. Rising toward max indicates GC pressure. |
| jvm_heap_max_mb | int | Yes | — | Maximum JVM heap size in megabytes from the Management API. Configured via JVM -Xmx parameter (typically 8192 MB). Provides the denominator for heap utilization percentage. |
| jvm_nonheap_used_mb | int | Yes | — | JVM non-heap memory usage in megabytes from the Management API. Includes metaspace and code cache. Gradual growth without stabilization may indicate a classloader leak. |
| jvm_thread_count | int | Yes | — | Current JVM thread count from the Management API. Baseline is approximately 800-830 at idle. Sustained increase well above peak indicates potential thread exhaustion. |
| jvm_thread_peak | int | Yes | — | Peak JVM thread count since JVM start from the Management API. Provides the high-water mark for thread usage. Resets on JBoss restart. |
| undertow_request_count | bigint | Yes | — | Cumulative HTTP request count since JVM start from the Undertow HTTP listener. The delta between consecutive snapshots indicates request throughput per interval. |
| undertow_error_count | bigint | Yes | — | Cumulative HTTP error count since JVM start from the Undertow HTTP listener. The delta between consecutive snapshots indicates error rate per interval. Should normally be zero. |
| undertow_bytes_sent | bigint | Yes | — | Cumulative bytes sent since JVM start from the Undertow HTTP listener. The delta between consecutive snapshots indicates outbound throughput per interval. |
| undertow_processing_ms | bigint | Yes | — | Cumulative request processing time in milliseconds since JVM start. Requires record-request-start-time enabled on the HTTP listener. The delta divided by request count delta gives average response time per interval. |
| undertow_max_proc_ms | bigint | Yes | — | Maximum single request processing time in milliseconds since JVM start. Identifies the slowest individual request the server has handled. Resets on JBoss restart. |
| io_worker_queue_size | int | Yes | — | Number of requests waiting for an IO worker thread from the Undertow worker pool. Zero is healthy. Any sustained non-zero value indicates request processing is falling behind incoming request rate. |
| tx_committed | bigint | Yes | — | Cumulative committed transaction count since JVM start. The delta between consecutive snapshots indicates transaction throughput per interval. |
| tx_inflight | int | Yes | — | Currently active (in-flight) transaction count. A sustained high value may indicate long-running transactions or transaction leaks. |
| tx_timed_out | bigint | Yes | — | Cumulative timed-out transaction count since JVM start. Transaction timeout is configured at 900 seconds (15 minutes). Any increase indicates a transaction was stuck for at least 15 minutes. |
| tx_rollbacks | bigint | Yes | — | Cumulative application-initiated rollback count since JVM start. Rollbacks can be normal business logic (validation failures, duplicate checks). The delta and ratio to committed transactions indicates health. |
| tx_aborted | bigint | Yes | — | Cumulative aborted transaction count since JVM start. Typically matches rollback count. Divergence from rollbacks may indicate system-level transaction failures. |
| tx_heuristics | bigint | Yes | — | Cumulative heuristic decision count since JVM start. Heuristic decisions occur when the transaction manager cannot determine the outcome of a two-phase commit and makes a unilateral decision. Non-zero values warrant investigation. |
| ds_active_count | int | Yes | — | Total connections in the main datasource pool (active = in-use + idle). The pool prefills to min-pool-size (300) at startup and can grow to max-pool-size (1000). |
| ds_in_use_count | int | Yes | — | Connections currently checked out by application code from the main datasource pool. This is the primary database load indicator. Compare against ds_active_count for utilization. |
| ds_idle_count | int | Yes | — | Connections available in the main datasource pool not currently in use. Low idle count with high in-use count indicates heavy database demand. |
| ds_wait_count | int | Yes | — | Threads currently waiting for a connection from the main datasource pool. Should always be zero. Any non-zero value indicates the pool is exhausted and application threads are blocked. |
| ds_max_used_count | int | Yes | — | Peak concurrent in-use connections since JVM start from the main datasource pool. Indicates the high-water mark for database connection demand. Resets on JBoss restart. |
| ds_timed_out | bigint | Yes | — | Cumulative connections destroyed by the pool idle timeout housekeeping since JVM start. This is normal pool maintenance, not connection failures. The pool prefills 300 but usage is typically much lower, so idle connections are periodically recycled. |
| ds_avg_get_time_ms | int | Yes | — | Average time in milliseconds to acquire a connection from the main datasource pool. Low values (1-5ms) are normal. Increasing values indicate pool contention or connection creation overhead. |
| ds_max_wait_time_ms | int | Yes | — | Longest wait time in milliseconds for a connection from the main datasource pool since JVM start. High values indicate a period of pool contention occurred. Resets on JBoss restart. |
| ds_alert_fired | bit | No | 0 | Whether this snapshot is part of an active DS pool alert episode. Set to 1 by Collect-JBossMetrics.ps1 on the triggering snapshot (second consecutive reading above threshold) and on all subsequent snapshots while the episode remains open. Returns to 0 (default) when recovery is confirmed: two consecutive snapshots with HTTP 200, ds_in_use_count below threshold, and positive undertow_processing_ms delta. |

  - **PK_Snapshot** (CLUSTERED): snapshot_id -- PRIMARY KEY
  - **IX_Snapshot_collected** (NONCLUSTERED): collected_dttm
  - **IX_Snapshot_server_collected** (NONCLUSTERED): server_name, collected_dttm [includes: http_response_ms, http_status_code]

**Foreign Keys:**

  - **FK_Snapshot_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Response Time Trend (Last 24 Hours)** [sort:1] -- Hourly average and maximum HTTP response times per server. Identifies slow periods and response time degradation patterns.

```sql
SELECT
    server_name,
    DATEADD(HOUR, DATEDIFF(HOUR, 0, collected_dttm), 0) AS hour_bucket,
    COUNT(*)                     AS samples,
    AVG(http_response_ms)        AS avg_response_ms,
    MAX(http_response_ms)        AS max_response_ms,
    MIN(http_response_ms)        AS min_response_ms
FROM JBoss.Snapshot
WHERE collected_dttm >= DATEADD(HOUR, -24, GETDATE())
  AND http_status_code = 200
GROUP BY server_name,
         DATEADD(HOUR, DATEDIFF(HOUR, 0, collected_dttm), 0)
ORDER BY server_name, hour_bucket;
```

**HTTP Failure History** [sort:2] -- Snapshots where the HTTP health check failed — non-200 status or error message. Each row represents a potential freeze or outage event.

```sql
SELECT
    server_name,
    collected_dttm,
    http_status_code,
    http_response_ms,
    http_error_message,
    service_state,
    api_server_state
FROM JBoss.Snapshot
WHERE http_status_code <> 200
   OR http_error_message IS NOT NULL
ORDER BY collected_dttm DESC;
```

**JVM Heap Trend (Last 24 Hours)** [sort:3] -- Hourly average and peak heap utilization percentage per server. Rising averages over time may indicate a memory leak or increasing workload.

```sql
SELECT
    server_name,
    DATEADD(HOUR, DATEDIFF(HOUR, 0, collected_dttm), 0) AS hour_bucket,
    AVG(CAST(jvm_heap_used_mb AS FLOAT) / NULLIF(jvm_heap_max_mb, 0) * 100)
                                 AS avg_heap_pct,
    MAX(CAST(jvm_heap_used_mb AS FLOAT) / NULLIF(jvm_heap_max_mb, 0) * 100)
                                 AS max_heap_pct,
    AVG(jvm_heap_used_mb)        AS avg_heap_used_mb,
    MAX(jvm_heap_max_mb)         AS heap_max_mb
FROM JBoss.Snapshot
WHERE collected_dttm >= DATEADD(HOUR, -24, GETDATE())
  AND jvm_heap_used_mb IS NOT NULL
GROUP BY server_name,
         DATEADD(HOUR, DATEDIFF(HOUR, 0, collected_dttm), 0)
ORDER BY server_name, hour_bucket;
```

**Connection Pool Pressure Events** [sort:4] -- Snapshots where threads were waiting for database connections (ds_wait_count > 0). Any occurrence means the pool was exhausted and application threads were blocked.

```sql
SELECT
    server_name,
    collected_dttm,
    ds_wait_count,
    ds_in_use_count,
    ds_active_count,
    ds_idle_count,
    ds_max_used_count,
    ds_avg_get_time_ms,
    ds_max_wait_time_ms,
    jvm_heap_used_mb,
    tx_inflight
FROM JBoss.Snapshot
WHERE ds_wait_count > 0
ORDER BY collected_dttm DESC;
```

**Transaction Anomalies** [sort:5] -- Snapshots with transaction timeouts or elevated in-flight counts. Timed-out transactions exceeded the 15-minute timeout. High in-flight counts may indicate long-running operations or transaction leaks.

```sql
SELECT
    server_name,
    collected_dttm,
    tx_inflight,
    tx_committed,
    tx_timed_out,
    tx_rollbacks,
    tx_aborted,
    tx_heuristics,
    http_response_ms,
    ds_in_use_count,
    jvm_heap_used_mb
FROM JBoss.Snapshot
WHERE tx_timed_out > 0
   OR tx_inflight >= 10
ORDER BY collected_dttm DESC;
```

  - **ServerRegistry**: [sort:1] server_id references dbo.ServerRegistry. Only servers with server_type = 'APP_SERVER' and jboss_enabled = 1 produce snapshot rows. server_name is denormalized from ServerRegistry for direct querying without joins.
  - **QueueSnapshot**: [sort:2] Each Snapshot collection cycle produces a corresponding set of QueueSnapshot rows for the same server and collected_dttm. Snapshot captures the server-level health summary; QueueSnapshot provides per-queue detail for the same point in time. Joined on server_id and collected_dttm for correlated analysis.
  - **ConfigHistory**: [sort:3] ConfigHistory provides the configuration context for interpreting Snapshot metrics. To determine what configuration was in effect for a given snapshot, find the most recent ConfigHistory row per setting where collected_dttm is less than or equal to the snapshot timestamp.


### Collect-JBossMetrics.ps1

Collects health metrics from all JBoss-enabled application servers in ServerRegistry using five independent data sources per server: HTTP responsiveness (Invoke-WebRequest), CIM service state and JBoss process metrics (Win32_Service, Win32_Process, Win32_OperatingSystem), and JBoss Management API metrics via composite REST operations to the domain controller. Writes to three tables per cycle: one Snapshot row per server (35 metric columns covering HTTP, CIM, JVM memory/threads, Undertow HTTP stats, transactions, IO worker pool, and datasource connection pool), ~18 QueueSnapshot rows per server (per-queue JMS stats for all active queues), and ConfigHistory rows only on detected configuration changes. Nine API calls per cycle total (3 health composites + 3 queue composites + 3 config composites). First script to use Initialize-XFActsScript shared infrastructure and shared Get-ServiceCredentials for JBoss Management API authentication.

**Data Flow:** Reads server list from dbo.ServerRegistry filtered by jboss_enabled = 1 and server_type = 'APP_SERVER'. Reads http_base_path, http_timeout_seconds, and api_timeout_seconds from dbo.GlobalConfig (module JBoss, category App). Reads management_api_url from GlobalConfig (module JBoss, category Admin) with dynamic fallback to ServerRegistry is_domain_controller lookup. Retrieves JBoss Management API credentials via shared Get-ServiceCredentials (ServiceName: JBossManagement) from dbo.Credentials using two-tier decryption. Loads config change detection cache from JBoss.ConfigHistory (most recent value per server per setting). For each server: (1) HTTP GET via Invoke-WebRequest for responsiveness, (2) CIM session for service state, process metrics, and uptime, (3) composite REST call to JBoss domain controller for server state, JVM memory, JVM threads, datasource pool stats, Undertow HTTP stats, transaction stats, and IO worker pool, (4) composite REST call for 18 active JMS queue stats, (5) composite REST call for 9 config settings compared against cached values. Writes one row per server to JBoss.Snapshot, ~18 rows per server to JBoss.QueueSnapshot, and 0-N rows to JBoss.ConfigHistory (only on change or first capture). Reports completion to the orchestrator via Complete-OrchestratorTask.

**Five Independent Collection Layers:** [sort:1] HTTP, CIM, health composite, queue composite, and config composite are all independent. If the Management API is unreachable, HTTP and CIM data still gets written with API columns as NULL. If the queue composite fails, the health snapshot is still inserted. If the config check fails, health and queue data are preserved. Every cycle produces exactly one Snapshot row per server regardless of partial failures.

**Composite API Design:** [sort:2] All Management API metrics are collected via composite REST operations — multiple reads batched into single HTTP POSTs. Three composites per server: health (7 steps: server state, JVM memory, JVM threads, datasource pool, Undertow, transactions, IO worker), queue (18 steps: one per active queue), and config (9 steps: mix of server-instance-level and profile-level settings). Total: 9 API calls per cycle across 3 servers, completing in ~1-2 seconds. Hand-built JSON strings are used because PowerShell 5.1 ConvertTo-Json does not reliably serialize the nested array-of-objects address format JBoss requires.

**Config Change Detection:** [sort:3] At script start, the most recent config value per server per setting is loaded from ConfigHistory into a hashtable cache. Each cycle reads current values via the config composite and compares against the cache. Rows are only written when a value differs or on first capture (NULL previous). Profile-level settings (datasource pool sizes, messaging config) are read from the full-ha profile and recorded per server. Server-level settings (worker threads, IO threads, heap max, transaction timeout) are read from the runtime server instance. Typically produces 0 rows per cycle after the initial 27-row baseline (9 settings x 3 servers).

**JBoss Address Path Case Sensitivity:** [sort:4] JBoss domain controller uses lowercase hostnames in its address paths (dm-prod-app, dm-prod-app2-inst1) while ServerRegistry stores uppercase (DM-PROD-APP). The script applies ToLower() when building API address paths. The original server name is preserved for database INSERTs and logging. Server instance naming follows the pattern {hostname}-inst1.

**Shared Infrastructure Adoption:** [sort:5] Uses Initialize-XFActsScript from xFACts-OrchestratorFunctions.ps1 for standardized startup (SQL module loading, logging, execute guard, application identity). Uses shared Get-SqlData, Invoke-SqlNonQuery, and Write-Log functions instead of script-local copies. Uses shared Get-ServiceCredentials for JBoss Management API credential retrieval via the two-tier decryption pattern. No script-local function definitions required beyond Get-ConfigValue (convenience wrapper) and Invoke-JBossAPI (Management API call wrapper).

  - **JBoss.Snapshot**: [sort:1] Sole writer. Inserts one row per server per collection cycle containing all 35 metric columns from five data sources (HTTP, CIM service, CIM process, CIM uptime, Management API health composite). API columns remain NULL when the Management API is unreachable.
  - **JBoss.QueueSnapshot**: [sort:2] Sole writer. Inserts one row per active JMS queue per server per cycle (~18 queues x 3 servers = ~54 rows). Queue list is hardcoded based on discovery session — queues with observed throughput (messages-added > 0). Only written when the Management API health composite succeeds.
  - **JBoss.ConfigHistory**: [sort:3] Sole writer. Write-on-change only — inserts rows when a JBoss config value differs from the previously recorded value or on first capture. Tracks 9 settings per server: worker/IO thread counts, datasource pool min/max, JVM heap max, transaction timeout, messaging pool min/max/threads.
  - **dbo.ServerRegistry**: [sort:4] Reads server list filtered by is_active = 1, jboss_enabled = 1, server_type = 'APP_SERVER'. Uses server_id, server_name, and server_role. Falls back to is_domain_controller lookup for Management API URL if GlobalConfig entry is missing.
  - **dbo.GlobalConfig**: [sort:5] Reads JBoss/App settings: http_base_path, http_timeout_seconds, api_timeout_seconds. Reads JBoss/Admin setting: management_api_url. Falls back to script defaults if unavailable.
  - **dbo.Credentials**: [sort:6] Reads JBossManagement service credentials (JBossUser, JBossPassword) via shared Get-ServiceCredentials function using two-tier decryption. Credentials authenticate all Management API REST calls to the JBoss domain controller.
  - **Orchestrator.ProcessRegistry**: [sort:7] Receives TaskId and ProcessId parameters from the orchestrator engine for completion callback via Complete-OrchestratorTask. Reports server count, queue row count, and config change count in the output message.



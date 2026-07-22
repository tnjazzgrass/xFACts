# Object_Metadata: JBoss
Source: dbo.Object_Metadata
Generated: 2026-07-22 05:46:01

## Collect-JBossMetrics.ps1 (Script)

### category #0

App

### data_flow #0

Reads server list from dbo.ServerRegistry filtered by jboss_enabled = 1 and server_type = 'APP_SERVER'. Reads http_base_path, http_timeout_seconds, and api_timeout_seconds from dbo.GlobalConfig (module JBoss, category App). Reads management_api_url from GlobalConfig (module JBoss, category Admin) with dynamic fallback to ServerRegistry is_domain_controller lookup. Retrieves JBoss Management API credentials via shared Get-ServiceCredentials (ServiceName: JBossManagement) from dbo.Credentials using two-tier decryption. Loads config change detection cache from JBoss.ConfigHistory (most recent value per server per setting). For each server: (1) HTTP GET via Invoke-WebRequest for responsiveness, (2) CIM session for service state, process metrics, and uptime, (3) composite REST call to JBoss domain controller for server state, JVM memory, JVM threads, datasource pool stats, Undertow HTTP stats, transaction stats, and IO worker pool, (4) composite REST call for 18 active JMS queue stats, (5) composite REST call for 9 config settings compared against cached values. Writes one row per server to JBoss.Snapshot, ~18 rows per server to JBoss.QueueSnapshot, and 0-N rows to JBoss.ConfigHistory (only on change or first capture). Reports completion to the orchestrator via Complete-OrchestratorTask.

### description #0

Collects health metrics from all JBoss-enabled application servers in ServerRegistry using five independent data sources per server: HTTP responsiveness (Invoke-WebRequest), CIM service state and JBoss process metrics (Win32_Service, Win32_Process, Win32_OperatingSystem), and JBoss Management API metrics via composite REST operations to the domain controller. Writes to three tables per cycle: one Snapshot row per server (35 metric columns covering HTTP, CIM, JVM memory/threads, Undertow HTTP stats, transactions, IO worker pool, and datasource connection pool), ~18 QueueSnapshot rows per server (per-queue JMS stats for all active queues), and ConfigHistory rows only on detected configuration changes. Nine API calls per cycle total (3 health composites + 3 queue composites + 3 config composites). First script to use Initialize-XFActsScript shared infrastructure and shared Get-ServiceCredentials for JBoss Management API authentication.

### design_note #1
Title: Five Independent Collection Layers
Description: Each data source is isolated in its own try/catch block

HTTP, CIM, health composite, queue composite, and config composite are all independent. If the Management API is unreachable, HTTP and CIM data still gets written with API columns as NULL. If the queue composite fails, the health snapshot is still inserted. If the config check fails, health and queue data are preserved. Every cycle produces exactly one Snapshot row per server regardless of partial failures.

### design_note #2
Title: Composite API Design
Description: Nine API calls per cycle using JBoss composite operations

All Management API metrics are collected via composite REST operations — multiple reads batched into single HTTP POSTs. Three composites per server: health (7 steps: server state, JVM memory, JVM threads, datasource pool, Undertow, transactions, IO worker), queue (18 steps: one per active queue), and config (9 steps: mix of server-instance-level and profile-level settings). Total: 9 API calls per cycle across 3 servers, completing in ~1-2 seconds. Hand-built JSON strings are used because PowerShell 5.1 ConvertTo-Json does not reliably serialize the nested array-of-objects address format JBoss requires.

### design_note #3
Title: Config Change Detection
Description: Write-on-change pattern with in-memory cache

At script start, the most recent config value per server per setting is loaded from ConfigHistory into a hashtable cache. Each cycle reads current values via the config composite and compares against the cache. Rows are only written when a value differs or on first capture (NULL previous). Profile-level settings (datasource pool sizes, messaging config) are read from the full-ha profile and recorded per server. Server-level settings (worker threads, IO threads, heap max, transaction timeout) are read from the runtime server instance. Typically produces 0 rows per cycle after the initial 27-row baseline (9 settings x 3 servers).

### design_note #4
Title: JBoss Address Path Case Sensitivity
Description: Server names must be lowercased for Management API calls

JBoss domain controller uses lowercase hostnames in its address paths (dm-prod-app, dm-prod-app2-inst1) while ServerRegistry stores uppercase (DM-PROD-APP). The script applies ToLower() when building API address paths. The original server name is preserved for database INSERTs and logging. Server instance naming follows the pattern {hostname}-inst1.

### design_note #5
Title: Shared Infrastructure Adoption
Description: First script to use Initialize-XFActsScript and shared Get-ServiceCredentials

Uses Initialize-XFActsScript from xFACts-OrchestratorFunctions.ps1 for standardized startup (SQL module loading, logging, execute guard, application identity). Uses shared Get-SqlData, Invoke-SqlNonQuery, and Write-Log functions instead of script-local copies. Uses shared Get-ServiceCredentials for JBoss Management API credential retrieval via the two-tier decryption pattern. No script-local function definitions required beyond Get-ConfigValue (convenience wrapper) and Invoke-JBossAPI (Management API call wrapper).

### module #0

DmOps

### relationship_note #1
Title: JBoss.Snapshot

Sole writer. Inserts one row per server per collection cycle containing all 35 metric columns from five data sources (HTTP, CIM service, CIM process, CIM uptime, Management API health composite). API columns remain NULL when the Management API is unreachable.

### relationship_note #2
Title: JBoss.QueueSnapshot

Sole writer. Inserts one row per active JMS queue per server per cycle (~18 queues x 3 servers = ~54 rows). Queue list is hardcoded based on discovery session — queues with observed throughput (messages-added > 0). Only written when the Management API health composite succeeds.

### relationship_note #3
Title: JBoss.ConfigHistory

Sole writer. Write-on-change only — inserts rows when a JBoss config value differs from the previously recorded value or on first capture. Tracks 9 settings per server: worker/IO thread counts, datasource pool min/max, JVM heap max, transaction timeout, messaging pool min/max/threads.

### relationship_note #4
Title: dbo.ServerRegistry

Reads server list filtered by is_active = 1, jboss_enabled = 1, server_type = 'APP_SERVER'. Uses server_id, server_name, and server_role. Falls back to is_domain_controller lookup for Management API URL if GlobalConfig entry is missing.

### relationship_note #5
Title: dbo.GlobalConfig

Reads JBoss/App settings: http_base_path, http_timeout_seconds, api_timeout_seconds. Reads JBoss/Admin setting: management_api_url. Falls back to script defaults if unavailable.

### relationship_note #6
Title: dbo.Credentials

Reads JBossManagement service credentials (JBossUser, JBossPassword) via shared Get-ServiceCredentials function using two-tier decryption. Credentials authenticate all Management API REST calls to the JBoss domain controller.

### relationship_note #7
Title: Orchestrator.ProcessRegistry

Receives TaskId and ProcessId parameters from the orchestrator engine for completion callback via Complete-OrchestratorTask. Reports server count, queue row count, and config change count in the output message.

## ConfigHistory (Table)

### category #0

App

### data_flow #0

Collect-JBossMetrics.ps1 reads JBoss configuration values via the Management API each collection cycle and compares them against the most recent recorded values in this table. Rows are only written when a value changes or on first capture. Settings tracked include IO worker pool sizing, datasource pool min/max, JVM heap max, transaction timeout, and messaging pool configuration. The Control Center JBoss Monitoring page can reference this table to provide configuration context alongside performance metrics.

### description #0

Change detection log for JBoss configuration settings on DM application servers. Each collection cycle reads current configuration values from the Management API and compares against the most recent recorded value per server per setting. A row is written only when a value differs from the previously recorded value, or on first capture when no prior record exists. Provides historical context for interpreting performance metrics — configuration at any point in time can be determined by finding the most recent row per setting before that timestamp.

### design_note #1
Title: Write on Change Only

The collector reads configuration values every cycle but only writes to this table when a value differs from the most recently recorded value for that server and setting. This keeps the table extremely small — typically one initial baseline row per setting per server, with additional rows only when someone changes a JBoss configuration. The comparison is done in the script against cached values, so no database write occurs on the vast majority of cycles.

### design_note #2
Title: Point-in-Time Config Lookup

To determine what configuration was in effect at a specific time, query the most recent row per server per setting where collected_dttm is less than or equal to the target timestamp. This enables correlation between metric anomalies and configuration changes — if a pool size was changed Tuesday and performance degraded Wednesday, the timeline is visible in the data.

### module #0

DmOps

### query #1
Title: Current Configuration Per Server
Description: Most recent value for each tracked setting on each server. Shows the configuration currently in effect.

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

### query #2
Title: Configuration Differences Across Servers
Description: Compares current settings between servers to identify configuration drift. Settings with identical values across all servers are excluded.

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

### relationship_note #1
Title: Snapshot

Configuration changes recorded here provide context for Snapshot metric trends. A change in datasource pool sizing, worker thread count, or transaction timeout may correlate with shifts in the health metrics captured in Snapshot.

### relationship_note #2
Title: QueueSnapshot

Messaging configuration changes (thread pool sizes, connection factory settings) tracked here may explain shifts in queue processing patterns observed in QueueSnapshot.

### description / collected_dttm #7

When the change was detected. This is the detection time, not necessarily the exact time the configuration was modified — the actual change could have occurred at any point since the previous collection cycle. Defaults to GETDATE() at insert time.

### description / config_history_id #1

Auto-incrementing primary key.

### description / previous_value #6

The previously recorded value for this server and setting. NULL on the first capture when no prior record exists. Populated on subsequent rows so that each change record is self-contained — the old and new values are visible in a single row without needing to look at the prior record.

### description / server_id #2

FK to dbo.ServerRegistry. Identifies which DM application server this configuration observation is from.

### description / server_name #3

Server hostname denormalized from ServerRegistry for direct querying without joins.

### description / setting_name #4

Configuration setting identifier using a descriptive key name (e.g., worker_max_threads, datasource_max_pool, jvm_heap_max_mb, transaction_timeout_seconds). Consistent naming across servers enables cross-server comparison.

### description / setting_value #5

Observed value of the setting stored as a string for flexibility across different data types (integers, booleans, strings). The collector reads the current value from the JBoss Management API each cycle.

## QueueSnapshot (Table)

### category #0

App

### data_flow #0

Collect-JBossMetrics.ps1 reads JMS queue metrics via composite REST operations to the JBoss Management API domain controller. For each server, one composite call retrieves all active queue stats. Only queues with historical throughput (messages-added > 0 at any point) are collected — approximately 12-15 queues per server out of 65 total. The Control Center JBoss Monitoring page reads this table for queue health display and backlog detection. Retention is managed alongside Snapshot by snapshot_retention_days in GlobalConfig.

### description #0

Per-queue JMS metrics for DM application servers. Each collection cycle produces one row per active queue per monitored server, capturing pending message count, delivery state, consumer count, and cumulative throughput. Used for queue backlog detection, dead consumer alerting, and workload distribution analysis across servers.

### design_note #1
Title: Active Queue Filtering

Each DM app server has 65 JMS queues configured, but only 12-15 have meaningful throughput. The collector maintains an active queue list based on observed messages-added > 0 and only collects metrics for those queues. This keeps row volume manageable (~45 rows per cycle across 3 servers) while ensuring all operationally relevant queues are monitored.

### design_note #2
Title: Queues Are Independent Per Server

JMS queues operate independently on each server — they are not clustered despite cluster configuration existing. When a server freezes, all messages in its queues stop processing. Other servers cannot pick up the work. This means queue health must be monitored per-server, not in aggregate.

### design_note #3
Title: Workload Distribution Pattern

Queue activity correlates with server role: user-driven queues (fixedFeeEventQueue, documentOutputRequestQueue, consumerCacheRequestQueue) concentrate on APP2 where users connect via SharePoint. Batch job queues (jobBatchQueue, nbReleaseQueue, paymentsImportPartitionQueue) concentrate on APP and APP3 where Task Scheduler scripts direct work. Cross-server comparison of messages-added deltas reveals workload balance.

### module #0

DmOps

### query #1
Title: Sustained Queue Backlog
Description: Queues with pending messages in consecutive snapshots — indicates consumers are not keeping pace. Uses a self-join to find queues that stayed backed up across two collection cycles.

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

### query #2
Title: Hourly Queue Throughput by Server
Description: Messages processed per queue per server per hour using messages_added deltas. Shows workload distribution patterns and identifies peak activity periods.

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

### query #3
Title: Dead Consumer Detection
Description: Queues where messages are being added but no consumers are listening. Work is being queued with nobody to process it.

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

### query #4
Title: Busiest Queues (Last Hour)
Description: Top queues ranked by throughput in the last hour. Identifies which queues are carrying the heaviest workload and which servers they run on.

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

### relationship_note #1
Title: Snapshot

Queue snapshots are collected in the same cycle as the parent Snapshot row. The server_id and collected_dttm values align between the two tables, enabling correlated analysis of server health and queue state at the same point in time.

### relationship_note #2
Title: ConfigHistory

ConfigHistory tracks messaging pool configuration (thread pool sizes, connection pool sizes) that affects queue processing capacity. Changes to these settings may explain shifts in queue throughput or backlog patterns.

### description / collected_dttm #9

When this queue snapshot was collected. Defaults to GETDATE() at insert time. Aligns with the corresponding Snapshot.collected_dttm for the same collection cycle.

### description / consumer_count #7

Number of active consumers listening on this queue. Zero consumers on a queue that normally has throughput indicates a dead queue — no processing will occur regardless of message volume. Consumer counts vary by queue: requestQueue typically has 67-70, most others have 1-6.

### description / delivering_count #6

Messages currently being delivered to consumers. These are in-flight — picked up by a consumer but not yet acknowledged. High delivering_count with stable message_count indicates normal processing. High delivering_count with rising message_count indicates consumers are stuck.

### description / message_count #5

Pending messages in the queue waiting to be processed. Zero is healthy. A sustained non-zero value indicates the queue is backing up — consumers are not keeping pace with producers. This is the primary queue health indicator.

### description / messages_added #8

Cumulative messages added to the queue since JVM start. The delta between consecutive snapshots indicates queue throughput per interval. Resets on JBoss restart. Used for workload distribution analysis across servers.

### description / queue_name #4

JMS queue name as reported by the JBoss Management API (e.g., jobBatchQueue, requestQueue, fixedFeeEventQueue). Only active queues with historical message throughput are collected — idle queues with zero messages-added are excluded.

### description / queue_snapshot_id #1

Auto-incrementing primary key.

### description / server_id #2

FK to dbo.ServerRegistry. Identifies which DM application server this queue snapshot is from.

### description / server_name #3

Server hostname denormalized from ServerRegistry for direct querying without joins.

## Snapshot (Table)

### category #0

App

### data_flow #0

Collect-JBossMetrics.ps1 inserts one row per JBoss-enabled APP_SERVER in ServerRegistry per collection cycle. Five data sources feed each row: (1) HTTP responsiveness via Invoke-WebRequest to the DM splash page, (2) CIM service state via Win32_Service for DebtManager-Host, (3) CIM process metrics via Win32_Process for the main JBoss java.exe, (4) CIM server uptime via Win32_OperatingSystem, and (5) JBoss Management API via composite REST operations to the domain controller for JVM memory, threading, Undertow HTTP stats, transactions, IO worker pool, and main datasource pool metrics. The Control Center JBoss Monitoring page reads this table for current status display, health indicators, and performance trending. Retention is managed by snapshot_retention_days in GlobalConfig.

### description #0

Append-only point-in-time snapshots for DM application servers. Each collection cycle produces one row per monitored server capturing HTTP responsiveness, CIM service state, JBoss process metrics, server uptime, and JBoss Management API metrics including JVM memory, threading, Undertow HTTP statistics, transaction health, IO worker pool state, and main datasource connection pool utilization. Used for freeze detection, response time trending, performance diagnosis, and service availability history.

### design_note #1
Title: JBoss Process Identification

Each DM app server runs multiple java.exe processes in a tiered tree: service wrapper, JBoss bootstrap, management layer, and the main application server. The collector identifies the main JBoss process by selecting the java.exe with the largest WorkingSetSize (~9-10 GB), which reliably distinguishes it from the smaller bootstrap and management processes.

### design_note #2
Title: Partial Snapshot on Failure

If one data source fails (e.g., CIM timeout but HTTP succeeds), the snapshot is still inserted with NULL values for the failed source. This preserves whatever data was successfully collected rather than discarding an entire cycle. Every collection cycle produces exactly one row per server regardless of partial failures.

### design_note #3
Title: Composite API Collection

Management API metrics are collected via composite REST operations to the JBoss domain controller on APP. One composite call per server retrieves server state, JVM memory, JVM threads, datasource pool stats, Undertow HTTP stats, transaction stats, and IO worker pool state in a single round trip (~65ms per server). This minimizes API call count to 3 per collection cycle for all health metrics. The domain controller fans out queries to APP2 and APP3 internally. All API columns are nullable — they remain NULL when the Management API is unreachable, preserving HTTP and CIM data collection independently.

### design_note #4
Title: DS Pool Alert Episode Tracking

Alert detection uses two consecutive snapshots with ds_in_use_count at or above the per-server threshold from ServerRegistry.jboss_ds_alert_threshold. A single spike is ignored to avoid false positives from normal batch workload variations. Episode tracking via ds_alert_fired prevents duplicate alerts during an ongoing event. Recovery requires two consecutive snapshots where all three conditions are met simultaneously: HTTP status 200 (server reachable), ds_in_use_count below threshold (pool healthy), and positive undertow_processing_ms delta (application processing work). NULL undertow delta does not count as recovery — this handles the JVM restart scenario where cumulative counters reset and no prior value exists for comparison. The three-metric recovery condition prevents premature episode closure during the death spiral phase where connections bleed off via transaction timeouts but the server remains unresponsive.

### module #0

DmOps

### query #1
Title: Response Time Trend (Last 24 Hours)
Description: Hourly average and maximum HTTP response times per server. Identifies slow periods and response time degradation patterns.

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

### query #2
Title: HTTP Failure History
Description: Snapshots where the HTTP health check failed — non-200 status or error message. Each row represents a potential freeze or outage event.

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

### query #3
Title: JVM Heap Trend (Last 24 Hours)
Description: Hourly average and peak heap utilization percentage per server. Rising averages over time may indicate a memory leak or increasing workload.

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

### query #4
Title: Connection Pool Pressure Events
Description: Snapshots where threads were waiting for database connections (ds_wait_count > 0). Any occurrence means the pool was exhausted and application threads were blocked.

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

### query #5
Title: Transaction Anomalies
Description: Snapshots with transaction timeouts or elevated in-flight counts. Timed-out transactions exceeded the 15-minute timeout. High in-flight counts may indicate long-running operations or transaction leaks.

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

### relationship_note #1
Title: ServerRegistry

server_id references dbo.ServerRegistry. Only servers with server_type = 'APP_SERVER' and jboss_enabled = 1 produce snapshot rows. server_name is denormalized from ServerRegistry for direct querying without joins.

### relationship_note #2
Title: QueueSnapshot

Each Snapshot collection cycle produces a corresponding set of QueueSnapshot rows for the same server and collected_dttm. Snapshot captures the server-level health summary; QueueSnapshot provides per-queue detail for the same point in time. Joined on server_id and collected_dttm for correlated analysis.

### relationship_note #3
Title: ConfigHistory

ConfigHistory provides the configuration context for interpreting Snapshot metrics. To determine what configuration was in effect for a given snapshot, find the most recent ConfigHistory row per setting where collected_dttm is less than or equal to the snapshot timestamp.

### description / api_server_state #17

JBoss server state from the Management API. Values: running, stopped, reload-required, restart-required. NULL when Management API is unreachable.

### description / collected_dttm #4

When this snapshot was collected. Defaults to GETDATE() at insert time.

### description / ds_active_count #35

Total connections in the main datasource pool (active = in-use + idle). The pool prefills to min-pool-size (300) at startup and can grow to max-pool-size (1000).

### description / ds_alert_fired #43

Whether this snapshot is part of an active DS pool alert episode. Set to 1 by Collect-JBossMetrics.ps1 on the triggering snapshot (second consecutive reading above threshold) and on all subsequent snapshots while the episode remains open. Returns to 0 (default) when recovery is confirmed: two consecutive snapshots with HTTP 200, ds_in_use_count below threshold, and positive undertow_processing_ms delta.

### description / ds_avg_get_time_ms #41

Average time in milliseconds to acquire a connection from the main datasource pool. Low values (1-5ms) are normal. Increasing values indicate pool contention or connection creation overhead.

### description / ds_idle_count #37

Connections available in the main datasource pool not currently in use. Low idle count with high in-use count indicates heavy database demand.

### description / ds_in_use_count #36

Connections currently checked out by application code from the main datasource pool. This is the primary database load indicator. Compare against ds_active_count for utilization.

### description / ds_max_used_count #39

Peak concurrent in-use connections since JVM start from the main datasource pool. Indicates the high-water mark for database connection demand. Resets on JBoss restart.

### description / ds_max_wait_time_ms #42

Longest wait time in milliseconds for a connection from the main datasource pool since JVM start. High values indicate a period of pool contention occurred. Resets on JBoss restart.

### description / ds_timed_out #40

Cumulative connections destroyed by the pool idle timeout housekeeping since JVM start. This is normal pool maintenance, not connection failures. The pool prefills 300 but usage is typically much lower, so idle connections are periodically recycled.

### description / ds_wait_count #38

Threads currently waiting for a connection from the main datasource pool. Should always be zero. Any non-zero value indicates the pool is exhausted and application threads are blocked.

### description / http_error_message #8

Error message captured when the HTTP request fails (timeout, connection refused, DNS failure, etc.). NULL on successful requests.

### description / http_response_ms #6

HTTP response time in milliseconds. Measures total round-trip time for the responsiveness request.

### description / http_status_code #5

HTTP response status code from the responsiveness request. 200 indicates a responding server. NULL if the request timed out or failed to connect.

### description / io_worker_queue_size #28

Number of requests waiting for an IO worker thread from the Undertow worker pool. Zero is healthy. Any sustained non-zero value indicates request processing is falling behind incoming request rate.

### description / jboss_handle_count #15

Handle count of the main JBoss java.exe process.

### description / jboss_process_id #12

Windows process ID of the main JBoss java.exe process (the large grandchild in the process tree).

### description / jboss_thread_count #14

Thread count of the main JBoss java.exe process.

### description / jboss_working_set_mb #13

JBoss java.exe working set memory in megabytes.

### description / jvm_heap_max_mb #19

Maximum JVM heap size in megabytes from the Management API. Configured via JVM -Xmx parameter (typically 8192 MB). Provides the denominator for heap utilization percentage.

### description / jvm_heap_used_mb #18

Current JVM heap memory usage in megabytes from the Management API. Compare against jvm_heap_max_mb to calculate utilization percentage. Rising toward max indicates GC pressure.

### description / jvm_nonheap_used_mb #20

JVM non-heap memory usage in megabytes from the Management API. Includes metaspace and code cache. Gradual growth without stabilization may indicate a classloader leak.

### description / jvm_thread_count #21

Current JVM thread count from the Management API. Baseline is approximately 800-830 at idle. Sustained increase well above peak indicates potential thread exhaustion.

### description / jvm_thread_peak #22

Peak JVM thread count since JVM start from the Management API. Provides the high-water mark for thread usage. Resets on JBoss restart.

### description / server_id #2

FK to dbo.ServerRegistry. Identifies which DM application server this snapshot is for.

### description / server_name #3

Server hostname denormalized from ServerRegistry for direct querying without joins.

### description / server_uptime_hours #16

Server uptime in hours calculated from Win32_OperatingSystem.LastBootUpTime.

### description / service_name #9

Windows service name queried via CIM (DebtManager-Controller on APP, DebtManager-Host on all three servers).

### description / service_start_mode #11

Service startup configuration: Auto, Manual, Disabled.

### description / service_state #10

Windows service state from CIM: Running, Stopped, StartPending, StopPending, etc.

### description / snapshot_id #1

Auto-incrementing primary key.

### description / tx_aborted #33

Cumulative aborted transaction count since JVM start. Typically matches rollback count. Divergence from rollbacks may indicate system-level transaction failures.

### description / tx_committed #29

Cumulative committed transaction count since JVM start. The delta between consecutive snapshots indicates transaction throughput per interval.

### description / tx_heuristics #34

Cumulative heuristic decision count since JVM start. Heuristic decisions occur when the transaction manager cannot determine the outcome of a two-phase commit and makes a unilateral decision. Non-zero values warrant investigation.

### description / tx_inflight #30

Currently active (in-flight) transaction count. A sustained high value may indicate long-running transactions or transaction leaks.

### description / tx_rollbacks #32

Cumulative application-initiated rollback count since JVM start. Rollbacks can be normal business logic (validation failures, duplicate checks). The delta and ratio to committed transactions indicates health.

### description / tx_timed_out #31

Cumulative timed-out transaction count since JVM start. Transaction timeout is configured at 900 seconds (15 minutes). Any increase indicates a transaction was stuck for at least 15 minutes.

### description / undertow_bytes_sent #25

Cumulative bytes sent since JVM start from the Undertow HTTP listener. The delta between consecutive snapshots indicates outbound throughput per interval.

### description / undertow_error_count #24

Cumulative HTTP error count since JVM start from the Undertow HTTP listener. The delta between consecutive snapshots indicates error rate per interval. Should normally be zero.

### description / undertow_max_proc_ms #27

Maximum single request processing time in milliseconds since JVM start. Identifies the slowest individual request the server has handled. Resets on JBoss restart.

### description / undertow_processing_ms #26

Cumulative request processing time in milliseconds since JVM start. Requires record-request-start-time enabled on the HTTP listener. The delta divided by request count delta gives average response time per interval.

### description / undertow_request_count #23

Cumulative HTTP request count since JVM start from the Undertow HTTP listener. The delta between consecutive snapshots indicates request throughput per interval.

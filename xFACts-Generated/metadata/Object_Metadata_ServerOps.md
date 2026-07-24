# Object_Metadata: ServerOps
Source: dbo.Object_Metadata
Generated: 2026-07-24 04:05:08

## Activity_DMV_ConnectionHealth (Table)

### category #0  [metadata_id: 1717]

Activity

### data_flow #0  [metadata_id: 2516]

Collect-DMVMetrics.ps1 queries sys.dm_exec_sessions with a CTE that classifies sessions as zombies based on configurable idle threshold from GlobalConfig (threshold_zombie_idle_minutes). Inserts one row per server per collection cycle. sp_Activity_CorrelateIncidents reads the latest zombie_count for threshold evaluation. sp_DiagnoseServerHealth reads this table for connection and zombie analysis (Section 6). The Control Center Server Health page reads this table for zombie trend charts and connection pool gauges.

### description #0  [metadata_id: 107]

Stores point-in-time connection pool health snapshots collected via DMV polling, providing visibility into zombie connections, open transactions, and JDBC session breakdown.

### design_note #1  [metadata_id: 2517]
Title: Zombie Connection Definition

A session is classified as a zombie when ALL three conditions are met: status = sleeping, open_transaction_count = 0, and idle time exceeds the configurable threshold (GlobalConfig threshold_zombie_idle_minutes, default 60). This three-part test avoids false positives from legitimately sleeping sessions that are part of connection pools or have pending transactions.

### design_note #2  [metadata_id: 2518]
Title: JDBC Session Tracking

The jdbc_total, jdbc_sleeping, and jdbc_zombie columns track JDBC driver sessions separately because applications using Java connection pooling (JBoss, Tomcat) are the primary source of zombie connections. JDBC sessions are identified by program_name LIKE '%JDBC%'. Other application sessions are included in the overall session counts but not broken out individually.

### module #0  [metadata_id: 1613]

ServerOps

### query #1  [metadata_id: 2649]
Title: Current Connection Health (All Servers)
Description: Latest snapshot per server

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

### query #2  [metadata_id: 2650]
Title: Zombie Trend for Specific Server
Description: Last 24 hours of zombie counts for DM-PROD-DB

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

### query #3  [metadata_id: 2651]
Title: High Zombie Count Events
Description: Snapshots where zombie count exceeded threshold

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

### query #4  [metadata_id: 2652]
Title: JDBC Pool Health Over Time
Description: Track JDBC connection pool behavior

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

### query #5  [metadata_id: 2653]
Title: Open Transaction Monitoring
Description: Sessions with long-running open transactions

-- Sessions with long-running open transactions
SELECT 
    server_name,
    snapshot_dttm,
    sessions_with_open_tran,
    oldest_open_tran_min
FROM ServerOps.Activity_DMV_ConnectionHealth
WHERE oldest_open_tran_min > 60
ORDER BY oldest_open_tran_min DESC;

### query #6  [metadata_id: 2654]
Title: Zombie Accumulation Rate
Description: How fast are zombies accumulating?

-- How fast are zombies accumulating?
SELECT 
    snapshot_dttm,
    zombie_count,
    zombie_count - LAG(zombie_count) OVER (ORDER BY snapshot_dttm) AS zombie_delta
FROM ServerOps.Activity_DMV_ConnectionHealth
WHERE server_name = 'DM-PROD-DB'
  AND snapshot_dttm >= DATEADD(HOUR, -24, GETDATE())
ORDER BY snapshot_dttm;

### description / collected_dttm #15  [metadata_id: 1260]

When the snapshot was imported into xFACts

### description / jdbc_sleeping #13  [metadata_id: 1258]

Sleeping JDBC sessions

### description / jdbc_total #12  [metadata_id: 1257]

All JDBC driver sessions

### description / jdbc_zombie #14  [metadata_id: 1259]

JDBC sessions meeting zombie criteria

### description / oldest_open_tran_min #11  [metadata_id: 1256]

Minutes since last request for oldest session with open transaction

### description / oldest_zombie_idle_min #9  [metadata_id: 1254]

Minutes idle for the oldest zombie session

### description / running_sessions #7  [metadata_id: 1252]

Sessions with status = 'running'

### description / server_id #2  [metadata_id: 1247]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 1248]

Denormalized server name for easier querying

### description / sessions_with_open_tran #10  [metadata_id: 1255]

Sessions with open_transaction_count > 0

### description / sleeping_sessions #6  [metadata_id: 1251]

Sessions with status = 'sleeping'

### description / snapshot_dttm #4  [metadata_id: 1249]

When the snapshot was captured

### description / snapshot_id #1  [metadata_id: 1246]

Unique identifier for the snapshot

### description / total_sessions #5  [metadata_id: 1250]

All user sessions (session_id > 50)

### description / zombie_count #8  [metadata_id: 1253]

Sessions meeting zombie criteria (sleeping, no open tran, idle > threshold)

## Activity_DMV_IO_Stats (Table)

### category #0  [metadata_id: 1718]

Activity

### data_flow #0  [metadata_id: 2522]

Collect-DMVMetrics.ps1 queries sys.dm_io_virtual_file_stats joined to sys.master_files on each monitored server, aggregating by database and file type (DATA or LOG). Inserts multiple rows per server per collection cycle (one per database/file-type combination). sp_DiagnoseServerHealth does not currently use this table directly. The Control Center Server Health page reads this table for I/O latency charts and database throughput analysis.

### description #0  [metadata_id: 114]

Stores point-in-time I/O latency snapshots collected via DMV polling, providing visibility into storage performance and database file throughput across all monitored servers.

### design_note #1  [metadata_id: 2523]
Title: Database/File-Type Aggregation

Raw DMV data is per-file. The collection query aggregates to database + file type (DATA vs LOG) to reduce row volume while preserving the ability to distinguish data file I/O from transaction log I/O. Individual file-level detail is not captured. Like WaitStats, all numeric columns are cumulative since service startup and require delta calculation.

### module #0  [metadata_id: 1614]

ServerOps

### query #1  [metadata_id: 2655]
Title: Current I/O State (All Databases)
Description: Latest snapshot per server/database/file_type

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

### query #2  [metadata_id: 2656]
Title: Average Read Latency by Database (Last 24 Hours)
Description: Calculate average read latency per I/O operation

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

### query #3  [metadata_id: 2657]
Title: High Latency Events
Description: Find intervals with high read latency (> 20ms average)

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

### description / collected_dttm #13  [metadata_id: 1336]

When the snapshot was imported into xFACts

### description / database_name #5  [metadata_id: 1328]

Database name

### description / file_type #6  [metadata_id: 1329]

File type: DATA or LOG

### description / io_stall_read_ms #11  [metadata_id: 1334]

Cumulative milliseconds waiting on reads (since service start)

### description / io_stall_write_ms #12  [metadata_id: 1335]

Cumulative milliseconds waiting on writes (since service start)

### description / num_of_bytes_read #9  [metadata_id: 1332]

Cumulative bytes read (since service start)

### description / num_of_bytes_written #10  [metadata_id: 1333]

Cumulative bytes written (since service start)

### description / num_of_reads #7  [metadata_id: 1330]

Cumulative read operations (since service start)

### description / num_of_writes #8  [metadata_id: 1331]

Cumulative write operations (since service start)

### description / server_id #2  [metadata_id: 1325]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 1326]

Denormalized server name for easier querying

### description / snapshot_dttm #4  [metadata_id: 1327]

When the snapshot was captured

### description / snapshot_id #1  [metadata_id: 1324]

Unique identifier for the snapshot

## Activity_DMV_Memory (Table)

### category #0  [metadata_id: 1719]

Activity

### data_flow #0  [metadata_id: 2512]

Collect-DMVMetrics.ps1 queries sys.dm_os_performance_counters (Buffer Manager and Memory Manager categories) on each monitored server and inserts one row per server per collection cycle. sp_Activity_CorrelateIncidents reads the latest snapshot per server to evaluate PLE thresholds and writes results to Activity_Heartbeat and Activity_IncidentLog. sp_DiagnoseServerHealth reads this table for memory health analysis (Section 2) including PLE trending, buffer cache hit ratio, and memory grants pending. The Control Center Server Health page reads this table for memory health gauges and trend charts.

### description #0  [metadata_id: 100]

Stores point-in-time memory health snapshots collected via DMV polling, providing visibility into Page Life Expectancy, buffer cache efficiency, and memory pressure indicators.

### design_note #1  [metadata_id: 2513]
Title: Performance Counter Sources

PLE and buffer cache hit ratio come from the Buffer Manager performance counter object. Memory grants pending, target memory, and total memory come from the Memory Manager object. Free list stalls and lazy writes are cumulative counters from Buffer Manager — they reset on service restart and require delta calculation in queries to derive per-interval rates.

### module #0  [metadata_id: 1615]

ServerOps

### query #1  [metadata_id: 2658]
Title: Current Memory State (All Servers)
Description: Latest snapshot per server

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

### query #2  [metadata_id: 2659]
Title: PLE Trend for Specific Server
Description: Last 24 hours of PLE for DM-PROD-DB

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

### query #3  [metadata_id: 2660]
Title: Low PLE Events
Description: Snapshots where PLE dropped below 300 seconds

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

### query #4  [metadata_id: 2661]
Title: Lazy Writes Delta (Memory Pressure Indicator)
Description: Calculate lazy writes per interval

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

### description / buffer_cache_hit_ratio #6  [metadata_id: 1165]

Percentage of pages found in buffer cache without disk read

### description / collected_dttm #12  [metadata_id: 1171]

When the snapshot was imported into xFACts

### description / free_list_stalls #10  [metadata_id: 1169]

Cumulative stalls waiting for free buffer page (since service start)

### description / lazy_writes #11  [metadata_id: 1170]

Cumulative pages flushed by lazy writer (since service start)

### description / memory_grants_pending #7  [metadata_id: 1166]

Number of queries waiting for memory grant

### description / ple_seconds #5  [metadata_id: 1164]

Page Life Expectancy - seconds a page stays in buffer pool

### description / server_id #2  [metadata_id: 1161]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 1162]

Denormalized server name for easier querying

### description / snapshot_dttm #4  [metadata_id: 1163]

When the snapshot was captured

### description / snapshot_id #1  [metadata_id: 1160]

Unique identifier for the snapshot

### description / target_memory_mb #8  [metadata_id: 1167]

Maximum memory SQL Server can use (from max server memory)

### description / total_memory_mb #9  [metadata_id: 1168]

Current memory committed to buffer pool

## Activity_DMV_WaitStats (Table)

### category #0  [metadata_id: 1720]

Activity

### data_flow #0  [metadata_id: 2519]

Collect-DMVMetrics.ps1 queries sys.dm_os_wait_stats for all wait types with wait_time_ms > 0 on each monitored server. Inserts multiple rows per server per collection cycle (one per active wait type). sp_Activity_CorrelateIncidents reads HADR_SYNC_COMMIT wait deltas between consecutive snapshots for threshold evaluation. sp_DiagnoseServerHealth reads this table for wait category analysis (Section 3) and HADR health analysis (Section 4). The Control Center Server Health page reads this table for wait statistics breakdown charts.

### description #0  [metadata_id: 112]

Stores point-in-time wait statistics snapshots collected via DMV polling, providing visibility into what SQL Server is waiting on and enabling performance trend analysis.

### design_note #1  [metadata_id: 2520]
Title: Multiple Rows Per Snapshot

Unlike other DMV tables that store one row per server per cycle, WaitStats stores one row per wait type per server per cycle. This captures the full wait type breakdown without pre-aggregating into categories, enabling flexible analysis at query time. The volume is higher but the granularity supports ad-hoc investigation of any wait type.

### design_note #2  [metadata_id: 2521]
Title: Cumulative Counters With Delta Analysis

All three numeric columns (waiting_tasks_count, wait_time_ms, signal_wait_time_ms) are cumulative since SQL Server startup. Delta calculation between consecutive snapshots yields per-interval activity. A negative delta indicates a service restart. The signal_wait_time_ms component isolates CPU scheduling delays from resource wait time, helping distinguish CPU pressure from I/O or lock contention.

### module #0  [metadata_id: 1616]

ServerOps

### query #1  [metadata_id: 2662]
Title: Current Top Waits (All Servers)
Description: Top wait types by cumulative time per server (latest snapshot)

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

### query #2  [metadata_id: 2663]
Title: Wait Deltas Over Time (Specific Wait Type)
Description: PAGEIOLATCH_SH trend for last 24 hours

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

### query #3  [metadata_id: 2664]
Title: Top Waits in Last Hour (Delta-Based)
Description: What did we wait on most in the last hour?

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

### query #4  [metadata_id: 2665]
Title: Detect Service Restarts
Description: Find snapshots where counters reset (service restarted)

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

### description / collected_dttm #9  [metadata_id: 1310]

When the snapshot was imported into xFACts

### description / server_id #2  [metadata_id: 1303]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 1304]

Denormalized server name for easier querying

### description / signal_wait_time_ms #8  [metadata_id: 1309]

Cumulative signal wait time in milliseconds (since service start)

### description / snapshot_dttm #4  [metadata_id: 1305]

When the snapshot was captured

### description / snapshot_id #1  [metadata_id: 1302]

Unique identifier for the snapshot row

### description / wait_time_ms #7  [metadata_id: 1308]

Cumulative wait time in milliseconds (since service start)

### description / wait_type #5  [metadata_id: 1306]

SQL Server wait type name

### description / waiting_tasks_count #6  [metadata_id: 1307]

Cumulative count of waits on this type (since service start)

## Activity_DMV_Workload (Table)

### category #0  [metadata_id: 1721]

Activity

### data_flow #0  [metadata_id: 2514]

Collect-DMVMetrics.ps1 queries sys.dm_os_performance_counters (General Statistics and SQL Statistics categories), sys.dm_exec_requests for blocked/active counts, and @@CPU_BUSY/@@IO_BUSY for server-level utilization on each monitored server. Inserts one row per server per collection cycle. sp_DiagnoseServerHealth reads this table for workload context. The Control Center Server Health page reads this table for connection count and batch throughput charts.

### description #0  [metadata_id: 104]

Stores point-in-time workload health snapshots collected via DMV polling, providing visibility into connection counts, blocking, active requests, and query compilation rates.

### design_note #1  [metadata_id: 2515]
Title: Cumulative Counters Require Delta Calculation

batch_requests, sql_compilations, sql_recompilations, cpu_busy_ms, and io_busy_ms are cumulative counters that reset on service restart. Raw values are stored; delta calculation between consecutive snapshots is performed in queries. A negative delta indicates a service restart occurred between snapshots.

### module #0  [metadata_id: 1617]

ServerOps

### query #1  [metadata_id: 2666]
Title: Current Workload State (All Servers)
Description: Latest snapshot per server

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

### query #2  [metadata_id: 2667]
Title: Connection Trend for Specific Server
Description: Last 24 hours of connections for DM-PROD-DB

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

### query #3  [metadata_id: 2668]
Title: Blocking Events Over Time
Description: Snapshots where blocking was occurring

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

### query #4  [metadata_id: 2669]
Title: Batch Requests Per Interval (Throughput)
Description: Calculate batch requests per interval

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

### query #5  [metadata_id: 2670]
Title: Compilation Rate Analysis
Description: Identify periods of high compilation/recompilation

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

### query #6  [metadata_id: 2671]
Title: CPU Utilization Between Snapshots
Description: Calculate server CPU busy percentage between snapshots

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

### description / active_request_count #7  [metadata_id: 1213]

Number of requests in running, runnable, or suspended state

### description / batch_requests #8  [metadata_id: 1214]

Cumulative batch requests received (since service start)

### description / blocked_session_count #6  [metadata_id: 1212]

Number of sessions currently blocked by another session

### description / collected_dttm #11  [metadata_id: 1217]

When the snapshot was imported into xFACts

### description / cpu_busy_ms #12  [metadata_id: 1218]

Cumulative CPU busy time in milliseconds (@@CPU_BUSY * @@TIMETICKS / 1000 since service start)

### description / io_busy_ms #13  [metadata_id: 1219]

Cumulative I/O busy time in milliseconds (@@IO_BUSY * @@TIMETICKS / 1000 since service start)

### description / server_id #2  [metadata_id: 1208]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 1209]

Denormalized server name for easier querying

### description / snapshot_dttm #4  [metadata_id: 1210]

When the snapshot was captured

### description / snapshot_id #1  [metadata_id: 1207]

Unique identifier for the snapshot

### description / sql_compilations #9  [metadata_id: 1215]

Cumulative SQL compilations (since service start)

### description / sql_recompilations #10  [metadata_id: 1216]

Cumulative SQL recompilations (since service start)

### description / user_connections #5  [metadata_id: 1211]

Current number of user connections

## Activity_DMV_xFACts (Table)

### category #0  [metadata_id: 1722]

Activity

### data_flow #0  [metadata_id: 2524]

Collect-DMVMetrics.ps1 queries sys.dm_exec_sessions filtered to program_name LIKE 'xFACts%' on each monitored server. Inserts one row per active xFACts session per server per collection cycle. sp_DiagnoseServerHealth reads this table for monitoring overhead analysis (Section 5). Provides self-monitoring capability: xFACts tracking its own resource impact on the servers it monitors.

### description #0  [metadata_id: 120]

Stores point-in-time snapshots of active xFACts sessions on each monitored server, capturing cumulative resource counters for impact analysis.

### design_note #1  [metadata_id: 2525]
Title: Self-Monitoring Footprint

Captures cumulative resource counters (cpu_time_ms, reads, logical_reads, writes, memory_usage_pages) for every active xFACts session on each monitored server. This allows detection of scenarios where xFACts monitoring itself is contributing to server load — particularly the XE collection script reading large event files. The program_name filter matches the ApplicationName parameter set by all xFACts PowerShell scripts.

### design_note #2  [metadata_id: 2526]
Title: Per-Session Granularity

Unlike other DMV tables that aggregate to one row per server, this table stores one row per xFACts session per server. A server may have multiple concurrent xFACts sessions (collection scripts, diagnostic queries). Each session's individual resource consumption is tracked to identify which specific xFACts process is the heaviest consumer.

### module #0  [metadata_id: 1618]

ServerOps

### query #1  [metadata_id: 2672]
Title: Current xFACts Connection Footprint
Description: Latest snapshot of all xFACts sessions per server

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

### query #2  [metadata_id: 2673]
Title: Session Count by Server Over Time
Description: How many xFACts sessions per server per snapshot

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

### query #3  [metadata_id: 2674]
Title: Control Center Resource Delta
Description: Track Control Center resource consumption between snapshots

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

### query #4  [metadata_id: 2675]
Title: Processes by Resource Consumption
Description: Which xFACts components use the most resources (latest snapshot)

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

### description / collected_dttm #17  [metadata_id: 1413]

When the snapshot was imported into xFACts

### description / cpu_time_ms #9  [metadata_id: 1405]

Cumulative CPU time in milliseconds since session connect

### description / last_request_end #14  [metadata_id: 1410]

When the session last completed a request

### description / last_request_start #13  [metadata_id: 1409]

When the session last started a request

### description / logical_reads #11  [metadata_id: 1407]

Cumulative buffer cache reads since session connect

### description / login_name #7  [metadata_id: 1403]

Login that owns the session

### description / memory_usage_pages #16  [metadata_id: 1412]

Number of 8KB pages used by the session

### description / open_transaction_count #15  [metadata_id: 1411]

Number of open transactions (should be 0 for well-behaved sessions)

### description / program_name #6  [metadata_id: 1402]

xFACts component name from connection string ApplicationName

### description / reads #10  [metadata_id: 1406]

Cumulative physical disk reads since session connect

### description / server_id #2  [metadata_id: 1398]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 1399]

Denormalized server name for easier querying

### description / session_id #5  [metadata_id: 1401]

SQL Server session ID (SPID)

### description / snapshot_dttm #4  [metadata_id: 1400]

When the snapshot was captured

### description / snapshot_id #1  [metadata_id: 1397]

Unique identifier for the snapshot

### description / status #8  [metadata_id: 1404]

Session status (running, sleeping, etc.)

### description / writes #12  [metadata_id: 1408]

Cumulative writes since session connect

## Activity_Heartbeat (Table)

### category #0  [metadata_id: 1723]

Activity

### data_flow #0  [metadata_id: 2551]

sp_Activity_CorrelateIncidents writes one row per server per collection cycle after evaluating all thresholds. The overall_status reflects the worst condition detected across all threshold checks. Key metrics (PLE, HADR delta, zombie count, cache hit) are denormalized from the DMV tables for efficient dashboard queries. Activity_IncidentLog rows created in the same cycle are back-linked via heartbeat_id. The Control Center Server Health page reads this table for the health status timeline and health summary statistics.

### description #0  [metadata_id: 37]

Per-cycle health pulse recording overall status and key metrics for each monitored server, providing a foundation for daily health reporting and trend analysis.

### design_note #1  [metadata_id: 2552]
Title: Denormalized Key Metrics

PLE, HADR delta, zombie count, and buffer cache hit ratio are copied from the latest DMV snapshots rather than requiring joins back to Activity_DMV_Memory, Activity_DMV_WaitStats, and Activity_DMV_ConnectionHealth. This trades storage for query simplicity and supports efficient dashboard aggregation (e.g., "240 healthy, 20 warning, 22 critical cycles yesterday").

### design_note #2  [metadata_id: 2553]
Title: Duplicate Prevention on Re-Run

sp_Activity_CorrelateIncidents checks for an existing heartbeat with the same server_name and snapshot_dttm before inserting. This prevents duplicate heartbeats if the procedure is called multiple times for the same collection cycle (e.g., during testing or recovery). Incidents from the cycle are linked to the heartbeat via heartbeat_id using SCOPE_IDENTITY after the heartbeat insert.

### module #0  [metadata_id: 1619]

ServerOps

### query #1  [metadata_id: 2676]
Title: Daily Health Summary by Server

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

### query #2  [metadata_id: 2677]
Title: Problem Periods (Last 24 Hours)

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

### query #3  [metadata_id: 2678]
Title: Hourly Health Pattern

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

### query #4  [metadata_id: 2679]
Title: Server Comparison

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

### description / buffer_cache_hit_pct #9  [metadata_id: 208]

Buffer cache hit ratio percentage

### description / created_dttm #10  [metadata_id: 209]

When the heartbeat was recorded

### description / hadr_sync_delta_ms #7  [metadata_id: 206]

HADR_SYNC_COMMIT wait delta since previous snapshot (AG servers only)

### description / heartbeat_id #1  [metadata_id: 200]

Unique identifier for the heartbeat record

### description / incidents_logged #5  [metadata_id: 204]

Number of incidents logged during this cycle

### description / overall_status #4  [metadata_id: 203]

HEALTHY, WARNING, or CRITICAL

### status_value / overall_status #1  [metadata_id: 2554]
Title: HEALTHY

No threshold crossings detected for this server in this collection cycle. All monitored metrics are within acceptable ranges.

### status_value / overall_status #2  [metadata_id: 2555]
Title: WARNING

One or more metrics crossed warning thresholds but none reached critical. Examples: PLE below warning threshold, HADR delta above warning but below critical, memory grants pending above threshold.

### status_value / overall_status #3  [metadata_id: 2556]
Title: CRITICAL

One or more metrics crossed critical thresholds. Examples: PLE below critical threshold (PLE_CRISIS), HADR delta above critical threshold (HADR_SPIKE_CRITICAL). Critical status takes precedence over warning in the same cycle.

### description / ple_seconds #6  [metadata_id: 205]

Page Life Expectancy at this snapshot

### description / server_name #2  [metadata_id: 201]

Server this heartbeat is for

### description / snapshot_dttm #3  [metadata_id: 202]

Timestamp of the DMV collection cycle

### description / zombie_count #8  [metadata_id: 207]

Number of zombie connections detected

## Activity_IncidentLog (Table)

### category #0  [metadata_id: 1724]

Activity

### data_flow #0  [metadata_id: 2562]

sp_Activity_CorrelateIncidents writes one row per threshold crossing detected during each collection cycle. Each row includes the triggering metric, its value, the correlation window searched, and any concurrent activity found in Activity_XE_LRQ. The heartbeat_id column is back-filled after the Activity_Heartbeat row is created for the same cycle. The Control Center Server Health page reads this table for the incident timeline and root cause analysis display.

### description #0  [metadata_id: 133]

Detailed incident records capturing threshold crossings with correlated concurrent activity, providing automated root cause evidence for performance issues.

### design_note #1  [metadata_id: 2563]
Title: Automated Root Cause Evidence

The correlated_* columns (source, query, user, database, duration_sec, count) capture the top concurrent long-running query and total LRQ count within the correlation window. The correlated_source field identifies known process patterns: Redgate Monitoring, xFACts XE Collection, Azure Data Sync, BIDATA Builds, PROCESSES Jobs. This transforms a threshold alert from "PLE crashed" into "PLE crashed and here are the three queries that were running" without manual investigation.

### design_note #2  [metadata_id: 2564]
Title: Cross-Server HADR Correlation

For HADR incidents, the secondary_server column identifies the AG partner, and the correlated_* columns contain activity from that secondary server — not the primary where the wait was detected. This reflects the causal relationship: heavy workload on the secondary causes synchronous commit delays on the primary. The AG partner is dynamically determined from ServerRegistry using the ag_cluster_name field.

### module #0  [metadata_id: 1620]

ServerOps

### query #1  [metadata_id: 2680]
Title: Recent Incidents

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

### query #2  [metadata_id: 2681]
Title: Incidents by Correlated Source

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

### query #3  [metadata_id: 2682]
Title: Incident Timeline for Specific Server

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

### query #4  [metadata_id: 2683]
Title: HADR Incidents with Secondary Correlation

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

### query #5  [metadata_id: 2684]
Title: Daily Incident Summary

SELECT 
    CAST(detected_dttm AS DATE) AS day,
    incident_type_code,
    COUNT(*) AS count,
    COUNT(DISTINCT primary_server) AS servers_affected
FROM ServerOps.Activity_IncidentLog
GROUP BY CAST(detected_dttm AS DATE), incident_type_code
ORDER BY day DESC, count DESC;

### description / acknowledged_by #18  [metadata_id: 1502]

Who reviewed this incident

### description / acknowledged_dttm #19  [metadata_id: 1503]

When the incident was reviewed

### description / correlated_count #16  [metadata_id: 1500]

Total number of LRQs found in the correlation window

### description / correlated_database #14  [metadata_id: 1498]

Database context of the correlated query

### description / correlated_duration_sec #15  [metadata_id: 1499]

Duration of the top correlated query in seconds

### description / correlated_query #12  [metadata_id: 1496]

Text of the top correlated query (truncated)

### description / correlated_source #11  [metadata_id: 1495]

Identified source pattern (e.g., Azure Data Sync, Redgate Monitoring)

### description / correlated_user #13  [metadata_id: 1497]

Username running the correlated query

### description / correlation_window_end #10  [metadata_id: 1494]

End of the correlation window (typically = detected_dttm)

### description / correlation_window_start #9  [metadata_id: 1493]

Start of the time window searched for correlated activity

### description / created_dttm #22  [metadata_id: 1506]

When the incident was logged

### description / detected_dttm #3  [metadata_id: 1487]

When the incident was detected (matches snapshot_dttm)

### description / heartbeat_id #21  [metadata_id: 1505]

FK to Activity_Heartbeat linking incident to its collection cycle

### description / incident_id #1  [metadata_id: 1485]

Unique identifier for the incident

### description / incident_type_code #2  [metadata_id: 1486]

FK to Activity_IncidentType (e.g., PLE_CRISIS, HADR_SPIKE)

### description / notes #20  [metadata_id: 1504]

Manual notes about the incident

### description / primary_metric_name #6  [metadata_id: 1490]

Metric that crossed threshold (e.g., ple_seconds, hadr_sync_commit_delta_ms)

### description / primary_metric_value #7  [metadata_id: 1491]

Value that crossed the threshold

### description / primary_server #5  [metadata_id: 1489]

Server where the threshold was crossed

### description / secondary_server #8  [metadata_id: 1492]

AG partner server (for HADR incidents) or NULL

### description / severity #4  [metadata_id: 1488]

WARNING or CRITICAL

### status_value / severity #1  [metadata_id: 2565]
Title: WARNING

Threshold crossing at warning level. Logged for PLE_WARNING, HADR_SPIKE, MEMORY_GRANTS_PENDING. Indicates the metric is outside normal range but not at crisis level.

### status_value / severity #2  [metadata_id: 2566]
Title: CRITICAL

Threshold crossing at critical level. Logged for PLE_CRISIS, HADR_SPIKE_CRITICAL. Indicates immediate attention may be needed.

### description / summary #17  [metadata_id: 1501]

Auto-generated human-readable summary of the incident

## Activity_IncidentType (Table)

### category #0  [metadata_id: 1725]

Activity

### data_flow #0  [metadata_id: 2557]

Pre-populated reference table. sp_Activity_CorrelateIncidents reads this table to get the correlation_window_min for each incident type when performing concurrent activity lookups. The incident_type_code values are used as foreign key references in Activity_IncidentLog. New incident types require both a row in this table and corresponding detection logic in the procedure.

### description #0  [metadata_id: 128]

Reference table defining incident types with default severity levels, correlation windows, and correlation targets for the incident detection system.

### design_note #1  [metadata_id: 2558]
Title: Code-Based Primary Key

Uses incident_type_code (e.g., PLE_CRISIS, HADR_SPIKE) as the primary key rather than an identity column. This makes Activity_IncidentLog entries self-documenting — the incident_type_code value conveys meaning without requiring a join to this reference table for basic queries.

### design_note #2  [metadata_id: 2559]
Title: Correlation Target Controls Cross-Server Lookup

The correlation_target column (SELF, SECONDARY, or NULL) tells sp_Activity_CorrelateIncidents where to search for concurrent long-running queries. SELF searches Activity_XE_LRQ on the same server (used for PLE issues caused by local queries). SECONDARY searches the AG partner (used for HADR spikes caused by workload on the secondary). NULL skips correlation entirely.

### module #0  [metadata_id: 1621]

ServerOps

### description / correlation_target #6  [metadata_id: 1469]

Where to look for correlated activity: SELF, SECONDARY, or NULL

### description / correlation_window_min #5  [metadata_id: 1468]

Minutes to look back when correlating concurrent activity

### description / created_dttm #8  [metadata_id: 1471]

When the incident type was created

### description / default_severity #4  [metadata_id: 1467]

Default severity level: WARNING or CRITICAL

### status_value / default_severity #1  [metadata_id: 2560]
Title: WARNING

Threshold crossing at warning level. Indicates a metric is outside normal range but not at crisis level. Used for PLE_WARNING, HADR_SPIKE, MEMORY_GRANTS_PENDING.

### status_value / default_severity #2  [metadata_id: 2561]
Title: CRITICAL

Threshold crossing at critical level. Indicates immediate attention may be needed. Used for PLE_CRISIS, HADR_SPIKE_CRITICAL.

### description / description #3  [metadata_id: 1466]

Detailed explanation of what this incident type represents

### description / incident_type_code #1  [metadata_id: 1464]

Unique code identifying the incident type (e.g., PLE_CRISIS, HADR_SPIKE)

### description / incident_type_name #2  [metadata_id: 1465]

Human-readable name for display

### description / is_active #7  [metadata_id: 1470]

Whether this incident type is currently being detected

## Activity_XE_AGHealth (Table)

### category #0  [metadata_id: 1726]

Activity

### data_flow #0  [metadata_id: 2539]

Collect-XEEvents.ps1 reads events from the AlwaysOn_health XE session on AG servers only (collected in a separate Step 4 loop targeting only DM-PROD-DB and DM-PROD-REP). Parses via Parse-AGHealthEvent and inserts individual events. The raw XML is optionally retained based on GlobalConfig aghealth_retain_raw_xml. The Control Center Server Health page reads this table for AG state change history and failover timeline.

### description #0  [metadata_id: 73]

Stores events from the AlwaysOn_health Extended Events session, capturing availability group state changes, replica health transitions, and synchronization events for AG monitoring.

### design_note #1  [metadata_id: 2540]
Title: Separate Collection Step for AG Servers

AlwaysOn_health is collected in Step 4 of Collect-XEEvents.ps1, separate from the Step 3 loop that processes custom xFACts sessions. This is because AlwaysOn_health is a Microsoft built-in session that only exists on servers participating in an Availability Group. The server list for Step 4 is queried separately, targeting only the known AG servers.

### design_note #2  [metadata_id: 2541]
Title: Configurable Raw XML Retention

Same pattern as Activity_XE_BlockedProcess. The raw_event_xml column is populated based on GlobalConfig aghealth_retain_raw_xml. Parsed fields cover the common AG state change attributes; raw XML is needed only for unusual event types or deep-dive analysis.

### module #0  [metadata_id: 1622]

ServerOps

### query #1  [metadata_id: 2685]
Title: Recent AG State Changes

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

### query #2  [metadata_id: 2686]
Title: Failover Events

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

### query #3  [metadata_id: 2687]
Title: AG Event Summary by Type

SELECT 
    event_type,
    COUNT(*) AS event_count,
    MIN(event_timestamp) AS first_occurrence,
    MAX(event_timestamp) AS last_occurrence
FROM ServerOps.Activity_XE_AGHealth
WHERE event_timestamp >= DATEADD(DAY, -30, GETDATE())
GROUP BY event_type
ORDER BY event_count DESC;

### description / alert_sent #22  [metadata_id: 762]

Whether an alert has been sent for this event

### description / alert_sent_dttm #23  [metadata_id: 763]

When the alert was sent

### description / availability_group_name #9  [metadata_id: 749]

Availability group name

### description / availability_replica_name #10  [metadata_id: 750]

Replica server name

### description / collected_dttm #19  [metadata_id: 759]

When the event was imported into xFACts

### description / current_state #8  [metadata_id: 748]

Current state after transition

### description / database_name #11  [metadata_id: 751]

Database name (for database-level events)

### description / ddl_action #15  [metadata_id: 755]

DDL action performed (CREATE, ALTER, DROP)

### description / ddl_phase #16  [metadata_id: 756]

DDL phase (START, COMMIT, ROLLBACK)

### description / ddl_statement #17  [metadata_id: 757]

Full DDL statement text

### description / error_message #14  [metadata_id: 754]

Full error message text

### description / error_number #12  [metadata_id: 752]

SQL Server error number

### description / error_severity #13  [metadata_id: 753]

Error severity level

### description / event_id #1  [metadata_id: 741]

Unique identifier for the event

### description / event_timestamp #4  [metadata_id: 744]

When the event occurred

### description / event_type #5  [metadata_id: 745]

Event name from AlwaysOn_health

### description / previous_state #7  [metadata_id: 747]

Previous state before transition

### description / raw_event_xml #18  [metadata_id: 758]

Complete event XML for forensic analysis

### description / server_id #2  [metadata_id: 742]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 743]

Denormalized server name for easier querying

### description / session_name #6  [metadata_id: 746]

Source XE session name

### description / source_file #20  [metadata_id: 760]

XE file the event was read from

### description / source_offset #21  [metadata_id: 761]

Byte offset within the source file

## Activity_XE_BlockedProcess (Table)

### category #0  [metadata_id: 1727]

Activity

### data_flow #0  [metadata_id: 2529]

Collect-XEEvents.ps1 reads events from the xFACts_BlockedProcess XE session on each monitored server, parses the XML event data via Parse-BlockedProcessEvent, and inserts individual events. The raw XML is optionally retained based on GlobalConfig blocked_process_retain_raw_xml setting. The Control Center Server Health page reads this table for blocking event timelines and blocker/blocked session detail.

### description #0  [metadata_id: 54]

Stores blocked_process_report events collected from Extended Events sessions, capturing both the blocked process (victim) and blocking process (culprit) details for blocking analysis.

### design_note #1  [metadata_id: 2530]
Title: Configurable Raw XML Retention

The raw_event_xml column is populated or set to NULL based on the GlobalConfig setting blocked_process_retain_raw_xml. Parsing extracts the key fields (blocking/blocked session IDs, wait time, resources, query text) into typed columns for efficient querying. The raw XML is only needed for deep-dive analysis of complex blocking scenarios and consumes significant storage, so retention is configurable.

### module #0  [metadata_id: 1623]

ServerOps

### query #1  [metadata_id: 2688]
Title: Recent Blocking Events
Description: Last 24 hours of blocking events

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

### query #2  [metadata_id: 2689]
Title: Blocking Summary by Blocker
Description: Who causes the most blocking?

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

### query #3  [metadata_id: 2690]
Title: Longest Blocking Events
Description: Top 10 longest blocking events

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

### description / alert_sent #27  [metadata_id: 447]

Whether an alert has been sent for this event

### description / alert_sent_dttm #28  [metadata_id: 448]

When the alert was sent

### description / blocked_by_client_app #19  [metadata_id: 439]

Application name from connection string

### description / blocked_by_database #17  [metadata_id: 437]

Database context of blocking process

### description / blocked_by_host_name #20  [metadata_id: 440]

Client machine name

### description / blocked_by_login #18  [metadata_id: 438]

Login name of blocking process

### description / blocked_by_query_text #22  [metadata_id: 442]

Query text of the blocking process

### description / blocked_by_spid #16  [metadata_id: 436]

Session ID of the blocking process

### description / blocked_by_status #21  [metadata_id: 441]

Status of blocking process (running, sleeping, suspended)

### description / blocked_client_app #10  [metadata_id: 430]

Application name from connection string

### description / blocked_database #8  [metadata_id: 428]

Database context of blocked process

### description / blocked_host_name #11  [metadata_id: 431]

Client machine name

### description / blocked_login #9  [metadata_id: 429]

Login name of blocked process

### description / blocked_query_text #15  [metadata_id: 435]

Query text of the blocked process

### description / blocked_spid #7  [metadata_id: 427]

Session ID of the blocked process

### description / blocked_wait_resource #14  [metadata_id: 434]

Resource being waited on

### description / blocked_wait_time_ms #12  [metadata_id: 432]

How long the process has been blocked (milliseconds)

### description / blocked_wait_type #13  [metadata_id: 433]

Type of wait (e.g., LCK_M_X, LCK_M_S)

### description / collected_dttm #24  [metadata_id: 444]

When the event was imported into xFACts

### description / event_id #1  [metadata_id: 421]

Unique identifier for the event

### description / event_timestamp #4  [metadata_id: 424]

When the blocking event occurred

### description / event_type #5  [metadata_id: 425]

Always 'blocked_process_report'

### description / raw_event_xml #23  [metadata_id: 443]

Complete event XML for forensic analysis (controlled by config)

### description / server_id #2  [metadata_id: 422]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 423]

Denormalized server name for easier querying

### description / session_name #6  [metadata_id: 426]

Always 'xFACts_BlockedProcess'

### description / source_file #25  [metadata_id: 445]

XE file the event was read from

### description / source_offset #26  [metadata_id: 446]

Byte offset within the source file

## Activity_XE_CollectionState (Table)

### category #0  [metadata_id: 1728]

Activity

### data_flow #0  [metadata_id: 2544]

Collect-XEEvents.ps1 reads this table at the start of each session collection to get the last file_offset, then updates it via MERGE after processing events. One row per server/session combination. The MERGE pattern auto-creates rows for newly enrolled servers or sessions. The Control Center Server Health page reads this table for collection health indicators showing per-session status and event counts.

### description #0  [metadata_id: 76]

Tracks Extended Events collection progress for each server/session combination, enabling incremental event collection and preventing duplicate imports.

### design_note #1  [metadata_id: 2545]
Title: Incremental Collection via File Offset

XE sessions write to rolling .xel files. The last_file_name and last_file_offset columns track exactly where the previous collection stopped. sys.fn_xe_file_target_read_file accepts these as parameters to return only events after that position. This makes each collection cycle incremental — no duplicate detection needed, no full file re-reads. A NULL offset triggers a full initial collection.

### design_note #2  [metadata_id: 2546]
Title: MERGE for Auto-Enrollment

The script uses MERGE (not INSERT/UPDATE) when updating collection state. This automatically creates a new row when a server or session is encountered for the first time, eliminating the need for a separate enrollment step. When a new server is added to ServerRegistry with serverops_activity_enabled = 1, collection state rows are created on the first collection cycle.

### module #0  [metadata_id: 1624]

ServerOps

### query #1  [metadata_id: 2691]
Title: View Current State for All Servers

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

### query #2  [metadata_id: 2692]
Title: Find Servers Not Collecting
Description: Servers with no collection in last hour

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

### query #3  [metadata_id: 2693]
Title: Find Failed Collections

SELECT 
    sr.server_name,
    cs.session_name,
    cs.last_collection_dttm,
    cs.last_collection_status
FROM ServerOps.Activity_XE_CollectionState cs
JOIN dbo.ServerRegistry sr ON cs.server_id = sr.server_id
WHERE cs.last_collection_status = 'FAILED'
ORDER BY cs.last_collection_dttm DESC;

### description / created_by #12  [metadata_id: 806]

Who created the record

### description / created_dttm #11  [metadata_id: 805]

When the state record was created

### description / events_collected #10  [metadata_id: 804]

Number of events imported in last collection

### description / first_file_offset #6  [metadata_id: 800]

Byte offset at start of most recent collection

### description / last_collection_dttm #8  [metadata_id: 802]

When the last collection completed

### description / last_collection_status #9  [metadata_id: 803]

Result: SUCCESS, FAILED, PARTIAL, NO_DATA

### status_value / last_collection_status #1  [metadata_id: 2547]
Title: SUCCESS

Events were found and successfully processed. The file offset was advanced.

### status_value / last_collection_status #2  [metadata_id: 2548]
Title: NO_DATA

Collection executed successfully but no new events were found since the last offset. The file offset remains unchanged. This is normal during quiet periods.

### status_value / last_collection_status #3  [metadata_id: 2549]
Title: FAILED

Collection encountered an error. Possible causes: server unreachable, XE session not running, file path resolution failure, or permission issue. The file offset remains unchanged so the next cycle will retry from the same position.

### status_value / last_collection_status #4  [metadata_id: 2550]
Title: PARTIAL

Reserved for future use. Intended for scenarios where some events were processed but collection was interrupted before completion.

### description / last_file_name #5  [metadata_id: 799]

Full path of the last .xel file processed

### description / last_file_offset #7  [metadata_id: 801]

Byte offset at end of most recent collection

### description / modified_by #14  [metadata_id: 808]

Who last updated the record

### description / modified_dttm #13  [metadata_id: 807]

When the record was last updated

### description / server_id #2  [metadata_id: 796]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 797]

Denormalized server name for easier querying

### description / session_name #4  [metadata_id: 798]

XE session name (e.g., xFACts_LongQueries, xFACts_BlockedProcess)

### description / state_id #1  [metadata_id: 795]

Unique identifier for the state record

## Activity_XE_Deadlock (Table)

### category #0  [metadata_id: 1729]

Activity

### data_flow #0  [metadata_id: 2531]

Collect-XEEvents.ps1 reads events from the xFACts_Deadlock XE session on each monitored server, parses the XML deadlock graph via Parse-DeadlockEvent, and inserts individual events. The full deadlock graph XML is always retained for analysis. The Control Center Server Health page reads this table for deadlock event history and victim/survivor details.

### description #0  [metadata_id: 90]

Stores xml_deadlock_report events collected from Extended Events sessions, capturing both the victim (killed process) and survivor (winning process) details for deadlock analysis.

### design_note #1  [metadata_id: 2532]
Title: Deadlock Graph Parsing

The parse function extracts both sides of the deadlock (victim and survivor) into separate column sets: process IDs, query text, login names, application names, lock resources, and wait types. The full deadlock graph XML is always stored in raw_event_xml because deadlock analysis often requires examining the complete resource dependency chain, which cannot be fully represented in flat columns.

### module #0  [metadata_id: 1625]

ServerOps

### query #1  [metadata_id: 2694]
Title: Recent Deadlocks
Description: Last 30 days of deadlocks

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

### query #2  [metadata_id: 2695]
Title: Deadlock Frequency by Database
Description: Which databases have the most deadlocks?

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

### query #3  [metadata_id: 2696]
Title: View Full Deadlock Graph
Description: Get complete deadlock XML for analysis

-- Get complete deadlock XML for analysis
SELECT 
    event_id,
    event_timestamp,
    victim_login,
    survivor_login,
    raw_deadlock_xml
FROM ServerOps.Activity_XE_Deadlock
WHERE event_id = @EventID;

### description / alert_sent #26  [metadata_id: 995]

Whether an alert has been sent for this event

### description / alert_sent_dttm #27  [metadata_id: 996]

When the alert was sent

### description / collected_dttm #23  [metadata_id: 992]

When the event was imported into xFACts

### description / deadlock_category #9  [metadata_id: 978]

STANDARD (single victim) or COMPLEX (multi-victim)

### description / event_id #1  [metadata_id: 970]

Unique identifier for the event

### description / event_timestamp #4  [metadata_id: 973]

When the deadlock was detected

### description / event_type #5  [metadata_id: 974]

Always 'xml_deadlock_report'

### description / process_count #7  [metadata_id: 976]

Total number of processes involved in the deadlock

### description / raw_deadlock_xml #22  [metadata_id: 991]

Complete deadlock graph for forensic analysis

### description / server_id #2  [metadata_id: 971]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 972]

Denormalized server name for easier querying

### description / session_name #6  [metadata_id: 975]

Always 'xFACts_Deadlock'

### description / source_file #24  [metadata_id: 993]

XE file the event was read from

### description / source_offset #25  [metadata_id: 994]

Byte offset within the source file

### description / survivor_client_app #19  [metadata_id: 988]

Application name from connection string

### description / survivor_database #17  [metadata_id: 986]

Database context of survivor process

### description / survivor_host_name #20  [metadata_id: 989]

Client machine name

### description / survivor_login #18  [metadata_id: 987]

Login name of survivor process

### description / survivor_query_text #21  [metadata_id: 990]

Query text that completed

### description / survivor_spid #16  [metadata_id: 985]

Session ID of the process that survived

### description / victim_client_app #13  [metadata_id: 982]

Application name from connection string

### description / victim_count #8  [metadata_id: 977]

Number of victims (processes killed). Values > 1 indicate complex/parallel deadlocks

### description / victim_database #11  [metadata_id: 980]

Database context of victim process

### description / victim_host_name #14  [metadata_id: 983]

Client machine name

### description / victim_login #12  [metadata_id: 981]

Login name of victim process

### description / victim_query_text #15  [metadata_id: 984]

Query text that was killed

### description / victim_spid #10  [metadata_id: 979]

Session ID of the process that was killed

## Activity_XE_LinkedServerIn (Table)

### category #0  [metadata_id: 1730]

Activity

### data_flow #0  [metadata_id: 2533]

Collect-XEEvents.ps1 reads events from the xFACts_LS_Inbound XE session on each monitored server, parses via Parse-LSInboundEvent, aggregates via Aggregate-LSEvents, and inserts aggregated records via Insert-LSInboundEventAggregated. The Control Center Server Health page reads this table for inbound linked server traffic analysis.

### description #0  [metadata_id: 51]

Aggregated storage for inbound linked server queries captured from Extended Events sessions, tracking queries received FROM other servers via linked server connections. Similar queries are grouped and metrics accumulated for efficient storage and analysis.

### design_note #1  [metadata_id: 2534]
Title: Event Aggregation

Unlike other XE tables that store individual events, linked server events are aggregated before insertion. The Aggregate-LSEvents function groups parsed events by server, source server, database, and time window, then stores execution count, total/min/max/avg duration, and total rows. This reduces storage volume significantly for high-frequency linked server traffic while preserving the metrics needed for performance analysis.

### module #0  [metadata_id: 1626]

ServerOps

### query #1  [metadata_id: 2701]
Title: Recent Inbound Linked Server Activity

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

### query #2  [metadata_id: 2702]
Title: Inbound Query Volume by Client Host

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

### query #3  [metadata_id: 2703]
Title: Slowest Inbound Query Patterns

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

### query #4  [metadata_id: 2704]
Title: High-Frequency Query Patterns
Description: Find queries executing many times (potential optimization targets)

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

### description / client_app_name #7  [metadata_id: 363]

Application name from connection string

### description / client_hostname #6  [metadata_id: 362]

Client machine name initiating the linked server query

### description / client_pid #5  [metadata_id: 361]

Client process ID

### description / collected_dttm #25  [metadata_id: 381]

When the row was created or last updated

### description / database_name #8  [metadata_id: 364]

Database where query executed

### description / event_id #1  [metadata_id: 357]

Unique identifier for the aggregated event group

### description / execution_count #14  [metadata_id: 370]

Number of executions aggregated into this row

### description / first_event_timestamp #15  [metadata_id: 371]

Timestamp of first execution in aggregation window

### description / last_event_timestamp #16  [metadata_id: 372]

Timestamp of most recent execution

### description / max_duration_ms #18  [metadata_id: 374]

Maximum duration of any single execution

### description / nt_username #10  [metadata_id: 366]

Windows username

### description / query_hash #12  [metadata_id: 368]

Hash identifying query shape (ignores literals)

### description / query_plan_hash #13  [metadata_id: 369]

Hash identifying execution plan

### description / server_id #2  [metadata_id: 358]

FK to dbo.ServerRegistry (local server receiving query)

### description / server_name #3  [metadata_id: 359]

Local server name receiving the query

### description / session_id #4  [metadata_id: 360]

Local session ID (SPID)

### description / session_name #24  [metadata_id: 380]

Source XE session name (xFACts_LS_Inbound)

### description / sql_text #11  [metadata_id: 367]

Query text received (from most recent execution)

### description / total_cpu_time_ms #19  [metadata_id: 375]

Sum of CPU time across all executions

### description / total_duration_ms #17  [metadata_id: 373]

Sum of duration across all executions

### description / total_logical_reads #20  [metadata_id: 376]

Sum of logical reads across all executions

### description / total_physical_reads #21  [metadata_id: 377]

Sum of physical reads across all executions

### description / total_row_count #23  [metadata_id: 379]

Sum of rows affected across all executions

### description / total_writes #22  [metadata_id: 378]

Sum of writes across all executions

### description / username #9  [metadata_id: 365]

Login executing the query

## Activity_XE_LinkedServerOut (Table)

### category #0  [metadata_id: 1731]

Activity

### data_flow #0  [metadata_id: 2535]

Collect-XEEvents.ps1 reads events from the xFACts_LS_Outbound XE session on each monitored server, parses via Parse-LSOutboundEvent, aggregates via Aggregate-LSEvents, and inserts aggregated records via Insert-LSOutboundEventAggregated. The Control Center Server Health page reads this table for outbound linked server traffic analysis.

### description #0  [metadata_id: 57]

Aggregated storage for outbound linked server queries captured from Extended Events sessions, tracking queries sent TO other servers via linked server connections. Similar queries are grouped and metrics accumulated for efficient storage and analysis.

### design_note #1  [metadata_id: 2536]
Title: Event Aggregation

Same aggregation pattern as Activity_XE_LinkedServerIn. Outbound events capture queries that this server sends to other servers via linked server connections (four-part naming, OPENQUERY, OPENROWSET). The aggregation groups by target server, database, and time window.

### module #0  [metadata_id: 1627]

ServerOps

### query #1  [metadata_id: 2705]
Title: Recent Outbound Linked Server Activity

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

### query #2  [metadata_id: 2706]
Title: Outbound Query Volume by Application

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

### query #3  [metadata_id: 2707]
Title: Slowest Outbound Query Patterns

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

### query #4  [metadata_id: 2708]
Title: High-Frequency Query Patterns
Description: Find queries executing many times (potential optimization targets)

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

### query #5  [metadata_id: 2709]
Title: Outbound Activity by User

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

### description / client_app_name #7  [metadata_id: 467]

Application name from connection string

### description / client_hostname #6  [metadata_id: 466]

Client machine name

### description / client_pid #5  [metadata_id: 465]

Client process ID

### description / collected_dttm #25  [metadata_id: 485]

When the row was created or last updated

### description / database_name #8  [metadata_id: 468]

Local database where query originated

### description / event_id #1  [metadata_id: 461]

Unique identifier for the aggregated event group

### description / execution_count #14  [metadata_id: 474]

Number of executions aggregated into this row

### description / first_event_timestamp #15  [metadata_id: 475]

Timestamp of first execution in aggregation window

### description / last_event_timestamp #16  [metadata_id: 476]

Timestamp of most recent execution

### description / max_duration_ms #18  [metadata_id: 478]

Maximum duration of any single execution

### description / nt_username #10  [metadata_id: 470]

Windows username

### description / query_hash #12  [metadata_id: 472]

Hash identifying query shape (ignores literals)

### description / query_plan_hash #13  [metadata_id: 473]

Hash identifying execution plan

### description / server_id #2  [metadata_id: 462]

FK to dbo.ServerRegistry (local server sending query)

### description / server_name #3  [metadata_id: 463]

Local server name sending the query

### description / session_id #4  [metadata_id: 464]

Local session ID (SPID)

### description / session_name #24  [metadata_id: 484]

Source XE session name (xFACts_LS_Outbound)

### description / sql_text #11  [metadata_id: 471]

Query text sent to remote server (from most recent execution)

### description / total_cpu_time_ms #19  [metadata_id: 479]

Sum of CPU time across all executions

### description / total_duration_ms #17  [metadata_id: 477]

Sum of duration across all executions (includes network latency)

### description / total_logical_reads #20  [metadata_id: 480]

Sum of logical reads across all executions

### description / total_physical_reads #21  [metadata_id: 481]

Sum of physical reads across all executions

### description / total_row_count #23  [metadata_id: 483]

Sum of rows affected across all executions

### description / total_writes #22  [metadata_id: 482]

Sum of writes across all executions

### description / username #9  [metadata_id: 469]

Login executing the query

## Activity_XE_LRQ (Table)

### category #0  [metadata_id: 1732]

Activity

### data_flow #0  [metadata_id: 2527]

Collect-XEEvents.ps1 reads events from the xFACts_LongQueries XE session on each monitored server, parses the XML event data via Parse-LRQEvent, and inserts individual events via Insert-LRQEvent. sp_Activity_CorrelateIncidents reads this table within configurable time windows to find concurrent long-running queries when PLE or HADR threshold crossings are detected — providing automated root cause correlation. sp_DiagnoseServerHealth reads this table for manual investigation. The Control Center Server Health page displays recent long-running queries with duration, database, and user details.

### description #0  [metadata_id: 63]

Central repository for long-running queries (LRQ) exceeding the configured duration threshold, captured from Extended Events sessions across all monitored servers.

### design_note #1  [metadata_id: 2528]
Title: Primary Correlation Target

This is the most important table for incident correlation. When sp_Activity_CorrelateIncidents detects a PLE crisis, it searches this table on the same server for heavy queries within the correlation window. When it detects a HADR spike, it searches this table on the AG secondary server — because secondary workload (reporting queries, BIDATA builds, Azure Data Sync) causes HADR_SYNC_COMMIT waits on the primary. The correlation logic identifies known process patterns (Redgate monitoring, xFACts XE collection, Azure Data Sync, BIDATA builds) to provide actionable source attribution.

### module #0  [metadata_id: 1628]

ServerOps

### query #1  [metadata_id: 2697]
Title: Recent Long-Running Queries by Server

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

### query #2  [metadata_id: 2698]
Title: Top 10 Slowest Queries Today

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

### query #3  [metadata_id: 2699]
Title: Query Pattern Analysis (by Hash)
Description: Find recurring slow query patterns

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

### query #4  [metadata_id: 2700]
Title: Find Queries by User

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

### description / alert_sent #24  [metadata_id: 564]

Whether a Teams alert was sent for this event

### description / alert_sent_dttm #25  [metadata_id: 565]

When the alert was sent

### description / client_app_name #10  [metadata_id: 550]

Application name from connection string

### description / client_hostname #9  [metadata_id: 549]

Client machine name

### description / collected_dttm #21  [metadata_id: 561]

When the event was imported to xFACts

### description / cpu_time_ms #13  [metadata_id: 553]

CPU time consumed in milliseconds

### description / database_name #7  [metadata_id: 547]

Database where query executed

### description / duration_ms #12  [metadata_id: 552]

Total duration in milliseconds

### description / event_id #1  [metadata_id: 541]

Unique identifier for the event

### description / event_timestamp #4  [metadata_id: 544]

When the query completed (from XE event)

### description / event_type #5  [metadata_id: 545]

XE event type: sql_statement_completed, sql_batch_completed, rpc_completed

### description / logical_reads #14  [metadata_id: 554]

Pages read from buffer cache

### description / physical_reads #15  [metadata_id: 555]

Pages read from disk

### description / query_hash #19  [metadata_id: 559]

Hash identifying query shape (ignores literals)

### description / query_plan_hash #20  [metadata_id: 560]

Hash identifying execution plan

### description / row_count #17  [metadata_id: 557]

Rows affected or returned

### description / server_id #2  [metadata_id: 542]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 543]

Denormalized server name for easier querying

### description / session_id #11  [metadata_id: 551]

SQL Server session ID (SPID)

### description / session_name #6  [metadata_id: 546]

Source XE session name

### description / source_file #22  [metadata_id: 562]

XE file path the event was read from

### description / source_offset #23  [metadata_id: 563]

Byte offset in source file

### description / sql_text #18  [metadata_id: 558]

Full query text

### description / username #8  [metadata_id: 548]

Login that executed the query

### description / writes #16  [metadata_id: 556]

Pages written

## Activity_XE_SystemHealth (Table)

### category #0  [metadata_id: 1733]

Activity

### data_flow #0  [metadata_id: 2537]

Collect-XEEvents.ps1 reads events from the system_health XE session (a Microsoft built-in session) on each monitored server, parses via Parse-SystemHealthEvent, and inserts individual events. This session is processed in the same Step 3 loop as custom sessions. The Control Center Server Health page reads this table for system-level health event history.

### description #0  [metadata_id: 84]

Stores events from the system_health Extended Events session, capturing security errors, connectivity issues, wait statistics, scheduler health, server diagnostics, and deadlock reports for centralized system health monitoring.

### design_note #1  [metadata_id: 2538]
Title: Microsoft Built-In Session

system_health is a SQL Server built-in XE session that runs by default on every instance. It captures a broad range of system-level events (connectivity issues, scheduler problems, errors). The session file path is resolved differently than custom sessions — via Get-SystemHealthFilePath which queries the default LOG directory rather than looking up a custom session path.

### module #0  [metadata_id: 1629]

ServerOps

### query #1  [metadata_id: 2710]
Title: Connectivity Issues

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

### query #2  [metadata_id: 2711]
Title: Component Health Summary

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

### query #3  [metadata_id: 2712]
Title: Recent Security Errors

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

### description / calling_api_name #8  [metadata_id: 901]

API that triggered security errors

### description / client_app_name #10  [metadata_id: 903]

Application name from connection string

### description / client_hostname #9  [metadata_id: 902]

Remote host for connectivity events

### description / collected_dttm #21  [metadata_id: 914]

When the event was imported into xFACts

### description / component_state #17  [metadata_id: 910]

Component state (clean, warning, error)

### description / component_type #16  [metadata_id: 909]

Component for sp_server_diagnostics

### description / duration_ms #14  [metadata_id: 907]

Wait duration or component duration in milliseconds

### description / error_code #7  [metadata_id: 900]

Error number for security_error and connectivity events

### description / event_id #1  [metadata_id: 894]

Unique identifier for the event

### description / event_timestamp #4  [metadata_id: 897]

When the event occurred

### description / event_type #5  [metadata_id: 898]

Event name from system_health (discriminator)

### description / login_time_ms #12  [metadata_id: 905]

Total login time in milliseconds

### description / os_error #11  [metadata_id: 904]

OS-level error code

### description / raw_event_xml #18  [metadata_id: 911]

Complete event XML - always stored for system_health

### description / server_id #2  [metadata_id: 895]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 896]

Denormalized server name for easier querying

### description / session_id #6  [metadata_id: 899]

SPID associated with the event (when applicable)

### description / signal_duration_ms #15  [metadata_id: 908]

Signal wait portion for wait_info events

### description / source_file #19  [metadata_id: 912]

XE file the event was read from

### description / source_offset #20  [metadata_id: 913]

Byte offset within the source file

### description / wait_type #13  [metadata_id: 906]

Wait type for wait_info events

## Activity_XE_xFACts (Table)

### category #0  [metadata_id: 1734]

Activity

### data_flow #0  [metadata_id: 2542]

Collect-XEEvents.ps1 reads events from the xFACts_Tracking XE session on each monitored server, parses via Parse-xFACtsEvent, and inserts individual events. Captures all completed query executions from xFACts processes, complementing the DMV-based footprint snapshots in Activity_DMV_xFACts with event-level detail including actual query text and execution metrics.

### description #0  [metadata_id: 122]

Central repository for all completed query executions from xFACts processes, captured from the xFACts_Tracking Extended Events session across all monitored servers.

### design_note #1  [metadata_id: 2543]
Title: XE vs DMV Self-Monitoring

Activity_DMV_xFACts captures point-in-time session state (cumulative counters) while Activity_XE_xFACts captures individual completed query events. Together they provide two complementary views of xFACts impact: the DMV table answers "how much total resource has this session used?" while the XE table answers "what specific queries did xFACts run and how long did each take?"

### module #0  [metadata_id: 1630]

ServerOps

### query #1  [metadata_id: 2713]
Title: Query Volume by Process (Last Hour)
Description: How many queries did each xFACts component run?

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

### query #2  [metadata_id: 2714]
Title: Total xFACts Footprint Per Server (Last 24 Hours)
Description: Aggregate impact per server

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

### query #3  [metadata_id: 2715]
Title: Heaviest Individual Queries
Description: Top queries by logical reads

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

### query #4  [metadata_id: 2716]
Title: xFACts vs LRQ Crossover
Description: How many long-running queries were from xFACts?

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

### description / client_app_name #9  [metadata_id: 1431]

xFACts component name from connection string ApplicationName

### description / collected_dttm #18  [metadata_id: 1440]

When the event was imported to xFACts

### description / cpu_time_ms #12  [metadata_id: 1434]

CPU time consumed in milliseconds (NULL when below resolution threshold)

### description / database_name #7  [metadata_id: 1429]

Database where query executed

### description / duration_ms #11  [metadata_id: 1433]

Total duration in milliseconds

### description / event_id #1  [metadata_id: 1423]

Unique identifier for the event

### description / event_timestamp #4  [metadata_id: 1426]

When the query completed (from XE event)

### description / event_type #5  [metadata_id: 1427]

XE event type (sql_batch_completed)

### description / logical_reads #13  [metadata_id: 1435]

Pages read from buffer cache

### description / physical_reads #14  [metadata_id: 1436]

Pages read from disk (typically NULL — xFACts tables stay in cache)

### description / row_count #16  [metadata_id: 1438]

Rows affected or returned

### description / server_id #2  [metadata_id: 1424]

FK to dbo.ServerRegistry

### description / server_name #3  [metadata_id: 1425]

Denormalized server name for easier querying

### description / session_id #10  [metadata_id: 1432]

SQL Server session ID (SPID)

### description / session_name #6  [metadata_id: 1428]

Source XE session name (xFACts_Tracking)

### description / source_file #19  [metadata_id: 1441]

XE file path the event was read from

### description / source_offset #20  [metadata_id: 1442]

Byte offset in source file

### description / sql_text #17  [metadata_id: 1439]

Full query text

### description / username #8  [metadata_id: 1430]

Login that executed the query

### description / writes #15  [metadata_id: 1437]

Pages written (NULL for read-only queries)

## AlwaysOn_health (XE Session)

### category #0  [metadata_id: 2624]

Activity

### description #0  [metadata_id: 2622]

Microsoft built-in XE session that captures AlwaysOn Availability Group health events including state changes, failovers, and errors. Only present on servers participating in an AG. xFACts collects from this session on AG servers only.

### design_note #1  [metadata_id: 2625]
Title: AG-Only Collection

Collected in a separate Step 4 of Collect-XEEvents.ps1 rather than in the main Step 3 session loop. The server list for this step is queried independently, targeting only servers known to participate in an AG. This session does not exist on standalone SQL Server instances.

### design_note #2  [metadata_id: 2646]
Title: Captured Events (Microsoft-Managed)

Microsoft built-in session capturing AG health events. Key events: availability_replica_state_change (failovers and role changes - always investigate), availability_replica_state (state snapshots), availability_replica_manager_state_change (internal state machine transitions - usually normal), hadr_db_partner_set_sync_state (database sync state updates - monitor for stuck states). Only present on servers participating in an AG. xFACts does not modify this session - it collects from it as-is.

### module #0  [metadata_id: 2623]

ServerOps

### query #1  [metadata_id: 2647]
Title: Check Session Status
Description: Verify the session is running on an AG server (should always be running)

SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'AlwaysOn_health';

### relationship_note #1  [metadata_id: 2626]
Title: Activity_XE_AGHealth

Events from this session are parsed by Parse-AGHealthEvent and stored in Activity_XE_AGHealth. Raw XML retention is configurable via GlobalConfig aghealth_retain_raw_xml.

## Backup_DatabaseConfig (Table)

### category #0  [metadata_id: 1736]

Backup

### data_flow #0  [metadata_id: 2861]

Rows are manually inserted per database during enrollment. Collect-BackupStatus.ps1 reads backup_network_copy_enabled and backup_aws_upload_enabled to determine initial pipeline statuses for discovered backups. Process-BackupNetworkCopy.ps1 and Process-BackupAWSUpload.ps1 join through this table to filter for eligible databases. Process-BackupRetention.ps1 reads full_retention_chain_local_count and full_retention_chain_network_count to calculate per-database cutoff timestamps for chain-based deletion. Collect-BackupStatus.ps1 updates last_full_dttm, last_diff_dttm, last_log_dttm, and the corresponding backup_set_id columns after discovering new backups.

### description #0  [metadata_id: 69]

Per-database backup scheduling configuration including tier classification, full/differential/log schedules, and state tracking. Provides complete flexibility for staggered schedules while maintaining self-documenting tier assignments.

### design_note #1  [metadata_id: 2862]
Title: Active Pipeline Flags vs Future Scheduling

Three columns drive current pipeline behavior: backup_network_copy_enabled controls whether discovered backups are queued for network copy, backup_aws_upload_enabled controls AWS upload queuing, and backup_enabled is reserved for a future switchover to native xFACts backup creation (currently 0 for all databases since Redgate manages backup execution). The scheduling columns (full_frequency, full_time, diff_time, log_frequency_minutes) define future-state schedules in conjunction with the backup_enabled flag.

### design_note #2  [metadata_id: 2863]
Title: Chain-Based Retention

Retention is driven by FULL backup chain counts rather than date-based policies. full_retention_chain_local_count and full_retention_chain_network_count specify how many complete FULL backup chains to retain on each storage tier. All files (FULL, DIFF, LOG) older than the Nth oldest FULL are candidates for deletion. This eliminates orphaned DIFFs and LOGs that cannot be used for recovery without their parent FULL.

### design_note #3  [metadata_id: 2864]
Title: Explicit Per-Database Scheduling

Each database has its own complete schedule definition rather than using tier-based templates. This allows fine-grained staggering to avoid resource contention and avoids template management overhead. The tier column provides operational grouping for reporting and filtering but does not constrain scheduling or retention behavior.

### design_note #4  [metadata_id: 2865]
Title: Denormalized Names

server_name and database_name are stored directly alongside the database_id foreign key. This avoids joins for the most common queries — tier summaries, schedule views, and retention configuration reviews — while the FK to DatabaseRegistry preserves referential integrity.

### module #0  [metadata_id: 1632]

ServerOps

### query #1  [metadata_id: 2872]
Title: Configuration overview by server and tier
Description: Shows all database configurations grouped by server and tier with pipeline flags and retention settings.

SELECT
    server_name,
    database_name,
    tier,
    backup_enabled,
    backup_network_copy_enabled,
    backup_aws_upload_enabled,
    full_retention_chain_local_count,
    full_retention_chain_network_count
FROM ServerOps.Backup_DatabaseConfig
ORDER BY server_name, tier, database_name;

### query #2  [metadata_id: 2873]
Title: Summary by server and tier
Description: Counts databases per server and tier with pipeline flag totals for capacity planning.

SELECT
    server_name,
    tier,
    COUNT(*) AS database_count,
    SUM(CAST(backup_network_copy_enabled AS INT)) AS network_enabled,
    SUM(CAST(backup_aws_upload_enabled AS INT)) AS aws_enabled
FROM ServerOps.Backup_DatabaseConfig
GROUP BY server_name, tier
ORDER BY server_name, tier;

### query #3  [metadata_id: 2874]
Title: Retention configuration review
Description: Shows per-database retention chain counts for verifying retention policies before or after changes.

SELECT
    server_name,
    database_name,
    tier,
    full_retention_chain_local_count,
    full_retention_chain_network_count
FROM ServerOps.Backup_DatabaseConfig
WHERE full_retention_chain_local_count > 0
   OR full_retention_chain_network_count > 0
ORDER BY server_name, database_name;

### relationship_note #1  [metadata_id: 2875]
Title: Backup_FileTracking

Pipeline flags in this table (backup_network_copy_enabled, backup_aws_upload_enabled) determine the initial statuses assigned to FileTracking records at collection time. Retention chain counts drive the cutoff calculations that determine which FileTracking records are eligible for deletion.

### relationship_note #2  [metadata_id: 2876]
Title: dbo.DatabaseRegistry

Each row references a database_id from DatabaseRegistry. A database must be enrolled (is_active = 1) in DatabaseRegistry and have a Backup_DatabaseConfig row for the pipeline to process its backups. DatabaseRegistry.backup_enabled is a separate flag that indicates whether xFACts creates backups — distinct from the pipeline flags here that control post-creation distribution.

### description / backup_aws_upload_enabled #7  [metadata_id: 1364]

Whether xFACts uploads completed backups to AWS S3

### description / backup_enabled #5  [metadata_id: 1362]

Whether xFACts handles backup creation for this database (0 = Redgate handles)

### description / backup_network_copy_enabled #6  [metadata_id: 1363]

Whether xFACts copies completed backups to network storage

### description / config_id #1  [metadata_id: 677]

Unique identifier for the configuration

### description / created_by #25  [metadata_id: 698]

Who created the configuration

### description / created_dttm #24  [metadata_id: 697]

When the configuration was created

### description / database_id #2  [metadata_id: 678]

FK to DatabaseRegistry.database_id

### description / database_name #3  [metadata_id: 679]

Denormalized database name for convenience

### description / diff_backup_enabled #15  [metadata_id: 688]

Whether differential backups are scheduled

### description / diff_time #16  [metadata_id: 689]

Time of day for diff backup (runs all days except full_day_of_week)

### description / full_backup_enabled #9  [metadata_id: 682]

Whether full backups are scheduled

### description / full_day_of_week #11  [metadata_id: 684]

1=Sun, 2=Mon...7=Sat (NULL if DAILY)

### description / full_frequency #10  [metadata_id: 683]

WEEKLY or DAILY

### description / full_retention_chain_local_count #13  [metadata_id: 686]

Number of full backup chains to retain on local storage. DIFFs and LOGs older than the Nth oldest FULL are automatically deleted

### description / full_retention_chain_network_count #14  [metadata_id: 687]

Number of full backup chains to retain on network storage. DIFFs and LOGs older than the Nth oldest FULL are automatically deleted

### description / full_time #12  [metadata_id: 685]

Time of day for full backup

### description / last_diff_backup_set_id #22  [metadata_id: 695]

msdb.backupset reference for chain tracking

### description / last_diff_dttm #21  [metadata_id: 694]

When last differential backup completed

### description / last_full_backup_set_id #20  [metadata_id: 693]

msdb.backupset reference for chain tracking

### description / last_full_dttm #19  [metadata_id: 692]

When last full backup completed

### description / last_log_dttm #23  [metadata_id: 696]

When last log backup completed

### description / log_backup_enabled #17  [metadata_id: 690]

Whether log backups are scheduled

### description / log_frequency_minutes #18  [metadata_id: 691]

Minutes between log backups (15, 240, 1440, etc.)

### description / modified_by #27  [metadata_id: 700]

Who last modified the configuration

### description / modified_dttm #26  [metadata_id: 699]

When the configuration was last modified

### description / server_name #4  [metadata_id: 680]

Denormalized server name for convenience

### description / tier #8  [metadata_id: 681]

Critical, Standard, LowActivity, Working, System, Deprecated

### status_value / tier #1  [metadata_id: 2866]
Title: Critical

High-transaction, business-critical databases. Future schedule: weekly FULLs, daily DIFFs, 15-minute LOGs. Network copy and AWS upload enabled.

### status_value / tier #2  [metadata_id: 2867]
Title: Standard

Normal FULL recovery databases. Future schedule: weekly FULLs, daily DIFFs, 4-hour LOGs. Network copy and AWS upload enabled.

### status_value / tier #3  [metadata_id: 2868]
Title: LowActivity

Databases with sporadic activity. Future schedule: weekly FULLs, daily DIFFs, daily LOGs. Network copy enabled, AWS upload optional.

### status_value / tier #4  [metadata_id: 2869]
Title: Working

Transient or staging data in SIMPLE recovery mode. Future schedule: daily FULLs only. Local storage only — no network copy or AWS upload.

### status_value / tier #5  [metadata_id: 2870]
Title: System

System databases (master, model, msdb). Future schedule: weekly FULLs on Saturday. Network copy enabled, no AWS upload.

### status_value / tier #6  [metadata_id: 2871]
Title: Deprecated

Databases pending removal. Backups disabled. No network copy or AWS upload.

## Backup_ExecutionLog (Table)

### category #0  [metadata_id: 1737]

Backup

### data_flow #0  [metadata_id: 2890]

All four pipeline scripts write to this table. Collect-BackupStatus.ps1 logs per-server collection results (success or failure with error message). Process-BackupNetworkCopy.ps1 and Process-BackupAWSUpload.ps1 log per-file copy/upload operations with duration, byte counts, and error details. Process-BackupRetention.ps1 logs per-file deletion operations for both local and network storage, but skips logging for HISTORICAL records to prevent table bloat during large-scale cleanup.

### description #0  [metadata_id: 105]

Detailed execution history for all Backup component operations including collection, network copy, AWS upload, and retention activities. Provides audit trail and troubleshooting data.

### design_note #1  [metadata_id: 2891]
Title: Component-Based Filtering

The component column identifies which pipeline process generated each entry (COLLECTION, NETWORK_COPY, AWS_UPLOAD, RETENTION). This enables component-specific analysis — throughput trends for network copy, failure rates for AWS upload, collection timing per server — without requiring separate log tables per process.

### design_note #2  [metadata_id: 2892]
Title: Selective Logging for HISTORICAL Records

Process-BackupRetention.ps1 skips ExecutionLog writes when processing HISTORICAL records (checking network_copy_status != HISTORICAL before logging). During initial cleanup of pre-existing files, hundreds of thousands of records may be processed — logging each one would flood the table with low-value entries. Failures are always logged regardless of HISTORICAL status.

### module #0  [metadata_id: 1633]

ServerOps

### query #1  [metadata_id: 2901]
Title: Recent failures by component
Description: Shows failed operations from the last 7 days grouped by pipeline component for troubleshooting.

SELECT
    component,
    operation,
    server_name,
    database_name,
    file_name,
    error_message,
    started_dttm
FROM ServerOps.Backup_ExecutionLog
WHERE status = 'FAILED'
  AND started_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY started_dttm DESC;

### query #2  [metadata_id: 2902]
Title: Component summary — last 24 hours
Description: Aggregated view of operations per component showing success/failure counts and throughput.

SELECT
    component,
    COUNT(*) AS total_operations,
    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) AS succeeded,
    SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) AS failed,
    SUM(bytes_processed) / 1073741824.0 AS total_gb_processed,
    AVG(duration_ms) AS avg_duration_ms
FROM ServerOps.Backup_ExecutionLog
WHERE started_dttm >= DATEADD(DAY, -1, GETDATE())
GROUP BY component
ORDER BY component;

### query #3  [metadata_id: 2903]
Title: Network copy throughput trend
Description: Daily throughput analysis for network copy operations over the last 30 days.

SELECT
    CAST(started_dttm AS DATE) AS copy_date,
    COUNT(*) AS files_copied,
    SUM(bytes_processed) / 1073741824.0 AS total_gb,
    CASE
        WHEN SUM(duration_ms) > 0
        THEN SUM(bytes_processed) / 1048576.0 / (SUM(duration_ms) / 1000.0)
        ELSE 0
    END AS avg_mb_per_second
FROM ServerOps.Backup_ExecutionLog
WHERE component = 'NETWORK_COPY'
  AND status = 'SUCCESS'
  AND started_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY CAST(started_dttm AS DATE)
ORDER BY copy_date DESC;

### description / bytes_processed #11  [metadata_id: 1230]

Bytes copied or uploaded

### description / completed_dttm #16  [metadata_id: 1235]

When the operation completed

### description / component #3  [metadata_id: 1222]

COLLECTION, NETWORK_COPY, AWS_UPLOAD, RETENTION

### status_value / component #1  [metadata_id: 2897]
Title: COLLECTION

Logged by Collect-BackupStatus.ps1. Operations include per-server collection summaries with file counts and duration.

### status_value / component #2  [metadata_id: 2898]
Title: NETWORK_COPY

Logged by Process-BackupNetworkCopy.ps1. Operations include per-file copy results with byte counts and throughput.

### status_value / component #3  [metadata_id: 2899]
Title: AWS_UPLOAD

Logged by Process-BackupAWSUpload.ps1. Operations include per-file upload results with byte counts and throughput.

### status_value / component #4  [metadata_id: 2900]
Title: RETENTION

Logged by Process-BackupRetention.ps1. Operations include LOCAL_DELETE and NETWORK_DELETE with byte counts. HISTORICAL record operations are excluded from logging.

### description / database_name #5  [metadata_id: 1224]

Database involved (if applicable)

### description / duration_ms #10  [metadata_id: 1229]

Duration in milliseconds

### description / error_details #14  [metadata_id: 1233]

Stack trace or additional context

### description / error_message #13  [metadata_id: 1232]

Error summary if failed

### description / file_name #6  [metadata_id: 1225]

File processed (if applicable)

### description / files_processed #12  [metadata_id: 1231]

Number of files (for batch operations)

### description / log_id #1  [metadata_id: 1220]

Unique identifier for the log entry

### description / operation #8  [metadata_id: 1227]

Specific action performed (e.g., 'Discover new backups', 'Copy to network')

### description / run_id #2  [metadata_id: 1221]

Orchestrator run identifier (if applicable)

### description / server_name #4  [metadata_id: 1223]

Server involved (if applicable)

### description / started_dttm #15  [metadata_id: 1234]

When the operation started

### description / status #9  [metadata_id: 1228]

SUCCESS, FAILED, SKIPPED, WARNING

### status_value / status #1  [metadata_id: 2893]
Title: SUCCESS

Operation completed successfully.

### status_value / status #2  [metadata_id: 2894]
Title: FAILED

Operation encountered an error. error_message contains the summary; error_details may contain the full stack trace.

### status_value / status #3  [metadata_id: 2895]
Title: SKIPPED

Operation intentionally bypassed — typically logged when there is no work to do.

### status_value / status #4  [metadata_id: 2896]
Title: WARNING

Operation completed with non-fatal issues.

### description / tracking_id #7  [metadata_id: 1226]

FK to FileTracking (if applicable)

## Backup_FileTracking (Table)

### category #0  [metadata_id: 1738]

Backup

### data_flow #0  [metadata_id: 2838]

Collect-BackupStatus.ps1 queries msdb.backupset on each monitored server, inserts one row per discovered backup with PENDING or SKIPPED pipeline statuses based on Backup_DatabaseConfig flags (backup_network_copy_enabled, backup_aws_upload_enabled), and captures compressed_size_bytes from the on-disk file via UNC path. In InitialLoad mode all statuses are set to HISTORICAL. Process-BackupNetworkCopy.ps1 claims PENDING network rows via atomic batch UPDATE, copies files to the centralized network share on FA-SQLDBB, and sets network_copy_status to COMPLETED or FAILED with path and timing. Process-BackupAWSUpload.ps1 independently claims PENDING AWS rows, uploads to S3 Glacier via AWS CLI, and sets aws_upload_status to COMPLETED or FAILED with the S3 path. Process-BackupRetention.ps1 evaluates chain-based retention using FULL backup counts from Backup_DatabaseConfig, deletes expired files from local and network storage, and records local_deleted_dttm and network_deleted_dttm. sp_Backup_Monitor reads this table to detect stale PENDING files (status PENDING with NULL started timestamp aged beyond threshold) and logs detections to Backup_AlertHistory.

### description #0  [metadata_id: 91]

Tracks backup files through the complete pipeline from creation through network copy, AWS upload, and eventual deletion. Provides full audit trail and enables idempotent processing by preventing duplicate operations.

### design_note #1  [metadata_id: 2839]
Title: Decoupled Pipeline Coordination

FileTracking is the coordination layer for four independent scripts that each own one pipeline stage. No script depends on another having run — network copy and AWS upload both read from source servers via UNC paths, not from each other's output. This enables true parallel execution and fault isolation: S3 outages do not block network copies and vice versa.

### design_note #2  [metadata_id: 2840]
Title: Atomic Batch Claim Pattern

Process-BackupNetworkCopy and Process-BackupAWSUpload both use an atomic batch claim pattern: a single UPDATE sets all PENDING rows to IN_PROGRESS before per-file processing begins. The WHERE clause includes status = PENDING, so overlapping executions cannot claim the same files. Individual started_dttm timestamps are set when each file actually begins processing, creating three observable states: IN_PROGRESS with NULL start (claimed, queued), IN_PROGRESS with timestamp (actively processing), and COMPLETED/FAILED (finished).

### design_note #3  [metadata_id: 2841]
Title: Source-Agnostic Discovery

Tracks backups regardless of whether they were created by Redgate SQL Backup (.sqb files) or native SQL Server backup (.bak/.trn files). Detection is based on msdb.backupset entries, and backup_source is set automatically based on file extension. This supports the current Redgate-managed environment and a future transition to native xFACts backup execution.

### design_note #4  [metadata_id: 2842]
Title: Compressed Size vs Logical Size

file_size_bytes contains the logical/uncompressed size from msdb.backupset.backup_size. compressed_size_bytes contains the actual on-disk file size captured via UNC path at collection time. Redgate compression typically achieves 10:1 ratios, so without compressed_size_bytes, retention space reporting would overstate reclaimed space by an order of magnitude. Process-BackupRetention uses COALESCE(compressed_size_bytes, file_size_bytes) for accurate reporting, falling back to logical size for historical records where compressed size was not captured.

### design_note #5  [metadata_id: 2843]
Title: HISTORICAL Status and Phased Migration

The HISTORICAL status marks records that were not processed by xFACts — either because they pre-date xFACts tracking or were distributed by Redgate before xFACts took over. InitialLoad mode sets all statuses to HISTORICAL. Process-BackupRetention skips ExecutionLog writes for HISTORICAL records to prevent log flooding during large-scale cleanup of pre-existing files.

### design_note #6  [metadata_id: 2844]
Title: AG Listener Path Resolution

For databases enrolled under the AG Listener (server_id = 0), the server_name field contains AVG-PROD-LSNR which cannot be used for UNC admin shares. All four pipeline scripts use Get-PhysicalServerFromPath to parse the physical server name from the backup filename pattern (TYPE_SERVER_DATABASE_TIMESTAMP.ext). The destination folder structure still uses AVG-PROD-LSNR for unified organization. Process-BackupRetention has a legacy fallback for old (local) filename patterns that maps server_id to physical server name.

### module #0  [metadata_id: 1634]

ServerOps

### query #1  [metadata_id: 2851]
Title: Pipeline status for recent backups
Description: Shows all backups from the last 7 days with their network copy and AWS upload progress.

SELECT
    server_name,
    database_name,
    backup_type,
    backup_source,
    file_name,
    backup_finish_dttm,
    network_copy_status,
    network_copy_completed_dttm,
    aws_upload_status,
    aws_upload_completed_dttm
FROM ServerOps.Backup_FileTracking
WHERE backup_finish_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY backup_finish_dttm DESC;

### query #2  [metadata_id: 2852]
Title: Stale PENDING files
Description: Files stuck in PENDING with no started timestamp — the condition sp_Backup_Monitor checks for stale detection.

SELECT
    tracking_id,
    server_name,
    database_name,
    backup_type,
    file_name,
    network_copy_status,
    network_copy_started_dttm,
    aws_upload_status,
    aws_upload_started_dttm,
    DATEDIFF(MINUTE, backup_finish_dttm, GETDATE()) AS minutes_since_backup
FROM ServerOps.Backup_FileTracking
WHERE (network_copy_status = 'PENDING' AND network_copy_started_dttm IS NULL)
   OR (aws_upload_status = 'PENDING' AND aws_upload_started_dttm IS NULL)
ORDER BY backup_finish_dttm;

### query #3  [metadata_id: 2853]
Title: Failed operations needing attention
Description: Any file where network copy or AWS upload failed. Review Backup_ExecutionLog for error details or reset to PENDING for retry.

SELECT
    tracking_id,
    server_name,
    database_name,
    backup_type,
    file_name,
    network_copy_status,
    aws_upload_status,
    backup_finish_dttm
FROM ServerOps.Backup_FileTracking
WHERE network_copy_status = 'FAILED'
   OR aws_upload_status = 'FAILED'
ORDER BY backup_finish_dttm DESC;

### query #4  [metadata_id: 2854]
Title: Compression ratio analysis
Description: Compares logical vs compressed backup sizes per server and database. Useful for evaluating Redgate compression effectiveness and accurate space reporting.

SELECT
    server_name,
    database_name,
    COUNT(*) AS backup_count,
    SUM(compressed_size_bytes) / 1073741824.0 AS total_compressed_gb,
    SUM(file_size_bytes) / 1073741824.0 AS total_logical_gb,
    CAST(
        SUM(file_size_bytes) * 1.0
        / NULLIF(SUM(compressed_size_bytes), 0)
        AS DECIMAL(5,1)
    ) AS compression_ratio
FROM ServerOps.Backup_FileTracking
WHERE compressed_size_bytes IS NOT NULL
GROUP BY server_name, database_name
ORDER BY total_compressed_gb DESC;

### query #5  [metadata_id: 2855]
Title: Reset a failed operation for retry
Description: Resets a failed network copy back to PENDING for reprocessing. Change column names for AWS retry (aws_upload_status, aws_upload_started_dttm, aws_upload_completed_dttm, aws_path).

UPDATE ServerOps.Backup_FileTracking
SET network_copy_status = 'PENDING',
    network_copy_started_dttm = NULL,
    network_copy_completed_dttm = NULL
WHERE tracking_id = @TrackingID;

### query #6  [metadata_id: 2856]
Title: Full pipeline history for a database
Description: Complete lifecycle view for a single database showing sizes, pipeline statuses, and deletion timestamps.

SELECT
    backup_type,
    file_name,
    file_size_bytes / 1048576.0 AS logical_size_mb,
    compressed_size_bytes / 1048576.0 AS compressed_size_mb,
    backup_finish_dttm,
    network_copy_status,
    aws_upload_status,
    local_deleted_dttm,
    network_deleted_dttm
FROM ServerOps.Backup_FileTracking
WHERE server_name = 'DM-PROD-DB'
  AND database_name = 'crs5_oltp'
ORDER BY backup_finish_dttm DESC;

### relationship_note #1  [metadata_id: 2857]
Title: Backup_DatabaseConfig

Backup_DatabaseConfig controls which pipeline stages apply to each database (backup_network_copy_enabled, backup_aws_upload_enabled) and defines chain-based retention counts (full_retention_chain_local_count, full_retention_chain_network_count). Collect-BackupStatus.ps1 reads these flags to determine initial statuses. Process-BackupRetention.ps1 reads the retention counts to calculate per-database cutoff timestamps.

### relationship_note #2  [metadata_id: 2858]
Title: Backup_ExecutionLog

Each pipeline script logs per-file operations to Backup_ExecutionLog with the tracking_id as a foreign key. This provides a detailed audit trail for troubleshooting: when a file shows FAILED status, the ExecutionLog entry contains the error message and timing. HISTORICAL records are excluded from retention logging to prevent table bloat.

### relationship_note #3  [metadata_id: 2859]
Title: Backup_AlertHistory

sp_Backup_Monitor reads FileTracking to detect stale PENDING files — specifically records where status is PENDING, the started timestamp is NULL, and time since backup_finish_dttm exceeds the configurable threshold. Detections are logged to Backup_AlertHistory and auto-resolved when the file's status changes from PENDING.

### relationship_note #4  [metadata_id: 2860]
Title: Backup_Status

Backup_Status provides a dashboard summary of each pipeline process. The processing scripts update FileTracking per-file and Backup_Status per-run. FileTracking is the detailed record; Backup_Status is the operational at-a-glance view showing whether each process last succeeded and when.

### description / aws_path #22  [metadata_id: 1018]

S3 path after successful upload

### description / aws_upload_completed_dttm #21  [metadata_id: 1017]

When AWS upload completed

### description / aws_upload_retry_count #27  [metadata_id: 3379]

Number of times this file has been retried for AWS upload. Incremented when the retry step resets a FAILED file to PENDING. When this value reaches the configured maximum (GlobalConfig aws_upload_max_retries), the file is left FAILED permanently and a Teams alert is fired.

### description / aws_upload_started_dttm #20  [metadata_id: 1016]

When AWS upload started

### description / aws_upload_status #19  [metadata_id: 1015]

PENDING, IN_PROGRESS, COMPLETED, FAILED, SKIPPED, HISTORICAL

### description / backup_finish_dttm #11  [metadata_id: 1007]

When backup completed (from msdb.backupset)

### description / backup_source #6  [metadata_id: 1002]

Source of backup: REDGATE (.sqb files) or NATIVE (.bak files)

### description / backup_start_dttm #10  [metadata_id: 1006]

When backup started (from msdb.backupset)

### description / backup_type #5  [metadata_id: 1001]

FULL, DIFF, or LOG

### description / compressed_size_bytes #9  [metadata_id: 1005]

Actual on-disk file size (via UNC path at collection time)

### description / created_dttm #24  [metadata_id: 1020]

When the tracking record was created

### description / database_name #4  [metadata_id: 1000]

Database name

### description / file_name #7  [metadata_id: 1003]

Backup filename

### description / file_size_bytes #8  [metadata_id: 1004]

Logical/uncompressed file size from msdb.backupset

### description / local_deleted_dttm #13  [metadata_id: 1009]

When file was cleaned from local storage

### description / local_path #12  [metadata_id: 1008]

Full local path to backup file

### description / msdb_backup_set_id #23  [metadata_id: 1019]

backup_set_id from source server's msdb.backupset

### description / network_copy_completed_dttm #16  [metadata_id: 1012]

When network copy completed

### description / network_copy_retry_count #26  [metadata_id: 3378]

Number of times this file has been retried for network copy. Incremented when the retry step resets a FAILED file to PENDING. When this value reaches the configured maximum (GlobalConfig network_copy_max_retries), the file is left FAILED permanently and a Teams alert is fired.

### description / network_copy_started_dttm #15  [metadata_id: 1011]

When network copy started

### description / network_copy_status #14  [metadata_id: 1010]

PENDING, IN_PROGRESS, COMPLETED, FAILED, SKIPPED, HISTORICAL

### status_value / network_copy_status,aws_upload_status #1  [metadata_id: 2845]
Title: PENDING

Awaiting processing. Set by Collect-BackupStatus.ps1 when the corresponding Backup_DatabaseConfig flag is enabled (backup_network_copy_enabled or backup_aws_upload_enabled). The next run of the processing script will pick up this file.

### status_value / network_copy_status,aws_upload_status #2  [metadata_id: 2846]
Title: IN_PROGRESS

Claimed by a processing script via atomic batch UPDATE. If the started timestamp is NULL, the file is queued behind other files in the batch. If the started timestamp is populated, the file is actively being copied or uploaded.

### status_value / network_copy_status,aws_upload_status #3  [metadata_id: 2847]
Title: COMPLETED

Successfully processed. The corresponding path column (network_path or aws_path) contains the destination location. The completed timestamp records when processing finished.

### status_value / network_copy_status,aws_upload_status #4  [metadata_id: 2848]
Title: FAILED

Error occurred during processing. The Backup_ExecutionLog entry for this tracking_id contains the error message. FAILED files are automatically retried up to the configured maximum (GlobalConfig network_copy_max_retries / aws_upload_max_retries). Each retry increments the retry count column. Files that exhaust all retries remain FAILED permanently and generate a Teams alert via Send-TeamsAlert.

### status_value / network_copy_status,aws_upload_status #5  [metadata_id: 2849]
Title: SKIPPED

Intentionally bypassed based on database configuration. Set by Collect-BackupStatus.ps1 when the corresponding Backup_DatabaseConfig flag is disabled. Network copy: backup_network_copy_enabled = 0. AWS upload: backup_aws_upload_enabled = 0.

### status_value / network_copy_status,aws_upload_status #6  [metadata_id: 2850]
Title: HISTORICAL

Not processed by xFACts. Set during InitialLoad mode for all records, indicating the backup was distributed by Redgate or another mechanism before xFACts pipeline management began. Processing scripts ignore HISTORICAL records. Retention processes HISTORICAL records but skips ExecutionLog writes to prevent log flooding.

### description / network_deleted_dttm #18  [metadata_id: 1014]

When file was cleaned from network storage

### description / network_path #17  [metadata_id: 1013]

Full network path after successful copy

### description / notes #25  [metadata_id: 1021]

Relevant notes for context

### description / server_id #2  [metadata_id: 998]

FK to ServerRegistry.server_id

### description / server_name #3  [metadata_id: 999]

Denormalized server name for query convenience

### description / tracking_id #1  [metadata_id: 997]

Unique identifier for the tracking record

## Collect-BackupStatus.ps1 (Script)

### category #0  [metadata_id: 2917]

Backup

### data_flow #0  [metadata_id: 2918]

Reads dbo.ServerRegistry for SQL Server instances and AG Listeners with serverops_backup_enabled = 1. Reads dbo.DatabaseRegistry joined to Backup_DatabaseConfig for enrolled databases and their pipeline flags. Queries msdb.backupset with CROSS APPLY to backupmediafamily on each target server for backup records, filtering by device_type (2=Disk, 7=Redgate Virtual Device) and excluding GUID paths (VSS/virtual device backups). Reads Backup_FileTracking for last collected timestamp per server to build incremental date filters. Writes discovered backups to Backup_FileTracking in batches of 500 with compressed_size_bytes captured via UNC path. Logs per-server results to Backup_ExecutionLog. Updates Backup_Status (COLLECTION process). Calls sp_Backup_Monitor at completion to detect stale PENDING files. Reports to Orchestrator v2 via Complete-OrchestratorTask callback.

### description #0  [metadata_id: 2915]

Discovers backup completions from msdb.backupset across all registered SQL Server instances and populates Backup_FileTracking for pipeline processing. Runs as a WAIT process under Orchestrator v2 every 5 minutes. Supports two modes: InitialLoad (all historical data, HISTORICAL status) and ongoing (incremental since last collection, PENDING/SKIPPED based on database flags). Calls sp_Backup_Monitor at end of each run.

### design_note #1  [metadata_id: 2919]
Title: Date-Based Incremental Collection

Ongoing collection queries only backups newer than the last collected timestamp per server, using MAX(backup_finish_dttm) from FileTracking as the date filter. This keeps msdb queries fast regardless of history size and ensures no duplicate tracking records.

### design_note #2  [metadata_id: 2920]
Title: Empty Results vs Connection Failure

When the msdb query returns null, the script runs a test query (SELECT 1) to distinguish between "no new backups" and "server unreachable." This prevents false failure reports for servers that simply have no new backups since last collection.

### design_note #3  [metadata_id: 2921]
Title: Backup Source Detection

Determines backup_source from file extension: .sqb files are REDGATE, all others are NATIVE. This enables pipeline analysis by source and supports tracking through the phased migration from Redgate to native backups.

### design_note #4  [metadata_id: 2922]
Title: Extension Whitelist Filtering

Only backup files with recognized extensions (.sqb, .bak, .trn) are collected from msdb.backupmediafamily. This replaced an earlier GUID exclusion filter (NOT LIKE '{%') that failed to exclude Redgate temporary filenames (SQLBACKUP_<GUID>). Temporary filenames appear in msdb while Redgate is actively writing a backup; if collected, the real file is missed when Redgate renames it because the timestamp watermark has already advanced. The whitelist approach is more defensive — any unrecognized filename pattern is silently excluded.

### module #0  [metadata_id: 2916]

ServerOps

### relationship_note #1  [metadata_id: 2923]
Title: sp_Backup_Monitor

Called at the end of each successful collection run with @PreviewOnly = 0. The monitor detects stale PENDING files and logs detections to Backup_AlertHistory. This ensures pipeline health monitoring runs on the collection schedule regardless of processing script status.

### relationship_note #2  [metadata_id: 2924]
Title: Orchestrator v2

Runs as a WAIT process — the orchestrator holds for completion before launching dependent pipeline processes (network copy, AWS upload). TaskId and ProcessId are passed by the engine; the script calls back via Complete-OrchestratorTask with status, duration, and output summary.

## Collect-DMVMetrics.ps1 (Script)

### category #0  [metadata_id: 2578]

Activity

### data_flow #0  [metadata_id: 2579]

Reads dbo.ServerRegistry for servers with serverops_activity_enabled = 1 and server_type = SQL_SERVER. Reads dbo.GlobalConfig for zombie idle threshold. Connects to each server and queries sys.dm_os_performance_counters, sys.dm_exec_sessions, sys.dm_exec_requests, sys.dm_os_wait_stats, sys.dm_io_virtual_file_stats, and sys.master_files. Writes to Activity_DMV_Memory, Activity_DMV_Workload, Activity_DMV_ConnectionHealth, Activity_DMV_WaitStats, Activity_DMV_IO_Stats, and Activity_DMV_xFACts. Calls sp_Activity_CorrelateIncidents at Step 4 which writes to Activity_Heartbeat and Activity_IncidentLog.

### description #0  [metadata_id: 2576]

Collects point-in-time DMV metrics from all monitored SQL Server instances and runs incident correlation. Captures memory health, workload indicators, connection pool health, wait statistics, I/O statistics, and xFACts session footprint. After collection, calls sp_Activity_CorrelateIncidents to evaluate thresholds and log heartbeats and incidents. Runs on a configurable Orchestrator schedule.

### design_note #1  [metadata_id: 2580]
Title: Per-Metric Error Isolation

Each of the six metric categories (memory, workload, connection health, wait stats, I/O stats, xFACts footprint) is collected and inserted in its own try/catch block within the server loop. If one metric category fails on a server (e.g., a permission issue querying dm_io_virtual_file_stats), the other five categories still succeed for that server. The server is counted as successful if at least one metric category succeeds.

### design_note #2  [metadata_id: 2581]
Title: Correlation as Secondary Operation

The sp_Activity_CorrelateIncidents call at Step 4 is wrapped in its own try/catch with a warning-level log on failure. A correlation failure does not affect the exit status of the script or the already-committed DMV data. This follows the principle that data collection should never be blocked by analysis logic.

### module #0  [metadata_id: 2577]

ServerOps

### relationship_note #1  [metadata_id: 2582]
Title: Orchestrator ProcessRegistry

Registered in Orchestrator.ProcessRegistry with standard parameters (-Execute, -TaskId, -ProcessId). Task completion callback reports server success/total count. Supports preview mode (without -Execute flag) for testing.

## Collect-ReplicationHealth.ps1 (Script)

### category #0  [metadata_id: 2828]

Replication

### data_flow #0  [metadata_id: 2829]

Reads from: distribution.dbo.MSdistribution_agents, MSdistribution_history, MSlogreader_agents, MSlogreader_history, MSsubscriber_info, MSpublications (agent catalog and health); sp_replmonitorsubscriptionpendingcmds (queue depth); sp_posttracertoken, sp_helptracertokenhistory, sp_deletetracertokenhistory (tracer tokens) on DM-PROD-DB. Reads from: dbo.GlobalConfig (thresholds and intervals), ServerOps.Replication_PublicationRegistry (existing registry), ServerOps.Replication_AgentHistory (previous snapshot for event detection), BIDATA.BuildExecution (correlation check) on AVG-PROD-LSNR. Writes to: ServerOps.Replication_PublicationRegistry (registry sync), ServerOps.Replication_AgentHistory (snapshots), ServerOps.Replication_EventLog (state change events), ServerOps.Replication_LatencyHistory (tracer token results).

### description #0  [metadata_id: 2826]

Single collection engine for replication monitoring. Handles registry discovery, agent health/queue/throughput snapshots, event detection with BIDATA build correlation, and tracer token latency measurement — all in a single orchestrated cycle running every 60 seconds via the xFACts Orchestrator.

### design_note #1  [metadata_id: 2830]
Title: Single Script, Multiple Layers

All four monitoring layers (registry discovery, agent health, event detection, tracer tokens) run in a single script to eliminate coordination overhead. Discovery ensures the registry is fresh before collecting health data. Event detection uses the snapshot just collected. Tracer tokens run conditionally based on elapsed time. One script, one cycle, one clean pass.

### design_note #2  [metadata_id: 2831]
Title: Conditional Tracer Token Execution

Tracer tokens run on a separate interval (default 5 minutes) rather than every 60-second cycle. The script checks MAX(collected_dttm) from Replication_LatencyHistory to determine elapsed time. This avoids overwhelming the distribution database with token operations while still providing regular latency measurements. Most cycles complete in under 1 second; tracer token cycles take 15-45 seconds due to the propagation wait.

### design_note #3  [metadata_id: 2832]
Title: Subscriber Name Prefix Matching

The discovery query joins MSdistribution_agents with MSsubscriber_info using prefix matching against the agent name string. This is necessary because MSdistribution_agents.subscriber_id maps to linked server aliases in master.sys.servers, which may differ from the registered subscriber name in MSsubscriber_info (e.g., linked server "DM-TEST-APP" maps to subscriber "fa-bidata.database.windows.net").

### design_note #4  [metadata_id: 2833]
Title: FIRE_AND_FORGET Orchestrator Integration

Runs as a FIRE_AND_FORGET process in the orchestrator. On completion, calls Complete-OrchestratorTask to report success/failure and duration. The output message includes snapshot and event counts for operational visibility in TaskLog.

### module #0  [metadata_id: 2827]

ServerOps

### relationship_note #1  [metadata_id: 2834]
Title: Orchestrator.ProcessRegistry

Registered as a FIRE_AND_FORGET process in dependency group 10 (collection tier) with a 60-second interval. Receives TaskId and ProcessId parameters from the orchestrator engine for completion callback.

### relationship_note #2  [metadata_id: 2835]
Title: dbo.GlobalConfig

Reads all configuration from GlobalConfig under module_name = 'ServerOps', category = 'Replication'. Settings include tracer_interval_minutes, tracer_wait_seconds, queue/latency warning/critical thresholds, and alerting_enabled master switch.

### relationship_note #3  [metadata_id: 2836]
Title: BIDATA.BuildExecution

Cross-module read during event detection. When an agent stop is detected, checks BuildExecution for an active or recently completed build to tag the event as expected (correlation_source = 'BIDATA_BUILD').

### relationship_note #4  [metadata_id: 2837]
Title: distribution database (DM-PROD-DB)

External dependency. All source data comes from the distribution database system tables and procedures. The service account running this script must have SQL access to both the distribution database and the publisher database (crs5_oltp) on DM-PROD-DB.

## Collect-ServerHealth.ps1 (Script)

### category #0  [metadata_id: 2496]

Disk

### data_flow #0  [metadata_id: 2497]

Reads dbo.ServerRegistry for the list of monitored servers (is_active = 1, serverops_disk_enabled = 1). Connects to each server via CIM session over WinRM to query Win32_LogicalDisk (DriveType=3). Inserts disk metrics into ServerOps.Disk_Snapshot. For SQL_SERVER type servers, queries sys.dm_os_sys_info and updates dbo.ServerRegistry with service start times. Reads dbo.GlobalConfig (ServerOps/Disk) for default_threshold_pct, space_request_buffer_pct, and warning_buffer_pct. Reads and writes ServerOps.Disk_ThresholdConfig for auto-creation and threshold lookup. Reads and writes ServerOps.Disk_AlertHistory for breach detection and auto-resolution. Inserts into Jira.TicketQueue for new breach tickets. Updates ServerOps.Disk_Status with collection and poll timestamps.

### description #0  [metadata_id: 2494]

Collects disk space metrics from all monitored servers via WinRM/CIM and inserts into Disk_Snapshot. Also captures SQL Server service start times from sys.dm_os_sys_info for DMV freshness context. After collection, performs inline threshold evaluation: auto-creates threshold configs for new drives, detects breaches, creates Jira tickets for space requests with calculated GB needed, and auto-resolves alerts when drives recover above the resolution threshold. Runs on a configurable Orchestrator schedule.

### design_note #1  [metadata_id: 2498]
Title: In-Memory Threshold Evaluation

Threshold evaluation runs inline against the in-memory collection data rather than re-querying from the database. This eliminates any timing gap between collection and evaluation and ensures the evaluation always uses the freshest data. The evaluation block (Steps 5-10) is wrapped in try/catch so that a threshold evaluation failure does not affect already-committed collection data.

### design_note #2  [metadata_id: 2499]
Title: Error Isolation Between Collection and Evaluation

The script is structured in two major phases. Steps 1-4 (collection) commit disk snapshot data and update the collection timestamp. Steps 5-10 (threshold evaluation) are wrapped in a separate try/catch. If threshold evaluation fails, collection data is preserved and the Disk_Status table records the failure in last_poll_status. This prevents a monitoring logic error from blocking data collection.

### design_note #3  [metadata_id: 2500]
Title: Calculated Space Request

For each new breach, the script calculates the disk space needed to bring the drive above threshold_pct + space_request_buffer_pct using the actual total drive size. The result is rounded up to the nearest 10 GB with a minimum of 10 GB. This goes directly into the Jira ticket summary as a specific, actionable request — no guesswork required from IT Ops.

### module #0  [metadata_id: 2495]

ServerOps

### relationship_note #1  [metadata_id: 2501]
Title: Activity Component Cross-Reference

In addition to disk collection, this script captures SQL Server service start times from sys.dm_os_sys_info and updates dbo.ServerRegistry.last_service_start_dttm. This data provides DMV freshness context for the Activity monitoring component — DMV statistics reset on service restart, so knowing the last restart time helps interpret DMV metrics accurately.

### relationship_note #2  [metadata_id: 2502]
Title: Orchestrator Registration

Registered in Orchestrator.ProcessRegistry with standard parameters (-Execute, -TaskId, -ProcessId). Supports preview mode (without -Execute flag) for testing — queries and evaluates thresholds but does not write to any tables. Task completion callback reports server count, drive count, and breach/approaching counts.

## Collect-XEEvents.ps1 (Script)

### category #0  [metadata_id: 2585]

Activity

### data_flow #0  [metadata_id: 2586]

Reads dbo.ServerRegistry for servers with serverops_activity_enabled = 1. Reads dbo.GlobalConfig for XML retention settings (blocked_process_retain_raw_xml, aghealth_retain_raw_xml). Reads and writes ServerOps.Activity_XE_CollectionState for incremental offset tracking (via MERGE). Connects to each server and calls sys.fn_xe_file_target_read_file with offset parameters. Writes to Activity_XE_LRQ, Activity_XE_BlockedProcess, Activity_XE_Deadlock, Activity_XE_LinkedServerIn, Activity_XE_LinkedServerOut, Activity_XE_xFACts, Activity_XE_SystemHealth, and Activity_XE_AGHealth.

### description #0  [metadata_id: 2583]

Collects Extended Events from all monitored SQL Server instances using incremental file offset tracking. Processes seven custom xFACts XE sessions (LongQueries, BlockedProcess, Deadlock, LS_Inbound, LS_Outbound, Tracking, system_health) in a unified loop, plus AlwaysOn_health from AG servers in a separate step. Parses XML event data into typed columns and inserts into corresponding Activity_XE_* tables. Runs on a configurable Orchestrator schedule.

### design_note #1  [metadata_id: 2587]
Title: Session-Driven Architecture

The $XESessions array defines the mapping between XE session names, target tables, parse functions, and insert functions. The main loop iterates this array for each server, providing a uniform collection pattern. Adding a new XE session type requires: creating the XE session DDL, adding a target table, writing parse/insert functions, and adding an entry to $XESessions. The loop handles offset tracking, error handling, and collection state updates generically.

### design_note #2  [metadata_id: 2588]
Title: Aggregated vs Individual Event Storage

Most XE sessions store individual events (one row per event). Linked server sessions (xFACts_LS_Inbound, xFACts_LS_Outbound) are marked IsAggregated = $true in the session definition. For these, all events in a collection cycle are parsed first, then the Aggregate-LSEvents function groups them by server, source/target, database, and time window before insertion. This reduces storage volume for high-frequency linked server traffic.

### design_note #3  [metadata_id: 2589]
Title: Separate AG Health Collection

AlwaysOn_health is collected in Step 4, separate from the Step 3 loop that processes custom sessions. Step 3 iterates all activity-enabled servers and all sessions in $XESessions. Step 4 queries only AG servers (currently DM-PROD-DB and DM-PROD-REP) and processes only the AlwaysOn_health session. This separation exists because AlwaysOn_health is a Microsoft built-in session only present on AG-participating servers.

### module #0  [metadata_id: 2584]

ServerOps

### query #1  [metadata_id: 2648]
Title: Check All XE Sessions on a Server
Description: Run on a monitored server to verify all xFACts XE sessions are running

SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name LIKE 'xFACts_%'
   OR es.name IN ('system_health', 'AlwaysOn_health')
ORDER BY es.name;

### relationship_note #1  [metadata_id: 2590]
Title: Orchestrator ProcessRegistry

Registered in Orchestrator.ProcessRegistry with standard parameters (-Execute, -TaskId, -ProcessId). Task completion callback reports server success/total count and total events collected. Supports preview mode (without -Execute flag) for testing.

## DBCC_ExecutionLog (Table)

### category #0  [metadata_id: 3526]

DBCC

### data_flow #0  [metadata_id: 3543]

Execute-DBCC.ps1 inserts a PENDING row at claim time, transitions to IN_PROGRESS with the resolved physical server at execution start, and updates with final status, duration, error details, and DBCC output metrics on completion. One row per database per operation per run, grouped by run_id. CHECKDB and CHECKALLOC populate allocation_errors, consistency_errors, repaired_errors, dbcc_elapsed_seconds, LSN values, and buffer pool scan metrics from the DBCC summary output. CHECKCONSTRAINTS stores an aggregated violation summary in error_details. The Control Center DBCC Operations page reads this table for live progress, execution history, and duration trending. A Teams alert is queued on any non-SUCCESS result; a Jira ticket is queued on CHECKDB corruption (ERRORS_FOUND).

### description #0  [metadata_id: 3524]

Execution history for DBCC integrity operations. One row per database per operation per execution; a single script invocation processes databases sequentially and produces multiple rows grouped by run_id.

### design_note #1  [metadata_id: 3586]
Title: Self-Documenting Options

operation, check_mode, max_dop, and extended_logical_checks are captured on every row. operation and check_mode come from the per-database schedule (DBCC_ScheduleConfig); max_dop and extended_logical_checks come from GlobalConfig. Capturing them per row records exactly what options each execution used, even if the configuration changes between runs.

### design_note #2  [metadata_id: 3587]
Title: AG Listener vs Physical Server

server_name and server_id capture the ServerRegistry entry that triggered the run - the AG listener for AG databases. executed_on_server captures the physical server where DBCC actually ran - the resolved replica for AG databases. For non-AG servers both values are identical. The distinction matters for I/O contention analysis and troubleshooting.

### design_note #3  [metadata_id: 3588]
Title: CHECKCONSTRAINTS Output Handling

CHECKCONSTRAINTS returns a result set of constraint violations rather than a message stream. The script aggregates violations by table and constraint name, storing the summary in error_details with violation counts per constraint. error_count reflects the number of distinct constraints with violations, not the total number of violating rows. Detailed row-level investigation is done via live queries from the Control Center page.

### design_note #4  [metadata_id: 3643]
Title: DBCC Output Metric Capture

DBCC summary-output metrics are captured per row for historical trending. CHECKDB and CHECKALLOC populate the metric columns; CHECKCATALOG and CHECKCONSTRAINTS leave them NULL, since those operations produce different output. NULL means the metric does not apply to that operation type, not that it was missed. NO_INFOMSGS stays enabled to suppress per-object informational messages while still capturing the summary line the metrics are parsed from.

### module #0  [metadata_id: 3525]

ServerOps

### query #1  [metadata_id: 3583]
Title: Non-success executions
Description: Shows all executions that did not complete successfully — errors found, failures, or still in progress.

SELECT
    log_id, run_id, server_name, executed_on_server,
    database_name, operation, check_mode,
    started_dttm, duration_seconds, status,
    error_count, LEFT(error_details, 500) AS error_preview
FROM ServerOps.DBCC_ExecutionLog
WHERE status NOT IN ('SUCCESS')
ORDER BY started_dttm DESC;

### query #2  [metadata_id: 3584]
Title: Last execution per database per operation
Description: Shows the most recent result for each database and operation type. Quick health overview.

SELECT
    el.server_name, el.database_name, el.operation,
    el.check_mode, el.started_dttm, el.duration_seconds,
    el.status, el.error_count
FROM ServerOps.DBCC_ExecutionLog el
INNER JOIN (
    SELECT database_name, operation, MAX(log_id) AS max_log_id
    FROM ServerOps.DBCC_ExecutionLog
    GROUP BY database_name, operation
) latest ON el.log_id = latest.max_log_id
ORDER BY el.server_name, el.database_name, el.operation;

### query #3  [metadata_id: 3585]
Title: CHECKDB duration trending
Description: Shows CHECKDB execution durations over time for a specific database. Useful for detecting drift in execution times.

SELECT
    started_dttm, duration_seconds,
    duration_seconds / 3600 AS duration_hours,
    check_mode, executed_on_server, status
FROM ServerOps.DBCC_ExecutionLog
WHERE operation = 'CHECKDB'
  AND database_name = '<database_name>'
ORDER BY started_dttm DESC;

### relationship_note #1  [metadata_id: 3580]
Title: ServerRegistry

server_id references dbo.ServerRegistry. Only servers with serverops_dbcc_enabled = 1 are eligible for DBCC operations. For AG listeners, the script resolves the secondary replica dynamically and records the physical server in executed_on_server.

### relationship_note #2  [metadata_id: 3581]
Title: DBCC_ScheduleConfig

In scheduled mode, operations are driven by DBCC_ScheduleConfig entries matching the current day and hour. The ExecutionLog is checked for existing rows today to prevent duplicate execution of the same operation on the same database.

### relationship_note #3  [metadata_id: 3582]
Title: GlobalConfig

Execution options (max_dop, extended_logical_checks, alerting_enabled) are read from dbo.GlobalConfig at script startup under module ServerOps, category DBCC. check_mode is read per database from DBCC_ScheduleConfig. Captured options are stored per row in the log for historical accuracy.

### description / allocation_errors #19  [metadata_id: 3634]

Number of allocation errors reported by DBCC; NULL when the operation does not report allocation errors.

### description / buffer_pool_scan_seconds #26  [metadata_id: 3640]

Duration in seconds of the buffer pool scan at the start of DBCC execution; NULL when the operation performs no buffer pool scan.

### description / check_mode #8  [metadata_id: 3568]

DBCC check mode used by CHECKDB; NULL for operations that have no check mode.

### status_value / check_mode #1  [metadata_id: 3578]
Title: PHYSICAL_ONLY

Physical structure checks only — page checksums, torn pages, physical page integrity. Catches most real-world storage corruption. Significantly faster than FULL.

### status_value / check_mode #2  [metadata_id: 3579]
Title: FULL

Complete logical and physical integrity check. Includes all PHYSICAL_ONLY checks plus cross-object logical consistency validation.

### description / completed_dttm #14  [metadata_id: 3537]

When the DBCC operation completed. NULL while still running.

### description / consistency_errors #20  [metadata_id: 3635]

Number of consistency errors reported by DBCC; NULL when the operation does not report consistency errors.

### description / database_name #6  [metadata_id: 3532]

Database name as enrolled in DatabaseRegistry.

### description / dbcc_elapsed_seconds #16  [metadata_id: 3637]

DBCC's own reported elapsed time, distinct from duration_seconds; NULL when the operation does not report it.

### description / dbcc_summary_output #17  [metadata_id: 3664]

Raw DBCC summary text captured from the SQL Server error log; the source the parsed metric columns are derived from. NULL when the operation produces no error-log summary or the error-log query fails.

### description / duration_seconds #15  [metadata_id: 3538]

Total elapsed seconds, measured around the DBCC command invocation.

### description / error_count #22  [metadata_id: 3540]

Number of errors reported by DBCC - the sum of allocation_errors and consistency_errors. 0 for SUCCESS, and 0 for FAILED (script-level errors produce no DBCC error count).

### description / error_details #23  [metadata_id: 3541]

Full DBCC error output text when errors are found, or exception message when the script fails. NULL for SUCCESS. Truncated to 8000 characters if excessively large.

### description / executed_by #29  [metadata_id: 3542]

Windows account that ran the script; defaults to SUSER_SNAME().

### description / executed_on_server #5  [metadata_id: 3531]

Physical server where DBCC actually ran. For AG databases, the resolved replica; for non-AG servers, matches server_name.

### description / extended_logical_checks #11  [metadata_id: 3535]

Whether EXTENDED_LOGICAL_CHECKS was enabled for this execution. Only meaningful when check_mode is FULL.

### description / first_lsn #25  [metadata_id: 3639]

First LSN of the internal database snapshot DBCC used; NULL when the operation creates no internal snapshot.

### description / log_id #1  [metadata_id: 3527]

Unique identifier for the log entry.

### description / max_dop #10  [metadata_id: 3534]

MAXDOP value used for this execution.

### description / operation #7  [metadata_id: 3567]

Which DBCC command was executed.

### status_value / operation #1  [metadata_id: 3572]
Title: CHECKDB

Full database integrity check. Verifies physical and logical consistency of all objects. Longest-running operation — hours for large databases.

### status_value / operation #2  [metadata_id: 3573]
Title: CHECKALLOC

Allocation structure consistency check. Verifies page allocation and extent structures. Lightweight — seconds to minutes.

### status_value / operation #3  [metadata_id: 3574]
Title: CHECKCATALOG

System catalog consistency check. Verifies system table relationships. Very fast — seconds.

### status_value / operation #4  [metadata_id: 3575]
Title: CHECKCONSTRAINTS

FK and CHECK constraint data validation. Identifies rows that violate constraint rules. Duration varies — minutes to hours depending on table sizes and constraint count. Not included in CHECKDB.

### description / pages_iterated #28  [metadata_id: 3642]

Total buffers iterated during the buffer pool scan phase; NULL when the operation reports no page count.

### description / pages_scanned #27  [metadata_id: 3641]

Number of database pages (buffers) DBCC scanned during the buffer pool scan phase; NULL when the operation reports no page count.

### description / queued_dttm #12  [metadata_id: 3632]

When the operation was claimed and inserted as PENDING; its gap from started_dttm is time spent waiting in queue.

### description / repaired_errors #21  [metadata_id: 3636]

Number of errors DBCC repaired during execution; typically 0, NULL when the operation does not report a repair count.

### description / run_id #2  [metadata_id: 3528]

Groups all rows produced by one script invocation.

### description / server_id #3  [metadata_id: 3529]

FK to ServerRegistry. The enabled entry that triggered the run — for AG databases this is the listener, not the physical execution target.

### description / server_name #4  [metadata_id: 3530]

Denormalized from ServerRegistry; the server_name of the entry that triggered the run (the listener for AG databases).

### description / split_point_lsn #24  [metadata_id: 3638]

Internal database snapshot split-point LSN used by DBCC; NULL when the operation creates no internal snapshot.

### description / started_dttm #13  [metadata_id: 3536]

When the DBCC operation began executing; NULL while PENDING. Duration is measured from this timestamp, not queued_dttm.

### description / status #18  [metadata_id: 3539]

Execution result.

### status_value / status #0  [metadata_id: 3633]
Title: PENDING

Operation has been claimed by a script invocation and is waiting in queue. The row exists to prevent other concurrent invocations from claiming the same work. queued_dttm is populated; started_dttm is NULL.

### status_value / status #1  [metadata_id: 3546]
Title: IN_PROGRESS

DBCC operation is actively executing. Transitioned from PENDING when the script begins processing this item. started_dttm and executed_on_server are populated at this transition.

### status_value / status #2  [metadata_id: 3547]
Title: SUCCESS

The DBCC operation completed with no errors reported. Integrity verified for the checked scope.

### status_value / status #3  [metadata_id: 3548]
Title: FAILED

Script or connection error prevented DBCC from completing. Typical causes: database not online, connection timeout, permissions issue. error_details contains the exception message. Teams alert is sent.

### status_value / status #4  [metadata_id: 3549]
Title: ERRORS_FOUND

The DBCC operation completed but reported problems - corruption for the integrity checks, or constraint violations for CHECKCONSTRAINTS. error_count has the total and error_details has the full output. A Teams alert is sent; CHECKDB corruption also queues a Jira ticket.

### description / target_object #9  [metadata_id: 3569]

Reserved for object-scoped operations; unused today - no current operation populates it, so it is NULL on every row.

## DBCC_ScheduleConfig (Table)

### category #0  [metadata_id: 3592]

DBCC

### data_flow #0  [metadata_id: 3615]

Rows are manually inserted when enrolling databases for DBCC operations, typically populated from DatabaseRegistry and ServerRegistry. Execute-DBCC.ps1 reads this table on each cycle to determine which operations are due based on the current day and hour. The script joins to ServerRegistry to enforce the serverops_dbcc_enabled master switch. The Control Center DBCC Operations page reads this table for the schedule overview display.

### description #0  [metadata_id: 3590]

Per-database scheduling configuration for DBCC integrity operations. One row per database with independent enabled/day/time settings per operation type. The row-level is_enabled flag combines with serverops_dbcc_enabled on ServerRegistry for two-tier control.

### design_note #1  [metadata_id: 3616]
Title: Per-Database Granularity

Each database gets its own schedule row with independent settings per operation. This allows staggering heavy operations like CHECKDB across different days while running lightweight operations together, so a large database's full check and smaller databases' checks need not share a window.

### design_note #2  [metadata_id: 3617]
Title: Two-Tier Enable Control

Three levels of control exist: serverops_dbcc_enabled on ServerRegistry (server-level kill switch), is_enabled on this table (database-level kill switch), and individual operation _enabled flags (operation-level control). All three must be active for an operation to execute. This provides quick disable at any scope without losing schedule configuration.

### design_note #3  [metadata_id: 3618]
Title: Hour-Based Schedule Matching

The script matches the hour component of run_time against the current hour, so an operation becomes due once the script fires during its scheduled hour. Combined with the already-executed-today check on DBCC_ExecutionLog, this prevents duplicate execution when the script fires multiple times within the same hour.

### module #0  [metadata_id: 3591]

ServerOps

### query #1  [metadata_id: 3619]
Title: Full schedule overview
Description: Shows all scheduled operations across all databases with their day and time settings.

SELECT
    server_name, database_name, is_enabled,
    checkdb_enabled, checkdb_run_day, checkdb_run_time,
    checkalloc_enabled, checkalloc_run_day, checkalloc_run_time,
    checkcatalog_enabled, checkcatalog_run_day, checkcatalog_run_time,
    checkconstraints_enabled, checkconstraints_run_day, checkconstraints_run_time
FROM ServerOps.DBCC_ScheduleConfig
ORDER BY server_name, database_name;

### query #2  [metadata_id: 3620]
Title: Operations due today
Description: Shows which operations are scheduled to run today across all databases.

DECLARE @today TINYINT = DATEPART(dw, GETDATE());

SELECT
    server_name, database_name,
    CASE WHEN checkdb_enabled = 1 AND checkdb_run_day = @today THEN 'CHECKDB ' + CAST(checkdb_run_time AS VARCHAR(5)) ELSE '-' END AS checkdb,
    CASE WHEN checkalloc_enabled = 1 AND checkalloc_run_day = @today THEN 'CHECKALLOC ' + CAST(checkalloc_run_time AS VARCHAR(5)) ELSE '-' END AS checkalloc,
    CASE WHEN checkcatalog_enabled = 1 AND checkcatalog_run_day = @today THEN 'CHECKCATALOG ' + CAST(checkcatalog_run_time AS VARCHAR(5)) ELSE '-' END AS checkcatalog,
    CASE WHEN checkconstraints_enabled = 1 AND checkconstraints_run_day = @today THEN 'CHECKCONSTRAINTS ' + CAST(checkconstraints_run_time AS VARCHAR(5)) ELSE '-' END AS checkconstraints
FROM ServerOps.DBCC_ScheduleConfig
WHERE is_enabled = 1
ORDER BY server_name, database_name;

### relationship_note #1  [metadata_id: 3621]
Title: ServerRegistry

server_id references dbo.ServerRegistry. The serverops_dbcc_enabled flag on ServerRegistry acts as a server-level master switch — when disabled, all schedule rows for that server are effectively inactive regardless of their own is_enabled setting.

### relationship_note #2  [metadata_id: 3622]
Title: DatabaseRegistry

database_id references dbo.DatabaseRegistry with a unique constraint ensuring one schedule row per database. Databases must be enrolled in DatabaseRegistry before they can be scheduled for DBCC operations.

### relationship_note #3  [metadata_id: 3623]
Title: DBCC_ExecutionLog

The script checks ExecutionLog for existing rows today before executing a scheduled operation. If any row exists for the same operation + database + today, the operation is skipped. This prevents duplicate execution across multiple script invocations.

### description / check_mode #18  [metadata_id: 3665]

DBCC check mode used by CHECKDB scheduling; other operations ignore it. Defaults to NONE.

### status_value / check_mode #1  [metadata_id: 5309]
Title: NONE

No check mode configured. CHECKDB cannot be enabled while check_mode is NONE, and check_mode cannot be set to NONE while CHECKDB is enabled.

### status_value / check_mode #2  [metadata_id: 5310]
Title: PHYSICAL_ONLY

Physical structure checks only - page checksums, torn pages, physical page integrity. Significantly faster than FULL.

### status_value / check_mode #3  [metadata_id: 5311]
Title: FULL

Complete logical and physical integrity check. Includes all PHYSICAL_ONLY checks plus cross-object logical consistency validation.

### description / checkalloc_enabled #9  [metadata_id: 3601]

Whether CHECKALLOC is scheduled for this database.

### description / checkalloc_run_day #10  [metadata_id: 3602]

Day of week for CHECKALLOC execution. Same convention as checkdb_run_day.

### description / checkalloc_run_time #11  [metadata_id: 3603]

Time of day for CHECKALLOC execution.

### description / checkcatalog_enabled #12  [metadata_id: 3604]

Whether CHECKCATALOG is scheduled for this database.

### description / checkcatalog_run_day #13  [metadata_id: 3605]

Day of week for CHECKCATALOG execution. Same convention as checkdb_run_day.

### description / checkcatalog_run_time #14  [metadata_id: 3606]

Time of day for CHECKCATALOG execution.

### description / checkconstraints_enabled #15  [metadata_id: 3607]

Whether CHECKCONSTRAINTS is scheduled for this database.

### description / checkconstraints_run_day #16  [metadata_id: 3608]

Day of week for CHECKCONSTRAINTS execution. Same convention as checkdb_run_day.

### description / checkconstraints_run_time #17  [metadata_id: 3609]

Time of day for CHECKCONSTRAINTS execution.

### description / checkdb_enabled #6  [metadata_id: 3598]

Whether CHECKDB is scheduled for this database.

### description / checkdb_run_day #7  [metadata_id: 3599]

Day of week for CHECKDB execution (1=Sunday through 7=Saturday). NULL when disabled.

### description / checkdb_run_time #8  [metadata_id: 3600]

Time of day for CHECKDB execution. NULL when disabled.

### description / created_by #22  [metadata_id: 3612]

Who created this schedule row.

### description / created_dttm #21  [metadata_id: 3611]

When this schedule row was created.

### description / database_id #4  [metadata_id: 3596]

FK to DatabaseRegistry. One schedule row per enrolled database.

### description / database_name #5  [metadata_id: 3597]

Denormalized database name from DatabaseRegistry.

### description / is_enabled #20  [metadata_id: 3610]

Row-level master switch; when 0, no operations run for this database regardless of per-operation settings.

### description / modified_by #24  [metadata_id: 3614]

Who last modified this schedule row.

### description / modified_dttm #23  [metadata_id: 3613]

When this schedule row was last modified.

### description / replica_override #19  [metadata_id: 3663]

Per-database replica routing override for AG listener databases. NULL uses the default routing: the configured source replica (typically SECONDARY) for all operations except CHECKCATALOG, which always routes to PRIMARY. A non-null value pins this database's operations to the chosen replica. Persists until manually cleared. Non-AG servers ignore this column.

### status_value / replica_override #1  [metadata_id: 5312]
Title: PRIMARY

Pins this database's DBCC operations to the primary replica, overriding the default routing.

### status_value / replica_override #2  [metadata_id: 5313]
Title: SECONDARY

Pins this database's DBCC operations to the secondary replica, overriding the default routing.

### description / schedule_id #1  [metadata_id: 3593]

Auto-incrementing primary key.

### description / server_id #2  [metadata_id: 3594]

FK to ServerRegistry, denormalized from DatabaseRegistry.

### description / server_name #3  [metadata_id: 3595]

Denormalized server name from ServerRegistry.

## Disk_AlertHistory (Table)

### category #0  [metadata_id: 1742]

Disk

### data_flow #0  [metadata_id: 2478]

Collect-ServerHealth.ps1 inserts new alert rows when a drive breaches its threshold and no active (is_resolved = 0) alert exists for that server/drive. The script then queues a Jira ticket via Jira.TicketQueue and updates the alert with alerted_dttm and alert_method. When a drive recovers above the resolution threshold (threshold + warning_buffer_pct), the same script sets is_resolved = 1, resolved_dttm, and resolved_by. The Control Center Server Health page reads active alerts for display.

### description #0  [metadata_id: 113]

Audit trail and deduplication table for disk space alerts, tracking when alerts were detected, sent, and resolved.

### design_note #1  [metadata_id: 2479]
Title: Two-Level Deduplication

Alert deduplication operates at two levels. First, Collect-ServerHealth.ps1 checks for an existing active (is_resolved = 0) alert before creating a new one for the same server/drive. Second, the Jira ticket insert uses TriggerType/TriggerValue (ServerOps_DiskSpace / ServerName_DriveLetter) for deduplication at the ticket queue level. A drive can remain below threshold across multiple poll cycles without generating duplicate alerts or tickets.

### design_note #2  [metadata_id: 2480]
Title: Resolution Hysteresis

Alerts are not auto-resolved the moment a drive crosses back above its threshold. The drive must reach threshold_pct + warning_buffer_pct (from GlobalConfig) before resolution occurs. This prevents alert flapping when drives hover near the threshold. A drive between the threshold and resolution point is in a HOLDING state — the active alert remains but no new alerts are created.

### design_note #3  [metadata_id: 2481]
Title: Automated Space Request Calculation

When a breach is detected, Collect-ServerHealth.ps1 calculates the disk space needed to bring the drive above threshold_pct + space_request_buffer_pct (from GlobalConfig). The result is rounded up to the nearest 10 GB with a minimum of 10 GB. This calculated value is included in the Jira ticket summary and description, giving IT Ops a specific actionable request rather than a vague alert.

### module #0  [metadata_id: 1638]

ServerOps

### query #1  [metadata_id: 2717]
Title: Current Active Alerts

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

### query #2  [metadata_id: 2718]
Title: Alert History for a Server

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

### query #3  [metadata_id: 2719]
Title: Alert Statistics (Last 30 Days)

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

### relationship_note #1  [metadata_id: 2486]
Title: Jira Integration for Space Requests

New breach alerts trigger a direct INSERT into Jira.TicketQueue with project SD, issue type Issue, priority High. The Jira ticket includes calculated space requirements and server/drive details. TriggerType ServerOps_DiskSpace and TriggerValue ServerName_DriveLetter provide deduplication at the Jira queue level.

### description / actual_value #7  [metadata_id: 1317]

Actual value when alert was created

### description / alert_details #5  [metadata_id: 1315]

Human-readable alert description

### description / alert_id #1  [metadata_id: 1311]

Unique identifier for the alert

### description / alert_key #4  [metadata_id: 1314]

Identifier within alert type (drive letter for disk)

### description / alert_method #10  [metadata_id: 1320]

How notification was sent (TEAMS, JIRA)

### status_value / alert_method #1  [metadata_id: 2483]
Title: JIRA

Alert was delivered by creating a Jira ticket via Jira.TicketQueue. This is the primary notification method for disk space breaches — Jira tickets create actionable work items for IT Ops to add storage.

### status_value / alert_method #2  [metadata_id: 2484]
Title: TEAMS

Alert was delivered via Teams webhook notification. Not currently used by the Disk component for breach alerts (those use Jira), but available for future use.

### status_value / alert_method #3  [metadata_id: 2485]
Title: EMAIL

Alert was delivered via email. Not currently used but allowed by the check constraint for future expansion.

### description / alert_type #3  [metadata_id: 1313]

Type of alert (e.g., DISK_SPACE_LOW)

### status_value / alert_type #1  [metadata_id: 2482]
Title: DISK_SPACE_LOW

Drive free space has fallen below its configured threshold in Disk_ThresholdConfig. This is the only alert type currently used by the Disk component. The check constraint allows additional types (BACKUP_MISSED, JOB_FAILED, DB_OFFLINE, ERROR_LOG_CRITICAL, LONG_RUNNING_QUERY) for future expansion.

### description / alerted_dttm #9  [metadata_id: 1319]

When notification was sent

### description / detected_dttm #8  [metadata_id: 1318]

When condition was first detected

### description / is_resolved #11  [metadata_id: 1321]

Whether alert condition has cleared

### description / resolved_by #13  [metadata_id: 1323]

Who/what resolved the alert

### description / resolved_dttm #12  [metadata_id: 1322]

When condition cleared

### description / server_id #2  [metadata_id: 1312]

FK to ServerRegistry.server_id

### description / threshold_value #6  [metadata_id: 1316]

Threshold that was breached

## Disk_Snapshot (Table)

### category #0  [metadata_id: 1743]

Disk

### data_flow #0  [metadata_id: 2471]

Collect-ServerHealth.ps1 connects to each monitored server via WinRM/CIM (Win32_LogicalDisk, DriveType=3) and inserts one row per fixed drive per collection cycle. The script evaluates thresholds against in-memory collection data immediately after insert, checking Disk_ThresholdConfig and Disk_AlertHistory for breach detection and auto-resolution. Send-DiskHealthSummary.ps1 reads the latest snapshot per server/drive joined to Disk_ThresholdConfig to build the daily Adaptive Card. The Control Center Server Health page reads this table for current disk status display and historical trend charts.

### description #0  [metadata_id: 111]

Hourly disk space snapshots from all monitored servers, collected by PowerShell and used for threshold monitoring and historical trending.

### design_note #1  [metadata_id: 2472]
Title: PowerShell Collection Over SQL DMVs

SQL Server DMVs (sys.dm_os_volume_stats) only see drives containing database files. PowerShell via WinRM queries Win32_LogicalDisk which sees all fixed drives on the server, including drives used for backups, logs, or application data that have no database files.

### module #0  [metadata_id: 1639]

ServerOps

### query #1  [metadata_id: 2720]
Title: Current Disk Status (Latest Snapshot)

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

### query #2  [metadata_id: 2721]
Title: 7-Day Trend for a Specific Drive

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

### query #3  [metadata_id: 2722]
Title: Find Drives with Declining Free Space
Description: Compare today vs 7 days ago

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

### relationship_note #1  [metadata_id: 2473]
Title: ServerRegistry Enrollment

server_id references dbo.ServerRegistry. Only servers with is_active = 1 and serverops_disk_enabled = 1 are collected. Server enrollment is the single control point for adding or removing servers from disk monitoring.

### description / drive_letter #3  [metadata_id: 1296]

Drive letter (C, D, E, etc.)

### description / free_space_mb #6  [metadata_id: 1299]

Current free space in megabytes

### description / percent_free #7  [metadata_id: 1300]

Percentage of drive that is free

### description / server_id #2  [metadata_id: 1295]

FK to ServerRegistry.server_id

### description / snapshot_dttm #8  [metadata_id: 1301]

When the snapshot was collected

### description / snapshot_id #1  [metadata_id: 1294]

Unique identifier for the snapshot

### description / total_size_mb #5  [metadata_id: 1298]

Total drive capacity in megabytes

### description / volume_label #4  [metadata_id: 1297]

Windows volume label (if set)

## Disk_Status (Table)

### category #0  [metadata_id: 1744]

Disk

### data_flow #0  [metadata_id: 2487]

Collect-ServerHealth.ps1 updates this table twice per execution cycle: once after disk collection (last_collection_dttm) and once after threshold evaluation (last_poll_dttm, last_poll_status, poll metrics, and daily counters). Send-DiskHealthSummary.ps1 updates last_health_check_dttm and last_health_check_status after generating the daily summary. The Control Center Server Health page reads this table for the Disk component health indicator and script execution gauges.

### description #0  [metadata_id: 137]

Single-row dashboard and status tracking table providing at-a-glance disk monitoring health information and poll metrics.

### design_note #1  [metadata_id: 2488]
Title: Single-Row Status Pattern

CK_Disk_Status_SingleRow constrains status_id to exactly 1, ensuring only one row exists. This simplifies dashboard queries (no WHERE clause needed beyond the constant) and guarantees consistent state. Both scripts update the same row with their respective timestamps and metrics.

### design_note #2  [metadata_id: 2489]
Title: Separate Collection and Poll Tracking

last_collection_dttm and last_poll_dttm are updated at different points in the Collect-ServerHealth.ps1 execution. Collection (Steps 1-4) updates first when disk data is gathered. Poll evaluation (Steps 5-10) updates after threshold analysis completes. If collection succeeds but threshold evaluation fails, the timestamps diverge — this distinction helps isolate which phase had the problem.

### design_note #3  [metadata_id: 2490]
Title: Daily Counter Reset

alerts_detected_today and alerts_sent_today reset when the date portion of last_poll_dttm differs from the current date. Collect-ServerHealth.ps1 checks this at the start of the poll metrics update and resets counters to 0 before adding the current cycle counts. This provides day-over-day comparison without requiring a separate scheduled reset process.

### module #0  [metadata_id: 1640]

ServerOps

### query #1  [metadata_id: 2723]
Title: Component Health Check

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

### query #2  [metadata_id: 2724]
Title: Dashboard Summary

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

### query #3  [metadata_id: 2725]
Title: Today's Alert Activity

SELECT 
    alerts_detected_today,
    alerts_sent_today,
    CAST(last_poll_dttm AS DATE) AS last_poll_date
FROM ServerOps.Disk_Status
WHERE status_id = 1;

### description / alerts_detected_today #9  [metadata_id: 1556]

New alerts detected today (resets at midnight)

### description / alerts_sent_today #10  [metadata_id: 1557]

Notifications sent today (resets at midnight)

### description / drives_below_threshold #8  [metadata_id: 1555]

Count of drives currently below threshold

### description / drives_monitored #7  [metadata_id: 1554]

Count of drives checked in last poll

### description / last_collection_dttm #2  [metadata_id: 1549]

When PowerShell last collected disk data

### description / last_health_check_dttm #11  [metadata_id: 1558]

When Send-DiskHealthSummary.ps1 last ran

### description / last_health_check_status #12  [metadata_id: 1559]

Result of last health check

### description / last_poll_dttm #3  [metadata_id: 1550]

When Collect-ServerHealth.ps1 last evaluated thresholds

### description / last_poll_duration_ms #4  [metadata_id: 1551]

Duration of last poll in milliseconds

### description / last_poll_status #5  [metadata_id: 1552]

Result of last poll (SUCCESS, NO_DATA, etc.)

### status_value / last_poll_status #1  [metadata_id: 2491]
Title: SUCCESS

Threshold evaluation completed normally. All collected drives were evaluated against their thresholds, alerts were created or resolved as needed, and poll metrics were updated.

### status_value / last_poll_status #2  [metadata_id: 2492]
Title: FAILED

Threshold evaluation encountered an error. The try/catch wrapper around Steps 5-10 in Collect-ServerHealth.ps1 catches the failure and records it here. Disk collection data from Steps 1-4 is already committed and unaffected.

### status_value / last_poll_status #3  [metadata_id: 2493]
Title: SKIPPED

Threshold evaluation was skipped because no drives were collected in the current cycle. This occurs when all servers are unreachable or no servers have serverops_disk_enabled = 1.

### description / modified_dttm #13  [metadata_id: 1560]

When status was last updated

### description / servers_monitored #6  [metadata_id: 1553]

Count of active servers in last poll

### description / status_id #1  [metadata_id: 1548]

Fixed identifier - always 1

## Disk_ThresholdConfig (Table)

### category #0  [metadata_id: 1745]

Disk

### data_flow #0  [metadata_id: 2474]

Collect-ServerHealth.ps1 auto-creates rows for newly discovered drives using the default_threshold_pct from GlobalConfig (ServerOps/Disk), with created_by set to Collect-ServerHealth.ps1. Manual adjustments are made directly by administrators. Send-DiskHealthSummary.ps1 reads threshold_pct for drive classification (BELOW, APPROACHING, OK). Collect-ServerHealth.ps1 reads threshold_pct and alert_enabled during threshold evaluation to determine breach detection and alert eligibility.

### description #0  [metadata_id: 98]

Per-drive threshold configuration for disk space monitoring, allowing different alert thresholds for each drive on each server.

### design_note #1  [metadata_id: 2475]
Title: Auto-Creation for New Drives

When Collect-ServerHealth.ps1 discovers a drive in collection data that has no matching ThresholdConfig row, it automatically creates one using the default threshold from GlobalConfig. The new config is added to an in-memory lookup immediately so threshold evaluation can use it in the same cycle. This ensures new drives are monitored from their first appearance without manual intervention.

### design_note #2  [metadata_id: 2476]
Title: Per-Drive Alerting Control

The alert_enabled flag allows suppressing alerts for individual drives without changing the threshold or removing the configuration. A drive with alert_enabled = 0 still appears in snapshots and the daily summary but will not trigger Jira tickets. Useful for drives being decommissioned, intentionally kept full, or under separate management.

### module #0  [metadata_id: 1641]

ServerOps

### query #1  [metadata_id: 2726]
Title: List All Threshold Configurations

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

### query #2  [metadata_id: 2727]
Title: Find Non-Standard Thresholds
Description: Find drives with thresholds different from default 20%

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

### relationship_note #1  [metadata_id: 2477]
Title: One Threshold Per Drive

UQ_Disk_ThresholdConfig_ServerDrive enforces one configuration row per server_id + drive_letter combination. This ensures unambiguous threshold lookup during evaluation and prevents conflicting configurations for the same drive.

### description / alert_enabled #5  [metadata_id: 1124]

Whether to generate alerts for this drive

### description / created_by #9  [metadata_id: 1127]

Who created the configuration

### description / created_dttm #8  [metadata_id: 1126]

When threshold was configured

### description / description #7  [metadata_id: 1125]

Optional description of the drive purpose

### description / drive_letter #3  [metadata_id: 1122]

Drive letter (C, D, E, etc.)

### description / modified_by #11  [metadata_id: 1129]

Who last changed the threshold

### description / modified_dttm #10  [metadata_id: 1128]

When threshold was last changed

### description / server_id #2  [metadata_id: 1121]

FK to ServerRegistry.server_id

### description / threshold_id #1  [metadata_id: 1120]

Unique identifier for the threshold config

### description / threshold_pct #4  [metadata_id: 1123]

Minimum percent free before alerting

## Execute-DBCC.ps1 (Script)

### category #0  [metadata_id: 3562]

DBCC

### data_flow #0  [metadata_id: 3624]

Reads execution options from dbo.GlobalConfig (module ServerOps, category DBCC). In scheduled mode, reads ServerOps.DBCC_ScheduleConfig joined to dbo.ServerRegistry for operations due this hour. In manual mode, reads dbo.ServerRegistry and dbo.DatabaseRegistry for the specified target. For AG listeners, resolves replica roles via sys.dm_hadr_availability_replica_states. Checks database online state via sys.databases on the target server. Executes DBCC commands and writes results to ServerOps.DBCC_ExecutionLog. Queues Teams alerts via Teams.AlertQueue on non-SUCCESS and Jira tickets via Jira.sp_QueueTicket on CHECKDB ERRORS_FOUND. Reports completion to the orchestrator via Complete-OrchestratorTask.

### description #0  [metadata_id: 3560]

Executes scheduled DBCC integrity operations against databases per DBCC_ScheduleConfig. Supports CHECKDB, CHECKALLOC, CHECKCATALOG, and CHECKCONSTRAINTS. In scheduled mode, queries the schedule table for operations due in the current hour and executes them in priority order from lightest to heaviest. In manual override mode (-TargetServer + -Operation), bypasses the schedule table to run a specific operation on demand. Results are logged to DBCC_ExecutionLog with Teams alerting on non-SUCCESS and Jira tickets on CHECKDB corruption.

### design_note #1  [metadata_id: 3625]
Title: Schedule-Driven Execution

The script runs on a configurable interval via ProcessRegistry. Each invocation queries DBCC_ScheduleConfig for operations whose run_day matches today and whose run_time hour has arrived. If nothing is due, it reports success with a no-work result and exits. The ExecutionLog is checked before each operation to prevent duplicate execution within the same day.

### design_note #2  [metadata_id: 3626]
Title: Operation Priority Order

Scheduled operations execute from lightest to heaviest: CHECKCATALOG (seconds), CHECKALLOC (seconds to minutes), CHECKCONSTRAINTS (minutes to hours), CHECKDB (hours). This ensures lightweight checks complete quickly even when a long-running CHECKDB is in the queue.

### design_note #3  [metadata_id: 3627]
Title: Manual Override Mode

The -TargetServer, -TargetDatabase, and -Operation parameters bypass the schedule table entirely. Manual mode skips the already-executed-today check, allowing re-execution for diagnostic purposes. Server connection details are still resolved from ServerRegistry.

### design_note #4  [metadata_id: 3628]
Title: AG Secondary Execution

For AG listener entries, the script uses the standard AG topology detection pattern to resolve the current secondary replica. DBCC operations run via a direct connection to the physical secondary. The physical server name is recorded in executed_on_server for accurate history. If the secondary cannot be resolved, the server is skipped with a Teams alert.

### module #0  [metadata_id: 3561]

ServerOps

### relationship_note #1  [metadata_id: 3629]
Title: DBCC_ScheduleConfig

Primary input for scheduled mode. The script queries this table for enabled operations matching the current day and hour, joined to ServerRegistry for the server-level master switch.

### relationship_note #2  [metadata_id: 3630]
Title: DBCC_ExecutionLog

Primary output. One row inserted per database per operation at start (IN_PROGRESS), updated on completion with status, duration, and error details. Also checked before execution to prevent duplicate runs today.

### relationship_note #3  [metadata_id: 3631]
Title: GlobalConfig

Reads DBCC execution options at startup: max_dop, extended_logical_checks, alerting_enabled. AG topology settings (AGName, SourceReplica) are also loaded from GlobalConfig. check_mode is read per database from DBCC_ScheduleConfig, not GlobalConfig.

## Execute-IndexMaintenance.ps1 (Script)

### category #0  [metadata_id: 3063]

Index

### data_flow #0  [metadata_id: 3064]

Reads GlobalConfig for rebuild settings (MAXDOP, lock timeout, seconds-per-page coefficients). Queries Index_Queue joined to DatabaseRegistry, ServerRegistry, and Index_DatabaseConfig for databases with queued work. Evaluates schedule via xFACts-IndexFunctions.ps1 (Get-EffectiveSchedule, Get-AvailableMinutes, Get-MaxWeekdayWindow, Get-IndexesForWindow). Resets queue statuses at startup (DEFERRED/FAILED ? PENDING; SCHEDULED ? PENDING on extended windows). For each selected index: sets queue status to IN_PROGRESS, inserts IN_PROGRESS row into Index_ExecutionLog, executes ALTER INDEX REBUILD, captures post-rebuild fragmentation, calculates variance, updates ExecutionLog and Index_Registry, and deletes the queue entry (success) or sets it to FAILED. Updates Index_Status (EXECUTE row) with real-time counter increments. Logs per-database results to Index_ExecutionSummary (EXECUTE). Reports to Orchestrator v2.

### description #0  [metadata_id: 3061]

Executes index rebuild operations from the Index_Queue during maintenance windows. Respects the three-tier schedule hierarchy (Exception ? Holiday ? DatabaseSchedule), uses best-fit selection on weekdays to maximize throughput, switches to priority ordering on extended windows (weekends/holidays), marks oversized indexes as SCHEDULED, and tracks estimate-vs-actual variance for duration refinement. Runs as a FIRE_AND_FORGET process under Orchestrator v2.

### design_note #1  [metadata_id: 3065]
Title: Continuous Work Claiming

Uses a WHILE loop per database that re-queries the queue after each batch of indexes. When a batch completes and time remains in the maintenance window, it claims more work. This maximizes throughput during long windows instead of processing one batch and exiting.

### design_note #2  [metadata_id: 3066]
Title: Schedule Re-Check Before Each Index

Before each individual rebuild, the script re-evaluates Get-EffectiveSchedule to confirm the window is still open. If the window closes mid-batch, the script stops gracefully rather than overrunning into production hours. This provides per-index granularity on schedule enforcement.

### design_note #3  [metadata_id: 3067]
Title: Edition-Aware Online/Offline

The online_option from Index_Queue respects the database's index_allow_offline_rebuild setting. However, if the SQL Server edition is not Enterprise, the script overrides to OFFLINE regardless — online rebuilds require Enterprise Edition. This is noted in the log for transparency.

### module #0  [metadata_id: 3062]

ServerOps

## Index_DatabaseConfig (Table)

### category #0  [metadata_id: 1740]

Index

### data_flow #0  [metadata_id: 2943]

Rows are manually inserted per database during enrollment. Sync-IndexRegistry.ps1 reads index_sync_enabled to filter target databases and respects the server-level master switch (ServerRegistry.serverops_index_enabled). Scan-IndexFragmentation.ps1 reads index_maintenance_enabled, index_fragmentation_threshold, index_min_page_count, index_allow_offline_rebuild, and index_maintenance_priority to apply per-database overrides during scanning and queue population. Execute-IndexMaintenance.ps1 reads index_maintenance_priority and index_allow_offline_rebuild for work selection and rebuild mode decisions. Update-IndexStatistics.ps1 reads stats_maintenance_enabled and stats_sample_pct for per-database statistics processing.

### description #0  [metadata_id: 117]

Per-database configuration for index rebuild/reorganize maintenance and statistics updates. Stores priority, thresholds, offline rebuild permissions, and maintenance enablement flags for each enrolled database.

### design_note #1  [metadata_id: 2944]
Title: Three Independent Feature Flags

index_sync_enabled controls whether indexes are cataloged in Index_Registry (prerequisite for everything). stats_maintenance_enabled controls statistics updates. index_maintenance_enabled controls fragmentation scanning and index rebuilds. This allows progressive enrollment: catalog first, then enable stats, then enable rebuilds — each independently togglable.

### design_note #2  [metadata_id: 2945]
Title: Per-Database Threshold Overrides

index_fragmentation_threshold, index_min_page_count, and index_scan_interval_minutes are nullable — when NULL, the script uses GlobalConfig defaults. This provides sensible defaults with opt-in per-database customization. A large OLTP database might use a higher page count minimum to skip tiny indexes, while a smaller database might lower the fragmentation threshold for tighter maintenance.

### design_note #3  [metadata_id: 2946]
Title: Priority-Based Scheduling

index_maintenance_priority (1-3) drives two behaviors: priority scoring in the queue (higher priority databases get higher scores) and execution ordering (priority 1 databases are processed before priority 2 and 3). This ensures critical production databases get maintenance attention first when time is limited.

### module #0  [metadata_id: 1636]

ServerOps

### query #1  [metadata_id: 2950]
Title: Enrollment overview
Description: Shows all enrolled databases with their feature flags and threshold overrides.

SELECT
    dr.database_name,
    sr.server_name,
    dc.index_sync_enabled,
    dc.index_maintenance_enabled,
    dc.stats_maintenance_enabled,
    dc.index_maintenance_priority,
    dc.index_allow_offline_rebuild,
    dc.index_fragmentation_threshold,
    dc.index_min_page_count,
    dc.stats_sample_pct
FROM ServerOps.Index_DatabaseConfig dc
JOIN dbo.DatabaseRegistry dr ON dc.database_id = dr.database_id
JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
ORDER BY sr.server_name, dc.index_maintenance_priority, dr.database_name;

### relationship_note #1  [metadata_id: 2951]
Title: dbo.DatabaseRegistry

Each row references a database_id from DatabaseRegistry. A database must be active in DatabaseRegistry (is_active = 1) and have a DatabaseConfig row with the appropriate feature flag enabled for any Index component script to process it.

### relationship_note #2  [metadata_id: 2952]
Title: dbo.ServerRegistry

ServerRegistry.serverops_index_enabled acts as a server-level master switch. Even if a database has all feature flags enabled in DatabaseConfig, no Index scripts will process it if the server's master switch is disabled. This allows emergency shutdown of all index maintenance on a server without touching individual database configurations.

### description / created_by #16  [metadata_id: 1375]

Who created the configuration

### description / created_dttm #15  [metadata_id: 1374]

When the configuration was created

### description / database_config_id #1  [metadata_id: 3662]

Identity primary key.

### description / database_id #2  [metadata_id: 1361]

PK and FK to dbo.DatabaseRegistry.database_id

### description / index_allow_offline_rebuild #10  [metadata_id: 1369]

Whether offline rebuilds are permitted (0 = ONLINE only)

### description / index_fragmentation_threshold #11  [metadata_id: 1370]

Override fragmentation threshold (NULL = use global default)

### description / index_maintenance_enabled #7  [metadata_id: 1366]

Whether index rebuild/reorganize maintenance is enabled

### description / index_maintenance_priority #9  [metadata_id: 1368]

Priority tier for maintenance scoring: 1=Critical (40 pts), 2=High (25 pts), 3=Normal (15 pts)

### status_value / index_maintenance_priority #1  [metadata_id: 2947]
Title: 1

Highest priority. Critical production databases. Receives the highest priority score component (default 40 points) and is processed first during execution.

### status_value / index_maintenance_priority #2  [metadata_id: 2948]
Title: 2

Standard priority. Normal production databases. Receives a mid-range priority score component (default 25 points).

### status_value / index_maintenance_priority #3  [metadata_id: 2949]
Title: 3

Lowest priority. Low-activity or non-critical databases. Receives the lowest priority score component (default 15 points). Also the default if not explicitly set.

### description / index_min_page_count #12  [metadata_id: 1371]

Override minimum page count (NULL = use global default)

### description / index_scan_interval_minutes #13  [metadata_id: 1372]

Override scan frequency in minutes (NULL = use global default)

### description / index_sync_enabled #6  [metadata_id: 1365]

Whether database indexes are cataloged in Index_Registry. Prerequisite for index and stats maintenance

### description / modified_by #18  [metadata_id: 1377]

Who last modified the configuration

### description / modified_dttm #17  [metadata_id: 1376]

When the configuration was last modified

### description / stats_maintenance_enabled #8  [metadata_id: 1367]

Whether statistics maintenance is enabled for this database

### description / stats_sample_pct #14  [metadata_id: 1373]

Override sample percentage for UPDATE STATISTICS (NULL = use global default, 0 = FULLSCAN)

## Index_DatabaseSchedule (Table)

### category #0  [metadata_id: 1741]

Index

### data_flow #0  [metadata_id: 2953]

Rows are created by sp_Index_AddDatabaseSchedule during enrollment (7 rows per database, one per day of week). xFACts-IndexFunctions.ps1 reads this table via Get-EffectiveSchedule to determine whether the current hour is allowed for index maintenance. Get-MaxWeekdayWindow queries Monday through Friday rows to find the largest contiguous allowed block, which determines whether an index is too large for any weekday window (marking it SCHEDULED for weekend/holiday processing).

### description #0  [metadata_id: 99]

Per-database default maintenance schedules defining allowed and blocked hours for each day of the week. Each database enrolled in index maintenance has 7 rows (one per day) with 24 hourly columns representing the weekly schedule template.

### design_note #1  [metadata_id: 2954]
Title: Hourly Bit Grid

Each row represents one day of the week with 24 bit columns (hr00 through hr23). A value of 1 means maintenance is allowed during that hour; 0 means blocked. This denormalized design enables single-row lookups for schedule checks — no joins, no pivots, and no interpretation needed. sp_Index_AddDatabaseSchedule generates these from simple block range parameters.

### design_note #2  [metadata_id: 2955]
Title: Lowest Priority in Schedule Hierarchy

This is the fallback schedule, checked only after Exception and Holiday schedules. Execute-IndexMaintenance.ps1 evaluates Exception (DATABASE ? SERVER ? GLOBAL scope) first, then Holiday (weekdays only, via dbo.Holiday + Index_HolidaySchedule), then DatabaseSchedule. This allows ad-hoc overrides without modifying the baseline schedule.

### module #0  [metadata_id: 1637]

ServerOps

### relationship_note #1  [metadata_id: 2956]
Title: sp_Index_AddDatabaseSchedule

The proc generates all 7 rows from simple parameters (weekday block start/end, weekend block start/end, optional Sunday override). Existing rows must be deleted before re-initialization — the proc validates no rows exist for the database.

### relationship_note #2  [metadata_id: 2957]
Title: Index_ExceptionSchedule

Exception overrides take priority over DatabaseSchedule. If an exception row exists for today's date at any scope (DATABASE, SERVER, GLOBAL), it completely replaces the DatabaseSchedule for that hour. This is evaluated in Get-EffectiveSchedule before DatabaseSchedule is checked.

### description / created_by #28  [metadata_id: 1157]

Who created this schedule

### description / created_dttm #27  [metadata_id: 1156]

When this schedule was created

### description / database_id #1  [metadata_id: 1130]

FK to dbo.DatabaseRegistry.database_id

### description / day_of_week #2  [metadata_id: 1131]

1=Sunday, 2=Monday, ..., 7=Saturday

### description / hr00 #3  [metadata_id: 1132]

Midnight to 1am

### description / hr01 #4  [metadata_id: 1133]

1am to 2am

### description / hr02 #5  [metadata_id: 1134]

2am to 3am

### description / hr03 #6  [metadata_id: 1135]

3am to 4am

### description / hr04 #7  [metadata_id: 1136]

4am to 5am

### description / hr05 #8  [metadata_id: 1137]

5am to 6am

### description / hr06 #9  [metadata_id: 1138]

6am to 7am

### description / hr07 #10  [metadata_id: 1139]

7am to 8am

### description / hr08 #11  [metadata_id: 1140]

8am to 9am

### description / hr09 #12  [metadata_id: 1141]

9am to 10am

### description / hr10 #13  [metadata_id: 1142]

10am to 11am

### description / hr11 #14  [metadata_id: 1143]

11am to noon

### description / hr12 #15  [metadata_id: 1144]

Noon to 1pm

### description / hr13 #16  [metadata_id: 1145]

1pm to 2pm

### description / hr14 #17  [metadata_id: 1146]

2pm to 3pm

### description / hr15 #18  [metadata_id: 1147]

3pm to 4pm

### description / hr16 #19  [metadata_id: 1148]

4pm to 5pm

### description / hr17 #20  [metadata_id: 1149]

5pm to 6pm

### description / hr18 #21  [metadata_id: 1150]

6pm to 7pm

### description / hr19 #22  [metadata_id: 1151]

7pm to 8pm

### description / hr20 #23  [metadata_id: 1152]

8pm to 9pm

### description / hr21 #24  [metadata_id: 1153]

9pm to 10pm

### description / hr22 #25  [metadata_id: 1154]

10pm to 11pm

### description / hr23 #26  [metadata_id: 1155]

11pm to midnight

### description / modified_by #30  [metadata_id: 1159]

Who last modified this schedule

### description / modified_dttm #29  [metadata_id: 1158]

When this schedule was last modified

## Index_ExceptionSchedule (Table)

### category #0  [metadata_id: 1746]

Index

### data_flow #0  [metadata_id: 2958]

Rows are manually inserted for planned events (deployments, emergency freezes, special maintenance windows). xFACts-IndexFunctions.ps1 reads this table first in the Get-EffectiveSchedule hierarchy, checking DATABASE scope, then SERVER scope, then GLOBAL scope. The first match at any scope determines whether the hour is allowed — no further schedule tables are consulted.

### description #0  [metadata_id: 36]

Ad-hoc maintenance window exceptions with hierarchical scope (DATABASE ? SERVER ? GLOBAL). Provides one-time overrides to normal schedules and holidays, allowing temporary adjustment of maintenance windows without modifying recurring schedules.

### design_note #1  [metadata_id: 2959]
Title: Three-Scope Hierarchy with Constraint Enforcement

The scope column (GLOBAL, SERVER, DATABASE) determines which resources are affected. CHECK constraints enforce referential consistency: DATABASE scope requires database_id and NULL server_id, SERVER scope requires server_id and NULL database_id, GLOBAL scope requires both NULL. The evaluation order (DATABASE ? SERVER ? GLOBAL) means a database-specific exception overrides a server-wide freeze, which overrides a global block.

### design_note #2  [metadata_id: 2960]
Title: Same Hourly Bit Grid as DatabaseSchedule

Uses the same hr00-hr23 bit column pattern as DatabaseSchedule and HolidaySchedule. A value of 1 means maintenance is allowed during that hour; 0 means blocked. An EMERGENCY_BLOCK exception with all hours set to 0 completely prevents maintenance for the specified date and scope.

### module #0  [metadata_id: 1642]

ServerOps

### query #1  [metadata_id: 2967]
Title: Active exceptions for the next 7 days
Description: Shows upcoming exceptions that will affect maintenance scheduling.

SELECT
    exception_date,
    exception_name,
    exception_type,
    scope,
    COALESCE(sr.server_name, 'ALL') AS server_name,
    COALESCE(dr.database_name, 'ALL') AS database_name,
    (CAST(hr00 AS INT)+CAST(hr01 AS INT)+CAST(hr02 AS INT)+CAST(hr03 AS INT)+
     CAST(hr04 AS INT)+CAST(hr05 AS INT)+CAST(hr06 AS INT)+CAST(hr07 AS INT)+
     CAST(hr08 AS INT)+CAST(hr09 AS INT)+CAST(hr10 AS INT)+CAST(hr11 AS INT)+
     CAST(hr12 AS INT)+CAST(hr13 AS INT)+CAST(hr14 AS INT)+CAST(hr15 AS INT)+
     CAST(hr16 AS INT)+CAST(hr17 AS INT)+CAST(hr18 AS INT)+CAST(hr19 AS INT)+
     CAST(hr20 AS INT)+CAST(hr21 AS INT)+CAST(hr22 AS INT)+CAST(hr23 AS INT)) AS allowed_hours
FROM ServerOps.Index_ExceptionSchedule es
LEFT JOIN dbo.ServerRegistry sr ON es.server_id = sr.server_id
LEFT JOIN dbo.DatabaseRegistry dr ON es.database_id = dr.database_id
WHERE es.exception_date >= CAST(GETDATE() AS DATE)
  AND es.exception_date < DATEADD(DAY, 7, CAST(GETDATE() AS DATE))
  AND es.is_enabled = 1
ORDER BY es.exception_date, es.scope;

### description / created_by #35  [metadata_id: 197]

Who created this exception

### description / created_dttm #34  [metadata_id: 196]

When this exception was created

### description / database_id #7  [metadata_id: 169]

FK to dbo.DatabaseRegistry (required for DATABASE scope)

### description / exception_date #2  [metadata_id: 164]

The calendar date this exception applies to

### description / exception_id #1  [metadata_id: 163]

Unique identifier for the exception

### description / exception_name #3  [metadata_id: 165]

Short name identifying this exception

### description / exception_type #4  [metadata_id: 166]

MAINTENANCE_WINDOW, EMERGENCY_BLOCK, or SPECIAL_EVENT

### status_value / exception_type #1  [metadata_id: 2964]
Title: MAINTENANCE_WINDOW

A planned expanded or modified maintenance window. Typically opens additional hours for index rebuilds.

### status_value / exception_type #2  [metadata_id: 2965]
Title: EMERGENCY_BLOCK

An emergency freeze blocking all maintenance. Typically used during incidents, unexpected load, or deployment issues. All hr columns set to 0.

### status_value / exception_type #3  [metadata_id: 2966]
Title: SPECIAL_EVENT

A known event requiring schedule adjustment (deployment, migration, audit). May block certain hours while opening others.

### description / hr00 #8  [metadata_id: 170]

Midnight to 1am

### description / hr01 #9  [metadata_id: 171]

1am to 2am

### description / hr02 #10  [metadata_id: 172]

2am to 3am

### description / hr03 #11  [metadata_id: 173]

3am to 4am

### description / hr04 #12  [metadata_id: 174]

4am to 5am

### description / hr05 #13  [metadata_id: 175]

5am to 6am

### description / hr06 #14  [metadata_id: 176]

6am to 7am

### description / hr07 #15  [metadata_id: 177]

7am to 8am

### description / hr08 #16  [metadata_id: 178]

8am to 9am

### description / hr09 #17  [metadata_id: 179]

9am to 10am

### description / hr10 #18  [metadata_id: 180]

10am to 11am

### description / hr11 #19  [metadata_id: 181]

11am to noon

### description / hr12 #20  [metadata_id: 182]

Noon to 1pm

### description / hr13 #21  [metadata_id: 183]

1pm to 2pm

### description / hr14 #22  [metadata_id: 184]

2pm to 3pm

### description / hr15 #23  [metadata_id: 185]

3pm to 4pm

### description / hr16 #24  [metadata_id: 186]

4pm to 5pm

### description / hr17 #25  [metadata_id: 187]

5pm to 6pm

### description / hr18 #26  [metadata_id: 188]

6pm to 7pm

### description / hr19 #27  [metadata_id: 189]

7pm to 8pm

### description / hr20 #28  [metadata_id: 190]

8pm to 9pm

### description / hr21 #29  [metadata_id: 191]

9pm to 10pm

### description / hr22 #30  [metadata_id: 192]

10pm to 11pm

### description / hr23 #31  [metadata_id: 193]

11pm to midnight

### description / is_enabled #32  [metadata_id: 194]

Whether this exception is currently active

### description / modified_by #37  [metadata_id: 199]

Who last modified this exception

### description / modified_dttm #36  [metadata_id: 198]

When this exception was last modified

### description / notes #33  [metadata_id: 195]

Business reason or additional context for this exception

### description / scope #5  [metadata_id: 167]

DATABASE, SERVER, or GLOBAL

### status_value / scope #1  [metadata_id: 2961]
Title: DATABASE

Applies to a single database. Requires database_id to be populated and server_id to be NULL. Checked first in the hierarchy — overrides SERVER and GLOBAL exceptions.

### status_value / scope #2  [metadata_id: 2962]
Title: SERVER

Applies to all databases on a specific server. Requires server_id to be populated and database_id to be NULL. Checked second — overrides GLOBAL exceptions but yields to DATABASE exceptions.

### status_value / scope #3  [metadata_id: 2963]
Title: GLOBAL

Applies to all databases across all servers. Requires both server_id and database_id to be NULL. Checked last — yields to SERVER and DATABASE exceptions.

### description / server_id #6  [metadata_id: 168]

FK to dbo.ServerRegistry (required for SERVER scope)

## Index_ExecutionLog (Table)

### category #0  [metadata_id: 1748]

Index

### data_flow #0  [metadata_id: 3003]

Execute-IndexMaintenance.ps1 inserts an IN_PROGRESS row before each rebuild with pre-rebuild fragmentation, priority score, estimated duration, rebuild mode, and MAXDOP. After the rebuild completes (or fails), it updates the row with actual duration, post-rebuild fragmentation, variance percentage, and status. Each row is tied to a run_id (batch), queue_id (queue entry), and registry_id (index registry entry).

### description #0  [metadata_id: 96]

Per-index execution detail for Index component rebuild operations. Captures timing, variance, and before/after fragmentation for audit trails and estimate refinement.

### design_note #1  [metadata_id: 3004]
Title: Estimate vs Actual Variance Tracking

variance_pct records the percentage difference between estimated and actual rebuild duration: ((actual - estimated) / estimated) * 100. Positive values indicate underestimation, negative values overestimation. This enables analysis of estimate accuracy by size tier and rebuild mode, which informs tuning of the seconds-per-page coefficients in GlobalConfig.

### design_note #2  [metadata_id: 3005]
Title: Before/After Fragmentation Proof

fragmentation_pct_before is captured from the queue at rebuild start. fragmentation_pct_after is captured via a fresh dm_db_index_physical_stats scan immediately after the rebuild. This provides auditable proof that each rebuild accomplished its goal and supports effectiveness reporting.

### design_note #3  [metadata_id: 3006]
Title: Deferral Count at Execution

deferral_count_at_execution captures how many times this index was skipped before finally being rebuilt. This metric identifies indexes that consistently get deferred — potential candidates for SCHEDULED status, fill factor adjustment, or priority tuning.

### module #0  [metadata_id: 1644]

ServerOps

### query #1  [metadata_id: 3012]
Title: Current run progress
Description: Shows all operations from the most recent execution run with their status and timing.

SELECT
    database_name,
    schema_name,
    table_name,
    index_name,
    rebuild_mode,
    page_count,
    fragmentation_pct_before,
    fragmentation_pct_after,
    estimated_seconds,
    duration_seconds,
    variance_pct,
    status,
    started_dttm
FROM ServerOps.Index_ExecutionLog
WHERE run_id = (SELECT MAX(run_id) FROM ServerOps.Index_ExecutionLog)
ORDER BY started_dttm;

### query #2  [metadata_id: 3013]
Title: Estimation accuracy by size tier
Description: Analyzes how well the seconds-per-page coefficients predict rebuild duration across different index sizes.

SELECT
    CASE
        WHEN page_count < 10000 THEN 'Small (<10K)'
        WHEN page_count < 100000 THEN 'Medium (10K-100K)'
        WHEN page_count < 1000000 THEN 'Large (100K-1M)'
        ELSE 'Huge (>1M)'
    END AS size_tier,
    rebuild_mode,
    COUNT(*) AS rebuilds,
    AVG(estimated_seconds) AS avg_estimated,
    AVG(duration_seconds) AS avg_actual,
    AVG(variance_pct) AS avg_variance_pct
FROM ServerOps.Index_ExecutionLog
WHERE status = 'SUCCESS'
  AND variance_pct IS NOT NULL
GROUP BY
    CASE
        WHEN page_count < 10000 THEN 'Small (<10K)'
        WHEN page_count < 100000 THEN 'Medium (10K-100K)'
        WHEN page_count < 1000000 THEN 'Large (100K-1M)'
        ELSE 'Huge (>1M)'
    END,
    rebuild_mode
ORDER BY size_tier, rebuild_mode;

### query #3  [metadata_id: 3014]
Title: Indexes that consistently fail
Description: Indexes with 3 or more failures in the last 30 days — may need exclusion, investigation, or manual intervention.

SELECT
    database_name,
    index_name,
    COUNT(*) AS failure_count,
    MAX(started_dttm) AS last_failure,
    MAX(error_message) AS last_error
FROM ServerOps.Index_ExecutionLog
WHERE status = 'FAILED'
  AND started_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY database_name, index_name
HAVING COUNT(*) >= 3
ORDER BY failure_count DESC;

### description / completed_dttm #23  [metadata_id: 1078]

When the rebuild completed (NULL if still running)

### description / database_id #5  [metadata_id: 1060]

FK to dbo.DatabaseRegistry.database_id

### description / database_name #7  [metadata_id: 1062]

Database name

### description / deferral_count_at_execution #26  [metadata_id: 1081]

How many times this index was deferred before finally running

### description / detail_id #1  [metadata_id: 1056]

Unique identifier for the detail entry

### description / duration_seconds #20  [metadata_id: 1075]

Actual duration (NULL if still running)

### description / error_message #25  [metadata_id: 1080]

Error details if failed

### description / estimated_seconds #19  [metadata_id: 1074]

Pre-calculated duration estimate (mode-specific)

### description / fill_factor_used #17  [metadata_id: 1072]

Fill factor applied (NULL = default)

### description / fragmentation_pct_after #13  [metadata_id: 1068]

Fragmentation after rebuild (NULL if failed)

### description / fragmentation_pct_before #12  [metadata_id: 1067]

Fragmentation before rebuild

### description / index_name #10  [metadata_id: 1065]

Name of the index

### description / maxdop_used #18  [metadata_id: 1073]

MAXDOP setting used

### description / operation_type #15  [metadata_id: 1070]

REBUILD or REORGANIZE

### description / page_count #11  [metadata_id: 1066]

Page count at time of rebuild

### description / priority_score #14  [metadata_id: 1069]

Priority score at execution time

### description / queue_id #3  [metadata_id: 1058]

Original queue entry (NULL if manually triggered)

### description / rebuild_mode #16  [metadata_id: 1071]

Execution mode used: ONLINE or OFFLINE

### description / registry_id #4  [metadata_id: 1059]

FK to Index_Registry.registry_id

### description / run_id #2  [metadata_id: 1057]

Groups entries from the same execution cycle

### description / schema_name #8  [metadata_id: 1063]

Schema containing the table

### description / server_name #6  [metadata_id: 1061]

Server name from dbo.ServerRegistry

### description / started_dttm #22  [metadata_id: 1077]

When the rebuild started

### description / status #24  [metadata_id: 1079]

Current status (see Status Values)

### status_value / status #1  [metadata_id: 3007]
Title: IN_PROGRESS

Rebuild currently executing. Set at INSERT time before the ALTER INDEX command. If this status persists after the maintenance window closes, the rebuild may have timed out or the process crashed.

### status_value / status #2  [metadata_id: 3008]
Title: SUCCESS

Rebuild completed successfully. All metrics populated: duration_seconds, fragmentation_pct_after, variance_pct.

### status_value / status #3  [metadata_id: 3009]
Title: FAILED

Rebuild encountered an error. error_message contains the exception details (truncated to 4000 characters). The corresponding queue entry is set to FAILED with an incremented deferral_count.

### status_value / status #4  [metadata_id: 3010]
Title: DEFERRED

Index was evaluated but not rebuilt in this run — typically because it did not fit in the remaining maintenance window.

### status_value / status #5  [metadata_id: 3011]
Title: SKIPPED

Index was bypassed for a non-deferral reason (e.g., database skipped due to schedule).

### description / table_name #9  [metadata_id: 1064]

Table containing the index

### description / variance_pct #21  [metadata_id: 1076]

((actual - estimated) / estimated) * 100

## Index_ExecutionSummary (Table)

### category #0  [metadata_id: 1749]

Index

### data_flow #0  [metadata_id: 3015]

All four Index scripts write per-database summary rows to this table using a shared run_id per process per run. Sync-IndexRegistry.ps1 logs SYNC operations with items_processed (updated), items_added (new), and items_skipped (marked dropped). Scan-IndexFragmentation.ps1 logs SCAN operations with items_processed (scanned), items_added (queued), items_skipped (removed from queue). Execute-IndexMaintenance.ps1 logs EXECUTE operations per database with items_processed (attempted), items_added (succeeded), and items_failed. Update-IndexStatistics.ps1 logs STATS operations with items_processed (evaluated), items_added (updated), and items_failed.

### description #0  [metadata_id: 61]

Historical execution summary for Index component processes. One row per database per run captures timing, volume, and outcome for performance analysis and audit trails.

### design_note #1  [metadata_id: 3016]
Title: Per-Database Granularity

Unlike Index_Status (one row per process updated in place), ExecutionSummary keeps per-database rows per run. This enables analysis of which databases take the longest, which fail most often, and how processing distributes across the fleet. run_id groups all databases processed in a single script invocation.

### module #0  [metadata_id: 1645]

ServerOps

### query #1  [metadata_id: 3027]
Title: Recent run summary by process
Description: Shows the latest run for each process with aggregate metrics.

SELECT
    process_name,
    MAX(run_id) AS last_run_id,
    COUNT(*) AS databases_in_run,
    SUM(items_processed) AS total_processed,
    SUM(items_added) AS total_added,
    SUM(items_failed) AS total_failed,
    SUM(duration_ms) / 1000 AS total_seconds
FROM ServerOps.Index_ExecutionSummary
WHERE run_id IN (
    SELECT MAX(run_id)
    FROM ServerOps.Index_ExecutionSummary
    GROUP BY process_name
)
GROUP BY process_name
ORDER BY process_name;

### description / completed_dttm #7  [metadata_id: 533]

When processing completed (NULL if still running)

### description / database_name #5  [metadata_id: 531]

Database name processed

### description / duration_ms #8  [metadata_id: 534]

Duration in milliseconds

### description / error_message #14  [metadata_id: 540]

Error details if failed

### description / items_added #10  [metadata_id: 536]

Secondary count - meaning varies by process

### description / items_failed #12  [metadata_id: 538]

Error count - meaning varies by process

### description / items_processed #9  [metadata_id: 535]

Primary count - meaning varies by process

### description / items_skipped #11  [metadata_id: 537]

Skipped/deferred count - meaning varies by process

### description / log_id #1  [metadata_id: 527]

Unique identifier for the log entry

### description / process_name #3  [metadata_id: 529]

Process type: SYNC, SCAN, EXECUTE, STATS

### status_value / process_name #1  [metadata_id: 3017]
Title: SYNC

Sync-IndexRegistry.ps1 — daily discovery and metadata refresh of indexes across enrolled databases.

### status_value / process_name #2  [metadata_id: 3018]
Title: SCAN

Scan-IndexFragmentation.ps1 — fragmentation assessment via dm_db_index_physical_stats and queue population.

### status_value / process_name #3  [metadata_id: 3019]
Title: EXECUTE

Execute-IndexMaintenance.ps1 — index rebuild execution during maintenance windows.

### status_value / process_name #4  [metadata_id: 3020]
Title: STATS

Update-IndexStatistics.ps1 — statistics maintenance for modification-based and staleness-based updates.

### description / run_id #2  [metadata_id: 528]

Groups entries from the same execution cycle

### description / server_name #4  [metadata_id: 530]

Server name from dbo.ServerRegistry

### description / started_dttm #6  [metadata_id: 532]

When processing of this database started

### description / status #13  [metadata_id: 539]

IN_PROGRESS, SUCCESS, PARTIAL, FAILED, NO_WORK, SKIPPED

### status_value / status #1  [metadata_id: 3021]
Title: SUCCESS

All operations for this database completed without errors.

### status_value / status #2  [metadata_id: 3022]
Title: PARTIAL

Some operations succeeded but others failed. Check items_failed for the count.

### status_value / status #3  [metadata_id: 3023]
Title: FAILED

All operations for this database failed or the database was unreachable.

### status_value / status #4  [metadata_id: 3024]
Title: NO_WORK

Database was evaluated but had no qualifying work items.

### status_value / status #5  [metadata_id: 3025]
Title: SKIPPED

Database was bypassed — typically because the schedule did not allow maintenance during the current hour.

### status_value / status #6  [metadata_id: 3026]
Title: IN_PROGRESS

Currently being processed. Set at the start of database processing.

## Index_HolidaySchedule (Table)

### category #0  [metadata_id: 1747]

Index

### data_flow #0  [metadata_id: 2968]

Rows are created by sp_Index_AddDatabaseHolidaySchedule during enrollment (one row per database with default 9am-11pm allowed). xFACts-IndexFunctions.ps1 reads this table in Get-EffectiveSchedule on weekdays when the current date matches a dbo.Holiday entry — the two-table check (Holiday for date, HolidaySchedule for hours) determines whether the hour is allowed. Holidays trigger extended window detection via Test-IsExtendedWindow, which causes Execute-IndexMaintenance.ps1 to reset SCHEDULED indexes to PENDING.

### description #0  [metadata_id: 67]

Per-database maintenance schedules for company holidays. Each database enrolled in index maintenance has one row defining which hours allow maintenance on any holiday. Works in conjunction with dbo.Holiday which provides the calendar of holiday dates.

### design_note #1  [metadata_id: 2969]
Title: Two-Table Holiday Architecture

dbo.Holiday defines which dates are holidays (shared across the platform). This table defines per-database maintenance hours on those holidays. This separation means new holidays only need one Holiday row — all databases automatically get their existing HolidaySchedule applied. If a database has no HolidaySchedule row, the regular DatabaseSchedule is used on holidays.

### design_note #2  [metadata_id: 2970]
Title: Extended Window Trigger

Holidays qualify as extended window days alongside weekends. Execute-IndexMaintenance.ps1 checks Test-IsExtendedWindow at startup — if true, all SCHEDULED indexes (those too large for weekday windows) are reset to PENDING and eligible for processing. This is the primary mechanism for handling large indexes that accumulate during the week.

### module #0  [metadata_id: 1643]

ServerOps

### relationship_note #1  [metadata_id: 2971]
Title: dbo.Holiday

Holiday stores the calendar of recognized holidays. Get-EffectiveSchedule first checks if today matches a Holiday row (is_active = 1), and only then looks up the per-database hours in HolidaySchedule. Both tables must have matching entries for the holiday schedule to apply.

### description / created_by #27  [metadata_id: 650]

Who created this schedule

### description / created_dttm #26  [metadata_id: 649]

When this schedule was created

### description / database_id #1  [metadata_id: 624]

FK to dbo.DatabaseRegistry.database_id

### description / hr00 #2  [metadata_id: 625]

Midnight to 1am

### description / hr01 #3  [metadata_id: 626]

1am to 2am

### description / hr02 #4  [metadata_id: 627]

2am to 3am

### description / hr03 #5  [metadata_id: 628]

3am to 4am

### description / hr04 #6  [metadata_id: 629]

4am to 5am

### description / hr05 #7  [metadata_id: 630]

5am to 6am

### description / hr06 #8  [metadata_id: 631]

6am to 7am

### description / hr07 #9  [metadata_id: 632]

7am to 8am

### description / hr08 #10  [metadata_id: 633]

8am to 9am

### description / hr09 #11  [metadata_id: 634]

9am to 10am

### description / hr10 #12  [metadata_id: 635]

10am to 11am

### description / hr11 #13  [metadata_id: 636]

11am to noon

### description / hr12 #14  [metadata_id: 637]

Noon to 1pm

### description / hr13 #15  [metadata_id: 638]

1pm to 2pm

### description / hr14 #16  [metadata_id: 639]

2pm to 3pm

### description / hr15 #17  [metadata_id: 640]

3pm to 4pm

### description / hr16 #18  [metadata_id: 641]

4pm to 5pm

### description / hr17 #19  [metadata_id: 642]

5pm to 6pm

### description / hr18 #20  [metadata_id: 643]

6pm to 7pm

### description / hr19 #21  [metadata_id: 644]

7pm to 8pm

### description / hr20 #22  [metadata_id: 645]

8pm to 9pm

### description / hr21 #23  [metadata_id: 646]

9pm to 10pm

### description / hr22 #24  [metadata_id: 647]

10pm to 11pm

### description / hr23 #25  [metadata_id: 648]

11pm to midnight

### description / modified_by #29  [metadata_id: 652]

Who last modified this schedule

### description / modified_dttm #28  [metadata_id: 651]

When this schedule was last modified

## Index_Queue (Table)

### category #0  [metadata_id: 1750]

Index

### data_flow #0  [metadata_id: 2985]

Scan-IndexFragmentation.ps1 manages the queue as a living reflection of reality: inserts new entries when indexes exceed the fragmentation threshold, updates existing entries with fresh scan data, resets FAILED entries to PENDING when re-qualifying, and deletes entries that drop below threshold. Execute-IndexMaintenance.ps1 claims entries by setting status to IN_PROGRESS, deletes them after successful rebuild, or sets them to FAILED on error. At startup, Execute-IndexMaintenance.ps1 resets DEFERRED and FAILED to PENDING, and on extended windows (weekends/holidays) also resets SCHEDULED to PENDING.

### description #0  [metadata_id: 82]

Working queue of indexes awaiting maintenance, populated from Index_Registry based on fragmentation thresholds. Records are removed upon successful completion.

### design_note #1  [metadata_id: 2986]
Title: Living Queue

Unlike a static work list, the queue reflects current reality. Indexes are added when they exceed thresholds, updated when rescanned, and automatically removed if they no longer qualify (e.g., someone manually rebuilt an index). If it is in the queue, it needs work. No zombie entries.

### design_note #2  [metadata_id: 2987]
Title: Priority Scoring System

Each queue entry receives a calculated priority_score from four weighted components, all configurable via GlobalConfig: (1) Database Priority — tiered by index_maintenance_priority: priority 1 = 40 points, 2 = 25, 3 = 15; (2) Fragmentation Severity — tiered by fragmentation percentage: low = 10, medium = 15, high = 20 points; (3) Index Size — tiered by page count: small = 10, medium = 20, large = 30 points; (4) Deferral Anti-Starvation — indexes previously skipped due to time constraints get bonus points: base = 5, above threshold = 10 points. Maximum possible score is 100. The scoring ensures critical databases and large, heavily fragmented indexes are rebuilt first, while the deferral component prevents any index from being perpetually skipped.

### design_note #3  [metadata_id: 2988]
Title: Best-Fit vs Priority Ordering

Execute-IndexMaintenance.ps1 uses different selection strategies based on window type. On weekdays: best-fit algorithm — iterates through the queue by priority, selecting indexes whose estimated duration fits in the remaining window, skipping larger ones to try smaller ones (maximizes throughput). On extended windows (weekends/holidays): straight priority order — processes all indexes including SCHEDULED ones that were too large for weekday windows.

### design_note #4  [metadata_id: 2989]
Title: SCHEDULED Status for Oversized Indexes

When the best-fit algorithm encounters an index whose estimated duration exceeds the largest contiguous weekday window (calculated by Get-MaxWeekdayWindow), it marks it SCHEDULED rather than repeatedly deferring it. SCHEDULED indexes are only reset to PENDING on extended window days (weekends/holidays), which is the designed mechanism for handling large indexes that accumulate during the work week.

### module #0  [metadata_id: 1646]

ServerOps

### query #1  [metadata_id: 2997]
Title: Queue depth by status
Description: At-a-glance summary showing queue size, total pages, and estimated duration per status.

SELECT
    status,
    COUNT(*) AS index_count,
    SUM(page_count) AS total_pages,
    SUM(estimated_seconds_offline) / 60 AS est_minutes_offline,
    SUM(estimated_seconds_online) / 60 AS est_minutes_online
FROM ServerOps.Index_Queue
GROUP BY status;

### query #2  [metadata_id: 2998]
Title: Queue by database
Description: Breakdown showing how work is distributed across databases with deferral information.

SELECT
    dr.database_name,
    q.status,
    COUNT(*) AS index_count,
    SUM(q.page_count) AS total_pages,
    MAX(q.deferral_count) AS max_deferrals
FROM ServerOps.Index_Queue q
JOIN dbo.DatabaseRegistry dr ON q.database_id = dr.database_id
GROUP BY dr.database_name, q.status
ORDER BY dr.database_name, q.status;

### query #3  [metadata_id: 2999]
Title: Most deferred indexes
Description: Indexes repeatedly skipped due to time constraints — high deferral counts may indicate indexes that need SCHEDULED treatment or extended window attention.

SELECT
    dr.database_name,
    q.schema_name,
    q.table_name,
    q.index_name,
    q.status,
    q.deferral_count,
    q.page_count,
    q.priority_score,
    q.estimated_seconds_online / 60 AS est_min_online
FROM ServerOps.Index_Queue q
JOIN dbo.DatabaseRegistry dr ON q.database_id = dr.database_id
WHERE q.deferral_count > 0
ORDER BY q.deferral_count DESC, q.priority_score DESC;

### query #4  [metadata_id: 3000]
Title: SCHEDULED indexes awaiting extended window
Description: Indexes too large for weekday maintenance windows that will be processed on the next weekend or holiday.

SELECT
    dr.database_name,
    q.index_name,
    q.page_count,
    q.estimated_seconds_online / 60.0 AS est_minutes_online,
    q.deferral_count,
    q.queued_dttm
FROM ServerOps.Index_Queue q
JOIN dbo.DatabaseRegistry dr ON q.database_id = dr.database_id
WHERE q.status = 'SCHEDULED'
ORDER BY q.deferral_count DESC, q.page_count DESC;

### relationship_note #1  [metadata_id: 3001]
Title: Index_Registry

Each queue entry references a registry_id. The registry provides the scan data that determines whether an index qualifies for queuing, and receives updates (last_rebuild_dttm, lifetime_rebuild_count) after successful rebuilds. Queue entries are deleted on successful rebuild; registry entries persist for history.

### relationship_note #2  [metadata_id: 3002]
Title: Index_ExecutionLog

When Execute-IndexMaintenance.ps1 begins processing a queue entry, it inserts an IN_PROGRESS row into ExecutionLog with the queue_id and registry_id. On completion, the ExecutionLog row is updated with duration, fragmentation before/after, and variance. The queue entry is then deleted (success) or set to FAILED.

### description / database_id #3  [metadata_id: 865]

FK to dbo.DatabaseRegistry.database_id (for quick filtering)

### description / deferral_count #14  [metadata_id: 876]

Number of times this index has been skipped or failed

### description / estimated_seconds_offline #10  [metadata_id: 872]

Estimated rebuild duration using OFFLINE factor

### description / estimated_seconds_online #9  [metadata_id: 871]

Estimated rebuild duration using ONLINE factor

### description / fragmentation_pct #7  [metadata_id: 869]

Fragmentation when queued

### description / index_name #6  [metadata_id: 868]

Name of the index

### description / last_evaluated_dttm #17  [metadata_id: 879]

When the entry was last considered for execution

### description / online_option #12  [metadata_id: 874]

Planned mode: ONLINE=ON (1) or ONLINE=OFF (0)

### description / operation_type #11  [metadata_id: 873]

REBUILD or REORGANIZE

### status_value / operation_type #1  [metadata_id: 2995]
Title: REBUILD

Full index rebuild (ALTER INDEX ... REBUILD). This is the standard operation for all queued indexes.

### status_value / operation_type #2  [metadata_id: 2996]
Title: REORGANIZE

Index reorganization (ALTER INDEX ... REORGANIZE). Reserved for future use — currently all operations are REBUILD.

### description / page_count #8  [metadata_id: 870]

Page count when queued

### description / priority_score #15  [metadata_id: 877]

Calculated priority for execution ordering (higher = more urgent)

### description / queue_id #1  [metadata_id: 863]

Unique identifier for the queue entry

### description / queued_dttm #16  [metadata_id: 878]

When the entry was added to the queue

### description / registry_id #2  [metadata_id: 864]

FK to Index_Registry.registry_id

### description / schema_name #4  [metadata_id: 866]

Schema containing the table

### description / status #13  [metadata_id: 875]

Current status: PENDING, IN_PROGRESS, DEFERRED, SCHEDULED, or FAILED

### status_value / status #1  [metadata_id: 2990]
Title: PENDING

Awaiting processing. Set when an index is first added to the queue by Scan-IndexFragmentation.ps1, or reset from DEFERRED/FAILED at the start of each Execute-IndexMaintenance.ps1 run.

### status_value / status #2  [metadata_id: 2991]
Title: IN_PROGRESS

Currently being rebuilt. Set by Execute-IndexMaintenance.ps1 immediately before issuing the ALTER INDEX command. Scan-IndexFragmentation.ps1 skips IN_PROGRESS entries to avoid interfering with active rebuilds.

### status_value / status #3  [metadata_id: 2992]
Title: DEFERRED

Skipped in the current run because it did not fit in the remaining window. Reset to PENDING at the start of the next Execute-IndexMaintenance.ps1 run. The deferral_count is incremented to boost priority scoring on subsequent runs.

### status_value / status #4  [metadata_id: 2993]
Title: SCHEDULED

Too large for any weekday maintenance window. Identified by comparing estimated duration against Get-MaxWeekdayWindow. Only reset to PENDING on extended window days (weekends/holidays). If a SCHEDULED index still does not fit even in an extended window, its deferral_count is incremented.

### status_value / status #5  [metadata_id: 2994]
Title: FAILED

Rebuild attempt failed. The error is logged to Index_ExecutionLog. deferral_count is incremented. Reset to PENDING at the start of the next Execute-IndexMaintenance.ps1 run. If the index re-qualifies on the next scan, Scan-IndexFragmentation.ps1 also resets FAILED to PENDING.

### description / table_name #5  [metadata_id: 867]

Table containing the index

## Index_Registry (Table)

### category #0  [metadata_id: 1751]

Index

### data_flow #0  [metadata_id: 2972]

Sync-IndexRegistry.ps1 performs the daily "cheap pass" — queries sys.indexes, sys.dm_db_partition_stats, and sys.dm_db_index_usage_stats on each enrolled database, inserts new indexes, updates metadata (page count, fill factor, usage stats) for existing indexes, and marks missing indexes as is_dropped = 1. Scan-IndexFragmentation.ps1 reads scan candidates (not dropped, not excluded, above minimum page count, not recently scanned or rebuilt), then updates current_fragmentation_pct and last_scanned_dttm after scanning each index via sys.dm_db_index_physical_stats. Execute-IndexMaintenance.ps1 updates last_rebuild_dttm, last_rebuild_duration_seconds, lifetime_rebuild_count, and current_fragmentation_pct after successful rebuilds. Update-IndexStatistics.ps1 updates stats_last_updated after updating statistics.

### description #0  [metadata_id: 135]

Persistent catalog of all indexes in enrolled databases, storing last-known fragmentation statistics, rebuild history, and metadata to enable efficient incremental scanning without expensive full catalog queries.

### design_note #1  [metadata_id: 2973]
Title: Central Catalog — Single Source of Truth

All Index component scripts operate through the registry. An index must exist in the registry before it can be scanned, queued, rebuilt, or have its statistics updated. This prevents orphaned queue entries and enables comprehensive lifecycle tracking (discovery ? scanning ? rebuild ? statistics) for every index.

### design_note #2  [metadata_id: 2974]
Title: Soft-Delete for Dropped Indexes

When Sync-IndexRegistry.ps1 finds an index in the registry that no longer exists in the source database, it sets is_dropped = 1 and dropped_detected_dttm rather than deleting the row. This preserves the lifetime_rebuild_count and rebuild history for analysis. Dropped indexes are excluded from scanning and queue population.

### design_note #3  [metadata_id: 2975]
Title: Exclusion Mechanism

is_excluded = 1 with an optional exclusion_reason removes an index from scanning and queue population without affecting sync. This handles vendor-managed indexes, known problematic indexes, or indexes under temporary investigation. Unlike is_dropped, excluded indexes are still tracked and updated by sync.

### design_note #4  [metadata_id: 2976]
Title: Usage Statistics Capture

user_seeks, user_scans, user_lookups, user_updates, and the last_user_seek/last_user_scan timestamps are captured from sys.dm_db_index_usage_stats during sync. These are cumulative since the last service restart (tracked via usage_captured_dttm). The data supports identifying unused indexes — zero seeks and zero scans since service start suggests the index may be a deletion candidate.

### design_note #5  [metadata_id: 2977]
Title: Average Daily Fragmentation Rate

avg_daily_fragmentation_rate captures how quickly an index fragments between rebuilds. This enables predictive scheduling — indexes that fragment rapidly can be prioritized, while slow-fragmenting indexes can be scanned less frequently. Currently populated by Scan-IndexFragmentation.ps1 based on observed fragmentation growth between scans.

### module #0  [metadata_id: 1647]

ServerOps

### query #1  [metadata_id: 2978]
Title: Registry summary by database
Description: Overview showing total indexes, dropped count, unscanned count, and indexes above the fragmentation threshold per database.

SELECT
    dr.database_name,
    COUNT(*) AS total_indexes,
    SUM(CASE WHEN ir.is_dropped = 1 THEN 1 ELSE 0 END) AS dropped,
    SUM(CASE WHEN ir.current_fragmentation_pct IS NULL AND ir.is_dropped = 0 THEN 1 ELSE 0 END) AS never_scanned,
    SUM(CASE WHEN ir.current_fragmentation_pct >= 15 AND ir.is_dropped = 0 THEN 1 ELSE 0 END) AS above_threshold,
    MAX(ir.last_scanned_dttm) AS last_scan_activity
FROM ServerOps.Index_Registry ir
JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
GROUP BY dr.database_name
ORDER BY dr.database_name;

### query #2  [metadata_id: 2979]
Title: Most frequently rebuilt indexes
Description: Top 20 indexes by lifetime rebuild count — high-churn indexes that may benefit from fill factor adjustment or schema review.

SELECT TOP 20
    dr.database_name,
    ir.schema_name,
    ir.table_name,
    ir.index_name,
    ir.lifetime_rebuild_count,
    ir.last_rebuild_dttm,
    ir.current_page_count,
    ir.current_fragmentation_pct
FROM ServerOps.Index_Registry ir
JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
WHERE ir.is_dropped = 0
  AND ir.lifetime_rebuild_count > 0
ORDER BY ir.lifetime_rebuild_count DESC;

### query #3  [metadata_id: 2980]
Title: Potentially unused indexes
Description: Indexes with zero seeks and zero scans since service start — candidates for review and possible removal.

SELECT
    dr.database_name,
    ir.schema_name,
    ir.table_name,
    ir.index_name,
    ir.index_type,
    ir.current_page_count,
    ir.user_updates,
    ir.usage_captured_dttm
FROM ServerOps.Index_Registry ir
JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
WHERE ir.is_dropped = 0
  AND ir.usage_captured_dttm IS NOT NULL
  AND COALESCE(ir.user_seeks, 0) = 0
  AND COALESCE(ir.user_scans, 0) = 0
  AND ir.current_page_count >= 1000
ORDER BY ir.current_page_count DESC;

### query #4  [metadata_id: 2981]
Title: Exclude an index from maintenance
Description: Marks an index as excluded with a reason. Excluded indexes are still tracked by sync but skipped by scanning and queue population.

UPDATE ServerOps.Index_Registry
SET is_excluded = 1,
    exclusion_reason = 'Vendor-managed index - do not modify',
    modified_dttm = GETDATE()
WHERE database_id = @DatabaseID
  AND schema_name = 'dbo'
  AND table_name = 'TargetTable'
  AND index_name = 'IX_VendorManaged';

### query #5  [metadata_id: 2982]
Title: Recently dropped indexes
Description: Indexes detected as dropped in the last 30 days — useful for reviewing schema changes.

SELECT
    dr.database_name,
    ir.schema_name,
    ir.table_name,
    ir.index_name,
    ir.dropped_detected_dttm,
    ir.lifetime_rebuild_count
FROM ServerOps.Index_Registry ir
JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
WHERE ir.is_dropped = 1
  AND ir.dropped_detected_dttm >= DATEADD(DAY, -30, GETDATE())
ORDER BY ir.dropped_detected_dttm DESC;

### relationship_note #1  [metadata_id: 2983]
Title: Index_Queue

Queue entries reference registry_id as a foreign key. An index must exist in the registry before it can be queued. When an index is rebuilt successfully, the queue entry is deleted and the registry is updated with post-rebuild fragmentation and timing. When a registry entry is marked as dropped, any corresponding queue entry should be removed.

### relationship_note #2  [metadata_id: 2984]
Title: Index_ExecutionLog

ExecutionLog entries reference registry_id for per-index rebuild history. This links each rebuild operation back to the registry entry, enabling analysis of rebuild frequency, duration trends, and estimate accuracy over time for specific indexes.

### description / avg_daily_fragmentation_rate #25  [metadata_id: 1531]

Reserved for future trend analysis

### description / created_dttm #30  [metadata_id: 1536]

When the registry entry was created

### description / current_fill_factor #12  [metadata_id: 1518]

Current fill factor setting (0 = 100%)

### description / current_fragmentation_pct #11  [metadata_id: 1517]

Last-known fragmentation from sys.dm_db_index_physical_stats

### description / current_page_count #10  [metadata_id: 1516]

Last-known page count from sys.dm_db_partition_stats

### description / database_id #2  [metadata_id: 1508]

FK to dbo.DatabaseRegistry.database_id

### description / dropped_detected_dttm #29  [metadata_id: 1535]

When the drop was detected

### description / exclusion_reason #27  [metadata_id: 1533]

Why the index is excluded

### description / index_id #6  [metadata_id: 1512]

SQL Server index_id from sys.indexes

### description / index_name #5  [metadata_id: 1511]

Name of the index

### description / index_type #7  [metadata_id: 1513]

CLUSTERED, NONCLUSTERED, or COLUMNSTORE variant

### description / is_dropped #28  [metadata_id: 1534]

Whether index no longer exists in source database

### description / is_excluded #26  [metadata_id: 1532]

Whether index is excluded from maintenance

### description / is_primary_key #8  [metadata_id: 1514]

Whether this index backs a primary key constraint

### description / is_unique #9  [metadata_id: 1515]

Whether this is a unique index

### description / last_rebuild_dttm #14  [metadata_id: 1520]

When index was last rebuilt by this system

### description / last_rebuild_duration_seconds #15  [metadata_id: 1521]

How long the last rebuild took

### description / last_scanned_dttm #13  [metadata_id: 1519]

When fragmentation was last scanned

### description / last_user_scan #23  [metadata_id: 1529]

Timestamp of last user scan operation

### description / last_user_seek #22  [metadata_id: 1528]

Timestamp of last user seek operation

### description / lifetime_rebuild_count #16  [metadata_id: 1522]

Total number of rebuilds performed by this system

### description / modified_dttm #31  [metadata_id: 1537]

When the entry was last modified

### description / registry_id #1  [metadata_id: 1507]

Unique identifier for the registry entry

### description / schema_name #3  [metadata_id: 1509]

Schema containing the table

### description / stats_last_updated #17  [metadata_id: 1523]

When UPDATE STATISTICS was last run on this index

### description / table_name #4  [metadata_id: 1510]

Table containing the index

### description / usage_captured_dttm #24  [metadata_id: 1530]

When usage statistics were last captured

### description / user_lookups #20  [metadata_id: 1526]

Cumulative user lookups since last service restart

### description / user_scans #19  [metadata_id: 1525]

Cumulative user scans since last service restart

### description / user_seeks #18  [metadata_id: 1524]

Cumulative user seeks since last service restart

### description / user_updates #21  [metadata_id: 1527]

Cumulative user updates since last service restart

## Index_StatsExecutionLog (Table)

### category #0  [metadata_id: 1752]

Index

### data_flow #0  [metadata_id: 3028]

Update-IndexStatistics.ps1 writes two types of entries. MODIFICATION entries are logged individually per statistic when the modification counter exceeds the configured threshold (default 10% of rows modified) — each row captures the specific statistic name, row count, modification counter, and percentage modified. STALENESS entries are logged as one cumulative row per database when statistics exceed the age threshold (default 30 days) — the row captures stats_count, min_days_stale, and max_days_stale rather than individual statistic details.

### description #0  [metadata_id: 48]

Per-statistic execution detail for statistics maintenance operations. Supports individual tracking for modification-based updates and cumulative logging for staleness-based updates.

### design_note #1  [metadata_id: 3029]
Title: Dual Logging Strategy

MODIFICATION updates are logged individually because they represent meaningful data changes worth investigating — which tables are changing rapidly, how much, and how often. STALENESS updates are logged as one cumulative row per database because they represent routine freshness maintenance — logging hundreds of individual "it was old, now it is not" entries would flood the table with low-value data.

### design_note #2  [metadata_id: 3030]
Title: Targeted vs Blanket Statistics Updates

Traditional maintenance updates all statistics weekly regardless of need. This approach evaluates each statistic individually: modification threshold catches actively changing data, staleness threshold catches distribution drift. In practice, only ~2% of statistics need updating on any given run, completing in seconds instead of minutes.

### module #0  [metadata_id: 1648]

ServerOps

### query #1  [metadata_id: 3033]
Title: Most frequently modified statistics
Description: Statistics that are updated most often due to high modification rates — indicates actively changing tables.

SELECT
    database_name,
    schema_name,
    table_name,
    stat_name,
    COUNT(*) AS update_count,
    AVG(pct_modified) AS avg_pct_modified,
    MAX(rows_at_update) AS max_rows
FROM ServerOps.Index_StatsExecutionLog
WHERE update_type = 'MODIFICATION'
  AND started_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY database_name, schema_name, table_name, stat_name
HAVING COUNT(*) >= 3
ORDER BY update_count DESC;

### description / completed_dttm #20  [metadata_id: 328]

When the update completed

### description / database_id #3  [metadata_id: 311]

FK to dbo.DatabaseRegistry.database_id

### description / database_name #7  [metadata_id: 315]

Database name

### description / days_since_update #14  [metadata_id: 322]

Days since stat was last updated

### description / detail_id #1  [metadata_id: 309]

Unique identifier for the detail entry

### description / duration_ms #21  [metadata_id: 329]

Duration in milliseconds

### description / error_message #23  [metadata_id: 331]

Error details if failed

### description / max_days_stale #17  [metadata_id: 325]

Age of oldest stat in batch

### description / min_days_stale #16  [metadata_id: 324]

Age of youngest stat in batch

### description / modification_counter #12  [metadata_id: 320]

Rows modified since last update (from sys.dm_db_stats_properties)

### description / pct_modified #13  [metadata_id: 321]

(modification_counter / rows) * 100

### description / registry_id #4  [metadata_id: 312]

FK to Index_Registry (NULL for STALENESS)

### description / rows_at_update #11  [metadata_id: 319]

Table row count when updated

### description / run_id #2  [metadata_id: 310]

Groups entries from the same execution cycle

### description / sample_pct_used #18  [metadata_id: 326]

0 = FULLSCAN, 1-100 = SAMPLE n PERCENT

### description / schema_name #8  [metadata_id: 316]

Schema containing the table (NULL for STALENESS)

### description / server_name #6  [metadata_id: 314]

Server name (NULL for STALENESS)

### description / started_dttm #19  [metadata_id: 327]

When the update started

### description / stat_name #10  [metadata_id: 318]

Name of the statistic/index (NULL for STALENESS)

### description / stats_count #15  [metadata_id: 323]

Number of statistics updated in batch

### description / status #22  [metadata_id: 330]

Current status (see Status Values)

### description / table_name #9  [metadata_id: 317]

Table containing the statistic (NULL for STALENESS)

### description / update_type #5  [metadata_id: 313]

'MODIFICATION' or 'STALENESS'

### status_value / update_type #1  [metadata_id: 3031]
Title: MODIFICATION

Statistic updated because modification_counter exceeded the configured threshold (default 10% of rows). Logged individually with full details: schema, table, stat name, row count, modification counter, percentage modified.

### status_value / update_type #2  [metadata_id: 3032]
Title: STALENESS

Statistics updated because they exceeded the age threshold (default 30 days since last update) regardless of modification count. Logged as one cumulative row per database with stats_count, min_days_stale, and max_days_stale.

## Index_Status (Table)

### category #0  [metadata_id: 1753]

Index

### data_flow #0  [metadata_id: 3034]

Rows are pre-seeded — one per process (SYNC, SCAN, EXECUTE, STATS). Each script updates its row using a two-phase pattern: at start, sets started_dttm and clears metrics; at completion, populates completed_dttm, last_status, last_duration_seconds, and item counts. Rows are updated in place, never inserted or appended.

### description #0  [metadata_id: 53]

Dashboard table providing at-a-glance status for all Index component processes. One row per process (SYNC, SCAN, EXECUTE, STATS) tracks last run timing, outcome, and metrics.

### design_note #1  [metadata_id: 3035]
Title: One Row Per Process — Update in Place

Identical pattern to Backup_Status. Exactly four pre-seeded rows, updated in place after each run. Provides an instant dashboard answer to "when did each process last run and what was the result" without querying detailed logs.

### design_note #2  [metadata_id: 3036]
Title: Real-Time Counter Updates During Execution

Execute-IndexMaintenance.ps1 increments items_added (successes) and items_failed in real time after each index rebuild, before the overall run completes. This means the Status row reflects live progress during long execution runs, not just the final summary.

### module #0  [metadata_id: 1649]

ServerOps

### query #1  [metadata_id: 3046]
Title: Quick status check
Description: At-a-glance dashboard view of all Index processes showing last run timing and outcome.

SELECT
    process_name,
    last_status,
    started_dttm,
    completed_dttm,
    last_duration_seconds,
    items_processed,
    items_added,
    items_skipped,
    items_failed,
    last_error_message
FROM ServerOps.Index_Status
ORDER BY process_name;

### description / completed_dttm #3  [metadata_id: 413]

When the process completed (NULL if in progress)

### description / items_added #7  [metadata_id: 417]

Secondary count - meaning varies by process

### description / items_failed #9  [metadata_id: 419]

Error count - meaning varies by process

### description / items_processed #6  [metadata_id: 416]

Primary count - meaning varies by process

### description / items_skipped #8  [metadata_id: 418]

Skipped/deferred count - meaning varies by process

### description / last_duration_seconds #5  [metadata_id: 415]

Duration of last run in seconds

### description / last_error_message #10  [metadata_id: 420]

Error summary if last run had issues

### description / last_status #4  [metadata_id: 414]

Outcome of last run: IN_PROGRESS, SUCCESS, PARTIAL, FAILED, NO_WORK

### status_value / last_status #1  [metadata_id: 3041]
Title: IN_PROGRESS

Process is currently running. Set at script start; completed_dttm is NULL.

### status_value / last_status #2  [metadata_id: 3042]
Title: SUCCESS

Process completed all work without errors.

### status_value / last_status #3  [metadata_id: 3043]
Title: PARTIAL

Process completed but some databases or operations had errors. Check items_failed for count.

### status_value / last_status #4  [metadata_id: 3044]
Title: FAILED

Process encountered critical errors across all databases.

### status_value / last_status #5  [metadata_id: 3045]
Title: NO_WORK

Process ran but found no qualifying work. No databases matched the filter criteria or had eligible items.

### description / process_name #1  [metadata_id: 411]

Process identifier: SYNC, SCAN, EXECUTE, STATS

### status_value / process_name #1  [metadata_id: 3037]
Title: SYNC

Sync-IndexRegistry.ps1 — daily discovery and metadata refresh.

### status_value / process_name #2  [metadata_id: 3038]
Title: SCAN

Scan-IndexFragmentation.ps1 — fragmentation scanning and queue population.

### status_value / process_name #3  [metadata_id: 3039]
Title: EXECUTE

Execute-IndexMaintenance.ps1 — index rebuild execution.

### status_value / process_name #4  [metadata_id: 3040]
Title: STATS

Update-IndexStatistics.ps1 — statistics maintenance.

### description / started_dttm #2  [metadata_id: 412]

When the process started (set at beginning of run)

## Process-BackupAWSUpload.ps1 (Script)

### category #0  [metadata_id: 2932]

Backup

### data_flow #0  [metadata_id: 2933]

Reads aws_bucket_name and aws_path_prefix from dbo.GlobalConfig. Verifies AWS CLI accessibility. Queries Backup_FileTracking for PENDING AWS upload records, joining through DatabaseRegistry, ServerRegistry (serverops_backup_enabled = 1), and Backup_DatabaseConfig (backup_aws_upload_enabled = 1). Claims files via atomic batch UPDATE to IN_PROGRESS. For each file: converts local path to UNC (with AG Listener path resolution), uploads to S3 via AWS CLI with Glacier storage class, and sets status to COMPLETED or FAILED with aws_path and timing. Logs per-file operations to Backup_ExecutionLog. Updates Backup_Status (AWS_UPLOAD process). Reports to Orchestrator v2 via callback.

### description #0  [metadata_id: 2930]

Uploads completed backup files to AWS S3 Glacier Flexible Retrieval storage. Reads from source servers via UNC admin shares (not from the network copy destination), enabling true parallel execution with Process-BackupNetworkCopy.ps1. Uses AWS CLI for uploads with explicit credential paths. Runs as a FIRE_AND_FORGET process under Orchestrator v2.

### design_note #1  [metadata_id: 2934]
Title: Parallel Execution via Source Path Independence

Reads backup files from source servers via UNC admin shares — the same source as Process-BackupNetworkCopy.ps1. Neither script depends on the other's output. Both can process the same file simultaneously: one copying to the network share, the other uploading to S3. This eliminates a serial bottleneck and provides fault isolation between the two distribution paths.

### design_note #2  [metadata_id: 2935]
Title: Glacier Flexible Retrieval Storage Class

All uploads use S3 Glacier Flexible Retrieval, hardcoded in the Invoke-S3Upload function. This provides the lowest-cost archival storage appropriate for disaster recovery backups that are rarely accessed. Retrieval takes several hours, making network copy the primary path for operational restores.

### design_note #3  [metadata_id: 3381]
Title: Automatic Retry with Exhaustion Alerting

Before querying for PENDING files, the script checks for FAILED uploads where aws_upload_retry_count is below the configurable maximum (GlobalConfig aws_upload_max_retries, default 2). Eligible files are reset to PENDING with an incremented retry count, then picked up by the normal processing loop. Files that exhaust all retries remain FAILED and a Teams alert is fired via the shared Send-TeamsAlert function with trigger type BACKUP_AWS_UPLOAD_EXHAUSTED and the tracking_id as trigger value. Dedup in Teams.RequestLog prevents repeat alerts for the same file.

### module #0  [metadata_id: 2931]

ServerOps

## Process-BackupNetworkCopy.ps1 (Script)

### category #0  [metadata_id: 2927]

Backup

### data_flow #0  [metadata_id: 2928]

Reads network_backup_root from dbo.GlobalConfig. Queries Backup_FileTracking for PENDING network copy records, joining through DatabaseRegistry, ServerRegistry (serverops_backup_enabled = 1), and Backup_DatabaseConfig (backup_network_copy_enabled = 1). Claims files via atomic batch UPDATE to IN_PROGRESS. For each file: converts local path to UNC using source server name (with AG Listener path resolution via filename parsing), copies to network share, and sets status to COMPLETED or FAILED with network_path and timing. Logs per-file operations to Backup_ExecutionLog. Updates Backup_Status (NETWORK_COPY process). Reports to Orchestrator v2 via callback.

### description #0  [metadata_id: 2925]

Copies completed backup files from source servers to the centralized network share on FA-SQLDBB. Reads from source servers via UNC admin shares, creates a standardized folder hierarchy (server/database/type), and updates Backup_FileTracking pipeline status. Runs as a FIRE_AND_FORGET process under Orchestrator v2.

### design_note #1  [metadata_id: 2929]
Title: Fire-and-Forget Execution

Runs as FIRE_AND_FORGET under Orchestrator v2. The orchestrator does not hold for completion, preventing large file copies from blocking subsequent orchestrator cycles. Multiple runs catch up naturally if backups accumulate. MaxFiles parameter (default 100) caps per-run processing.

### design_note #2  [metadata_id: 3380]
Title: Automatic Retry with Exhaustion Alerting

Before querying for PENDING files, the script checks for FAILED copies where network_copy_retry_count is below the configurable maximum (GlobalConfig network_copy_max_retries, default 2). Eligible files are reset to PENDING with an incremented retry count, then picked up by the normal processing loop. Files that exhaust all retries remain FAILED and a Teams alert is fired via the shared Send-TeamsAlert function with trigger type BACKUP_NETWORK_COPY_EXHAUSTED and the tracking_id as trigger value. Dedup in Teams.RequestLog prevents repeat alerts for the same file.

### module #0  [metadata_id: 2926]

ServerOps

## Process-BackupRetention.ps1 (Script)

### category #0  [metadata_id: 2938]

Backup

### data_flow #0  [metadata_id: 2939]

Reads dbo.ServerRegistry for master switch check. Queries Backup_FileTracking with a CTE that ranks FULL backups per database and joins Backup_DatabaseConfig for chain counts to calculate per-database cutoff timestamps. Processes local deletes first (requiring network_copy_status IN COMPLETED or HISTORICAL as a safety check), then network deletes. For each file: builds UNC path (with AG Listener resolution and legacy (local) filename fallback), deletes the file or marks complete if already gone externally, and updates local_deleted_dttm or network_deleted_dttm. Logs per-file operations to Backup_ExecutionLog (excluding HISTORICAL records). Uses COALESCE(compressed_size_bytes, file_size_bytes) for accurate space reporting. Updates Backup_Status (RETENTION process). Reports to Orchestrator v2 via callback.

### description #0  [metadata_id: 2936]

Deletes backup files past their retention period from local source servers and the centralized network share. Uses chain-based retention logic: keeps N full backup chains per database as configured in Backup_DatabaseConfig, deleting all files (FULL, DIFF, LOG) older than the Nth oldest FULL. Runs daily as a FIRE_AND_FORGET process under Orchestrator v2.

### design_note #1  [metadata_id: 2940]
Title: Chain-Based Cutoff Calculation

Uses a CTE with ROW_NUMBER() OVER (PARTITION BY server_name, database_name ORDER BY backup_finish_dttm DESC) to rank FULL backups still on each storage tier. The Nth ranked FULL's backup_finish_dttm becomes the cutoff — all files older than this are eligible for deletion. This ensures complete backup chains are always available and prevents orphaned DIFFs or LOGs.

### design_note #2  [metadata_id: 2941]
Title: Local Delete Safety Check

Local files are only deleted when network_copy_status is COMPLETED or HISTORICAL. This ensures a file has been safely copied to the network share before being removed from the source server. The check prevents data loss if the network copy pipeline is stalled.

### design_note #3  [metadata_id: 2942]
Title: Graceful Handling of Externally Deleted Files

When a file targeted for deletion no longer exists on disk, the script marks it complete with a note ("Retention marked complete - file already deleted externally") rather than logging an error. This handles files cleaned up by Redgate, manual intervention, or disk maintenance without generating false failure alerts.

### module #0  [metadata_id: 2937]

ServerOps

## Replication_AgentHistory (Table)

### category #0  [metadata_id: 1754]

Replication

### data_flow #0  [metadata_id: 2778]

Append-only. Populated by Collect-ReplicationHealth.ps1 every 60 seconds. For each active registry entry, the collector queries MSdistribution_history (or MSlogreader_history for Log Reader agents) for the latest health/throughput snapshot, and calls sp_replmonitorsubscriptionpendingcmds for queue depth. One row inserted per agent per cycle. Also read internally by the collector for event detection — the previous cycle's snapshot is compared to the current state to detect state changes. Read by the Control Center Replication page for dashboards and trending.

### description #0  [metadata_id: 103]

Append-only periodic snapshots combining agent health status, queue depth, and throughput metrics for each monitored replication agent per collection cycle.

### design_note #1  [metadata_id: 2779]
Title: Combined Snapshot Design

Agent health, queue depth, and throughput are collected in the same cycle and stored in the same row. This avoids join overhead for dashboard queries and ensures metrics are always time-aligned. One metric alone can mislead — an agent can report Running while 500,000 commands pile up. Three dimensions together tell the truth.

### design_note #2  [metadata_id: 2780]
Title: Queue Depth via System Procedure

Queue depth comes from sp_replmonitorsubscriptionpendingcmds rather than aggregating MSdistribution_status directly. The system procedure returns instantly while the direct table join takes 90+ seconds on large distribution databases.

### design_note #3  [metadata_id: 2781]
Title: NULL Queue Depth for Log Reader

The Log Reader Agent reads the publisher transaction log and writes to the distribution database. Pending command count is a Distribution Agent concept, so queue depth columns are NULL for LogReader entries. This is by design, not missing data.

### design_note #4  [metadata_id: 2782]
Title: BIGINT Identity for Volume

At one row per agent per 60-second cycle with 4 agents, this table accumulates approximately 5,760 rows per day (~172,800 per 30-day retention window). BIGINT identity accommodates long-term growth.

### module #0  [metadata_id: 1650]

ServerOps

### query #1  [metadata_id: 2789]
Title: Current Status All Agents
Description: Latest snapshot per agent showing health, queue depth, and throughput.

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

### query #2  [metadata_id: 2790]
Title: Queue Depth Trend (24 Hours)
Description: Distribution agent queue depth and delivery rate over the last 24 hours for trending.

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

### query #3  [metadata_id: 2791]
Title: Throughput Averages by Publication (7 Days)
Description: Average, max, and min delivery rates per publication over the last 7 days. Filters to Running/Idle states only.

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

### query #4  [metadata_id: 2792]
Title: Agents Currently Down
Description: Any agents reporting Failed or Stopped status in the most recent collection cycle.

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

### relationship_note #1  [metadata_id: 2793]
Title: Replication_PublicationRegistry

FK to registry. Each snapshot row references a registry entry to identify which agent it describes. The registry provides stable identification while the distribution database agent_ids may change.

### relationship_note #2  [metadata_id: 2794]
Title: Replication_EventLog

The collector uses the previous AgentHistory snapshot to detect state changes. If the current run_status differs from the most recent snapshot, a STATE_CHANGE event (and potentially AGENT_START/AGENT_STOP) is logged to the EventLog. These two tables work as a pair: AgentHistory captures continuous state, EventLog captures transitions.

### description / agent_action_dttm #5  [metadata_id: 1197]

When the agent last reported activity in the distribution database

### description / agent_history_id #1  [metadata_id: 1193]

Unique identifier for this snapshot row

### description / agent_message #4  [metadata_id: 1196]

Agent comment at time of snapshot. Truncated from source nvarchar(max) to capture the meaningful portion

### description / average_commands #12  [metadata_id: 1204]

Average commands per transaction. Source: MSdistribution_history.average_commands

### description / collected_dttm #14  [metadata_id: 1206]

When this snapshot was captured by the collector

### description / delivered_commands #11  [metadata_id: 1203]

Cumulative commands delivered by this agent. Source: MSdistribution_history.delivered_commands

### description / delivered_transactions #10  [metadata_id: 1202]

Cumulative transactions delivered by this agent. Source: MSdistribution_history.delivered_transactions

### description / delivery_latency #13  [metadata_id: 1205]

Delivery latency reported by the agent. Source: MSdistribution_history.delivery_latency

### description / delivery_rate #9  [metadata_id: 1201]

Commands delivered per second. Source: MSdistribution_history.delivery_rate / MSlogreader_history.delivery_rate

### description / error_id #6  [metadata_id: 1198]

Reference to MSrepl_errors in the distribution database. Zero or NULL indicates no error

### description / estimated_processing_seconds #8  [metadata_id: 1200]

SQL Server's estimate of seconds needed to clear the pending queue. NULL for Log Reader entries. Source: sp_replmonitorsubscriptionpendingcmds

### description / pending_command_count #7  [metadata_id: 1199]

Number of commands waiting in the distribution database for delivery. NULL for Log Reader entries. Source: sp_replmonitorsubscriptionpendingcmds

### description / publication_registry_id #2  [metadata_id: 1194]

FK to Replication_PublicationRegistry. Identifies which agent this snapshot is for

### description / run_status #3  [metadata_id: 1195]

Agent run status code: 1=Started, 2=Running, 3=Idle, 4=Retrying, 5=Failed, 6=Stopped

### status_value / run_status #1  [metadata_id: 2783]
Title: 1 (Started)

Agent is initializing.

### status_value / run_status #2  [metadata_id: 2784]
Title: 2 (Running)

Agent is actively processing. Note: SQL Server sometimes reports run_status = 2 with a "successfully stopped" message when an agent is stopped externally. The collector detects this pattern.

### status_value / run_status #3  [metadata_id: 2785]
Title: 3 (Idle)

Agent is running but has no work to do.

### status_value / run_status #4  [metadata_id: 2786]
Title: 4 (Retrying)

Agent encountered an error and is retrying.

### status_value / run_status #5  [metadata_id: 2787]
Title: 5 (Failed)

Agent has stopped due to an error.

### status_value / run_status #6  [metadata_id: 2788]
Title: 6 (Stopped)

Agent has been stopped manually or by another process.

## Replication_EventLog (Table)

### category #0  [metadata_id: 1755]

Replication

### data_flow #0  [metadata_id: 2805]

Append-only, change-driven. Populated by Collect-ReplicationHealth.ps1 during event detection (Step 4). Each cycle, the collector compares the current run_status to the previous AgentHistory snapshot. State changes generate events. Errors detected via error_id > 0 on the current history row generate ERROR events independently of state changes. Agent stops are correlated with BIDATA.BuildExecution to tag expected events. Read by the Control Center Replication page for event timeline display.

### description #0  [metadata_id: 109]

Significant replication events including state transitions, errors, agent starts and stops, with correlation tracking to identify whether events are expected or require attention.

### design_note #1  [metadata_id: 2806]
Title: Change Detection Not Polling

Events are logged only when state changes — the collector compares current run_status to the previous AgentHistory snapshot each cycle. If nothing changed, nothing is logged. This filters out the enormous noise in SQL Server's distribution history tables (routine "delivered N transactions" messages every few seconds).

### design_note #2  [metadata_id: 2807]
Title: BIDATA Build Correlation

When an AGENT_STOP event is detected, the collector checks BIDATA.BuildExecution for an active or recently completed build. If found, correlation_source is set to 'BIDATA_BUILD', marking the stop as expected. NULL correlation_source means unexpected — these are the events that warrant investigation. Two of three Distribution agents are intentionally stopped during the nightly BIDATA build (~1 AM - 5 AM).

### design_note #3  [metadata_id: 2808]
Title: Stopped Detection Edge Case

SQL Server sometimes reports run_status = 2 (Running) with a "The process was successfully stopped" agent message when an agent is stopped externally. The collector detects this pattern by checking both the status code and the message content, and treats it as an AGENT_STOP event rather than a normal Running state.

### design_note #4  [metadata_id: 2809]
Title: Error Events Without State Change

ERROR events can be logged independently of state changes. If an agent reports error_id > 0 on the current history row but its run_status hasn't changed, the error is still captured. This catches transient errors that the agent recovers from without transitioning to a Failed state.

### module #0  [metadata_id: 1651]

ServerOps

### query #1  [metadata_id: 2818]
Title: Recent Events (24 Hours)
Description: All events in the last 24 hours with publication context and correlation status.

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

### query #2  [metadata_id: 2819]
Title: Unexpected Events (7 Days)
Description: Events with no correlation source — these are the ones that may need attention.

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

### query #3  [metadata_id: 2820]
Title: All Errors
Description: Error events with full detail including distribution database error text.

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

### query #4  [metadata_id: 2821]
Title: BIDATA Build Correlation History (30 Days)
Description: Events correlated with the nightly BIDATA build. Useful for verifying the expected stop/start pattern.

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

### query #5  [metadata_id: 2822]
Title: Event Summary by Type (30 Days)
Description: Count of events by type and correlation status for operational overview.

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

### relationship_note #1  [metadata_id: 2823]
Title: Replication_PublicationRegistry

FK to registry. Each event references a registry entry identifying which agent experienced the state change or error.

### relationship_note #2  [metadata_id: 2824]
Title: Replication_AgentHistory

No direct FK, but operationally dependent. Event detection works by comparing the current agent state to the most recent AgentHistory snapshot. Without continuous AgentHistory collection, event detection would not function.

### relationship_note #3  [metadata_id: 2825]
Title: BIDATA.BuildExecution

Cross-module dependency for correlation. When an AGENT_STOP event is detected, the collector queries BIDATA.BuildExecution for an active or recently completed build to determine if the stop was expected. This is the only cross-module reference in the Replication component.

### description / collected_dttm #13  [metadata_id: 1282]

When this event was detected and recorded by the collector

### description / correlation_source #12  [metadata_id: 1281]

Known process that correlates with this event. NULL indicates an unexpected or unidentified event

### status_value / correlation_source #7  [metadata_id: 2816]
Title: BIDATA_BUILD

Event coincides with the nightly BIDATA data warehouse build. Detected by checking BIDATA.BuildExecution for an active or recently completed build.

### status_value / correlation_source #8  [metadata_id: 2817]
Title: NULL

No known correlating process identified. This is a signal — unexpected events with NULL correlation warrant investigation.

### description / current_state #7  [metadata_id: 1276]

Current run_status code. NULL for non-state-change events

### description / current_state_desc #8  [metadata_id: 1277]

Current state description. NULL for non-state-change events

### description / error_detail #11  [metadata_id: 1280]

Error text captured from MSrepl_errors. Provides immediate context without distribution database lookup

### description / error_id #10  [metadata_id: 1279]

Reference to MSrepl_errors in the distribution database. NULL or zero if not an error event

### description / event_dttm #4  [metadata_id: 1273]

When the event occurred at the source (from distribution database, not collection time)

### description / event_id #1  [metadata_id: 1270]

Unique identifier for this event

### description / event_message #9  [metadata_id: 1278]

Agent message or comment associated with this event from the distribution database

### description / event_type #3  [metadata_id: 1272]

Type of event: STATE_CHANGE, ERROR, AGENT_START, AGENT_STOP, RETRY, INFO

### status_value / event_type #1  [metadata_id: 2810]
Title: STATE_CHANGE

Agent run_status changed between collection cycles. Generic transition event logged for any status change.

### status_value / event_type #2  [metadata_id: 2811]
Title: AGENT_START

Agent transitioned to Started, Running, or Idle from a non-running state. Subset of STATE_CHANGE for dashboard convenience.

### status_value / event_type #3  [metadata_id: 2812]
Title: AGENT_STOP

Agent transitioned to Stopped from a running state, or "successfully stopped" message detected. Subset of STATE_CHANGE for dashboard convenience.

### status_value / event_type #4  [metadata_id: 2813]
Title: ERROR

Agent reported an error (error_id > 0 on current distribution history row). Can occur with or without a state change.

### status_value / event_type #5  [metadata_id: 2814]
Title: RETRY

Agent entered retry state (run_status = 4). Indicates an error occurred but the agent is attempting recovery.

### status_value / event_type #6  [metadata_id: 2815]
Title: INFO

Informational event worth recording. Used for registry changes, configuration updates, and other non-error events at collector discretion.

### description / previous_state #5  [metadata_id: 1274]

Previous run_status code. NULL for non-state-change events

### description / previous_state_desc #6  [metadata_id: 1275]

Previous state description (Started, Running, Idle, Retrying, Failed, Stopped). NULL for non-state-change events

### description / publication_registry_id #2  [metadata_id: 1271]

FK to Replication_PublicationRegistry. Identifies which agent this event pertains to

## Replication_LatencyHistory (Table)

### category #0  [metadata_id: 1756]

Replication

### data_flow #0  [metadata_id: 2795]

Append-only. Populated by Collect-ReplicationHealth.ps1 on a configurable interval (default every 5 minutes). The collector posts a tracer token via sp_posttracertoken on the publisher database, waits a configurable period (default 15 seconds), then collects results via sp_helptracertokenhistory. One row inserted per subscriber per token. After collection, the token is cleaned up from the distribution database via sp_deletetracertokenhistory. Also queried by the collector to determine elapsed time since the last token run. Read by the Control Center Replication page for latency dashboards.

### description #0  [metadata_id: 106]

Tracer token results measuring end-to-end replication latency from publisher through distributor to subscriber, with individual hop timing for bottleneck identification.

### design_note #1  [metadata_id: 2796]
Title: Three-Hop Latency Breakdown

Each measurement breaks total latency into two segments: publisher-to-distributor (reflects Log Reader performance) and distributor-to-subscriber (reflects Distribution Agent and network performance). When total latency spikes, the breakdown immediately identifies which hop is the bottleneck.

### design_note #2  [metadata_id: 2797]
Title: NULL Subscriber Commit as Signal

When a tracer token never arrives at the subscriber (agent stopped, network issue), subscriber_commit_dttm and downstream latency values are NULL. This is meaningful data — it confirms the Distribution Agent is not delivering. During the nightly BIDATA build window, NULL subscriber commits are expected and prove agents are stopped as intended.

### design_note #3  [metadata_id: 2798]
Title: Token Cleanup

The collector calls sp_deletetracertokenhistory after collecting results to prevent accumulation of tracer token records in the distribution database. Tokens are lightweight but their metadata persists in system tables until explicitly removed.

### module #0  [metadata_id: 1652]

ServerOps

### query #1  [metadata_id: 2799]
Title: Latest Latency Per Publication
Description: Most recent tracer token measurement for each publication/subscriber pair.

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

### query #2  [metadata_id: 2800]
Title: Latency Trend (24 Hours)
Description: All latency measurements over the last 24 hours for trending and BIDATA build window analysis.

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

### query #3  [metadata_id: 2801]
Title: Tokens That Never Arrived
Description: Tracer tokens where the subscriber never received delivery. Expected during BIDATA build windows; unexpected at other times.

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

### query #4  [metadata_id: 2802]
Title: Average Latency by Publication (30 Days)
Description: Latency statistics per publication including failed token count. Useful for baselining normal behavior and tuning alert thresholds.

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

### relationship_note #1  [metadata_id: 2803]
Title: Replication_PublicationRegistry

FK to registry. Each latency measurement references a registry entry identifying the publication/subscriber pair. Only Distribution agents produce latency data — Log Reader entries never appear here.

### relationship_note #2  [metadata_id: 2804]
Title: Replication_AgentHistory

No direct FK, but operationally paired. AgentHistory shows whether agents are running; LatencyHistory measures what that means for actual data delivery timing. During BIDATA build windows, AgentHistory shows Stopped status while LatencyHistory shows NULL subscriber_commit — the two tables tell the same story from different angles.

### description / collected_dttm #10  [metadata_id: 1245]

When these results were captured by the collector

### description / distributor_commit_dttm #5  [metadata_id: 1240]

When the tracer token arrived at the distributor

### description / distributor_to_subscriber_ms #8  [metadata_id: 1243]

Milliseconds from distributor commit to subscriber commit. Reflects Distribution Agent and network performance. NULL if token never arrived

### description / latency_id #1  [metadata_id: 1236]

Unique identifier for this latency measurement row

### description / publication_registry_id #2  [metadata_id: 1237]

FK to Replication_PublicationRegistry. Identifies which publication/subscriber pair this measurement is for

### description / publisher_commit_dttm #4  [metadata_id: 1239]

When the tracer token was committed at the publisher

### description / publisher_to_distributor_ms #7  [metadata_id: 1242]

Milliseconds from publisher commit to distributor commit. Reflects Log Reader Agent performance

### description / subscriber_commit_dttm #6  [metadata_id: 1241]

When the tracer token arrived at the subscriber. NULL if token never arrived

### description / total_latency_ms #9  [metadata_id: 1244]

End-to-end milliseconds from publisher to subscriber. NULL if token did not complete the full journey

### description / tracer_token_id #3  [metadata_id: 1238]

Token ID returned by sp_posttracertoken. Unique within the distribution database

## Replication_PublicationRegistry (Table)

### category #0  [metadata_id: 1757]

Replication

### data_flow #0  [metadata_id: 2760]

Populated by Collect-ReplicationHealth.ps1 via registry discovery. Each cycle, the collector queries distribution.dbo.MSdistribution_agents joined with MSsubscriber_info and MSpublications to discover Distribution agents, and MSlogreader_agents for the Log Reader. New agents are inserted automatically. Existing entries are refreshed (agent_id, agent_name, metadata IDs). Agents no longer found are soft-deleted (is_dropped = 1). Previously dropped agents that reappear are reactivated on their original row. Read by all subsequent collection steps as the authoritative list of what to monitor.

### description #0  [metadata_id: 95]

Master catalog of monitored replication publications and subscribers, dynamically discovered from the distribution database with soft-delete support for dropped publications.

### design_note #1  [metadata_id: 2761]
Title: Dynamic Discovery with Soft Delete

No manual setup required when publications are created or dropped. The collector auto-discovers from the distribution database each cycle. Dropped publications are soft-deleted (is_dropped = 1) to preserve FK integrity with AgentHistory, LatencyHistory, and EventLog. If a dropped publication is recreated with the same natural key, the original row is reused rather than creating a duplicate.

### design_note #2  [metadata_id: 2762]
Title: Subscriber Name Resolution

subscriber_name stores the name from MSsubscriber_info in the distribution database, not the linked server alias from master.sys.servers. These can differ significantly (e.g., linked server "DM-TEST-APP" maps to subscriber "fa-bidata.database.windows.net"). The registered subscriber name is required for system procedure calls like sp_replmonitorsubscriptionpendingcmds. Resolution uses prefix matching against the agent name string.

### design_note #3  [metadata_id: 2763]
Title: Log Reader as Registry Entry

The Log Reader agent is stored as a registry entry with agent_type = 'LogReader' and subscriber fields set to the publisher_db name. This is a design convenience — the Log Reader has no subscriber, but storing it in the same registry table keeps all agent monitoring unified. The natural key uses publisher_db for publication_name, subscriber_name, and subscriber_db.

### module #0  [metadata_id: 1653]

ServerOps

### query #1  [metadata_id: 2771]
Title: Active Publications
Description: All monitored publications with their subscription details.

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

### query #2  [metadata_id: 2772]
Title: Dropped Publications
Description: Publications no longer found in the distribution database.

SELECT 
    publication_name,
    subscriber_name,
    subscriber_db,
    agent_type,
    dropped_detected_dttm
FROM ServerOps.Replication_PublicationRegistry
WHERE is_dropped = 1
ORDER BY dropped_detected_dttm DESC;

### query #3  [metadata_id: 2773]
Title: Current Landscape Summary
Description: Agent count and monitoring status overview for active publications.

SELECT 
    agent_type,
    COUNT(*) AS agent_count,
    SUM(CAST(is_monitored AS INT)) AS monitored,
    SUM(CAST(tracer_tokens_enabled AS INT)) AS tracer_enabled
FROM ServerOps.Replication_PublicationRegistry
WHERE is_dropped = 0
GROUP BY agent_type;

### relationship_note #1  [metadata_id: 2774]
Title: Replication_AgentHistory

FK parent. Every agent health snapshot references a registry entry. The registry provides the stable identifier while distribution database agent_ids may change if subscriptions are dropped and recreated.

### relationship_note #2  [metadata_id: 2775]
Title: Replication_LatencyHistory

FK parent. Tracer token results are stored per publication/subscriber pair, linked back through the registry. Only Distribution agents generate latency data.

### relationship_note #3  [metadata_id: 2776]
Title: Replication_EventLog

FK parent. State change events reference the registry to identify which agent experienced the transition.

### relationship_note #4  [metadata_id: 2777]
Title: Collect-ReplicationHealth.ps1

The collector script performs registry discovery each cycle by querying the distribution database and syncing results into this table. All subsequent collection steps use this registry as the authoritative list of agents to monitor.

### description / agent_id #14  [metadata_id: 1048]

Current agent_id from distribution database. Refreshed on discovery; may change if subscription is dropped and recreated

### description / agent_name #13  [metadata_id: 1047]

Distribution or Log Reader agent name from distribution database

### description / agent_type #15  [metadata_id: 1049]

Distribution or LogReader

### status_value / agent_type #1  [metadata_id: 2764]
Title: Distribution

Distribution Agent delivering commands from distributor to subscriber. One per publication/subscriber pair. Full monitoring: health, queue depth, throughput, tracer tokens.

### status_value / agent_type #2  [metadata_id: 2765]
Title: LogReader

Log Reader Agent reading the publisher transaction log and writing to the distribution database. One per published database. Health and throughput only — no queue depth or tracer tokens. Single point of failure for all publications from the same database.

### description / created_dttm #20  [metadata_id: 1054]

When this registry entry was first created

### description / dropped_detected_dttm #19  [metadata_id: 1053]

When the drop was first detected by the collector

### description / is_dropped #18  [metadata_id: 1052]

Whether this publication no longer exists in the distribution database

### description / is_monitored #16  [metadata_id: 1050]

User-controlled flag: whether this publication is included in health monitoring

### description / modified_dttm #21  [metadata_id: 1055]

When this entry was last modified by the collector

### description / publication_id #4  [metadata_id: 1038]

publication_id from distribution.dbo.MSpublications. Refreshed on discovery

### description / publication_name #5  [metadata_id: 1039]

Publication name as defined in SQL Server replication

### description / publication_registry_id #1  [metadata_id: 1035]

Unique identifier for this registry entry

### description / publication_type #6  [metadata_id: 1040]

0 = Transactional, 1 = Snapshot, 2 = Merge

### status_value / publication_type #5  [metadata_id: 2768]
Title: 0 (Transactional)

Transactional replication — continuous delivery of committed transactions. All current Frost-Arnett publications use this type.

### status_value / publication_type #6  [metadata_id: 2769]
Title: 1 (Snapshot)

Snapshot replication — periodic full data refresh. Not currently in use.

### status_value / publication_type #7  [metadata_id: 2770]
Title: 2 (Merge)

Merge replication — bidirectional sync with conflict resolution. Not currently in use.

### description / publication_type_desc #7  [metadata_id: 1041]

Transactional, Snapshot, or Merge

### description / publisher_db #3  [metadata_id: 1037]

Published database name (e.g., crs5_oltp)

### description / publisher_id #2  [metadata_id: 1036]

publisher_id from distribution.dbo.MSpublications. Refreshed on discovery

### description / subscriber_db #10  [metadata_id: 1044]

Subscriber database name

### description / subscriber_id #8  [metadata_id: 1042]

subscriber_id from MSdistribution_agents (maps to master.sys.servers). Refreshed on discovery

### description / subscriber_name #9  [metadata_id: 1043]

Subscriber name as registered in distribution.dbo.MSsubscriber_info

### description / subscription_type #11  [metadata_id: 1045]

0 = Push, 1 = Pull (matches SQL Server convention)

### status_value / subscription_type #3  [metadata_id: 2766]
Title: 0 (Push)

Publisher-initiated delivery. The Distribution Agent runs at the distributor and pushes changes to the subscriber.

### status_value / subscription_type #4  [metadata_id: 2767]
Title: 1 (Pull)

Subscriber-initiated delivery. The Distribution Agent runs at the subscriber and pulls changes from the distributor.

### description / subscription_type_desc #12  [metadata_id: 1046]

Push or Pull

### description / tracer_tokens_enabled #17  [metadata_id: 1051]

User-controlled flag: whether tracer tokens are posted for this publication

## Scan-IndexFragmentation.ps1 (Script)

### category #0  [metadata_id: 3056]

Index

### data_flow #0  [metadata_id: 3057]

Reads GlobalConfig for thresholds (fragmentation threshold, min page count, rescan interval, skip-if-rebuilt days, scan time limit, batch check size, seconds-per-page coefficients). Reads ServerRegistry, DatabaseRegistry, and Index_DatabaseConfig for per-database overrides (index_maintenance_enabled, index_fragmentation_threshold, index_min_page_count, index_maintenance_priority, index_allow_offline_rebuild). Queries Index_Registry for scan candidates (not dropped, not excluded, above minimum page count, not recently scanned/rebuilt). Scans each candidate via dm_db_index_physical_stats (LIMITED mode) with scaled timeouts. Updates Index_Registry (current_fragmentation_pct, last_scanned_dttm). Manages Index_Queue (insert/update/delete based on threshold evaluation). Logs per-database results to Index_ExecutionSummary (SCAN). Updates Index_Status (SCAN row). Reports to Orchestrator v2.

### description #0  [metadata_id: 3054]

Performs the "expensive pass" of index maintenance: queries sys.dm_db_index_physical_stats for fragmentation data on each candidate index, updates Index_Registry with current fragmentation percentages, and manages the Index_Queue as a living queue — adding qualifying indexes, updating existing entries, removing entries that drop below threshold, and respecting IN_PROGRESS entries. Includes configurable time limits, abort flag support, and batch-level abort checking. Runs as a FIRE_AND_FORGET process under Orchestrator v2.

### design_note #1  [metadata_id: 3058]
Title: Scaled Timeouts

Each dm_db_index_physical_stats query gets a timeout calculated as: base_seconds + (page_count / pages_per_second). This prevents small indexes from waiting too long on timeout while giving large indexes adequate time. Both coefficients (base and pages_per_second) are configurable via GlobalConfig.

### design_note #2  [metadata_id: 3059]
Title: Abort and Time Limit Safety

Checks the GlobalConfig abort flag (index_scan_abort) both at startup and periodically during processing (every batch_check_size indexes). Also supports a configurable time limit (index_scan_time_limit_minutes). Both enable graceful termination of long-running scans without killing the process, preserving all work completed before the stop.

### design_note #3  [metadata_id: 3060]
Title: Inline Priority Score Calculation

Calculate-PriorityScore is defined inline rather than in the shared xFACts-IndexFunctions.ps1 library. It computes a weighted score from four components (database priority, fragmentation severity, index size, deferral count) with all weights and tier boundaries read from GlobalConfig. Maximum possible score is 100.

### module #0  [metadata_id: 3055]

ServerOps

## Send-DiskHealthSummary.ps1 (Script)

### category #0  [metadata_id: 2505]

Disk

### data_flow #0  [metadata_id: 2506]

Reads dbo.GlobalConfig (ServerOps/Disk) for warning_buffer_pct. Queries the latest Disk_Snapshot per server/drive joined to dbo.ServerRegistry (serverops_disk_enabled = 1) and Disk_ThresholdConfig. Classifies each drive as BELOW, APPROACHING, or OK and determines overall card severity. Builds complete Adaptive Card JSON and inserts directly into Teams.AlertQueue with card_json populated, bypassing sp_QueueAlert. Updates ServerOps.Disk_Status with last_health_check_dttm and last_health_check_status.

### description #0  [metadata_id: 2503]

Generates a disk health summary and delivers it as a color-coded Adaptive Card to Teams. Queries the latest Disk_Snapshot per server/drive, classifies drives against Disk_ThresholdConfig thresholds, and builds a rich card with inline drive details for problem servers. Inserts directly into Teams.AlertQueue with pre-built card_json. Runs on a configurable Orchestrator schedule.

### design_note #1  [metadata_id: 2507]
Title: Direct AlertQueue Insert with Pre-Built Card JSON

This script inserts directly into Teams.AlertQueue rather than calling sp_QueueAlert because it provides a complete pre-built Adaptive Card via the card_json field. The sp_QueueAlert procedure builds a standard card from title/message/color fields, but the disk health summary requires custom layout with server grouping, inline drive details, and color-coded text that cannot be expressed through the standard fields.

### design_note #2  [metadata_id: 2508]
Title: Three-Tier Card Severity

The card background color communicates overall fleet health at a glance: green (good) when all drives are above threshold + buffer, yellow (warning) when any drive is approaching but none are below, red (attention) when any drive is below threshold. Servers are sorted worst-first within the card so problems are immediately visible without scrolling.

### design_note #3  [metadata_id: 2509]
Title: Emoji Placeholder Pattern

Uses placeholder tokens ({{FIRE}}, {{WARN}}, {{CHECK}}) instead of direct Unicode emoji characters due to PowerShell 5.1 ConvertTo-Json encoding limitations. Process-TeamsAlertQueue.ps1 resolves these placeholders to actual Unicode characters at delivery time.

### module #0  [metadata_id: 2504]

ServerOps

### relationship_note #1  [metadata_id: 2510]
Title: Teams Delivery Chain

The card is inserted into Teams.AlertQueue with trigger_type DiskHealthSummary and trigger_value set to the current date (YYYY-MM-DD). The TR_Teams_AlertQueue_QueueDepth trigger fires on insert, signaling the processor. Process-TeamsAlertQueue.ps1 picks up the row and delivers to Teams via the webhook configured in Teams.WebhookSubscription for source_module ServerOps.

### relationship_note #2  [metadata_id: 2511]
Title: Dependency on Collection Freshness

This script depends on Collect-ServerHealth.ps1 having run recently to populate current Disk_Snapshot data. If collection has not run, the query returns no drive data and the script exits with a warning. The daily summary reflects whatever the latest snapshot shows — there is no separate freshness check beyond the snapshot existence.

## sp_Activity_CorrelateIncidents (Procedure)

### category #0  [metadata_id: 1758]

Activity

### data_flow #0  [metadata_id: 2567]

Called by Collect-DMVMetrics.ps1 at the end of each collection cycle (Step 4). Reads the latest snapshot from Activity_DMV_Memory (PLE, buffer cache, memory grants), Activity_DMV_ConnectionHealth (zombie count), and Activity_DMV_WaitStats (HADR_SYNC_COMMIT delta). Reads Activity_IncidentType for correlation window configuration. Reads Activity_XE_LRQ for concurrent query correlation. Writes to Activity_Heartbeat (one row per server) and Activity_IncidentLog (one row per threshold crossing). Also reads dbo.GlobalConfig (ServerOps/Activity_DMV) for threshold values and dbo.ServerRegistry for AG partner determination.

### description #0  [metadata_id: 134]

Analyzes collected DMV metrics for all monitored servers, detects threshold crossings, correlates with concurrent activity, and logs heartbeats and incidents.

### design_note #1  [metadata_id: 2568]
Title: Preview Mode

The @preview_only parameter (default 1) enables safe execution: the procedure evaluates all thresholds and prints results via PRINT statements without writing any data to Heartbeat or IncidentLog. Collect-DMVMetrics.ps1 calls it with @preview_only = 0. Manual execution defaults to preview mode, making it safe to run interactively for diagnostics.

### design_note #2  [metadata_id: 2569]
Title: Configurable Thresholds via GlobalConfig

Six thresholds are loaded from GlobalConfig (module ServerOps, category Activity_DMV): incident_ple_warning_threshold (default 300), incident_ple_critical_threshold (default 100), incident_hadr_spike_warning_ms (default 500000), incident_hadr_spike_critical_ms (default 5000000), incident_zombie_warning_threshold (default 500), incident_memory_grants_threshold (default 5). All have fallback defaults if config rows are missing.

### design_note #3  [metadata_id: 2570]
Title: AG Partner Determination

The AG partner (secondary server) is determined dynamically from ServerRegistry by matching ag_cluster_name between two SQL_SERVER type servers. This avoids hardcoding server names and adapts automatically if the AG configuration changes. The partner is used for HADR spike correlation — searching Activity_XE_LRQ on the secondary to identify workload causing synchronous commit delays on the primary.

### module #0  [metadata_id: 1654]

ServerOps

### relationship_note #1  [metadata_id: 2571]
Title: Collect-DMVMetrics.ps1

Called at Step 4 of Collect-DMVMetrics.ps1 after all DMV data has been committed. The call is wrapped in try/catch so correlation failure does not affect the collection data already committed. A correlation failure is logged as a warning but does not fail the overall script execution.

## sp_DiagnoseServerHealth (Procedure)

### category #0  [metadata_id: 1760]

Activity

### data_flow #0  [metadata_id: 2572]

Interactive diagnostic procedure intended for manual execution. Reads Activity_DMV_Memory, Activity_DMV_WaitStats, Activity_DMV_ConnectionHealth, Activity_DMV_Workload, and Activity_XE_LRQ for the specified server within the lookback window. Also queries sys.dm_hadr_availability_replica_states and sys.dm_hadr_database_replica_states for live AG status. Outputs analysis via PRINT statements in 8 numbered sections. Does not write to any tables.

### description #0  [metadata_id: 127]

Guided diagnostic procedure that analyzes server health metrics and provides educational interpretation of results for team members with varying SQL expertise levels.

### design_note #1  [metadata_id: 2573]
Title: Three Detail Levels

The @detail_level parameter controls output verbosity: 0 = Technical (metrics only), 1 = Standard (metrics with interpretation), 2 = Educational (metrics with explanations of what each metric means and why it matters). The educational mode is designed for team members who are learning SQL Server performance concepts.

### design_note #2  [metadata_id: 2574]
Title: Pre-Written User Communication

Section 8 (Summary and Recommendations) includes a "What to Tell Users" subsection that generates pre-written communication text based on the overall server health status. This provides ready-to-send responses for common user complaints like "the system is slow" — translating technical findings into plain language without requiring the DBA to compose the message.

### design_note #3  [metadata_id: 2575]
Title: Eight-Section Diagnostic Report

Sections: 0-Data Availability Check, 1-AG Health, 2-Memory Health Analysis, 3-Wait Category Analysis, 4-HADR Health and Secondary Correlation, 5-Monitoring Overhead Analysis, 6-Connection and Zombie Analysis, 7-Manual Investigation Queries, 8-Summary and Recommendations. Each section contributes a component status (HEALTHY, ELEVATED, WARNING, CRITICAL) to the overall assessment.

### module #0  [metadata_id: 1656]

ServerOps

## sp_Index_AddDatabaseHolidaySchedule (Procedure)

### category #0  [metadata_id: 1761]

Index

### data_flow #0  [metadata_id: 3082]

Accepts database name and server name, resolves them to database_id via DatabaseRegistry and ServerRegistry. Checks Index_HolidaySchedule for existing entry (prevents duplicates). Inserts one row with a default schedule of 9am-11pm allowed (hr09-hr22 = 1, all others = 0).

### description #0  [metadata_id: 129]

Adds a holiday schedule row for a database into HolidaySchedule. Resolves database and server names to IDs and inserts with a standard default schedule.

### design_note #1  [metadata_id: 3083]
Title: Name-Based Interface

Accepts database_name and server_name rather than IDs, resolving internally. This is more user-friendly for ad-hoc enrollment since operators know database names, not integer IDs. The proc validates both exist and are active before proceeding.

### module #0  [metadata_id: 1657]

ServerOps

## sp_Index_AddDatabaseSchedule (Procedure)

### category #0  [metadata_id: 1762]

Index

### data_flow #0  [metadata_id: 3079]

Reads dbo.DatabaseRegistry to validate the database_id. Checks Index_DatabaseSchedule for existing rows (prevents duplicate initialization). Inserts 7 rows into Index_DatabaseSchedule (one per day of week) using the provided block range parameters to generate the hr00-hr23 bit pattern. Supports separate configurations for weekdays, Saturday, and Sunday with optional override for Sunday differing from Saturday.

### description #0  [metadata_id: 125]

Adds the 7 default schedule rows (one per day of week) for a database in DatabaseSchedule. Provides flexible parameters for customizing blocking patterns during initial enrollment.

### design_note #1  [metadata_id: 3080]
Title: Block Range to Bit Grid Conversion

Accepts simple parameters (WeekdayBlockStart/End, WeekendBlockStart/End, optional SundayBlockStart/End) and generates the 24 bit columns per day. Hours within the block range are set to 0 (not allowed); hours outside are set to 1 (allowed). This avoids requiring callers to specify 168 individual bit values (7 days × 24 hours) while still producing the full granularity the schedule system requires.

### design_note #2  [metadata_id: 3081]
Title: Validation-Heavy Design

Validates hour ranges (0-23), paired parameters (both start and end must be specified or both NULL), and start-before-end ordering. Overnight windows (start > end) are not supported — this is an intentional simplification to avoid ambiguous cross-midnight logic.

### module #0  [metadata_id: 1658]

ServerOps

## Sync-IndexRegistry.ps1 (Script)

### category #0  [metadata_id: 3049]

Index

### data_flow #0  [metadata_id: 3050]

Reads dbo.ServerRegistry (serverops_index_enabled master switch) and dbo.DatabaseRegistry joined to Index_DatabaseConfig (index_sync_enabled) for target databases. For AG Listener servers, detects the primary replica via sys.dm_hadr_availability_group_states. Queries sys.indexes, sys.dm_db_partition_stats, and sys.dm_db_index_usage_stats on each target database. Inserts new indexes into Index_Registry, updates existing entries with refreshed metadata and usage stats, and marks missing indexes as is_dropped = 1. Logs per-database results to Index_ExecutionSummary (SYNC process). Updates Index_Status (SYNC row). Reports to Orchestrator v2 via callback.

### description #0  [metadata_id: 3047]

Performs the daily "cheap pass" reconciliation of index metadata across all enrolled databases. Discovers new indexes and adds them to Index_Registry, updates metadata (page count, fill factor, usage statistics) for existing indexes, and marks dropped indexes (present in registry but absent from source) as is_dropped = 1. Runs as a FIRE_AND_FORGET process under Orchestrator v2. Does NOT scan for fragmentation — that expensive operation is handled by Scan-IndexFragmentation.ps1.

### design_note #1  [metadata_id: 3051]
Title: Cheap Pass vs Expensive Pass Separation

Registry sync queries sys.indexes and sys.dm_db_index_usage_stats — lightweight catalog and DMV queries that complete quickly even on large databases. Fragmentation scanning via sys.dm_db_index_physical_stats is deliberately separated into Scan-IndexFragmentation.ps1 because it requires physical page reads that can take 30-60 minutes per large database. This separation allows daily discovery without daily fragmentation cost.

### design_note #2  [metadata_id: 3052]
Title: Replication System Table Exclusion

Excludes known replication system tables by name (sysarticles, sysschemaarticles, etc.) and by pattern (MSpeer_%, MSpub_%) from discovery. These tables have system-managed indexes that should not be maintained by xFACts.

### design_note #3  [metadata_id: 3053]
Title: Dropped Index Detection

After processing all source indexes, iterates through existing registry entries and marks any not seen in the current pass as is_dropped = 1. This detects index deletions without querying the source again. Previously dropped indexes that reappear (same schema.table.index_name) are automatically restored — is_dropped is reset to 0 and dropped_detected_dttm is cleared.

### module #0  [metadata_id: 3048]

ServerOps

## system_health (XE Session)

### category #0  [metadata_id: 2619]

Activity

### description #0  [metadata_id: 2617]

Microsoft built-in XE session that runs by default on every SQL Server instance. Captures broad system-level events including connectivity issues, scheduler problems, and errors. xFACts collects from this session for centralized health monitoring.

### design_note #1  [metadata_id: 2620]
Title: Built-In Session With Custom File Path Resolution

Unlike custom xFACts sessions that store files in a known directory, system_health uses the SQL Server default LOG directory. The collection script uses Get-SystemHealthFilePath to determine the correct file path pattern, which differs from the Get-XEFilePath function used for custom sessions.

### design_note #2  [metadata_id: 2644]
Title: Captured Events (Microsoft-Managed)

Microsoft built-in session capturing a broad range of system events. Key events include: sp_server_diagnostics_component_result (component health assessments), error_reported (errors with severity >= 20), connectivity_ring_buffer_recorded (connectivity issues), scheduler_monitor_system_health_ring_buffer_recorded (scheduler problems). The event list is defined by Microsoft and varies by SQL Server version. xFACts does not modify this session - it collects from it as-is.

### module #0  [metadata_id: 2618]

ServerOps

### query #1  [metadata_id: 2645]
Title: Check Session Status
Description: Verify the session is running (should always be running as it is a SQL Server default)

SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'system_health';

### relationship_note #1  [metadata_id: 2621]
Title: Activity_XE_SystemHealth

Events from this session are parsed by Parse-SystemHealthEvent and stored in Activity_XE_SystemHealth.

## Update-IndexStatistics.ps1 (Script)

### category #0  [metadata_id: 3070]

Index

### data_flow #0  [metadata_id: 3071]

Reads GlobalConfig for thresholds (modification threshold percentage, max days stale, min rows, global sample percentage). Reads ServerRegistry, DatabaseRegistry, and Index_DatabaseConfig (stats_maintenance_enabled, stats_sample_pct) for per-database overrides. Queries Index_Registry for enrolled indexes with their stats_last_updated timestamps. Queries sys.dm_db_stats_properties on each target database for current modification counters. Joins the two datasets to identify MODIFICATION candidates (pct_modified >= threshold) and STALENESS candidates (days since update >= threshold). Executes UPDATE STATISTICS with the appropriate sample rate. Updates Index_Registry (stats_last_updated). Logs to Index_StatsExecutionLog (individual MODIFICATION rows, cumulative STALENESS rows per database). Logs to Index_ExecutionSummary (STATS). Updates Index_Status (STATS row). Reports to Orchestrator v2.

### description #0  [metadata_id: 3068]

Updates statistics on indexes based on modification thresholds and staleness age. Queries sys.dm_db_stats_properties for modification counters, updates statistics exceeding the modification threshold (logged individually to Index_StatsExecutionLog), and updates stale statistics exceeding the age threshold (logged as one cumulative row per database). Works exclusively from Index_Registry — only index-associated statistics are processed. Runs as a FIRE_AND_FORGET process under Orchestrator v2.

### design_note #1  [metadata_id: 3072]
Title: Per-Database Sample Rate Override

stats_sample_pct in Index_DatabaseConfig overrides the GlobalConfig default. A value of 0 means FULLSCAN. This allows critical databases with skewed distributions to use full scans while less critical databases use sampling for speed.

### module #0  [metadata_id: 3069]

ServerOps

## xFACts-BackupFunctions.ps1 (Script)

### category #0  [metadata_id: 5127]

Backup

### data_flow #0  [metadata_id: 5128]

Dot-sourced by Collect-BackupStatus.ps1, Process-BackupNetworkCopy.ps1, Process-BackupAWSUpload.ps1, and Process-BackupRetention.ps1 after xFACts-OrchestratorFunctions.ps1. Get-bkp_PhysicalServerFromPath and Convert-bkp_ToUncPath resolve the physical server and admin-share UNC path for a backup file so the processors can reach files on whichever AG replica produced them. Write-bkp_ExecutionLog writes one detail row per operation to ServerOps.Backup_ExecutionLog. Set-bkp_AwsUploadStatus and Set-bkp_NetworkCopyStatus update the per-file status columns in ServerOps.Backup_FileTracking that the Control Center Backup Monitoring page displays. Invoke-bkp_RetryFailedFiles resets retry-eligible failed files in Backup_FileTracking back to PENDING and posts the retries-exhausted alert via the shared Send-TeamsAlert. The functions hold no state of their own; they operate on values the calling script passes in.

### description #0  [metadata_id: 5125]

Shared scoped-function library for the ServerOps.Backup pipeline scripts. Centralizes the backup-filename physical-server parsing, the local-to-UNC admin-share path conversion, the Backup_ExecutionLog detail writer, the AWS-upload and network-copy Backup_FileTracking status writes, and the retry-handling routine that the backup collector and the network-copy, AWS-upload, and retention processors previously duplicated. Dot-sourced after xFACts-OrchestratorFunctions.ps1, which supplies the Write-Log, Get-SqlData, Invoke-SqlNonQuery, and Send-TeamsAlert it calls.

### design_note #1  [metadata_id: 5129]
Title: No self-import of the orchestrator

As a shared-library file it declares no IMPORTS section, so it does not dot-source xFACts-OrchestratorFunctions.ps1 even though it depends on that file's Write-Log, Get-SqlData, Invoke-SqlNonQuery, and Send-TeamsAlert. Consuming scripts dot-source the orchestrator first, then this helper. This keeps the load order explicit at the call site and avoids a shared library reaching back into platform infrastructure.

### design_note #2  [metadata_id: 5130]
Title: One execution-log writer for all callers

Write-bkp_ExecutionLog takes the union of every pipeline's columns, including the error_details column only the AWS-upload path supplies, so all four scripts share one writer. Any unsupplied duration, byte count, error message, or error detail is written as a SQL NULL rather than a zero or empty string, which keeps a missing metric distinguishable from a real zero in Backup_ExecutionLog.

### design_note #3  [metadata_id: 5131]
Title: Separate status writers per column family

The AWS-upload and network-copy pipelines write to different Backup_FileTracking column families, so each has its own writer (Set-bkp_AwsUploadStatus, Set-bkp_NetworkCopyStatus) rather than one writer parameterized across both. Each writer includes only the columns it was given, building the UPDATE set clause from the supplied values.

### design_note #4  [metadata_id: 5132]
Title: Retry handling parameterized by operation

Invoke-bkp_RetryFailedFiles serves both the network-copy and AWS-upload pipelines over their separate column families through a single -Operation discriminator that selects the column family, the alert label, and the trigger type. It performs both halves of the retry step: resetting retry-eligible failed files to PENDING and alerting on files that have exhausted their retries. The network-copy script's network-root verification stays inline in that script because it is adjacent to, not part of, the shared retry pattern.

### module #0  [metadata_id: 5126]

ServerOps

## xFACts-IndexFunctions.ps1 (Script)

### category #0  [metadata_id: 3075]

Index

### data_flow #0  [metadata_id: 3076]

Reads Index_ExceptionSchedule (DATABASE ? SERVER ? GLOBAL scope evaluation), dbo.Holiday and Index_HolidaySchedule (two-table holiday check), and Index_DatabaseSchedule (default schedule fallback) in the Get-EffectiveSchedule function. Reads GlobalConfig abort flags (index_scan_abort, index_execute_abort) in Test-AbortRequested. Reads Index_Queue and Index_DatabaseConfig in Get-IndexesForWindow for best-fit index selection. All reads are performed against the xFACts database via Invoke-Sqlcmd.

### description #0  [metadata_id: 3073]

Shared function library dot-sourced by Execute-IndexMaintenance.ps1 and Scan-IndexFragmentation.ps1. Provides schedule evaluation (Get-EffectiveSchedule), available window calculation (Get-AvailableMinutes, Get-MaxWeekdayWindow), extended window detection (Test-IsExtendedWindow), index selection for windows (Get-IndexesForWindow), abort flag checking (Test-AbortRequested), and AG primary detection (Get-AGPrimary).

### design_note #1  [metadata_id: 3077]
Title: Three-Tier Schedule Resolution

Get-EffectiveSchedule evaluates schedules in strict priority order: Exception (DATABASE scope ? SERVER scope ? GLOBAL scope) ? Holiday (weekdays only, two-table check) ? DatabaseSchedule. The first match at any tier determines the result — no further tables are consulted. This enables surgical overrides (freeze one database for a deployment) without affecting the rest of the fleet.

### design_note #2  [metadata_id: 3078]
Title: Best-Fit Index Selection

Get-IndexesForWindow implements a bin-packing algorithm for weekday processing: iterates through the queue by priority, selecting indexes whose estimated duration fits in the remaining time, and skipping larger ones to try smaller ones. On extended windows, it uses simple priority ordering since time is not constrained. Returns three arrays: selected indexes, newly SCHEDULED indexes (too large for any weekday window), and deferred SCHEDULED indexes (too large even for the current extended window).

### module #0  [metadata_id: 3074]

ServerOps

## xFACts_BlockedProcess (XE Session)

### category #0  [metadata_id: 2597]

Activity

### description #0  [metadata_id: 2595]

Captures blocked_process_report events triggered by the SQL Server blocked process threshold configuration. Provides the raw data for Activity_XE_BlockedProcess.

### design_note #1  [metadata_id: 2598]
Title: Server-Level Prerequisite

This session requires the sp_configure 'blocked process threshold' to be set on each monitored server. SQL Server only generates blocked_process_report events when blocking exceeds this threshold. The XE session captures the event; the server configuration controls when events are generated.

### design_note #2  [metadata_id: 2632]
Title: Captured Events and Actions

Captures blocked_process_report events. Unlike other XE sessions, this event is triggered by the SQL Server sp_configure 'blocked process threshold' setting, not by an XE predicate. The session simply captures all events that SQL Server generates. Actions collected: database_name, session_id, client_hostname, client_app_name, username. Most blocking details (both blocked and blocking sides) come from the event XML payload, not actions. Target: rolling .xel files (5 files x 50 MB = 250 MB max) at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

### module #0  [metadata_id: 2596]

ServerOps

### query #1  [metadata_id: 2633]
Title: Check Session Status and Threshold
Description: Shows session status and the sp_configure blocked process threshold

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

### relationship_note #1  [metadata_id: 2599]
Title: Activity_XE_BlockedProcess

Events from this session are parsed by Parse-BlockedProcessEvent and stored in Activity_XE_BlockedProcess.

## xFACts_Deadlock (XE Session)

### category #0  [metadata_id: 2602]

Activity

### description #0  [metadata_id: 2600]

Captures xml_deadlock_report events containing the full deadlock graph. Provides the raw data for Activity_XE_Deadlock.

### design_note #1  [metadata_id: 2635]
Title: Captured Events

Captures xml_deadlock_report events with no predicate filter - all deadlocks are captured. This provides the complete deadlock graph XML including both victim and survivor process details, lock resources, and full query text. The built-in system_health session also captures deadlocks, but xFACts_Deadlock provides a dedicated, isolated capture. Target: rolling .xel files (5 files x 50 MB = 250 MB max) at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

### module #0  [metadata_id: 2601]

ServerOps

### query #1  [metadata_id: 2636]
Title: Check Session Status
Description: Verify the session is running on a monitored server

SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_Deadlock';

### relationship_note #1  [metadata_id: 2603]
Title: Activity_XE_Deadlock

Events from this session are parsed by Parse-DeadlockEvent and stored in Activity_XE_Deadlock. The full deadlock graph XML is always retained.

## xFACts_LongQueries (XE Session)

### category #0  [metadata_id: 2593]

Activity

### description #0  [metadata_id: 2591]

Captures sql_batch_completed and rpc_completed events that exceed a configurable duration threshold. Provides the raw data for Activity_XE_LRQ and serves as the primary correlation source for incident detection.

### design_note #1  [metadata_id: 2627]
Title: Captured Events and Actions

Captures sql_statement_completed and rpc_completed events exceeding the configured duration threshold. Two event types ensure coverage of all query execution paths: sql_statement_completed fires for ad-hoc SQL and statements within batches; rpc_completed fires for parameterized queries from applications (sp_executesql, ORM-generated queries). Actions collected: sql_text, database_name, username, client_hostname, client_app_name, session_id, query_hash, query_plan_hash. Target: rolling .xel files (5 files x 50 MB = 250 MB max per server) at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

### design_note #2  [metadata_id: 2628]
Title: Duration Threshold in Microseconds

The duration predicate is specified in microseconds (not milliseconds). 1 second = 1,000,000 microseconds. The threshold is set in the XE session DDL predicate, not in GlobalConfig. Changing it requires redeploying the session on each server. The deployment script is idempotent - it stops and drops any existing session before creating a new one.

### module #0  [metadata_id: 2592]

ServerOps

### query #1  [metadata_id: 2629]
Title: Check Session Status
Description: Verify the session is running on a monitored server

SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_LongQueries';

### query #2  [metadata_id: 2630]
Title: View Current Threshold
Description: Shows the duration predicate value configured in the session

SELECT 
    ses.name AS event_name,
    ses.predicate
FROM sys.server_event_session_events ses
JOIN sys.server_event_sessions s 
    ON ses.event_session_id = s.event_session_id
WHERE s.name = 'xFACts_LongQueries';

### relationship_note #1  [metadata_id: 2594]
Title: Activity_XE_LRQ

Events from this session are parsed by Parse-LRQEvent and stored in Activity_XE_LRQ. The duration threshold is configured in the XE session CREATE EVENT SESSION DDL on each monitored server.

## xFACts_LS_Inbound (XE Session)

### category #0  [metadata_id: 2606]

Activity

### description #0  [metadata_id: 2604]

Captures inbound linked server query events — queries received from other servers via linked server connections. Provides the raw data for Activity_XE_LinkedServerIn after aggregation.

### design_note #1  [metadata_id: 2637]
Title: Captured Events and Predicate

Captures sql_statement_completed and rpc_completed events filtered to linked server connections (client_app_name = 'Microsoft SQL Server', which is the signature of linked server connections). Actions collected: sql_text. The predicate ensures only inbound linked server traffic is captured, avoiding all local query activity. Target: rolling .xel files at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

### module #0  [metadata_id: 2605]

ServerOps

### query #1  [metadata_id: 2638]
Title: Check Session Status
Description: Verify the session is running on a monitored server

SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_LS_Inbound';

### relationship_note #1  [metadata_id: 2607]
Title: Activity_XE_LinkedServerIn

Events from this session are parsed by Parse-LSInboundEvent, aggregated by Aggregate-LSEvents, and stored in Activity_XE_LinkedServerIn. High-frequency linked server traffic is aggregated before storage to manage data volume.

## xFACts_LS_Outbound (XE Session)

### category #0  [metadata_id: 2610]

Activity

### description #0  [metadata_id: 2608]

Captures outbound linked server query events — queries sent to other servers via four-part naming, OPENQUERY, or OPENROWSET. Provides the raw data for Activity_XE_LinkedServerOut after aggregation.

### design_note #1  [metadata_id: 2639]
Title: Captured Events and Predicate Exclusions

Captures sql_statement_completed and rpc_completed events for queries targeting linked servers (four-part naming, OPENQUERY, OPENROWSET). Actions collected: sql_text. The predicate excludes known noisy sources at the XE engine level: Redgate monitoring tools and SQLServerCEIP telemetry. This predicate-level exclusion means zero overhead for excluded sources - events never allocate memory or write to the buffer. Target: rolling .xel files at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

### module #0  [metadata_id: 2609]

ServerOps

### query #1  [metadata_id: 2640]
Title: Check Session Status
Description: Verify the session is running on a monitored server

SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_LS_Outbound';

### relationship_note #1  [metadata_id: 2611]
Title: Activity_XE_LinkedServerOut

Events from this session are parsed by Parse-LSOutboundEvent, aggregated by Aggregate-LSEvents, and stored in Activity_XE_LinkedServerOut. Same aggregation pattern as xFACts_LS_Inbound.

## xFACts_Tracking (XE Session)

### category #0  [metadata_id: 2614]

Activity

### description #0  [metadata_id: 2612]

Captures all completed query executions from xFACts processes on each monitored server. Filters to sessions with application name matching xFACts patterns. Provides the raw data for Activity_XE_xFACts.

### design_note #1  [metadata_id: 2615]
Title: Self-Monitoring Complement to DMV Footprint

This XE session captures event-level detail (individual queries with text and execution metrics) while Activity_DMV_xFACts captures point-in-time session state (cumulative counters). Together they provide complete self-monitoring: the DMV table shows total resource impact and the XE table shows what specific queries xFACts ran.

### design_note #2  [metadata_id: 2641]
Title: Captured Events and Actions

Captures sql_batch_completed events from xFACts processes only (filtered by client_app_name LIKE 'xFACts%'). No duration threshold - captures all completed batches regardless of duration for comprehensive impact tracking. Actions collected: sql_text. Target: rolling .xel files at E:\xFACts_XE\. Session options: STARTUP_STATE = ON, ALLOW_SINGLE_EVENT_LOSS.

### design_note #3  [metadata_id: 2642]
Title: Collector Self-Exclusion Predicate

The predicate explicitly excludes client_app_name = 'xFACts Collect-XEEvents'. Without this exclusion, the collector's INSERT statements into Activity_XE_xFACts would be captured as events, collected on the next cycle, inserted again, and captured again - creating a feedback amplification loop. The collector's own impact is tracked via Orchestrator.TaskLog duration and Activity_DMV_xFACts instead.

### module #0  [metadata_id: 2613]

ServerOps

### query #1  [metadata_id: 2643]
Title: Check Session Status
Description: Verify the session is running on a monitored server

SELECT 
    es.name AS session_name,
    CASE WHEN dxs.name IS NOT NULL THEN 'RUNNING' ELSE 'STOPPED' END AS status,
    es.startup_state
FROM sys.server_event_sessions es
LEFT JOIN sys.dm_xe_sessions dxs ON es.name = dxs.name
WHERE es.name = 'xFACts_Tracking';

### relationship_note #1  [metadata_id: 2616]
Title: Activity_XE_xFACts

Events from this session are parsed by Parse-xFACtsEvent and stored in Activity_XE_xFACts.

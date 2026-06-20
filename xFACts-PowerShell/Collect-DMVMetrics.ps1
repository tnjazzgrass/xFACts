<#
.SYNOPSIS
    xFACts - DMV Metrics Collection

.DESCRIPTION
    Collects point-in-time server health metrics via DMV polling from all
    registered servers and imports them into xFACts Activity_DMV_* tables.

    Collected metrics:
    - Memory health (PLE, buffer cache, memory grants) -> Activity_DMV_Memory
    - Workload indicators (connections, requests, blocking, CPU/IO busy) -> Activity_DMV_Workload
    - Connection pool health (zombies, open transactions) -> Activity_DMV_ConnectionHealth
    - Wait statistics -> Activity_DMV_WaitStats
    - I/O statistics -> Activity_DMV_IO_Stats
    - xFACts session footprint (per-session CPU, reads, writes) -> Activity_DMV_xFACts

    Complements Extended Events collection (event-driven) with continuous
    state monitoring (snapshot-driven). All DMV queries return numeric or
    short-string data, so none require extended MaxCharLength handling.

.PARAMETER ServerInstance
    SQL Server instance name for xFACts database (default: AVG-PROD-LSNR)

.PARAMETER Database
    Database name (default: xFACts)

.PARAMETER Execute
    Perform writes. Without this flag, the script exits immediately.
    No preview mode - this is a high-frequency collector with no dry-run path.

.PARAMETER Force
    Bypass any checks and run immediately

.PARAMETER TaskId
    Orchestrator TaskLog ID passed by the v2 engine at launch. Used for task
    completion callback. Default 0 (no callback when run manually).

.PARAMETER ProcessId
    Orchestrator ProcessRegistry ID passed by the v2 engine at launch. Used for
    task completion callback. Default 0 (no callback when run manually).

.COMPONENT
    ServerOps.ServerHealth

.NOTES
    File Name : Collect-DMVMetrics.ps1
    Location  : E:\xFACts-PowerShell\Collect-DMVMetrics.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    PARAMETERS: SCRIPT PARAMETERS
    IMPORTS: SCRIPT DEPENDENCIES
    INITIALIZATION: SCRIPT INITIALIZATION
    FUNCTIONS: MEMORY METRICS
    FUNCTIONS: WORKLOAD METRICS
    FUNCTIONS: CONNECTION HEALTH METRICS
    FUNCTIONS: WAIT STATS METRICS
    FUNCTIONS: IO STATS METRICS
    FUNCTIONS: FOOTPRINT METRICS
    EXECUTION: SCRIPT EXECUTION
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this file, most recent first. Authoritative
   version tracking lives in dbo.System_Metadata (component
   ServerOps.ServerHealth); this section records what changed and when.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-19  Conformed to the PowerShell file format spec: header CHANGELOG and
#             deployment block removed, section banners added, functions renamed
#             to approved verbs with the srv prefix, sub-section markers and
#             trailing comments regularized. Deleted the local Get-SqlInstanceName
#             and Get-ConfigValue copies in favor of the shared
#             Get-SqlInstanceName and Get-GlobalConfigValue in
#             xFACts-OrchestratorFunctions.ps1.
# 2026-03-11  Migrated to Initialize-XFActsScript shared infrastructure.
#             Removed inline Write-Log, Get-SqlData, Invoke-SqlNonQuery.
#             Converted 1 direct Invoke-Sqlcmd (sp_Activity_CorrelateIncidents).
#             Updated -DB parameter refs to -DatabaseName for cross-server calls.
# 2026-02-19  Added cpu_busy_ms/io_busy_ms server counters to workload collection.
#             New Activity_DMV_xFACts session capture.
# 2026-02-05  Orchestrator v2 integration. Added -Execute safeguard,
#             TaskId/ProcessId, orchestrator callback. Relocated to
#             E:\xFACts-PowerShell on FA-SQLDBB.
# 2026-01-23  Refactoring standardization. Added master switch check
#             (serverops_activity_enabled). ServerOps.ServerRegistry ->
#             dbo.ServerRegistry. ServerOps.Activity_Config -> dbo.GlobalConfig.
#             Activity_DMV_Connection_Health -> Activity_DMV_ConnectionHealth.
#             Activity_DMV_Wait_Stats -> Activity_DMV_WaitStats.
# 2026-01-16  Added incident correlation step after DMV collection.
# 2026-01-15  Initial implementation. Memory, Workload, ConnectionHealth,
#             WaitStats, I/O Stats collection.

<# ============================================================================
   PARAMETERS: SCRIPT PARAMETERS
   ----------------------------------------------------------------------------
   Script-level parameters: connection target, the execute switch, the force
   override, and the orchestrator callback identifiers.
   Prefix: (none)
   ============================================================================ #>

[CmdletBinding()]
param(
    [string]$ServerInstance = "AVG-PROD-LSNR",
    [string]$Database = "xFACts",
    [switch]$Execute,
    [switch]$Force,
    [long]$TaskId = 0,
    [int]$ProcessId = 0
)

<# ============================================================================
   IMPORTS: SCRIPT DEPENDENCIES
   ----------------------------------------------------------------------------
   Dot-sourced shared infrastructure: orchestrator helpers, SQL data access,
   logging, the GlobalConfig reader, and the orchestrator callback.
   Prefix: (none)
   ============================================================================ #>

. "$PSScriptRoot\xFACts-OrchestratorFunctions.ps1"

<# ============================================================================
   INITIALIZATION: SCRIPT INITIALIZATION
   ----------------------------------------------------------------------------
   Establishes shared script context (application identity, connection
   target, log path, Execute mode) and enforces the hard -Execute guard: this
   high-frequency collector has no preview path and exits without -Execute.
   Prefix: (none)
   ============================================================================ #>

Initialize-XFActsScript -ScriptName 'Collect-DMVMetrics' `
    -ServerInstance $ServerInstance -Database $Database -Execute:$Execute

# Hard exit without -Execute - no preview mode for this collector
if (-not $Execute) {
    exit 0
}

<# ============================================================================
   FUNCTIONS: MEMORY METRICS
   ----------------------------------------------------------------------------
   Collects memory-health DMV counters (page life expectancy, buffer cache hit
   ratio, memory grants, target/total memory) and persists a snapshot row to
   Activity_DMV_Memory.
   Prefix: srv
   ============================================================================ #>

# Collects memory health DMV metrics (PLE, buffer cache, grants) for one instance.
function Get-srv_MemoryMetrics {
    param([string]$SqlInstanceName)

    $query = @"
SELECT
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Page life expectancy') AS ple_seconds,
    (SELECT CAST(100.0 * cntr_value / NULLIF((SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Buffer cache hit ratio base'), 0) AS DECIMAL(5,2))
     FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Buffer cache hit ratio') AS buffer_cache_hit_ratio,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Memory Grants Pending') AS memory_grants_pending,
    (SELECT cntr_value / 1024 FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Target Server Memory (KB)') AS target_memory_mb,
    (SELECT cntr_value / 1024 FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Total Server Memory (KB)') AS total_memory_mb,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Free list stalls/sec') AS free_list_stalls,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Lazy writes/sec') AS lazy_writes
"@

    try {
        $result = Get-SqlData -Query $query -Instance $SqlInstanceName -DatabaseName "master"

        if ($null -ne $result) {
            return @{
                ple_seconds = $result.ple_seconds
                buffer_cache_hit_ratio = $result.buffer_cache_hit_ratio
                memory_grants_pending = $result.memory_grants_pending
                target_memory_mb = $result.target_memory_mb
                total_memory_mb = $result.total_memory_mb
                free_list_stalls = $result.free_list_stalls
                lazy_writes = $result.lazy_writes
            }
        }
        return $null
    }
    catch {
        Write-Log "    Memory metrics collection failed: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Inserts one memory metrics snapshot row into Activity_DMV_Memory.
function Write-srv_MemoryMetrics {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [datetime]$SnapshotTime,
        [hashtable]$Metrics
    )

    $query = @"
INSERT INTO ServerOps.Activity_DMV_Memory
    (server_id, server_name, snapshot_dttm, ple_seconds, buffer_cache_hit_ratio,
     memory_grants_pending, target_memory_mb, total_memory_mb, free_list_stalls, lazy_writes)
VALUES
    ($ServerId, '$ServerName', '$($SnapshotTime.ToString("yyyy-MM-dd HH:mm:ss"))',
     $($Metrics.ple_seconds), $($Metrics.buffer_cache_hit_ratio),
     $($Metrics.memory_grants_pending), $($Metrics.target_memory_mb), $($Metrics.total_memory_mb),
     $($Metrics.free_list_stalls), $($Metrics.lazy_writes))
"@

    return Invoke-SqlNonQuery -Query $query
}

<# ============================================================================
   FUNCTIONS: WORKLOAD METRICS
   ----------------------------------------------------------------------------
   Collects workload DMV counters (user connections, blocked/active requests,
   batch requests, compiles/recompiles, CPU and I/O busy time) and persists a
   snapshot row to Activity_DMV_Workload.
   Prefix: srv
   ============================================================================ #>

# Collects workload DMV metrics (connections, requests, compiles, CPU/IO busy) for one instance.
function Get-srv_WorkloadMetrics {
    param([string]$SqlInstanceName)

    $query = @"
SELECT
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%:General Statistics%' AND counter_name = 'User Connections') AS user_connections,
    (SELECT COUNT(*) FROM sys.dm_exec_requests
     WHERE blocking_session_id > 0) AS blocked_session_count,
    (SELECT COUNT(*) FROM sys.dm_exec_requests
     WHERE session_id > 50 AND status IN ('running', 'runnable', 'suspended')) AS active_request_count,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%:SQL Statistics%' AND counter_name = 'Batch Requests/sec') AS batch_requests,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%:SQL Statistics%' AND counter_name = 'SQL Compilations/sec') AS sql_compilations,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%:SQL Statistics%' AND counter_name = 'SQL Re-Compilations/sec') AS sql_recompilations,
    CAST(@@CPU_BUSY AS BIGINT) * CAST(@@TIMETICKS AS BIGINT) / 1000 AS cpu_busy_ms,
    CAST(@@IO_BUSY AS BIGINT) * CAST(@@TIMETICKS AS BIGINT) / 1000 AS io_busy_ms
"@

    try {
        $result = Get-SqlData -Query $query -Instance $SqlInstanceName -DatabaseName "master"

        if ($null -ne $result) {
            return @{
                user_connections = $result.user_connections
                blocked_session_count = $result.blocked_session_count
                active_request_count = $result.active_request_count
                batch_requests = $result.batch_requests
                sql_compilations = $result.sql_compilations
                sql_recompilations = $result.sql_recompilations
                cpu_busy_ms = $result.cpu_busy_ms
                io_busy_ms = $result.io_busy_ms
            }
        }
        return $null
    }
    catch {
        Write-Log "    Workload metrics collection failed: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Inserts one workload metrics snapshot row into Activity_DMV_Workload.
function Write-srv_WorkloadMetrics {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [datetime]$SnapshotTime,
        [hashtable]$Metrics
    )

    $query = @"
INSERT INTO ServerOps.Activity_DMV_Workload
    (server_id, server_name, snapshot_dttm, user_connections, blocked_session_count,
     active_request_count, batch_requests, sql_compilations, sql_recompilations,
     cpu_busy_ms, io_busy_ms)
VALUES
    ($ServerId, '$ServerName', '$($SnapshotTime.ToString("yyyy-MM-dd HH:mm:ss"))',
     $($Metrics.user_connections), $($Metrics.blocked_session_count),
     $($Metrics.active_request_count), $($Metrics.batch_requests),
     $($Metrics.sql_compilations), $($Metrics.sql_recompilations),
     $($Metrics.cpu_busy_ms), $($Metrics.io_busy_ms))
"@

    return Invoke-SqlNonQuery -Query $query
}

<# ============================================================================
   FUNCTIONS: CONNECTION HEALTH METRICS
   ----------------------------------------------------------------------------
   Collects connection-health DMV metrics (session counts, zombie detection,
   open transactions, JDBC breakdown) and persists a snapshot row to
   Activity_DMV_ConnectionHealth.
   Prefix: srv
   ============================================================================ #>

# Collects connection-health DMV metrics (sessions, zombies, open transactions) for one instance.
function Get-srv_ConnectionHealthMetrics {
    param(
        [string]$SqlInstanceName,
        [int]$ZombieIdleThresholdMinutes = 60
    )

    $query = @"
;WITH SessionStats AS (
    SELECT
        session_id,
        status,
        program_name,
        open_transaction_count,
        DATEDIFF(MINUTE, last_request_end_time, GETDATE()) AS idle_minutes
    FROM sys.dm_exec_sessions
    WHERE session_id > 50
),
ZombieCheck AS (
    SELECT
        session_id,
        status,
        program_name,
        idle_minutes,
        CASE
            WHEN status = 'sleeping'
                 AND open_transaction_count = 0
                 AND idle_minutes >= $ZombieIdleThresholdMinutes
            THEN 1 ELSE 0
        END AS is_zombie,
        CASE
            WHEN program_name LIKE '%JDBC%' THEN 1 ELSE 0
        END AS is_jdbc
    FROM SessionStats
)
SELECT
    COUNT(*) AS total_sessions,
    SUM(CASE WHEN status = 'sleeping' THEN 1 ELSE 0 END) AS sleeping_sessions,
    SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running_sessions,
    SUM(is_zombie) AS zombie_count,
    MAX(CASE WHEN is_zombie = 1 THEN idle_minutes ELSE NULL END) AS oldest_zombie_idle_min,
    (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE session_id > 50 AND open_transaction_count > 0) AS sessions_with_open_tran,
    (SELECT MAX(DATEDIFF(MINUTE, last_request_end_time, GETDATE()))
     FROM sys.dm_exec_sessions WHERE session_id > 50 AND open_transaction_count > 0) AS oldest_open_tran_min,
    SUM(is_jdbc) AS jdbc_total,
    SUM(CASE WHEN is_jdbc = 1 AND status = 'sleeping' THEN 1 ELSE 0 END) AS jdbc_sleeping,
    SUM(CASE WHEN is_jdbc = 1 AND is_zombie = 1 THEN 1 ELSE 0 END) AS jdbc_zombie
FROM ZombieCheck
"@

    try {
        $result = Get-SqlData -Query $query -Instance $SqlInstanceName -DatabaseName "master"

        if ($null -ne $result) {
            return @{
                total_sessions = $result.total_sessions
                sleeping_sessions = $result.sleeping_sessions
                running_sessions = $result.running_sessions
                zombie_count = $result.zombie_count
                oldest_zombie_idle_min = if ($result.oldest_zombie_idle_min -is [DBNull]) { $null } else { $result.oldest_zombie_idle_min }
                sessions_with_open_tran = $result.sessions_with_open_tran
                oldest_open_tran_min = if ($result.oldest_open_tran_min -is [DBNull]) { $null } else { $result.oldest_open_tran_min }
                jdbc_total = $result.jdbc_total
                jdbc_sleeping = $result.jdbc_sleeping
                jdbc_zombie = $result.jdbc_zombie
            }
        }
        return $null
    }
    catch {
        Write-Log "    Connection health metrics collection failed: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Inserts one connection-health snapshot row into Activity_DMV_ConnectionHealth.
function Write-srv_ConnectionHealthMetrics {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [datetime]$SnapshotTime,
        [hashtable]$Metrics
    )

    # Handle NULL values for optional fields
    $oldestZombie = if ($null -eq $Metrics.oldest_zombie_idle_min) { "NULL" } else { $Metrics.oldest_zombie_idle_min }
    $oldestOpenTran = if ($null -eq $Metrics.oldest_open_tran_min) { "NULL" } else { $Metrics.oldest_open_tran_min }

    $query = @"
INSERT INTO ServerOps.Activity_DMV_ConnectionHealth
    (server_id, server_name, snapshot_dttm, total_sessions, sleeping_sessions, running_sessions,
     zombie_count, oldest_zombie_idle_min, sessions_with_open_tran, oldest_open_tran_min,
     jdbc_total, jdbc_sleeping, jdbc_zombie)
VALUES
    ($ServerId, '$ServerName', '$($SnapshotTime.ToString("yyyy-MM-dd HH:mm:ss"))',
     $($Metrics.total_sessions), $($Metrics.sleeping_sessions), $($Metrics.running_sessions),
     $($Metrics.zombie_count), $oldestZombie, $($Metrics.sessions_with_open_tran), $oldestOpenTran,
     $($Metrics.jdbc_total), $($Metrics.jdbc_sleeping), $($Metrics.jdbc_zombie))
"@

    return Invoke-SqlNonQuery -Query $query
}

<# ============================================================================
   FUNCTIONS: WAIT STATS METRICS
   ----------------------------------------------------------------------------
   Collects nonzero wait-stats rows from sys.dm_os_wait_stats and persists them
   to Activity_DMV_WaitStats, returning the inserted row count.
   Prefix: srv
   ============================================================================ #>

# Collects nonzero wait-stats rows from sys.dm_os_wait_stats for one instance.
function Get-srv_WaitStatsMetrics {
    param([string]$SqlInstanceName)

    $query = @"
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_time_ms > 0
"@

    try {
        $results = Get-SqlData -Query $query -Instance $SqlInstanceName -DatabaseName "master"

        if ($null -ne $results) {
            $waitStats = @()
            foreach ($row in $results) {
                $waitStats += @{
                    wait_type = $row.wait_type
                    waiting_tasks_count = $row.waiting_tasks_count
                    wait_time_ms = $row.wait_time_ms
                    signal_wait_time_ms = $row.signal_wait_time_ms
                }
            }
            return $waitStats
        }
        return $null
    }
    catch {
        Write-Log "    Wait stats collection failed: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Inserts wait-stats rows into Activity_DMV_WaitStats; returns the inserted count.
function Write-srv_WaitStatsMetrics {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [datetime]$SnapshotTime,
        [array]$WaitStats
    )

    $insertedCount = 0

    foreach ($stat in $WaitStats) {
        $waitType = $stat.wait_type -replace "'", "''"

        $query = @"
INSERT INTO ServerOps.Activity_DMV_WaitStats
    (server_id, server_name, snapshot_dttm, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms)
VALUES
    ($ServerId, '$ServerName', '$($SnapshotTime.ToString("yyyy-MM-dd HH:mm:ss"))',
     '$waitType', $($stat.waiting_tasks_count), $($stat.wait_time_ms), $($stat.signal_wait_time_ms))
"@

        $result = Invoke-SqlNonQuery -Query $query
        if ($result) { $insertedCount++ }
    }

    return $insertedCount
}

<# ============================================================================
   FUNCTIONS: IO STATS METRICS
   ----------------------------------------------------------------------------
   Collects per-database file I/O stats from sys.dm_io_virtual_file_stats and
   persists them to Activity_DMV_IO_Stats, returning the inserted row count.
   Prefix: srv
   ============================================================================ #>

# Collects per-database file I/O stats from sys.dm_io_virtual_file_stats for one instance.
function Get-srv_IOStatsMetrics {
    param([string]$SqlInstanceName)

    $query = @"
SELECT
    DB_NAME(vfs.database_id) AS database_name,
    CASE WHEN mf.type = 0 THEN 'DATA' ELSE 'LOG' END AS file_type,
    SUM(vfs.num_of_reads) AS num_of_reads,
    SUM(vfs.num_of_writes) AS num_of_writes,
    SUM(vfs.num_of_bytes_read) AS num_of_bytes_read,
    SUM(vfs.num_of_bytes_written) AS num_of_bytes_written,
    SUM(vfs.io_stall_read_ms) AS io_stall_read_ms,
    SUM(vfs.io_stall_write_ms) AS io_stall_write_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
INNER JOIN sys.master_files mf ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
WHERE vfs.database_id > 0
  AND DB_NAME(vfs.database_id) IS NOT NULL
GROUP BY vfs.database_id, mf.type
"@

    try {
        $results = Get-SqlData -Query $query -Instance $SqlInstanceName -DatabaseName "master"

        if ($null -ne $results) {
            $ioStats = @()
            foreach ($row in $results) {
                $ioStats += @{
                    database_name = $row.database_name
                    file_type = $row.file_type
                    num_of_reads = $row.num_of_reads
                    num_of_writes = $row.num_of_writes
                    num_of_bytes_read = $row.num_of_bytes_read
                    num_of_bytes_written = $row.num_of_bytes_written
                    io_stall_read_ms = $row.io_stall_read_ms
                    io_stall_write_ms = $row.io_stall_write_ms
                }
            }
            return $ioStats
        }
        return $null
    }
    catch {
        Write-Log "    I/O stats collection failed: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Inserts I/O-stats rows into Activity_DMV_IO_Stats; returns the inserted count.
function Write-srv_IOStatsMetrics {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [datetime]$SnapshotTime,
        [array]$IOStats
    )

    $insertedCount = 0

    foreach ($stat in $IOStats) {
        $dbName = $stat.database_name -replace "'", "''"

        $query = @"
INSERT INTO ServerOps.Activity_DMV_IO_Stats
    (server_id, server_name, snapshot_dttm, database_name, file_type,
     num_of_reads, num_of_writes, num_of_bytes_read, num_of_bytes_written,
     io_stall_read_ms, io_stall_write_ms)
VALUES
    ($ServerId, '$ServerName', '$($SnapshotTime.ToString("yyyy-MM-dd HH:mm:ss"))',
     '$dbName', '$($stat.file_type)',
     $($stat.num_of_reads), $($stat.num_of_writes), $($stat.num_of_bytes_read), $($stat.num_of_bytes_written),
     $($stat.io_stall_read_ms), $($stat.io_stall_write_ms))
"@

        $result = Invoke-SqlNonQuery -Query $query
        if ($result) { $insertedCount++ }
    }

    return $insertedCount
}

<# ============================================================================
   FUNCTIONS: FOOTPRINT METRICS
   ----------------------------------------------------------------------------
   Collects per-session footprint rows for xFACts sessions and persists them to
   Activity_DMV_xFACts, returning the inserted row count.
   Prefix: srv
   ============================================================================ #>

# Collects per-session footprint rows for xFACts sessions on one instance.
function Get-srv_FootprintMetrics {
    param([string]$SqlInstanceName)

    $query = @"
SELECT
    session_id,
    program_name,
    login_name,
    status,
    cpu_time AS cpu_time_ms,
    reads,
    logical_reads,
    writes,
    last_request_start_time AS last_request_start,
    last_request_end_time AS last_request_end,
    open_transaction_count,
    memory_usage AS memory_usage_pages
FROM sys.dm_exec_sessions
WHERE session_id > 50
  AND program_name LIKE 'xFACts%'
"@

    try {
        $results = Get-SqlData -Query $query -Instance $SqlInstanceName -DatabaseName "master"

        if ($null -ne $results) {
            $sessions = @()
            foreach ($row in @($results)) {
                $sessions += @{
                    session_id = $row.session_id
                    program_name = $row.program_name
                    login_name = if ($row.login_name -is [DBNull]) { $null } else { $row.login_name }
                    status = if ($row.status -is [DBNull]) { $null } else { $row.status }
                    cpu_time_ms = $row.cpu_time_ms
                    reads = $row.reads
                    logical_reads = $row.logical_reads
                    writes = $row.writes
                    last_request_start = if ($row.last_request_start -is [DBNull]) { $null } else { $row.last_request_start }
                    last_request_end = if ($row.last_request_end -is [DBNull]) { $null } else { $row.last_request_end }
                    open_transaction_count = $row.open_transaction_count
                    memory_usage_pages = $row.memory_usage_pages
                }
            }
            return $sessions
        }
        return @()
    }
    catch {
        Write-Log "    Footprint metrics collection failed: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# Inserts xFACts session footprint rows into Activity_DMV_xFACts; returns the inserted count.
function Write-srv_FootprintMetrics {
    param(
        [int]$ServerId,
        [string]$ServerName,
        [datetime]$SnapshotTime,
        [array]$Sessions
    )

    $insertedCount = 0

    foreach ($s in $Sessions) {
        $progName = ($s.program_name -replace "'", "''")
        $loginName = if ($null -eq $s.login_name) { "NULL" } else { "'$($s.login_name -replace "'", "''")'" }
        $status = if ($null -eq $s.status) { "NULL" } else { "'$($s.status)'" }
        $reqStart = if ($null -eq $s.last_request_start) { "NULL" } else { "'$($s.last_request_start.ToString("yyyy-MM-dd HH:mm:ss.fff"))'" }
        $reqEnd = if ($null -eq $s.last_request_end) { "NULL" } else { "'$($s.last_request_end.ToString("yyyy-MM-dd HH:mm:ss.fff"))'" }

        $query = @"
INSERT INTO ServerOps.Activity_DMV_xFACts
    (server_id, server_name, snapshot_dttm, session_id, program_name, login_name,
     status, cpu_time_ms, reads, logical_reads, writes,
     last_request_start, last_request_end, open_transaction_count, memory_usage_pages)
VALUES
    ($ServerId, '$ServerName', '$($SnapshotTime.ToString("yyyy-MM-dd HH:mm:ss"))',
     $($s.session_id), '$progName', $loginName,
     $status, $($s.cpu_time_ms), $($s.reads), $($s.logical_reads), $($s.writes),
     $reqStart, $reqEnd, $($s.open_transaction_count), $($s.memory_usage_pages))
"@

        $result = Invoke-SqlNonQuery -Query $query
        if ($result) { $insertedCount++ }
    }

    return $insertedCount
}

<# ============================================================================
   EXECUTION: SCRIPT EXECUTION
   ----------------------------------------------------------------------------
   Main collection flow: verify the master switch, load configuration, resolve
   the server list, then per server collect and persist each DMV family. After
   collection runs incident correlation and reports the orchestrator callback.
   Prefix: (none)
   ============================================================================ #>

$scriptStart = Get-Date

Write-Log "========================================"
Write-Log "xFACts DMV Metrics Collection"
Write-Log "========================================"

# -- Step 0: Check master switch --

Write-Log "Checking server-level Activity enable flag..."

$serverCheck = Get-SqlData -Query @"
SELECT COUNT(*) AS enabled_count
FROM dbo.ServerRegistry
WHERE is_active = 1
  AND serverops_activity_enabled = 1
  AND server_type = 'SQL_SERVER'
"@

if (-not $serverCheck -or $serverCheck.enabled_count -eq 0) {
    Write-Log "Activity monitoring is not enabled on any server (serverops_activity_enabled = 0). Exiting." "WARN"
    exit 0
}

Write-Log "  Found $($serverCheck.enabled_count) server(s) with Activity monitoring enabled."

# -- Step 1: Load configuration --

Write-Log "Loading configuration..."

# Default zombie idle threshold when GlobalConfig has no value
$zombieIdleThreshold = Get-GlobalConfigValue -Module 'ServerOps' -Category 'Activity_DMV' -SettingName 'threshold_zombie_idle_minutes'
if ($null -eq $zombieIdleThreshold) {
    $zombieIdleThreshold = 60
}
$zombieIdleThreshold = [int]$zombieIdleThreshold

Write-Log "  Zombie idle threshold: $zombieIdleThreshold minutes"

# -- Step 2: Get list of servers to monitor --

Write-Log "Retrieving server list..."

$servers = Get-SqlData -Query @"
SELECT
    server_id,
    server_name,
    instance_name,
    server_type,
    environment
FROM dbo.ServerRegistry
WHERE is_active = 1
  AND serverops_activity_enabled = 1
  AND server_type = 'SQL_SERVER'
ORDER BY server_id
"@

if ($null -eq $servers -or @($servers).Count -eq 0) {
    Write-Log "No active servers configured for activity monitoring. Exiting." "WARN"
    exit 0
}

$serverCount = @($servers).Count
Write-Log "Found $serverCount server(s) to monitor."

# -- Step 3: Collect metrics from each server --

$snapshotTime = Get-Date
$successServers = 0
$failedServers = @()

foreach ($server in $servers) {
    $serverName = $server.server_name
    $serverId = $server.server_id
    $instanceName = if ($server.instance_name -isnot [DBNull]) { $server.instance_name } else { $null }

    $sqlInstanceName = Get-SqlInstanceName -ServerName $serverName -InstanceName $instanceName

    Write-Log "Collecting from: $sqlInstanceName (ID: $serverId)"

    $serverSuccess = $true

    # -- Step 3a: Memory metrics --

    Write-Log "  Collecting memory metrics..."
    $memoryMetrics = Get-srv_MemoryMetrics -SqlInstanceName $sqlInstanceName

    if ($null -ne $memoryMetrics) {
        $insertResult = Write-srv_MemoryMetrics -ServerId $serverId -ServerName $serverName -SnapshotTime $snapshotTime -Metrics $memoryMetrics
        if ($insertResult) {
            Write-Log "    PLE: $($memoryMetrics.ple_seconds)s, Memory Grants Pending: $($memoryMetrics.memory_grants_pending)"
        }
        else {
            $serverSuccess = $false
        }
    }
    else {
        $serverSuccess = $false
    }

    # -- Step 3b: Workload metrics --

    Write-Log "  Collecting workload metrics..."
    $workloadMetrics = Get-srv_WorkloadMetrics -SqlInstanceName $sqlInstanceName

    if ($null -ne $workloadMetrics) {
        $insertResult = Write-srv_WorkloadMetrics -ServerId $serverId -ServerName $serverName -SnapshotTime $snapshotTime -Metrics $workloadMetrics
        if ($insertResult) {
            Write-Log "    Connections: $($workloadMetrics.user_connections), Blocked: $($workloadMetrics.blocked_session_count), Active: $($workloadMetrics.active_request_count)"
        }
        else {
            $serverSuccess = $false
        }
    }
    else {
        $serverSuccess = $false
    }

    # -- Step 3c: Connection health metrics --

    Write-Log "  Collecting connection health metrics..."
    $connectionMetrics = Get-srv_ConnectionHealthMetrics -SqlInstanceName $sqlInstanceName -ZombieIdleThresholdMinutes $zombieIdleThreshold

    if ($null -ne $connectionMetrics) {
        $insertResult = Write-srv_ConnectionHealthMetrics -ServerId $serverId -ServerName $serverName -SnapshotTime $snapshotTime -Metrics $connectionMetrics
        if ($insertResult) {
            Write-Log "    Sessions: $($connectionMetrics.total_sessions), Zombies: $($connectionMetrics.zombie_count), JDBC Zombies: $($connectionMetrics.jdbc_zombie)"
        }
        else {
            $serverSuccess = $false
        }
    }
    else {
        $serverSuccess = $false
    }

    # Track success/failure
    if ($serverSuccess) {
        $successServers++
    }
    else {
        $failedServers += $serverName
    }

    # -- Step 3d: Wait stats --

    Write-Log "  Collecting wait stats..."
    $waitStatsMetrics = Get-srv_WaitStatsMetrics -SqlInstanceName $sqlInstanceName

    if ($null -ne $waitStatsMetrics -and $waitStatsMetrics.Count -gt 0) {
        $insertedCount = Write-srv_WaitStatsMetrics -ServerId $serverId -ServerName $serverName -SnapshotTime $snapshotTime -WaitStats $waitStatsMetrics
        Write-Log "    Inserted $insertedCount wait types"
    }
    else {
        Write-Log "    No wait stats collected" "WARN"
        $serverSuccess = $false
    }

    # -- Step 3e: I/O stats --

    Write-Log "  Collecting I/O stats..."
    $ioStatsMetrics = Get-srv_IOStatsMetrics -SqlInstanceName $sqlInstanceName

    if ($null -ne $ioStatsMetrics -and $ioStatsMetrics.Count -gt 0) {
        $insertedCount = Write-srv_IOStatsMetrics -ServerId $serverId -ServerName $serverName -SnapshotTime $snapshotTime -IOStats $ioStatsMetrics
        Write-Log "    Inserted $insertedCount database/file type rows"
    }
    else {
        Write-Log "    No I/O stats collected" "WARN"
        $serverSuccess = $false
    }

    # -- Step 3f: xFACts footprint --

    Write-Log "  Collecting xFACts footprint..."
    $footprintSessions = Get-srv_FootprintMetrics -SqlInstanceName $sqlInstanceName

    if ($footprintSessions.Count -gt 0) {
        $insertedCount = Write-srv_FootprintMetrics -ServerId $serverId -ServerName $serverName -SnapshotTime $snapshotTime -Sessions $footprintSessions
        Write-Log "    Captured $insertedCount xFACts session(s)"
    }
    else {
        Write-Log "    No xFACts sessions found on $serverName"
    }
}

# -- Step 4: Incident correlation --

Write-Log "Running incident correlation..."

try {
    $correlationQuery = "EXEC ServerOps.sp_Activity_CorrelateIncidents @preview_only = 0"
    Invoke-SqlNonQuery -Query $correlationQuery | Out-Null
    Write-Log "Incident correlation complete."
}
catch {
    Write-Log "Incident correlation failed: $($_.Exception.Message)" "WARN"
    # Don't fail the whole script - collection succeeded, correlation is secondary
}

# -- Summary --

Write-Log "========================================"
Write-Log "Collection Complete"
Write-Log "  Servers attempted: $serverCount"
Write-Log "  Servers successful: $successServers"
Write-Log "  Servers failed: $($failedServers.Count)"
Write-Log "========================================"

if ($failedServers.Count -gt 0) {
    Write-Log "Failed servers: $($failedServers -join ', ')" "WARN"
}

# -- Orchestrator callback --

if ($TaskId -gt 0) {
    $totalMs = [int]((New-TimeSpan -Start $scriptStart -End (Get-Date)).TotalMilliseconds)
    $outputMsg = "Servers: $successServers/$serverCount"
    Complete-OrchestratorTask -ServerInstance $ServerInstance -Database $Database `
        -TaskId $TaskId -ProcessId $ProcessId `
        -Status "SUCCESS" -DurationMs $totalMs `
        -Output $outputMsg
}
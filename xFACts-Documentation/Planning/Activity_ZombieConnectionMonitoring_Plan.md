# Activity Component: Zombie Connection Monitoring

## Problem Statement

On January 9, 2026, a production outage was traced to **802 zombie JDBC connections** - sessions that had been checked out from the JBoss connection pool but never returned. Some had been idle for 62+ days.

**Impact:**
- Application connection pool exhausted
- New user requests queued waiting for connections
- Users experienced "frozen" application
- SQL Server itself was healthy (no blocking, adequate workers)

**Root cause:** JBoss connection pool leak - connections checked out but never properly closed by application code.

**Discovery gap:** Existing monitoring (XE sessions, blocking detection) couldn't see this. The problem was invisible until it caused an outage.

---

## Proposed Solution

Add DMV-based connection health monitoring to the Activity component, running via the Master Orchestrator.

### Monitoring Targets

| Metric | Source | Purpose |
|--------|--------|---------|
| Zombie connections | sys.dm_exec_sessions | Detect pool leaks |
| Open transaction age | sys.dm_exec_sessions | Detect abandoned transactions |
| Connection count by app | sys.dm_exec_sessions | Trend connection usage |
| Sleeping vs active ratio | sys.dm_exec_sessions | Detect pool saturation |

### Zombie Definition

A "zombie" connection meets ALL of these criteria:
- `status = 'sleeping'`
- `open_transaction_count = 0`
- `last_request_end_time` older than threshold (default: 1 hour)
- Optionally filtered by `program_name` (e.g., JDBC only)

---

## Design Options

### Option A: Logging Only

**Behavior:** Capture snapshots, no automatic action. Human reviews data and takes manual action.

**Pros:**
- Safest approach
- Provides trending data
- No risk of killing legitimate connections

**Cons:**
- Requires human intervention during outage
- May not catch issues outside business hours

### Option B: Log + Auto-Kill Above Threshold

**Behavior:** Capture snapshots. When zombie count exceeds threshold, automatically kill oldest zombies.

**Pros:**
- Self-healing during off-hours
- Prevents outages proactively

**Cons:**
- Risk of killing legitimate long-running idle sessions
- Need careful threshold tuning

### Option C: Log + Staged Response

**Behavior:** Capture snapshots with escalating actions based on severity:

| Zombie Count | Action |
|--------------|--------|
| 0-99 | Log only |
| 100-299 | Log + flag for review |
| 300-499 | Log + auto-kill zombies > 4 hours idle |
| 500+ | Log + auto-kill zombies > 1 hour idle |

**Pros:**
- Graduated response matches severity
- Light touch for minor accumulation
- Aggressive only when critical

**Cons:**
- More complex logic
- More configuration to maintain

---

## Proposed Thresholds (Starting Point)

| Setting | Proposed Value | Rationale |
|---------|----------------|-----------|
| zombie_idle_threshold_minutes | 60 | 1 hour idle = definitely abandoned |
| zombie_warning_count | 100 | Worth noting, not critical |
| zombie_critical_count | 300 | Approaching pool exhaustion |
| zombie_emergency_count | 500 | Immediate action required |
| auto_kill_enabled | 0 | Start with logging only |
| auto_kill_idle_threshold_minutes | 240 | Only kill if idle > 4 hours |

---

## Proposed Table Structure

### Activity_DMV_ConnectionHealth

Periodic snapshots of connection pool health per server.

```sql
CREATE TABLE ServerOps.Activity_DMV_ConnectionHealth (
    snapshot_id BIGINT IDENTITY PRIMARY KEY,
    server_id INT NOT NULL,                    -- FK to ServerRegistry
    server_name VARCHAR(128) NOT NULL,
    snapshot_dttm DATETIME NOT NULL DEFAULT GETDATE(),
    
    -- Overall metrics
    total_sessions INT,
    sleeping_sessions INT,
    running_sessions INT,
    
    -- Zombie metrics (configurable idle threshold)
    zombie_count INT,
    zombie_oldest_idle_minutes INT,
    
    -- Open transaction metrics
    sessions_with_open_tran INT,
    oldest_open_tran_minutes INT,
    
    -- Top program breakdown (JSON or separate table?)
    jdbc_total INT,
    jdbc_sleeping INT,
    jdbc_zombie INT,
    
    -- Actions taken this cycle
    zombies_killed INT DEFAULT 0,
    
    CONSTRAINT FK_Activity_DMV_ConnectionHealth_Server 
        FOREIGN KEY (server_id) REFERENCES ServerOps.ServerRegistry(server_id)
);
```

### Activity_DMV_ZombieKillLog

Audit trail when auto-kill is enabled.

```sql
CREATE TABLE ServerOps.Activity_DMV_ZombieKillLog (
    kill_id BIGINT IDENTITY PRIMARY KEY,
    server_id INT NOT NULL,
    server_name VARCHAR(128) NOT NULL,
    killed_dttm DATETIME NOT NULL DEFAULT GETDATE(),
    session_id INT NOT NULL,
    login_name NVARCHAR(128),
    program_name NVARCHAR(128),
    login_time DATETIME,
    last_request_end_time DATETIME,
    idle_minutes INT,
    kill_reason VARCHAR(50)           -- 'ZOMBIE_THRESHOLD', 'EMERGENCY', etc.
);
```

---

## Implementation Components

### New Objects

| Object | Type | Purpose |
|--------|------|---------|
| Activity_DMV_ConnectionHealth | Table | Snapshot storage |
| Activity_DMV_ZombieKillLog | Table | Kill audit trail |
| sp_Activity_MonitorConnections | Procedure | Main monitoring logic |
| Collect-ConnectionHealth.ps1 | Script | Optional: collect from all servers |

### Configuration (Activity_Config additions)

| Setting | Default | Description |
|---------|---------|-------------|
| connection_monitor_enabled | 1 | Master enable/disable |
| zombie_idle_threshold_minutes | 60 | Minutes idle to qualify as zombie |
| zombie_warning_count | 100 | Warning threshold |
| zombie_critical_count | 300 | Critical threshold |
| zombie_auto_kill_enabled | 0 | Enable automatic killing |
| zombie_auto_kill_idle_minutes | 240 | Minimum idle time before auto-kill |
| zombie_program_filter | 'Microsoft JDBC Driver for SQL Server' | Which programs to monitor (NULL = all) |

### Orchestrator Registration

| Process | Frequency | Description |
|---------|-----------|-------------|
| sp_Activity_MonitorConnections | CONTINUOUS (5 min) | Connection health check |

---

## Collection Approach Options

### Option 1: Local Procedure (simpler)

Run `sp_Activity_MonitorConnections` on DM-PROD-DB only. It queries local DMVs and handles the local server.

**Limitation:** Only monitors one server unless procedure includes linked server queries.

### Option 2: PowerShell Multi-Server (consistent with XE collection)

`Collect-ConnectionHealth.ps1` connects to each server in ServerRegistry (where monitor_activity=1), collects DMV data, inserts into central table.

**Advantage:** Consistent with existing XE collection pattern.

### Option 3: Hybrid

- PowerShell collects read-only snapshot data from all servers
- Local procedure on each server handles auto-kill (if enabled)

---

## Questions to Resolve

1. **Auto-kill scope:** Kill all zombie programs or only JDBC?

2. **Frequency:** Every 5 minutes (with orchestrator) or less frequent?

3. **Multi-server:** Monitor all 5 servers or just DM-PROD-DB where the app connects?

4. **Open transaction handling:** Should we track/alert on long-idle sessions WITH open transactions separately? (These are more dangerous but can't be safely killed)

5. **Retention:** How long to keep ConnectionHealth snapshots? (30 days? 90 days?)

6. **Immediate action:** Should we implement auto-kill now or start with logging only and add auto-kill after we have baseline data?

---

## Recommended Starting Point

1. **Create tables:** Activity_DMV_ConnectionHealth, Activity_DMV_ZombieKillLog
2. **Create procedure:** sp_Activity_MonitorConnections (logging only initially)
3. **Register with orchestrator:** 5-minute frequency
4. **Run for 1-2 weeks:** Establish baseline zombie accumulation rate
5. **Tune thresholds:** Based on observed patterns
6. **Enable auto-kill:** After confidence in thresholds

---

## Appendix: Discovery Queries

### Current Zombie Count
```sql
SELECT COUNT(*) AS zombie_count
FROM sys.dm_exec_sessions
WHERE program_name = 'Microsoft JDBC Driver for SQL Server'
  AND status = 'sleeping'
  AND open_transaction_count = 0
  AND DATEDIFF(MINUTE, last_request_end_time, GETDATE()) > 60;
```

### Connection Breakdown by Program
```sql
SELECT 
    program_name,
    COUNT(*) AS total,
    SUM(CASE WHEN status = 'sleeping' THEN 1 ELSE 0 END) AS sleeping,
    SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running,
    SUM(CASE WHEN status = 'sleeping' 
             AND open_transaction_count = 0 
             AND DATEDIFF(MINUTE, last_request_end_time, GETDATE()) > 60 
        THEN 1 ELSE 0 END) AS zombies
FROM sys.dm_exec_sessions
WHERE session_id > 50
GROUP BY program_name
ORDER BY total DESC;
```

### Generate Kill Statements (Manual)
```sql
SELECT 'KILL ' + CAST(session_id AS VARCHAR(10)) + ';' AS kill_cmd
FROM sys.dm_exec_sessions
WHERE program_name = 'Microsoft JDBC Driver for SQL Server'
  AND status = 'sleeping'
  AND open_transaction_count = 0
  AND DATEDIFF(MINUTE, last_request_end_time, GETDATE()) > 60;
```

---

*Document created: January 9, 2026*
*Status: Planning*

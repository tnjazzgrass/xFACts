# Replication Monitoring Implementation Plan

> Architecture and implementation plan for adding SQL Server transactional replication monitoring to the xFACts platform. Designed to instrument existing replications immediately while providing the foundation for a future reporting server decoupling initiative.

**Created:** February 17, 2026

---

## Background

### The Problem

The xFACts AG environment (DM-PROD-DB ↔ DM-PROD-REP) runs as a two-node synchronous replica. DM-PROD-REP serves as the reporting server, which creates a fundamental tension: every commit on the primary must wait for the secondary to harden the log. When REP is busy servicing SSRS reports or BIDATA queries, that hardening is delayed — producing the HADR_SYNC_COMMIT waits that xFACts Activity Monitoring already captures as a daily problem.

A potential path forward is decoupling reporting from the AG by replicating the necessary tables to a standalone Standard Edition server via transactional replication. This eliminates the synchronous commit dependency for reporting workloads entirely.

### Current Replication Landscape

Replication is not new to this environment. Several publications already exist:

| Replication | Publisher | Subscriber | Purpose | Articles |
|-------------|-----------|------------|---------|----------|
| BIDATA subset | DM-PROD-DB | DM-PROD-REP | Source tables for nightly BIDATA warehouse rebuild | ~100 |
| POC reporting | DM-PROD-DB | TBD | Proof-of-concept for full reporting offload | ~150 |

The BIDATA replication runs alongside the AG and has been operational for some time. The POC was a separate investigation that identified the full set of tables needed to replace direct crs5_oltp reporting queries.

### Why Monitor It

1. **Prove stability.** Stakeholders have voiced concerns about replication reliability. Continuous monitoring with historical data provides evidence: "replication has been running at sub-10-second latency with 99.9% uptime for the past 6 months."
2. **Catch problems before users do.** Agent failures, growing undistributed command queues, and latency spikes should trigger immediate alerts — not wait for a report to return stale data.
3. **Baseline before expansion.** If the reporting decoupling initiative moves forward, having established baselines on the existing replications makes capacity planning and SLA conversations data-driven.
4. **Fits the existing architecture.** The xFACts collect/evaluate pattern with Teams alerting and Control Center visibility is purpose-built for exactly this kind of operational monitoring.

---

## Monitoring Architecture

### Where It Lives

**Schema:** ServerOps (with `Replication_` table prefix)

Rationale: Replication monitoring is fundamentally server infrastructure health, alongside backups, disk space, and index maintenance. It doesn't warrant its own schema unless scope grows significantly. The `Replication_` prefix keeps it logically grouped within ServerOps.

### Monitoring Approach: Three Layers

Replication health isn't captured by a single metric. The plan uses three complementary monitoring layers:

**Layer 1 — Agent Health (are the agents running?)**
The Log Reader Agent and Distribution Agent are SQL Agent jobs. If either stops, replication stops. This is the most basic and most critical check.

**Layer 2 — Queue Depth (is work backing up?)**
The distribution database holds commands waiting to be delivered to subscribers. A growing queue means the Distribution Agent can't keep up — either the subscriber is slow, the network is congested, or something is blocking. This is the early warning system.

**Layer 3 — End-to-End Latency (how far behind is the subscriber?)**
Tracer tokens measure actual publisher-to-subscriber latency by injecting a marker into the transaction log and timing how long it takes to arrive at the subscriber. This is the definitive "how stale is the data" measurement.

Each layer catches different failure modes:

| Failure | Agent Health | Queue Depth | Latency |
|---------|-------------|-------------|---------|
| Agent stopped | ✓ Immediate | ✓ Commands grow | ✓ Token never arrives |
| Subscriber blocking/slow | ✗ Agents running | ✓ Commands grow | ✓ Latency increases |
| Network issue | ✗ May look fine | ✓ Commands grow | ✓ Latency increases |
| Large transaction flood | ✗ Agents running | ✓ Spike visible | ✓ Temporary spike |
| Publication misconfigured | ✗ Agents running | ✗ No commands | ✓ Token fails |

---

## Phase 1: Foundation (Tables + Collector)

### Tables

#### ServerOps.Replication_AgentStatus

Snapshot of agent health captured each collection cycle.

| Column | Type | Purpose |
|--------|------|---------|
| agent_status_id | INT IDENTITY | PK |
| publication_name | NVARCHAR(128) | Publication being monitored |
| agent_type | VARCHAR(20) | 'LogReader' or 'Distribution' |
| agent_name | NVARCHAR(256) | Agent job name |
| status | VARCHAR(20) | Running, Stopped, Failed, Retrying |
| last_action_message | NVARCHAR(MAX) | Most recent agent message/comment |
| last_action_time | DATETIME | When the last action occurred |
| collected_dttm | DATETIME | When this snapshot was taken |

#### ServerOps.Replication_QueueDepth

Undistributed command counts per publication/subscriber.

| Column | Type | Purpose |
|--------|------|---------|
| queue_depth_id | INT IDENTITY | PK |
| publication_name | NVARCHAR(128) | Publication name |
| subscriber_server | NVARCHAR(128) | Subscriber server name |
| subscriber_db | NVARCHAR(128) | Subscriber database name |
| undistributed_commands | BIGINT | Commands waiting in distribution DB |
| delivered_commands | BIGINT | Commands successfully delivered (current window) |
| delivery_rate | FLOAT | Average commands/second |
| delivery_latency_ms | INT | Current delivery latency in milliseconds |
| collected_dttm | DATETIME | When this snapshot was taken |

#### ServerOps.Replication_LatencyHistory

Tracer token results for end-to-end latency measurement.

| Column | Type | Purpose |
|--------|------|---------|
| latency_id | INT IDENTITY | PK |
| publication_name | NVARCHAR(128) | Publication name |
| tracer_token_id | INT | Token ID from sp_posttracertoken |
| publisher_commit | DATETIME | When token committed at publisher |
| distributor_commit | DATETIME | When token arrived at distributor |
| subscriber_commit | DATETIME | When token arrived at subscriber |
| publisher_to_distributor_ms | INT | Latency: publisher → distributor |
| distributor_to_subscriber_ms | INT | Latency: distributor → subscriber |
| total_latency_ms | INT | End-to-end latency |
| collected_dttm | DATETIME | When this measurement was recorded |

#### ServerOps.Replication_Status

Collector execution tracking (standard xFACts pattern).

| Column | Type | Purpose |
|--------|------|---------|
| status_id | INT IDENTITY | PK |
| collector_name | VARCHAR(50) | 'Collect-ReplicationHealth' |
| last_execution_dttm | DATETIME | When collector last ran |
| last_execution_status | VARCHAR(20) | SUCCESS, FAILED |
| last_error_message | NVARCHAR(MAX) | Error details if failed |
| publications_checked | INT | Count of publications evaluated |
| alerts_generated | INT | Alerts fired this cycle |
| next_tracer_dttm | DATETIME | When next tracer token should be posted |

### Collector Script: Collect-ReplicationHealth.ps1

Single collector that performs all three monitoring layers per cycle:

**Every cycle (60 seconds suggested):**
1. Query `distribution.dbo.MSdistribution_agents` joined with agent job status for agent health
2. Query `distribution.dbo.MSdistribution_status` for undistributed command counts per agent/publication
3. Insert snapshots into Replication_AgentStatus and Replication_QueueDepth

**Every N cycles (5 minutes suggested, configurable via GlobalConfig):**
4. Post tracer tokens via `sp_posttracertoken` for each publication
5. Wait configurable delay (default 15 seconds)
6. Collect results via `sp_helptracertokenhistory`
7. Insert into Replication_LatencyHistory
8. Clean up old tokens via `sp_deletetracertokenhistory`

The tracer token cycle runs less frequently because tokens need time to traverse the pipeline and posting too frequently adds unnecessary overhead. The interval is configurable — could be tightened during investigation periods.

**Source queries (distribution database):**

Agent status:
```sql
-- Agent health from distribution database
SELECT 
    a.name AS agent_name,
    a.publication,
    CASE 
        WHEN h.runstatus = 1 THEN 'Started'
        WHEN h.runstatus = 2 THEN 'Running' 
        WHEN h.runstatus = 3 THEN 'Idle'
        WHEN h.runstatus = 4 THEN 'Retrying'
        WHEN h.runstatus = 5 THEN 'Failed'
        WHEN h.runstatus = 6 THEN 'Stopped'
        ELSE 'Unknown'
    END AS status,
    h.comments AS last_action_message,
    h.[time] AS last_action_time
FROM distribution.dbo.MSdistribution_agents a
CROSS APPLY (
    SELECT TOP 1 runstatus, comments, [time]
    FROM distribution.dbo.MSdistribution_history
    WHERE agent_id = a.id
    ORDER BY [time] DESC
) h
WHERE a.subscriber_db NOT LIKE '%virtual%'
```

Queue depth:
```sql
-- Undistributed commands per agent
SELECT 
    a.publication,
    UPPER(srv.name) AS subscriber_server,
    a.subscriber_db,
    s.UndelivCmdsInDistDB AS undistributed_commands,
    s.DelivCmdsInDistDB AS delivered_commands,
    h.delivery_rate,
    h.delivery_latency
FROM distribution.dbo.MSdistribution_status s
INNER JOIN distribution.dbo.MSdistribution_agents a ON a.id = s.agent_id
INNER JOIN master.sys.servers srv ON srv.server_id = a.subscriber_id
CROSS APPLY (
    SELECT TOP 1 delivery_rate, delivery_latency
    FROM distribution.dbo.MSdistribution_history
    WHERE agent_id = a.id AND runstatus IN (2, 3, 4)
    ORDER BY [time] DESC
) h
WHERE a.subscriber_db NOT LIKE '%virtual%'
```

Tracer token latency:
```sql
-- Results from MStracer_tokens + MStracer_history
SELECT 
    t.publisher_commit,
    t.distributor_commit,
    h.subscriber_commit,
    DATEDIFF(ms, t.publisher_commit, t.distributor_commit) AS pub_to_dist_ms,
    DATEDIFF(ms, t.distributor_commit, h.subscriber_commit) AS dist_to_sub_ms,
    DATEDIFF(ms, t.publisher_commit, h.subscriber_commit) AS total_ms
FROM distribution.dbo.MStracer_tokens t
JOIN distribution.dbo.MStracer_history h ON t.tracer_id = h.parent_tracer_id
WHERE t.tracer_id = @token_id
```

### GlobalConfig Settings

| Key | Default | Purpose |
|-----|---------|---------|
| replication_collection_enabled | 1 | Master enable/disable |
| replication_tracer_interval_minutes | 5 | How often to post tracer tokens |
| replication_tracer_wait_seconds | 15 | How long to wait after posting before collecting results |
| replication_queue_warning_threshold | 5000 | Undistributed commands: warning |
| replication_queue_critical_threshold | 50000 | Undistributed commands: critical |
| replication_latency_warning_ms | 30000 | End-to-end latency: warning (30 sec) |
| replication_latency_critical_ms | 120000 | End-to-end latency: critical (2 min) |
| replication_agent_down_alert_minutes | 5 | How long agent can be down before alert |

> **Note:** Threshold defaults are starting points. The first few weeks of collection will establish baselines that should inform proper threshold tuning. This is exactly the pattern used with Index Maintenance and Backup Monitoring — deploy, observe, then tighten.

---

## Phase 2: Alert Evaluation

### Stored Procedure: sp_Replication_EvaluateHealth

Evaluates collected data and queues Teams alerts. Called by the collector after each cycle. Follows the standard xFACts evaluate pattern.

**Alert Conditions:**

| Condition | Severity | Alert Content |
|-----------|----------|---------------|
| Agent stopped for > threshold minutes | Critical | Which agent, which publication, how long, last error message |
| Agent in Retrying status | Warning | Agent name, retry count, last error |
| Undistributed commands > warning threshold | Warning | Publication, subscriber, command count, delivery rate |
| Undistributed commands > critical threshold | Critical | Same as warning + estimated time to clear at current rate |
| Queue growing for N consecutive checks | Warning | Publication, growth trend, current depth |
| Tracer token latency > warning threshold | Warning | Publication, latency breakdown (pub→dist, dist→sub) |
| Tracer token latency > critical threshold | Critical | Same + comparison to baseline |
| Tracer token never arrived (NULL subscriber_commit) | Critical | Publication, subscriber — potential full break |

**Deduplication:** Standard approach — check Teams.AlertQueue for recent matching alerts before queuing duplicates. Use publication + alert type as the dedup key with a configurable cooldown window.

### Teams Alert Cards

Adaptive Card format consistent with existing xFACts alerts:

- **Header:** "Replication Alert — [Publication Name]"
- **Severity badge:** Warning (amber) or Critical (red)
- **Details section:** Agent status, queue depth, latency measurements
- **Context:** Current vs. baseline comparison when historical data exists

---

## Phase 3: Retention and Trending

### Data Retention

| Table | Retention | Rationale |
|-------|-----------|-----------|
| Replication_AgentStatus | 30 days | Agent health snapshots — useful for incident correlation |
| Replication_QueueDepth | 30 days | Queue trends for capacity analysis |
| Replication_LatencyHistory | 90 days | Longer retention for latency trending and SLA reporting |
| Replication_Status | 30 days | Standard collector status retention |

Retention managed by the existing orchestrator cleanup pattern or a dedicated retention step in the collector.

### Trend Queries

Once data is flowing, these become immediately valuable:

**Daily latency profile** — "What does normal look like?"
```sql
SELECT 
    DATEPART(HOUR, publisher_commit) AS hour_of_day,
    AVG(total_latency_ms) AS avg_latency_ms,
    MAX(total_latency_ms) AS peak_latency_ms,
    COUNT(*) AS sample_count
FROM ServerOps.Replication_LatencyHistory
WHERE collected_dttm >= DATEADD(DAY, -7, GETDATE())
GROUP BY DATEPART(HOUR, publisher_commit)
ORDER BY hour_of_day
```

**Queue depth correlation with HADR waits** — "Does replication queue growth correlate with AG problems?"
```sql
-- Compare queue spikes with HADR_SYNC_COMMIT wait spikes
-- (joins against Activity_DMV_WaitStats data)
```

**Reliability scorecard** — "What's our uptime?"
```sql
SELECT 
    publication_name,
    COUNT(*) AS total_checks,
    SUM(CASE WHEN status IN ('Running', 'Idle') THEN 1 ELSE 0 END) AS healthy_checks,
    CAST(SUM(CASE WHEN status IN ('Running', 'Idle') THEN 1.0 ELSE 0 END) / COUNT(*) * 100 AS DECIMAL(5,2)) AS uptime_pct
FROM ServerOps.Replication_AgentStatus
WHERE collected_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY publication_name
```

---

## Phase 4: Control Center Integration (Future)

Not in initial scope, but the natural progression:

- **Server Health page addition** — Replication health card showing current latency, queue depth, agent status with color coding
- **Dedicated slideout or section** — Latency trend chart, queue depth over time, agent history
- **Or standalone page** — If monitoring expands to cover the decoupled reporting server, a dedicated Replication Monitoring page may be warranted

This follows the same pattern as every other xFACts module: build the data layer first, prove it works, then add visibility.

---

## Orchestrator Integration

### ProcessRegistry Entry

| Field | Value |
|-------|-------|
| process_name | Collect-ReplicationHealth |
| script_path | Collect-ReplicationHealth.ps1 |
| execution_mode | FIRE_AND_FORGET |
| interval_seconds | 60 |
| dependency_group | (same group as other ServerOps collectors) |
| timeout_seconds | 45 |

### Connection Considerations

The collector needs to query the **distribution database**, which lives on the publisher (DM-PROD-DB or whichever server acts as distributor). Since the orchestrator runs from FA-SQLDBB, this follows the same remote WinRM/Invoke-SqlCmd pattern used by other collectors.

Key question to verify: **Where is the distribution database configured?** If it's on DM-PROD-DB (common for local distribution), the collector queries there. If a remote distributor is configured, the collector targets that server instead.

---

## Open Questions

These should be resolved during Phase 1 implementation:

| Question | Impact |
|----------|--------|
| Where is the distribution database? Local to DM-PROD-DB or remote? | Determines collector connection target |
| How many publications exist currently? Just BIDATA or others? | Determines scope of initial monitoring |
| Are the existing replications push or pull subscriptions? | Affects where Distribution Agent runs and how to monitor it |
| What's the current Log Reader Agent polling interval? | Affects baseline latency expectations |
| Should tracer tokens be posted from the orchestrator (FA-SQLDBB) or does sp_posttracertoken need to run on the publisher directly? | sp_posttracertoken must execute on the publisher — collector may need to invoke remotely |
| Is there an existing cleanup job for the distribution database? What's the retention? | Affects how far back historical queries can reach in distribution tables |

---

## Implementation Order

1. **Create tables** — ServerOps.Replication_AgentStatus, Replication_QueueDepth, Replication_LatencyHistory, Replication_Status
2. **Add GlobalConfig entries** — Thresholds and intervals with conservative defaults
3. **Build collector** — Collect-ReplicationHealth.ps1 with standard xFACts initialization block, preview mode support
4. **Test in preview mode** — Verify queries against distribution database return expected data for existing publications
5. **Deploy to orchestrator** — ProcessRegistry entry, begin collecting
6. **Observe for 1-2 weeks** — Establish baselines before enabling alerts
7. **Build evaluator** — sp_Replication_EvaluateHealth with alert conditions tuned to observed baselines
8. **Enable alerting** — Teams integration for agent failures and threshold breaches
9. **Control Center integration** — Add visibility once data is flowing and patterns are understood

---

## Appendix: Key Distribution Database Objects

These are the system tables in the distribution database that the collector will query:

| Object | Purpose |
|--------|---------|
| MSdistribution_agents | One row per Distribution Agent — maps publications to subscribers |
| MSdistribution_history | Agent execution history — status, commands delivered, errors |
| MSdistribution_status | Current undistributed/delivered command counts per agent |
| MSlogreader_agents | One row per Log Reader Agent |
| MSlogreader_history | Log Reader execution history |
| MSrepl_errors | Error details referenced by history tables |
| MStracer_tokens | Posted tracer tokens with publisher/distributor commit times |
| MStracer_history | Tracer token subscriber arrival times |
| MSpublications | Publication definitions |
| MSarticles | Articles (tables) within each publication |

### Useful System Procedures

| Procedure | Purpose |
|-----------|---------|
| sp_posttracertoken | Insert a tracer token into a publication's transaction log |
| sp_helptracertokens | List all tracer tokens for a publication |
| sp_helptracertokenhistory | Get latency breakdown for a specific token |
| sp_deletetracertokenhistory | Clean up old tracer token records |
| sp_replmonitorsubscriptionpendingcmds | Pending command count (alternative to querying MSdistribution_status directly) |

# Sterling Integrator Module - Planning Document

## Executive Summary

A preliminary investigation of the IBM Sterling Integrator database revealed that significant operational data is already available in SQL Server and can be leveraged for monitoring, alerting, and historical analysis. This document outlines findings, opportunities, and next steps for building an xFACts Sterling module.

---

## Background

### Current State

Sterling Integrator was implemented by a prior IT Manager and currently operates as a "black box" - it runs, but institutional knowledge is limited. The Integration team is comfortable with the front-end UI but lacks visibility into:

- Process execution history beyond 48 hours
- Failure patterns and root causes
- Volume trends and anomalies
- Missing or late process detection

### Pain Points

| Issue | Impact |
|-------|--------|
| No proactive failure alerting | Issues discovered only when someone complains |
| Limited historical visibility | 48-hour archive window in UI |
| Difficult troubleshooting | Requires restoring old backups to view XML details |
| No volume monitoring | Can't detect "we got 0 files when we expected 50" |
| No schedule monitoring | Can't detect "this daily process didn't run" |
| Log file sprawl | Tons of logs on app server, no easy way to search |

---

## Discovery Findings

### Database Overview

The Sterling database (`b2bi` on FA-INT-DBP) contains substantial operational data:

| Table | Rows | Purpose |
|-------|------|---------|
| WORKFLOW_CONTEXT | 672K | Current process executions (last ~13 days) |
| WFC_S_RESTORE | 1.22M | Archived executions (Nov 8 - Jan 1) |
| DOCUMENT | 510K | Current file/payload tracking |
| DOCUMENT_RESTORE | 1.09M | Archived documents |
| TRANS_DATA | 1.6M | Current transaction data |
| TRANS_DATA_RESTORE | 3.25M | Archived transaction data |
| ACTIVITY_INFO | 33K | Step-level execution detail |
| DATA_FLOW | 36K | Document routing |

**Key Finding:** Sterling archives data to `*_RESTORE` tables rather than deleting it. This provides ~2+ months of queryable history without needing log files.

### Key Tables for Monitoring

#### WORKFLOW_CONTEXT (Primary)

| Column | Purpose |
|--------|---------|
| WORKFLOW_ID | Unique execution identifier |
| SERVICE_NAME | Business process name |
| START_TIME | Execution start |
| END_TIME | Execution end |
| BASIC_STATUS | Status code (0=success, 1=warning, 100+=error) |
| ADV_STATUS | Detailed status message |
| STEP_ID | 0=parent process, >0=sub-step |
| DOC_ID | Link to DOCUMENT table |

#### Status Code Reference

| BASIC_STATUS | Meaning | Action |
|--------------|---------|--------|
| 0 | Success | Normal |
| 1 | Warning/Soft Error | Log, usually OK |
| 10 | SFTP Status | Normal for file transfers |
| 100 | Process Stopped | Alert |
| 300 | Service Exception | Alert |
| 450 | Service Interrupted | Alert |
| 900 | Unknown | Investigate |

### Process Inventory

The system runs 200+ scheduled processes with clear naming conventions:

| Pattern | Direction | Example |
|---------|-----------|---------|
| `Scheduler_FA_FROM_*` | Inbound | `Scheduler_FA_FROM_REVSPRING_IB_BD_PULL` |
| `Scheduler_FA_TO_*` | Outbound | `Scheduler_FA_TO_LIVEVOX_IVR_OB_BD_S2D` |
| `Scheduler_FA_*` | Internal | `Scheduler_FA_DM_ENOTICE` |
| `Scheduler_*` | System | `Scheduler_FileGatewayReroute` |

### Current Health Assessment

Based on queries run during discovery:

- **Last 24 hours:** 8,069 executions, 0 failures
- **Process types:** Inbound (473), Outbound (160), Internal (98), System (1,237)
- **Sub-step warnings:** Normal housekeeping (BPMarkService, Translation) - not actionable
- **Actual business process failures:** Rare

---

## Proposed Capabilities

### Phase 1: Core Monitoring

#### 1.1 Process Failure Detection

Monitor for `BASIC_STATUS NOT IN (0, 10)` at `STEP_ID = 0` level.

```sql
-- Real-time failure check
SELECT WORKFLOW_ID, SERVICE_NAME, START_TIME, BASIC_STATUS, ADV_STATUS
FROM WORKFLOW_CONTEXT
WHERE BASIC_STATUS NOT IN (0, 10)
  AND STEP_ID = 0
  AND START_TIME >= DATEADD(MINUTE, -@CheckIntervalMinutes, GETDATE());
```

**Alert via:** Teams webhook  
**Escalate via:** Jira ticket after N occurrences

#### 1.2 Missing Process Detection

Compare expected schedule against actual executions.

**Requires:** Configuration table defining:
- Process name or pattern
- Expected frequency (hourly, daily, weekly, monthly)
- Expected time window (e.g., "between 6 AM and 8 AM")
- Alert threshold (hours overdue)

```sql
-- Example: Daily processes that haven't run in 25+ hours
SELECT SERVICE_NAME, MAX(START_TIME) AS last_run
FROM WORKFLOW_CONTEXT
WHERE SERVICE_NAME LIKE 'Scheduler_FA_%'
  AND STEP_ID = 0
GROUP BY SERVICE_NAME
HAVING MAX(START_TIME) < DATEADD(HOUR, -25, GETDATE());
```

#### 1.3 Volume Anomaly Detection

Track execution counts and alert on significant deviations.

**Approach:**
- Calculate rolling 7-day average per process
- Alert if today's count is < 50% or > 200% of average
- Useful for detecting "we got 0 files when we expected 50"

### Phase 2: Historical Analysis

#### 2.1 Unified History View

Create a view combining current and archived data:

```sql
CREATE VIEW Sterling.Workflow_History AS
SELECT * FROM WORKFLOW_CONTEXT
UNION ALL
SELECT * FROM WFC_S_RESTORE;
```

**Benefits:**
- Single query point for all historical research
- Enables trend analysis across months
- Eliminates need to restore backups for basic troubleshooting

#### 2.2 Trend Dashboards

- Daily/weekly/monthly execution volumes
- Failure rates over time
- Process duration trends (detect slowdowns)
- Partner-specific metrics

### Phase 3: Deep Data Extraction

#### 3.1 Document Content Tracking

The `DOCUMENT` table tracks files processed but payloads are stored on disk. Key fields:

| Column | Purpose |
|--------|---------|
| DOC_ID | Links to WORKFLOW_CONTEXT |
| DOC_NAME | Original filename |
| DOCUMENT_SIZE | File size in bytes |
| CREATE_TIME | When processed |
| BODY_NAME | Storage reference |

**Potential:** Track file volumes, sizes, names without accessing filesystem.

#### 3.2 Log File Investigation

**Location:** Application server (path TBD)  
**Format:** XML  
**Contains:** Detailed execution logs, error stack traces, payload previews

**Questions to answer:**
- What is the exact path structure?
- How are files organized (by date, process, etc.)?
- What retention exists?
- Can we parse and load relevant data into SQL?

**Potential approach:**
- PowerShell script to scan log directories
- Parse XML for key fields (process ID, timestamp, status, errors)
- Load into xFACts for searchable history
- Link via WORKFLOW_ID to database records

---

## Open Questions

### Business Questions

1. Which processes are critical and require immediate alerting?
2. What SLAs exist for file processing (must complete by X time)?
3. Which trading partners are highest priority?
4. Who should receive alerts? (Teams channel, individuals, distribution list)
5. What historical retention is required? (90 days? 1 year? 7 years?)

### Technical Questions

1. Where exactly are log files stored on the application server?
2. What is the log file naming convention and structure?
3. How long are logs retained before deletion?
4. Is there a correlation ID between database records and log files?
5. Does Sterling have any built-in alerting we should leverage or replace?
6. What credentials/access is needed for the app server filesystem?

### Data Questions

1. How often does the archive process run (moving data to `*_RESTORE` tables)?
2. Is there a purge process that deletes from `*_RESTORE` tables?
3. What is the actual retention window in the archive tables?
4. Are there other `*_RESTORE` tables with useful data?

---

## Proposed Architecture

### Schema: Sterling

Following xFACts patterns, a dedicated schema for Sterling integration.

### Core Tables

| Table | Purpose |
|-------|---------|
| Sterling.Process_Config | Expected processes with schedules and thresholds |
| Sterling.Process_Status | Dashboard showing current state per process |
| Sterling.Alert_History | Deduplication and audit trail |
| Sterling.Execution_Log | xFACts collection activity logging |

### Views

| View | Purpose |
|------|---------|
| Sterling.Workflow_History | Union of current + archived workflow data |
| Sterling.Document_History | Union of current + archived document data |

### Stored Procedures

| Procedure | Purpose |
|-----------|---------|
| sp_Sterling_Monitor | Main monitoring procedure (failures, missing, anomalies) |
| sp_Sterling_RefreshHistory | Optional: Copy/transform Sterling data for faster queries |

### Integration Points

| Component | Integration |
|-----------|-------------|
| Teams | Alert on failures, missing processes, anomalies |
| Jira | Create tickets for persistent issues |
| Orchestrator | Schedule monitoring via ProcessRegistry |

---

## Implementation Phases

### Phase 1: Foundation (1-2 weeks)

1. Create Sterling schema
2. Create Workflow_History view
3. Create Process_Config table
4. Manually populate critical processes
5. Create basic monitoring procedure
6. Integrate with Teams alerting
7. Test and refine

### Phase 2: Enhanced Monitoring (1-2 weeks)

1. Add volume anomaly detection
2. Add duration anomaly detection
3. Create dashboard queries
4. Document for operations team
5. Train Integration team on usage

### Phase 3: Historical Deep Dive (2-4 weeks)

1. Investigate log file structure
2. Design log parsing approach
3. Build extraction scripts (if valuable)
4. Load historical data
5. Create research queries/views

### Phase 4: Self-Service (Future)

1. Web UI for process status
2. Self-service historical search
3. Automated reporting

---

## Quick Wins (Available Now)

Even before building a formal module, these queries can be used immediately:

### Check for Failures (Last Hour)

```sql
SELECT SERVICE_NAME, START_TIME, BASIC_STATUS, ADV_STATUS
FROM b2bi.dbo.WORKFLOW_CONTEXT
WHERE BASIC_STATUS NOT IN (0, 10)
  AND STEP_ID = 0
  AND START_TIME >= DATEADD(HOUR, -1, GETDATE())
ORDER BY START_TIME DESC;
```

### Find Overdue Daily Processes

```sql
SELECT SERVICE_NAME, MAX(START_TIME) AS last_run,
       DATEDIFF(HOUR, MAX(START_TIME), GETDATE()) AS hours_ago
FROM b2bi.dbo.WORKFLOW_CONTEXT
WHERE SERVICE_NAME LIKE 'Scheduler_FA_%'
  AND STEP_ID = 0
  AND START_TIME >= DATEADD(DAY, -7, GETDATE())
GROUP BY SERVICE_NAME
HAVING MAX(START_TIME) < DATEADD(HOUR, -25, GETDATE())
ORDER BY hours_ago DESC;
```

### Research a Specific Process (Full History)

```sql
SELECT SERVICE_NAME, START_TIME, END_TIME, 
       DATEDIFF(SECOND, START_TIME, END_TIME) AS duration_sec,
       BASIC_STATUS, ADV_STATUS
FROM (
    SELECT * FROM b2bi.dbo.WORKFLOW_CONTEXT WHERE STEP_ID = 0
    UNION ALL
    SELECT * FROM b2bi.dbo.WFC_S_RESTORE WHERE STEP_ID = 0
) h
WHERE SERVICE_NAME = 'Scheduler_FA_FROM_REVSPRING_IB_BD_PULL'
ORDER BY START_TIME DESC;
```

### Daily Volume Trend (60 Days)

```sql
SELECT CAST(START_TIME AS DATE) AS run_date, COUNT(*) AS executions
FROM (
    SELECT START_TIME FROM b2bi.dbo.WORKFLOW_CONTEXT WHERE STEP_ID = 0
    UNION ALL
    SELECT START_TIME FROM b2bi.dbo.WFC_S_RESTORE WHERE STEP_ID = 0
) h
WHERE START_TIME >= DATEADD(DAY, -60, GETDATE())
GROUP BY CAST(START_TIME AS DATE)
ORDER BY run_date DESC;
```

---

## Next Steps

1. **Review this document** with Integration team for feedback
2. **Answer open questions** (especially log file locations)
3. **Identify critical processes** that need monitoring first
4. **Decide on phasing** - start with Phase 1 or quick wins only?
5. **Schedule follow-up** to begin implementation

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Author | Applications Team |
| Created | January 13, 2026 |
| Status | Draft - Planning |
| Next Review | TBD |

# B2B Integrator Module - Planning Document

## Executive Summary

IBM Sterling B2B Integrator (commonly referred to as "IBM" or "IBM B2B" internally) is the platform's file transfer and ETL processing engine handling inbound and outbound file transfers between FAC and its trading partners.

Discovery revealed two complementary data sources:

1. **`b2bi` database on FA-INT-DBP** — Sterling's operational database with real-time workflow execution data, aggressively purged on a ~2-3 day cycle
2. **`Integration` database on AVG-PROD-LSNR (AG)** — A structured extraction layer containing 5 years of batch status history, file transfer details, client configuration, and schedule definitions

A confirmed correlation key (`WORKFLOW_ID` in b2bi = `RUN_ID` in Integration) links the two systems reliably (20/20 match rate with logically consistent client-to-service pairings verified).

The module will collect from both sources into clean, consolidated xFACts tables — capturing real-time execution status from `b2bi` and enriching with business context from `Integration`. The data from Integration's loosely structured tables will be normalized into xFACts-standard table designs.

The eventual goal is end-to-end file lifecycle tracking: File Monitoring (SFTP receipt) → B2B (ETL processing) → Batch Monitoring (DM loading).

---

## Prerequisites

### Shared Infrastructure: dbo.ClientHierarchy

A new shared infrastructure table providing a complete, flattened DM creditor hierarchy. This replaces the recursive scalar function approach (`Integration.dbo.fn_HighestParent`) with a single recursive CTE that resolves the entire hierarchy in one pass.

**Table:** `dbo.ClientHierarchy`
**Component:** Engine.SharedInfrastructure
**Refresh:** Scheduled script reading from `crs5_oltp.dbo.crdtr` and `crs5_oltp.dbo.crdtr_grp`

| Column | Type | Purpose |
|--------|------|---------|
| creditor_id | BIGINT | crdtr_id from DM |
| creditor_key | VARCHAR(10) | crdtr_shrt_nm (CE/CB code) |
| creditor_name | VARCHAR(128) | crdtr_nm |
| parent_group_id | BIGINT | Direct parent crdtr_grp_id (self-referencing if standalone) |
| parent_group_key | VARCHAR(10) | Direct parent crdtr_grp_shrt_nm |
| parent_group_name | VARCHAR(128) | Direct parent crdtr_grp_nm |
| top_parent_id | BIGINT | Highest ancestor crdtr_grp_id (resolved via recursive CTE) |
| top_parent_key | VARCHAR(10) | Highest ancestor crdtr_grp_shrt_nm |
| top_parent_name | VARCHAR(128) | Highest ancestor crdtr_grp_nm |
| is_active | BIT | crdtr_stts_cd = 1 |
| last_refreshed_dttm | DATETIME | When this row was last rebuilt |

**Key design decisions:**
- Standalone creditors (`crdtr_grp_id = 1`) self-reference: their parent and top parent fields point to themselves
- Group 1 ("Internal Creditor Group" / "DefGrp") is excluded from the CTE anchor to prevent duplicate path resolution
- No commission data or ranking — that is a Jira-specific concern and can be layered on top via view or separate table
- Includes ALL creditors regardless of transaction history (unlike the current `Jira_ClientTblRanked` which filters to 13 months of activity)
- `Applications.dbo.Jira_ClientTblRanked` continues independently for now — not redirected to xFACts due to potential future xFACts server relocation

**Hierarchy resolution CTE (proven accurate against existing Jira_ClientTblRanked):**

```sql
;WITH GroupHierarchy AS (
    SELECT 
        crdtr_grp_id,
        crdtr_grp_shrt_nm,
        crdtr_grp_nm,
        crdtr_grp_id AS top_parent_id,
        crdtr_grp_shrt_nm AS top_parent_key,
        crdtr_grp_nm AS top_parent_name
    FROM crs5_oltp.dbo.crdtr_grp
    WHERE (crdtr_grp_prnt_id IS NULL OR crdtr_grp_prnt_id = 1)
      AND crdtr_grp_id <> 1
      AND crdtr_grp_sft_dlt_flg = 'N'
    
    UNION ALL
    
    SELECT 
        cg.crdtr_grp_id,
        cg.crdtr_grp_shrt_nm,
        cg.crdtr_grp_nm,
        gh.top_parent_id,
        gh.top_parent_key,
        gh.top_parent_name
    FROM crs5_oltp.dbo.crdtr_grp cg
    INNER JOIN GroupHierarchy gh ON cg.crdtr_grp_prnt_id = gh.crdtr_grp_id
    WHERE cg.crdtr_grp_sft_dlt_flg = 'N'
)
SELECT 
    cr.crdtr_id,
    cr.crdtr_shrt_nm,
    cr.crdtr_nm,
    CASE WHEN cr.crdtr_grp_id = 1 THEN cr.crdtr_id ELSE gh.crdtr_grp_id END,
    CASE WHEN cr.crdtr_grp_id = 1 THEN cr.crdtr_shrt_nm ELSE gh.crdtr_grp_shrt_nm END,
    CASE WHEN cr.crdtr_grp_id = 1 THEN cr.crdtr_nm ELSE gh.crdtr_grp_nm END,
    CASE WHEN cr.crdtr_grp_id = 1 THEN cr.crdtr_id ELSE gh.top_parent_id END,
    CASE WHEN cr.crdtr_grp_id = 1 THEN cr.crdtr_shrt_nm ELSE gh.top_parent_key END,
    CASE WHEN cr.crdtr_grp_id = 1 THEN cr.crdtr_nm ELSE gh.top_parent_name END,
    CASE WHEN cr.crdtr_stts_cd = 1 THEN 1 ELSE 0 END
FROM crs5_oltp.dbo.crdtr cr
LEFT JOIN GroupHierarchy gh ON cr.crdtr_grp_id = gh.crdtr_grp_id
```

**Consumers:**
- B2B module: resolves Integration `CREDITOR_NAME` (CE/CB codes) to DM hierarchy for crosswalk
- Future: any module needing DM client hierarchy resolution

---

## Background

### Current State

Sterling was implemented by a prior IT Manager and operates as a "black box." The Integration team maintains it but lacks deep visibility into execution history, failure patterns, and processing metrics. A separate team built structured extraction tables in the Integration database, but no monitoring or alerting layer exists on top of them.

### Pain Points

| Issue | Impact |
|-------|--------|
| No proactive failure alerting | Issues discovered only when someone complains |
| Aggressive data purging in b2bi | ~2-3 day retention; 10-minute purge cycle |
| Missing process detection gap | Scheduled processes that don't run go unnoticed for days/weeks |
| No volume monitoring | Cannot detect "we got 0 files when we expected 50" |
| No schedule monitoring | Cannot detect "this daily process didn't run" |
| Limited historical visibility in Sterling UI | ~48 hours; filesystem archives are binary |
| No institutional knowledge | Original implementer no longer at FAC |
| Complex client mapping | B2B client structure independent from DM with many-to-many relationships |
| Integration database poorly documented | ~320 tables, key-value parameter design, type-specific data tables |

### Infrastructure

| Component | Details |
|-----------|---------|
| Product | IBM Sterling B2B Integrator |
| Database Server | FA-INT-DBP (SQL Server 2019 Enterprise) |
| Application Server | FA-INT-APPP |
| Sterling Database | b2bi (on FA-INT-DBP) |
| Integration Database | Integration (on AVG-PROD-LSNR, in the AG) |
| Installation Path | E:\App\IBM\SI\ |
| Archive Path | E:\App\IBM\SI\arc_data\ |
| Archive Format | Proprietary binary (.dat files) — not parseable |
| Archive Retention | ~2 weeks local filesystem |
| DB Backup Strategy | Full weekly, diff nightly, logs 15m; 2 weeks local/network, older to Glacier |

---

## Data Source 1: b2bi Database (FA-INT-DBP)

### Purpose in Module

Real-time execution monitoring and failure detection. This is the only source that shows workflow status before Integration tables are populated, and the only source that captures failures where Sterling processes terminate before writing to Integration.

### Key Tables

| Table | Rows | Size (MB) | Purpose |
|-------|------|-----------|---------|
| WORKFLOW_CONTEXT | 408K | 331 | Current process executions (~2-3 days) |
| DOCUMENT | 233K | 100 | Current file/payload tracking |
| SCHEDULE | 595 | <1 | Process schedule configuration |

### Data Retention

- `Schedule_PurgeService` runs every ~10 minutes
- `WORKFLOW_CONTEXT` retains ~2-3 days before purging
- `*_RESTORE` tables are brief staging areas (3-day window observed), not long-term storage
- TRANS_DATA, ACTIVITY_INFO, DATA_FLOW contain binary/compressed objects — not usable

### Daily Volumes

| Metric | Daily Volume |
|--------|-------------|
| Parent processes (STEP_ID = 0) | ~4,600 |
| Sub-step records (STEP_ID > 0) | ~160,000 |
| Collector captures STEP_ID = 0 only | ~4,600 rows/day |

### WORKFLOW_CONTEXT — Columns to Collect

| b2bi Column | xFACts Column | Purpose |
|-------------|---------------|---------|
| WORKFLOW_ID (int) | workflow_id | Unique execution ID; correlation key to Integration RUN_ID |
| WFD_ID | workflow_def_id | Workflow definition identifier |
| WFD_VERSION | workflow_def_version | Workflow definition version |
| SERVICE_NAME | service_name | Process name (e.g., Scheduler_FA_FROM_REVSPRING_IB_BD_PULL) |
| DOC_ID | doc_id | Link to DOCUMENT table |
| BASIC_STATUS | status_code | Status (0=success, 1=warning, 10=SFTP, 100+=error) |
| ADV_STATUS | status_message | Detailed status text |
| START_TIME | start_time | Execution start |
| END_TIME | end_time | Execution end |
| NODEEXECUTED | node_executed | Server node |

### Status Code Reference

| BASIC_STATUS | Meaning | Action |
|--------------|---------|--------|
| 0 | Success | None |
| 1 | Warning / Soft Error | Log |
| 10 | SFTP Status | None (normal) |
| 100 | Process Stopped | Alert |
| 300 | Service Exception | Alert |
| 450 | Service Interrupted | Alert |
| 900 | Unknown | Investigate |

### Observed Failure Patterns

- All observed failures occurred at sub-step level (STEP_ID > 0) only
- Zero parent-level failures in 30 days
- BASIC_STATUS = 100 clustered on April 1: AS2LightweightJDBCAdapter sub-steps; parent processes completed
- Failures are rare but cluster when they occur (infrastructure-related)

### DOCUMENT — Columns to Collect

| b2bi Column | xFACts Column | Purpose |
|-------------|---------------|---------|
| DOC_ID | doc_id | Unique document identifier |
| DOC_NAME | doc_name | Original filename (filter: NOT NULL only) |
| DOCUMENT_SIZE | document_size | File size in bytes |
| WORKFLOW_ID | workflow_id | Link to WorkflowTracking |
| BODY_NAME | file_reference | Storage reference |
| CREATE_TIME | create_time | Processing timestamp |

### SCHEDULE Table

595 rows (479 active FA processes, 87 inactive). `SERVICENAME` maps to `WORKFLOW_CONTEXT.SERVICE_NAME` with `Scheduler_` prefix. `TIMINGXML` contains opaque internal IDs — use Integration's `CLIENTS_SCHEDULES` for readable schedules instead.

---

## Data Source 2: Integration Database (AVG-PROD-LSNR)

### Purpose in Module

Business context enrichment and historical analysis. Provides structured batch lifecycle data, file transfer details, client identification, and schedule definitions. Contains 5 years of history (since June 2021). Resides on the AG — local read access.

**Important:** Integration table relationships and the SEQ_ID → process type mapping are not yet fully understood. Collection design for Integration-sourced data is deferred until these relationships are clarified with the Integration team.

### Correlation Key

**Confirmed:** `WORKFLOW_ID` (integer) in b2bi = `RUN_ID` in Integration. 20/20 match rate verified.

### Key Tables — Execution and Lifecycle

| Table | Rows | Purpose |
|-------|------|---------|
| etl.tbl_B2B_CLIENTS_BATCH_STATUS | 1,542,058 | **Primary lifecycle tracker.** CLIENT_ID, SEQ_ID, PARENT_ID, RUN_ID, BATCH_ID, BATCH_STATUS, INSERT_DATE, FINISH_DATE. History to June 2021. |
| etl.tbl_B2B_CLIENTS_BATCH_STATUS_CROSSWALK | 8 | Status code reference |
| etl.tbl_B2B_CLIENTS_BATCH_FILES | 2,383,319 | **File transfer inventory.** FILE_NAME, FILE_SIZE, COMM_METHOD. |

### Batch Status Codes

| BATCH_STATUS | Description |
|-------------|-------------|
| -2 | PREVIOUS BP FAILED |
| -1 | BP FAILED |
| 0 | RUNNING |
| 1 | WAITING |
| 2 | BP COMPLETED |
| 3 | RELEASED/POSTED |
| 4 | EMPTY FILE |
| 5 | DUPLICATE FILE |

### Key Tables — Configuration and Reference

| Table | Rows | Purpose |
|-------|------|---------|
| etl.tbl_B2B_CLIENTS_MN | 718 | **Client lookup.** CLIENT_ID → CLIENT_NAME, ACTIVE_FLAG, AUTOMATED. |
| etl.tbl_B2B_CLIENTS_SCHEDULES | 856 | **Human-readable schedules.** BP_NAME, RUN_DATE (Everyday/Monday/1 Month/etc.), TIME_START, STATUS. |
| etl.tbl_B2B_CLIENTS_PARAM | 25,100 | Process parameters (key-value pairs). Not collected — query live if needed. |
| etl.tbl_B2B_CLIENTS_FILES | 2,380 | Client file configuration. |

### Key Tables — Record-Level Business Data

Separated by file type. Common columns vary significantly across tables.

| Table | Rows | Size (MB) | Type | RUN_ID | CLIENT_ID | NODE_ID |
|-------|------|-----------|------|--------|-----------|---------|
| CLIENTS_ACCTS | 34.4M | 6,377 | New business | Yes | Yes | Yes |
| CLIENTS_ACCTS_RETURN | 9.8M | 926 | Returns | No | Yes | No |
| CLIENTS_ADDRESS_UPDATE | 5.6M | 541 | Address updates | Yes | No | Yes |
| CLIENTS_BDL_CNSMR_ACCNT_AR | 11M | 1,781 | BDL AR logs | Yes | No | No |
| CLIENTS_BDL_CNSMR_TAG | 8.8M | 889 | BDL tags | Yes | No | No |
| CLIENTS_WORKERS_COMP | 121K | 30 | Workers comp | Yes | No | No |
| CLIENTS_REMIT_FILES_DATA | 29K | 4 | Remit data | TBD | TBD | TBD |

Record counts derivable from `MAX(NODE_ID) + 1` where NODE_ID exists; `COUNT(*)` by RUN_ID otherwise.

### DM Crosswalk (Confirmed)

`CREDITOR_NAME` in `CLIENTS_ACCTS` contains DM client keys (CE/CB codes) resolvable via `dbo.ClientHierarchy`:

```
B2B CLIENT_ID → CLIENTS_ACCTS.CREDITOR_NAME (CE/CB code)
    → dbo.ClientHierarchy.creditor_key → parent/top_parent hierarchy
```

Example: B2B CLIENT_ID 10724 ("ACADIA HEALTHCARE EO") → 45+ DM creditor keys → parent "Acadia Healthcare"

### DM Batch Correlation

`BATCH_ID` in `BATCH_STATUS` contains DM batch identifiers for new business (8-character alpha codes matching `new_bsnss_btch`). Content varies by process type — interpretation depends on SEQ_ID mapping.

### Investigation Items (Blocking Collection Design)

| Item | Status | Impact |
|------|--------|--------|
| What writes to etl.tbl_B2B_* tables? | Ask team | Determines write latency and failure scenarios |
| Write latency (Sterling → Integration) | Ask team | Determines b2bi collector criticality |
| SEQ_ID → process type mapping | Ask team | **Blocks WorkflowTracking design** — determines how to join BATCH_STATUS to record-level tables |
| BATCH_ID interpretation by process type | Ask team | Determines DM batch correlation approach |
| How record-level tables link via SEQ_ID/RUN_ID | Investigate | Required to build unified record count view |

### Investigation Items (Non-Blocking)

| Item | Status | Notes |
|------|--------|-------|
| ~320 additional Integration tables | Unexplored | May contain additional useful data |
| FILES_LOG table | Investigated | Misnamed — it's a config change audit log, not file processing metrics |
| Naming suffixes S2D, S2P, D2S, P2S | Ask team lead | S = SQL; others TBD |
| Naming suffix SP | Ask team | Unknown |

---

## Process Naming Conventions

| Pattern | Direction | Example |
|---------|-----------|---------|
| `Scheduler_FA_FROM_*` | Inbound (partner → FAC) | `Scheduler_FA_FROM_REVSPRING_IB_BD_PULL` |
| `Scheduler_FA_TO_*` | Outbound (FAC → partner) | `Scheduler_FA_TO_LIVEVOX_IVR_OB_BD_S2D` |
| `Scheduler_FA_*` | Internal / Utility | `Scheduler_FA_DM_ENOTICE` |
| `Scheduler_*` (no FA_) | System / Housekeeping | `Scheduler_FileGatewayReroute` |

### Naming Segment Definitions

| Segment | Meaning |
|---------|---------|
| IB / OB | Inbound / Outbound |
| BD | Bad Debt (3rd party collections) |
| EO | Early Out (1st party collections) |
| NT | Notes file |
| RT | Return file |
| RM | Remit file |
| RC | Recall file |
| SP | TBD |
| NB | New Business |
| TR | Transactions (PMT / payment transactions) |
| BDL | Bulk Data Load |
| RPT | Report |
| INV | Inventory file (probable — confirm with team) |
| S2D, S2P, D2S, P2S | Transfer patterns — S = SQL; others TBD (ask team lead) |
| PULL / PUSH | Transfer direction initiation |

---

## Architecture

### Schema: B2B

Dedicated `B2B` schema in xFACts. No references to "Sterling" in table or column names. Module configuration via `dbo.GlobalConfig` with `module_name = 'B2B'`.

### Data Flow

```
b2bi (FA-INT-DBP)                Integration (AG)
WORKFLOW_CONTEXT  ──┐         BATCH_STATUS  ──┐
DOCUMENT          ──┤         BATCH_FILES   ──┤
                    │         CLIENTS_MN    ──┤
                    ▼                         ▼
              Collect-B2BWorkflow.ps1
                    │
                    ▼
              ┌─────────────────────────────────┐
              │     xFACts B2B Schema (AG)      │
              │  WorkflowTracking               │
              │  DocumentTracking               │
              │  ProcessConfig                  │
              └─────────────┬───────────────────┘
              ┌─────────────┘
              │     xFACts dbo Schema (AG)      │
              │  ClientHierarchy (shared)       │
              └─────────────┬───────────────────┘
                            │
                    Monitor-B2B.ps1
                            │
                    ┌───────┴───────┐
                    │  Teams/Jira   │
                    └───────────────┘
```

### Core Tables

| Table | Purpose |
|-------|---------|
| dbo.ClientHierarchy | **Shared infrastructure.** Complete DM creditor hierarchy for crosswalk and client resolution. |
| B2B.WorkflowTracking | Consolidated execution records from b2bi, enriched with Integration data. **Design pending SEQ_ID investigation.** |
| B2B.DocumentTracking | File records from b2bi DOCUMENT (DOC_NAME IS NOT NULL only). |
| B2B.ProcessConfig | Process configuration: schedule metadata, monitoring thresholds, client association. |

### Scripts

| Script | Source(s) | Frequency | Purpose |
|--------|-----------|-----------|---------|
| Collect-B2BWorkflow.ps1 | b2bi + Integration | Every 10 min | Captures workflows from b2bi, enriches from Integration. **Design pending SEQ_ID investigation.** |
| Monitor-B2B.ps1 | xFACts B2B tables | Every 30-60 min | Evaluates data, detects failures/missing processes, queues alerts. |
| Sync-B2BConfig.ps1 | Integration | Daily | Syncs schedules and clients into ProcessConfig. |

### Control Center Page

Dedicated "B2B Monitoring" page: process status overview, failure feed, missing process alerts, file transfer activity, volume trends, client-grouped views, process detail slideout.

---

## Build Readiness Assessment

### Ready to Build Now

| Item | Rationale |
|------|-----------|
| `dbo.ClientHierarchy` table + refresh script | Shared infrastructure. CTE proven accurate. No Integration dependency. |
| B2B schema creation | Simple `CREATE SCHEMA` |
| `B2B.ProcessConfig` table | Design is independent of SEQ_ID question. Seeded from Integration schedules/clients. |
| `Sync-B2BConfig.ps1` | Reads well-understood tables (CLIENTS_SCHEDULES, CLIENTS_MN). |

### Blocked — Waiting on Team Input

| Item | Blocking Question |
|------|-------------------|
| `B2B.WorkflowTracking` final design | SEQ_ID → process type mapping. How does BATCH_STATUS relate to record-level tables? |
| `Collect-B2BWorkflow.ps1` enrichment logic | Same — need to know what Integration data to pull and how to join it. |
| `B2B.DocumentTracking` | May be affected by BATCH_FILES overlap — need to confirm whether b2bi DOCUMENT adds value beyond Integration BATCH_FILES. |
| `Monitor-B2B.ps1` | Depends on WorkflowTracking design. |

---

## Historical Data

| Source | Earliest | Latest | Rows |
|--------|----------|--------|------|
| Integration BATCH_STATUS | 2021-06-23 | Current | 1,542,058 |
| Integration BATCH_FILES | TBD | Current | 2,383,319 |
| Integration CLIENTS_ACCTS | TBD | Current | 34,372,524 |
| b2bi WORKFLOW_CONTEXT | ~2-3 days back | Current | ~4,600/day |

**No historical backload required.** Integration contains 5 years of structured history.

---

## Client Structure

### B2B Client Inventory

718 clients in `tbl_B2B_CLIENTS_MN` (CLIENT_ID, CLIENT_NAME, ACTIVE_FLAG, AUTOMATED).

### DM Crosswalk

B2B CLIENT_ID → DM Creditor Keys via `CLIENTS_ACCTS.CREDITOR_NAME` → resolved through `dbo.ClientHierarchy`. Relationship is predominantly one-to-many (one B2B client → many DM creditor keys rolling up to a common parent). Crosswalk derived from actual data flow.

---

## Implementation Phases

### Phase 1: Foundation (Ready Now)

1. Build `dbo.ClientHierarchy` table and refresh script
2. Create B2B schema
3. Create `B2B.ProcessConfig` table
4. Build `Sync-B2BConfig.ps1` (daily schedule/client sync)
5. Seed ProcessConfig from Integration schedules and client data
6. Register in Module_Registry, Component_Registry, Object_Registry

### Phase 2: Collection (After Team Input)

1. Finalize `B2B.WorkflowTracking` design (informed by SEQ_ID mapping)
2. Determine `B2B.DocumentTracking` necessity (b2bi DOCUMENT vs Integration BATCH_FILES)
3. Build `Collect-B2BWorkflow.ps1` with Integration enrichment
4. Seed initial data
5. Register in ProcessRegistry

### Phase 3: Monitoring and Alerting

1. Build `Monitor-B2B.ps1`
2. Integrate with Teams and Jira
3. Configure monitoring thresholds on critical processes
4. Validate alert accuracy

### Phase 4: Control Center Page

1. Build B2B Monitoring CC page (route, API, CSS, JS)
2. Process status, failure feed, file transfers, volume trends
3. Client-grouped views with ClientHierarchy resolution
4. Engine indicator integration

### Phase 5: Enhanced Analytics (Future)

1. Volume and duration anomaly detection
2. End-to-end file lifecycle (FileOps → B2B → BatchOps)
3. DM batch correlation via BATCH_ID
4. Historical trend analysis

---

## Open Questions

### For Integration Team (Blocking Phase 2)

1. What writes to the `etl.tbl_B2B_*` tables? (Sterling adapters? Separate ETL?)
2. How quickly after a Sterling execution does the Integration row appear?
3. What do SEQ_ID values represent? (process type mapping)
4. How is BATCH_ID populated for different process types?

### For Team Lead

1. What do S2D, S2P, D2S, P2S mean? (S = SQL; others TBD)
2. What does the SP suffix mean?
3. Is INV = Inventory (not Invoice)?

### For Applications Team

1. Which processes are critical and require immediate alerting?
2. What SLAs exist for file processing?
3. Review the 196 active schedules with no recent execution

### For Infrastructure (Shawn)

1. Is there a network share for older arc_data archives?
2. Can the Sterling purge retention window be extended?

---

## Quick Reference Queries

### b2bi (FA-INT-DBP)

```sql
-- Recent failures
SELECT WORKFLOW_ID, SERVICE_NAME, START_TIME, BASIC_STATUS, ADV_STATUS
FROM b2bi.dbo.WORKFLOW_CONTEXT
WHERE BASIC_STATUS NOT IN (0, 10) AND STEP_ID = 0
  AND START_TIME >= DATEADD(HOUR, -24, GETDATE())
ORDER BY START_TIME DESC;
```

### Integration (AVG-PROD-LSNR)

```sql
-- Recent batch status with client names
SELECT bs.RUN_ID, mn.CLIENT_NAME, bs.SEQ_ID, bs.BATCH_STATUS, 
       cw.BATCH_STATUS_TXT, bs.INSERT_DATE, bs.FINISH_DATE
FROM Integration.etl.tbl_B2B_CLIENTS_BATCH_STATUS bs
LEFT JOIN Integration.etl.tbl_B2B_CLIENTS_MN mn ON bs.CLIENT_ID = mn.CLIENT_ID
LEFT JOIN Integration.etl.tbl_B2B_CLIENTS_BATCH_STATUS_CROSSWALK cw 
    ON bs.BATCH_STATUS = cw.BATCH_STATUS
WHERE bs.INSERT_DATE >= DATEADD(HOUR, -4, GETDATE())
ORDER BY bs.INSERT_DATE DESC;

-- Recent file transfers
SELECT bf.RUN_ID, mn.CLIENT_NAME, bf.FILE_NAME, bf.FILE_SIZE, 
       bf.COMM_METHOD, bf.INSERT_DATE
FROM Integration.etl.tbl_B2B_CLIENTS_BATCH_FILES bf
LEFT JOIN Integration.etl.tbl_B2B_CLIENTS_MN mn ON bf.CLIENT_ID = mn.CLIENT_ID
WHERE bf.INSERT_DATE >= DATEADD(HOUR, -4, GETDATE())
ORDER BY bf.INSERT_DATE DESC;

-- DM crosswalk (requires dbo.ClientHierarchy)
SELECT mn.CLIENT_NAME, a.CLIENT_ID, a.CREDITOR_NAME,
       ch.creditor_name AS dm_creditor_name,
       ch.top_parent_name
FROM Integration.etl.tbl_B2B_CLIENTS_ACCTS a
INNER JOIN Integration.etl.tbl_B2B_CLIENTS_MN mn ON a.CLIENT_ID = mn.CLIENT_ID
INNER JOIN dbo.ClientHierarchy ch ON ch.creditor_key = a.CREDITOR_NAME
WHERE a.RUN_ID >= 7890000
GROUP BY mn.CLIENT_NAME, a.CLIENT_ID, a.CREDITOR_NAME, 
         ch.creditor_name, ch.top_parent_name
ORDER BY mn.CLIENT_NAME, a.CREDITOR_NAME;

-- Active schedules
SELECT BP_NAME, STATUS, RUN_DATE, TIME_START
FROM Integration.etl.tbl_B2B_CLIENTS_SCHEDULES
WHERE STATUS = 'ACTIVE'
ORDER BY BP_NAME;
```

### Correlation Test (PowerShell)

```powershell
$integrationQuery = @"
    SELECT TOP 20 bs.RUN_ID, bs.CLIENT_ID, bs.BATCH_STATUS, bs.INSERT_DATE,
           mn.CLIENT_NAME
    FROM Integration.etl.tbl_B2B_CLIENTS_BATCH_STATUS bs
    LEFT JOIN Integration.etl.tbl_B2B_CLIENTS_MN mn ON bs.CLIENT_ID = mn.CLIENT_ID
    WHERE bs.INSERT_DATE >= DATEADD(HOUR, -1, GETDATE())
      AND bs.PARENT_ID IS NULL
    ORDER BY bs.INSERT_DATE DESC
"@

$b2biQuery = @"
    SELECT WORKFLOW_ID, SERVICE_NAME, BASIC_STATUS, START_TIME
    FROM WORKFLOW_CONTEXT
    WHERE START_TIME >= DATEADD(HOUR, -1, GETDATE())
    ORDER BY START_TIME DESC
"@

$batchData = Invoke-Sqlcmd -ServerInstance "AVG-PROD-LSNR" -Database "Integration" `
    -Query $integrationQuery -TrustServerCertificate
$workflowData = Invoke-Sqlcmd -ServerInstance "FA-INT-DBP" -Database "b2bi" `
    -Query $b2biQuery -TrustServerCertificate

foreach ($batch in $batchData) {
    $match = $workflowData | Where-Object { $_.WORKFLOW_ID -eq $batch.RUN_ID }
    if ($match) {
        Write-Host "MATCH | RUN_ID: $($batch.RUN_ID) | Client: $($batch.CLIENT_NAME)"
    } else {
        Write-Host "MISS  | RUN_ID: $($batch.RUN_ID) | Client: $($batch.CLIENT_NAME)"
    }
}
```

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Author | Applications Team |
| Created | January 13, 2026 |
| Revised | April 5, 2026 |
| Status | Active — Phase 1 Ready, Phase 2 Pending Team Input |
| Schema | B2B |
| Primary Source | b2bi on FA-INT-DBP (real-time) + Integration on AG (enrichment/history) |
| Correlation Key | b2bi WORKFLOW_ID (int) = Integration RUN_ID |
| Prerequisite | dbo.ClientHierarchy (shared infrastructure) |

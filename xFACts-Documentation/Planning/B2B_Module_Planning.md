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

### Shared Infrastructure: dbo.ClientHierarchy ✅ IMPLEMENTED

A shared infrastructure table providing a complete, flattened DM creditor hierarchy. This replaces the recursive scalar function approach (`Integration.dbo.fn_HighestParent`) with a single recursive CTE that resolves the entire hierarchy in one pass.

**Table:** `dbo.ClientHierarchy`
**Component:** Engine.SharedInfrastructure
**Refresh:** `Sync-ClientHierarchy.ps1` (daily via orchestrator)
**Status:** DDL deployed, sync script built and executed successfully, Object_Registry and Object_Metadata populated.

| Column | Type | Purpose |
|--------|------|---------|
| creditor_id | BIGINT (PK) | crdtr_id from DM |
| creditor_key | VARCHAR(10) | crdtr_shrt_nm (CE/CB code) |
| creditor_name | VARCHAR(128) | crdtr_nm |
| parent_group_id | BIGINT | Direct parent crdtr_grp_id (self-referencing if standalone) |
| parent_group_key | VARCHAR(10) | Direct parent crdtr_grp_shrt_nm |
| parent_group_name | VARCHAR(128) | Direct parent crdtr_grp_nm |
| parent_group_is_active | BIT | Derived from crdtr_grp_sft_dlt_flg on direct parent group |
| top_parent_id | BIGINT | Highest ancestor crdtr_grp_id (resolved via recursive CTE) |
| top_parent_key | VARCHAR(10) | Highest ancestor crdtr_grp_shrt_nm |
| top_parent_name | VARCHAR(128) | Highest ancestor crdtr_grp_nm |
| top_parent_is_active | BIT | Derived from crdtr_grp_sft_dlt_flg on top-level ancestor |
| is_active | BIT | crdtr_stts_cd = 1 |
| last_refreshed_dttm | DATETIME | When this row was last rebuilt |

**Key design decisions:**
- CTE does NOT filter on `crdtr_grp_sft_dlt_flg` — walks ALL groups regardless of soft-delete status to accurately capture the real DM hierarchy including warts (orphaned chains, inactive groups with active creditors)
- Standalone creditors (`crdtr_grp_id = 1`) self-reference: their parent and top parent fields point to themselves
- Group 1 ("Internal Creditor Group" / "DefGrp") is excluded from the CTE anchor to prevent duplicate path resolution
- NULL safety net (`OR gh.crdtr_grp_id IS NULL`) ensures creditors with unresolvable group chains self-reference rather than being excluded
- `parent_group_is_active` and `top_parent_is_active` capture group active status to identify hierarchy chain discrepancies (e.g., active creditor under soft-deleted group)
- MERGE with DELETE on NOT MATCHED BY SOURCE (hard delete for creditors removed from DM)
- Summary output includes "Active in Inactive Group" count for hierarchy health monitoring
- Diagnostic analysis revealed 31 orphaned creditors (10 active HCA Jacksonville under broken ancestor chain, 21 inactive under soft-deleted groups) — all resolve correctly
- No commission data or ranking — that is a Jira-specific concern and can be layered on top via view or separate table
- Includes ALL creditors regardless of transaction history (unlike the current `Jira_ClientTblRanked` which filters to 13 months of activity)
- `Applications.dbo.Jira_ClientTblRanked` continues independently for now — not redirected to xFACts due to potential future xFACts server relocation

**Indexes:**
- `IX_ClientHierarchy_creditor_key` — covering index for CE/CB code lookups (includes name columns)
- `IX_ClientHierarchy_top_parent_id` — for parent grouping queries

**Consumers:**
- B2B module: resolves Integration `CREDITOR_NAME` (CE/CB codes) to DM hierarchy for crosswalk
- Future: any module needing DM client hierarchy resolution

**Pending:**
- ProcessRegistry entry for daily orchestrator execution

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
| Sterling Database | b2bi (on FA-INT-DBP) — **case-sensitive collation** |
| Integration Database | Integration (on AVG-PROD-LSNR, in the AG) |
| Installation Path | E:\App\IBM\SI\ |
| Archive Path | E:\App\IBM\SI\arc_data\ |
| Archive Format | Proprietary binary (.dat files) — not parseable |
| Archive Retention | ~2 weeks local filesystem |
| DB Backup Strategy | Full weekly, diff nightly, logs 15m; 2 weeks local/network, older to Glacier |

**Important:** b2bi database uses case-sensitive collation. String comparisons must use exact case (e.g., `STATUS = 'ACTIVE'` not `'Active'`).

---

## Data Source 1: b2bi Database (FA-INT-DBP)

### Purpose in Module

Real-time execution monitoring, failure detection, and **activity detection**. This is the only source that shows workflow status before Integration tables are populated, the only source that captures failures where Sterling processes terminate before writing to Integration, and — critically — the authoritative source for determining whether a process actually processed data on a given execution.

### Key Tables

| Table | Rows | Size (MB) | Purpose |
|-------|------|-----------|---------|
| WORKFLOW_CONTEXT | 408K | 331 | Current process executions (~2-3 days) |
| WORKFLOW_LINKAGE | ~16K | <1 | Parent-child workflow relationships |
| DOCUMENT | 233K | 100 | Current file/payload tracking |
| SCHEDULE | 595 | <1 | Process schedule configuration |
| WFD | varies | <1 | Workflow definitions (template registry with versioning) |

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

### Workflow Hierarchy Discovery

b2bi workflows operate in a parent-child hierarchy:

1. **Scheduler_FA_* (parent)** — Top-level process (STEP_ID = 0). Orchestrates the overall operation.
2. **Sub-steps** — Within the same WORKFLOW_ID (STEP_ID > 0). Template plumbing services (AssignService, DecisionEngineService, AS2LightweightJDBCAdapter, ReleaseService, etc.). Identical across "found data" and "found nothing" runs — no useful signal at this level.
3. **Child workflows** — Separate WORKFLOW_IDs spawned via `InvokeBusinessProcessService`. Linked through `WORKFLOW_LINKAGE` table. **This is where the activity signal lives.**

**WORKFLOW_LINKAGE columns:** `ROOT_WF_ID` (numeric), `P_WF_ID` (numeric), `C_WF_ID` (numeric), `TYPE` (nvarchar 254). TYPE is always `Dispatch` for FA processes. No grandchild workflows observed — the hierarchy is exactly 2 levels deep.

**Naming chain:** `SCHEDULE.SERVICENAME` = `FA_CLIENTS_GET_LIST` → `WFD.NAME` = `FA_CLIENTS_GET_LIST` → `WORKFLOW_CONTEXT.SERVICE_NAME` = `Scheduler_FA_CLIENTS_GET_LIST` (Scheduler_ prefix added at execution) → Integration `CLIENTS_SCHEDULES.BP_NAME` = `FA_CLIENTS_GET_LIST`

### Activity Detection via Child Step Count Baseline

**Core discovery:** Each Scheduler_FA_* process produces a consistent "nothing happened" fingerprint — a specific child count and total step count — when it runs and finds nothing to process. When data IS processed, these metrics deviate from baseline.

**Inbound process example (Scheduler_FA_FROM_WOMANS_HOSPITAL_IB_BD_PULL):**

| Execution | Time | Children | Total Steps | Max Steps | Result |
|-----------|------|----------|-------------|-----------|--------|
| Empty run | 13:47 | 2 | 108 | 54 | Nothing found |
| Empty run | 12:47 | 2 | 108 | 54 | Nothing found |
| File found | 06:47 | 2 | 146 | 92 | One child elevated from 54→92 steps |
| File found (daily) | 07:05 | 4+ | varies | varies | Additional children spawned |

**Outbound process example (Scheduler_FA_TO_HSS_VISPA_OB_EO_PUSH):**

| Execution | Time | Children | Total Steps | Max Steps | Result |
|-----------|------|----------|-------------|-----------|--------|
| Empty run | 09:52 | 3 | 171 | 60 | Nothing to send |
| Empty run | 06:52 | 3 | 171 | 60 | Nothing to send |
| Data run | 12:52 | 3 | 1,274 | 1,023 | Data processed and sent |

**Step-by-step divergence point:** At the `DecisionEngineService` step within child workflows, `ADV_STATUS = 1` means "found something, proceed" and `ADV_STATUS = 2` means "nothing here, skip." When a file is found, extra steps appear: `SFTPClientGet`, `SFTPClientDelete`, `Translation`, `SFTPClientPut`.

**Baseline fingerprint validated** across 250+ processes over 2 days. Empty runs are completely uniform per-process.

### Inbound vs Outbound Detection Patterns

The activity detection approach differs by process direction:

**Inbound (FROM_) — Baseline Deviation Detection:**
- Run frequently (hourly or more), usually find nothing
- Store per-process baseline fingerprint: `baseline_child_count`, `baseline_total_steps`
- When `total_child_steps > baseline_total_steps` → activity detected
- Deviation magnitude indicates volume of work (e.g., 1,274 vs 171 baseline = significant data)

**Outbound (TO_) — Expected Delivery Verification:**
- Run daily (typically once), almost always have data to send
- No "empty baseline" to compare against — process should be working every time
- Detection approach: check for `SFTPClientPut` in child workflow steps as proof of file delivery
- Alert scenario 1: Expected daily process did not execute at all
- Alert scenario 2: Process executed but no child workflow contains `SFTPClientPut` (nothing was delivered)
- `has_sftp_put = 1` observed on virtually all outbound child workflows that successfully delivered files
- Some outbound processes have mixed children (one with SFTPClientPut, one without) — different sub-operations within the same parent

**Both approaches are purely from b2bi — no Integration dependency for activity detection.**

### WORKFLOW_CONTEXT — Columns to Collect

| b2bi Column | xFACts Column | Purpose |
|-------------|---------------|---------|
| WORKFLOW_ID (numeric) | workflow_id | Unique execution ID; correlation key to Integration RUN_ID |
| WFD_ID | workflow_def_id | Workflow definition identifier |
| WFD_VERSION | workflow_def_version | Workflow definition version |
| SERVICE_NAME | service_name | Process name (e.g., Scheduler_FA_FROM_REVSPRING_IB_BD_PULL) |
| DOC_ID | doc_id | Link to DOCUMENT table |
| BASIC_STATUS | status_code | Status (0=success, 1=warning, 10=SFTP, 100+=error) |
| ADV_STATUS | status_message | Detailed status text |
| START_TIME | start_time | Execution start |
| END_TIME | end_time | Execution end |
| NODEEXECUTED | node_executed | Server node |

### Child Rollup Metrics (derived from WORKFLOW_LINKAGE + WORKFLOW_CONTEXT)

| Metric | Source | Purpose |
|--------|--------|---------|
| child_workflow_count | COUNT from WORKFLOW_LINKAGE | How many children spawned |
| total_child_steps | SUM of step counts across children | Aggregate work volume |
| max_child_steps | MAX step count among children | Largest single child operation |
| has_sftp_put | ANY child has SFTPClientPut step | File was delivered outbound |
| has_sftp_get | ANY child has SFTPClientGet step | File was retrieved inbound |
| has_translation | ANY child has Translation step | Data transformation occurred |

### Sub-Step Service Inventory

| Service | Occurrences (4hr sample) | Process Count | Purpose |
|---------|-------------------------|---------------|---------|
| AssignService | 1,629 | 95 | Variable assignment plumbing |
| AS2LightweightJDBCAdapter | 971 | 96 | Database operations (reads/writes to Integration) |
| DecisionEngineService | 856 | 95 | Branch decisions (ADV_STATUS 1=proceed, 2=skip) |
| This | 478 | 93 | Self-referencing service call |
| ReleaseService | 340 | 87 | Resource/lock release |
| InlineInvokeBusinessProcessService | 334 | 94 | Inline sub-process invocation (ADV_STATUS shows begin/end markers) |
| InvokeBusinessProcessService | 312 | 83 | Spawns child workflows (linkage via WORKFLOW_LINKAGE) |
| SFTPClientBeginSession/Cd/List/EndSession | rare | 2 | SFTP operations (file transfer processes) |
| SFTPClientGet/Put/Delete | rare | varies | Actual file retrieval/delivery/cleanup |
| Translation | rare | varies | Data transformation |
| SMTP_SEND_ADAPTER | rare | 2 | Email delivery |
| FA_CLA_* | rare | 1 | Custom Frost Arnett services |

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
- 6 cases of parent-success/child-failure observed (BUSINESS_PROCESS_MARK status 900 at identical timestamps) — likely purge service marking, not real processing failures

### DOCUMENT — Columns to Collect

| b2bi Column | xFACts Column | Purpose |
|-------------|---------------|---------|
| DOC_ID | doc_id | Unique document identifier |
| DOC_NAME | doc_name | Original filename (filter: NOT NULL only) |
| DOCUMENT_SIZE | document_size | File size in bytes |
| WORKFLOW_ID | workflow_id | Link to WorkflowTracking |
| BODY_NAME | file_reference | Storage reference |
| CREATE_TIME | create_time | Processing timestamp |

**Note:** DOC_ID is NULL on all Scheduler_FA_* parent workflows — documents are at the child workflow level only.

### SCHEDULE Table

595 rows (479 active FA processes, 87 inactive). `SERVICENAME` maps to `WORKFLOW_CONTEXT.SERVICE_NAME` with `Scheduler_` prefix. `EXECUTIONDATE`/`EXECUTIONHOUR`/`EXECUTIONMINUTE` are all zeros; `EXECUTIONTIMER=1`. Actual timing buried in `TIMINGXML` (opaque internal IDs). Use Integration's `CLIENTS_SCHEDULES` for readable schedules instead.

### WFD Table

Workflow definition registry: `WFD_ID` + `WFD_VERSION` = template with `DESCRIPTION` (change notes), `EDITED_BY`, `MOD_DATE`. Multiple versions per process — useful for tracking definition changes over time.

---

## Data Source 2: Integration Database (AVG-PROD-LSNR)

### Purpose in Module

Business context enrichment, batch lifecycle tracking, and historical analysis. Provides structured batch status data, file transfer details, client identification, and schedule definitions. Contains 5 years of history (since June 2021). Resides on the AG — local read access.

**Critical design principle:** Integration is the enrichment layer for *what happened*, not the source of truth for *whether something happened*. Activity detection must come from b2bi to ensure reliability. Integration tables may have write latency, missing rows for certain failure modes, or incomplete data for edge cases.

### Correlation Key

**Confirmed:** `WORKFLOW_ID` (numeric) in b2bi = `RUN_ID` in Integration. 20/20 match rate verified.

**Note:** b2bi and Integration are on separate servers (FA-INT-DBP and AVG-PROD-LSNR respectively) with no linked server connectivity. Cross-database joins are not possible — correlation must be done in the collector script via separate queries.

### Key Tables — Execution and Lifecycle

| Table | Rows | Purpose |
|-------|------|---------|
| etl.tbl_B2B_CLIENTS_BATCH_STATUS | 1,542,058 | **Primary lifecycle tracker.** CLIENT_ID, SEQ_ID, PARENT_ID, RUN_ID, BATCH_ID, BATCH_STATUS, INSERT_DATE, FINISH_DATE. History to June 2021. |
| etl.tbl_B2B_CLIENTS_BATCH_STATUS_CROSSWALK | 8 | Status code reference |
| etl.tbl_B2B_CLIENTS_BATCH_FILES | 2,383,319 | **File transfer inventory.** FILE_NAME, FILE_SIZE, COMM_METHOD. |

### BATCH_STATUS Structure

Each execution (RUN_ID) produces multiple BATCH_STATUS rows:
- One row with `SEQ_ID = NULL` — the parent/summary row (BATCH_STATUS typically 2 = BP COMPLETED)
- One or more rows with specific `SEQ_ID` values — per-operation results (RELEASED/POSTED, EMPTY FILE, DUPLICATE FILE, etc.)

Each SEQ_ID represents a different file type or operation within the process. Example for Womans Hospital:
- SEQ_ID NULL: parent row (BP COMPLETED)
- SEQ_ID 8: one file check (often EMPTY FILE)
- SEQ_ID 9: another file check (EMPTY FILE or RELEASED/POSTED)
- SEQ_ID 1-4: daily load operations (mix of RELEASED/POSTED, EMPTY FILE, DUPLICATE FILE)

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
| etl.tbl_B2B_CLIENTS_SCHEDULES | 856 | **Human-readable schedules.** BP_NAME, RUN_DATE (Everyday/Monday/1 Month/etc.), TIME_START, STATUS. No CLIENT_ID column — BP_NAME contains client name segments (fuzzy match only). |
| etl.tbl_B2B_CLIENTS_PARAM | 25,100 | Process parameters (key-value pairs). Not collected — query live if needed. |
| etl.tbl_B2B_CLIENTS_FILES | 2,380 | Client file configuration. |

### Schedule Frequency Patterns

| RUN_DATE Pattern | Count | Meaning |
|------------------|-------|---------|
| Everyday | 170 | Runs every day |
| Monday, Tuesday, etc. | varies | Specific weekday |
| 1 Month, 10 Month, etc. | varies | Specific day of month (digit = day) |
| LDOM Month | varies | Last day of month |

`TIME_END` is mostly 00:00:00 (fire-once processes, not windows).

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

### Investigation Items (Partially Resolved)

| Item | Status | Notes |
|------|--------|-------|
| What writes to etl.tbl_B2B_* tables? | Likely business processes | AS2LightweightJDBCAdapter steps in child workflows write to Integration |
| Write latency (Sterling → Integration) | Near-instant observed | INSERT_DATE in Integration tracks closely with b2bi START_TIME |
| SEQ_ID → process type mapping | **Still blocking** | Ask team — varies by client/process, maps to different file operations |
| BATCH_ID interpretation by process type | Ask team | Determines DM batch correlation approach |

### Investigation Items (Non-Blocking)

| Item | Status | Notes |
|------|--------|-------|
| ~320 additional Integration tables | Unexplored | May contain additional useful data |
| FILES_LOG table | Investigated | Misnamed — it's a config change audit log, not file processing metrics |
| Naming suffixes S2D, S2P, D2S, P2S | Ask team lead | S = SQL confirmed; others TBD |
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

### Table Prefix Convention

Tables within B2B schema use prefixes to indicate data source origin:
- **`SI_`** — Data sourced from b2bi (Sterling Integrator) database on FA-INT-DBP
- **`INT_`** — Data sourced from Integration database on AVG-PROD-LSNR

This provides a clear visual boundary on where data originates without requiring separate components.

### Registration ✅ IMPLEMENTED

- **Module_Registry:** B2B — "IBM Sterling B2B Integrator file transfer and ETL processing monitoring"
- **Component_Registry:** B2B (single component — same pattern as BatchOps, BIDATA, FileOps)
- **System_Metadata:** version 1.0.0

### Data Flow

```
b2bi (FA-INT-DBP)                Integration (AG)
WORKFLOW_CONTEXT  ──┐         BATCH_STATUS  ──┐
WORKFLOW_LINKAGE  ──┤         BATCH_FILES   ──┤
DOCUMENT          ──┤         CLIENTS_MN    ──┤
                    │                         │
                    ▼                         ▼
              Collect-B2BWorkflow.ps1
              (10-min cycle)
              - Parent workflows from b2bi
              - Child rollup via WORKFLOW_LINKAGE
              - Activity detection: baseline vs actual
              - Enrichment from Integration
                    │
                    ▼
              ┌─────────────────────────────────┐
              │     xFACts B2B Schema (AG)      │
              │  SI_WorkflowTracking            │
              │  SI_ProcessBaseline             │
              │  INT_ClientRegistry             │
              │  INT_ScheduleConfig             │
              └─────────────┬───────────────────┘
              ┌─────────────┘
              │     xFACts dbo Schema (AG)      │
              │  ClientHierarchy (shared)        │
              └─────────────┬───────────────────┘
                            │
                    Monitor-B2B.ps1
                    (30-60 min cycle)
                            │
                    ┌───────┴───────┐
                    │  Teams/Jira   │
                    └───────────────┘
```

### Core Tables

| Table | Prefix | Purpose |
|-------|--------|---------|
| dbo.ClientHierarchy | — | **Shared infrastructure.** ✅ Complete DM creditor hierarchy for crosswalk and client resolution. |
| B2B.SI_WorkflowTracking | SI_ | Consolidated execution records from b2bi with child workflow rollup metrics. Activity detection via baseline comparison. |
| B2B.SI_ProcessBaseline | SI_ | Per-process baseline fingerprints (baseline_child_count, baseline_total_steps) for activity detection. |
| B2B.INT_ClientRegistry | INT_ | Client lookup from Integration CLIENTS_MN (CLIENT_ID, CLIENT_NAME, ACTIVE_FLAG, AUTOMATED). |
| B2B.INT_ScheduleConfig | INT_ | Schedule definitions from Integration CLIENTS_SCHEDULES (stored as-is from source). |

### SI_WorkflowTracking — Proposed Columns

| Column | Source | Purpose |
|--------|--------|---------|
| workflow_id | b2bi WORKFLOW_ID | PK; correlation key to Integration RUN_ID |
| workflow_def_id | b2bi WFD_ID | Template identifier |
| workflow_def_version | b2bi WFD_VERSION | Template version |
| service_name | b2bi SERVICE_NAME | Process name |
| status_code | b2bi BASIC_STATUS | Execution status |
| status_message | b2bi ADV_STATUS | Detail text |
| start_time | b2bi START_TIME | Execution start |
| end_time | b2bi END_TIME | Execution end |
| node_executed | b2bi NODEEXECUTED | Server node |
| child_workflow_count | WORKFLOW_LINKAGE rollup | Number of children spawned |
| total_child_steps | WORKFLOW_LINKAGE rollup | Aggregate step count across all children |
| max_child_steps | WORKFLOW_LINKAGE rollup | Largest single child step count |
| has_sftp_get | Child step scan | File retrieved inbound (BIT) |
| has_sftp_put | Child step scan | File delivered outbound (BIT) |
| has_translation | Child step scan | Data transformation occurred (BIT) |
| had_activity | Computed | `total_child_steps > baseline_total_steps` (BIT) |
| collected_dttm | System | When collected by xFACts |

### SI_ProcessBaseline — Proposed Columns

| Column | Purpose |
|--------|---------|
| service_name (PK) | Process name (Scheduler_FA_*) |
| process_direction | Derived: INBOUND, OUTBOUND, INTERNAL |
| baseline_child_count | Most common child count across recent executions |
| baseline_total_steps | Most common total child steps across recent executions |
| baseline_occurrences | How many executions matched baseline (confidence level) |
| total_executions_sampled | Total executions in sample window |
| max_observed_steps | Highest total_child_steps ever seen |
| last_calculated_dttm | When baseline was last recalculated |

### Scripts

| Script | Source(s) | Frequency | Purpose |
|--------|-----------|-----------|---------|
| Sync-ClientHierarchy.ps1 | crs5_oltp | Daily | ✅ Rebuilds dbo.ClientHierarchy via recursive CTE MERGE. |
| Collect-B2BWorkflow.ps1 | b2bi + Integration | Every 10 min | Captures parent workflows from b2bi, follows WORKFLOW_LINKAGE for child rollup, compares against SI_ProcessBaseline, enriches from Integration. |
| Monitor-B2B.ps1 | xFACts B2B tables | Every 30-60 min | Evaluates data, detects failures/missing processes, queues alerts. |
| Sync-B2BConfig.ps1 | Integration | Daily | Syncs schedules and clients into INT_ScheduleConfig and INT_ClientRegistry. |

### Control Center Page

Dedicated "B2B Monitoring" page: process status overview, failure feed, missing process alerts, file transfer activity, volume trends, client-grouped views, process detail slideout.

---

## Build Readiness Assessment

### Completed ✅

| Item | Status |
|------|--------|
| `dbo.ClientHierarchy` DDL + indexes | Deployed to both AG nodes |
| `Sync-ClientHierarchy.ps1` | Built, tested, executed successfully |
| Object_Registry + Object_Metadata for ClientHierarchy table | Populated |
| Object_Registry + Object_Metadata for Sync-ClientHierarchy.ps1 | Populated |
| Module_Registry (B2B) | Registered |
| Component_Registry (B2B) | Registered |
| System_Metadata baseline (1.0.0) | Set |
| B2B schema | Confirmed exists |

### Ready to Build Next

| Item | Rationale |
|------|-----------|
| `B2B.SI_ProcessBaseline` table | Design is clear from baseline fingerprint analysis. Seed from b2bi immediately. |
| `B2B.SI_WorkflowTracking` table | Column design is solid. Child rollup approach is proven. |
| `B2B.INT_ClientRegistry` table | Simple mirror of CLIENTS_MN. |
| `B2B.INT_ScheduleConfig` table | Store CLIENTS_SCHEDULES as-is. |
| `Collect-B2BWorkflow.ps1` | Core collector with b2bi parent + WORKFLOW_LINKAGE child rollup + baseline comparison. Integration enrichment can be layered in incrementally. |
| `Sync-B2BConfig.ps1` | Reads well-understood tables (CLIENTS_SCHEDULES, CLIENTS_MN). |
| ProcessRegistry entry for Sync-ClientHierarchy.ps1 | Needed for orchestrator scheduling. |

### Deferred — Waiting on Team Input

| Item | Blocking Question |
|------|-------------------|
| Integration enrichment in Collect-B2BWorkflow.ps1 | SEQ_ID → process type mapping still needed to know exactly which Integration columns to pull |
| `Monitor-B2B.ps1` | Depends on WorkflowTracking + ProcessBaseline being populated with real data |
| B2B.DocumentTracking | May be affected by BATCH_FILES overlap — need to confirm whether b2bi DOCUMENT adds value beyond Integration BATCH_FILES |

---

## Historical Data

| Source | Earliest | Latest | Rows |
|--------|----------|--------|------|
| Integration BATCH_STATUS | 2021-06-23 | Current | 1,542,058 |
| Integration BATCH_FILES | TBD | Current | 2,383,319 |
| Integration CLIENTS_ACCTS | TBD | Current | 34,372,524 |
| b2bi WORKFLOW_CONTEXT | ~2-3 days back | Current | ~4,600/day |

**No historical backload required.** Integration contains 5 years of structured history. b2bi data will be collected going forward only.

---

## Client Structure

### B2B Client Inventory

718 clients in `tbl_B2B_CLIENTS_MN` (CLIENT_ID, CLIENT_NAME, ACTIVE_FLAG, AUTOMATED).

### DM Crosswalk

B2B CLIENT_ID → DM Creditor Keys via `CLIENTS_ACCTS.CREDITOR_NAME` → resolved through `dbo.ClientHierarchy`. Relationship is predominantly one-to-many (one B2B client → many DM creditor keys rolling up to a common parent). Crosswalk derived from actual data flow.

---

## Implementation Phases

### Phase 1: Foundation ✅ COMPLETE

1. ✅ Build `dbo.ClientHierarchy` table and refresh script
2. ✅ Create B2B schema (confirmed exists)
3. ✅ Register in Module_Registry, Component_Registry, Object_Registry
4. ✅ System_Metadata baseline (1.0.0)

### Phase 2: Core Tables and Collection (Ready Now)

1. Build `B2B.SI_ProcessBaseline` table; seed from b2bi baseline fingerprint query
2. Build `B2B.SI_WorkflowTracking` table with child rollup columns
3. Build `B2B.INT_ClientRegistry` table; seed from CLIENTS_MN
4. Build `B2B.INT_ScheduleConfig` table; seed from CLIENTS_SCHEDULES
5. Build `Collect-B2BWorkflow.ps1` — b2bi parent workflows + WORKFLOW_LINKAGE child rollup + baseline comparison + activity flag
6. Build `Sync-B2BConfig.ps1` — daily sync of INT_ClientRegistry and INT_ScheduleConfig
7. Create ProcessRegistry entries for all scripts
8. Register all objects in Object_Registry + Object_Metadata

### Phase 3: Integration Enrichment (After Team Input)

1. Finalize Integration enrichment columns in SI_WorkflowTracking (informed by SEQ_ID mapping)
2. Add Integration BATCH_STATUS/BATCH_FILES enrichment to Collect-B2BWorkflow.ps1
3. Determine `B2B.DocumentTracking` necessity (b2bi DOCUMENT vs Integration BATCH_FILES)

### Phase 4: Monitoring and Alerting

1. Build `Monitor-B2B.ps1`
2. Integrate with Teams and Jira
3. Configure monitoring thresholds on critical processes
4. Validate alert accuracy

### Phase 5: Control Center Page

1. Build B2B Monitoring CC page (route, API, CSS, JS)
2. Process status, failure feed, file transfers, volume trends
3. Client-grouped views with ClientHierarchy resolution
4. Engine indicator integration

### Phase 6: Enhanced Analytics (Future)

1. Volume and duration anomaly detection
2. End-to-end file lifecycle (FileOps → B2B → BatchOps)
3. DM batch correlation via BATCH_ID
4. Historical trend analysis
5. Baseline drift detection (auto-recalculate when process definitions change)

---

## Open Questions

### For Integration Team (Partially Blocking Phase 3)

1. What writes to the `etl.tbl_B2B_*` tables? (Sterling adapters? Separate ETL?)
2. What do SEQ_ID values represent? (process type mapping — **blocking Integration enrichment**)
3. How is BATCH_ID populated for different process types?

### For Team Lead

1. What do S2D, S2P, D2S, P2S mean? (S = SQL confirmed; others TBD)
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

-- Child rollup for a specific parent workflow
SELECT 
    wl.ROOT_WF_ID,
    wl.C_WF_ID,
    wc.SERVICE_NAME AS child_service,
    sub.total_steps,
    sub.doc_count,
    sub.has_sftp_put,
    sub.has_sftp_get,
    sub.has_translation
FROM b2bi.dbo.WORKFLOW_LINKAGE wl
LEFT JOIN b2bi.dbo.WORKFLOW_CONTEXT wc 
    ON wc.WORKFLOW_ID = wl.C_WF_ID AND wc.STEP_ID = 0
OUTER APPLY (
    SELECT 
        COUNT(*) AS total_steps,
        COUNT(s.DOC_ID) AS doc_count,
        MAX(CASE WHEN s.SERVICE_NAME = 'SFTPClientPut' THEN 1 ELSE 0 END) AS has_sftp_put,
        MAX(CASE WHEN s.SERVICE_NAME = 'SFTPClientGet' THEN 1 ELSE 0 END) AS has_sftp_get,
        MAX(CASE WHEN s.SERVICE_NAME = 'Translation' THEN 1 ELSE 0 END) AS has_translation
    FROM b2bi.dbo.WORKFLOW_CONTEXT s
    WHERE s.WORKFLOW_ID = wl.C_WF_ID AND s.STEP_ID > 0
) sub
WHERE wl.ROOT_WF_ID = <WORKFLOW_ID>
ORDER BY wl.C_WF_ID;

-- Baseline fingerprint calculation (all Scheduler_FA_* processes)
;WITH ProcessRuns AS (
    SELECT 
        wc.SERVICE_NAME,
        wc.WORKFLOW_ID,
        child.child_count,
        child.total_child_steps
    FROM b2bi.dbo.WORKFLOW_CONTEXT wc
    OUTER APPLY (
        SELECT 
            COUNT(*) AS child_count,
            ISNULL(SUM(sub.step_count), 0) AS total_child_steps
        FROM b2bi.dbo.WORKFLOW_LINKAGE wl
        OUTER APPLY (
            SELECT COUNT(*) AS step_count
            FROM b2bi.dbo.WORKFLOW_CONTEXT s
            WHERE s.WORKFLOW_ID = wl.C_WF_ID AND s.STEP_ID > 0
        ) sub
        WHERE wl.ROOT_WF_ID = wc.WORKFLOW_ID
    ) child
    WHERE wc.STEP_ID = 0
      AND wc.SERVICE_NAME LIKE 'Scheduler_FA_%'
      AND wc.START_TIME >= DATEADD(DAY, -2, GETDATE())
      AND child.child_count > 0
),
RunCounts AS (
    SELECT SERVICE_NAME, child_count, total_child_steps,
           COUNT(*) AS execution_count
    FROM ProcessRuns
    GROUP BY SERVICE_NAME, child_count, total_child_steps
),
RankedBaselines AS (
    SELECT SERVICE_NAME, child_count, total_child_steps, execution_count,
           ROW_NUMBER() OVER (PARTITION BY SERVICE_NAME ORDER BY execution_count DESC) AS rn
    FROM RunCounts
)
SELECT rb.SERVICE_NAME, rb.child_count AS baseline_child_count,
       rb.total_child_steps AS baseline_total_steps,
       rb.execution_count AS baseline_occurrences,
       agg.total_executions,
       agg.total_executions - rb.execution_count AS deviated_executions,
       agg.max_child_steps AS max_observed_steps
FROM RankedBaselines rb
CROSS APPLY (
    SELECT COUNT(*) AS total_executions, MAX(total_child_steps) AS max_child_steps
    FROM ProcessRuns pr WHERE pr.SERVICE_NAME = rb.SERVICE_NAME
) agg
WHERE rb.rn = 1
ORDER BY deviated_executions DESC, rb.SERVICE_NAME;
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

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Author | Applications Team |
| Created | January 13, 2026 |
| Revised | April 16, 2026 |
| Status | Active — Phase 1 Complete, Phase 2 Ready to Build |
| Schema | B2B |
| Primary Source | b2bi on FA-INT-DBP (real-time, activity detection) + Integration on AG (enrichment/history) |
| Correlation Key | b2bi WORKFLOW_ID (numeric) = Integration RUN_ID |
| Prerequisite | dbo.ClientHierarchy ✅ (shared infrastructure — implemented) |

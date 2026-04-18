# B2B Integrator Module - Planning Document

## Executive Summary

IBM Sterling B2B Integrator (commonly referred to as "IBM" or "IBM B2B" internally) is the platform's file transfer and ETL processing engine handling inbound and outbound file transfers between FAC and its trading partners. The system processes new business placements, payment files, notes, returns, reconciliation files, and numerous other data exchanges between FAC and its clients, and is the backbone of the ETL pipeline feeding DM.

Historically, Sterling has operated as an opaque "black box" in the FAC environment — implemented by a prior IT manager who has since departed, and extended over several years by a separate Integration team whose original architects are no longer with the company. The Integration team's infrastructure (housed in the `Integration` database on the AG, built during 2020-2021) consists of roughly 320 tables and hundreds of stored procedures that collectively process and stage data between Sterling and DM. This infrastructure was built in a silo, often without attention to database design best practices (e.g., `CLIENTS_ACCTS`, a 34.7M-row table, shipped with only a primary key on its identity column — investigative queries taking minutes that dropped to seconds with basic nonclustered indexes), and documentation of how it all fits together is sparse. The Integration team has since been absorbed into Applications & Integration, and ongoing understanding of this infrastructure is being rebuilt gradually.

The xFACts B2B module's mandate is to build operational visibility over this critical data pipeline — detecting failures, tracking schedule adherence, surfacing execution history, and providing a real-time window into what's happening inside the Sterling processing layer. The investigation phase has been extensive, and the resulting architecture takes an authoritative, source-first approach:

**The xFACts B2B module is pure b2bi-driven.** All execution tracking, scheduling, and business-level activity data is captured directly from Sterling's own tables in the `b2bi` database on FA-INT-DBP. Integration-side tables are bypassed for data collection purposes. The only Integration table referenced operationally is `CLIENTS_MN`, mirrored into `B2B.INT_ClientRegistry` for client-name humanization in the UI.

This architecture was made possible by a key investigative breakthrough: Sterling's `TRANS_DATA` table, which stores gzip-compressed workflow transaction payloads, was initially believed to contain proprietary encrypted data. Investigation revealed the data is standard gzip-compressed XML, and every workflow execution's `ProcessData` document contains the complete client identity, process type, translation configuration, and runtime behavior flags for that run. Combined with `WORKFLOW_CONTEXT` (step-level execution log) and `WF_INST_S` (workflow instance summary), this provides source-of-truth data for every process type — including process types (like payments) that have no corresponding Integration-side tables at all.

The architectural principle: **Sterling knows what it did, and Sterling records it.** The B2B module reads Sterling directly, bypassing Integration's interpretive layer. This gives real-time accuracy, universal coverage across all process types, and independence from Integration-side ETL bugs or latency.

The eventual goal is end-to-end file lifecycle tracking spanning the full platform: File Monitoring (SFTP receipt) → B2B (Sterling ETL processing) → Batch Monitoring (DM loading).

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
- B2B module: resolves DM creditor keys found in Sterling-extracted VITAL XML business data to DM hierarchy for crosswalk/grouping
- Future: any module needing DM client hierarchy resolution

**Pending:**
- ProcessRegistry entry for daily orchestrator execution

---

## Background

### Current State

Sterling was implemented by a prior IT Manager and operates as a black box from Apps/Int's perspective. Substantial infrastructure exists in the Integration database to stage and process data between Sterling and DM, but this infrastructure was built by a separate team whose original architects are no longer with the company. The Integration team has since been absorbed into Apps/Int, but institutional knowledge of Sterling internals, Integration ETL design, and the interactions between the two has to be reconstructed.

No monitoring or alerting layer exists on top of any of this. When a Sterling workflow fails, when an expected file doesn't arrive, when a scheduled process doesn't run — there is no proactive visibility. Issues are typically discovered when someone calls to ask where a file is.

### Pain Points

| Issue | Impact |
|-------|--------|
| No proactive failure alerting | Issues discovered only when someone complains |
| Aggressive data purging in b2bi | ~2-3 day retention on most operational tables; 10-minute purge cycle |
| Missing process detection gap | Scheduled processes that don't run go unnoticed for days/weeks |
| No volume monitoring | Cannot detect "we got 0 files when we expected 50" |
| No schedule monitoring | Cannot detect "this daily process didn't run" |
| Limited historical visibility in Sterling UI | ~48 hours; filesystem archives are binary |
| No institutional knowledge | Original implementer and Integration team architects no longer at FAC |
| Complex client mapping | B2B client structure independent from DM with many-to-many relationships |
| Integration database poorly documented | ~320 tables, key-value parameter design, type-specific data tables, undocumented stored procedures |
| Integration database design quality concerns | Tables built without standard indexing practice; data integrity/validation rigor unknown |

### Why a Source-of-Truth Approach

The historical pattern in this environment has been to build downstream layers that interpret upstream data, then build further layers that interpret those interpretations. Integration's `CLIENTS_BATCH_STATUS` interprets Sterling's workflow state. Integration's `CLIENTS_SCHEDULES` is a summarized text version of Sterling's `SCHEDULE` + timing XML. And so on.

Each interpretation layer introduces opportunities for data loss, lag, and bugs. The B2B module deliberately breaks this pattern by going to the authoritative source (Sterling) for everything critical. If Integration has its own business-value reason to exist — as it does for payment bucket allocation via `USP_PAYMENT_INTEREST_ACCOUNTS`, for example — that's fine; Integration continues to serve its purpose. But xFACts' monitoring layer doesn't depend on Integration being correct, complete, or timely.

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

**Cross-server consideration:** b2bi (on FA-INT-DBP) and Integration (on AVG-PROD-LSNR) are on separate servers with no linked server connectivity. Cross-database joins are not possible. Where data from both environments is needed for a logical operation (e.g., Integration client-name humanization applied to Sterling execution records), this is handled in the xFACts collector scripts via separate queries, not in SQL joins.

---

## Module Architecture Overview

### Core Approach

The B2B module is built around three layers:

**1. Sterling data extraction (the core).** The collector reads from Sterling's operational tables (`WORKFLOW_CONTEXT`, `WF_INST_S`, `SCHEDULE`, `WFD`, `DATA_TABLE`, `TRANS_DATA`) to capture what's actually happening inside the ETL engine. This includes decompressing targeted gzip-compressed documents in `TRANS_DATA` to extract `ProcessData` XML — the self-describing metadata that Sterling itself uses to drive each workflow run.

**2. xFACts B2B schema (the persistence layer).** Sterling data is written to dedicated B2B-schema tables in the xFACts database on the AG. These tables are designed for stable querying by UI and alerting code without the aggressive purge cycle that governs Sterling's operational tables.

**3. Monitoring, alerting, and UI (the consumption layer).** Scheduled monitoring scripts evaluate the data in xFACts tables to detect failures, missing runs, unusual volumes, etc. A dedicated Control Center B2B page provides visualization and drill-down.

### Schema and Naming Conventions

Tables within the B2B schema use prefixes to indicate data source origin:

- **`SI_`** — Data sourced from b2bi (**S**terling **I**ntegrator) database on FA-INT-DBP
- **`INT_`** — Data sourced from Integration database on AVG-PROD-LSNR

With the pure b2bi architecture, the B2B schema is dominated by `SI_` tables. Only one `INT_` table is planned: `INT_ClientRegistry` (CLIENT_ID-to-CLIENT_NAME lookup for UI display).

### Registration ✅ IMPLEMENTED

- **Module_Registry:** B2B — "IBM Sterling B2B Integrator file transfer and ETL processing monitoring"
- **Component_Registry:** B2B (single component — same pattern as BatchOps, BIDATA, FileOps)
- **System_Metadata:** version 1.0.0

### Data Flow

```
                  FA-INT-DBP (b2bi)
          ┌──────────────────────────────┐
          │  SCHEDULE / WFD / DATA_TABLE │  ← schedule definitions + timing XML
          │  WF_INST_S                    │  ← workflow instance summaries
          │  WORKFLOW_CONTEXT             │  ← step-by-step execution log
          │  WORKFLOW_LINKAGE             │  ← parent/child workflow relationships
          │  TRANS_DATA                   │  ← gzip-compressed workflow payloads
          └──────────────┬────────────────┘
                         │
                         ▼
                ┌────────────────────┐
                │ Collect-B2BWorkflow│  ← core collector
                │ (5-15 min cycle)   │    - reads recent workflows from WF_INST_S
                │                    │    - joins WORKFLOW_CONTEXT for step data
                │                    │    - targeted TRANS_DATA decompression
                │                    │    - parses ProcessData for all <Client> blocks
                └──────────┬─────────┘
                           │
                           ▼
              ┌───────────────────────────┐    ┌─────────────────────┐
              │   xFACts B2B Schema (AG)  │    │  AVG-PROD-LSNR      │
              │   SI_ScheduleRegistry     │    │  (Integration DB)   │
              │   SI_ExecutionTracking    │    │  CLIENTS_MN         │
              │   SI_ProcessDataCache     │    └──────────┬──────────┘
              │   SI_WorkflowTracking     │               │
              │   SI_ProcessBaseline      │               │  daily sync
              │   INT_ClientRegistry ◀────┼───────────────┘  (CLIENT_ID → name)
              └─────────────┬─────────────┘
                            │
                            ▼
                   ┌────────────────┐
                   │  Monitor-B2B   │
                   │  (30-60 min)   │
                   └────────┬───────┘
                            │
                   ┌────────┴───────┐
                   │  Teams / Jira  │
                   │  CC B2B Page   │
                   └────────────────┘
```

### Core Tables (Summary — Details in Tables Section)

| Table | Prefix | Status | Purpose |
|-------|--------|--------|---------|
| dbo.ClientHierarchy | — | ✅ Built | Shared infrastructure for DM creditor hierarchy resolution |
| B2B.SI_WorkflowTracking | SI_ | ✅ Built | Workflow execution records from WORKFLOW_CONTEXT (initial Phase 1 design) |
| B2B.SI_ProcessBaseline | SI_ | ✅ Built | Per-process activity detection baselines (from initial discovery phase) |
| B2B.INT_ClientRegistry | INT_ | ✅ Built | Client roster from Integration CLIENTS_MN |
| B2B.SI_ScheduleRegistry | SI_ | To design | Sterling SCHEDULE mirror with parsed timing XML |
| B2B.SI_ExecutionTracking | SI_ | To design | Per-WF_ID execution summary with ProcessData-extracted client/process metadata |
| B2B.SI_ProcessDataCache | SI_ | To design | Decompressed ProcessData XML storage (raw + parsed) for audit and query performance |
| B2B.SI_BusinessDataTracking | SI_ | To design (optional) | Process-type-specific business data summaries (record counts, file names) from targeted Translation output extraction |

### Evolution from Initial Design

The initial design (Phase 1, completed) was built around baseline fingerprint activity detection from `WORKFLOW_CONTEXT` step counts — a discovery-driven approach that proved viable but treated Sterling as partially opaque. The updated architecture (from this investigation phase forward) leverages Sterling's `ProcessData` documents for direct, authoritative metadata extraction — eliminating the need for inference from step counts and providing full process context (CLIENT_ID, SEQ_ID, TRANSLATION_MAP, etc.) from the source itself. The `SI_WorkflowTracking` and `SI_ProcessBaseline` tables from Phase 1 remain useful and will be retained; the new `SI_ExecutionTracking` and `SI_ProcessDataCache` tables extend the architecture with ProcessData-sourced fidelity.

---

## Sterling (b2bi) — The Authoritative Data Source

The b2bi database on FA-INT-DBP is Sterling's operational database. Every workflow that runs, every file Sterling touches, every scheduled process — all of it is recorded here. The data is aggressively purged (~2-3 day retention on most operational tables, via `Schedule_PurgeService` running every 10 minutes), but during that window it is the complete, authoritative record of what Sterling has done.

### Key Operational Tables

| Table | Rows (at investigation) | Purpose |
|-------|------------------------|---------|
| `WORKFLOW_CONTEXT` | 559,211 | Step-level execution log — one row per step per workflow run |
| `WF_INST_S` | 15,574 | Workflow instance summary — one row per workflow run |
| `WORKFLOW_LINKAGE` | 16,728 | Parent-child workflow relationships |
| `TRANS_DATA` | 1,189,451 | Gzip-compressed workflow transaction payloads (ProcessData, raw files, translation outputs, status reports) |
| `SCHEDULE` | 602 | Workflow schedule configuration |
| `WFD` | 2,462 | Workflow definition catalog (template registry) |
| `DATA_TABLE` | 49,928 | Internal document store (schedule timing XML, workflow BPML, etc.) |
| `DOCUMENT` | 233K | File/payload metadata |
| `ACT_XFER` / `ACT_NON_XFER` | 33K / 48K | SFTP transfer and non-transfer operations with WFID + WFSTEP |

**Data retention:**
- `WORKFLOW_CONTEXT` retains ~2-3 days before purging
- `*_RESTORE` tables (e.g., `TRANS_DATA_RESTORE`) are brief staging areas (~3 day window observed), not long-term storage
- `ACTIVITY_INFO` is a workflow definition catalog (33,688 rows), not runtime execution tracking

### `SCHEDULE` Table

Sterling's native scheduling table. One row per scheduled workflow.

**Key columns:**
- `SCHEDULEID` (PK)
- `SERVICENAME` — **equals `WFD.NAME` for workflow schedules.** This is the direct link from a schedule to the workflow it fires.
- `STATUS` — ACTIVE/INACTIVE
- `TIMINGXML` — document handle (e.g., `FA-INT-APPP:node1:195ddbd9955:264387511`) pointing to the compressed timing XML in `DATA_TABLE`
- `SCHEDULETYPE`, `SCHEDULETYPEID` — schedule category
- `PARAMS`, `EXECUTIONSTATUS` — runtime state and parameters

**Non-workflow entries:** The table includes internal Sterling service schedules (DBMonitorService, IWFCDriverService, AutoTerminateService, Schedule_PurgeService, etc.). These are operational internals, not client workflows. Filter by joining to `WFD.NAME` to isolate real workflow schedules.

**Authoritative schedule source.** Integration's `CLIENTS_SCHEDULES` table is a lossy, human-readable interpretation of this data (text patterns like `Everyday`, `Monday`, `1 Month` rather than structured rules) and is missing many schedules entirely (e.g., 5 LIFESPAN R1 entries in Integration vs. 13 in Sterling's `SCHEDULE`). Sterling's `SCHEDULE` + parsed `TIMINGXML` is the canonical source.

### `WFD` Table

Workflow definition catalog. One row per workflow version — a workflow can have many versions over time.

**Key columns:**
- `WFD_ID` — numeric definition ID
- `WFD_VERSION` — version number
- `NAME` — the workflow name (matches `SCHEDULE.SERVICENAME`)
- `DESCRIPTION`, `TYPE`, `STATUS`, `MOD_DATE`, `EDITED_BY` — definition metadata

### `DATA_TABLE`

Sterling's internal document store for schedule timing, workflow BPML, and other internal references (distinct from `TRANS_DATA` which holds workflow runtime payloads).

**Key columns:**
- `DATA_ID` — the handle referenced from `SCHEDULE.TIMINGXML`, `WFD_XML.XML`, etc.
- `DATA_OBJECT` — gzip-compressed binary content (starts with `0x1F8B` magic bytes)
- `DATA_TYPE`, `REFERENCE_TABLE` — content type indicators

**Access pattern:** PowerShell decompresses via `System.IO.Compression.GZipStream`. Tested against 506 active schedules with 100% success rate.

### `WORKFLOW_CONTEXT` — Step-Level Execution Log

The most detailed execution record Sterling produces. Each workflow run generates one row per step executed.

**Key columns:**
- `WORKFLOW_ID` — joins to `WF_INST_S.WORKFLOW_ID` and `TRANS_DATA.WF_ID`
- `STEP_ID` — chronological step number within the workflow (0, 1, 2, ...)
- `SERVICE_NAME` — the service/adapter invoked at that step. Examples: `Translation`, `SFTPClientGet`, `AssignService`, `DecisionEngineService`, `InvokeBusinessProcessService`, `InlineInvokeBusinessProcessService`, `AS2LightweightJDBCAdapter`, `FA_CLA_DM_API`, `FA_CLA_WRKS_COMP`
- `DOC_ID` — handle to the step's input document in `TRANS_DATA`
- `CONTENT` — handle to the step's output/context document in `TRANS_DATA`
- `STATUS_RPT`, `WFE_STATUS_RPT` — handles to step status report documents in `TRANS_DATA`
- `ADV_STATUS` — detailed status text; critically, contains sub-workflow invocation markers like `Inline Begin FA_CLIENTS_ACCOUNTS_LOAD+817+1`
- `BASIC_STATUS` — numeric status code (0 = success, 1 = warning, 10 = SFTP, 100+ = error)
- `START_TIME`, `END_TIME` — step timing
- `WFD_ID`, `WFD_VERSION` — which workflow definition the step belongs to (changes mid-run when sub-workflows are invoked, while `WORKFLOW_ID` stays constant)

**Sub-workflow invocation markers:** When a workflow invokes a sub-workflow via `InvokeBusinessProcessService` or `InlineInvokeBusinessProcessService`, the step's `ADV_STATUS` contains an `Inline Begin <name>+<WFD_ID>+<WFD_VERSION>` marker. This is a programmatic identifier for exactly which sub-workflow is being entered — the key to understanding a workflow's business-level execution pattern. (See "ProcessData as Self-Describing Metadata" section.)

### `WF_INST_S` — Workflow Instance Summary

One row per workflow execution. Useful for finding recent workflow runs without scanning the 559K-row `WORKFLOW_CONTEXT`.

**Key columns:**
- `WORKFLOW_ID` — unique per run
- `WFD_ID`, `WFD_VERSION` — which workflow definition ran
- `START_TIME`, `END_TIME` — overall workflow timing
- `STATUS`, `STATE` — completion state
- `INITIAL_WFC_ID` — handle to the starting `WORKFLOW_CONTEXT` row
- `EXP_DATE`, `ARCHIVE_FLAG`, `ARCHIVE_DATE` — retention metadata

### `WORKFLOW_LINKAGE`

Parent-child workflow relationships. When one workflow spawns another via `InvokeBusinessProcessService` (not inline), a new `WORKFLOW_ID` is created, and this table records the parent-child link.

**Key columns:**
- `ROOT_WF_ID`, `P_WF_ID`, `C_WF_ID` — root, parent, child workflow IDs
- `TYPE` — always `Dispatch` for FA processes

### `TRANS_DATA` — Compressed Workflow Payloads

The table that unlocked the pure-b2bi architecture. Contains all the compressed workflow runtime data: `ProcessData` documents, raw input files, `Translation` outputs, status reports, and more.

**Key columns:**
- `DATA_ID` — the handle value referenced from `WORKFLOW_CONTEXT.DOC_ID`, `CONTENT`, `STATUS_RPT`, `WFE_STATUS_RPT`
- `DATA_OBJECT` — gzip-compressed binary content (magic bytes `0x1F8B`)
- `PAGE_INDEX` — multi-page support for large payloads (most rows are page 0)
- `DATA_TYPE` — content type identifier
- `WF_ID` — joins to `WORKFLOW_CONTEXT.WORKFLOW_ID`
- `REFERENCE_TABLE` — categorizes content as `DOCUMENT`, `WORKFLOW_CONTEXT`, `DOCUMENT_EXTENSION`, or other types
- `CUM_SIZE` — cumulative size for multi-page content
- `CREATION_DATE` — when the row was written (critically used for correlating rows to workflow steps by time alignment)

**What TRANS_DATA contains per workflow run:**

For a typical NB inbound run processing one file (~150 WORKFLOW_CONTEXT steps), TRANS_DATA holds ~160 rows including:
- **ProcessData XML** (one per workflow) — the self-describing metadata for the run (see next section)
- **Raw input file** — the file Sterling pulled via SFTP (e.g., `lifespan.20260417.LIFESPAN.PLACEMENT.txt.041726.3519`)
- **Translation outputs** — typically three per Translation step invocation:
  - Output 1: CSV/flat delimited representation
  - Output 2: Full XML representation
  - Output 3: Format-specific XML targeted at a specific downstream consumer (e.g., `<VITAL><TRANSACTION>` rows for CLIENTS_ACCTS loading)
- **Workflow context snapshots** — serialized Java Hashtable state at checkpoints
- **Intermediate documents** — file transformations between steps
- **Step status reports** — adapter output log entries

**Compression format:** Standard gzip. Decompressable via PowerShell `System.IO.Compression.GZipStream`. Same mechanism decompresses `DATA_TABLE.DATA_OBJECT` (schedule timing XML, BPML) and `TRANS_DATA.DATA_OBJECT` (runtime payloads).

**Content inside:** Varies by `DATA_TYPE` and content. Configuration content (schedule timing, BPML) is XML. Translation outputs are XML or CSV. ProcessData is serialized Java Hashtable with embedded XML string values. Raw input files are the file's original format (often plain text).

**Multi-page handling:** Large payloads split across multiple rows with incrementing `PAGE_INDEX`. Concatenate page-ordered `DATA_OBJECT` bytes before decompression.

**Query pattern (PowerShell):**
```powershell
Invoke-Sqlcmd ... -MaxBinaryLength 20971520   # required for large blobs
$ms = New-Object System.IO.MemoryStream(,$bytes)
$gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
$sr = New-Object System.IO.StreamReader($gz)
$content = $sr.ReadToEnd()
```

**WORKFLOW_CONTEXT ↔ TRANS_DATA correlation:** Most TRANS_DATA rows for a given `WF_ID` are directly referenced as `DOC_ID`, `CONTENT`, `STATUS_RPT`, or `WFE_STATUS_RPT` in a `WORKFLOW_CONTEXT` row. A minority (typically 10-15 out of 150-200) are unreferenced — these are adapter outputs (SFTPClientGet raw files, AS3FSAdapter collected files, Translation outputs) written to Sterling's document store without being attached to a specific step. Their `CREATION_DATE` aligns with a specific step's timing, which is how the collector finds them.

### `ACT_XFER` and `ACT_NON_XFER` Tables

Lower-level SFTP adapter logs with `WFID` + `WFSTEP` columns. Useful for SFTP-specific details (file names, bytes transferred, delete operations) but only cover SFTP activity. Not part of the core collector extraction — may be referenced for specific operational queries if needed.

---

## Timing XML Grammar (Validated)

`SCHEDULE.TIMINGXML` points to a compressed XML document in `DATA_TABLE.DATA_OBJECT`. Decompressed, it follows a small and well-behaved grammar. Tested against all 506 active schedules at the time of investigation — 73 distinct structural patterns observed (after normalizing specific time values), all conforming to:

```xml
<timingxml>
  <days>
    <day ofWeek|ofMonth="VALUE">
      <times>
        <time>HHMM</time>
        <!-- optionally more <time> entries -->
      </times>
    </day>
    <!-- optionally more <day> entries -->
  </days>
  <excludedDates>
    <!-- optionally populated -->
    <date>MM-DD</date>
  </excludedDates>
</timingxml>
```

**Day specifiers:**
- `ofWeek="-1"` — every day
- `ofWeek="1"` through `ofWeek="7"` — specific day of week (2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri confirmed by Mon-Fri 5-block patterns; 1=Sun seen rarely; 7=Sat not observed)
- `ofMonth="1"` through `ofMonth="31"` — specific day of month

**Multi-day schedules:** Separate `<day>` children per day (Mon-Fri is five `<day>` blocks, not a range).

**Multiple times per day:** Multiple `<time>` children within one `<times>` block.

**Combined day-of-week and day-of-month:** Not observed. Schedules are either weekday-based or date-based, never mixed.

**Excluded dates:** Format `MM-DD`, year-agnostic (e.g., `12-25` excludes Christmas every year). Must be honored when computing expected run dates.

**Case variants:** Sterling system services emit `<TimingXML>` (PascalCase, whitespace-formatted); FA-created workflows emit `<timingxml>` (lowercase, compact). XML parsing handles both the same.

**Top 10 structural patterns (506 active schedules):**

| Count | Structure | Notes |
|---|---|---|
| 166 | Every day, 1 time | Most common |
| 61 | Mon-Fri, 1 time | Standard weekday runs |
| 37 | 1st of month, 1 time | Monthly process |
| 34 | Monday only, 1 time | Weekly Monday run |
| 24 | 2nd of month, 1 time | Monthly process |
| 21 | Wednesday only, 1 time | Weekly Wednesday run |
| 16 | 10th of month, 1 time | Monthly process |
| 10 | Friday only, 1 time | Weekly Friday run |
| 9 | 3rd of month, 1 time | Monthly process |
| 9 | 15th of month, 1 time | Monthly process |

---

## ProcessData as Self-Describing Metadata

The architectural breakthrough of this investigation: Sterling's own workflow configuration is stored with every workflow run, in a form that describes exactly what the run will do. The collector can read this metadata and bypass every interpretive layer downstream of Sterling.

### What ProcessData Is

`ProcessData` is a serialized Java Hashtable document that Sterling passes through its workflow execution as the "current state" of the run. It's created at workflow start (from the spawning context), updated at checkpoints, and persisted in `TRANS_DATA` as standard gzip-compressed content (despite the Hashtable header, the embedded XML string values are trivially parseable as XML).

Every workflow run's first step (`STEP_ID = 0`, `SERVICE_NAME = InvokeBusinessProcessService`) has an associated ProcessData document in TRANS_DATA — created at or immediately before the Step 0 `START_TIME`. This is universal across process types.

### Structure

```xml
<Result>
  <Client>
    <CLIENT_ID>10608</CLIENT_ID>
    <SEQ_ID>1</SEQ_ID>
    <CLIENT_NAME>LIFESPAN R1</CLIENT_NAME>
    <PROCESS_TYPE>NEW_BUSINESS</PROCESS_TYPE>
    <COMM_METHOD>INBOUND</COMM_METHOD>
    <TRANSLATION_MAP>FA_LIFESPAN_R1_IB_BD_D2X_NB</TRANSLATION_MAP>
    <BUSINESS_TYPE>BD</BUSINESS_TYPE>
    <FILE_FILTER>lifespan*LIFESPAN.PLACEMENT*</FILE_FILTER>
    <GET_DOCS_TYPE>SFTP_PULL</GET_DOCS_TYPE>
    <GET_DOCS_LOC>lifespan</GET_DOCS_LOC>
    <PRE_ARCHIVE>Y</PRE_ARCHIVE>
    <POST_ARCHIVE>Y</POST_ARCHIVE>
    <PREPARE_SOURCE>Y</PREPARE_SOURCE>
    <WORKERS_COMP>Y</WORKERS_COMP>
    <DUP_CHECK>Y</DUP_CHECK>
    <PREPARE_COMM_CALL>Y</PREPARE_COMM_CALL>
    <COMM_CALL>Y</COMM_CALL>
    <AUTO_RELEASE>Y</AUTO_RELEASE>
    <POST_TRANSLATION>Y</POST_TRANSLATION>
    <POST_TRANSLATION_MAP>FA_PAY_N_SECONDS_IB_BD_S2X_TR</POST_TRANSLATION_MAP>
    <POST_TRANS_SQL_QUERY>concat('EXEC Integration.FAINT.USP_PAYMENT_INTEREST_ACCOUNTS ',string(...))</POST_TRANS_SQL_QUERY>
    <!-- ... ~70 additional configuration fields ... -->
  </Client>
  <!-- Optionally additional <Client> blocks for multi-client runs -->
</Result>
```

### Key Fields

**Identity and process categorization:**
- `CLIENT_ID`, `SEQ_ID` — the (CLIENT_ID, SEQ_ID) pair that uniquely identifies the process configuration
- `CLIENT_NAME` — human-readable client name (source of truth for the run, even authoritative over INT_ClientRegistry in rare discrepancies)
- `PROCESS_TYPE` — NEW_BUSINESS, PAYMENT, RETURN, RECON, NOTES, SPECIAL_PROCESS, FILE_EMAIL, SFTP_PULL, SIMPLE_EMAIL, REMIT, SFTP_PUSH, etc.
- `COMM_METHOD` — INBOUND, OUTBOUND
- `BUSINESS_TYPE` — BD (Bad Debt, 3rd party) or EO (Early Out, 1st party)
- `TRANSLATION_MAP` — the primary Sterling translation map applied

**File/source/destination configuration:**
- `FILE_FILTER` — file pattern(s) the workflow operates on (pipe-delimited for multi-file runs)
- `GET_DOCS_TYPE`, `GET_DOCS_LOC` — how the workflow receives files (SFTP_PULL, SQL query, etc.)
- `PUT_DOCS_TYPE`, `PUT_DOCS_LOC` — how the workflow delivers files

**Behavior flags (YES = invoke corresponding sub-workflow):**

| ProcessData Field | Triggers Sub-Workflow |
|---|---|
| `GET_DOCS_TYPE` populated | FA_CLIENTS_GET_DOCS |
| `PRE_ARCHIVE=Y` | FA_CLIENTS_ARCHIVE (before processing) |
| `PREPARE_SOURCE=Y` | FA_CLIENTS_PREP_SOURCE |
| `TRANSLATION_MAP` populated | FA_CLIENTS_TRANS (always runs) |
| `POST_TRANSLATION=Y` | FA_CLIENTS_POST_TRANSLATION |
| `WORKERS_COMP=Y` | FA_CLIENTS_WORKERS_COMP |
| `DUP_CHECK=Y` | FA_CLIENTS_DUP_CHECK |
| `PREPARE_COMM_CALL=Y` | FA_CLIENTS_PREP_COMM_CALL |
| `COMM_CALL=Y` | FA_CLIENTS_COMM_CALL |
| `POST_ARCHIVE=Y` | FA_CLIENTS_ARCHIVE (after processing) |
| `POST_TRANSLATION_VITAL=Y` | Generates VITAL XML in post-translation |
| `POST_TRANS_SQL_QUERY` populated | Executes that SQL query after translation (typically an EXEC of an Integration stored procedure) |

**This is the core insight: ProcessData is a blueprint.** It tells us exactly which sub-workflows will be invoked and in what order. The collector can parse ProcessData and predict the workflow's execution pattern without per-process-type hardcoded logic.

### Multi-Client Runs

Some workflow runs process multiple client configurations simultaneously. Example: the PAY N SECONDS payment workflow (WF_ID 7985099) has **two** `<Client>` blocks in its ProcessData:
- SEQ_ID=1 for ACH payments (`paynseconds.PnSACH*.txt*`)
- SEQ_ID=2 for credit card payments (`paynseconds.PnSCC*.txt*`)

Both belong to CLIENT_ID 10537 (PAY N SECONDS), PROCESS_TYPE=PAYMENT. The workflow runs once but processes both file patterns together.

**Implication for collector design:** The extractor must parse **all** `<Client>` blocks from ProcessData, not just the first, and write one `SI_ExecutionTracking` row per (WF_ID, CLIENT_ID, SEQ_ID) combination.

### Extraction Pattern

For a given WF_ID:

1. Query `WORKFLOW_CONTEXT` for `STEP_ID = 0` to get the workflow start time
2. Query `TRANS_DATA` for rows where `WF_ID` matches, `REFERENCE_TABLE = 'DOCUMENT'`, `PAGE_INDEX = 0`, `CREATION_DATE <= Step 0 START_TIME`, ordered by `CREATION_DATE DESC` — take the top row
3. Decompress the `DATA_OBJECT` bytes via gzip
4. Parse for all `<Client>` blocks within `<Result>`
5. Write one row per `<Client>` to `SI_ExecutionTracking`

**Performance:** One decompression per workflow. Measurable at under 100 ms per workflow. For the typical 15-30 concurrent workflows Sterling runs, full metadata extraction across all of them completes in under a second.

### Why This Replaces Integration-Sourced Metadata

Every field that Integration's `tbl_B2B_CLIENTS_FILES` would have given us is present in ProcessData, sourced directly from Sterling at execution time:

- CLIENT_ID, SEQ_ID, PROCESS_TYPE, COMM_METHOD → same as CLIENTS_FILES
- TRANSLATION_MAP, FILE_FILTER, GET_DOCS_LOC → additional detail not in CLIENTS_FILES
- Configuration flags (WORKERS_COMP, DUP_CHECK, etc.) → additional detail not in CLIENTS_FILES

And every field that would have described what actually happened during the run is in ProcessData too — because Sterling wrote it there before executing. There's no interpretive gap between what Sterling ran and what we record.

---

## Process-Type Patterns

Different `PROCESS_TYPE` values drive Sterling down different sub-workflow paths. Understanding these patterns lets the collector target the right Translation output for business-data extraction when desired, and lets monitoring code recognize expected vs. unexpected execution shapes.

**Common building blocks.** All process types share a core set of sub-workflows:
- `FA_CLIENTS_GET_DOCS` (WFD 796) — pull files via SFTP
- `FA_CLIENTS_ARCHIVE` (WFD 795) — archive files
- `FA_CLIENTS_PREP_SOURCE` (WFD 799) — prep input data
- `FA_CLIENTS_TRANS` (WFD 807) — translate data via primary TRANSLATION_MAP
- `FA_CLIENTS_POST_TRANSLATION` (WFD 975) — run POST_TRANSLATION_MAP and optional SQL query
- `FA_CLIENTS_PREP_COMM_CALL` (WFD 803) — prep DM communication
- `FA_CLIENTS_COMM_CALL` (WFD 793) — push data to DM via FA_CLA_DM_API
- `FA_CLIENTS_FILE_MERGE` (WFD 810) — merge multiple files
- `FA_CLIENTS_WORKERS_COMP` (WFD 808) — workers comp check
- `FA_CLIENTS_DUP_CHECK` (WFD 804) — duplicate detection
- `FA_CLIENTS_ADDRESS_CHECK` (WFD 826) — address validation
- `FA_CLIENTS_ACCOUNTS_LOAD` (WFD 817) — stages records into CLIENTS_ACCTS-format VITAL XML (NB-specific)
- `FA_CLIENTS_VITAL` (WFD 800) — VITAL XML worker
- `FA_CLIENTS_GET_LIST` (WFD 797) — SQL-based list dispatcher (used in schedulers like PAY_N_SECONDS)

The parent workflow is typically `FA_CLIENTS_MAIN` (WFD 798) — a common entry point that branches based on ProcessData configuration to invoke the appropriate sub-workflows. Different process types thus produce different sub-workflow invocation patterns within the same `FA_CLIENTS_MAIN` parent.

### NEW_BUSINESS Inbound (Validated — LIFESPAN R1)

**Pattern:**
```
FA_CLIENTS_GET_DOCS        (SFTP pull files matching FILE_FILTER)
FA_CLIENTS_ARCHIVE         (archive raw files)
FA_CLIENTS_PREP_SOURCE     (prep)
FA_CLIENTS_TRANS           (translate each file — may iterate per file)
FA_CLIENTS_ACCOUNTS_LOAD   (stage into VITAL XML for CLIENTS_ACCTS loading)
FA_CLIENTS_FILE_MERGE      (merge multiple files' results)
FA_CLIENTS_ACCOUNTS_LOAD   (final consolidated load — this is the key marker)
FA_CLIENTS_WORKERS_COMP    (if WORKERS_COMP=Y)
FA_CLIENTS_DUP_CHECK       (if DUP_CHECK=Y)
FA_CLIENTS_ADDRESS_CHECK   (address validation)
FA_CLIENTS_PREP_COMM_CALL  (prep DM push)
FA_CLIENTS_COMM_CALL       (push to DM via FA_CLA_DM_API)
```

**Distinctive marker:** Multiple `FA_CLIENTS_ACCOUNTS_LOAD` invocations — one per input file plus a final consolidated one.

**Business data target:** The `Translation` step immediately following the **last** `Inline Begin FA_CLIENTS_ACCOUNTS_LOAD` marker. Its third output (format-specific XML) is the consolidated VITAL XML with one `<TRANSACTION>` element per record — the authoritative CLIENTS_ACCTS-format data going to DM.

**Validated on:** WF_IDs 7979758 (LIFESPAN R1, 103 transactions across multiple files) and 7983261 (LIFESPAN R1, different run, same pattern).

### PAYMENT Inbound (Validated — PAY N SECONDS)

**Pattern:**
```
FA_CLIENTS_GET_DOCS        (SFTP pull payment files)
FA_CLIENTS_ARCHIVE         (archive raw files)
FA_CLIENTS_TRANS           (primary translation, writes to Integration.ETL.tbl_PAYMENT_INTEREST_ACCOUNTS_IN)
FA_CLIENTS_POST_TRANSLATION (invokes Integration.FAINT.USP_PAYMENT_INTEREST_ACCOUNTS
                             — bucket allocation stored procedure — then runs POST_TRANSLATION_MAP
                             to produce VITAL XML from tbl_PAYMENT_INTEREST_ACCOUNTS_OUT)
FA_CLIENTS_PREP_COMM_CALL  (prep DM push)
FA_CLIENTS_COMM_CALL       (push to DM)
```

**Distinctive marker:** `FA_CLIENTS_POST_TRANSLATION` invocation (not present in NB). No `FA_CLIENTS_ACCOUNTS_LOAD`.

**Business data target:** The `Translation` step within `FA_CLIENTS_POST_TRANSLATION` sub-workflow. Its output is the VITAL XML with bucket-allocated payment records (post-`USP_PAYMENT_INTEREST_ACCOUNTS` processing).

**Multi-Client note:** Payment runs commonly contain multiple `<Client>` blocks in ProcessData (e.g., SEQ_ID=1 ACH + SEQ_ID=2 CC for the same client).

**Important cross-system consideration:** Payment processing is genuinely hybrid — Sterling's translation populates Integration's staging table, Integration's stored procedure computes payment-to-bucket allocations (business logic that isn't in Sterling), and Sterling's post-translation reads the Integration-computed results to produce the final VITAL XML. The ultimate data Sterling sends to DM is in the POST_TRANSLATION Translation output, but the richer queryable form (one row per bucket allocation with consumer, creditor, and bucket context) is in `Integration.ETL.tbl_PAYMENT_INTEREST_ACCOUNTS_OUT`. The B2B module can extract the VITAL XML from Sterling; any business-level queries about payment allocations are best served by reading the Integration table directly rather than re-implementing the logic.

**Validated on:** WF_ID 7985099 (PAY N SECONDS, 2 Client blocks, POST_TRANSLATION_MAP = FA_PAY_N_SECONDS_IB_BD_S2X_TR).

### NOTES Outbound (Validated — LIVEVOX IVR)

**Pattern:**
```
SQL query to staging table  (e.g., reads from Integration.etl.LiveVox_Daily_Lists)
Iterative loop over FILE_FILTER entries (pipe-delimited list of N destination campaigns):
  FA_CLIENTS_PREP_SOURCE
  FA_CLIENTS_TRANS           (one per campaign file to be generated)
FA_CLIENTS_PREP_COMM_CALL
FA_CLIENTS_COMM_CALL         (SFTP push to LiveVox)
```

**Distinctive marker:** No `FA_CLIENTS_GET_DOCS` (no SFTP pull); FILE_FILTER is pipe-delimited list of output files rather than pattern match. Many iterations of PREP_SOURCE/TRANS corresponding to the campaign count.

**Business data target:** One Translation step output per campaign. Harder to summarize into single "the business data" than NB or PAYMENT — each Translation produces a distinct outbound file.

**Validated on:** WF_ID 7985092 (LIVEVOX IVR, PROCESS_TYPE=NOTES, ~96 Translation iterations across 96 campaign files listed in FILE_FILTER, 694 total transactions).

### Other Process Types (Not Yet Catalogued)

The following process types have been identified from Integration's `CLIENTS_FILES` table but have not yet been investigated for their sub-workflow patterns:

- **RETURN** (inbound and outbound)
- **RECON** (inbound and outbound)
- **REMIT**
- **SPECIAL_PROCESS**
- **FILE_EMAIL / SIMPLE_EMAIL**
- **SFTP_PULL / SFTP_PUSH** (raw passthrough)

Cataloguing these is a future investigation task — not blocking module construction, as the core `SI_ExecutionTracking` will populate correctly for all process types via ProcessData extraction, regardless of whether their detailed sub-workflow pattern is understood yet.

### Empty-File Runs (Not Yet Verified)

Workflows that execute on schedule and find no files to process — a significant fraction of all runs, especially for inbound processes running hourly. It has not yet been verified whether these runs still generate ProcessData in TRANS_DATA. This is an important edge case for the collector: if ProcessData is generated even for empty runs, we get full metadata for every workflow attempt. If it's only generated when data is present, the collector needs a fallback to record empty runs with metadata derived from WFD.NAME/SCHEDULE linkage.

---

## B2B Schema Tables

### Table Inventory (Current + Planned)

| Table | Prefix | Status | Source | Purpose |
|-------|--------|--------|--------|---------|
| `dbo.ClientHierarchy` | — | ✅ Built | crs5_oltp (DM) | Shared infrastructure. Flattened DM creditor hierarchy for crosswalk and grouping. |
| `B2B.SI_WorkflowTracking` | SI_ | ✅ Built (Phase 1) | b2bi WORKFLOW_CONTEXT + WORKFLOW_LINKAGE | Workflow execution records with child rollup metrics and activity detection via baseline comparison. |
| `B2B.SI_ProcessBaseline` | SI_ | ✅ Built (Phase 1) | b2bi (derived) | Per-process baseline fingerprints (child_count, total_steps) used for activity detection. |
| `B2B.INT_ClientRegistry` | INT_ | ✅ Built | Integration CLIENTS_MN | CLIENT_ID-to-CLIENT_NAME lookup for UI humanization. |
| `B2B.SI_ScheduleRegistry` | SI_ | To design | b2bi SCHEDULE + DATA_TABLE | Sterling schedule mirror with parsed, structured timing XML. |
| `B2B.SI_ExecutionTracking` | SI_ | To design | b2bi WF_INST_S + WORKFLOW_CONTEXT + TRANS_DATA (ProcessData) | Per-(WF_ID, CLIENT_ID, SEQ_ID) execution summary with full ProcessData-extracted metadata. |
| `B2B.SI_ProcessDataCache` | SI_ | To design | b2bi TRANS_DATA (decompressed) | Persisted ProcessData XML per WF_ID (raw + parsed) for audit and query performance. |
| `B2B.SI_BusinessDataTracking` | SI_ | To design (optional, deferred) | b2bi TRANS_DATA Translation outputs | Process-type-specific business data summaries (record counts, file names, bucket allocations). |

### SI_WorkflowTracking (Built — Phase 1)

Captured at initial Phase 1 build. Retained as-is. Holds workflow execution records with child rollup metrics from WORKFLOW_CONTEXT and WORKFLOW_LINKAGE. Was the primary execution record source before the ProcessData discovery extended our capabilities. Relationship to SI_ExecutionTracking will be evaluated after both tables are populated — there may be opportunities to consolidate or clarify the division of responsibility between them.

**Columns (reference):**

| Column | Source | Purpose |
|--------|--------|---------|
| workflow_id | b2bi WORKFLOW_ID | PK |
| workflow_def_id | b2bi WFD_ID | Template identifier |
| workflow_def_version | b2bi WFD_VERSION | Template version |
| service_name | b2bi SERVICE_NAME | Process name |
| status_code | b2bi BASIC_STATUS | Execution status |
| status_message | b2bi ADV_STATUS | Detail text |
| start_time | b2bi START_TIME | Execution start |
| end_time | b2bi END_TIME | Execution end |
| node_executed | b2bi NODEEXECUTED | Server node |
| child_workflow_count | WORKFLOW_LINKAGE rollup | Children spawned |
| total_child_steps | WORKFLOW_LINKAGE rollup | Aggregate step count |
| max_child_steps | WORKFLOW_LINKAGE rollup | Largest child step count |
| has_sftp_get | Child step scan | File retrieved inbound (BIT) |
| has_sftp_put | Child step scan | File delivered outbound (BIT) |
| has_translation | Child step scan | Data transformation occurred (BIT) |
| had_activity | Computed | `total_child_steps > baseline_total_steps` (BIT) |
| collected_dttm | System | When collected by xFACts |

### SI_ProcessBaseline (Built — Phase 1)

Per-process baseline fingerprints used by the initial activity detection approach. Retained. May become less central as ProcessData-based execution recording takes over primary monitoring, but baseline fingerprinting remains a useful anomaly detection technique (e.g., detecting workflows that take unexpectedly long or spawn unexpected numbers of sub-steps).

**Columns (reference):**

| Column | Purpose |
|--------|---------|
| service_name (PK) | Process name (Scheduler_FA_*) |
| process_direction | INBOUND, OUTBOUND, INTERNAL |
| baseline_child_count | Most common child count across recent executions |
| baseline_total_steps | Most common total child steps across recent executions |
| baseline_occurrences | How many executions matched baseline (confidence level) |
| total_executions_sampled | Total executions in sample window |
| max_observed_steps | Highest total_child_steps ever seen |
| last_calculated_dttm | When baseline was last recalculated |

### INT_ClientRegistry (Built)

Simple mirror of `Integration.etl.tbl_B2B_CLIENTS_MN` — provides CLIENT_NAME for a given CLIENT_ID. Used at display/UI time only. Not part of the data collection path; purely a lookup enrichment.

### SI_ScheduleRegistry (To Design)

Mirror of Sterling's `SCHEDULE` table, with the compressed `TIMINGXML` decompressed and parsed into structured columns. One row per scheduled workflow.

**Planned columns (draft — to be refined during design):**

| Column | Source | Purpose |
|--------|--------|---------|
| schedule_id | SCHEDULE.SCHEDULEID | PK |
| workflow_name | SCHEDULE.SERVICENAME | Joins to WFD.NAME |
| workflow_def_id | WFD.WFD_ID (via name join) | Workflow definition |
| is_active | SCHEDULE.STATUS = 'ACTIVE' | Is the schedule active |
| schedule_type | Derived from parsed timing XML | EVERYDAY / WEEKDAY / DAY_OF_MONTH / LDOM / etc. |
| days_of_week | Derived from parsed timing XML | Comma-delimited day list (e.g., "Mon,Tue,Wed,Thu,Fri") |
| days_of_month | Derived from parsed timing XML | Comma-delimited day list (e.g., "1,15") |
| run_times | Derived from parsed timing XML | Comma-delimited HH:MM list |
| excluded_dates | Derived from parsed timing XML | Comma-delimited MM-DD list |
| raw_timing_xml | DATA_TABLE content | Original decompressed XML for reference |
| last_synced_dttm | System | When this row was last refreshed |

**Design decisions pending:**
- Granular structured timing (separate rows per day or per time) vs. consolidated (one row per schedule with delimited fields) — consolidated is simpler, granular is easier for query logic
- How to represent `ofWeek="-1"` (everyday) — as explicit day list or a dedicated flag
- Handling of Sterling system services (DBMonitorService, etc.) — include with a flag, or filter out entirely

### SI_ExecutionTracking (To Design)

**The central execution record table** in the new architecture. One row per (WF_ID, CLIENT_ID, SEQ_ID) combination — note the composite grain because some workflow runs process multiple client configurations (e.g., PAY N SECONDS payment workflow with ACH + CC SEQ_IDs).

**Planned columns (draft — to be refined during design):**

Workflow-level (from WF_INST_S + WORKFLOW_CONTEXT):

| Column | Source | Purpose |
|--------|--------|---------|
| workflow_id | b2bi WORKFLOW_ID | Part of composite PK |
| workflow_def_id | b2bi WFD_ID | Which workflow definition |
| workflow_def_version | b2bi WFD_VERSION | Which version |
| workflow_name | WFD.NAME | Human-readable workflow name |
| parent_workflow_id | b2bi WORKFLOW_LINKAGE.P_WF_ID | Parent workflow if child |
| root_workflow_id | b2bi WORKFLOW_LINKAGE.ROOT_WF_ID | Root if nested |
| workflow_start_time | WF_INST_S.START_TIME | Execution start |
| workflow_end_time | WF_INST_S.END_TIME | Execution end |
| workflow_status | WF_INST_S.STATUS | Completion status |
| workflow_state | WF_INST_S.STATE | Completion state |

ProcessData-extracted (per-Client):

| Column | Source | Purpose |
|--------|--------|---------|
| client_id | ProcessData CLIENT_ID | Part of composite PK |
| seq_id | ProcessData SEQ_ID | Part of composite PK |
| client_name | ProcessData CLIENT_NAME | Client name from source |
| process_type | ProcessData PROCESS_TYPE | NEW_BUSINESS, PAYMENT, NOTES, etc. |
| comm_method | ProcessData COMM_METHOD | INBOUND / OUTBOUND |
| business_type | ProcessData BUSINESS_TYPE | BD / EO |
| translation_map | ProcessData TRANSLATION_MAP | Primary translation map |
| post_translation_map | ProcessData POST_TRANSLATION_MAP | Post-translation map (if any) |
| post_trans_sql_query | ProcessData POST_TRANS_SQL_QUERY | Integration SP call if any |
| file_filter | ProcessData FILE_FILTER | File pattern |
| get_docs_type | ProcessData GET_DOCS_TYPE | SFTP_PULL, etc. |
| get_docs_location | ProcessData GET_DOCS_LOC | Source location |
| put_docs_type | ProcessData PUT_DOCS_TYPE | Delivery method if outbound |
| put_docs_location | ProcessData PUT_DOCS_LOC | Destination if outbound |

Config flags (ProcessData Y/N fields):

| Column | Source | Purpose |
|--------|--------|---------|
| has_pre_archive | ProcessData PRE_ARCHIVE = Y | Archive-before-processing flag |
| has_post_archive | ProcessData POST_ARCHIVE = Y | Archive-after-processing flag |
| has_prepare_source | ProcessData PREPARE_SOURCE = Y | PREP_SOURCE sub-workflow flag |
| has_post_translation | ProcessData POST_TRANSLATION = Y | Post-translation sub-workflow flag |
| has_workers_comp | ProcessData WORKERS_COMP = Y | Workers comp check flag |
| has_dup_check | ProcessData DUP_CHECK = Y | Duplicate check flag |
| has_comm_call | ProcessData COMM_CALL = Y | COMM_CALL sub-workflow flag |
| has_auto_release | ProcessData AUTO_RELEASE = Y | Auto-release flag |

System columns:

| Column | Purpose |
|--------|---------|
| collected_dttm | When extracted by collector |
| processdata_cache_id | FK to SI_ProcessDataCache for raw XML reference |

**Design decisions pending:**
- Composite PK (workflow_id, client_id, seq_id) vs. surrogate identity PK with unique constraint
- Which ProcessData fields to promote to columns vs. leave in SI_ProcessDataCache only — currently listed set is a starting point, may expand or contract during design
- Status/success determination logic — ProcessData itself doesn't indicate success/failure; that comes from WF_INST_S.STATUS + step-level analysis. Need to decide on a single rolled-up status column and how to compute it.
- Whether to include sub-workflow pattern summary (count of each sub-workflow invoked) — could be useful for monitoring deviations from expected patterns

### SI_ProcessDataCache (To Design)

Persists the raw decompressed ProcessData XML per workflow run. Exists for two reasons: audit (so we have the original source data archived independent of Sterling's aggressive TRANS_DATA purge) and performance (parsed data in SI_ExecutionTracking is optimized for query; the raw XML is available here if deeper inspection is needed for a specific run without re-decompressing).

**Planned columns (draft):**

| Column | Purpose |
|--------|---------|
| cache_id | PK (identity) |
| workflow_id | FK to SI_ExecutionTracking |
| data_id | Sterling TRANS_DATA.DATA_ID |
| raw_xml | Decompressed ProcessData XML (NVARCHAR(MAX)) |
| raw_xml_size_bytes | Size for reference |
| client_count | Count of `<Client>` blocks parsed |
| extracted_dttm | When extracted |

**Design decisions pending:**
- Retention policy — indefinite vs. time-windowed purge (maybe match to SI_ExecutionTracking retention)
- Whether to compress the raw_xml on our side for storage efficiency (ProcessData is typically 2-10 KB, compression ratio modest, likely not worth it unless we're storing years)
- Whether to also cache Translation outputs (potentially large — likely not by default; only for specific process types with business-data extraction)

### SI_BusinessDataTracking (To Design, Deferred)

Optional. Per-process-type business data summaries extracted from targeted Translation outputs. Only needed if we decide to surface record counts, file names, or business-level rollups in monitoring beyond what's in SI_ExecutionTracking.

**Design pending full decision on whether this is worth the complexity.** For NB, we could extract `<TRANSACTION>` counts per run from the final VITAL XML. For payments, we'd likely reference Integration's `tbl_PAYMENT_INTEREST_ACCOUNTS_OUT` directly rather than extracting from Sterling's post-translation output. For NOTES outbound, the data is many campaign files — not clear what a single "record count" would even mean.

**Decision: defer until core tables are built and we understand what monitoring use cases demand this level of detail.**

---

## Collector Scripts

### Current Scripts (Phase 1)

| Script | Source(s) | Frequency | Status |
|--------|-----------|-----------|--------|
| `Sync-ClientHierarchy.ps1` | crs5_oltp | Daily | ✅ Built, deployed, tested |
| `Collect-B2BWorkflow.ps1` | b2bi + Integration | Every 10 min | ✅ Built (Phase 1 version — reads WORKFLOW_CONTEXT + WORKFLOW_LINKAGE, computes child rollup + baseline comparison) |
| `Sync-B2BConfig.ps1` | Integration | Daily | Built (syncs CLIENTS_MN to INT_ClientRegistry) |

### New Scripts (To Design)

| Script | Source(s) | Frequency | Purpose |
|--------|-----------|-----------|---------|
| `Sync-B2BSchedules.ps1` | b2bi SCHEDULE + DATA_TABLE | Daily | Reads all active workflow schedules, decompresses TIMINGXML, parses, writes to SI_ScheduleRegistry. |
| `Collect-B2BExecution.ps1` | b2bi WF_INST_S + WORKFLOW_CONTEXT + TRANS_DATA | Every 5-15 min | Core new collector. For each recently-completed workflow: reads WF_INST_S row, targets and decompresses ProcessData, parses all `<Client>` blocks, writes SI_ExecutionTracking rows + SI_ProcessDataCache entry. |
| `Monitor-B2B.ps1` | xFACts B2B tables | Every 30-60 min | Evaluates SI_ExecutionTracking + SI_ScheduleRegistry to detect failures, missing scheduled runs, anomalies. Queues alerts to Teams/Jira. |

### Collector Design Principles

- **Idempotent.** Running the collector twice with overlapping time windows produces the same final state.
- **Time-windowed.** Each run processes workflows completed in the last N minutes (with overlap for safety). No need to scan all of WORKFLOW_CONTEXT repeatedly.
- **Resilient to Sterling purge.** If a workflow existed at time T-1 but has been purged by time T, the collector doesn't crash or produce phantom records — just logs and moves on.
- **Performance-conscious.** Targeted TRANS_DATA decompression (one row per workflow for ProcessData) keeps overhead minimal even with 15-20 concurrent workflows.
- **Cross-server handled in PowerShell.** No linked servers. Queries to b2bi (FA-INT-DBP) and xFACts (AG) are separate `Invoke-Sqlcmd` calls. Data correlation happens in-memory.
- **Standard xFACts patterns.** All scripts use ProcessRegistry for scheduling, Object_Registry + Object_Metadata for cataloging, `$user = "FAC\$($WebEvent.Auth.User.Username)"` for write attribution where applicable.

### Integration Sync Scope

- `INT_ClientRegistry` (CLIENTS_MN mirror) remains in place and continues to sync daily.
- No other Integration table syncs are planned. Specifically retired: `INT_FileRegistry` (CLIENTS_FILES mirror), `INT_ExecutionTracking` (CLIENTS_BATCH_STATUS mirror), and any CLIENTS_SCHEDULES sync.

---

## Implementation Phases

### Phase 1: Foundation ✅ COMPLETE

1. ✅ Build `dbo.ClientHierarchy` table and refresh script
2. ✅ Create B2B schema (confirmed exists)
3. ✅ Register in Module_Registry, Component_Registry
4. ✅ System_Metadata baseline (1.0.0)
5. ✅ Build `B2B.SI_WorkflowTracking`, `B2B.SI_ProcessBaseline`, `B2B.INT_ClientRegistry`
6. ✅ Build `Collect-B2BWorkflow.ps1`, `Sync-B2BConfig.ps1`

### Phase 2: Investigation Completion (In Progress)

**Goal:** Fully validate the pure-b2bi architecture across all relevant scenarios before committing to table designs.

1. ⏳ Continue validating ProcessData extraction across process types:
   - Investigate RETURN, RECON, REMIT, SPECIAL_PROCESS, FILE_EMAIL, SIMPLE_EMAIL, SFTP_PULL, SFTP_PUSH patterns
   - Verify empty-file run behavior (does ProcessData exist for runs that find no files?)
   - Identify which process types invoke Integration stored procedures via POST_TRANS_SQL_QUERY
2. ⏳ Validate ProcessData extraction edge cases:
   - Workflows with many `<Client>` blocks (multi-Client stress test)
   - Workflows with unusually large ProcessData
   - Failed workflows (does Sterling still write ProcessData if the run errors out?)
3. ⏳ Finalize detailed understanding of TRANS_DATA retention and purge timing
4. ⏳ Understand the relationship between SI_WorkflowTracking (Phase 1) and the planned SI_ExecutionTracking — decide whether they coexist, one supersedes the other, or they're merged

### Phase 3: New Table Design and Construction

**Prerequisite:** Phase 2 complete.

1. Design and deploy `B2B.SI_ScheduleRegistry` with DDL + Object_Metadata
2. Design and deploy `B2B.SI_ExecutionTracking` with DDL + Object_Metadata
3. Design and deploy `B2B.SI_ProcessDataCache` with DDL + Object_Metadata
4. Decide on `B2B.SI_BusinessDataTracking` (build or defer further)

### Phase 4: New Collector Construction

**Prerequisite:** Phase 3 complete.

1. Build `Sync-B2BSchedules.ps1` — one-time bootstrap + ongoing sync
2. Build `Collect-B2BExecution.ps1` — the core new collector
3. Register all scripts in ProcessRegistry and Object_Registry + Object_Metadata
4. Run both in parallel with existing Phase 1 collectors to validate results before any cutover

### Phase 5: Monitoring and Alerting

**Prerequisite:** Phase 4 complete; SI_ExecutionTracking and SI_ScheduleRegistry populated with at least 2-4 weeks of data.

1. Build `Monitor-B2B.ps1`
2. Define alert thresholds in collaboration with Apps team
3. Integrate with Teams and Jira
4. Validate alert accuracy over a pilot period before enabling broad alerting

### Phase 6: Control Center Page

1. Build B2B Monitoring Control Center page (route, API, CSS, JS)
2. Process status overview, failure feed, missing process alerts, schedule adherence, activity timeline
3. Client-grouped views with ClientHierarchy resolution
4. Drill-down from summary to individual workflow runs with ProcessData detail

### Phase 7: Enhanced Analytics (Future)

1. Volume and duration anomaly detection
2. End-to-end file lifecycle tracking (FileOps → B2B → BatchOps)
3. DM batch correlation
4. Historical trend analysis
5. Automatic baseline drift detection

---

## Open Questions and Investigation Items

### Partially Resolved / Under Investigation

| Item | Status | Notes |
|------|--------|-------|
| ProcessData extraction across all process types | In progress | Validated for NB, PAYMENT, NOTES OB; 8+ other process types still to verify |
| Empty-file run behavior | Not verified | Unknown whether ProcessData is written for runs that find no data |
| Multi-Client handling in all process types | Partially verified | Payment confirmed (2 Clients); unclear how common this is elsewhere |
| Failed-workflow ProcessData availability | Not verified | Does Sterling write ProcessData if the workflow errors before completion? |
| POST_TRANS_SQL_QUERY usage across process types | Partially mapped | Confirmed for PAYMENT (USP_PAYMENT_INTEREST_ACCOUNTS); other types TBD |
| Sterling data retention windows | Approximate | ~2-3 days broadly observed; exact thresholds per table to be confirmed |

### Resolved During Investigation

| Item | Resolution |
|------|------------|
| Can TRANS_DATA be read? | Yes — standard gzip, fully decompressible |
| Is ProcessData universally present? | Yes — at Step 0 of every workflow run |
| BPML-to-(CLIENT_ID, SEQ_ID) linkage | Solved via ProcessData (no need to parse BPML) |
| Correlation of WORKFLOW_CONTEXT and TRANS_DATA | Via DOC_ID/CONTENT/STATUS_RPT/WFE_STATUS_RPT references + CREATION_DATE alignment |
| SEQ_ID interpretation | CLIENT_ID + SEQ_ID identifies a specific process configuration; multiple SEQ_IDs per CLIENT_ID represent different file types or directional flows for that client |
| Naming suffix interpretations (S2D, D2S, etc.) | Partially deferred — not blocking the module; can be catalogued later if operationally valuable |

### Non-Blocking Future Questions

| Item | Notes |
|------|-------|
| Sterling day-of-week values 0 and 7 | Not observed in active schedules; parser will handle if they appear |
| ~320 additional Integration tables | Unexplored; may contain data relevant to future features but not blocking |
| FILES_LOG table | Previously investigated — it's a config change audit log, not file processing metrics |
| Non-NB file type lifecycle to DM | Some process types may not have BATCH_ID correlation; path to DM varies |

### For Integration Team (Now Primarily Our Team)

With the Integration team absorbed into Apps/Int, these questions now sit within our own scope rather than being blocking external dependencies. They can be answered as time permits during ongoing investigation.

1. What writes to the `etl.tbl_B2B_*` tables? (Likely Sterling adapters via AS2LightweightJDBCAdapter, but confirm)
2. Full inventory of stored procedures invoked by Sterling workflows via POST_TRANS_SQL_QUERY
3. Which Integration tables are active processing pipeline components vs. historical tracking artifacts?

### For Apps Team

1. Which processes are critical and require immediate alerting when they fail?
2. What SLAs exist for file processing?
3. Review active schedules with no recent execution — are they still needed or legacy entries?

### For Infrastructure

1. Is there a network share for older `arc_data` archives beyond local retention?
2. Can Sterling purge retention be extended on TRANS_DATA specifically, to give us a larger buffer for ProcessData extraction?

---

## Quick Reference Queries

These queries are validated during the investigation phase and can be used directly or adapted for collector/monitoring script development.

### b2bi — Core Investigation Queries

```sql
-- Recent workflow runs (last 30 minutes) with workflow names
SELECT TOP 20 
    wis.WORKFLOW_ID,
    wis.WFD_ID,
    wis.WFD_VERSION,
    wfd.NAME AS workflow_name,
    wis.START_TIME,
    wis.END_TIME,
    wis.STATUS,
    wis.STATE
FROM b2bi.dbo.WF_INST_S wis
INNER JOIN b2bi.dbo.WFD wfd 
    ON wfd.WFD_ID = wis.WFD_ID 
    AND wfd.WFD_VERSION = wis.WFD_VERSION
WHERE wis.START_TIME >= DATEADD(MINUTE, -30, GETDATE())
ORDER BY wis.START_TIME DESC;

-- Sub-workflow invocation markers for a specific workflow
-- (shows which business-level sub-workflows were invoked)
SELECT STEP_ID, SERVICE_NAME, ADV_STATUS, START_TIME
FROM b2bi.dbo.WORKFLOW_CONTEXT
WHERE WORKFLOW_ID = @WFID
  AND ADV_STATUS LIKE '%Inline Begin%'
ORDER BY STEP_ID;

-- Find ProcessData document for a workflow
-- Step 1: get Step 0 START_TIME
SELECT TOP 1 STEP_ID, SERVICE_NAME, CONTENT, START_TIME
FROM b2bi.dbo.WORKFLOW_CONTEXT
WHERE WORKFLOW_ID = @WFID AND STEP_ID = 0;

-- Step 2: find the DOCUMENT-type TRANS_DATA row created at or before Step 0
SELECT TOP 1 DATA_ID, DATALENGTH(DATA_OBJECT) AS BYTES, CREATION_DATE
FROM b2bi.dbo.TRANS_DATA
WHERE WF_ID = @WFID
  AND REFERENCE_TABLE = 'DOCUMENT'
  AND PAGE_INDEX = 0
  AND CREATION_DATE <= @Step0StartTime
ORDER BY CREATION_DATE DESC, DATA_ID DESC;

-- Active schedules for a specific client
-- (replace the LIKE pattern to filter by client name)
SELECT SCHEDULEID, SERVICENAME, STATUS, TIMINGXML
FROM b2bi.dbo.SCHEDULE
WHERE SERVICENAME LIKE '%LIFESPAN%'
  AND STATUS = 'ACTIVE'
ORDER BY SERVICENAME;

-- Recent failures at parent level
SELECT WORKFLOW_ID, SERVICE_NAME, START_TIME, BASIC_STATUS, ADV_STATUS
FROM b2bi.dbo.WORKFLOW_CONTEXT
WHERE BASIC_STATUS NOT IN (0, 10) 
  AND STEP_ID = 0
  AND START_TIME >= DATEADD(HOUR, -24, GETDATE())
ORDER BY START_TIME DESC;
```

### b2bi — Baseline Fingerprint Query (Phase 1)

Retained as reference — this query remains useful for anomaly detection even as ProcessData becomes the primary execution record source.

```sql
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

### ProcessData Decompression (PowerShell)

```powershell
# Assumes $WFID and $Step0StartTime are set

$processDataQuery = @"
SELECT TOP 1 DATA_ID, DATA_OBJECT
FROM b2bi.dbo.TRANS_DATA
WHERE WF_ID = $WFID
  AND REFERENCE_TABLE = 'DOCUMENT'
  AND PAGE_INDEX = 0
  AND CREATION_DATE <= '$Step0StartTime'
ORDER BY CREATION_DATE DESC, DATA_ID DESC;
"@

$row = Invoke-Sqlcmd `
    -ServerInstance 'FA-INT-DBP' `
    -Database 'b2bi' `
    -Query $processDataQuery `
    -TrustServerCertificate `
    -MaxBinaryLength 20971520

# Decompress gzip bytes
$bytes = [byte[]]$row.DATA_OBJECT
$ms = New-Object System.IO.MemoryStream(,$bytes)
$gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
$sr = New-Object System.IO.StreamReader($gz)
$processDataXml = $sr.ReadToEnd()
$sr.Dispose(); $gz.Dispose(); $ms.Dispose()

# Extract <Client> blocks (multi-client aware)
$xml = [xml]$processDataXml
$clients = $xml.Result.Client
foreach ($client in $clients) {
    # Write one SI_ExecutionTracking row per client
    $clientId = $client.CLIENT_ID
    $seqId = $client.SEQ_ID
    $clientName = $client.CLIENT_NAME
    $processType = $client.PROCESS_TYPE
    # etc.
}
```

### Integration — Reference Query (INT_ClientRegistry Sync)

```sql
-- Source query for INT_ClientRegistry sync (CLIENTS_MN mirror)
SELECT CLIENT_ID, CLIENT_NAME, ACTIVE_FLAG, AUTOMATED
FROM Integration.etl.tbl_B2B_CLIENTS_MN
ORDER BY CLIENT_ID;
```

### xFACts B2B — Example Queries (Future, Once Tables Populated)

```sql
-- Recent workflow executions with full client context
SELECT 
    et.workflow_id,
    et.workflow_name,
    cr.client_name,
    et.seq_id,
    et.process_type,
    et.comm_method,
    et.translation_map,
    et.workflow_start_time,
    et.workflow_status
FROM B2B.SI_ExecutionTracking et
LEFT JOIN B2B.INT_ClientRegistry cr ON et.client_id = cr.client_id
WHERE et.workflow_start_time >= DATEADD(HOUR, -4, GETDATE())
ORDER BY et.workflow_start_time DESC;

-- Workflows scheduled but not executed today (missed runs detection — conceptual)
-- Actual implementation depends on parsed timing XML schedule evaluation
SELECT sr.workflow_name, sr.schedule_type, sr.run_times, sr.last_synced_dttm
FROM B2B.SI_ScheduleRegistry sr
WHERE sr.is_active = 1
  AND NOT EXISTS (
      SELECT 1 FROM B2B.SI_ExecutionTracking et
      WHERE et.workflow_name = sr.workflow_name
        AND et.workflow_start_time >= CAST(GETDATE() AS DATE)
  )
  -- AND <schedule_type indicates this should have run by now>
ORDER BY sr.workflow_name;
```

---

## Process Naming Conventions (Reference)

| Pattern | Direction | Example |
|---------|-----------|---------|
| `Scheduler_FA_FROM_*` | Inbound (partner → FAC) | `Scheduler_FA_FROM_REVSPRING_IB_BD_PULL` |
| `Scheduler_FA_TO_*` | Outbound (FAC → partner) | `Scheduler_FA_TO_LIVEVOX_IVR_OB_BD_S2D` |
| `Scheduler_FA_*` | Internal / Utility | `Scheduler_FA_DM_ENOTICE` |
| `Scheduler_*` (no FA_) | System / Housekeeping | `Scheduler_FileGatewayReroute` |
| `FA_CLIENTS_*` | Sub-workflow (common library) | `FA_CLIENTS_GET_DOCS`, `FA_CLIENTS_TRANS`, etc. |

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
| NB | New Business |
| TR | Transactions (PMT / payment transactions) |
| BDL | Bulk Data Load |
| RPT | Report |
| INV | Inventory file (probable — confirm with team) |
| SP | TBD |
| S2D, S2P, D2S, P2S | Transfer patterns — S = SQL; others TBD |
| PULL / PUSH | Transfer direction initiation |

---

## Document Flexibility

**This document describes a current plan, not a final specification.** The architectural direction (pure-b2bi, ProcessData-driven extraction) is firmly established based on multi-session investigation and validation across three process types. The specific table column lists, script designs, and phase ordering are the current best understanding and will evolve as investigation continues.

**Areas likely to evolve:**

- Column inventories for the new tables (SI_ScheduleRegistry, SI_ExecutionTracking, SI_ProcessDataCache) — current lists are starting points that will be refined as we work through design details
- Sub-workflow patterns for currently-uncatalogued process types (RETURN, RECON, REMIT, etc.) — these will be documented as each type is investigated
- The precise role and retention of retired Integration tables — if future features need capabilities only available via Integration tables, individual table syncs may be reintroduced (with explicit reasoning)
- Monitoring thresholds and alert rules — will be shaped by what we see in the data once collectors are running
- The Control Center page design — will be informed by what questions we find ourselves asking most often of the data

**Areas firmly established:**

- b2bi is the source of truth for all execution and schedule data
- ProcessData is the metadata mechanism; the collector extracts it per workflow run
- Integration DB is bypassed for data collection except for CLIENTS_MN (name lookup)
- Phase 2 (Investigation Completion) must finish before new tables are designed and built
- The SI_/INT_ prefix convention for source clarity is retained

The document is expected to be updated at the end of each significant investigation or design session. Retired or superseded content is called out inline rather than removed, so the document's history of decisions remains visible.

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Author | Applications Team (Dirk + xFACts Claude collaboration) |
| Created | January 13, 2026 |
| Revised | April 18, 2026 |
| Status | Active — Phase 1 Complete, Phase 2 In Progress (Investigation) |
| Schema | B2B |
| Primary Source | b2bi on FA-INT-DBP (authoritative for all execution and metadata) |
| Secondary Source | Integration on AVG-PROD-LSNR (CLIENTS_MN only, for client name humanization) |
| Correlation Key | b2bi WORKFLOW_ID (numeric) |
| Prerequisite | dbo.ClientHierarchy ✅ (shared infrastructure — implemented) |

### Revision History

| Date | Revision |
|------|----------|
| January 13, 2026 | Initial document created |
| April 16, 2026 | Phase 1 foundation complete; document updated to reflect deployed tables and scripts |
| April 17-18, 2026 | Deep investigation of b2bi internals: DATA_TABLE compression, timing XML grammar, WORKFLOW_CONTEXT ↔ TRANS_DATA linkage, ProcessData discovery, sub-workflow pattern cataloging |
| April 18, 2026 | Major revision: architecture shifted from hybrid (b2bi + Integration) to pure-b2bi based on investigation findings; Integration tables retired from core architecture; new tables (SI_ScheduleRegistry, SI_ExecutionTracking, SI_ProcessDataCache) introduced; phase plan restructured with Phase 2 as dedicated investigation completion before new build work |

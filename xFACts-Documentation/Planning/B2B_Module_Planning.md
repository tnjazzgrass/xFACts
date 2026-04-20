# B2B Integrator Module — Planning Roadmap

## Purpose of This Document

Top-level roadmap for the xFACts B2B module. Describes what the module is for, the pain points it addresses, the current understanding of where we are in the work, and what remains to get it built. Architectural detail, process-type specifics, and reference queries live in companion documents (see Document Ecosystem below).

This document is intentionally thin. It is meant to be the entry point for understanding the B2B module at a glance — what it covers, why it exists, what phase we're in. Detail is deferred to documents whose scope is specifically architecture or a specific process type or reference material.

---

## Document Ecosystem

The B2B module investigation and build is supported by a set of related documents. Each has a specific scope and is maintained independently. This document (the roadmap) is the top of the stack.

```
                  B2B_Module_Planning.md  (this document — roadmap)
                           │
                           ├── B2B_ArchitectureOverview.md  (architectural reference)
                           │        │
                           │        └── B2B_ProcessAnatomy_*.md  (one per process type)
                           │                  ├── B2B_ProcessAnatomy_NewBusiness.md  ✅
                           │                  ├── B2B_ProcessAnatomy_FileDeletion.md  (planned)
                           │                  ├── B2B_ProcessAnatomy_Payment.md  (planned)
                           │                  └── ... (one per remaining process type)
                           │
                           └── B2B_Reference_Queries.md  (investigation queries + snippets)
```

**Roll-up relationship:**
- Process anatomy docs capture the specifics of individual process types as they are investigated
- The architecture doc abstracts shared patterns across process anatomies into a unified architectural model
- This planning doc references both and tracks the overall direction of the build

**All of these are working documents.** They will be revised as investigation continues, and may eventually serve as source material for permanent Control Center help content. For now, they exist to help us understand the system well enough to commit to a build.

---

## Executive Summary

IBM Sterling B2B Integrator (commonly referred to as "IBM" or "IBM B2B" internally) is the platform's file transfer and ETL processing engine handling inbound and outbound file transfers between FAC and its trading partners. The system processes new business placements, payment files, notes, returns, reconciliation files, and numerous other data exchanges between FAC and its clients, and is the backbone of the ETL pipeline feeding DM.

Historically, Sterling has operated as an opaque "black box" in the FAC environment — implemented by a prior IT manager who has since departed, and extended over several years by a separate Integration team whose original architects are no longer with the company. The Integration team's infrastructure (housed in the `Integration` database on the AG, built during 2020-2021) consists of roughly 320 tables and hundreds of stored procedures that collectively process and stage data between Sterling and DM. This infrastructure was built in a silo, often without attention to database design best practices, and documentation of how it all fits together is sparse. The Integration team has since been absorbed into Applications & Integration, and ongoing understanding of this infrastructure is being rebuilt gradually.

The xFACts B2B module's mandate is to build operational visibility over this critical data pipeline — detecting failures, tracking schedule adherence, surfacing execution history, and providing a real-time window into what's happening inside the Sterling processing layer. The eventual goal is end-to-end file lifecycle tracking spanning the full platform: File Monitoring (SFTP receipt) → B2B (Sterling ETL processing) → Batch Monitoring (DM loading).

---

## Current Understanding

The investigation phase is ongoing. Key conclusions that shape where we're headed:

**b2bi is the authoritative source for execution and schedule data.** Sterling's own operational database on FA-INT-DBP records everything that happens. TRANS_DATA stores gzip-compressed ProcessData documents that self-describe every workflow run's configuration. Direct extraction from b2bi provides real-time, universal, source-of-truth fidelity that Integration-side interpretive layers cannot.

**Integration's `CLIENTS_FILES` and `CLIENTS_PARAM` are the configuration source.** Sterling assembles ProcessData at runtime from these two tables. Mirroring them into xFACts (`INT_ProcessRegistry`, `INT_ProcessConfig`) is worthwhile for configuration awareness, but they are not execution records.

**`FA_CLIENTS_MAIN` is the universal unit of work.** Every meaningful Sterling workflow run is driven by MAIN (WFD_ID 798). Dispatch patterns vary, but MAIN is consistent.

**MAIN is polymorphic.** It takes multiple fundamentally different execution paths depending on ProcessData — Standard File Processing, SP Executor (Internal Operation), SFTP Cleanup (FILE_DELETION), and possibly Polling Worker. This has significant implications for run classification and the collector's job.

**Five dispatch patterns exist.** Schedule-fired named workflow, GET_LIST dispatcher loop, Periodic Internal Operation Scanner, Periodic Puller, and Parallel Phased Workers. Pattern 5 (Parallel Phased Workers) is the operationally important one for ACADIA EO and complicates execution tracking grain.

**Three identity scopes coexist.** Sterling Entity (CLIENT_ID), Sterling Process (CLIENT_ID, SEQ_ID), and DM Creditor Key. These are distinct and "client" means different things depending on context. The xFACts B2B schema uses "Entity" to reflect the mixed nature of configured targets (real customers, vendors, internal services).

**There are still significant unknowns.** Most process types (25 of 30 identified) have not yet been traced. Pattern 5 grain resolution is unresolved. Several configuration field semantics (AUTOMATED, RUN_FLAG, PREV_SEQ enforcement) are speculative. The Integration team has 16 questions pending that will resolve several of these.

**The roadmap defers table design until investigation is sufficient.** `SI_ExecutionTracking` in particular cannot have final column definitions until the Pattern 5 grain question is resolved and enough process-type anatomies are traced to validate the planned extraction approach works universally.

---

## Background

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

**Cross-server consideration:** b2bi (on FA-INT-DBP) and Integration (on AVG-PROD-LSNR) are on separate servers with no linked server connectivity. Cross-database joins are not possible. Where data from both environments is needed for a logical operation, this is handled in the xFACts collector scripts via separate queries, not in SQL joins.

---

## Schema and Naming Conventions

Tables within the B2B schema use prefixes to indicate data source origin:

- **`SI_`** — Data sourced from b2bi (**S**terling **I**ntegrator) database on FA-INT-DBP
- **`INT_`** — Data sourced from Integration database on AVG-PROD-LSNR

Entity terminology (not "Client") is used for configured Sterling targets because those targets include real customers, vendors, and internal services — "Entity" is more accurate across the full population.

### Module Registration

- **Module_Registry:** B2B — "IBM Sterling B2B Integrator file transfer and ETL processing monitoring"
- **Component_Registry:** B2B (single component — same pattern as BatchOps, BIDATA, FileOps)
- **System_Metadata:** version 1.0.0

---

## Table Inventory (High-Level)

Current and planned tables supporting the B2B module. Column-level design is deferred to DDL generation sessions after investigation is sufficient. The architecture doc describes the conceptual role of each table; this inventory is just a status view.

| Table | Prefix | Status | Purpose |
|-------|--------|--------|---------|
| `dbo.ClientHierarchy` | — | ✅ Built | Shared infrastructure — flattened DM creditor hierarchy for crosswalk and grouping |
| `B2B.SI_WorkflowTracking` | SI_ | ✅ Built (Phase 1) | Workflow execution records from WORKFLOW_CONTEXT (initial design — relationship to SI_ExecutionTracking to be evaluated) |
| `B2B.SI_ProcessBaseline` | SI_ | ✅ Built (Phase 1) | Per-process activity detection baselines |
| `B2B.INT_ClientRegistry` | INT_ | ✅ Built | Client roster from Integration CLIENTS_MN (planned rename to `INT_EntityRegistry`) |
| `B2B.INT_EntityRegistry` | INT_ | Rename planned | `INT_ClientRegistry` renamed + altered with classification columns |
| `B2B.INT_ProcessRegistry` | INT_ | To design | Process-level classification mirror of `tbl_B2B_CLIENTS_FILES` |
| `B2B.INT_ProcessConfig` | INT_ | To design | Field-level configuration mirror of `tbl_B2b_CLIENTS_PARAM` |
| `B2B.SI_ScheduleRegistry` | SI_ | To design | Sterling SCHEDULE mirror with parsed structured timing XML |
| `B2B.SI_ExecutionTracking` | SI_ | To design (grain pending) | Per-execution tracking header — grain blocked on Pattern 5 resolution |
| `B2B.SI_ProcessDataCache` | SI_ | To design | Decompressed ProcessData XML storage per MAIN run |

---

## Phase Plan

Five phases, flattened from the earlier seven-phase structure. Phases overlap at the edges but roughly gate each other.

### Phase 1 — Foundation ✅ Complete

- Shared `dbo.ClientHierarchy` table + refresh script deployed
- B2B schema registered (Module_Registry, Component_Registry, System_Metadata)
- `SI_WorkflowTracking`, `SI_ProcessBaseline`, `INT_ClientRegistry` built
- Phase 1 collectors (`Collect-B2BWorkflow.ps1`, `Sync-B2BConfig.ps1`) deployed

### Phase 2 — Investigation (In Progress)

**Goal:** Understand Sterling's operational model well enough to design the execution tracking schema with confidence.

**Approach:** investigate before building. Minimize re-work by committing to architecture only after the system's behavior is well understood across process types.

**Work items:**

- Document each process type's anatomy in its own companion doc (see Process Anatomy Progress Tracker below)
- Maintain and revise `B2B_ArchitectureOverview.md` as new patterns and edge cases are discovered
- Resolve the Pattern 5 grain question (Options A-D in architecture doc) before committing to `SI_ExecutionTracking` structure
- Complete `INT_EntityRegistry` rename/alter path so it can serve as the entity-name source instead of the current scaffolded-but-empty state
- Track Integration team answers as they arrive (see Open Questions section)

**Exit criteria:**
- Majority of operationally important process types traced (at minimum: all process types with live runs observed in-window)
- Pattern 5 grain question resolved
- Grain-breaking edge cases documented or ruled out
- Integration team answers received on critical configuration field semantics (especially AUTOMATED, RUN_FLAG, PREV_SEQ)

### Phase 3 — Backend Build

**Prerequisite:** Phase 2 substantially complete.

- Design and deploy `B2B.INT_EntityRegistry` (rename + alter of existing `INT_ClientRegistry`)
- Design and deploy `B2B.INT_ProcessRegistry` and `B2B.INT_ProcessConfig`
- Design and deploy `B2B.SI_ScheduleRegistry`
- Design and deploy `B2B.SI_ExecutionTracking` and `B2B.SI_ProcessDataCache`
- Build `Sync-B2BSchedules.ps1` (schedule extraction + parsing)
- Build `Collect-B2BExecution.ps1` (core MAIN execution collector)
- Run new collectors in parallel with Phase 1 collectors; validate
- Evaluate whether Phase 1 tables should be retired, merged, or retained alongside new tables

### Phase 4 — Monitoring and Alerting

**Prerequisite:** Phase 3 complete; at least 2-4 weeks of data accumulated.

- Build `Monitor-B2B.ps1` — detects failures, missing scheduled runs, anomalies
- Define alert thresholds in collaboration with Apps team
- Integrate with Teams and Jira
- Pilot-run alerting before broad enablement

### Phase 5 — Control Center UI

**Prerequisite:** Phase 4 data model stable.

- B2B Monitoring Control Center page (route, API, CSS, JS)
- Process status overview, failure feed, missing process alerts, schedule adherence
- Entity-grouped views with ClientHierarchy resolution
- Drill-down from summary to individual workflow runs with ProcessData detail

**Future / post-MVP:** volume and duration anomaly detection; end-to-end file lifecycle (FileOps → B2B → BatchOps) correlation; DM batch correlation; trend analysis; automatic baseline drift detection.

---

## Process Anatomy Progress Tracker

Mirrors the investigation inventory in `B2B_ArchitectureOverview.md`. Updated as anatomies are completed.

**Legend:** ✅ Fully traced · ⚠️ Partially characterized · ❌ Not yet traced

| # | PROCESS_TYPE | COMM_METHOD | Status | Anatomy Doc |
|--:|---|---|---|---|
| 1 | NEW_BUSINESS | INBOUND | ✅ | `B2B_ProcessAnatomy_NewBusiness.md` |
| 2 | FILE_DELETION | INBOUND | ⚠️ | Planned |
| 3 | SPECIAL_PROCESS | INBOUND | ⚠️ | Planned (pipeline orchestration use case) |
| 4 | ENCOUNTER | INBOUND | ⚠️ | Planned |
| 5 | PAYMENT | INBOUND | ⚠️ | Planned (needs re-verification + multi-client modes) |
| 6 | NOTES | OUTBOUND | ⚠️ | Planned (needs re-verification) |
| 7 | RETURN | INBOUND | ❌ | — |
| 8 | RETURN | OUTBOUND | ❌ | — |
| 9 | RECON | INBOUND | ❌ | — |
| 10 | RECON | OUTBOUND | ❌ | — |
| 11 | REMIT | OUTBOUND | ❌ | — |
| 12 | SPECIAL_PROCESS | OUTBOUND | ❌ | — |
| 13 | SIMPLE_EMAIL | INBOUND | ❌ | — |
| 14 | SIMPLE_EMAIL | OUTBOUND | ❌ | — |
| 15 | FILE_EMAIL | INBOUND | ❌ | — |
| 16 | FILE_EMAIL | OUTBOUND | ❌ | — |
| 17 | NOTES | INBOUND | ❌ | — |
| 18 | NOTES_EMAIL | OUTBOUND | ❌ | — |
| 19 | NOTE | OUTBOUND | ❌ | — |
| 20 | ACKNOWLEDGMENT | OUTBOUND | ❌ | — |
| 21 | SFTP_PUSH | OUTBOUND | ❌ | — |
| 22 | SFTP_PUSH_ED25519 | OUTBOUND | ❌ | — |
| 23 | SFTP_PULL | OUTBOUND | ❌ | — |
| 24 | BDL | INBOUND | ❌ | — |
| 25 | STANDARD_BDL | INBOUND | ❌ | — |
| 26 | NCOA | INBOUND | ❌ | — |
| 27 | EMAIL_SCRUB | INBOUND | ❌ | — |
| 28 | ITS | OUTBOUND | ❌ | — |
| 29 | FULL_INVENTORY | INBOUND | ❌ | — |
| 30 | CORE_PROCESS | (empty) | ❌ | — |

**Progress: 1 fully traced, 5 partially characterized, 24 untraced.**

---

## Open Questions — Integration Team

Questions sent to the Integration team, tracked here for visibility. Status updated as answers arrive.

| # | Question | Status |
|--:|---|---|
| 1 | **FILE_DELETION lifecycle** — confirm SFTP remote cleanup interpretation and timing | Pending |
| 2 | **ACADIA EO pipeline coordination** — how do the 4 parallel workers coordinate phase execution | Pending |
| 3 | **`PREV_SEQ` semantics** — declarative dependency or metadata only | Pending |
| 4 | **`AUTOMATED` field values** (1 vs 2) — dispatch mechanism indicator? | Pending |
| 5 | **`RUN_FLAG` field** — lock flag, "ever run," or something else | Pending |
| 6 | **`FA_CLIENTS_GET_LIST` dispatcher** — which processes it iterates | Pending |
| 7 | **`SPECIAL_PROCESS` usage convention** | Pending |
| 8 | **External Python executable** — role of FA_MERGE_PLACEMENT_FILES.exe in ACADIA EO | Pending |
| 9 | **FILE_DELETION scope** — whether universal for SFTP-pull inbound processes | Pending |
| 10 | **Internal CLIENT_IDs inventory** | Pending |
| 11 | **Other Integration tables of interest** | Pending |
| 12 | **Legacy naming** (CLA, PV) | Pending |
| 13 | **Sterling SCHEDULE table authority** | Pending |
| 14 | **ACADIA SEQ_ID 9 mystery** (RETURN with no CLIENTS_PARAM rows) | Pending |
| 15 | **FA_PAYGROUND naming** | Pending |
| 16 | **Process type definitions** — quick descriptions of NCOA, ITS, ACKNOWLEDGMENT, CORE_PROCESS, EMAIL_SCRUB, FULL_INVENTORY, BDL vs STANDARD_BDL, REMIT, FILE_EMAIL, NOTES_EMAIL, NOTE vs NOTES | Pending |

---

## Open Design Questions (Blocking Build)

Decisions that must be made before Phase 3 can start in earnest.

| # | Question | Resolution Path |
|--:|---|---|
| 1 | `SI_ExecutionTracking` grain — how to handle Pattern 5 Parallel Phased Workers (16 rows per 1 conceptual pipeline invocation vs. deduplicated / child-table / pipeline-rollup alternatives) | Decide among Options A-D in architecture doc. Likely needs ACADIA EO to be traced more thoroughly before settling. |
| 2 | Relationship between Phase 1 `SI_WorkflowTracking` and planned `SI_ExecutionTracking` — coexist, merge, or supersede | Revisit after `SI_ExecutionTracking` has been populated. |
| 3 | Whether to persist ProcessData raw XML indefinitely or age out | Depends on storage observations and whether downstream queries ever re-parse raw XML. |
| 4 | Whether `SI_BusinessDataTracking` (record-count summaries from Translation outputs) is worth building | Defer until monitoring use cases make the case for it. |
| 5 | How to represent empty / polling / skeleton MAIN runs in execution tracking — suppress, flag, or treat same as work-performing runs | Needs trace of representative empty runs first (Path B, Path D observed; Pattern 1 empty not yet observed). |

---

## Open Investigation Items (Non-Blocking)

Items that would improve understanding but don't block the build directly. Tracked so they don't get lost.

- Empty-run behavior on Pattern 1/4 File Processes (not yet observed in-trace)
- GET_LIST spawn count and source filter (what exactly it iterates)
- Multi-Client prevalence outside PMT and ACADIA EO
- Internal Entity IDs beyond 328
- `PREPARE_COMM_CALL` invocation mechanism (no marker observed in NB trace)
- `COMM_CALL_CLA_EXE_PATH` Python exe role and ownership (covered by Integration team question #8)
- Sterling data retention exact thresholds per table
- Full inventory of stored procedures invoked via POST_TRANS_SQL_QUERY

---

## Process Naming Conventions (Reference)

Useful for interpreting workflow names at a glance.

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
| SP | TBD (Integration team question #12) |
| S2D, S2P, D2S, P2S | Transfer patterns — S = SQL; others TBD (question #12) |
| PULL / PUSH | Transfer direction initiation |

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Purpose | Top-level roadmap for the xFACts B2B module |
| Author | Applications Team (Dirk + xFACts Claude collaboration) |
| Created | January 13, 2026 |
| Last Updated | April 20, 2026 |
| Status | Active — Phase 2 (Investigation) In Progress |
| Schema | B2B |

### Revision History

| Date | Revision |
|------|----------|
| January 13, 2026 | Initial document created |
| April 16, 2026 | Phase 1 foundation complete; document updated to reflect deployed tables and scripts |
| April 17-18, 2026 | Deep investigation of b2bi internals: DATA_TABLE compression, timing XML grammar, WORKFLOW_CONTEXT ↔ TRANS_DATA linkage, ProcessData discovery, sub-workflow pattern cataloging |
| April 18, 2026 | Architecture shifted from hybrid (b2bi + Integration) to pure-b2bi; Integration tables retired from core architecture; new tables introduced; 7-phase plan established |
| April 20, 2026 | **Major rewrite to roadmap-only scope.** Architectural detail extracted to `B2B_ArchitectureOverview.md`; process-type specifics extracted to `B2B_ProcessAnatomy_*.md` docs; reference queries extracted to `B2B_Reference_Queries.md`. This document now focused on: Executive Summary, Pain Points / Infrastructure, Current Understanding, Table Inventory (status only, no column detail), 5-phase plan (flattened from 7), Process Anatomy Progress Tracker, Open Questions tracking. Column specs, sub-workflow pattern deep-dives, ProcessData field catalogs, multi-Client handling details, and empty/failed-run discussions all removed as they now live authoritatively in the architecture doc. Entity terminology direction incorporated (INT_ClientRegistry to be renamed INT_EntityRegistry). INT_ProcessRegistry and INT_ProcessConfig added to inventory. Five blocking open design questions formalized. Integration team 16-question tracker added. |

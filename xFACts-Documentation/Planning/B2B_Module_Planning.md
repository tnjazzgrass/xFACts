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

**All of these are working documents.** They will be revised as investigation continues, and may eventually serve as source material for permanent Control Center help content.

---

## Executive Summary

IBM Sterling B2B Integrator (commonly referred to as "IBM" or "IBM B2B" internally) is the platform's file transfer and ETL processing engine handling inbound and outbound file transfers between FAC and its trading partners. The system processes new business placements, payment files, notes, returns, reconciliation files, and numerous other data exchanges between FAC and its clients, and is the backbone of the ETL pipeline feeding DM.

Historically, Sterling has operated as an opaque "black box" in the FAC environment — implemented by a prior IT manager who has since departed, and extended over several years by a separate Integration team whose original architects are no longer with the company. The Integration team's infrastructure (housed in the `Integration` database on the AG, built during 2020-2021) consists of roughly 320 tables and hundreds of stored procedures that collectively process and stage data between Sterling and DM. This infrastructure was built in a silo, often without attention to database design best practices, and documentation of how it all fits together is sparse. The Integration team has since been absorbed into Applications & Integration, and ongoing understanding of this infrastructure is being rebuilt gradually.

The xFACts B2B module's mandate is to build operational visibility over this critical data pipeline — detecting failures, tracking schedule adherence, surfacing execution history, and providing a real-time window into what's happening inside the Sterling processing layer. The eventual goal is end-to-end file lifecycle tracking spanning the full platform: File Monitoring (SFTP receipt) → B2B (Sterling ETL processing) → Batch Monitoring (DM loading).

---

## Current Understanding

Phase 2 investigation is substantially complete as of April 20, 2026. The direct reading of Sterling's BPML workflow definitions and the Integration database's stored procedures has resolved the bulk of the architectural questions that were previously open. Key conclusions that shape where we're headed:

**b2bi is the authoritative source of truth for execution.** Sterling's operational database on FA-INT-DBP records everything that happens at the workflow instance level. Integration's coordination tables (BATCH_STATUS, TICKETS) are a convenience layer populated by Sterling's BPMLs — valuable for enrichment and human-readable context, but not a reliable source on their own because they only get written when workflows successfully cooperate. Infrastructure-level failures (JVM crash, network partition) leave Integration blind while b2bi captures the event. See `B2B_ArchitectureOverview.md` — "Source of Truth Stance" for the full rationale.

**`FA_CLIENTS_MAIN` is the universal unit of work.** Every meaningful Sterling workflow run is driven by MAIN (WFD_ID 798). Reading MAIN's BPML (version 48) confirmed it is a single linear sequence with ~22 conditional rules gating sub-workflow invocations. There are no structurally distinct "paths" — different process configurations just trigger different combinations of rules.

**`FA_CLIENTS_GET_LIST` is the universal dispatcher.** Reading its BPML (version 19) and its backing stored procedure (`USP_B2B_CLIENTS_GET_LIST`) resolved all dispatcher-side questions. GET_LIST serves two modes via the SP's two code branches:
- **Branch 1** (scheduler-fired, AUTOMATED=1): handles hourly dispatch of configured processes, filtered by `RUN_FLAG=1`
- **Branch 2** (wrapper-triggered, AUTOMATED=2): handles entity-specific dispatchers with CLIENT_ID + PROCESS_TYPE or SEQ_IDS filters

**Four dispatch patterns, not five.** What earlier revisions called "Pattern 5 (Parallel Phased Workers)" is actually just Pattern 4 with `SEQUENTIAL=1` and explicit `SEQ_IDS`. The ~90-second worker offsets we observed were a natural consequence of each phase's real runtime + BATCH_STATUS polling, not a distinct coordination mechanism. See the architecture doc's "Dispatch Patterns" section.

**The coordination layer is richer than we initially assumed.** Integration tables we now know are active players:
- `tbl_B2B_CLIENTS_BATCH_STATUS` — per-run state machine (written by MAIN and GET_LIST)
- `tbl_B2B_CLIENTS_TICKETS` — failure ticket log with ticket type classification
- `tbl_B2B_CLIENTS_SETTINGS` — global settings read by every GET_LIST run
- `tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` — the discovered-files table populated by Pattern 3 workflows and consumed by Pattern 2 for per-file inbound dispatch

**MAIN processes a single Client per run.** MAIN's BPML references `//Result/Client[1]/...` throughout — never Client[2], [3], etc. Earlier observations of "4 Client blocks in ACADIA EO ProcessData" were reading `//PrimaryDocument` (the raw SP result set) rather than `//Result` (the per-iteration current Client). GET_LIST's loop copies one Client per iteration to `//Result` before invoking MAIN, so each MAIN invocation gets single-Client ProcessData.

**PREV_SEQ is declaratively enforced.** MAIN's `Wait?` and `Continue?` rules implement a polling loop against BATCH_STATUS for the PREV_SEQ-referenced predecessor. When a dependency has BATCH_STATUS = -1 (failed), the dependent MAIN short-circuits — skipping all processing and exiting via its tail UPDATE. This is the mechanism underlying sequential pipeline cascades (e.g., ACADIA EO's SPECIAL_PROCESS → NEW_BUSINESS → PAYMENT → ENCOUNTER chain).

**Credentials exist in ProcessData beyond PGP.** In addition to `PGP_PASSPHRASE` (already documented), `PYTHON_KEY` is stored in `tbl_B2B_CLIENTS_SETTINGS` and flows into every MAIN run's ProcessData via the Settings/Values node. Any `SI_ProcessDataCache` design must address both.

**Failure detection requires nuance.** A simple `BASIC_STATUS > 0` scan is not enough. The root cause step may have `BASIC_STATUS = 0` with the error encoded in `ADV_STATUS` (e.g., `FA_CLA_UNPGP` exit code 255). Base Sterling services (`SFTPClientBeginSession`, `AS3FSAdapter`, `Translation`, etc.) can fail directly without a wrapping `Inline Begin` marker. The collector must capture the failure span.

**Grain question resolved.** Because MAIN processes a single Client per run, the natural grain is simply "one row per MAIN run" with Client[1]'s identity as columns. No multi-Client row explosion; the "16 rows per pipeline invocation" concern from prior revisions no longer applies.

**Still unknown / partially understood:**
- Whether `FA_CLIENTS_ETL_CALL` is actually used anywhere (its BPML has never been edited since v1 creation; if no Clients have `ETL_PATH` populated it may be effectively dead code).
- `E:\Utilities\FA_FILE_CHECK.java` — Java utility invoked by `FA_CLIENTS_GET_DOCS` during SFTP operations; source not yet read.
- Sterling translation map `FA_CLIENTS_BATCH_FILES_X2S` — invoked by GET_DOCS post-loop; purpose and output not yet analyzed.
- Multiple remaining process-type anatomies.

**Additional findings this session (rev 5):** Reading `FA_CLIENTS_GET_DOCS` (v37) and `FA_CLIENTS_ETL_CALL` (v1) revealed:
- FILE_DELETION lives in GET_DOCS, not MAIN — operates via the `ZeroSize?` rule forcing every file to skip retrieval.
- GET_DOCS handles three acquisition types: SFTP_PULL, FSA_PULL, and a newly discovered API_PULL (Python exe download prelude that mutates to FSA_PULL).
- ETL_CALL invokes Pervasive Cosmos 9's `djengine.exe` for macro-based ETL — NOT a SQL SP executor as initially assumed.
- ETL_CALL's BATCH_STATUS conventions diverge from MAIN in four ways that suggest it cannot safely be a PREV_SEQ predecessor.
- New Integration table discovered: `tbl_B2B_CLIENTS_BATCH_FILES` — file-level audit scoped to zero-size and FILE_DELETION files only.
- `MARCOS_PATH` setting resolved — root directory for Pervasive Cosmos macro files (likely "MACROS" typo).

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
| JDBC Pool (Sterling → Integration) | `AVG_PROD_LSNR_INTEGRATION` |
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

Current and planned tables supporting the B2B module. Column-level design is deferred to DDL generation sessions. The architecture doc describes the conceptual role of each table; this inventory is just a status view.

| Table | Prefix | Status | Purpose |
|-------|--------|--------|---------|
| `dbo.ClientHierarchy` | — | ✅ Built | Shared infrastructure — flattened DM creditor hierarchy for crosswalk and grouping |
| `B2B.SI_WorkflowTracking` | SI_ | ✅ Built (Phase 1) | Workflow execution records from WORKFLOW_CONTEXT (initial design — relationship to SI_ExecutionTracking to be evaluated; likely to be retired once SI_ExecutionTracking is deployed) |
| `B2B.SI_ProcessBaseline` | SI_ | ✅ Built (Phase 1) | Per-process activity detection baselines |
| `B2B.INT_ClientRegistry` | INT_ | ✅ Built | Client roster from Integration CLIENTS_MN (planned rename to `INT_EntityRegistry`) |
| `B2B.INT_EntityRegistry` | INT_ | Rename planned | `INT_ClientRegistry` renamed + altered with classification columns |
| `B2B.INT_ProcessRegistry` | INT_ | To design | Process-level classification mirror of `tbl_B2B_CLIENTS_FILES` |
| `B2B.INT_ProcessConfig` | INT_ | To design | Field-level configuration mirror of `tbl_B2b_CLIENTS_PARAM` |
| `B2B.INT_Settings` | INT_ | To design | Global settings mirror of `tbl_B2B_CLIENTS_SETTINGS` (includes credentials — handling subject to design decision) |
| `B2B.SI_ScheduleRegistry` | SI_ | To design | Sterling SCHEDULE mirror with parsed structured timing XML |
| `B2B.SI_ExecutionTracking` | SI_ | To design | Per-execution tracking header — grain resolved (one row per MAIN WORKFLOW_ID) |
| `B2B.SI_ProcessDataCache` | SI_ | To design (credential handling pending) | Decompressed ProcessData XML storage per MAIN run |

---

## Phase Plan

Five phases, flattened from the earlier seven-phase structure. Phases overlap at the edges but roughly gate each other.

### Phase 1 — Foundation ✅ Complete

- Shared `dbo.ClientHierarchy` table + refresh script deployed
- B2B schema registered (Module_Registry, Component_Registry, System_Metadata)
- `SI_WorkflowTracking`, `SI_ProcessBaseline`, `INT_ClientRegistry` built
- Phase 1 collectors (`Collect-B2BWorkflow.ps1`, `Sync-B2BConfig.ps1`) deployed

### Phase 2 — Investigation ✅ Substantially Complete

**Goal:** Understand Sterling's operational model well enough to design the execution tracking schema with confidence.

**Approach:** investigate before building. The April 20, 2026 BPML/SP reading session closed the bulk of the outstanding architectural questions.

**Work completed:**
- `FA_CLIENTS_MAIN` BPML read end-to-end (v48)
- `FA_CLIENTS_GET_LIST` BPML read end-to-end (v19)
- `FA_CLIENTS_GET_DOCS` BPML read end-to-end (v37)
- `FA_CLIENTS_ETL_CALL` BPML read end-to-end (v1)
- Four dispatcher wrapper BPMLs read (ACADIA EO, ACCRETIVE, COACHELLA VALLEY, MONUMENT)
- `USP_B2B_CLIENTS_GET_LIST` stored procedure read and analyzed
- `USP_B2B_CLIENTS_GET_SETTINGS` stored procedure read and analyzed
- Architecture doc updated through revision 8 capturing all findings
- Dispatcher model unified (Patterns 2 and 5 merged into Pattern 4 parameterization)
- Integration coordination layer characterized (BATCH_STATUS, TICKETS, SETTINGS, BATCH_FILES, FTP_FILES_LIST)
- Source of truth stance committed (b2bi primary, Integration enrichment, disagreement as alert)
- Grain question resolved (one row per MAIN WORKFLOW_ID)
- PREV_SEQ / AUTOMATED / RUN_FLAG / SEQUENTIAL semantics resolved
- FILE_DELETION implementation resolved (ZeroSize? rule in GET_DOCS)
- ETL_CALL subsystem characterized (Pervasive Cosmos 9 macro executor)

**Remaining Phase 2 items (not blocking Phase 3 start):**
- Individual process-type anatomies (now treated as discovery-as-needed, no longer blocking)
- Credential handling decision for ProcessDataCache (blocks Phase 3 table creation for that specific table)
- Usage census of ETL_CALL (query CLIENTS_PARAM for ETL_PATH rows — determines whether ETL_CALL warrants collector attention)
- `FA_FILE_CHECK.java` source read (nice-to-have; gives context on what GET_DOCS does during SFTP operations)
- Translation map `FA_CLIENTS_BATCH_FILES_X2S` analysis (nice-to-have)

### Phase 3 — Backend Build

**Prerequisite:** Phase 2 substantially complete (now the case). Concrete table and collector design is documented in `B2B_ArchitectureOverview.md` under "Execution Tracking Design."

**Current thinking on the build sequence:**

This is our committed direction unless something in early implementation surfaces a concern that shifts it. The phase 3 work breaks into three natural blocks:

**Block 1 — Configuration mirror tables (low risk, builds understanding of Integration data shapes):**
- `B2B.INT_EntityRegistry` — rename + alter of existing `INT_ClientRegistry`; mirrors `tbl_B2B_CLIENTS_MN`
- `B2B.INT_ProcessRegistry` — mirrors `tbl_B2B_CLIENTS_FILES`
- `B2B.INT_ProcessConfig` — mirrors `tbl_B2b_CLIENTS_PARAM`
- `B2B.INT_Settings` — mirrors `tbl_B2B_CLIENTS_SETTINGS` with credential redaction
- `B2B.SI_ScheduleRegistry` — b2bi schedule extraction (TIMINGXML-parsed)
- `Sync-B2BConfig.ps1` — populates Block 1 tables via scheduled sync

These are the HIGH-trust Integration tables (per the Trust Matrix in the architecture doc). They're static-ish config data. Mirroring them gives us queryable reference data and confirms the sync pattern before we take on the higher-risk execution collector.

**Block 2 — Execution tracking (the core deliverable):**
- `B2B.SI_ExecutionTracking` — column design finalized; see architecture doc "Execution Tracking Design" section for the complete schema including disagreement flags
- `Collect-B2BExecution.ps1` — core collector following the documented flow:
  1. b2bi primary poll — WF_INST_S for new FA_CLIENTS_MAIN and FA_CLIENTS_ETL_CALL runs
  2. b2bi enrichment per captured run — WORKFLOW_LINKAGE, WORKFLOW_CONTEXT analysis, ProcessData parse
  3. Integration bulk-join enrichment — BATCH_STATUS and TICKETS in batched queries, hash-joined in memory
  4. Compute disagreement flags (`int_status_missing`, `int_status_inconsistent`, `alert_infrastructure_failure`)
  5. MERGE into SI_ExecutionTracking
  6. Advance high-water mark

- Start simple (single-pass, modest batch sizes) and layer complexity as real data flows

**Block 3 — Deferred until credential decision is made:**
- `B2B.SI_ProcessDataCache` — holds decompressed ProcessData for forensic drill-down. Blocks on choosing an approach from: redact-credentials / parse-only-non-sensitive-fields / encrypt-at-rest / short-retention-only. Collector can operate without this table; it's purely forensic.

**Parallel operation and validation:**
- Run new collectors in parallel with Phase 1 collectors; compare results
- Validate that SI_ExecutionTracking captures every run we see in b2bi (no silent gaps)
- Tune disagreement rate thresholds based on observed frequencies
- Evaluate whether Phase 1 tables should be retired, merged, or retained

**Key principle for the build:** b2bi is authoritative; Integration is enrichment-only. Every execution captured in WF_INST_S gets a SI_ExecutionTracking row regardless of whether Integration has matching data. This is the architectural resolution of the historical "lack of centralized execution logging" concern.

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

Mirrors the investigation inventory in `B2B_ArchitectureOverview.md`.

**Legend:** ✅ Fully traced · ⚠️ Partially characterized · ❌ Not yet traced

| # | PROCESS_TYPE | COMM_METHOD | Status | Anatomy Doc |
|--:|---|---|---|---|
| 1 | NEW_BUSINESS | INBOUND | ✅ (standard) / ⚠️ (PGP variant) | `B2B_ProcessAnatomy_NewBusiness.md`; PGP variant needs separate coverage |
| 2 | FILE_DELETION | INBOUND | ⚠️ | Planned (deferred until GET_DOCS BPML read) |
| 3 | SPECIAL_PROCESS | INBOUND | ⚠️ | Planned (pipeline orchestration use case) |
| 4 | ENCOUNTER | INBOUND | ⚠️ | Planned |
| 5 | PAYMENT | INBOUND | ⚠️ | Planned (needs re-verification + multi-client modes) |
| 6 | NOTES | OUTBOUND | ⚠️ | Planned (needs re-verification) |
| 7 | SFTP_PULL | INBOUND | ⚠️ | Dispatcher side now understood; MAIN-side anatomy still to trace |
| 8 | SFTP_PULL | OUTBOUND | ⚠️ | Characterized via dispatcher wrappers; MAIN-side anatomy still to trace |
| 9-30 | Remaining types | Various | ❌ | See architecture doc Process Type Investigation Status table |

**Progress: 1 fully traced (NB standard), 7 partially characterized. 23 untraced.**

With Phase 2 substantially complete, further process-type anatomies become "nice to have as they arise" rather than "required before building." They can happen alongside Phase 3 / Phase 4 work as specific process types warrant attention.

---

## Known Failure Modes (Cumulative)

Discovered during investigation. Full detail in `B2B_ArchitectureOverview.md`.

| Mode | Signature | Operational Note |
|------|-----------|------------------|
| SSH_DISCONNECT_BY_APPLICATION | SFTPClientBeginSession step ~12, BASIC_STATUS=1 | Observed clustering at hours 04/10/16 (24-hour sample). May be remote maintenance windows or Sterling-side periodic activity. |
| FA_CLA_UNPGP exit 255 | Step ~54, BASIC_STATUS=0, ADV_STATUS="255" | PGP decrypt failed. Only applies to configs with `PGP_PASSPHRASE` populated. Root cause detection requires scanning ADV_STATUS, not just BASIC_STATUS. |

Corresponding `tbl_B2B_CLIENTS_TICKETS` rows are written with ticket type `'MAP ERROR'` (from MAIN's onFault) for both failure modes. The ticket type name is misleading for SSH_DISCONNECT (transport error, not translation) — but the ticket presence is still a valid failure signal.

More modes will be added as encountered.

---

## Open Questions — Apps Team

Significantly reduced from prior revisions — most resolved by BPML/SP reads.

| # | Question | Status |
|--:|---|---|
| 1 | FILE_DELETION lifecycle | ✅ Resolved (GET_DOCS ZeroSize? rule with PROCESS_TYPE='FILE_DELETION') |
| 2 | ACADIA EO pipeline coordination | ✅ Resolved (BATCH_STATUS + PREV_SEQ + GET_LIST SEQUENTIAL) |
| 3 | `PREV_SEQ` semantics | ✅ Resolved (declaratively enforced) |
| 4 | `AUTOMATED` field values | ✅ Resolved (1=scheduler, 2=wrapper) |
| 5 | `RUN_FLAG` field | ✅ Resolved ("currently executing" flag for AUTOMATED=1) |
| 6 | `FA_CLIENTS_GET_LIST` dispatcher | ✅ Resolved (USP_B2B_CLIENTS_GET_LIST two-branch logic) |
| 7 | `SPECIAL_PROCESS` usage convention | Still unclear across contexts |
| 8 | External Python executable inventory | Three observed (FA_FILE_REMOVE_SPECIAL_CHARACTERS, FA_MERGE_PLACEMENT_FILES, per-Client GET_DOCS_API); full inventory would help maintenance scoping |
| 9 | FILE_DELETION scope | ✅ Resolved (universal to SFTP_PULL inbound with PROCESS_TYPE='FILE_DELETION') |
| 10 | Internal CLIENT_IDs inventory | Still building list |
| 11 | Other Integration tables of interest | BATCH_FILES added this session; potentially more still |
| 12 | Legacy naming (CLA, PV) | CLA confirmed "Command Line Adapter"; PV meaning still open |
| 13 | Sterling SCHEDULE table authority | Implicit — SCHEDULE fires named workflows |
| 14 | ACADIA SEQ_ID 9 mystery | Still open |
| 15 | FA_PAYGROUND naming | Still open |
| 16 | Process type definitions | Still mostly open for less-common types |
| 17 | `FA_CLIENTS_ETL_CALL` role | ✅ Resolved (Pervasive Cosmos macro executor) |
| 18 | Known infrastructure-failure cases | Examples of "failed in b2bi, not in Integration" cases to validate alert logic |
| 19 | Is ETL_CALL actually in use anywhere? (NEW) | Query CLIENTS_PARAM for rows with PARAMETER_NAME='ETL_PATH'. Zero rows = effectively dead code. |
| 20 | `MARCOS_PATH` filesystem location (NEW) | What directory does MARCOS_PATH point to? Inventory of Pervasive macro files would help understand ETL_CALL usage. |
| 21 | `FA_FILE_CHECK.java` purpose (NEW) | Java utility on Sterling app server (E:\Utilities\) invoked by GET_DOCS — what does it validate? |
| 22 | Translation map `FA_CLIENTS_BATCH_FILES_X2S` (NEW) | Purpose and output of the map GET_DOCS invokes post-loop for non-SFTP_PULL processes? |

---

## Open Design Questions (Blocking Build)

Dramatically reduced from prior revisions.

| # | Question | Resolution Path |
|--:|---|---|
| 1 | ~~`SI_ExecutionTracking` grain~~ | ✅ Resolved — one row per MAIN WORKFLOW_ID |
| 2 | Relationship between Phase 1 `SI_WorkflowTracking` and new `SI_ExecutionTracking` — coexist, merge, or supersede | Revisit once `SI_ExecutionTracking` has been populated. Most likely outcome: SI_WorkflowTracking is retired in favor of the richer new table. |
| 3 | ProcessData credential handling for `SI_ProcessDataCache` — how to prevent plaintext credentials (`PGP_PASSPHRASE`, `PYTHON_KEY`, etc.) from being persisted in xFACts | Decide before building `SI_ProcessDataCache`. Options: redact known sensitive fields / parsed subset only / encrypt at rest / short retention / combination. |
| 4 | Whether to persist ProcessData indefinitely or age out | Depends on storage observations, downstream query needs, AND the credential handling decision (stricter retention if credentials are present). |
| 5 | Whether `SI_BusinessDataTracking` (record-count summaries from Translation outputs) is worth building | Defer until monitoring use cases make the case for it. |
| 6 | ~~How to represent empty / polling / skeleton MAIN runs~~ | ✅ Resolved — collector captures sub-workflow invocation counts + run_class classification; short-circuit runs are identifiable by absence of sub-workflow invocations after GET_DOCS |
| 7 | Whether `INT_Settings` should be mirrored at all given it contains `PYTHON_KEY` (NEW) | Leaning toward: yes for non-credential fields, explicit exclusion of credential fields. Same credential-handling design as ProcessDataCache. |

---

## Open Investigation Items (Non-Blocking)

Items that would improve understanding but don't block the build directly.

- Whether `FA_CLIENTS_ETL_CALL` is actually used anywhere (query CLIENTS_PARAM for ETL_PATH rows)
- `E:\Utilities\FA_FILE_CHECK.java` source read — what does this validate during GET_DOCS SFTP flow?
- Translation map `FA_CLIENTS_BATCH_FILES_X2S` — what does GET_DOCS translate at the end of the file loop?
- Pervasive Cosmos macro inventory — if ETL_CALL is in use, what macros live at MARCOS_PATH?
- Empty-run behavior on Pattern 4 pullers (not yet observed in-trace)
- Multi-Client prevalence in raw ProcessData (PrimaryDocument vs. //Result coexistence patterns)
- Internal Entity IDs beyond 328
- `PREPARE_COMM_CALL` invocation mechanism (no marker observed in NB trace, but rule is present in MAIN)
- `COMM_CALL_CLA_EXE_PATH` Python exe ownership and role
- Sterling data retention exact thresholds per table
- Full inventory of stored procedures invoked via POST_TRANS_SQL_QUERY
- **SSH_DISCONNECT clustering** (hours 04/10/16) — check `GET_DOCS_PROFILE_ID` across affected dispatchers
- **Scheduling collision quantification** — how often do independent entities have colliding round-hour schedules
- **BATCH_STATUS column default** — what DB-side default produces the 0/1 values the Wait? rule polls for
- **ETL_CALL polling-hang risk verification** — theoretical based on BPML divergences; confirm whether ever manifests in practice

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
| Status | Active — Phase 2 (Investigation) Substantially Complete; Phase 3 ready to start |
| Schema | B2B |

### Revision History

| Date | Revision |
|------|----------|
| January 13, 2026 | Initial document created |
| April 16, 2026 | Phase 1 foundation complete; document updated to reflect deployed tables and scripts |
| April 17-18, 2026 | Deep investigation of b2bi internals: DATA_TABLE compression, timing XML grammar, WORKFLOW_CONTEXT ↔ TRANS_DATA linkage, ProcessData discovery, sub-workflow pattern cataloging |
| April 18, 2026 | Architecture shifted from hybrid to pure-b2bi; Integration tables retired from core architecture; new tables introduced; 7-phase plan established |
| April 20, 2026 (rev 1) | Major rewrite to roadmap-only scope. Architectural detail extracted to `B2B_ArchitectureOverview.md`; process-type specifics extracted to `B2B_ProcessAnatomy_*.md` docs; reference queries extracted to `B2B_Reference_Queries.md`. 5-phase plan. |
| April 20, 2026 (rev 2) | Updated with findings from failure trace session (DENVER HEALTH NB and SFTP_PULL OUTBOUND failures). |
| April 20, 2026 (rev 3) | Updated after ACADIA EO Pattern 5 deep trace. BPML read added as next-session priority. |
| April 20, 2026 (rev 4) | **MAJOR UPDATE after direct BPML and stored procedure reads.** Six BPMLs read end-to-end (FA_CLIENTS_MAIN v48, FA_CLIENTS_GET_LIST v19, four dispatcher wrappers). Both key Integration SPs analyzed. Changes: (1) **Current Understanding** completely rewritten — b2bi-authoritative stance explicit, dispatcher model unified (4 patterns not 5), grain resolved, MAIN's single-Client nature clarified, coordination layer documented. (2) **Phase 2 marked substantially complete** — most exit criteria met, Phase 3 can start. (3) **Phase 3 prerequisites refined** — concrete collector architecture (primary b2bi loop + Integration enrichment). (4) **Table Inventory** adds `INT_Settings`; `SI_ExecutionTracking` grain marked resolved. (5) **Open Questions — Apps Team** drastically reduced — 10+ items resolved by BPML/SP reads, 2 new items added. (6) **Open Design Questions** reduced — grain resolved, credential handling extended to include PYTHON_KEY from Settings. (7) **Process Anatomy Progress Tracker** simplified — no longer block-blocking; SFTP_PULL INBOUND added as newly characterized dispatcher-side. (8) **Failure mode table** notes TICKETS correspondence ('MAP ERROR' type). All substantive changes cross-reference the architecture doc (rev 7) for detail. |
| April 20, 2026 (rev 5) | **Updated after GET_DOCS and ETL_CALL BPML reads.** Two more BPMLs read end-to-end (FA_CLIENTS_GET_DOCS v37, FA_CLIENTS_ETL_CALL v1). Changes: (1) **Current Understanding** updated — FILE_DELETION implementation resolved (ZeroSize? rule in GET_DOCS), ETL_CALL subsystem characterized (Pervasive Cosmos 9 macro executor, not SQL SP executor as assumed), API_PULL GET_DOCS_TYPE variant added, BATCH_FILES table added to Integration inventory, MARCOS_PATH resolved. (2) **Phase 2 completed work list** expanded — 14 items now checked off (was 12). (3) **Remaining Phase 2 items** — removed ETL_CALL and GET_DOCS BPML reads (done); added usage census of ETL_CALL, FA_FILE_CHECK.java read, and FA_CLIENTS_BATCH_FILES_X2S translation map analysis as nice-to-haves. (4) **Apps Team Questions** — 2 more resolved (FILE_DELETION lifecycle/scope, ETL_CALL role), 4 new items added (ETL_CALL usage, MARCOS_PATH location, FA_FILE_CHECK.java purpose, translation map analysis). (5) **Open Investigation Items** updated — items resolved removed, new items added (Pervasive macro inventory, ETL_CALL polling-hang verification). All substantive changes cross-reference architecture doc (rev 8) for detail. |
| April 20, 2026 (rev 6) | **Phase 3 build path formalized as committed current thinking.** Restructures Phase 3 section from a flat list into three concrete blocks: (1) Block 1 — Configuration mirror tables (low-risk HIGH-trust Integration mirror; builds pattern before execution collector). (2) Block 2 — Execution tracking (SI_ExecutionTracking with complete design referenced from architecture doc; Collect-B2BExecution.ps1 with 6-step flow). (3) Block 3 — SI_ProcessDataCache deferred behind credential handling decision; collector operates independently. Adds parallel-operation validation plan and key architectural principle statement ("b2bi authoritative, Integration enrichment-only"). Cross-references architecture doc (rev 9) "Execution Tracking Design" section for full column schema including disagreement flags and trust matrix. |

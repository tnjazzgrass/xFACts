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

**All of these are working documents.** They are reference material for the active build effort. Once the module goes live and permanent Control Center documentation is in place, these planning documents will be retired.

---

## Executive Summary

IBM Sterling B2B Integrator (commonly referred to as "IBM" or "IBM B2B" internally) is the platform's file transfer and ETL processing engine handling inbound and outbound file transfers between FAC and its trading partners. The system processes new business placements, payment files, notes, returns, reconciliation files, and numerous other data exchanges between FAC and its clients, and is the backbone of the ETL pipeline feeding DM.

Historically, Sterling has operated as an opaque "black box" in the FAC environment — implemented by a prior IT manager who has since departed, and extended over several years by a separate Integration team whose original architects are no longer with the company. The Integration team's infrastructure (housed in the `Integration` database on the AG, built during 2020-2021) consists of roughly 320 tables and hundreds of stored procedures that collectively process and stage data between Sterling and DM. This infrastructure was built in a silo, often without attention to database design best practices, and documentation of how it all fits together is sparse. The Integration team has since been absorbed into Applications & Integration, and ongoing understanding of this infrastructure is being rebuilt gradually.

The xFACts B2B module's mandate is to build operational visibility over this critical data pipeline — detecting failures, tracking schedule adherence, surfacing execution history, and providing a real-time window into what's happening inside the Sterling processing layer.

**Secondary goal — file lifecycle bridging.** A planned future capability of this module is to serve as the bridge between File Monitoring (SFTP receipt and upstream file tracking) and Batch Monitoring (DM-side batch loading). The vision is a Control Center page showing end-to-end lifecycle for a file or batch — for example: *"Client X sent 12 files on date A → Sterling processed and merged them into file Y on date B → DM loaded file Y as batch Z on date C."* Achieving this requires a middle-grain detail table beyond the per-execution header — with per-file information, filenames, and summary totals (by DM Creditor Key where applicable). This is captured in the roadmap as `SI_ExecutionDetail` but is deferred until more process-type anatomies are understood and the summarizing Translation output step can be reliably identified across process types. The initial `SI_ExecutionTracking` build is designed with this future state in mind — specifically, capturing the merged output filename on each execution row so the File Monitoring → B2B → Batch Monitoring correlation points are available as the upstream and downstream modules mature.

---

## Next Starting Point

**Phase 3 Block 1 (Schedule Registry) is complete and in production. Block 2 (Execution Tracking) is the next build.**

The collector `Collect-B2BExecution.ps1` is deployed and registered in Orchestrator.ProcessRegistry with `run_mode = 0` (disabled). Block 1 functionality runs in <5 seconds and has populated `B2B.SI_ScheduleRegistry` with all 604 schedules from b2bi. The collector's Step 2 (execution collection), Step 3 (Integration enrichment), Step 4 (detail extraction), and Step 5 (alert evaluation) exist as stubs ready to be filled in.

**Next-session work, in order:**

1. **Flip the collector to `run_mode = 1`** and confirm orchestrated runs succeed (Orchestrator.TaskLog entries, `ProcessRegistry.last_execution_status = 'SUCCESS'`). Block 1 schedule sync will then run every 5 minutes under the orchestrator.
2. **Design `B2B.SI_ExecutionTracking`** per the column list in `B2B_ArchitectureOverview.md` — "Execution Tracking Design." The design includes an `is_complete BIT` column that enables cheap lookback-window queries by excluding already-terminal rows.
3. **Build Block 2 of `Collect-B2BExecution.ps1`** — `Step-CollectExecutions` and `Step-EnrichFromIntegration`. Flow: pull WF_INST_S workflow IDs for the 3-day lookback window, anti-join against `SI_ExecutionTracking WHERE is_complete = 0` to identify new or in-flight runs, decompress ProcessData only for those, bulk-enrich from `Integration.ETL.tbl_B2B_*` tables via live join.
4. **Validate and tune** — observe disagreement rates, lookback window performance, and the frequency of `alert_infrastructure_failure` signals.

After Block 2 is stable, move to Block 3 (SI_ExecutionDetail) and then Phase 4 (monitoring and alerting).

---

## Current State (as of this revision)

**What exists in xFACts for B2B today:**
- The `B2B` schema is registered in the xFACts database
- `dbo.ClientHierarchy` shared infrastructure table is built and populated (used for DM creditor crosswalk)
- **Module_Registry, Component_Registry, and System_Metadata entries** for B2B are in place
- **`B2B.SI_ScheduleRegistry` is built and populated** — 604 schedules captured from b2bi (506 ACTIVE + 98 INACTIVE). Classification: DAILY 231, WEEKLY 172, MONTHLY 167, INTERVAL 29, MIXED 5, UNKNOWN 0.
- **`Collect-B2BExecution.ps1` is deployed** — Block 1 (schedule sync) fully implemented; Block 2/3 and alert evaluation stubbed
- **Collector is registered in Orchestrator.ProcessRegistry** with `run_mode = 0` (disabled pending Block 2 validation), `execution_mode = FIRE_AND_FORGET`, `interval_seconds = 300`, `timeout_seconds = 600`, `dependency_group = 10`

**What's next:** Block 2 (execution tracking) — see Next Starting Point above.

The Phase 2 investigation work is complete as documented in `B2B_ArchitectureOverview.md`. The direct reading of Sterling's BPML workflow definitions and the Integration database's stored procedures has resolved the architectural questions that were previously open. Answers from Melissa (File Processing Supervisor) have been folded into the Open Questions section.

### Key Architectural Conclusions from Investigation

These shape the build direction. Full rationale and detail in `B2B_ArchitectureOverview.md`.

**b2bi is the authoritative source of truth for execution.** Sterling's operational database on FA-INT-DBP records everything that happens at the workflow instance level. Integration's coordination tables (BATCH_STATUS, TICKETS) are a convenience layer populated by Sterling's BPMLs — valuable for enrichment and human-readable context, but not a reliable source on their own because they only get written when workflows successfully cooperate. Infrastructure-level failures (JVM crash, network partition) leave Integration blind while b2bi captures the event.

**`FA_CLIENTS_MAIN` is the universal unit of work.** Every meaningful Sterling workflow run is driven by MAIN (WFD_ID 798). MAIN's BPML (version 48) is a single linear sequence with ~22 conditional rules gating sub-workflow invocations. Different process configurations trigger different combinations of rules — they are not structurally distinct "paths."

**`FA_CLIENTS_GET_LIST` is the universal dispatcher.** Its BPML (version 19) and its backing stored procedure (`USP_B2B_CLIENTS_GET_LIST`) serve two dispatch modes:
- **Branch 1** (scheduler-fired, AUTOMATED=1): handles hourly dispatch of configured processes, filtered by `RUN_FLAG=1`
- **Branch 2** (wrapper-triggered, AUTOMATED=2): handles entity-specific dispatchers with CLIENT_ID + PROCESS_TYPE or SEQ_IDS filters

**Four dispatch patterns, not five.** Direct Named Workflow, Scheduler-Fired GET_LIST, Periodic Internal Operation Scanner, and Entity-Triggered GET_LIST wrapper. What earlier revisions called "Pattern 5 Parallel Phased Workers" is Pattern 4 with `SEQUENTIAL=1` and explicit `SEQ_IDS`.

**MAIN processes a single Client per run.** MAIN's BPML references `//Result/Client[1]/...` throughout. Each MAIN invocation gets single-Client ProcessData. No multi-Client grain explosion.

**PREV_SEQ is declaratively enforced.** MAIN's `Wait?` and `Continue?` rules implement a polling loop against BATCH_STATUS for the PREV_SEQ-referenced predecessor. When a dependency has BATCH_STATUS = -1 (failed), the dependent MAIN short-circuits.

**Credentials exist in ProcessData.** `PGP_PASSPHRASE` is per-Client; `PYTHON_KEY` is stored in `tbl_B2B_CLIENTS_SETTINGS` and flows into every MAIN run's ProcessData via the Settings/Values node. Since these credentials already exist in plaintext in Integration's tables and in Sterling's own configuration — all under the same backup/DR scope as xFACts — capturing them in xFACts does not meaningfully expand exposure. They will be stored raw; redaction (if needed) happens at the UI layer.

**ETL_CALL is deprecated / unused.** Confirmed with File Processing Supervisor — no `CLIENTS_PARAM` rows have `ETL_PATH` populated. ETL_CALL is excluded from the v1 collector scope. The v1 collector targets `FA_CLIENTS_MAIN` runs only. If ETL_CALL ever gets revived, we add handling then.

---

## Lessons Learned — Investigation History

This section exists to capture the reasoning behind course corrections, so a future session doesn't re-litigate settled decisions.

### Integration Mirror Tables — Attempted, Abandoned

An earlier plan attempted to mirror Integration configuration tables (`CLIENTS_MN`, `CLIENTS_FILES`, `CLIENTS_PARAM`, `SETTINGS`) into local `INT_*` tables for queryable reference. A table called `B2B.INT_ClientRegistry` was briefly built and populated. This direction was abandoned:

- The config data is already live on the AG (in the Integration database) and can be live-joined during collector cycles
- Mirroring creates a sync burden with no offsetting benefit given the AG already has the data available at low-latency
- UI-layer perf concerns (if any arise in Phase 5) are a future optimization, not a present requirement
- Every additional table is a maintenance surface we didn't need

**Current direction:** xFACts B2B tables are `SI_*` only (data sourced from b2bi on FA-INT-DBP). Integration-side data is consulted via live join from the collector when needed for enrichment. This keeps the module focused on its core mandate: monitoring Sterling's execution layer.

### Phase 1 Tables — Planned but Retired

Earlier revisions of this document described three Phase 1 tables (`SI_WorkflowTracking`, `SI_ProcessBaseline`, `INT_ClientRegistry`) and two Phase 1 collectors (`Collect-B2BWorkflow.ps1`, `Sync-B2BConfig.ps1`) as "built and deployed." **None of them currently exist.** They were attempted before the architectural breakthrough from reading the BPMLs and SPs; once the b2bi-authoritative model emerged, their design was superseded and the attempted artifacts were dropped. The current build starts fresh from the architectural conclusions above.

### Architectural Breakthrough — BPML and SP Reads

The pivot from "Integration is primary" to "b2bi is primary, Integration is enrichment" came from direct reads of Sterling BPML workflow definitions and Integration stored procedures. This is the foundation of everything in the current docs. BPMLs read: MAIN v48, GET_LIST v19, GET_DOCS v37, ETL_CALL v1, plus four dispatcher wrappers. SPs read: `USP_B2B_CLIENTS_GET_LIST`, `USP_B2B_CLIENTS_GET_SETTINGS`. The "Current Understanding" section above and the Architecture doc's detail sections are products of this work.

---

## Schema and Naming Conventions

### Table Prefix Convention

- **`SI_`** — Data sourced from b2bi (**S**terling **I**ntegrator) database on FA-INT-DBP — **this is the only prefix in use.**

(An `INT_` prefix was reserved for Integration-mirror tables in an earlier plan; that approach has been dropped — see Lessons Learned above. No `INT_` tables are currently planned.)

### Entity Terminology

"Entity" (rather than "Client") is used for configured Sterling targets because those targets include real customers, vendors, and internal services — "Entity" is more accurate across the full population.

### Module Registration

- **Module_Registry:** B2B — "IBM Sterling B2B Integrator file transfer and ETL processing monitoring"
- **Component_Registry:** B2B (single component — same pattern as BatchOps, BIDATA, FileOps)
- **System_Metadata:** version 1.0.0 on initial build

These registry entries are in place as of the Block 1 deployment (April 22, 2026).

---

## Table Inventory

Planned tables supporting the B2B module. Column-level design is captured in `B2B_ArchitectureOverview.md` under "Execution Tracking Design." This inventory is a status view only.

| Table | Status | Purpose |
|-------|--------|---------|
| `dbo.ClientHierarchy` | ✅ Built (shared) | Flattened DM creditor hierarchy for crosswalk and grouping — shared infrastructure |
| `B2B.SI_ScheduleRegistry` | ✅ Built (Phase 3 Block 1) | b2bi SCHEDULE mirror with parsed TIMINGXML timing data — flat grain (one row per schedule). 604 rows as of April 22, 2026. |
| `B2B.SI_ExecutionTracking` | To design (Phase 3 Block 2) | Per-execution tracking — one row per `FA_CLIENTS_MAIN` WORKFLOW_ID. Includes parsed ProcessData fields AND the raw ProcessData XML stored on the same row for forensic drill-down. Includes merged-output filename column to support future lifecycle bridging, plus a `has_detail_captured` bit to support future incremental backfill of detail data. |
| `B2B.SI_ExecutionDetail` | Planned (future — Phase 3 Block 3 / Phase 4) | Middle-grain per-execution detail — file-level information with summary totals. Supports file lifecycle bridging between File Monitoring and Batch Monitoring. Grain and column design deferred until process-type investigation matures across more than NB. See Open Design Questions for extraction-target notes. |

**Design principle:** as few scripts and tables as possible. One collector script handles all B2B collection (schedule sync + execution tracking + enrichment). No separate ProcessData cache table — raw XML is a column on `SI_ExecutionTracking`. When `SI_ExecutionDetail` is eventually built, it will also be populated by the same collector (as a toggleable pipeline step).

---

## Phase Plan

### Phase 1 — Schema Foundation ✅ Complete

The `B2B` schema is registered. `dbo.ClientHierarchy` is built (shared infrastructure). Nothing else B2B-specific exists yet.

### Phase 2 — Investigation ✅ Complete

**Goal:** Understand Sterling's operational model well enough to design the execution tracking schema with confidence.

**Work completed:**
- `FA_CLIENTS_MAIN` BPML read end-to-end (v48)
- `FA_CLIENTS_GET_LIST` BPML read end-to-end (v19)
- `FA_CLIENTS_GET_DOCS` BPML read end-to-end (v37)
- `FA_CLIENTS_ETL_CALL` BPML read end-to-end (v1) — confirmed deprecated
- Four dispatcher wrapper BPMLs read (ACADIA EO, ACCRETIVE, COACHELLA VALLEY, MONUMENT)
- `USP_B2B_CLIENTS_GET_LIST` and `USP_B2B_CLIENTS_GET_SETTINGS` stored procedures read and analyzed
- Dispatcher model unified (Patterns 2 and 5 merged into Pattern 4 parameterization)
- Integration coordination layer characterized (BATCH_STATUS, TICKETS, SETTINGS, BATCH_FILES, FTP_FILES_LIST)
- Source of truth stance committed (b2bi primary, Integration enrichment, disagreement as alert)
- Grain question resolved (one row per MAIN WORKFLOW_ID)
- PREV_SEQ / AUTOMATED / RUN_FLAG / SEQUENTIAL semantics resolved
- FILE_DELETION implementation resolved (ZeroSize? rule in GET_DOCS)
- ETL_CALL subsystem characterized (Pervasive Cosmos 9 macro executor — confirmed deprecated)

**Remaining Phase 2 items (not blocking Phase 3 Block 1 / Block 2 start):**
- Individual process-type anatomies (now treated as discovery-as-needed, no longer blocking for Blocks 1/2)
- `FA_FILE_CHECK.java` source read (nice-to-have)
- Translation map `FA_CLIENTS_BATCH_FILES_X2S` analysis (nice-to-have)
- **Identifying the "skinny" Translation output row pattern for detail extraction** (prerequisite for Block 3 `SI_ExecutionDetail` build)

### Phase 3 — Backend Build (IN PROGRESS)

**Prerequisite:** Phase 2 complete (the case).

**Build sequence:**

**Block 1 — `SI_ScheduleRegistry` ✅ Complete (April 22, 2026).** Small, low-risk, uses the validated TIMINGXML decompression pattern. Gives us a reference table for "what schedules exist" and "when are they supposed to fire" — will feed into Phase 4 schedule-adherence monitoring. Delivered:
- `B2B.SI_ScheduleRegistry` table (25 columns, 604 rows)
- `Collect-B2BExecution.ps1` with schedule sync implemented; execution-tracking steps stubbed
- TIMINGXML parser handles all 73 observed distinct patterns with zero errors
- Single JOIN query pulls all schedules with their compressed TIMINGXML blobs in one round trip
- Object_Registry + Object_Metadata baseline entries for the collector
- Orchestrator.ProcessRegistry entry (disabled pending Block 2 validation)
- Full collector runtime: <5 seconds; idle cycles report 0 inserts/updates/deletes

**Block 2 — `SI_ExecutionTracking` + the collector (NEXT).** Column design per `B2B_ArchitectureOverview.md` — "Execution Tracking Design" section. "Collect everything possible up front" principle applies: every known ProcessData field parsed into its own column, plus the raw ProcessData XML stored on the same row for forensic drill-down and future-proofing against fields we haven't seen yet. Also includes forward-looking columns (`merged_output_file_name`, a `has_detail_captured` bit, etc.) to support Block 3 without requiring retrofit. Design includes an `is_complete` flag enabling cheap lookback-window queries by excluding already-terminal rows — per-cycle workload scales with "new + in-flight" count, not total lookback volume.

**One collector handles Blocks 1 and 2.** `Collect-B2BExecution.ps1` performs (Block 1 steps implemented; Block 2 steps stubbed and next to build):
1. Schedule sync — query b2bi.SCHEDULE, MERGE changes into `SI_ScheduleRegistry`. Cheap; runs every cycle. **(Block 1 — implemented.)**
2. b2bi primary poll — WF_INST_S for new `FA_CLIENTS_MAIN` runs since high-water mark (with a 3-day lookback window on every cycle to absorb collection gaps within b2bi's retention). Anti-join against `SI_ExecutionTracking WHERE is_complete = 0` to identify new or in-flight runs.
3. b2bi enrichment per captured run — WORKFLOW_LINKAGE, WORKFLOW_CONTEXT analysis, ProcessData decompress + parse
4. Integration bulk-join enrichment — BATCH_STATUS and TICKETS in batched queries, hash-joined in PowerShell memory (no linked server between FA-INT-DBP and AVG-PROD-LSNR)
5. Compute disagreement flags (`int_status_missing`, `int_status_inconsistent`, `alert_infrastructure_failure`)
6. MERGE into `SI_ExecutionTracking`; flip `is_complete = 1` when terminal state reached in both sources
7. Advance high-water mark

**One-time historical backfill:** after the collector is validated in production, a one-time backfill run will pull whatever history is still available against Integration tables (BATCH_STATUS, TICKETS) for runs that have already been purged from b2bi but still have Integration traces. This is expected to be partial — b2bi's aggressive purging (~2-3 day retention) means most history is already gone — but every row we recover is value.

**Block 3 — `SI_ExecutionDetail` (future, deferred).** Middle-grain detail table capturing per-file and per-creditor-within-file information. Design and build deferred until `SI_ExecutionTracking` is proven in production AND the "skinny" Translation output pattern has been identified across more than just NB. The same `Collect-B2BExecution.ps1` script will gain a toggleable detail-extraction pipeline step when Block 3 activates. Block 2's `SI_ExecutionTracking` design includes forward-looking columns to support this future work without requiring retrofit.

**Run frequency:** every 5 minutes under the orchestrator once Block 2 is validated. Block 1 is currently registered at that cadence but held disabled pending Block 2 build-out.

### Phase 4 — Monitoring and Alerting

**Prerequisite:** Phase 3 Block 2 complete; at least 2-4 weeks of data accumulated. Block 3 may happen before, during, or after Phase 4 depending on how process-type investigation progresses.

- Build `Monitor-B2B.ps1` — detects failures, missing scheduled runs, anomalies
- Define alert thresholds in collaboration with Apps team and File Processing Supervisor
- Integrate with Teams and Jira
- Pilot-run alerting before broad enablement

### Phase 5 — Control Center UI

**Prerequisite:** Phase 4 data model stable. End-to-end lifecycle page requires Block 3 complete.

- B2B Monitoring Control Center page (route, API, CSS, JS)
- Process status overview, failure feed, missing process alerts, schedule adherence
- Entity-grouped views with ClientHierarchy resolution
- Drill-down from summary to individual workflow runs with ProcessData detail
- ProcessData display redacts sensitive fields (PGP_PASSPHRASE, PYTHON_KEY) at the UI layer — storage remains raw for forensic purposes
- **File lifecycle page** (depends on Block 3 being in place AND File Monitoring / Batch Monitoring data being queryable) — bridges the three modules into a single end-to-end view

**Future / post-MVP:** volume and duration anomaly detection; DM batch correlation; trend analysis; automatic baseline drift detection; possible targeted mirroring of Integration tables if live-join performance becomes a UI bottleneck.

---

## Process Anatomy Progress Tracker

Mirrors the investigation inventory in `B2B_ArchitectureOverview.md`.

**Legend:** ✅ Fully traced · ⚠️ Partially characterized · ❌ Not yet traced

| # | PROCESS_TYPE | COMM_METHOD | Status | Anatomy Doc |
|--:|---|---|---|---|
| 1 | NEW_BUSINESS | INBOUND | ✅ (standard) / ⚠️ (PGP variant) | `B2B_ProcessAnatomy_NewBusiness.md`; PGP variant needs separate coverage |
| 2 | FILE_DELETION | INBOUND | ⚠️ | Planned. Removes files from Joker SFTP server for clients that submit un-needed files; files remain in ftpbackup. |
| 3 | SPECIAL_PROCESS | INBOUND | ⚠️ | Planned. Catch-all for non-standard process types. |
| 4 | ENCOUNTER | INBOUND | ⚠️ | Planned |
| 5 | PAYMENT | INBOUND | ⚠️ | Planned (needs re-verification + multi-client modes) |
| 6 | NOTES | OUTBOUND | ⚠️ | Planned (needs re-verification) |
| 7 | SFTP_PULL | INBOUND | ⚠️ | Dispatcher side understood; MAIN-side anatomy still to trace |
| 8 | SFTP_PULL | OUTBOUND | ⚠️ | Characterized via dispatcher wrappers; MAIN-side anatomy still to trace |
| 9-30 | Remaining types | Various | ❌ | See architecture doc Process Type Investigation Status table |

**Progress: 1 fully traced (NB standard), 7 partially characterized. 23 untraced.**

With Phase 2 substantially complete, further process-type anatomies become "nice to have as they arise" rather than "required before building" for Blocks 1/2. They can happen alongside Phase 3 / Phase 4 work as specific process types warrant attention. The "collect everything" principle in the collector design means new process types won't break collection when they're first seen — they'll just show up with their fields captured and their `run_class` classification available for review.

**Anatomy-level investigation takes on new importance for Block 3.** Identifying the "skinny" Translation output row pattern (see Open Investigation Items) requires process-type-specific investigation because each process type may structure its Translation outputs differently. Expect per-process-type investigation to feed directly into `SI_ExecutionDetail` design.

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

Answers received from File Processing Supervisor (Melissa) have been folded in; remaining items below. Additional answers may arrive from Melissa on further items she's still researching.

| # | Question | Status |
|--:|---|---|
| 1 | FILE_DELETION lifecycle | ✅ Resolved. Removes files from Joker SFTP server without processing; files remain in ftpbackup. Picked up via GET_LIST, deleted from Joker. |
| 2 | ACADIA EO pipeline coordination | ✅ Resolved (BATCH_STATUS + PREV_SEQ + GET_LIST SEQUENTIAL) |
| 3 | `PREV_SEQ` semantics | ✅ Resolved (declaratively enforced via BATCH_STATUS polling) |
| 4 | `AUTOMATED` field values | ✅ Resolved. AUTOMATED=1 → uses GET_LIST business process to pick up files; GET_LIST runs 5:05am–3:05pm M–F every 1 hour. AUTOMATED=2 → scheduled business process fires directly at specific scheduled times. |
| 5 | `RUN_FLAG` field | ✅ Resolved. Used only for AUTOMATED=1 processes. When RUN_FLAG=1 AND AUTOMATED=1, the files get picked up and processed when GET_LIST kicks off at :05 past the hour. |
| 6 | `FA_CLIENTS_GET_LIST` dispatcher | ✅ Resolved. AUTOMATED=1 for the GET_LIST path; AUTOMATED=2 for the Scheduler path. |
| 7 | `SPECIAL_PROCESS` usage convention | ✅ Resolved. Catch-all for process configurations that "don't fit the standard process types." |
| 8 | External Python executable inventory | Partial. Known: FA_FILE_REMOVE_SPECIAL_CHARACTERS, FA_MERGE_PLACEMENT_FILES, per-Client GET_DOCS_API exes. Full inventory would help maintenance scoping. |
| 9 | FILE_DELETION scope | ✅ Resolved. Only clients that submit un-needed files have a FILE_DELETION process configured. |
| 10 | Internal CLIENT_IDs inventory | Still building list (known: 328 = INTEGRATION TOOLS) |
| 11 | Other Integration tables of interest | BATCH_FILES added; potentially more still |
| 12 | Legacy naming (CLA, PV) | CLA confirmed "Command Line Adapter"; PV meaning still open |
| 13 | Sterling SCHEDULE table authority | ✅ Resolved. Sterling's own SCHEDULE table defines these schedules. |
| 14 | ACADIA SEQ_ID 9 mystery | ✅ Resolved. Appears misconfigured — likely development work started but never completed or was added incorrectly. |
| 15 | FA_PAYGROUND naming | Still open |
| 16 | Process type definitions for less-common types | Still mostly open (NCOA, ITS, ACKNOWLEDGMENT, CORE_PROCESS, EMAIL_SCRUB, FULL_INVENTORY, BDL vs STANDARD_BDL, REMIT, FILE_EMAIL, NOTES_EMAIL, NOTE vs NOTES) |
| 17 | `FA_CLIENTS_ETL_CALL` role | ✅ Resolved. Pervasive Cosmos macro executor. **Confirmed deprecated** — no CLIENTS_PARAM rows with ETL_PATH populated. Excluded from v1 collector scope. |
| 18 | Known infrastructure-failure cases | Examples of "failed in b2bi, not in Integration" cases to validate alert logic |
| 19 | `MARCOS_PATH` filesystem location | Moot — ETL_CALL deprecated |
| 20 | `FA_FILE_CHECK.java` purpose | Java utility on Sterling app server (E:\Utilities\) invoked by GET_DOCS — what does it validate? |
| 21 | Translation map `FA_CLIENTS_BATCH_FILES_X2S` | Purpose and output of the map GET_DOCS invokes post-loop for non-SFTP_PULL processes? |

---

## Open Design Questions (Blocking Build)

| # | Question | Resolution Path |
|--:|---|---|
| 1 | ~~`SI_ExecutionTracking` grain~~ | ✅ Resolved — one row per MAIN WORKFLOW_ID |
| 2 | ~~Phase 1 `SI_WorkflowTracking` relationship to new `SI_ExecutionTracking`~~ | ✅ Moot — SI_WorkflowTracking no longer exists (was never permanently built). Building `SI_ExecutionTracking` from scratch. |
| 3 | ~~ProcessData credential handling~~ | ✅ Resolved. Captured raw in `SI_ExecutionTracking.process_data_xml` column. Credentials already exist in plaintext in Integration and Sterling configuration — capturing in xFACts doesn't meaningfully expand exposure. Redaction happens at the UI layer in Phase 5, not at storage. |
| 4 | ~~Whether to persist ProcessData indefinitely or age out~~ | ✅ Resolved for initial build. Persist indefinitely alongside execution row; revisit only if storage observations warrant it (~40GB estimate at 3-year retention is acceptable). |
| 5 | Whether record-count summaries from Translation outputs are worth a separate table | Deferred into Block 3 — `SI_ExecutionDetail` is the home for this. |
| 6 | ~~How to represent empty / polling / skeleton MAIN runs~~ | ✅ Resolved — collector captures sub-workflow invocation counts + run_class classification; short-circuit runs are identifiable by absence of sub-workflow invocations after GET_DOCS |
| 7 | Integration enrichment approach | ✅ Resolved. Live-join in collector via PowerShell in-memory hash join. No mirror tables. No linked server (none exists between FA-INT-DBP and AVG-PROD-LSNR). |
| 8 | `SI_ExecutionDetail` grain, columns, and extraction target | **Deferred — does not block Block 1 or Block 2.** Depends on process-type anatomy investigation across more than NB. Working model for extraction: among the multiple Translation output documents per MAIN run (observed: ~12 DOCUMENT rows in TRANS_DATA per execution; 3-4 of those are XML outputs containing different segments of import data), target the **"skinny" output** — characterized by a file-name header followed by individual account rows with balance and intended creditor keys — as opposed to the denser demographic XML outputs. The identification of which specific TRANS_DATA row in the sequence consistently produces this format across process types is itself part of the investigation. Single merged-output-file filename captured on `SI_ExecutionTracking` row, not duplicated in detail table. |

---

## Open Investigation Items (Non-Blocking)

Items that would improve understanding but don't block the Block 1 / Block 2 build directly.

- **Which TRANS_DATA output row(s) consistently contain the "skinny" per-file account-with-creditor summary across process types** — characterized by file-name header followed by individual account numbers with balance and intended creditor keys. Observed in one inspected NB run as one of 3-4 XML outputs (out of ~12 DOCUMENT rows total). Identifying this reliably across process types is the prerequisite for building `SI_ExecutionDetail` (Phase 3 Block 3).
- `E:\Utilities\FA_FILE_CHECK.java` source read — what does this validate during GET_DOCS SFTP flow?
- Translation map `FA_CLIENTS_BATCH_FILES_X2S` — what does GET_DOCS translate at the end of the file loop?
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

## Infrastructure Reference

### Server / Database Topology

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
| SFTP Server | "Joker" — FAC's SFTP endpoint. FILE_DELETION process removes files from here; deleted files remain in ftpbackup. |

**Important:** b2bi database uses case-sensitive collation. String comparisons must use exact case (e.g., `STATUS = 'ACTIVE'` not `'Active'`).

**Cross-server consideration:** b2bi (on FA-INT-DBP) and Integration (on AVG-PROD-LSNR) are on separate servers with no linked server connectivity. Cross-database joins are not possible in SQL. Where data from both environments is needed, this is handled in the xFACts collector scripts via separate queries joined in PowerShell memory.

### Operational Pain Points (What the Module Addresses)

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
| No file lifecycle visibility | No single view of a file's path from client submission through DM batch loading — stitching this together across File Monitoring, B2B, and Batch Monitoring is the secondary goal of the module |

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Purpose | Top-level roadmap for the xFACts B2B module |
| Author | Applications Team (Dirk + xFACts Claude collaboration) |
| Created | January 13, 2026 |
| Last Updated | April 22, 2026 |
| Status | Active — Phase 3 Block 1 (Schedule Registry) complete; Block 2 (Execution Tracking) next |
| Schema | B2B |

### Revision History

| Date | Revision |
|------|----------|
| January 13, 2026 | Initial document created |
| April 16, 2026 | Phase 1 foundation marked complete (since reverted — see Lessons Learned) |
| April 17-18, 2026 | Deep investigation of b2bi internals |
| April 18, 2026 | Architecture shifted from hybrid to pure-b2bi |
| April 20, 2026 (revs 1-6) | Major rewrites capturing BPML/SP read findings; dispatcher model unified; grain resolved; Phase 3 build path formalized |
| April 21, 2026 | Off-course build session (artifacts created and subsequently dropped) |
| April 22, 2026 (rev 7) | **Reset and realignment revision.** (1) Phase 1 "built and deployed" claims retracted — those tables and scripts don't exist; moved to Lessons Learned. (2) All `INT_*` mirror tables removed from scope — direction changed to live-join from collector; documented in Lessons Learned. (3) Melissa's File Processing Supervisor answers folded in — 10 open questions resolved or clarified (GET_LIST schedule window specifics, AUTOMATED/RUN_FLAG operational detail, FILE_DELETION scope on "Joker" SFTP server, SPECIAL_PROCESS as catch-all, ACADIA SEQ_ID 9 as misconfigured development work, Sterling SCHEDULE table authority confirmed). (4) ETL_CALL confirmed deprecated; excluded from v1 collector scope. (5) "Collect everything possible up front" build principle captured explicitly. (6) ProcessData credential handling resolved — raw XML captured in `SI_ExecutionTracking`, redaction deferred to UI layer. (7) Table inventory reshaped to three tables (`SI_ScheduleRegistry`, `SI_ExecutionTracking`, `SI_ExecutionDetail`) — no separate ProcessData cache, no INT mirrors. (8) Phase 3 build sequence: Schedule registry first as warm-up, then execution tracking + collector; `SI_ExecutionDetail` added as Block 3 (future, deferred). (9) Single-collector design confirmed (`Collect-B2BExecution.ps1` handles schedule sync + execution collection together; will gain toggleable detail-extraction step when Block 3 activates). (10) 3-day lookback every cycle + one-time historical Integration backfill documented. (11) "Joker" SFTP server added to infrastructure reference. (12) **Secondary goal of file lifecycle bridging** (File Monitoring → B2B → Batch Monitoring) added to Executive Summary. (13) `SI_ExecutionDetail` added to Table Inventory as Phase 3 Block 3 / Phase 4 item with "skinny Translation output" extraction breadcrumb. (14) Forward-looking columns on `SI_ExecutionTracking` noted (merged_output_file_name, has_detail_captured) to prevent retrofit when Block 3 activates. (15) New Open Investigation Item added: identifying the "skinny" Translation output row pattern across process types. |
| April 22, 2026 (rev 8) | **Phase 3 Block 1 (Schedule Registry) complete.** (1) Added "Next Starting Point" section near the top with the concrete 4-step sequence for Block 2. (2) Current State section updated — `SI_ScheduleRegistry` built and populated (604 schedules), `Collect-B2BExecution.ps1` deployed with schedule sync implemented and execution tracking stubbed, registry entries in place, Orchestrator.ProcessRegistry entry registered (disabled pending Block 2). (3) Module Registration note updated — entries are in place rather than to be created. (4) Table Inventory — `SI_ScheduleRegistry` flipped from "To design" to "✅ Built" with population stats. (5) Phase 2 header updated from "Substantially Complete" to "Complete." (6) Phase 3 section — Block 1 flipped to "✅ Complete (April 22, 2026)" with delivery details; Block 2 marked as "NEXT" with the `is_complete` lookback optimization principle added; collector flow steps annotated as "(Block 1 — implemented)" vs. "to build" to reflect current state. (7) Document Status updated to reflect Phase 3 Block 1 complete, Block 2 next. |

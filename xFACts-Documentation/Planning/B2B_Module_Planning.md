# B2B Module Planning Document

## Purpose

Planning and direction document for the xFACts B2B monitoring module. Captures current architectural direction, phase plan, in-progress design work, and open questions that the build process will resolve.

This is a **working reference document**, not a permanent artifact. It will be discarded once the module is running in production and its content is superseded by Object_Metadata, Object_Registry entries, and help-page content in Control Center.

Companion documents:
- **`B2B_ArchitectureOverview.md`** — architectural reference grounded in BPML reads, stored procedure analysis, and live b2bi / Integration database investigation
- **`B2B_ProcessAnatomy_*.md`** — one per process type (currently only `B2B_ProcessAnatomy_NewBusiness.md` exists)
- **`B2B_Reference_Queries.md`** — investigation queries and snippets

---

## Executive Summary

The xFACts B2B module monitors IBM Sterling B2B Integrator. It is one part of a broader lifecycle-monitoring ambition:

- **FileOps module** — captures files landing at FAC (before Sterling)
- **B2B module** (this one) — captures execution of Sterling workflows that process those files
- **BatchOps module** — captures DM file submissions produced by Sterling

**Downstream ambition: full file-lifecycle tracking across all three modules.** A file that lands on Joker (captured by FileOps) → is picked up by Sterling and processed (captured by B2B) → produces a DM submission (captured by BatchOps). Today, these modules track their own slices independently. The secondary goal of the B2B module, once it's standing, is to provide the correlation keys and output identifiers that stitch the three slices together into one narrative per file.

This lifecycle framing informs the detail-table design — filenames and creditor-key breakdowns are captured at the B2B layer specifically because they are the join points to FileOps (filename) and BatchOps (output filename, DM creditor).

## Architectural Direction

**b2bi is the authoritative source of truth for execution.** The xFACts collector reads execution primarily from `b2bi.dbo.WF_INST_S` and its related tables. Integration database tables are **live-joined at collection time for enrichment only** — never mirrored into xFACts. This direction was formalized in the architecture doc rev 10 and is reflected throughout this plan.

**Disagreement between b2bi and Integration is the core alert signal.** If b2bi says a workflow failed and Integration has no corresponding record (BATCH_STATUS missing, TICKETS row absent), that is evidence of Sterling crashing before its onFault handler could report — an infrastructure-level failure class that was previously invisible. The disagreement flags on `SI_ExecutionTracking` turn these historically silent failures into named alerts.

**No Integration table mirrors exist in the B2B schema.** `CLIENTS_MN`, `CLIENTS_FILES`, `CLIENTS_PARAM`, `SETTINGS`, `BATCH_STATUS`, `TICKETS`, `BATCH_FILES`, `FTP_FILES_LIST` — all are queried live when needed. The prior discarded-Phase-1 `INT_*` tables have been dropped; their concept was sound for reference data but the ongoing sync burden wasn't justified given Integration is on the same AG and reachable at low cost.

---

## Historical Context — Scrapped Phase 1

Three tables were briefly scaffolded during an earlier planning session under the assumption that Integration-side tables would be mirrored into xFACts and that Sterling's `FA_CLIENTS_MAIN` had polymorphic execution paths per `PROCESS_TYPE`. Both assumptions turned out to be wrong once we read the BPMLs directly:

- **`B2B.INT_ClientRegistry`** — empty Entity mirror table. Dropped.
- **`B2B.SI_ProcessBaseline`** — table keyed on `PROCESS_TYPE` for per-path baselines. Invalidated once we learned MAIN is a single linear sequence with conditional rules, not distinct paths.
- **`B2B.SI_WorkflowTracking`** — placeholder for execution tracking, designed before we understood the ProcessData / WORKFLOW_CONTEXT / Integration coordination layer.

All three were empty, are now dropped, and their Object_Registry / Object_Metadata entries have been removed. This is preserved as a cautionary note: **do not design database objects before the architectural investigation is complete.** The session-by-session discoveries since then (BPML reads, Integration SP reads, WORKFLOW_CONTEXT inline marker mechanism, ETL_CALL deprecation, etc.) have collectively reshaped the design. The final shape bears no resemblance to those early scaffolds.

---

## Phase Plan

| Phase | Status | Description |
|---|---|---|
| 0 — Investigation | ✅ Substantially complete | Architecture doc grounded in BPML reads and SP analysis. Most key mechanisms resolved. A handful of items remain open but are not blockers. |
| 1 — Schedule Inventory | Design pending | `SI_ScheduleRegistry` — mirrors Sterling's own `b2bi.dbo.SCHEDULE` table. Intentionally simple; mostly reference data with some deviations flagged. |
| 2 — Execution Tracking (Header) | **Design locked — DDL build pending** | `SI_ExecutionTracking` — 93 columns, one row per MAIN run. Full column list documented below under "SI_ExecutionTracking Design." |
| 3 — Execution Tracking (Detail) | Design direction set; validation pending | `SI_FileDetail` and `SI_CreditorBreakdown` — two detail tables at "between summary and detail" grain. Architecture-level design captured below; final column commitments deferred until decompression probe confirms filename and creditor-key extractability. |
| 4 — Collector | Not started | `Collect-B2BExecution.ps1` populates header + detail, runs on cycle. |
| 5 — ProcessData Cache | Deferred | `SI_ProcessDataCache` — blocked on credential-handling decision. Core collector operates independently of it. |
| 6 — UI | Not started | Control Center pages for browsing / drilling down / alerting. |
| 7+ — Cross-module correlation | Not started | Join to FileOps upstream and BatchOps downstream. Requires BatchOps' own design to be further along than it currently is. |

**Current focus:** Phase 2 DDL generation (next session). Phase 3 detail-table validation (next session as well, if time permits).

---

## SI_ExecutionTracking Design

**Design status:** Locked as of 2026-04-21 session. 93 columns across 12 blocks. Grain is one row per `FA_CLIENTS_MAIN` WORKFLOW_ID. ETL_CALL is excluded from scope (confirmed deprecated — see below).

Physical design (data types, indexes, PK, constraints) has not yet been drafted. That is the next session's first deliverable alongside DDL generation.

### Scoping decisions

- **MAIN-only.** `FA_CLIENTS_ETL_CALL` is deprecated. Confirmed via two queries: no rows in `Integration.etl.tbl_B2b_CLIENTS_PARAM` where `PARAMETER_NAME = 'ETL_PATH'`, and zero recent executions of `FA_CLIENTS_ETL_CALL` in the b2bi 48-hour window. FAC migrated off Pervasive Cosmos / Actian DataConnect, which was the legacy ETL platform ETL_CALL fronted. The workflow and its infrastructure survive as dead code. The architecture doc retains its characterization for historical knowledge; the collector filters `WFD.NAME = 'FA_CLIENTS_MAIN'` only. If ETL_CALL is ever reactivated, a `workflow_class` column and ETL_CALL-specific handling can be added non-destructively.
- **Comprehensive by design.** The 48-hour collection window for discovery is narrow. Quarterly, semi-annual, or rarely-triggered sub-workflows will surface later. Columns are included for every theoretically possible sub-workflow and ProcessData field the architecture doc identifies, not only for those observed in the sample. Unused columns sit NULL at trivial storage cost; missing columns would require ALTER TABLE on a growing table after the fact.
- **Three detection paths for sub-workflow activity.** Empirical result from the discovery phase:
  - **Inline markers** — `WORKFLOW_CONTEXT.ADV_STATUS LIKE ' Inline Begin FA_CLIENTS_%'` (note leading space — critical). Detects inline sub-workflow invocations that don't create child workflows.
  - **Async child linkage** — `WORKFLOW_LINKAGE.P_WF_ID = main_wfid`. Detects ASYNC sub-workflow children.
  - **Base service steps** — `WORKFLOW_CONTEXT.SERVICE_NAME IN ('SFTPClientGet', 'SFTPClientPut', ...)`. Detects Sterling-native services used directly by MAIN without a FA_CLIENTS_* wrapper.
- **Integration enrichment, not mirroring.** `BATCH_STATUS`, `TICKETS`, `CLIENTS_MN` are live-joined at collection time. Results populate derived columns (rollup flags, stamped fields) without persisting raw Integration data.

### Discovery validation — what informed the design

The discovery queries run during this session (2026-04-21) produced the following empirical ground truth over a 48-hour window of 2358 MAIN runs:

**Inline sub-workflow activity** (via ADV_STATUS markers):

| Sub-workflow | % of MAIN runs | Avg invocations per run |
|---|---:|---:|
| `FA_CLIENTS_GET_DOCS` | 99.49% | 1.00 |
| `FA_CLIENTS_PREP_COMM_CALL` | 64.66% | 1.00 |
| `FA_CLIENTS_TRANS` | 38.35% | 4.17 |
| `FA_CLIENTS_ARCHIVE` (inline) | 36.65% | 4.04 |
| `FA_CLIENTS_PREP_SOURCE` | 34.24% | 4.16 |
| `FA_CLIENTS_COMM_CALL` | 30.17% | 1.00 |
| `FA_CLIENTS_POST_TRANSLATION` | 16.78% | 1.00 |
| `FA_CLIENTS_FILE_MERGE` | 8.18% | 4.20 |
| `FA_CLIENTS_ACCOUNTS_LOAD` | 5.81% | 4.58 |
| `FA_CLIENTS_DUP_CHECK` | 5.64% | 1.00 |
| `FA_CLIENTS_WORKERS_COMP` | 5.34% | 1.00 |
| `FA_CLIENTS_ADDRESS_CHECK` | 2.20% | 1.00 |

**Async sub-workflow activity** (via WORKFLOW_LINKAGE):

| Sub-workflow | % of MAIN runs | Total invocations |
|---|---:|---:|
| `FA_CLIENTS_VITAL` | 47.33% | 4187 |
| `FA_CLIENTS_ARCHIVE` (async) | 40.20% | 4056 |
| `FA_CLIENTS_EMAIL` | 10.01% | 236 |
| `FA_CLIENTS_ENCOUNTER_LOAD` | 1.40% | 52 |
| `EmailOnError` | 1.15% | 27 |

Sub-workflows appearing in the architecture doc's rule catalog but not observed in the window — `FA_CLIENTS_TRANSLATION_STAGING`, `SaveDoc?` triggers, post-loop `FA_CLIENTS_VITAL` from `PostTranslationVITAL?` — are still represented in the design as comprehensive-design inclusions.

**Base-service activity** (via WORKFLOW_CONTEXT SERVICE_NAME, corrected for BASIC_STATUS=10 being normal SFTP status, not failure):

- SFTPClientGet — 951 runs, 3990 invocations
- SFTPClientPut — 308 runs, 1241 invocations
- SFTPClientDelete — 681 runs, 4899 invocations
- Translation (base) — 1488 runs, 5907 invocations
- AS3FSAdapter, AS2Extract, CommandLineAdapter2, FA_CLA_* — various

### Column list

All columns nullable unless noted. Physical types are initial proposals and will be confirmed in DDL generation.

#### Block 1 — Core execution identity (12 columns)

Source: `b2bi.dbo.WF_INST_S`

| Column | Proposed Type | Notes |
|---|---|---|
| `workflow_id` | `bigint NOT NULL` | Primary key. Sterling WORKFLOW_ID. |
| `workflow_def_id` | `int` | WFD_ID |
| `workflow_def_version` | `int` | WFD_VERSION |
| `workflow_name` | `varchar(200) NOT NULL` | Always `'FA_CLIENTS_MAIN'` in initial scope |
| `workflow_start_time` | `datetime2` | START_TIME |
| `workflow_end_time` | `datetime2` | END_TIME — NULL while in-flight |
| `duration_ms` | `int` | Computed and stored at write time (not a computed column) |
| `b2bi_basic_status` | `smallint` | BASIC_STATUS |
| `b2bi_adv_status` | `varchar(500)` | ADV_STATUS (truncated if source exceeds) |
| `b2bi_state` | `smallint` | STATE |
| `node_executed` | `varchar(100)` | NODEEXECUTED (single Sterling node at FAC currently, but captured) |
| `step_count` | `int` | `COUNT(*)` from WORKFLOW_CONTEXT for this workflow_id |

#### Block 2 — Workflow tree (4 columns)

Source: `b2bi.dbo.WORKFLOW_LINKAGE` joined back to `WF_INST_S` / `WFD` for name resolution.

| Column | Proposed Type | Notes |
|---|---|---|
| `parent_workflow_id` | `bigint` | P_WF_ID of linkage row where C_WF_ID = this workflow_id |
| `root_workflow_id` | `bigint` | ROOT_WF_ID — useful for pipeline rollup (e.g., ACADIA EO's 4 phases) |
| `root_workflow_name` | `varchar(200)` | Name of the root workflow — lets UI group MAIN runs by dispatcher |
| `linkage_type` | `varchar(20)` | LINKAGE.TYPE (typically `'Dispatch'`) |

#### Block 3 — Process identity from ProcessData (21 columns)

Source: decompressed ProcessData XML, `//Result/Client[1]/` fields.

| Column | Proposed Type | Notes |
|---|---|---|
| `client_id` | `int` | Sterling Entity identifier |
| `client_name` | `varchar(128)` | Stamped at collection; UI may live-join `tbl_B2B_CLIENTS_MN` for current-name display |
| `seq_id` | `int` | Process identifier within Entity |
| `process_type` | `varchar(50)` | NEW_BUSINESS, PAYMENT, FILE_DELETION, SPECIAL_PROCESS, etc. |
| `comm_method` | `varchar(20)` | INBOUND / OUTBOUND / empty |
| `business_type` | `varchar(50)` | From ProcessData when present |
| `translation_map` | `varchar(200)` | TRANSLATION_MAP |
| `post_translation_map` | `varchar(200)` | POST_TRANSLATION_MAP |
| `encounter_map` | `varchar(200)` | ENCOUNTER_MAP |
| `file_filter` | `varchar(200)` | FILE_FILTER pattern |
| `get_docs_type` | `varchar(20)` | SFTP_PULL / FSA_PULL / API_PULL — captured before GET_DOCS mutates API_PULL → FSA_PULL mid-workflow |
| `get_docs_loc` | `varchar(500)` | SFTP folder or FSA path |
| `put_docs_type` | `varchar(20)` | Outbound counterpart to get_docs_type |
| `put_docs_loc` | `varchar(500)` | Outbound path |
| `prev_seq` | `int` | Dependency chain predecessor SEQ_ID |
| `has_pgp_passphrase` | `bit` | True if `PGP_PASSPHRASE` in ProcessData was non-empty — signals PGP workflow attempted |
| `comm_call_exe_path` | `varchar(500)` | COMM_CALL_CLA_EXE_PATH (e.g., `FA_MERGE_PLACEMENT_FILES.exe` for ACADIA EO) |
| `get_docs_api` | `varchar(500)` | Python exe path for API_PULL |
| `misc_rec1` | `varchar(500)` | MISC_REC1 (pipe-delimited config for SPECIAL_PROCESS pipelines; API_PULL params) |
| `run_class` | `varchar(20)` | Derived: `FILE_PROCESS` / `INTERNAL_OP` / `UNCLASSIFIED` |

Note on the 21st column placement: `run_class` rounds out Block 3 because it's derived from process identity rather than from execution evidence.

#### Block 4 — Inline sub-workflow flags (13 columns)

Source: `WORKFLOW_CONTEXT.ADV_STATUS LIKE ' Inline Begin FA_CLIENTS_%'` markers (note leading space).

| Column | Proposed Type | Notes |
|---|---|---|
| `had_get_docs` | `bit` | 99.49% observed |
| `had_prep_source` | `bit` | 34.24% observed |
| `had_trans` | `bit` | 38.35% observed |
| `had_accounts_load` | `bit` | 5.81% observed — NB-specific |
| `had_dup_check` | `bit` | 5.64% observed |
| `had_workers_comp` | `bit` | 5.34% observed |
| `had_file_merge` | `bit` | 8.18% observed |
| `had_post_translation` | `bit` | 16.78% observed |
| `had_address_check` | `bit` | 2.20% observed |
| `had_prep_comm_call` | `bit` | 64.66% observed |
| `had_comm_call` | `bit` | 30.17% observed |
| `had_translation_staging` | `bit` | Not observed in window — comprehensive-design inclusion |
| `had_save_doc` | `bit` | Not observed in window — from `SaveDoc?` rule — comprehensive-design inclusion |

#### Block 5 — Async sub-workflow flags (6 columns)

Source: `WORKFLOW_LINKAGE.P_WF_ID = main_wfid` with child name resolution.

| Column | Proposed Type | Notes |
|---|---|---|
| `had_vital` | `bit` | 47.33% observed |
| `had_encounter_load` | `bit` | 1.40% observed |
| `had_archive` | `bit` | Combined: inline OR async (Pre inline, Post async, PostArchive2 depends on PV_FN_ADDRESS) |
| `had_post_translation_vital` | `bit` | Post-loop VITAL — not explicitly observed as distinct from in-loop VITAL; comprehensive-design inclusion |
| `had_email` | `bit` | 10.01% observed |
| `had_email_on_error` | `bit` | 1.15% observed — fault fired |

#### Block 6 — Invocation counts (6 columns)

Source: same as flags; use COUNT rather than EXISTS.

| Column | Proposed Type | Notes |
|---|---|---|
| `trans_count` | `int` | Inline TRANS marker count — file count proxy |
| `archive_count` | `int` | Combined inline + async — up to 3 per run (Pre/Post/Post2) |
| `vital_count` | `int` | Async linkage count — exceeds MAIN count when N files × 1 in-loop + 1 post-loop |
| `prep_source_count` | `int` | Inline marker count (~4.16 avg) |
| `accounts_load_count` | `int` | Inline marker count (~4.58 avg) |
| `file_merge_count` | `int` | Inline marker count |

#### Block 7 — Base-service counts (5 columns)

Source: `WORKFLOW_CONTEXT.SERVICE_NAME` grouped counts.

| Column | Proposed Type | Notes |
|---|---|---|
| `sftp_get_count` | `int` | Files retrieved — direct signal, independent of FA_CLIENTS_* wrappers |
| `sftp_put_count` | `int` | Files delivered outbound |
| `sftp_delete_count` | `int` | Remote deletes (FILE_DELETION or post-retrieve cleanup) |
| `translation_count` | `int` | Base Translation steps — distinct from `trans_count` (which counts inline FA_CLIENTS_TRANS wrappers) |
| `cla_invocation_count` | `int` | Total FA_CLA_* command-line adapter invocations |

#### Block 8 — Run outcome (1 column)

Derived from execution evidence (WORKFLOW_CONTEXT presence/absence patterns, BASIC_STATUS).

| Column | Proposed Type | Notes |
|---|---|---|
| `run_outcome` | `varchar(20)` | `PROCESSED` / `SHORT_CIRCUIT` / `FAILED` / `INTERNAL_OP` / `UNKNOWN` |

Definitions:
- `PROCESSED` — GET_DOCS fired, work was done, no terminal failure
- `SHORT_CIRCUIT` — entered polling loop, PREV_SEQ predecessor failed, `Continue?` evaluated false, processing skipped
- `FAILED` — entered processing but faulted out
- `INTERNAL_OP` — `run_class = 'INTERNAL_OP'` SP-executor runs
- `UNKNOWN` — doesn't fit cleanly; flag for investigation

#### Block 9 — Failure detail (9 columns)

Populated only when the run failed. All NULL on success. Source: `WORKFLOW_CONTEXT` scan for error-coded ADV_STATUS and elevated BASIC_STATUS steps (excluding BASIC_STATUS=10 which is normal SFTP status).

| Column | Proposed Type | Notes |
|---|---|---|
| `root_cause_step_id` | `int` | First step with error-coded ADV_STATUS (e.g., FA_CLA_UNPGP=255) even if BASIC_STATUS=0 |
| `root_cause_service_name` | `varchar(200)` | SERVICE_NAME at root_cause_step_id |
| `root_cause_adv_status` | `varchar(500)` | ADV_STATUS at root_cause_step_id |
| `failure_step_id` | `int` | First step with `BASIC_STATUS > 0 AND BASIC_STATUS <> 10` |
| `failure_service_name` | `varchar(200)` | SERVICE_NAME at failure_step_id |
| `failure_service_category` | `varchar(50)` | Classified: `SFTP_TRANSPORT` / `TRANSLATION` / `COMMAND_LINE` / `JDBC` / `FRAMEWORK` / `FA_SUB_WORKFLOW` / `OTHER` |
| `failure_basic_status` | `smallint` | BASIC_STATUS at failure_step_id |
| `failure_adv_status` | `varchar(500)` | ADV_STATUS at failure_step_id |
| `failure_summary` | `varchar(1000)` | Human-readable summary assembled by collector from the failure span |

#### Block 10 — Integration enrichment, live-joined (6 columns)

Stamped at collection time. Will be re-evaluated on subsequent cycles for rows where the Integration data was missing on first pass (handles Integration lag).

| Column | Proposed Type | Notes |
|---|---|---|
| `int_batch_status` | `smallint` | BATCH_STATUS.BATCH_STATUS value |
| `int_batch_parent_id` | `bigint` | BATCH_STATUS.PARENT_ID (Integration-side dispatcher RUN_ID) |
| `int_batch_start_date` | `datetime2` | BATCH_STATUS.START_DATE if populated |
| `int_batch_finish_date` | `datetime2` | BATCH_STATUS.FINISH_DATE |
| `int_enrichment_source` | `varchar(20)` | `COLLECTION_TIME` / `REENRICHED` / `INTEGRATION_UNREACHABLE` |
| `int_enrichment_dttm` | `datetime2` | When Integration enrichment was last attempted/applied |

**TICKETS is NOT mirrored.** The TICKETS table has two grains (workflow-level `MAP ERROR` rows with ACCT_ID NULL, account-level rows like `INVALID DATE OF SERVICE` / `NEW LOCATION` with ACCT_ID populated) and captures data that Integration's downstream Jira workflow needs. xFACts has no operational reason to duplicate it. Live queries handle drill-down use cases. Disagreement detection (see Block 11) is computed from the live join without persisting ticket detail.

#### Block 11 — Disagreement flags (6 columns)

Derived during collection from b2bi-vs-Integration comparison. These are the alert-generating signals.

| Column | Proposed Type | Notes |
|---|---|---|
| `int_status_missing` | `bit` | BATCH_STATUS row absent for this RUN_ID |
| `int_status_inconsistent` | `bit` | b2bi FAILED but Integration BATCH_STATUS doesn't reflect failure |
| `alert_infrastructure_failure` | `bit` | High-severity — b2bi FAILED + Integration blind (either missing row or in-progress state) |
| `alert_enrichment_anomaly` | `bit` | Medium-severity — b2bi SUCCESS but Integration anomalous |
| `alert_ticket_missing` | `bit` | b2bi FAILED + expected TICKETS row absent (Sterling's onFault didn't write) |
| `alert_jira_unassigned` | `bit` | TICKETS row exists but Jira number not assigned within threshold (default 30 min, configurable via GlobalConfig) |

`alert_jira_unassigned` is evaluated asynchronously after execution since Jira assignment is downstream. Collector re-enriches rows where this flag is 1 OR where the TICKETS evaluation hasn't settled yet, until Jira number assignment either clears the flag or the threshold confirms it.

#### Block 12 — Collector metadata (4 columns)

| Column | Proposed Type | Notes |
|---|---|---|
| `collected_dttm` | `datetime2 NOT NULL` | When the row was first written. Default `SYSDATETIME()`. |
| `last_updated_dttm` | `datetime2 NOT NULL` | When the row was last updated. Default `SYSDATETIME()`. Maintained by MERGE. |
| `processdata_cache_id` | `bigint` | FK to `SI_ProcessDataCache` when that table exists; NULL otherwise |
| `collector_version` | `varchar(20)` | Version of the collector that wrote this row — useful when schema/logic changes |

### Totals

| Block | Columns |
|---|---:|
| 1. Core execution identity | 12 |
| 2. Workflow tree | 4 |
| 3. Process identity | 21 |
| 4. Inline sub-workflow flags | 13 |
| 5. Async sub-workflow flags | 6 |
| 6. Invocation counts | 6 |
| 7. Base-service counts | 5 |
| 8. Run outcome | 1 |
| 9. Failure detail | 9 |
| 10. Integration enrichment | 6 |
| 11. Disagreement flags | 6 |
| 12. Collector metadata | 4 |
| **Total** | **93** |

### Physical design decisions — deferred to DDL session

The following decisions are NOT yet finalized and will be addressed in the DDL generation session:

- **Indexes** — Primary key on `workflow_id` is obvious. Secondary candidates: `(collected_dttm)` for recency queries, `(client_id, seq_id)` for entity/process filtering, `(run_outcome, collected_dttm)` for outcome-filtered recency queries, `(alert_infrastructure_failure, alert_ticket_missing, collected_dttm)` for alert feeds. Need actual query patterns before committing.
- **Partitioning** — Table will grow ~2,300 rows/day × 365 = ~840K/year. Unlikely to need partitioning in year 1 but worth revisiting once real data lands.
- **Data type confirmations** — Particularly: varchar lengths for ADV_STATUS fields (source is nvarchar(255) in b2bi, but the failure column stores synthesized summaries which may exceed). Revisit once we have concrete examples of actual content sizes.
- **MERGE pattern for the collector** — Uses `workflow_id` as merge key; `last_updated_dttm` bumped on every match; `collected_dttm` set only on insert. Re-enrichment pass for Integration-lag cases handled as a separate UPDATE pass, not as MERGE.

---

## Detail Tables (Phase 3)

### Design direction — locked

The detail table is NOT a row-level record mirror. Grain is **"between summary and detail"** — captures file-level metadata and (where applicable) DM creditor breakdown, without duplicating CLIENTS_ACCTS row-level content. CLIENTS_ACCTS can be live-queried from Integration for true record-level drill-down.

**Two detail tables proposed:**

#### `SI_FileDetail`
Grain: one row per source file per MAIN run. Captures file-level metadata and the SFTP/FSA retrieval story.

Proposed columns (subject to decompression probe validation):

| Column | Notes |
|---|---|
| `workflow_id` | FK to SI_ExecutionTracking |
| `file_sequence` | 1-based ordinal within the run |
| `source_filename` | From decompression of SFTPClientGet output or ProcessData `<Files>` element |
| `source_file_size` | From same document metadata |
| `source_data_id` | `TRANS_DATA.DATA_ID` for the retrieved file document — correlation key back to Sterling |
| `acquisition_method` | `SFTP_PULL` / `FSA_PULL` / `API_PULL` |
| `retrieval_step_id` | WORKFLOW_CONTEXT.STEP_ID of the SFTPClientGet / AS3FSAdapter step |
| `retrieval_start_time` | |
| `retrieval_end_time` | |
| `retrieval_status` | BASIC_STATUS at that step |
| `output_filename` | Filename delivered to DM staging (when applicable) — the join point to BatchOps |
| `collected_dttm` | When xFACts captured this row |

#### `SI_CreditorBreakdown`
Grain: one row per (MAIN run, DM creditor key). Aggregated from the final/consolidated Translation output's VITAL XML.

Proposed columns (subject to validation):

| Column | Notes |
|---|---|
| `workflow_id` | FK to SI_ExecutionTracking |
| `dm_creditor_key` | CLIENT_KEY from VITAL XML (e.g., CE2049) — join point to `dbo.ClientHierarchy` |
| `record_count` | Count of records for this creditor in the output |
| `collected_dttm` | |

### Validation work pending

Before committing DDL for either detail table, a PowerShell probe must confirm:

1. **Filename extractability.** Filenames are not stored as first-class metadata in `TRANS_DATA` — no `DOC_NAME` or `DATA_NAME` columns exist (confirmed this session via D3). `WORKFLOW_CONTEXT.STATUS_RPT` and `CONTENT` columns hold `DATA_ID` references to TRANS_DATA, not filenames (confirmed via D4). `WORKFLOW_CONTEXT.DOC_ID` stays fixed on the ProcessData document throughout execution and does not pivot per-step (confirmed via D6). Filenames therefore live inside the gzipped `DATA_OBJECT` payloads. The probe must extract a sample SFTPClientGet document and confirm the filename is accessible in the decompressed content — either in a wrapping envelope, an XML header, or the ProcessData `<Files>` element.
2. **Creditor-key extractability.** Confirm the final Translation output reliably contains `CLIENT_KEY` values in a parseable structure, across at least 3 process types (NEW_BUSINESS, PAYMENT, and one non-account-oriented type like NOTES OUTBOUND). If any process type doesn't produce creditor-level output, `SI_CreditorBreakdown` may need to be scoped to specific process types only.
3. **Cardinality bounds.** Observed 22-file case (WORKFLOW_ID 8007206) sets the floor for "large but tractable." Need to confirm creditor-count-per-execution distribution — if a single execution regularly produces 1000+ distinct CLIENT_KEYs, we may need to aggregate further or use a different grain.

The probe will be designed and run in the next session, before detail-table DDL.

### Key discovery results that shape detail design

From the 2026-04-21 discovery session:

- **TRANS_DATA has 3 REFERENCE_TABLE values**: `WORKFLOW_CONTEXT` (per-step context, most rows), `DOCUMENT` (actual payloads — ProcessData at PAGE_INDEX 0 + per-file payloads at higher PAGE_INDEX), `DOCUMENT_EXTENSION` (supplementary document metadata on some runs).
- **PAGE_INDEX 0 is always ProcessData** (one per MAIN run). Higher PAGE_INDEX values (1, 2, ..., up to 179 observed) are per-file payloads on runs that process multiple files.
- **Typical MAIN has 60–200 TRANS_DATA rows** with 5–15 DOCUMENT rows. Heavy-merge runs can hit 2000+ total rows with 200+ DOCUMENT rows.
- **Filenames must be extracted via decompression** — they don't live in `WORKFLOW_CONTEXT` text columns. Step → document correlation works via `WORKFLOW_CONTEXT.STATUS_RPT` / `CONTENT` holding DATA_IDs.
- **File count per run is directly countable** from WORKFLOW_CONTEXT SFTPClientGet step occurrences — this is already captured in the header's `sftp_get_count` column.
- **WORKFLOW_ID 8007206 is our canonical multi-merge test case** — 22 SFTPClientGet steps, 218 DOCUMENT rows, 2195 total TRANS_DATA rows. Useful for probe sizing.

---

## SI_ScheduleRegistry (Phase 1)

### Design direction

Intentionally simple. Sterling's own `b2bi.dbo.SCHEDULE` table is authoritative for workflow schedules (confirmed by Melissa Q13). `SI_ScheduleRegistry` mirrors relevant fields for inventory and alerting purposes (e.g., detecting "scheduled workflow didn't run when expected").

Planned columns (TBD pending detailed discovery of `b2bi.dbo.SCHEDULE`):

- Schedule ID, schedule name, associated workflow name
- Cron-like schedule expression or recurrence fields
- Active flag
- Last-known-fire timestamp
- Collector metadata

**Deviations worth flagging:**
- GET_LIST's documented schedule: hourly at `:05`, `5:05 AM – 3:05 PM`, weekdays only (confirmed by Melissa Q4). If the SCHEDULE table has a different representation, we capture both forms for disagreement detection.

No urgency on this table — it's reference data that doesn't change often. Build after `SI_ExecutionTracking` is in production.

---

## Collector (Phase 4)

`Collect-B2BExecution.ps1` — populates `SI_ExecutionTracking` and (when validated) `SI_FileDetail` / `SI_CreditorBreakdown`.

### Collector flow

Per collection cycle (frequency TBD — likely 1–5 min):

1. **b2bi primary** — Query `WF_INST_S` for `FA_CLIENTS_MAIN` runs started since last high-water mark. Produces the list of workflow_ids needing a row.
2. **b2bi enrichment** — For each captured workflow_id:
   - Query WORKFLOW_LINKAGE for parent + root.
   - Query WORKFLOW_CONTEXT for step count, inline markers, base-service counts.
   - If failure: deep-scan WORKFLOW_CONTEXT for root-cause + reported-failure steps.
   - Query TRANS_DATA for ProcessData; decompress gzip; parse `//Result/Client[1]` fields.
   - Parse or defer SFTPClientGet document decompression for filename extraction (detail table).
3. **Integration live-join enrichment (bulk)** — After accumulating a batch:
   - Bulk query `BATCH_STATUS` for matching RUN_IDs.
   - Bulk query `TICKETS` for matching RUN_IDs (for disagreement flag derivation, not for stamping rows).
   - Bulk query `CLIENTS_MN` for display-name resolution per distinct client_id.
   - Compute disagreement flags: `int_status_missing`, `int_status_inconsistent`, `alert_infrastructure_failure`, `alert_enrichment_anomaly`, `alert_ticket_missing`, `alert_jira_unassigned`.
4. **Write** — MERGE into `SI_ExecutionTracking`. Detail rows (once tables exist) inserted into `SI_FileDetail` / `SI_CreditorBreakdown`.
5. **Re-enrichment pass** — For rows collected within last 24h where `int_status_missing=1` or `alert_jira_unassigned=1`, re-query Integration and update accordingly.
6. **Advance high-water mark.**

### Key collector design notes

- **Rate limit:** batch MERGE, not per-row. 2300 MAIN runs/day × 5–200 WORKFLOW_CONTEXT rows per run × 1 ProcessData blob each means the collector touches meaningful data volume; batching is essential.
- **Decompression strategy:** decompress ProcessData per row at write time. Defer per-file SFTPClientGet output decompression to the detail-table collector pass (can be async).
- **Cross-server latency:** b2bi on FA-INT-DBP, Integration on AVG-PROD-LSNR — no linked server. Each cycle makes separate DB calls with `-ApplicationName` tagged for tracing.
- **Credential concerns:** PGP_PASSPHRASE and PYTHON_KEY are in ProcessData plaintext. The collector records `has_pgp_passphrase` (bit) but does not persist the passphrase itself. ProcessData cache (`SI_ProcessDataCache`) is deferred until credential handling is designed.
- **High-water mark robustness:** store per-collection-run hwm, not just latest. Collector crash mid-cycle shouldn't produce duplicates or gaps. MERGE pattern handles duplicates; gap protection requires an overlap window or per-batch acknowledgment.

---

## Open Design Questions

1. **Detail table grain — per file vs per (file, creditor).** `SI_FileDetail` is per-file. `SI_CreditorBreakdown` is per-(workflow, creditor). The question is whether a third relationship — per-(file, creditor) — is needed to support "this file contributed records for these creditors." Depends on whether the VITAL XML preserves source filename attribution or loses it during merge. Decompression probe will answer.
2. **SI_ProcessDataCache credential handling.** Open options: redact known sensitive fields before persistence, store only a parsed field subset, encrypt raw XML at rest, shorten retention, or combination. No decision yet. Core collector operates without this table.
3. **UDP BDL scope.** User Defined Pages BDL — Matt's legacy UDP reference code exists in the WorkingFiles folder on GitHub. Not yet reviewed. Deferred to when BDL-specific monitoring is designed.
4. **Configured-but-never-runs detection.** Melissa's Q14 response (ACADIA SEQ_ID 9 is misconfigured) implies other configuration rows may exist that never execute. Candidate for Phase 4+ monitoring — "SEQs configured but dormant." Not blocking current build.

---

## Melissa Feedback (2026-04-21)

Melissa provided first-pass responses to 8 of the 22 Apps/Integration team questions. The remaining questions she'll follow up on.

Resolved:

| # | Topic | Resolution |
|--:|---|---|
| 1 | FILE_DELETION lifecycle | Files removed from Joker SFTP, retained in `ftpbackup`. Only clients submitting un-needed files have this configured. |
| 4 | AUTOMATED field values | `AUTOMATED=1` = GET_LIST-driven. GET_LIST schedule: **5:05 AM – 3:05 PM, hourly at :05, weekdays only**. `AUTOMATED=2` = scheduled business process (wrapper-driven). |
| 5 | RUN_FLAG mechanism | Set upstream of GET_LIST; GET_LIST reads and clears it. |
| 6 | AUTOMATED terminology | Apps team says "GET_LIST" for AUTOMATED=1 and "Scheduler" for AUTOMATED=2 — matches our SP-derived understanding. |
| 7 | SPECIAL_PROCESS semantics | **Catch-all, not a semantic type.** Anything that doesn't fit standard process types becomes SPECIAL_PROCESS. Implication: `run_class` is more reliable than `process_type` for classification. |
| 9 | FILE_DELETION scope | Only clients that submit un-needed files have it. Confirms our GET_DOCS ZeroSize? rule understanding. |
| 13 | Schedule authority | Sterling's own `SCHEDULE` table is authoritative. Confirms `SI_ScheduleRegistry` should source from `b2bi.dbo.SCHEDULE`. |
| 14 | ACADIA SEQ_ID 9 | Misconfigured — dev started on it, never needed or incorrectly added. Implies other misconfigured SEQs likely exist in the field. |

Still pending responses from Melissa / Apps / Integration on questions 2, 3, 8, 10, 11, 12, 15, 16, 17, 18, 19, 20, 21, 22.

---

## Next Session Priorities

1. **Generate DDL for `SI_ExecutionTracking`** — physical types, PK, indexes, constraints; match the 93-column design above. One script, full file replacement of an initial DDL file (no existing object to alter against).
2. **Design PowerShell decompression probe** for detail-table validation — extract sample documents from WORKFLOW_ID 8007206 and one recent NB run, decompress, inspect for filename location and creditor breakdown extractability.
3. **Commit `SI_FileDetail` and `SI_CreditorBreakdown` designs** once probe results are in.
4. **Architecture doc + Process Anatomy docs** — small-batch update pass to incorporate this session's findings:
   - Architecture doc: ftpbackup retention in FILE_DELETION section; GET_LIST schedule window specifics; AUTOMATED terminology note; SPECIAL_PROCESS catch-all note; BASIC_STATUS=10 normal SFTP status clarification; ETL_CALL deprecation banner; file-lifecycle goal added to Core Architectural Insight section.
   - NewBusiness anatomy doc: nothing urgent but review for consistency once other updates are in.

---

## Document Status

| Attribute | Value |
|---|---|
| Purpose | Planning and direction for xFACts B2B module build |
| Created | April 19, 2026 |
| Last Updated | April 21, 2026 |
| Status | Working document — ephemeral; discarded once module is running |
| Maintainer | xFACts build (Dirk + Claude collaboration) |

### Revision Log

| Date | Revision |
|---|---|
| April 19, 2026 (rev 1–4) | Initial creation, iterative additions through early investigation sessions. |
| April 20, 2026 (rev 5–6) | BPML read integrations, GET_LIST dispatcher model, four-pattern corrections, Integration coordination layer. |
| April 20, 2026 (rev 7) | Integration mirror approach abandoned; architecture reframed for b2bi-first with live-join enrichment. Phase 1 tables dropped. |
| **April 21, 2026 (rev 8)** | **SI_ExecutionTracking 93-column design locked.** ETL_CALL confirmed deprecated (omitted from scope; retained in architecture doc for historical reference). Sub-workflow detection paths empirically validated — inline markers (`Inline Begin` with leading space), async linkage, base service SERVICE_NAME scans. BASIC_STATUS=10 clarified as normal SFTP status. TICKETS explicitly NOT mirrored; disagreement flags on header table handle ticket/Jira monitoring use cases. Detail tables scoped (`SI_FileDetail`, `SI_CreditorBreakdown`) with design pending decompression-probe validation. File-lifecycle goal promoted to Executive Summary. Melissa feedback absorbed (Q1/4/5/6/7/9/13/14 resolved). Next-session priorities updated. |

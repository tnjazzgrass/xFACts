# B2B Sterling Architecture Overview

## Purpose of This Document

Reference document capturing the architectural model of IBM Sterling B2B Integrator as it is configured and operated at FAC. Built from a combination of live `b2bi` database investigation, the original architect's Visio flow document (`BPs_Flow.vsdx`, authored by Rober Makram circa April 2021), direct inspection of Integration configuration tables, and operational observations.

Intended audience: Dirk and the xFACts build effort. Eventually will serve as the source material for Control Center help pages under the B2B module. This is a reference document for understanding and building — not a finished publication.

Companion documents: `B2B_ProcessAnatomy_*.md` — one per process type, drilling into specifics.

---

## The Core Architectural Insight

**Every unit of work in Sterling corresponds to one execution of the `FA_CLIENTS_MAIN` workflow.**

This is the universal grain. Regardless of how a workflow was dispatched, and regardless of what the workflow does (NB inbound, payment, file cleanup, internal ops, etc.), the actual work is driven by `FA_CLIENTS_MAIN` (WFD_ID 798). Every MAIN execution carries its own `ProcessData` document that self-describes what that run is about — which entity, which process type, which files, which sub-workflows to invoke.

**But MAIN is polymorphic.** Depending on the configuration in ProcessData, MAIN executes one of at least three fundamentally different code paths (see "MAIN's Polymorphic Execution Paths" below). This is important for understanding why step counts vary so dramatically between runs and why sub-workflow invocation patterns differ.

From the xFACts collector's perspective, **the target is simple: every `FA_CLIENTS_MAIN` run in b2bi is a unit of work worth tracking. What that work IS varies, but the collection target is consistent.**

Everything else in `b2bi.dbo.WF_INST_S` is either a **dispatcher** (invokes MAIN), a **sub-workflow** (invoked by MAIN), or **Sterling infrastructure** (unrelated to MAIN — utility, housekeeping, gateway plumbing).

---

## The Three Identity Scopes

There are three distinct identity scopes at play in Sterling file processing. Confusion between them is a common source of misunderstanding.

### Scope 1: Sterling Entity (via CLIENT_ID)
The `CLIENT_ID` in Sterling's Integration tables identifies a **configured entity** — a customer, vendor, or internal endpoint that Sterling processes files for/to. Some "clients" are real customers (ACADIA HEALTHCARE = CLIENT_ID 10557), others are internal pseudo-clients (INTEGRATION TOOLS = CLIENT_ID 328). Sterling's CLIENT_ID is NOT the same as a DM Creditor.

The term "CLIENT" in Sterling terminology is inherited from Integration team conventions and doesn't precisely match semantics. In the xFACts B2B schema, we use **"Entity"** instead to reflect that these identifiers cover clients, vendors, and internal services.

### Scope 2: Sterling Process (via (CLIENT_ID, SEQ_ID))
Within a single Entity, multiple **Processes** are configured, each differentiated by `SEQ_ID`. ACADIA alone has 9 configured processes spanning NB, file-deletion variants, RECON, SPECIAL_PROCESS, FILE_EMAIL, and outbound RETURNs. ACADIA HEALTHCARE EO (CLIENT_ID 10724) has 4 processes that form an orchestrated pipeline (see Multi-Client section).

The **(CLIENT_ID, SEQ_ID) pair uniquely identifies a Process.**

### Scope 3: DM Creditor Key
Inside the file payload itself, individual records may carry **DM Creditor Keys** (e.g., `CE12345`, `CE98765`). These refer to entities in DM's creditor hierarchy (exposed in xFACts via the `dbo.ClientHierarchy` table). A single file processed by one Sterling Process may contain records for multiple DM Creditors.

**Critical:** when the Sterling team says "client," context determines what they mean. "ACADIA" as a Sterling Entity (CLIENT_ID 10557) is not the same as an ACADIA-related DM Creditor Key. A single Sterling Process for ACADIA can route records to many DM Creditors.

### Implied Grain Layering

```
MAIN RUN (WORKFLOW_ID)
 └── Sterling Process (CLIENT_ID, SEQ_ID)         ← usually 1 per MAIN; multi-Client runs have N
      └── Individual File                          ← 1 or more per Process (loop)
           └── DM Creditor breakdown               ← 1 or more per File (records to different creditors)
```

The xFACts execution tracking schema needs to reflect this layering. See "Execution Tracking Grain Proposal" below — note that this proposal has a known complication from Pattern 5 that requires further design work.

---

## MAIN's Polymorphic Execution Paths

A single WFD (`FA_CLIENTS_MAIN`, WFD_ID 798) serves multiple distinct execution paths. Depending on ProcessData flags, MAIN takes one of at least three very different branches through its BPML logic. These paths should be thought of as different "modes" of MAIN rather than different code.

### Path A: Standard File Processing (the NB / PMT / RECON / etc. pattern)
The "typical" MAIN execution most people envision: GET_DOCS to pull files, loop per file through PREP_SOURCE → TRANS → (possibly ACCOUNTS_LOAD) → FILE_MERGE → per-iteration ARCHIVE, then tail-phase sub-workflows (WORKERS_COMP, DUP_CHECK, ADDRESS_CHECK, POST_TRANSLATION, COMM_CALL, etc.).

**Signature:**
- FILE_FILTER populated
- GET_DOCS_TYPE populated
- TRANSLATION_MAP populated
- Multiple file-processing sub-workflow flags populated (PREPARE_SOURCE, DUP_CHECK, WORKERS_COMP, etc.)
- Step counts typically 100+ (one traced run had 1,210 steps for 14 files)

**Example:** ACADIA NB (WF 7990812) — see `B2B_ProcessAnatomy_NewBusiness.md`

### Path B: Internal Operation / SP Executor
MAIN serves as a thin wrapper to execute an Integration stored procedure. Minimal sub-workflow pattern: GET_DOCS (no-op) → POST_TRANSLATION → PREP_COMM_CALL → COMM_CALL (all degenerate).

**Signature:**
- CLIENT_ID is an internal pseudo-client (e.g., 328 "INTEGRATION TOOLS")
- FILE_FILTER empty, GET_DOCS_TYPE empty, TRANSLATION_MAP empty
- POST_TRANS_SQL_QUERY populated with `EXEC Integration.FAINT.USP_*`
- Step count is ~49 (skeleton)

**Example:** The FTP_FILES_LIST internal ops that fire every 10 minutes.

### Path C: SFTP Cleanup (FILE_DELETION)
MAIN does NOT invoke the standard file-processing sub-workflow stack. Instead it opens a single SFTP session, lists remote files, and performs inline `SFTPClientDelete` operations in a loop. Uses native Sterling services (AS2LightweightJDBCAdapter for tracking, DecisionEngineService for loop control) rather than FA_CLIENTS_* sub-workflows.

**Signature:**
- PROCESS_TYPE = FILE_DELETION
- FILE_FILTER populated (identifies which remote files to remove)
- GET_DOCS_TYPE populated (SFTP_PULL) — but used for *deletion*, not retrieval
- TRANSLATION_MAP empty
- All processing flags empty (no PREPARE_SOURCE, no WORKERS_COMP, no DUP_CHECK, no COMM_CALL)
- Step counts in the 900+ range for a busy cleanup, dominated by repeated SFTPClientDelete operations

**What it actually does:** Goes back to the client's SFTP server and removes files that were previously retrieved and processed. This is remote source-side cleanup, not local file system cleanup. The 112 SFTPClientDelete operations observed in one ACADIA FILE_DELETION run = 112 files removed from the remote SFTP.

**Example:** ACADIA CMT FILE_DELETION (WF 7992163) — full anatomy pending (`B2B_ProcessAnatomy_FileDeletion.md` planned)

### Possible Path D: Polling Worker (Early Exit)
We've observed MAIN runs with step counts as low as 16 — BELOW the empty-run skeleton of Path B (49 steps). These runs:
- Don't invoke any Inline Begin sub-workflows
- Consist of JDBC adapter queries, wait services, and decision engine calls
- Appear to "check something, find it not ready, exit cleanly"

Pattern observed in ACADIA EO pipeline parallel workers. Not yet fully understood — included for completeness.

**Implication for the collector:** not all MAIN runs are "attempting to do the same thing and failing early." Some MAIN runs are intentionally short-lived polling workers. Need to decide whether these count as "a unit of work" in SI_ExecutionTracking.

---

## Dispatch Patterns

`FA_CLIENTS_MAIN` is never a root. It is always invoked by something. Five distinct dispatch patterns have been observed.

### Pattern 1 — Schedule-Fired Named Workflow

A named workflow (typically entity-specific) fires on its own schedule in Sterling's `SCHEDULE` table. It invokes `FA_CLIENTS_MAIN` directly with one Client block of ProcessData.

**Examples:**
- `FA_TO_FORREST_GENERAL_OB_BD_S2D_NT` → fires at 06:40 → invokes MAIN
- `FA_FROM_ACADIA_HEALTHCARE_IB_BD_P2X_NB` → fires on daily schedule → invokes MAIN (see NB anatomy)

**Characteristics:**
- One root → one MAIN (usually)
- Most common pattern by sheer variety of workflows
- Root fires regardless of whether work exists

### Pattern 2 — GET_LIST Dispatcher Loop

`FA_CLIENTS_GET_LIST` fires on a schedule, iterates configured processes (likely by reading CLIENTS_FILES + CLIENTS_PARAM), and invokes `FA_CLIENTS_MAIN` for each. This is the dispatcher pattern documented in Page 1 of Rober's Visio.

**Live data:** 17 GET_LIST runs per day. Each run spawns multiple MAIN invocations (count not yet verified).

### Pattern 3 — Periodic Internal Operation Scanner

A periodic workflow (`FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` and its `_ARC` variant) fires every ~10 minutes and invokes MAIN to execute Integration stored procedures. **These are Internal Operations (Path B of MAIN), not file scanners.**

**Note:** Despite the "FTP_FILES_LIST" name suggesting file scanning, these workflows do NOT scan FTP folders for customer files. The names are literal descriptions of the Integration stored procedures they execute.

### Pattern 4 — Periodic Puller

Entity-specific puller workflows (`FA_FROM_*_PULL`) fire on entity schedules, pull files via SFTP, and invoke MAIN per file processed.

**Examples:**
- `FA_FROM_REVSPRING_IB_BD_PULL`: 14 runs per day
- `FA_FROM_ACCRETIVE_IB_BD_PULL`: observed spawning **three MAIN children** in a single invocation (three files found in one scan)

**Characteristics:**
- Each puller has its own schedule
- Can spawn 1 or more MAINs per invocation depending on what's found
- These are File Processes (Path A of MAIN)

### Pattern 5 — Parallel Phased Workers

**A dispatcher workflow fires MULTIPLE MAIN children simultaneously, each with the same multi-Client ProcessData containing an orchestrated pipeline of phases.** The 4 workers appear to function as polling workers — each checks conditions for its assigned phase, does work if ready, exits cleanly if not.

**Example:** `FA_FROM_ACADIA_HEALTHCARE_IB_EO` spawned 4 MAIN children simultaneously on 2026-04-19 14:00:03. Each carried identical ProcessData with 4 Client blocks:
- SEQ_ID 1: SPECIAL_PROCESS (orchestration/merging — calls external Python exe)
- SEQ_ID 2: NEW_BUSINESS
- SEQ_ID 3: PAYMENT
- SEQ_ID 8: ENCOUNTER
- Linked via `PREV_SEQ` field: 2→1, 3→2, 8→3 (sequential dependencies)

Observed step counts for the 4 workers: 16, 19, 21 (failed on SFTP), 33. Very short — most workers exited without meaningful work.

**Characteristics:**
- Multi-Client ProcessData shared across all MAIN workers
- Workers coordinate via JDBC checks (presumably consulting a shared state table)
- Many runs may have 0 or 1 worker do meaningful work while others exit fast
- Potential for failures on one worker while others succeed

**Open question:** exactly how the coordination works — whether the 4 workers run truly independently and self-select their phase, or whether some external state controls who does what. **To be verified with the Apps team.**

---

## Run Classification — File Process vs. Internal Operation

Not every MAIN run is a file process. Some MAIN runs exist to execute Integration stored procedures. The collector must distinguish these.

**Note:** PROCESS_TYPE alone cannot distinguish. `SPECIAL_PROCESS` is used by both legitimate entity processes (ACADIA SEQ_ID 6 and ACADIA EO SEQ_ID 1) and internal housekeeping (CLIENT_ID 328). The classification signal is the **configuration signature**, not the process type name.

### File Process
Real entity data moving through Sterling. The MAIN run is processing, attempting to process, or maintaining files for a real client/vendor.

**Indicators:**
- CLIENT_ID is a real entity (not `328` / "INTEGRATION TOOLS")
- FILE_FILTER populated OR SPECIAL_PROCESS with MISC_REC1 pipe-delimited list
- GET_DOCS_TYPE populated (inbound) OR PUT_DOCS_TYPE populated (outbound)

### Internal Operation
MAIN runs whose real purpose is to execute Integration stored procedures or other Sterling-internal tasks.

**Indicators:**
- CLIENT_ID is an internal identifier (e.g., `328`)
- FILE_FILTER empty
- GET_DOCS_TYPE empty
- POST_TRANS_SQL_QUERY populated with `EXEC Integration.FAINT.USP_*` call

**Known Internal Entity IDs:** 328 ("INTEGRATION TOOLS"). Others may exist — to be discovered as encountered.

### Proposed run_class Values for SI_ExecutionTracking
- `FILE_PROCESS` — real file/cleanup work
- `INTERNAL_OP` — SP-executor pattern
- `UNCLASSIFIED` — doesn't fit either cleanly (flag for investigation)

---

## The Configuration Source — CLIENTS_FILES and CLIENTS_PARAM

ProcessData is not pulled from thin air. Sterling assembles it at runtime from **two Integration database tables**.

### `Integration.etl.tbl_B2B_CLIENTS_FILES`
**Process-level classification.** One row per (CLIENT_ID, SEQ_ID). Defines what kind of process this is.

| Column | Type | Purpose |
|--------|------|---------|
| ID | identity | PK |
| CLIENT_ID | numeric | Entity identifier |
| SEQ_ID | numeric | Process sequence within entity |
| ACTIVE_FLAG | bit | Enabled (1) / disabled (0) |
| RUN_FLAG | bit | **Semantics unclear** — possibly "currently running/locked" or "eligible to run" |
| PROCESS_TYPE | string | NEW_BUSINESS, PAYMENT, NOTES, RECON, FILE_DELETION, etc. |
| COMM_METHOD | string | INBOUND / OUTBOUND |
| AUTOMATED | tinyint | **Semantics unclear** — values 1 or 2 observed; possibly indicates dispatch mechanism |
| FILE_MERGE | bit | Whether merge behavior applies |

### `Integration.etl.tbl_B2b_CLIENTS_PARAM`
**Field-level configuration.** Key-value store. One row per (CLIENT_ID, SEQ_ID, PARAMETER_NAME).

### Assembly at Runtime

When Sterling needs to invoke `FA_CLIENTS_MAIN` for a given (CLIENT_ID, SEQ_ID):
1. Reads the `CLIENTS_FILES` row → gets `PROCESS_TYPE`, `COMM_METHOD`, `ACTIVE_FLAG`, etc.
2. Reads all matching `CLIENTS_PARAM` rows → gets field-level config
3. Assembles into a ProcessData XML document wrapped in `<r><Client>...</Client></r>`
4. Injects that ProcessData as input to MAIN

For multi-Client pipelines (Pattern 5), the assembled ProcessData contains multiple `<Client>` blocks linked via `PREV_SEQ`.

---

## Confirmation of MAIN as Collector Target

From a 24-hour sample (April 18–19, 2026):

| Workflow | Total Runs | % with ProcessData (DOCUMENT type TRANS_DATA) |
|----------|-----------:|-----------------------------------------------:|
| FA_CLIENTS_MAIN | 820 | 100.0% |
| FA_CLIENTS_VITAL | 888 | 100.0% |
| FA_CLIENTS_ARCHIVE | 753 | 96.9% |
| FA_CLIENTS_EMAIL | 33 | 100.0% |
| FA_CLIENTS_JIRA_TICKETS | 24 | 100.0% |
| FA_CLIENTS_ENCOUNTER_LOAD | 11 | 100.0% |
| All named `FA_FROM_*`, `FA_TO_*`, client workflows | varies | 100.0% each |
| FileGatewayReroute, FileGatewayListeningProducer | 288/287 | 0.0% |
| Schedule_* (infrastructure) | various | 0.0% |
| TimeoutEvent, Alert, Recover.bpml | 96/48/32 | 0.0% |

Filter for the collector: `WFD.NAME = 'FA_CLIENTS_MAIN'` (simplest) or presence of DOCUMENT-type TRANS_DATA (more defensive).

**Why FA_CLIENTS_VITAL has 888 runs vs. 820 for MAIN:** VITAL is a sub-workflow invoked inside ACCOUNTS_LOAD. It shows in WF_INST_S because each VITAL invocation has its own WORKFLOW_ID.

---

## The ProcessData Document

### Where It Lives

Every `FA_CLIENTS_MAIN` run writes one or more documents to `TRANS_DATA` with `REFERENCE_TABLE = 'DOCUMENT'` and `PAGE_INDEX = 0`. The **first** such document (by `CREATION_DATE`) is the ProcessData. Subsequent rows contain sub-workflow outputs, SQL query results, or intermediate documents.

### Correct Lookup Pattern

```sql
SELECT TOP 1 DATA_ID, DATA_OBJECT
FROM b2bi.dbo.TRANS_DATA
WHERE WF_ID = @WFID
  AND REFERENCE_TABLE = 'DOCUMENT'
  AND PAGE_INDEX = 0
ORDER BY CREATION_DATE ASC, DATA_ID ASC
```

### Verified Schema

**Wrapper:** `<?xml version='1.0' encoding='UTF-8'?><r><Client>...</Client></r>`

Outer element is `<r>`, not `<r>` as the original planning doc stated. Multiple `<Client>` blocks may appear (multi-Client).

**Process type field:** `<PROCESS_TYPE>` (sourced from CLIENTS_FILES). Rober's Visio showed `<CLIENT_TYPE>` — older schema since renamed.

### Multi-Client ProcessData — Two Distinct Meanings

Multi-Client ProcessData appears in two fundamentally different scenarios:

**Case 1 — Parallel file types for one entity (e.g., PMT ACH + CC)**
PAY N SECONDS has 2 Client blocks — one for ACH payments, one for credit card. The MAIN workflow processes both file types together as parallel sequential imports within a single run. Both arrive at DM as separate batches.

**Case 2 — Sequential pipeline phases (e.g., ACADIA EO)**
ACADIA EO has 4 Client blocks linked by `PREV_SEQ`: SPECIAL_PROCESS (orchestration) → NEW_BUSINESS → PAYMENT → ENCOUNTER. These are **sequential phases** of a pipeline, not parallel types. The dispatcher (`FA_FROM_ACADIA_HEALTHCARE_IB_EO`) spawns **multiple parallel MAIN workers, all sharing the same 4-Client ProcessData** (Pattern 5), and the workers coordinate via JDBC to execute the phases.

**Distinguishing the two cases:**
- Case 1: all Client blocks fire in one MAIN run; `PREV_SEQ` empty
- Case 2: `PREV_SEQ` populated linking blocks sequentially; dispatcher fires multiple MAIN workers with the same ProcessData

**Collector implication:** the grain of "(WORKFLOW_ID, CLIENT_ID, SEQ_ID) = one row" breaks in Case 2. If 4 MAIN workers each carry 4 Client blocks, naive grain creates 16 rows for what's conceptually 4 phases of 1 pipeline run. **This is a known design question requiring resolution before collector build.**

### PREV_SEQ Field

Previously unexplained. Now understood: `PREV_SEQ` is a **sequential dependency reference**. A Client block with `PREV_SEQ=1` says "this phase depends on phase SEQ_ID 1 completing first."

Whether Sterling enforces this or it's metadata-only is unclear — **to be verified with the Apps team.**

### Failed Runs Have ProcessData

**Resolved open question:** when a MAIN workflow fails (STATUS=1), ProcessData is still written at Step 0, BEFORE the failure occurs. The collector can extract ProcessData for failed runs normally.

**Failure signal location:** the failing step in WORKFLOW_CONTEXT has `BASIC_STATUS > 0` (typically = 1) and `ADV_STATUS` contains the error message. Example from a traced failure: step 15 (`SFTPClientBeginSession`) had `BASIC_STATUS=1` and `ADV_STATUS="Connection Failure! Could not complete connection to specified host:"`. This step-level information is the source of truth for failure detail; WF_INST_S.STATUS just reflects that a failure occurred.

### Known Fields (Partial Inventory — ~70+ fields)

(Full list as in previous revision — sections on Identity, Process categorization, File input/output, Translation, SQL hooks, Sub-workflow flags, Archive, Processing helpers, Notification, Executable paths, Custom BP hooks, DM config.)

**New since prior revision:**
- `PREV_SEQ` — sequential phase dependency reference (see above)
- `COMM_CALL_CLA_EXE_PATH` — external executable invocation. Observed value:  `\\kingkong\Data_Processing\Pervasive\Python_EXE_files\FA_PAYGROUND\FA_MERGE_PLACEMENT_FILES.exe $0 $1 $2 $3`. Sterling can invoke external Python executables during COMM_CALL phase for SPECIAL_PROCESS pipeline orchestration.
- `COMM_CALL_WORKING_DIR` — working directory for the external exe
- `MISC_REC1` (more context) — observed as pipe-delimited FILE_FILTER list for SPECIAL_PROCESS pipeline orchestration: `acadia.2*FEOPF2*|acadia.2*FEOTRN*|acadia.2*FEOPFT*`
- `GET_DOCS_DLT` — delete-after-get flag (observed Y for ENCOUNTER process type)
- `ENCOUNTER_MAP` — specific translation map for ENCOUNTER process type

### PRE_ARCHIVE / POST_ARCHIVE Semantics — Resolved

Current Sterling uses `Y` / empty (and possibly `N` explicitly) for these fields. Paths in Rober's 2021 Visio were dev-environment configurations, not production.

### Storage Strategy

The field inventory is large (~70 fields) and mostly empty per run. Strategy for `SI_ProcessDataCache`:
- Always persist the raw decompressed XML
- Parse a targeted subset into structured columns in SI_ExecutionTracking
- Leave the rest queryable via cached XML for edge cases

---

## Empty-Run and Short-Run Behavior

Multiple varieties of "nothing happened" MAIN runs have been observed:

**~49-step Internal Operation skeleton** (CLIENT_ID=328 SP executors): GET_DOCS → POST_TRANSLATION → PREP_COMM_CALL → COMM_CALL, all degenerate. No real work.

**~16-step Polling Worker** (ACADIA EO phased workers that didn't pick up work): No sub-workflows at all. JDBC checks + waits + decisions + exit.

**Failed runs** (varies): step count depends on when the failure occurs. ProcessData is written normally. The failing step's `BASIC_STATUS` and `ADV_STATUS` identify the failure.

**Real File Processes with no files** (Pattern 1 scheduled runs that find nothing): not yet explicitly traced, but expected to resemble the Internal Op skeleton.

**Collector implication:** "no work happened" is not a single condition. Different short-run signatures correspond to different reasons. The collector should probably capture:
- Count of `FA_CLIENTS_TRANS` invocations — if 0, no data was translated
- Count of each major sub-workflow invocation
- Whether any step has `BASIC_STATUS > 0` — failure signal

---

## Inbound vs. Outbound — Different Sub-Workflow Shapes

Per the Visio (Pages 2 and 3), inbound and outbound MAIN execute materially different sub-workflow sequences. Live observation confirms the general structure but with some differences from the 2021 diagram.

(Previous details on inbound/outbound shapes retained from prior revisions; see `B2B_ProcessAnatomy_NewBusiness.md` for the verified inbound sub-workflow shape with 14-iteration loop pattern.)

---

## Execution Tracking Grain Proposal (with Known Complication)

Based on the Three Identity Scopes, execution tracking needs at least a two-level grain.

### Header Level — `SI_ExecutionTracking` (sketch)

**Proposed grain:** one row per `(WORKFLOW_ID, CLIENT_ID, SEQ_ID)` from ProcessData.

**Known complication:** Pattern 5 (Parallel Phased Workers) breaks this grain. Four concurrent MAIN workers each carrying 4 Client blocks = 16 rows for 1 conceptual pipeline invocation. **This needs resolution before collector build.**

Possible resolutions (to discuss):
- **Option A:** Accept redundancy. Write 16 rows. Add a `root_workflow_id` column for clustering and a `did_work` flag for filtering. Aggregate views roll up.
- **Option B:** Write one row per unique (ROOT_WF_ID, CLIENT_ID, SEQ_ID), with the collector responsible for deduplicating across sibling workers. More complex collector logic but cleaner data.
- **Option C:** Change grain to one row per WORKFLOW_ID (regardless of Client count), with Client details in a child table. Deviates from the original design but handles Pattern 5 naturally.
- **Option D:** Keep current grain for Patterns 1-4, but for Pattern 5 only write the Client block that actually did work (detected by which worker had sub-workflow invocations). More complex but most semantically clean.

No decision yet. **Open design question.**

### Columns (preliminary):
- `workflow_id`, `parent_workflow_id`, `root_workflow_id`
- `client_id`, `seq_id`, `client_name`
- `process_type`, `comm_method`, `business_type`
- `translation_map`, `file_filter`, `get_docs_type` (targeted subset of ProcessData)
- `run_class` (FILE_PROCESS / INTERNAL_OP / UNCLASSIFIED)
- `execution_path` (STANDARD / SP_EXECUTOR / SFTP_CLEANUP / POLLING_EXIT) — new dimension reflecting MAIN's polymorphic paths
- `file_count` — derived from TRANS invocation count
- `workflow_start_time`, `workflow_end_time`, `duration_ms`
- `status`, `state`, `status_message`, `failure_step_id`, `failure_service_name`
- `had_trans`, `had_vital`, `had_accounts_load` — sub-workflow invocation flags
- `collected_dttm`, `processdata_cache_id`

### Detail Level — `SI_ExecutionDetail` (Deferred to Phase 2)

Grain: one row per `(WORKFLOW_ID, CLIENT_ID, SEQ_ID, FILE_INDEX, DM_CREDITOR_KEY)`. Source: Translation output XML parsed per MAIN run. Build first at header level; add detail when that's validated.

### ProcessData Cache — `SI_ProcessDataCache`

Grain: one row per MAIN run. Preserves raw decompressed XML.

---

## Integration Source Table Mirrors (Proposed)

Three tables planned for xFACts B2B schema to mirror Integration's configuration source. Renaming: "Entity" rather than "Client" to accurately reflect mixed entity nature (customers, vendors, internal services).

- **`B2B.INT_EntityRegistry`** — replaces the scaffolded-but-empty `B2B.INT_ClientRegistry`. Source: `tbl_B2B_CLIENTS_MN`. Approach: `sp_rename` the existing table + alter to add classification columns; update Object_Registry / Object_Metadata in place.
- **`B2B.INT_ProcessRegistry`** (new). Source: `tbl_B2B_CLIENTS_FILES`. Grain: one row per (CLIENT_ID, SEQ_ID).
- **`B2B.INT_ProcessConfig`** (new). Source: `tbl_B2b_CLIENTS_PARAM`. Grain: one row per (CLIENT_ID, SEQ_ID, PARAMETER_NAME).

DDL drafts deferred until process-type investigation is more complete.

---

## Process Type Investigation Status

Distinct PROCESS_TYPE × COMM_METHOD pairs observed in `tbl_B2B_CLIENTS_FILES` (observed-in-practice list, not authoritative lookup — new types may be added as teams configure them):

| # | PROCESS_TYPE | COMM_METHOD | Anatomy Status | Notes |
|--:|---|---|---|---|
| 1 | NEW_BUSINESS | INBOUND | ✅ Live-traced (ACADIA) | See `B2B_ProcessAnatomy_NewBusiness.md` |
| 2 | FILE_DELETION | INBOUND | ⚠️ Partially traced (ACADIA) | Path C of MAIN; SFTP remote cleanup. Anatomy doc pending team confirmation of lifecycle |
| 3 | SPECIAL_PROCESS | INBOUND | ⚠️ ProcessData seen (ACADIA EO) | Pipeline orchestration role with external Python exe; internal-op usage separately (CLIENT_ID 328) |
| 4 | ENCOUNTER | INBOUND | ⚠️ ProcessData seen (ACADIA EO) | Minimal config; GET_DOCS_DLT=Y; ENCOUNTER_MAP specific |
| 5 | PAYMENT | INBOUND | ⚠️ Prior session (PAY N SECONDS) + ProcessData seen (ACADIA EO) | Needs re-verification; multi-Client parallel case (PMT) vs. multi-Client sequential case (ACADIA EO) |
| 6 | NOTES | OUTBOUND | ⚠️ Prior session (LIVEVOX IVR) | Needs re-verification |
| 7 | RETURN | INBOUND | ❌ Not yet | |
| 8 | RETURN | OUTBOUND | ❌ Not yet | ACADIA has two outbound returns |
| 9 | RECON | INBOUND | ❌ Not yet | ACADIA SEQ_ID 4 is a prime candidate |
| 10 | RECON | OUTBOUND | ❌ Not yet | |
| 11 | REMIT | OUTBOUND | ❌ Not yet | |
| 12 | SPECIAL_PROCESS | OUTBOUND | ❌ Not yet | |
| 13 | SIMPLE_EMAIL | INBOUND | ❌ Not yet | |
| 14 | SIMPLE_EMAIL | OUTBOUND | ❌ Not yet | |
| 15 | FILE_EMAIL | INBOUND | ❌ Not yet | |
| 16 | FILE_EMAIL | OUTBOUND | ❌ Not yet | ACADIA SEQ_ID 7 example |
| 17 | NOTES | INBOUND | ❌ Not yet | |
| 18 | NOTES_EMAIL | OUTBOUND | ❌ Not yet | |
| 19 | NOTE | OUTBOUND | ❌ Not yet | Singular — possibly typo of NOTES or legitimately distinct |
| 20 | ACKNOWLEDGMENT | OUTBOUND | ❌ Not yet | |
| 21 | SFTP_PUSH | OUTBOUND | ❌ Not yet | |
| 22 | SFTP_PUSH_ED25519 | OUTBOUND | ❌ Not yet | Unusual — key algorithm elevated to process type |
| 23 | SFTP_PULL | OUTBOUND | ❌ Not yet | Unusual — PULL is typically inbound |
| 24 | BDL | INBOUND | ❌ Not yet | Bulk Data Load |
| 25 | STANDARD_BDL | INBOUND | ❌ Not yet | Relationship to BDL unclear |
| 26 | NCOA | INBOUND | ❌ Not yet | National Change of Address |
| 27 | EMAIL_SCRUB | INBOUND | ❌ Not yet | |
| 28 | ITS | OUTBOUND | ❌ Not yet | Unknown acronym |
| 29 | FULL_INVENTORY | INBOUND | ❌ Not yet | |
| 30 | CORE_PROCESS | (empty) | ❌ Not yet | Empty COMM_METHOD — possibly state-mgmt process |

**Progress:** 1 fully traced, 4 partially characterized from this session. 25 remaining.

---

## Sterling Infrastructure (Ignored by Collector)

Same as previous revision — `FileGatewayReroute`, `Schedule_*`, `TimeoutEvent`, `Alert`, `Recover.bpml`, etc. all have 0% ProcessData and are not MAIN runs.

---

## Things Clarified Since Original Planning Doc

(Cumulative list with this revision's additions marked.)

| Topic | Planning Doc Said | Now Verified |
|-------|-------------------|-------------|
| ProcessData wrapper | `<r>` | `<r>` (verified) |
| Process type field | `PROCESS_TYPE` | `PROCESS_TYPE` (verified) |
| ProcessData lookup pattern | `CREATION_DATE <= Step0.START_TIME` | `ORDER BY CREATION_DATE ASC` (created ~10 ms after Step 0) |
| Multiple DOCUMENT rows per MAIN | Implied single | Multiple exist; ProcessData is the first chronologically, others are sub-workflow outputs |
| PRE_ARCHIVE / POST_ARCHIVE | Y/N flags | Y / empty (not paths) |
| GET_DOCS_TYPE values | `SFTP_PULL` | Also `FSA_PULL` (File System Adapter) and likely others |
| Collector grain | "per workflow run" (ambiguous) | Proposed (WORKFLOW_ID, CLIENT_ID, SEQ_ID) — **but Pattern 5 complicates this; unresolved** |
| All MAIN runs are file processes | Implied | **WRONG** — MAIN serves multiple execution paths (Standard, SP Executor, SFTP Cleanup, Polling Worker) |
| FTP_FILES_LIST workflows | File scanners | Actually SP-executor Internal Operations |
| ProcessData field count | ~30 fields | ~70+ fields |
| Integration table role | Mostly deprecated | CLIENTS_MN/CLIENTS_FILES/CLIENTS_PARAM are authoritative config sources worth syncing (not for execution tracking) |
| Entity terminology | "Client" | "Entity" more accurate |
| Three identity scopes | Not addressed | Sterling Entity (CLIENT_ID) ≠ Sterling Process ((CLIENT_ID, SEQ_ID)) ≠ DM Creditor |
| **NEW: FILE_DELETION process type** | Not addressed | Remote SFTP source cleanup after file processing; Path C of MAIN |
| **NEW: Multi-Client has two modes** | Not addressed | Parallel (PMT ACH/CC) vs. Sequential Pipeline (ACADIA EO with PREV_SEQ chaining) |
| **NEW: Pattern 5 dispatcher** | Not addressed | Parallel Phased Workers — dispatcher spawns multiple MAINs with same multi-Client ProcessData |
| **NEW: PREV_SEQ meaning** | Not addressed | Sequential dependency reference for pipeline phases |
| **NEW: MAIN execution paths** | Implied monolithic | At least 3 distinct paths (Standard/SP Executor/SFTP Cleanup); possibly 4 with Polling |
| **NEW: External executable invocation** | Not addressed | `COMM_CALL_CLA_EXE_PATH` can invoke Python exes (e.g., FA_MERGE_PLACEMENT_FILES.exe for ACADIA EO orchestration) |
| **NEW: Failed MAIN runs have ProcessData** | Unknown | ✅ Verified — ProcessData written at Step 0 before failure occurs |

---

## Still Unverified — Open Investigation Items

| Item | Status | How to Resolve |
|------|--------|----------------|
| ProcessData schema | ✅ Resolved | — |
| Empty-file run behavior (Internal Op) | ✅ Resolved | — |
| ProcessData lookup pattern | ✅ Resolved | — |
| PRE_ARCHIVE/POST_ARCHIVE semantics | ✅ Resolved | — |
| Failed workflow ProcessData | ✅ Resolved (has ProcessData) | — |
| Pattern 5 multi-Client semantics | ⚠️ Partially resolved; coordination mechanism unclear | Ask Apps team; also observe a successful ACADIA EO run |
| Empty-run behavior on File Process (not Internal Op) | ❌ Not verified | Find a Pattern 1/4 File Process that fired with no files and trace |
| GET_LIST spawn count and source filter | ❌ Not verified | Walk WORKFLOW_LINKAGE from a GET_LIST root; trace GET_LIST's early steps |
| Multi-Client prevalence outside PMT, ACADIA EO | ❌ Not verified | Sample across process types |
| `AUTOMATED` field semantics | ❌ Speculative | Ask Apps team |
| `RUN_FLAG` field semantics | ❌ Speculative | Ask Apps team |
| `PREV_SEQ` enforcement | ❌ Not verified | Ask Apps team; observe successful pipeline run |
| FILE_DELETION lifecycle details (pickup → processing → cleanup timing) | ⚠️ Hypothesized based on evidence | Confirm with Apps team |
| Internal Entity IDs beyond 328 | ❌ Not verified | Build up list as encountered |
| Collector grain resolution (Pattern 5 complication) | ❌ Design question | Decide among Options A-D |
| Remaining 25 process-type anatomies | ❌ Not yet traced | Continue discovery per investigation strategy |
| `PREPARE_COMM_CALL` invocation mechanism (no marker observed) | ❌ Not verified | Inspect non-Inline Begin steps in known runs |
| `COMM_CALL_CLA_EXE_PATH` Python exe role and ownership | ❌ Not verified | Ask Apps team |

---

## Open Questions Sent to the Apps Team

Questions documented for the Apps team that, once answered, will unblock or clarify design decisions:

1. **FILE_DELETION lifecycle** — confirm SFTP remote cleanup interpretation and timing
2. **ACADIA EO pipeline coordination** — how do the 4 parallel workers coordinate phase execution
3. **`PREV_SEQ` semantics** — declarative dependency or metadata only
4. **`AUTOMATED` field values** (1 vs 2) — dispatch mechanism indicator?
5. **`RUN_FLAG` field** — lock flag, "ever run," or something else
6. **`FA_CLIENTS_GET_LIST` dispatcher** — which processes it iterates
7. **`SPECIAL_PROCESS` usage convention**
8. **External Python executable** — role of FA_MERGE_PLACEMENT_FILES.exe in ACADIA EO
9. **FILE_DELETION scope** — whether universal for SFTP-pull inbound processes
10. **Internal CLIENT_IDs inventory**
11. **Other Integration tables of interest**
12. **Legacy naming** (CLA, PV)
13. **Sterling SCHEDULE table authority**
14. **ACADIA SEQ_ID 9 mystery** (RETURN with no CLIENTS_PARAM rows)
15. **FA_PAYGROUND naming**
16. **Process type definitions** — quick descriptions of NCOA, ITS, ACKNOWLEDGMENT, CORE_PROCESS, EMAIL_SCRUB, FULL_INVENTORY, BDL vs STANDARD_BDL, REMIT, FILE_EMAIL, NOTES_EMAIL, NOTE vs NOTES

---

## Content in `B2B_Module_Planning.md` That Is Superseded

For future cleanup of the planning doc:

- Extensive field-level ProcessData documentation → now in this doc's Field Inventory
- Phase 1 SI_WorkflowTracking design → historical; superseded by Execution Tracking Grain Proposal
- Extended SI_ExecutionTracking column specification → removed pending resolution of Pattern 5 grain question
- Process Type Patterns (NB, PMT, NOTES OB sub-workflow shapes) → move to respective ProcessAnatomy docs
- CLIENT_TYPE vs PROCESS_TYPE ambiguity discussion → resolved; remove

---

## Document Relationship to Other Docs

- **`B2B_Module_Planning.md`** — direction and phase plan. Slated for cleanup.
- **`B2B_ProcessAnatomy_*.md`** — per-process-type companion documents.
- **`BPs_Flow.vsdx`** (Rober Makram, circa 2021) — historical architect's diagram. Useful foundation with known divergences from current behavior.

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Purpose | Architectural reference for Sterling B2B, shared by all Process Anatomy docs |
| Created | April 19, 2026 |
| Last Updated | April 20, 2026 |
| Status | Living document — updated iteratively as investigation progresses |
| Sources | Live `b2bi` database (FA-INT-DBP), `Integration.etl.tbl_B2B_CLIENTS_FILES`, `Integration.etl.tbl_B2b_CLIENTS_PARAM`, `BPs_Flow.vsdx` (Rober Makram), prior xFACts investigation sessions |
| Maintainer | xFACts build (Dirk + Claude collaboration) |

### Revision Log

| Date | Revision |
|------|----------|
| April 19, 2026 (initial) | Initial creation. Four-pattern dispatch model, FA_CLIENTS_MAIN as universal grain, ProcessData schema uncertainties, inbound/outbound shapes, open items. |
| April 19, 2026 (rev 2) | Empty Internal Op MAIN run traced. Run Classification dimension added. Pattern 3 reclassified as SP executors. Field inventory expanded to ~70+. |
| April 20, 2026 (rev 3) | Live NB trace (ACADIA WF 7990812). Three Identity Scopes added. Configuration Source (CLIENTS_FILES + CLIENTS_PARAM) documented. Entity naming direction. 30-process investigation inventory. |
| April 20, 2026 (rev 4) | **Major revision after FILE_DELETION trace and ACADIA EO pipeline discovery.** Additions: (1) **MAIN's Polymorphic Execution Paths** — Path A (Standard), Path B (SP Executor), Path C (SFTP Cleanup), possible Path D (Polling Worker); (2) **Pattern 5 — Parallel Phased Workers** — dispatcher spawns multiple MAINs with shared multi-Client ProcessData; (3) **Multi-Client has two modes** — parallel types (PMT) vs. sequential pipeline (ACADIA EO); (4) **`PREV_SEQ` explained** as sequential dependency reference; (5) **Failed runs have ProcessData** — verified; (6) **Grain complication from Pattern 5** — 4 workers × 4 Client blocks = 16 rows vs. 1 pipeline; Options A-D proposed; (7) **FILE_DELETION characterized** as remote SFTP source cleanup (Path C of MAIN), pending team confirmation of lifecycle; (8) **External executable invocation** (COMM_CALL_CLA_EXE_PATH) discovered; (9) Open Questions for Apps team formalized. |

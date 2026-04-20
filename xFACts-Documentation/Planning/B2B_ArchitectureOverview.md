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

**Variant: PGP-encrypted inbound NB.** Some NB configurations have `PGP_PASSPHRASE` populated, indicating the source sends PGP-encrypted files. In these cases, `FA_CLA_UNPGP` runs inside PREP_SOURCE to decrypt before translation. Observed in DENVER HEALTH NB. Absent from ACADIA NB. This is a per-entity configuration, not a separate execution path — PGP decryption is inline within Path A's PREP_SOURCE phase.

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

### Path D: File Relay / Passthrough (SFTP_PULL OUTBOUND)
MAIN performs a two-stage SFTP operation: pulls files from one SFTP endpoint and pushes them to another, with no translation or business logic in between. No FA_CLIENTS_* sub-workflow chain in the standard NB/PMT sense.

**Signature:**
- PROCESS_TYPE = SFTP_PULL
- COMM_METHOD = OUTBOUND
- FILE_FILTER populated
- GET_DOCS_TYPE = SFTP_PULL with GET_DOCS_LOC set
- PUT_DOCS_TYPE = SFTP_PUSH with PUT_DOCS_LOC set
- TRANSLATION_MAP empty
- Processing flags empty (no PREPARE_SOURCE, no WORKERS_COMP, no DUP_CHECK)
- `SEND_EMPTY_FILES=Y` commonly set (sends the push even if nothing was pulled)
- Multi-Client Case 1 is common: one MAIN run often carries 2 Client blocks for different file-pattern pairs from the same entity

**Examples:** COACHELLA VALLEY ANESTHESIA (CLIENT_ID 10745, SEQ_ID 5+6), MSN HEALTHCARE SOLUTION (CLIENT_ID 10734, SEQ_ID 10+11). Both observed failing at 04:00:04 on SSH_DISCONNECT.

**Note on naming:** `PROCESS_TYPE = SFTP_PULL` describes what the process *does* (an SFTP pull operation) rather than a direction. `COMM_METHOD = OUTBOUND` indicates the pulled file's final destination is outbound to another SFTP endpoint.

### Path E: Short-Circuit (Minimal Work)
MAIN runs that invoke `FA_CLIENTS_GET_DOCS` and `FA_CLIENTS_COMM_CALL` but not the full file-processing stack. Low step counts (16-33 observed) and short durations.

**Example (WF 7999286, ACADIA EO worker on 2026-04-20):**
- Invoked `FA_CLIENTS_GET_DOCS` at step 9, ended at step 14 (immediate return, likely no files)
- Invoked `FA_CLIENTS_COMM_CALL` at step 25, ended at step 30
- 33 total steps, 2.2 second duration
- No TRANS, no ACCOUNTS_LOAD, no FILE_MERGE, no DUP_CHECK, etc.

**Interpretation (tentative):** MAIN entered its processing flow, attempted a GET_DOCS for its assigned Client block, found nothing to retrieve, and proceeded directly to a degenerate COMM_CALL before exiting. Not a pure "poll and exit" pattern as originally hypothesized — the worker did enter processing logic, but had nothing to process.

**Distinction from Path B (SP Executor):** Path B has POST_TRANSLATION in its flow and CLIENT_ID=328. Path E has the standard entity CLIENT_ID and no POST_TRANSLATION call.

**Implication for the collector:** these are legitimate "no work happened" runs for real entities. They should probably be captured in execution tracking but clearly flagged as `did_work = false` or equivalent.

---

## Dispatch Patterns

`FA_CLIENTS_MAIN` is never a root. It is always invoked by something. Five distinct dispatch patterns have been observed.

**Important distinguishing principle:** Simultaneous MAIN starts are NOT sufficient to identify Pattern 5. Scheduling collision between independent dispatchers is common (many entities have 04:00, 05:00, or other round-hour schedules). Multiple MAIN children starting at the same second may be:
- Two or more independent Pattern 4 pullers on colliding schedules (each spawning their own children), OR
- A single Pattern 5 dispatcher spawning coordinated workers

The distinguishing feature of Pattern 5 is **shared multi-Client ProcessData across the worker set**, NOT simultaneous start time. Always check WORKFLOW_LINKAGE to confirm a common parent before classifying.

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

`FA_CLIENTS_GET_LIST` fires hourly at :05 past the hour. It iterates configured processes (likely by reading CLIENTS_FILES + CLIENTS_PARAM), and invokes `FA_CLIENTS_MAIN` for each.

**Observed spawn counts** (7-hour window on April 20):

| Hour | Children Spawned |
|------|-----------------:|
| 05:05 | 164 |
| 09:05 | 59 |
| 07:05 | 29 |
| 08:05 | 27 |
| 10:05 | 18 |
| 06:05 | 13 |

Spawn count varies dramatically by hour. 05:05 is a peak dispatch window. Pattern needs further investigation to understand what GET_LIST iterates vs. what the named workflows handle independently.

### Pattern 3 — Periodic Internal Operation Scanner

A periodic workflow (`FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` and its `_ARC` variant) fires every ~10 minutes and invokes MAIN to execute Integration stored procedures. **These are Internal Operations (Path B of MAIN), not file scanners.**

**Note:** Despite the "FTP_FILES_LIST" name suggesting file scanning, these workflows do NOT scan FTP folders for customer files. The names are literal descriptions of the Integration stored procedures they execute.

### Pattern 4 — Periodic Puller

Entity-specific puller workflows (`FA_FROM_*_PULL`) fire on entity schedules, pull files via SFTP, and invoke MAIN per file found (or once per configured process for multi-SEQ setups).

**Examples:**
- `FA_FROM_REVSPRING_IB_BD_PULL`: 14 runs per day
- `FA_FROM_ACCRETIVE_IB_BD_PULL`: observed spawning **12 MAIN children** in a single invocation on April 20 (high-volume day)
- `FA_FROM_MONUMENT_HEALTH_IB_EO_PULL`: consistently spawns 7 children per invocation (observed at 07:30, 08:30, 09:30)
- `FA_FROM_COACHELLA_VALLEY_ANESTHESIA_IB_BD_SFTP_PULL`: spawns 2 MAIN children per invocation (one per configured SEQ_ID; SEQ 5 and SEQ 6 run as parallel children)

**Characteristics:**
- Each puller has its own schedule
- Can spawn 1 or many MAINs per invocation (observed 1-12+)
- Children can be near-simultaneous (<1 sec spread) OR spread over time, depending on the puller's internal loop logic
- These are File Processes (usually Path A or Path D of MAIN)

### Pattern 5 — Multi-Worker Dispatch with Shared Multi-Client ProcessData

**A dispatcher workflow fires MULTIPLE MAIN children (always 4 observed), each carrying the same multi-Client ProcessData.** The workers execute *different* sub-workflow sequences despite identical ProcessData input, which means something — not yet identified — causes each worker to process a different portion of the shared configuration.

**Known Pattern 5 dispatchers:** `FA_FROM_ACADIA_HEALTHCARE_IB_EO`. No others confirmed. Several other EO workflows dispatch multiple children but may be Pattern 4 multi-SEQ rather than Pattern 5.

**Canonical observation (WF 7999275, 2026-04-20 10:00):**

The dispatcher itself ran briefly (49 steps, 8 seconds) and spawned 4 MAIN children within 237ms:

| Worker | Started | Duration | Steps | First Inline Begin | Activity |
|---|---|---|---|---|---|
| 7999286 | 10:00:08.673 | 2.2 sec | 33 | GET_DOCS @ step 9 | GET_DOCS + COMM_CALL only (Path E — short-circuit) |
| 7999287 | 10:00:08.770 | 92 sec | 152 | GET_DOCS @ step 12 | Full NB pattern (GET_DOCS, ARCHIVE, PREP_SOURCE, TRANS, ACCOUNTS_LOAD, FILE_MERGE, WORKERS_COMP, DUP_CHECK, PREP_COMM_CALL, COMM_CALL) |
| 7999288 | 10:00:08.847 | 173 sec | 137 | GET_DOCS @ step 15 | Abbreviated pattern (GET_DOCS, ARCHIVE, PREP_SOURCE, TRANS, FILE_MERGE, PREP_COMM_CALL, COMM_CALL) — NO ACCOUNTS_LOAD, NO WORKERS_COMP, NO DUP_CHECK |
| 7999289 | 10:00:08.910 | 258 sec | 91 | GET_DOCS @ step 18 | Only GET_DOCS and ARCHIVE visible in Inline Begin markers; long runtime suggests substantial non-Inline work (e.g., long-running ENCOUNTER_LOAD child) |

### Observations That Don't Yet Add Up

**1. Workers do different things despite identical ProcessData.** Worker 7999287 ran the full NB pattern. Worker 7999288 ran a pattern missing the NB-distinctive ACCOUNTS_LOAD/WORKERS_COMP/DUP_CHECK steps. Worker 7999289 barely invoked any sub-workflows in Inline Begin markers. Worker 7999286 short-circuited. Same ProcessData input → four different execution paths.

**2. Workers activate sequentially with ~90-second offsets.** All 4 started within 237ms but their first `FA_CLIENTS_GET_DOCS` invocations were staggered:
- 7999286: GET_DOCS at start+2 sec
- 7999287: GET_DOCS at start+72 sec
- 7999288: GET_DOCS at start+161 sec
- 7999289: GET_DOCS at start+251 sec

That's ~90 seconds between activations, linearly. Something external is controlling when each worker begins processing. Between start and their first GET_DOCS, the workers are presumably polling JDBC state or waiting on coordination signals — the exact mechanism is not visible in Inline Begin markers and has not been traced.

**3. Pattern 5 does not always exhibit this behavior.** The April 19 ACADIA EO observation showed 4 workers with step counts 16/19/21/33 — all four short. Either that was a "nothing to do today" day, or the coordination mechanism behaves differently under different conditions. Without a broader sample we can't distinguish.

**4. WORKFLOW_LINKAGE shows non-inline sub-workflow children.** In the WF 7999275 tree, 10 additional WORKFLOW_IDs appear as children of the 4 workers:
- Worker 7999287: 4 children (VITAL, ENCOUNTER_LOAD, ARCHIVE x2)
- Worker 7999288: 4 children (VITAL, ENCOUNTER_LOAD, ARCHIVE x2)
- Worker 7999289: 2 children (VITAL, ENCOUNTER_LOAD)

These are sub-workflows invoked via `InvokeBusinessProcessService` (not inline), each of which gets its own WORKFLOW_ID. Their presence does not mean the worker is processing "ENCOUNTER data" — it means that somewhere in the worker's flow (possibly deep inside ACCOUNTS_LOAD or similar), these sub-workflows were invoked.

### What Remains Unknown

- **How workers differentiate their work.** Four workers with identical ProcessData should execute identically. They don't. Something outside ProcessData is assigning work — but what, and where that assignment is stored, is unclear.
- **What the workers do during their pre-activation wait.** The 90-second intervals before first GET_DOCS are not represented in Inline Begin markers. Likely JDBC polling or shared-state checks, but not confirmed.
- **Whether the 4-worker count is always 4 or varies.** Observed 4 twice (April 19 and April 20). Sample size too small.
- **How failures in one worker affect the others.** If worker 7999288 had failed, would 7999289 still activate 90 seconds later? Would the tree's overall STATUS reflect partial completion?
- **The meaning of `PREV_SEQ`.** The ProcessData's 4 Client blocks have PREV_SEQ chaining (2→1, 3→2, 8→3). Whether Sterling enforces this declaratively or it's documentation/metadata is not determined.

### Implication for Collector Grain

The grain question (one row per Client block × one row per worker = up to 16 rows for a single conceptual pipeline run) is **still unresolved and is now more nuanced**:

- If the 4 workers each process a DIFFERENT Client block, then there's really only 1 row of meaningful work per Client block. But how to identify which worker did which Client block is unclear.
- If the 4 workers all share state and coordinate, the "one row per worker per Client block" grain creates 16 rows where some are real and some are ghost/empty.

**Options A-D (see Execution Tracking Grain Proposal section) are still in play.** The new data does not conclusively favor one option over another, but **Option D** ("write only the Client block that actually did work, detected by sub-workflow invocations") looks more appealing now that we can see worker 7999286 clearly didn't do real work while 7999287 clearly did.

### Honest Assessment

Pattern 5 is the least-understood dispatch pattern. The mechanism that differentiates the 4 workers' behavior is not visible in ProcessData, not visible in WORKFLOW_CONTEXT's Inline Begin markers, and not (so far) resolvable without either:
- Reading the `FA_CLIENTS_MAIN` BPML definition directly from `DATA_TABLE`
- Direct explanation from someone who built the ACADIA EO workflow
- More traces across varied conditions to see what changes

This is a known gap in our architecture understanding. It's documented here to avoid further speculation.

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

**Updated observation (April 20):** 679 MAIN runs in a 7-hour window projects to ~2,300 per day — volume is notably higher on some days than the 820/day sample above.

**Why FA_CLIENTS_VITAL has more runs than MAIN:** VITAL is a sub-workflow invoked inside ACCOUNTS_LOAD. It shows in WF_INST_S because each VITAL invocation has its own WORKFLOW_ID. The ratio varies with daily file volume (higher ratio = more multi-file NB runs).

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

Outer element is `<r>`. Multiple `<Client>` blocks may appear (multi-Client).

**Process type field:** `<PROCESS_TYPE>` (sourced from CLIENTS_FILES). Rober's Visio showed `<CLIENT_TYPE>` — older schema since renamed.

### Multi-Client ProcessData — Two Distinct Meanings

Multi-Client ProcessData appears in two fundamentally different scenarios:

**Case 1 — Parallel file patterns for one entity**
One MAIN run processes multiple configured SEQs for the same entity, typically because the entity sends multiple file types that should be handled together. Examples:
- PAY N SECONDS: 2 Client blocks — ACH payments and credit card payments processed in one MAIN run
- COACHELLA VALLEY ANESTHESIA (SFTP_PULL OUTBOUND): 2 Client blocks (SEQ_ID 5 and 6) with different file filters and pull paths
- MSN HEALTHCARE SOLUTION (SFTP_PULL OUTBOUND): 2 Client blocks (SEQ_ID 10 and 11)

In Case 1, all Client blocks fire in one MAIN run; `PREV_SEQ` is empty.

**Case 2 — Sequential pipeline phases (ACADIA EO)**
ACADIA EO has 4 Client blocks linked by `PREV_SEQ`: SPECIAL_PROCESS (orchestration) → NEW_BUSINESS → PAYMENT → ENCOUNTER. These are **sequential phases** of a pipeline, not parallel types. The dispatcher (`FA_FROM_ACADIA_HEALTHCARE_IB_EO`) spawns **multiple parallel MAIN workers, all sharing the same 4-Client ProcessData** (Pattern 5), and the workers coordinate via JDBC to execute the phases.

**Distinguishing the two cases:**
- Case 1: all Client blocks fire in one MAIN run; `PREV_SEQ` empty
- Case 2: `PREV_SEQ` populated linking blocks sequentially; dispatcher fires multiple MAIN workers with the same ProcessData

**Collector implication:** the grain of "(WORKFLOW_ID, CLIENT_ID, SEQ_ID) = one row" breaks in Case 2. If 4 MAIN workers each carry 4 Client blocks, naive grain creates 16 rows for what's conceptually 4 phases of 1 pipeline run. **This is a known design question requiring resolution before collector build.**

### PREV_SEQ Field

`PREV_SEQ` is a **sequential dependency reference**. A Client block with `PREV_SEQ=1` says "this phase depends on phase SEQ_ID 1 completing first."

Whether Sterling enforces this or it's metadata-only is unclear — **to be verified with the Apps team.**

### Failed Runs Have ProcessData

When a MAIN workflow fails (STATUS=1), ProcessData is still written at Step 0, BEFORE the failure occurs. The collector can extract ProcessData for failed runs normally — observed across multiple failure types (PGP decrypt failure, SSH disconnect, translation errors).

### Failure Signal — Nuanced

The architecture doc previously said "the failing step has `BASIC_STATUS > 0`." This is true but incomplete. Real failure detection requires understanding three things:

**1. The reported failure step** — the step where `BASIC_STATUS` first becomes > 0. This is where Sterling records the failure state transition. Example: in a DENVER HEALTH NB failure, step 77 (Translation) had `BASIC_STATUS=1`.

**2. The root cause step** — may be earlier than the reported failure, and may have `BASIC_STATUS=0` despite being the real cause. Some services encode errors in `ADV_STATUS` without setting `BASIC_STATUS`. Example: in that same DENVER HEALTH failure, step 54 (`FA_CLA_UNPGP`) had `BASIC_STATUS=0` but `ADV_STATUS="255"` — the PGP decrypt exit code, which is the actual root cause. The later Translation failure was a downstream consequence of having nothing to translate.

**3. Base Sterling services can fail directly** — services like `SFTPClientBeginSession`, `AS3FSAdapter`, `AS2LightweightJDBCAdapter`, and `Translation` are base Sterling services, not FA_CLIENTS_* sub-workflows. They do NOT have `Inline Begin` markers. Failures at this level show up in `WORKFLOW_CONTEXT` but scanning only for sub-workflow invocations will miss them.

**Collector implication:** capture the failure **span** — the first error-coded step (by ADV_STATUS or BASIC_STATUS) through the final BASIC_STATUS>0 step. Record both the root cause step and the reported failure step. Don't rely solely on `BASIC_STATUS > 0`.

### Known Fields (Partial Inventory — ~70+ fields)

(Full list as in previous revisions — sections on Identity, Process categorization, File input/output, Translation, SQL hooks, Sub-workflow flags, Archive, Processing helpers, Notification, Executable paths, Custom BP hooks, DM config.)

**Recently observed fields:**
- `PREV_SEQ` — sequential phase dependency reference
- `COMM_CALL_CLA_EXE_PATH` — external executable invocation. Observed value: `\\kingkong\Data_Processing\Pervasive\Python_EXE_files\FA_PAYGROUND\FA_MERGE_PLACEMENT_FILES.exe $0 $1 $2 $3`. Sterling can invoke external Python executables during COMM_CALL phase for SPECIAL_PROCESS pipeline orchestration.
- `COMM_CALL_WORKING_DIR` — working directory for the external exe
- `MISC_REC1` (more context) — observed as pipe-delimited FILE_FILTER list for SPECIAL_PROCESS pipeline orchestration: `acadia.2*FEOPF2*|acadia.2*FEOTRN*|acadia.2*FEOPFT*`
- `GET_DOCS_DLT` — delete-after-get flag. Values observed include `Y`, specific path strings like `/Archive/`, or empty.
- `ENCOUNTER_MAP` — specific translation map for ENCOUNTER process type
- `SEND_EMPTY_FILES` — whether to push even if no file was pulled (observed in SFTP_PULL OUTBOUND)
- `GET_DOCS_PROFILE_ID` / `PUT_DOCS_PROFILE_ID` — references to stored SFTP connection profiles

### PRE_ARCHIVE / POST_ARCHIVE Semantics

Current Sterling uses `Y` / empty (and possibly `N` explicitly) for these fields. Paths in Rober's 2021 Visio were dev-environment configurations, not production.

### Sensitive Data in ProcessData

**ProcessData may contain credentials in plaintext.** Observed sensitive fields:

- `PGP_PASSPHRASE` — populated for entities sending PGP-encrypted files. Contains the decryption passphrase in plaintext. Example observed: DENVER HEALTH NB.
- Other plaintext secrets (e.g., Python API keys) have been seen in Integration-side artifacts and may also appear in ProcessData fields.

**Implications for architecture:**
- Any raw ProcessData persistence (e.g., `SI_ProcessDataCache`) will copy credentials from Sterling's own data into xFACts
- This extends the credential footprint — backups, disaster-recovery copies, user access, support screenshots all become potential exposure surfaces
- Even for internal systems, stored plaintext credentials typically require tighter access controls, audit logging, and explicit treatment in data-handling policies

**Design options for `SI_ProcessDataCache` to be decided before build:**
- **Redact known sensitive fields** before persistence (field allowlist — parse, strip sensitive tags, re-serialize)
- **Store only a parsed field subset** (never the raw XML)
- **Encrypt raw XML at rest** (column-level encryption or equivalent)
- **Shorten retention** (days rather than indefinite) for raw ProcessData
- Combination of the above

This is a new open design question — see Open Design Questions section.

### Storage Strategy

The field inventory is large (~70 fields) and mostly empty per run. Strategy for `SI_ProcessDataCache` pending resolution of the credential handling question above.

---

## Empty-Run and Short-Run Behavior

Multiple varieties of "nothing happened" MAIN runs have been observed:

**~49-step Internal Operation skeleton** (CLIENT_ID=328 SP executors): GET_DOCS → POST_TRANSLATION → PREP_COMM_CALL → COMM_CALL, all degenerate. No real work.

**~16-step Polling Worker** (ACADIA EO phased workers that didn't pick up work): No sub-workflows at all. JDBC checks + waits + decisions + exit.

**Failed runs** (varies): step count depends on when the failure occurs. ProcessData is written normally. The failing step's `BASIC_STATUS` and `ADV_STATUS` identify the failure (with caveats — see Failure Signal section).

**Real File Processes with no files** (Pattern 1 scheduled runs that find nothing): not yet explicitly traced, but expected to resemble the Internal Op skeleton.

**Collector implication:** "no work happened" is not a single condition. Different short-run signatures correspond to different reasons. The collector should probably capture:
- Count of `FA_CLIENTS_TRANS` invocations — if 0, no data was translated
- Count of each major sub-workflow invocation
- Whether any step has `BASIC_STATUS > 0` or anomalous `ADV_STATUS` — failure signal

---

## Known Failure Modes

Catalog of concrete failures observed during investigation. Not exhaustive — additions as new modes are encountered.

### SSH_DISCONNECT_BY_APPLICATION at SFTPClientBeginSession

**Signature:**
- Step ~12, `SERVICE_NAME = SFTPClientBeginSession`, `BASIC_STATUS = 1`
- `ADV_STATUS = "com.sterlingcommerce.perimeter.api.ClosedConduitException:SSH_DISCONNECT_BY_APPLICATION:SFTP session channel closed by server."`
- Workflow aborts the GET_DOCS phase entirely

**Cause:** remote SFTP server actively closing the SSH session during connection. Could originate server-side (remote maintenance windows, keep-alive rejection, IP blocking) or Sterling-side (certificate/key issues, connection pool exhaustion, network appliance disruption).

**Observed clustering** (24-hour sample, April 19-20):

| Hour of Day | Affected Workflows | Failure Step Instances |
|-------------|-------------------:|----------------------:|
| 04 | 4  | 8  |
| 10 | 2  | 4  |
| 16 | 12 | 24 |

The 16:00 hour is the largest observed cluster. Clustering at hours 6 apart (04, 10, 16) is suggestive but not fully understood — could indicate remote-server scheduled activity or Sterling-side periodic events. **Worth monitoring.**

**Scope note:** SFTPClientBeginSession is a base Sterling service, not a FA_CLIENTS_* sub-workflow. It has NO `Inline Begin` marker. Scanning only for sub-workflow invocations will miss this failure.

### FA_CLA_UNPGP Exit Code 255

**Signature:**
- Step ~54 (within PREP_SOURCE phase), `SERVICE_NAME = FA_CLA_UNPGP`, `BASIC_STATUS = 0`, `ADV_STATUS = "255"`
- Step ~55: `AS3FSAdapter` with `ADV_STATUS = "No files to collect"`
- Later in the workflow: Translation fails with `BASIC_STATUS = 1`

**Cause:** PGP decryption via `FA_CLA_UNPGP` command-line adapter failed. 255 is a generic process failure exit code. Possible underlying causes:
- Source sent corrupted PGP file
- Source sent a non-encrypted file when encrypted was expected
- Pulled file is truncated or zero-byte
- PGP passphrase no longer matches source's signing key

**Only applies to configurations where `PGP_PASSPHRASE` is populated** in ProcessData. Observed on DENVER HEALTH NB.

**Critical detection nuance:** The root cause step has `BASIC_STATUS = 0`. The `BASIC_STATUS > 0` signal only fires later at Translation. Collectors scanning for `BASIC_STATUS > 0` will detect the workflow failed but will point to the wrong step.

---

## Inbound vs. Outbound — Different Sub-Workflow Shapes

Per the Visio (Pages 2 and 3), inbound and outbound MAIN execute materially different sub-workflow sequences. Live observation confirms the general structure but with some differences from the 2021 diagram.

(Previous details on inbound/outbound shapes retained from prior revisions; see `B2B_ProcessAnatomy_NewBusiness.md` for the verified inbound sub-workflow shape with 14-iteration loop pattern.)

---

## Execution Tracking Grain Proposal (with Known Complication)

Based on the Three Identity Scopes, execution tracking needs at least a two-level grain.

### Header Level — `SI_ExecutionTracking` (sketch)

**Proposed grain:** one row per `(WORKFLOW_ID, CLIENT_ID, SEQ_ID)` from ProcessData.

**Known complication:** Pattern 5 (Multi-Worker Dispatch with Shared Multi-Client ProcessData) breaks this grain. Four concurrent MAIN workers each carrying 4 Client blocks = up to 16 rows for 1 conceptual pipeline invocation. **This needs resolution before collector build.**

Possible resolutions (to discuss):
- **Option A:** Accept redundancy. Write 16 rows. Add a `root_workflow_id` column for clustering and a `did_work` flag for filtering. Aggregate views roll up.
- **Option B:** Write one row per unique (ROOT_WF_ID, CLIENT_ID, SEQ_ID), with the collector responsible for deduplicating across sibling workers. More complex collector logic but cleaner data.
- **Option C:** Change grain to one row per WORKFLOW_ID (regardless of Client count), with Client details in a child table. Deviates from the original design but handles Pattern 5 naturally.
- **Option D:** Keep current grain for Patterns 1-4, but for Pattern 5 only write the Client block that actually did work (detected by which worker had sub-workflow invocations). More complex but most semantically clean. **Current leaning** based on the WF 7999275 trace — we saw clearly idle workers (7999286 short-circuited) alongside working ones (7999287 ran full NB), and capturing only the working ones avoids 16 rows of mostly-noise.

No decision yet. **Open design question.**

### Columns (preliminary):
- `workflow_id`, `parent_workflow_id`, `root_workflow_id`
- `client_id`, `seq_id`, `client_name`
- `process_type`, `comm_method`, `business_type`
- `translation_map`, `file_filter`, `get_docs_type` (targeted subset of ProcessData)
- `run_class` (FILE_PROCESS / INTERNAL_OP / UNCLASSIFIED)
- `execution_path` (STANDARD / SP_EXECUTOR / SFTP_CLEANUP / FILE_RELAY / POLLING_EXIT) — reflects MAIN's polymorphic paths
- `file_count` — derived from TRANS invocation count
- `workflow_start_time`, `workflow_end_time`, `duration_ms`
- `status`, `state`, `status_message`, `failure_step_id`, `failure_service_name`, `root_cause_step_id`, `root_cause_service_name`
- `had_trans`, `had_vital`, `had_accounts_load` — sub-workflow invocation flags
- `collected_dttm`, `processdata_cache_id`

### Detail Level — `SI_ExecutionDetail` (Deferred to Phase 2)

Grain: one row per `(WORKFLOW_ID, CLIENT_ID, SEQ_ID, FILE_INDEX, DM_CREDITOR_KEY)`. Source: Translation output XML parsed per MAIN run. Build first at header level; add detail when that's validated.

### ProcessData Cache — `SI_ProcessDataCache`

Grain: one row per MAIN run. Preserves decompressed XML. **See "Sensitive Data in ProcessData" above for credential-handling design options.**

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
| 1 | NEW_BUSINESS | INBOUND | ✅ Live-traced (ACADIA), ⚠️ PGP variant (DENVER HEALTH) | See `B2B_ProcessAnatomy_NewBusiness.md`. PGP variant needs separate documentation. |
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
| 23 | SFTP_PULL | OUTBOUND | ⚠️ Characterized (COACHELLA VALLEY, MSN HEALTHCARE) | File relay/passthrough — Path D of MAIN. Often Multi-Client Case 1 (2+ Client blocks per MAIN). |
| 24 | BDL | INBOUND | ❌ Not yet | Bulk Data Load |
| 25 | STANDARD_BDL | INBOUND | ❌ Not yet | Relationship to BDL unclear |
| 26 | NCOA | INBOUND | ❌ Not yet | National Change of Address |
| 27 | EMAIL_SCRUB | INBOUND | ❌ Not yet | |
| 28 | ITS | OUTBOUND | ❌ Not yet | Unknown acronym |
| 29 | FULL_INVENTORY | INBOUND | ❌ Not yet | |
| 30 | CORE_PROCESS | (empty) | ❌ Not yet | Empty COMM_METHOD — possibly state-mgmt process |

**Progress:** 1 fully traced (NB baseline), 6 partially characterized (FILE_DELETION, SPECIAL_PROCESS, ENCOUNTER, PAYMENT, NOTES OB, SFTP_PULL OB). 23 remaining.

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
| All MAIN runs are file processes | Implied | **WRONG** — MAIN serves multiple execution paths (Standard, SP Executor, SFTP Cleanup, File Relay, Polling) |
| FTP_FILES_LIST workflows | File scanners | Actually SP-executor Internal Operations |
| ProcessData field count | ~30 fields | ~70+ fields |
| Integration table role | Mostly deprecated | CLIENTS_MN/CLIENTS_FILES/CLIENTS_PARAM are authoritative config sources worth syncing (not for execution tracking) |
| Entity terminology | "Client" | "Entity" more accurate |
| Three identity scopes | Not addressed | Sterling Entity (CLIENT_ID) ≠ Sterling Process ((CLIENT_ID, SEQ_ID)) ≠ DM Creditor |
| FILE_DELETION process type | Not addressed | Remote SFTP source cleanup after file processing; Path C of MAIN |
| Multi-Client has two modes | Not addressed | Parallel (PMT, SFTP_PULL OB) vs. Sequential Pipeline (ACADIA EO with PREV_SEQ chaining) |
| Pattern 5 dispatcher | Not addressed | Parallel Phased Workers — dispatcher spawns multiple MAINs with same multi-Client ProcessData. ACADIA EO confirmed as Pattern 5. |
| PREV_SEQ meaning | Not addressed | Sequential dependency reference for pipeline phases |
| MAIN execution paths | Implied monolithic | At least 5 distinct paths (Standard/SP Executor/SFTP Cleanup/File Relay/Polling) |
| External executable invocation | Not addressed | `COMM_CALL_CLA_EXE_PATH` can invoke Python exes (e.g., FA_MERGE_PLACEMENT_FILES.exe for ACADIA EO orchestration) |
| Failed MAIN runs have ProcessData | Unknown | ✅ Verified — ProcessData written at Step 0 before failure occurs |
| **NEW: Path D (File Relay)** | Not addressed | SFTP_PULL OUTBOUND processes — pull-then-push with no translation. Observed COACHELLA VALLEY and MSN HEALTHCARE. |
| **NEW: PGP decryption in NB** | Not addressed | Some NB configs use `FA_CLA_UNPGP` within PREP_SOURCE when `PGP_PASSPHRASE` is populated (DENVER HEALTH observed). |
| **NEW: ProcessData contains plaintext credentials** | Not addressed | `PGP_PASSPHRASE` stored in plaintext. Design question for `SI_ProcessDataCache` around credential handling. |
| **NEW: Failure signal nuance** | Simple "BASIC_STATUS > 0" | Root cause may have `BASIC_STATUS=0` with error-coded `ADV_STATUS`. Collector needs to capture the failure span, not just the reported failure step. |
| **NEW: Base services fail without Inline markers** | Not addressed | SFTPClientBeginSession, AS3FSAdapter, Translation, etc. fail directly. Scanning for Inline Begin markers alone will miss these. |
| **NEW: Scheduling collision** | Not addressed | Multiple independent Pattern 4 dispatchers often collide at round-hour schedules. Simultaneity does not imply Pattern 5. |
| **NEW: Pattern 2 spawn counts** | Rough estimate | Measured 13-164 children per GET_LIST run; 05:05 is peak. |

---

## Still Unverified — Open Investigation Items

| Item | Status | How to Resolve |
|------|--------|----------------|
| 🎯 **`FA_CLIENTS_MAIN` BPML read** (next-session priority) | ❌ Pending — highest-leverage action | Query WFD_XML for WFD_ID=798, pull compressed XML from DATA_TABLE.DATA_OBJECT, decompress. Inspect branching logic for Path A-E divergence and Pattern 5 worker coordination. Time-boxed 45 min. |
| ProcessData schema | ✅ Resolved | — |
| Empty-file run behavior (Internal Op) | ✅ Resolved | — |
| ProcessData lookup pattern | ✅ Resolved | — |
| PRE_ARCHIVE/POST_ARCHIVE semantics | ✅ Resolved | — |
| Failed workflow ProcessData | ✅ Resolved (has ProcessData) | — |
| Pattern 5 coordination mechanism | ❌ Investigation ceiling hit via queries alone | BPML read (top of this table). Possibly unresolvable otherwise — original architect is gone. |
| Empty-run behavior on File Process (not Internal Op) | ❌ Not verified | Find a Pattern 1/4 File Process that fired with no files and trace |
| GET_LIST spawn count and source filter | ⚠️ Counts measured (13-164/run); source filter unknown | Walk WORKFLOW_LINKAGE from a GET_LIST root; trace GET_LIST's early steps |
| Multi-Client prevalence outside PMT, ACADIA EO, SFTP_PULL OB | ❌ Not verified | Sample across process types |
| `AUTOMATED` field semantics | ❌ Speculative | Ask Apps team (low-confidence they'll know) |
| `RUN_FLAG` field semantics | ❌ Speculative | Ask Apps team (low-confidence they'll know) |
| `PREV_SEQ` enforcement | ❌ Not verified | Likely answered by BPML read; also observe successful pipeline run |
| FILE_DELETION lifecycle details (pickup → processing → cleanup timing) | ⚠️ Hypothesized based on evidence | Confirm with Apps team |
| Internal Entity IDs beyond 328 | ❌ Not verified | Build up list as encountered |
| Collector grain resolution (Pattern 5 complication) | ❌ Design question | Commit after BPML read — Option D preferred, Option A fallback |
| Remaining process-type anatomies | ❌ Not yet traced | Continue discovery as operationally needed; no longer a build prerequisite |
| `PREPARE_COMM_CALL` invocation mechanism (no marker observed) | ❌ Not verified | Likely answered by BPML read |
| `COMM_CALL_CLA_EXE_PATH` Python exe role and ownership | ❌ Not verified | Ask Apps team |
| SSH_DISCONNECT clustering pattern (hours 04, 10, 16) | ⚠️ Dispatcher-level data captured | Check `GET_DOCS_PROFILE_ID` across affected dispatchers to test "shared Sterling-side SFTP profile" hypothesis |
| ProcessData credential handling for SI_ProcessDataCache | ❌ Design question | Decide among redact / parsed-subset-only / encrypt-at-rest / short-retention options |

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

- **`B2B_Module_Planning.md`** — direction and phase plan.
- **`B2B_ProcessAnatomy_*.md`** — per-process-type companion documents.
- **`B2B_Reference_Queries.md`** — investigation queries and snippets.
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
| April 20, 2026 (rev 4) | Major revision after FILE_DELETION trace and ACADIA EO pipeline discovery. Added MAIN's Polymorphic Execution Paths (A/B/C/possible D), Pattern 5 Parallel Phased Workers, Multi-Client two modes, PREV_SEQ, failure ProcessData, grain complication, FILE_DELETION as Path C, external executable invocation, Apps team questions formalized. |
| April 20, 2026 (rev 5) | **Major revision from failure trace session (WF 7998314 DENVER HEALTH NB, and WFs 7994488-7994491 SFTP_PULL OUTBOUND failures).** Additions: (1) **Path D introduced** — SFTP_PULL OUTBOUND file relay/passthrough. Moved former "Polling Worker" to Path E. (2) **NB PGP variant** documented — `FA_CLA_UNPGP` decryption step within PREP_SOURCE when `PGP_PASSPHRASE` is populated. (3) **Known Failure Modes section** — SSH_DISCONNECT_BY_APPLICATION (with 24-hour clustering data: 04/10/16 hours) and FA_CLA_UNPGP exit 255. (4) **Failure signal nuance** — root cause step may have BASIC_STATUS=0 with error in ADV_STATUS; collector must capture failure span. (5) **Base services fail without Inline markers** — SFTPClientBeginSession, AS3FSAdapter, Translation are direct failure points. (6) **Scheduling collision** explicitly called out as NOT Pattern 5. (7) **Pattern 2 spawn counts measured** (13-164/run). (8) **Pattern 4 Multi-SEQ behavior** documented. (9) **ProcessData credential exposure** — PGP_PASSPHRASE stored plaintext; design question for SI_ProcessDataCache. (10) Multiple `execution_path` values proposed including FILE_RELAY. (11) Process type #23 (SFTP_PULL OB) promoted from ❌ to ⚠️. |
| April 20, 2026 (rev 6) | **Major revision from ACADIA EO Pattern 5 trace (WF 7999275).** Substantial rewrite of Pattern 5 section with honest "what we observed vs. what remains unknown" framing. Key findings: (1) **Workers execute different sub-workflow patterns despite identical ProcessData** — observed full NB pattern on one worker, abbreviated pattern on another, short-circuit on a third. (2) **Workers activate sequentially with ~90-second offsets** — all 4 start within 237ms but their first GET_DOCS invocations are staggered 72/161/251 seconds after start. Something external controls activation timing. (3) **Non-inline sub-workflow invocations appear as separate rows in WORKFLOW_LINKAGE** — VITAL, ENCOUNTER_LOAD, and ARCHIVE children get their own WORKFLOW_IDs. (4) **Path E reclassified** from "Polling Worker" to "Short-Circuit (Minimal Work)" based on observed behavior — worker 7999286 did invoke GET_DOCS and COMM_CALL (not pure poll/exit as previously hypothesized). (5) **Previous "self-select phase via JDBC" hypothesis withdrawn** in favor of honest "coordination mechanism is not visible in our data." (6) **Grain question deepened** — Option D (only write the Client block that did real work) looks more attractive given evidence of clearly idle workers. (7) **Ceiling on investigation acknowledged** — full Pattern 5 understanding likely requires reading the FA_CLIENTS_MAIN BPML definition or direct knowledge from the ACADIA EO workflow's author. Pattern 5 coordination mechanism now explicitly documented as an unresolved gap rather than a hypothesis pending team confirmation. (8) **BPML read added as top-priority investigation item** with specific guidance on what to look for — referenced in planning doc as next-session priority. |

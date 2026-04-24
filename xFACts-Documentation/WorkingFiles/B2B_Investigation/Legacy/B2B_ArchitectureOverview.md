> ### ⚠️ Deprecated — Reference Only
>
> **This document was written during the initial (incomplete) B2B investigation and contains both verified and unverified claims.** Some content remains accurate for the narrow scope of FA_CLIENTS_MAIN; other content has been proven incorrect by subsequent investigation (Steps 1-5).
>
> **Authoritative sources, in order of precedence:**
> 1. `Planning/B2B_Roadmap.md` — current investigation state, Known True list, and pending decisions
> 2. `WorkingFiles/B2B_Investigation/Step_NN_*/Step_NN_Findings.md` — detailed findings per investigation step
>
> **Known-false or significantly misleading claims in this document include:**
> - The opening claim that "every unit of work in Sterling corresponds to one execution of `FA_CLIENTS_MAIN`" — MAIN is ~16% of total Sterling activity, not the universal grain.
> - "b2bi has ~48hr retention" — actual retention is ~30 days across live + `_RESTORE` tables.
> - "200+ FA_* workflows" — there are 643 distinct FA_* workflow definitions, 304 active in any 48-hour window.
> - The "Four Dispatch Patterns" framing is MAIN-centric and incomplete for the full workflow universe.
>
> **Read with skepticism.** When this document disagrees with the Roadmap or step findings, the Roadmap and findings win. This document is preserved for its valuable reference content (ProcessData grammar, Integration table descriptions, NB workflow traces) but should not be used as a primary source of truth.

---

# B2B Sterling Architecture Overview

## Purpose of This Document

Reference document capturing the architectural model of IBM Sterling B2B Integrator as it is configured and operated at FAC. Built from a combination of live `b2bi` database investigation, direct reads of the workflow BPML definitions stored in `WFD_XML` / `DATA_TABLE`, reads of the Integration stored procedures that assemble Sterling's execution state, the original architect's Visio flow document (`BPs_Flow.vsdx`, authored by Rober Makram circa April 2021), direct inspection of Integration configuration tables, operational observations, and clarifications from FAC's File Processing Supervisor.

Intended audience: Dirk and the xFACts build effort. Eventually will serve as the source material for Control Center help pages under the B2B module. This is a reference document for understanding and building — not a finished publication.

Companion documents: `B2B_ProcessAnatomy_*.md` — one per process type, drilling into specifics.

---

## The Core Architectural Insight

**Every unit of work in Sterling corresponds to one execution of the `FA_CLIENTS_MAIN` workflow.**

This is the universal grain. Regardless of how a workflow was dispatched, and regardless of what the workflow does (NB inbound, payment, file cleanup, internal ops, etc.), the actual work is driven by `FA_CLIENTS_MAIN` (WFD_ID 798). Every MAIN execution carries its own `ProcessData` document that self-describes what that run is about — which entity, which process type, which files, which sub-workflows to invoke.

**MAIN is not polymorphic in structure — it's a single linear sequence with ~22 conditional rules.** Earlier revisions of this document described MAIN as having "polymorphic execution paths" based on PROCESS_TYPE. That framing was a useful approximation but structurally incorrect. Reading the BPML definition directly (WFD_ID 798, version 48) shows that MAIN is actually one `<sequence>` with many `<choice>` blocks — each sub-workflow invocation is individually gated by a rule evaluating ProcessData fields. What we previously called "Path A" (NB) vs. "Path C" (FILE_DELETION) vs. "Path D" (SFTP_PULL outbound) are different evaluations of the same rules producing different combinations of sub-workflow invocations.

From the xFACts collector's perspective, **the target is simple: every `FA_CLIENTS_MAIN` run in b2bi is a unit of work worth tracking. What that work IS varies based on configuration, but the collection target is consistent.**

Everything else in `b2bi.dbo.WF_INST_S` is either a **dispatcher** (invokes MAIN via `FA_CLIENTS_GET_LIST` or directly), a **sub-workflow** (invoked by MAIN), or **Sterling infrastructure** (unrelated to MAIN — utility, housekeeping, gateway plumbing).

**ETL_CALL note.** `FA_CLIENTS_ETL_CALL` is a parallel dispatch target invoked when a Client has `ETL_PATH` populated. Confirmed by File Processing Supervisor to be deprecated — no `CLIENTS_PARAM` rows have `ETL_PATH` populated. ETL_CALL is excluded from the v1 collector scope. Its characterization is preserved in this document for reference and to support rapid re-integration if it ever gets revived.

---

## The Coordination Layer (Integration Database)

Sterling's workflow execution is coordinated by a set of tables and stored procedures in the **Integration database** (on AVG-PROD-LSNR). Sterling BPMLs write to and read from these tables via the `AVG_PROD_LSNR_INTEGRATION` JDBC pool. This layer was partially hypothesized before the BPML reads; direct reading of the workflow definitions has now revealed its full structure.

**Architectural stance:** xFACts does not mirror Integration tables into local `INT_*` tables. Instead, the B2B collector **live-joins** to Integration tables on each collection cycle as needed for enrichment. The Integration database is on the AG (AVG-PROD-LSNR, same cluster as the xFACts database), making live-join latency acceptable for batch collection work. This direction was chosen over mirroring to reduce maintenance surface and sync burden — see `B2B_Module_Planning.md` → Lessons Learned → Integration Mirror Tables for context.

### Integration Tables Referenced By Sterling Workflows

| Table | Purpose | Populated By | xFACts Use |
|-------|---------|--------------|------------|
| `etl.tbl_B2B_CLIENTS_MN` | Entity roster (CLIENT_ID, CLIENT_NAME, flags) | Human configuration | Live-joined by collector for entity name enrichment; not mirrored |
| `etl.tbl_B2B_CLIENTS_FILES` | Process-level classification per (CLIENT_ID, SEQ_ID); includes `RUN_FLAG`, `AUTOMATED`, `FILE_MERGE`, `PROCESS_TYPE`, `COMM_METHOD`, `ACTIVE_FLAG` | Human configuration + `RUN_FLAG` updated by scheduler and `FA_CLIENTS_GET_LIST` at runtime | Live-joined by collector for process classification; not mirrored |
| `etl.tbl_B2b_CLIENTS_PARAM` | Field-level configuration per (CLIENT_ID, SEQ_ID, PARAMETER_NAME) — the key-value store that feeds into ProcessData | Human configuration | Not routinely queried — ProcessData captures the same values at runtime per-execution |
| `etl.tbl_B2B_CLIENTS_SETTINGS` | Global settings (DATABASE_SERVER, DM_*_PATH, DEF_*_ARCHIVE, PYTHON_KEY, etc.) | Human configuration | Not routinely queried — Settings/Values node in ProcessData captures the active settings at execution time |
| `ETL.tbl_B2B_CLIENTS_BATCH_STATUS` | Per-run execution state machine row | `FA_CLIENTS_GET_LIST` and `FA_CLIENTS_MAIN` at runtime | Live-joined by collector for enrichment and disagreement detection |
| `ETL.tbl_B2B_CLIENTS_TICKETS` | Failure ticket log with ticket type classification | Sterling workflow `onFault` handlers | Live-joined by collector for ticket_type enrichment on failed runs |
| `ETL.tbl_B2B_CLIENTS_BATCH_FILES` | File-level audit log — scope-limited: only zero-size and `FILE_DELETION` files are recorded | `FA_CLIENTS_GET_DOCS` during file-collection loop (only the `ZeroSize?` branch writes here) | Potentially live-joined for FILE_DELETION activity detail — decision pending based on Block 3 investigation |
| `DBO.tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` | List of files discovered on SFTP endpoints by Pattern 3 polling workflows | `FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` and variants every ~10 minutes | Not currently used — possible future "expected vs. processed" comparison downstream |

### Integration Stored Procedures Used by Sterling Workflows

| Procedure | Purpose | Called From |
|-----------|---------|-------------|
| `faint.USP_B2B_CLIENTS_GET_SETTINGS` | Reads `tbl_B2B_CLIENTS_SETTINGS`, pivots name/value pairs into columns, returns single-row settings document | `FA_CLIENTS_GET_LIST` at start |
| `faint.USP_B2B_CLIENTS_GET_LIST` | Assembles the dispatch list — joins CLIENTS_FILES, CLIENTS_PARAM, CLIENTS_MN, and (for per-file cases) the discovered-files table; pivots config into a multi-column Client result set; computes `PREV_SEQ` based on GET_DOCS_LOC adjacency or explicit SEQUENTIAL flag | `FA_CLIENTS_GET_LIST` |

### The `BATCH_STATUS` State Machine

`tbl_B2B_CLIENTS_BATCH_STATUS` is the coordination primitive that enables dependency chaining (PREV_SEQ), parent-child tracking, and workflow-level status reporting. Values observed in the BPMLs:

| Value | Meaning | Writer |
|-------|---------|--------|
| *(NULL / default)* | Row exists, not yet transitioned to a terminal state | GET_LIST or MAIN on initial INSERT |
| `-2` | Failed (legacy code path; converted to `-1` by polling SELECT's CASE expression) | MAIN tail UPDATE via conditional logic |
| `-1` | Failed | GET_LIST `onFault`; MAIN `onFault` (sets own row); MAIN tail UPDATE case |
| `0`, `1` | Transitional / in-progress — polled for by `Wait?` rule | Unclear source; may be DB default or Integration-side code |
| `2` | Done — dispatcher completed, OR BDL process, OR NB/PAYMENT with files processed | GET_LIST tail UPDATE; MAIN tail UPDATE |
| `3` | Done — non-NB/PAYMENT file process with files processed | MAIN tail UPDATE |
| `4` | Done — no files found, no duplicate | MAIN tail UPDATE |
| `5` | Done — duplicate file detected | MAIN tail UPDATE |

The `Wait?` rule in MAIN polls for values in the range `0 ≤ x ≤ 2` (still in progress from the polling worker's perspective) and the `Continue?` rule unblocks when the value is in `3 ≤ x ≤ 5` (done). A value of `-1` (or `-2` converted to `-1`) signals the prior phase failed, which causes `Continue?` to evaluate false and the polling worker to skip all its processing — proceeding directly to its tail UPDATE and exiting. This is the mechanism underlying what earlier revisions called "Path E" (short-circuit).

### The `TICKETS` Table as a Failure Signal

Sterling workflows log failures by inserting rows into `tbl_B2B_CLIENTS_TICKETS` from their `onFault` handlers. Observed ticket types:

- **`MAP ERROR`** — inserted by `FA_CLIENTS_MAIN`'s onFault handler on any fault propagating out of MAIN's main sequence
- **`CLIENTS GET LIST`** — inserted by `FA_CLIENTS_GET_LIST`'s onFault handler on any fault during dispatch

Additional ticket types may exist from other workflows we have not yet read. Ticket rows include `CLIENT_ID`, `SEQ_ID`, `RUN_ID` (Sterling WORKFLOW_ID), `CLIENT_NAME`, and insert timestamp — useful for correlating failures back to Sterling workflows without parsing WORKFLOW_CONTEXT.

**Note on missing ticket types:** Not every Sterling workflow's onFault handler writes to TICKETS. `FA_CLIENTS_ETL_CALL`, for example, updates BATCH_STATUS to -1 on fault but does NOT insert a TICKETS row. Ticket presence is a valid failure signal when present, but absence is not definitive evidence of success. (Moot for v1 collector since ETL_CALL is excluded; retained here for completeness.)

### The `BATCH_FILES` Table — File-Level Audit (Partial)

`tbl_B2B_CLIENTS_BATCH_FILES` is a file-level audit log populated by `FA_CLIENTS_GET_DOCS`. **Scope limitation:** only writes rows for files that take the `ZeroSize?` branch — i.e., zero-size files that were skipped (not retrieved) and all files in `FILE_DELETION` operations (where every file skips retrieval by design). Normal file pickups through the `PickupDoc` branch do NOT write to this table.

Columns observed:
- `CLIENT_ID`, `SEQ_ID`, `RUN_ID` (Sterling WORKFLOW_ID)
- `FILE_NAME`, `FILE_SIZE`
- `COMM_METHOD` — in the one observed INSERT, literal string `'SFTP_GET'`; other literal values may be written by other code paths not yet traced

**Operational interpretation:** think of BATCH_FILES as a "skipped-or-deleted files" log rather than a comprehensive file inventory. The real file processing audit trail for normal files lives in the sub-workflow execution (Translation outputs, ACCOUNTS_LOAD results) — not in this table.

### Source of Truth Stance

An important nuance: **`tbl_B2B_CLIENTS_BATCH_STATUS` and `tbl_B2B_CLIENTS_TICKETS` are a convenience layer, not the authoritative execution source.**

Both tables are written to from Sterling BPMLs — meaning they only get written when the BPML's JDBC calls succeed. If a Sterling process is killed mid-workflow, the JVM crashes, or the onFault handler itself faults, the Integration-side tables will not reflect what actually happened. Live operational experience has confirmed cases where b2bi showed a failed workflow that had no corresponding failure record in Integration.

**b2bi IS the authoritative source of truth for execution.** Integration's tables are a valuable enrichment layer — cheaper to query, relationally structured, human-readable — but not a replacement for b2bi's execution log.

**xFACts collector architecture implication:**
- Primary source: `b2bi.dbo.WF_INST_S` filtered to `FA_CLIENTS_MAIN` runs
- Enrichment: live-join to `tbl_B2B_CLIENTS_BATCH_STATUS` on `RUN_ID = WORKFLOW_ID` (PowerShell in-memory hash-join after separate queries; no linked server)
- Enrichment: live-join to `tbl_B2B_CLIENTS_TICKETS` on `RUN_ID = WORKFLOW_ID`
- Deep failure context: WORKFLOW_CONTEXT parsing for step-level detail (captured selectively, not for every run)
- Configuration: ProcessData from `TRANS_DATA` for field-level snapshots

**Disagreement detection as an alert signal:** when b2bi shows FAILED and Integration has no corresponding failure record (BATCH_STATUS NULL or still "in progress"), this is a high-severity alert — it means Sterling failed before it could report to Integration. This is a capability that exists *because* we're using b2bi as primary rather than trusting Integration.

---

## The Three Identity Scopes

There are three distinct identity scopes at play in Sterling file processing. Confusion between them is a common source of misunderstanding.

### Scope 1: Sterling Entity (via CLIENT_ID)

The `CLIENT_ID` in Sterling's Integration tables identifies a **configured entity** — a customer, vendor, or internal endpoint that Sterling processes files for/to. Some "clients" are real customers (ACADIA HEALTHCARE = CLIENT_ID 10557), others are internal pseudo-clients (INTEGRATION TOOLS = CLIENT_ID 328). Sterling's CLIENT_ID is NOT the same as a DM Creditor.

The term "CLIENT" in Sterling terminology is inherited from Integration team conventions and doesn't precisely match semantics. In the xFACts B2B schema, we use **"Entity"** instead to reflect that these identifiers cover clients, vendors, and internal services.

### Scope 2: Sterling Process (via (CLIENT_ID, SEQ_ID))

Within a single Entity, multiple **Processes** are configured, each differentiated by `SEQ_ID`. ACADIA alone has 9 configured processes spanning NB, file-deletion variants, RECON, SPECIAL_PROCESS, FILE_EMAIL, and outbound RETURNs. ACADIA HEALTHCARE EO (CLIENT_ID 10724) has 4 processes that form an orchestrated pipeline (SEQ_IDs 1, 2, 3, 8 with SEQUENTIAL dispatch).

The **(CLIENT_ID, SEQ_ID) pair uniquely identifies a Process.**

### Scope 3: DM Creditor Key

Inside the file payload itself, individual records may carry **DM Creditor Keys** (e.g., `CE12345`, `CE98765`). These refer to entities in DM's creditor hierarchy (exposed in xFACts via the `dbo.ClientHierarchy` table). A single file processed by one Sterling Process may contain records for multiple DM Creditors.

**Critical:** when the Sterling team says "client," context determines what they mean. "ACADIA" as a Sterling Entity (CLIENT_ID 10557) is not the same as an ACADIA-related DM Creditor Key. A single Sterling Process for ACADIA can route records to many DM Creditors.

### Implied Grain Layering

```
MAIN RUN (WORKFLOW_ID)
 └── Sterling Process (CLIENT_ID, SEQ_ID)         ← one per MAIN run (from MAIN's perspective)
      └── Individual File                          ← 1 or more per Process (loop)
           └── DM Creditor breakdown               ← 1 or more per File (records to different creditors)
```

**Important clarification from BPML read:** MAIN's rules all reference `//Result/Client[1]/...`, meaning each MAIN execution processes exactly one Client block from its perspective. When a dispatcher (like the ACADIA EO wrapper) spawns multiple MAIN children from a multi-SEQ configuration, each MAIN child gets its own ProcessData with exactly one `<Client>` block at `//Result/Client[1]`. The full multi-SEQ configuration may be present in `//PrimaryDocument` for reference but MAIN only operates on `//Result`.

See "Execution Tracking Design" below for how this maps to the collector schema. The future `SI_ExecutionDetail` table (see `B2B_Module_Planning.md`) is the home for the File and DM Creditor breakdown grain layers.

---

## Dispatch Patterns

`FA_CLIENTS_MAIN` is never a root. It is always invoked by something. Reading the BPML definitions of representative dispatchers (`FA_CLIENTS_GET_LIST`, `FA_FROM_ACADIA_HEALTHCARE_IB_EO`, `FA_FROM_ACCRETIVE_IB_BD_PULL`, `FA_FROM_COACHELLA_VALLEY_ANESTHESIA_IB_BD_SFTP_PULL`, `FA_FROM_MONUMENT_HEALTH_IB_EO_PULL`) has resolved the dispatcher model. There are **four** distinct dispatch patterns. The earlier catalog of five was an over-count — what was previously called "Pattern 5 Parallel Phased Workers" is actually Pattern 4 with specific parameters.

### Pattern 1 — Direct Named Workflow

A named workflow fires on a Sterling SCHEDULE and invokes `FA_CLIENTS_MAIN` directly, **bypassing `FA_CLIENTS_GET_LIST`**. One root workflow → one MAIN child. ProcessData is assembled within the named workflow itself (typically via direct JDBC queries against CLIENTS_PARAM, or via simple hardcoded values).

**Examples:**
- `FA_TO_FORREST_GENERAL_OB_BD_S2D_NT` → fires on schedule → invokes MAIN with hardcoded/static Client configuration
- Similar outbound NOTES workflows

**Characteristics:**
- One root → one MAIN
- Most structurally simple pattern
- Root fires regardless of whether work exists

**Distinguishing feature:** The MAIN's parent in WORKFLOW_LINKAGE is NOT `FA_CLIENTS_GET_LIST` (and not a dispatcher that inlined GET_LIST either). Instead it's the named workflow directly.

### Pattern 2 — Scheduler-Fired `FA_CLIENTS_GET_LIST`

`FA_CLIENTS_GET_LIST` fires on its own schedule, with no `CLIENT_ID` / `SEQ_ID` / `PROCESS_TYPE` / `SEQUENTIAL` parameters set. Per File Processing Supervisor clarification, this schedule is **5:05am – 3:05pm Monday–Friday every 1 hour** — so GET_LIST fires at :05 past each hour within that window (11 fires per business day).

The stored procedure (`USP_B2B_CLIENTS_GET_LIST`) follows the "Branch 1" path (the `@CLIENT_ID IS NULL` code path), which:

1. Selects `CLIENTS_FILES` rows where `RUN_FLAG = 1 AND AUTOMATED = 1` (combined with either `FILE_MERGE = 1` or `COMM_METHOD = 'OUTBOUND'`) — these are the "merge-enabled inbound" or "outbound" configs.
2. Separately selects CLIENTS_FILES rows that have matching files discovered in `tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` (the Pattern 3-populated discovered-files table) — these are "per-file inbound" configs.
3. UNION ALLs both sets, PIVOTs CLIENTS_PARAM into ~65 Client-block columns, and returns them.

GET_LIST then loops over the returned rows and invokes `FA_CLIENTS_MAIN` (or `FA_CLIENTS_ETL_CALL`, if ETL_PATH is populated — which in practice is never) **asynchronously** for each row. See "`FA_CLIENTS_GET_LIST` Detail" below.

**Observed spawn counts** (7-hour window on April 20):

| Hour | Children Spawned |
|------|-----------------:|
| 05:05 | 164 |
| 09:05 | 59 |
| 07:05 | 29 |
| 08:05 | 27 |
| 10:05 | 18 |
| 06:05 | 13 |

Spawn count varies dramatically by hour. 05:05 is a peak dispatch window — reflects accumulated overnight files + all OUTBOUND configs firing together. Spawn count == count of `USP_B2B_CLIENTS_GET_LIST` result rows for that run.

### Pattern 3 — Periodic Internal Operation Scanner

A periodic workflow (`FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` and its `_ARC` variant) fires every ~10 minutes and invokes MAIN to execute Integration stored procedures. **These are Internal Operations (MAIN running in "SP Executor" mode for CLIENT_ID 328), not file scanners.**

**Important role:** The FTP_FILES_LIST workflow populates `tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` — the discovered-files table that Pattern 2 consumes. So Pattern 3 is actually the **source** of input for Pattern 2's per-file inbound branch. Every 10 minutes, the list of files available on SFTP endpoints is refreshed; every hour at `:05`, GET_LIST consumes that list and dispatches MAIN runs.

**Note:** Despite the "FTP_FILES_LIST" name suggesting file scanning, these workflows' internal logic uses MAIN as an SP executor to invoke stored procedures that do the scanning and writing. The workflow name is a literal description of the procedure it runs.

### Pattern 4 — Entity-Triggered `FA_CLIENTS_GET_LIST`

**This is the unifying pattern** that replaces what earlier revisions called "Pattern 4 (Periodic Puller)" and "Pattern 5 (Parallel Phased Workers)." Both turn out to be the same pattern with different GET_LIST parameters.

Entity-specific wrapper workflows fire on Sterling schedules. Each wrapper is a thin BPML (typically ~25-30 lines, ~850 bytes) that does only one thing: sets some combination of `CLIENT_ID`, `SEQ_IDS`, `PROCESS_TYPE`, and `SEQUENTIAL` parameters in ProcessData, then **inlines** an invocation of `FA_CLIENTS_GET_LIST`.

Because the invocation is inline (`InlineInvokeBusinessProcessService`), GET_LIST runs inside the wrapper's own WORKFLOW_ID — it does NOT appear as a separate workflow in WORKFLOW_LINKAGE. The MAIN children that GET_LIST spawns appear as direct children of the wrapper workflow in linkage terms.

GET_LIST's stored procedure (`USP_B2B_CLIENTS_GET_LIST`) follows "Branch 2" (the `@CLIENT_ID IS NOT NULL` code path), which:

1. Selects `CLIENTS_FILES` rows where `AUTOMATED = 2` for the given `CLIENT_ID` filtered by `(SEQ_ID = @SEQ_ID OR PROCESS_TYPE = @PROCESS_TYPE OR SEQ_ID IN StrSplit(@SEQ_IDS))` — at least one of these three parameters must be set for any rows to match.
2. Optionally forces `PREV_SEQ` chaining across all matched rows when `@SEQUENTIAL = 1` (regardless of GET_DOCS_LOC adjacency).
3. Returns the dispatch list.

**Wrapper variants observed:**

| Wrapper | Parameters Set | Behavior |
|---------|----------------|----------|
| `FA_FROM_ACCRETIVE_IB_BD_PULL` | `CLIENT_ID=488`, `PROCESS_TYPE='SFTP_PULL'`, `SEQUENTIAL=1` | Matches all SFTP_PULL-type SEQs for ACCRETIVE; runs sequentially |
| `FA_FROM_COACHELLA_VALLEY_ANESTHESIA_IB_BD_SFTP_PULL` | `CLIENT_ID=10745`, `PROCESS_TYPE='SFTP_PULL'` | Matches SFTP_PULL SEQs for COACHELLA; runs in parallel (SEQUENTIAL not set) |
| `FA_FROM_MONUMENT_HEALTH_IB_EO_PULL` | `CLIENT_ID=227`, `PROCESS_TYPE='SFTP_PULL'` | Matches SFTP_PULL SEQs for MONUMENT; runs in parallel |
| `FA_FROM_ACADIA_HEALTHCARE_IB_EO` | `CLIENT_ID=10724`, `SEQ_IDS='1,2,3,8'`, `SEQUENTIAL=1` | Matches specific pipeline phase SEQs; runs sequentially |

**Observed spawn counts** — now explicable:

- `FA_FROM_ACCRETIVE_IB_BD_PULL`: observed spawning 12 MAIN children on busy days — matches count of SFTP_PULL SEQs configured for CLIENT_ID 488 where files were discovered
- `FA_FROM_MONUMENT_HEALTH_IB_EO_PULL`: consistently spawns 7 children — count of SFTP_PULL SEQs for CLIENT_ID 227
- `FA_FROM_COACHELLA_VALLEY_ANESTHESIA_IB_BD_SFTP_PULL`: spawns 2 MAIN children per invocation — SEQs 5 and 6 are the configured SFTP_PULL SEQs
- `FA_FROM_ACADIA_HEALTHCARE_IB_EO`: spawns 4 MAIN children — matches `SEQ_IDS='1,2,3,8'` exactly

**The "parallel vs. sequential" distinction:** Without `SEQUENTIAL=1`, the PREV_SEQ field is only set between SEQs sharing the same `GET_DOCS_LOC` (automatic serialization to prevent concurrent SFTP sessions to the same folder). With `SEQUENTIAL=1`, PREV_SEQ is set across ALL rows in the result set, forcing a sequential pipeline regardless of folder.

**Why "Pattern 5" no longer exists as a distinct pattern:** The behavior we observed in ACADIA EO traces (4 workers activating with ~90 second offsets) is a natural consequence of `SEQUENTIAL=1` + BATCH_STATUS polling. Worker 1 runs; worker 2 polls BATCH_STATUS until worker 1's tail UPDATE marks it done; worker 3 similarly waits for 2; worker 4 for 3. The "90-second offsets" are just the actual durations of each phase. No special "pattern" — same GET_LIST + PREV_SEQ mechanism at work.

### Summary Table

| Pattern | Dispatcher | How MAIN is Reached | Parameter Signature |
|---------|-----------|---------------------|---------------------|
| 1 | Named workflow on schedule | Direct | N/A (wrapper doesn't call GET_LIST) |
| 2 | `FA_CLIENTS_GET_LIST` on schedule (5:05am-3:05pm M-F hourly) | Via GET_LIST → SP Branch 1 | No parameters set |
| 3 | `FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` | Direct (MAIN runs as SP executor) | CLIENT_ID = internal pseudo-client |
| 4 | Named entity wrapper (e.g., `FA_FROM_*_PULL`, `FA_FROM_ACADIA_HEALTHCARE_IB_EO`) | Via inlined GET_LIST → SP Branch 2 | At least one of CLIENT_ID, SEQ_IDS, PROCESS_TYPE; optional SEQUENTIAL |

---

## `FA_CLIENTS_GET_LIST` Detail

Because GET_LIST underlies both Pattern 2 and Pattern 4, its behavior is foundational to the architecture. This section captures the mechanism.

### Inputs (from ProcessData)

- `CLIENT_ID` — specific client to filter to, or empty for scheduler-mode
- `SEQ_ID` — single specific SEQ, or empty
- `SEQ_IDS` — comma-delimited list of SEQ_IDs (e.g., `'1,2,3,8'`)
- `PROCESS_TYPE` — process type filter (e.g., `'SFTP_PULL'`)
- `SEQUENTIAL` — `1` = force PREV_SEQ chaining across all matched rows; anything else = standard GET_DOCS_LOC-based chaining

### Execution

1. **Get parent WORKFLOW_ID** (its own WORKFLOW_ID since GET_LIST typically runs inline within a wrapper).
2. **INSERT into `tbl_B2B_CLIENTS_BATCH_STATUS`** — establishes GET_LIST's own tracking row:
   ```sql
   INSERT INTO INTEGRATION.ETL.tbl_B2B_CLIENTS_BATCH_STATUS(CLIENT_ID, SEQ_ID, RUN_ID)
   VALUES (?, CASE WHEN ? = -1 THEN NULL ELSE ? END, ?)
   ```
3. **Call `USP_B2B_CLIENTS_GET_SETTINGS`** — populates `Settings/Values` node in ProcessData with global settings (DATABASE_SERVER, DEF_POST_ARCHIVE, DM_NB_PATH, etc.).
4. **Call `USP_B2B_CLIENTS_GET_LIST`** — returns the dispatch list as a multi-Client result set. The SP has two code branches:
   - **Branch 1** (`@CLIENT_ID IS NULL`) — scheduler mode: filter by `AUTOMATED=1` + `RUN_FLAG=1`
   - **Branch 2** (`@CLIENT_ID IS NOT NULL`) — wrapper mode: filter by `AUTOMATED=2` + matching CLIENT_ID and at least one of (SEQ_ID / PROCESS_TYPE / SEQ_IDS).
5. **Loop over returned rows**:
   - Copy `Client[ClientCounter]` to `//Result` in ProcessData (this becomes MAIN's `//Result/Client[1]`)
   - Branch on `ETL?` rule: if `ETL_PATH` is populated, invoke `FA_CLIENTS_ETL_CALL`; otherwise invoke `FA_CLIENTS_MAIN`. In practice ETL_PATH is never populated (ETL_CALL deprecated).
   - Both invocations use `InvokeBusinessProcessService` (NOT inline) with no `INVOKE_MODE` specified — Sterling's default is async, so **MAIN children are fired in rapid succession** (~100-200ms apart) rather than sequentially with wait
   - UPDATE `tbl_B2B_CLIENTS_FILES SET RUN_FLAG = 0 WHERE CLIENT_ID = ? AND SEQ_ID = ?` — releases the currently-executing flag
   - Increment `ClientCounter`
6. **Tail UPDATE**: `tbl_B2B_CLIENTS_BATCH_STATUS SET BATCH_STATUS = 2, FINISH_DATE = GETDATE()` for GET_LIST's own row.

### onFault Handler

Three operations:
1. UPDATE BATCH_STATUS = -1 for GET_LIST's row
2. INSERT into `tbl_B2B_CLIENTS_TICKETS` with ticket type `'CLIENTS GET LIST'`
3. Invoke `EmailOnError` workflow

### The `AUTOMATED` Field Semantics

Per File Processing Supervisor confirmation:
- **`AUTOMATED = 1`** — Uses the `FA_CLIENTS_GET_LIST` business process to pick up files for processing. GET_LIST is scheduled to run 5:05am–3:05pm Monday–Friday every 1 hour. The SP's Branch 1 filters for these, combined with `RUN_FLAG = 1`.
- **`AUTOMATED = 2`** — A scheduled business process is set up to run at specific scheduled times. The SP's Branch 2 filters for these. No `RUN_FLAG` gating needed — the caller already knows exactly which SEQs to run.

### `RUN_FLAG` Semantics

Per File Processing Supervisor confirmation: `RUN_FLAG` is used specifically for processes with `AUTOMATED = 1`. When `RUN_FLAG = 1` AND `AUTOMATED = 1`, files get picked up and processed when GET_LIST kicks off at :05 past the hour. Purpose: prevent concurrent dispatch and flag "ready to process" state.

The scheduler's responsibility is to set `RUN_FLAG = 1` before dispatch; GET_LIST clears it to 0 in the loop after each corresponding MAIN invocation returns.

### `SEQUENTIAL` Semantics

`SEQUENTIAL = 1` affects how the SP computes `PREV_SEQ` in the result set:

- **Without SEQUENTIAL=1:** `PREV_SEQ` is set only when consecutive rows share the same `CLIENT_ID` AND same `GET_DOCS_LOC`. Automatic serialization of same-folder pulls.
- **With SEQUENTIAL=1:** `PREV_SEQ` is set between consecutive rows sharing `CLIENT_ID` regardless of GET_DOCS_LOC. Forces a sequential pipeline.

The `PREV_SEQ` value then flows into MAIN's ProcessData, and MAIN's `Wait?` rule polls BATCH_STATUS for the dependency.

### `FA_CLIENTS_ETL_CALL` Dispatch Path (Deprecated)

The BPML reveals a parallel dispatch target that has been deprecated:

```xml
<choice name="Choice Start">
  <select>
    <case ref="ETL?" activity="ETL"/>
    <case ref="ETL?" negative="true" activity="BP"/>
  </select>
  <sequence name="ETL">
    ... Invoke FA_CLIENTS_ETL_CALL ...
  </sequence>
  <sequence name="BP">
    ... Invoke FA_CLIENTS_MAIN ...
  </sequence>
</choice>
```

When a Client block has `ETL_PATH` populated, GET_LIST would invoke `FA_CLIENTS_ETL_CALL` instead of `FA_CLIENTS_MAIN`. Confirmed no `CLIENTS_PARAM` rows currently have `ETL_PATH` populated — so in practice this code path is never taken. The v1 xFACts collector excludes `FA_CLIENTS_ETL_CALL` tracking entirely.

---

## `FA_CLIENTS_MAIN` Detail

MAIN is a single `<sequence>` with ~22 named rules that gate sub-workflow invocations. Every configurable step is wrapped in a `<choice>` that references a rule. The rules evaluate XPath expressions against ProcessData (specifically `//Result/Client[1]/...`).

### Execution Skeleton

1. **Preamble** — Release inputs, capture `thisProcessInstance`, get timestamp, initialize flags (`Ready=-999`, `ClientArchiveName`).
2. **INSERT BATCH_STATUS row** for this MAIN run: `(CLIENT_ID, SEQ_ID, RUN_ID=thisProcessInstance, PARENT_ID)`.
3. **StatusUpdate / Wait loop** (if `PREV_SEQ` is set): wait 1 second, poll BATCH_STATUS for the dependency, loop until status leaves the in-progress range.
4. **`Continue?` gate** — if prior phase failed (BATCH_STATUS = -1), skip all processing. Otherwise enter the processing block.
5. **Invoke `FA_CLIENTS_GET_DOCS`** inline (always runs when processing is entered).
6. **File processing loop** (up to `noofdocs` iterations):
   - PreArchive, PrepSource, RemoveSpecialCharacters, Translation, VITAL insert, AccountsTbl (NB), EncounterLoad, PostArchive, TranslationStaging, MergeFiles
   - PostTranslation invocation (inside or outside the loop depending on config)
7. **Tail sub-workflows** (after loop): WorkersComp, DupCheck, PostArchive2, AddressLookup, PrepCommCall, CommCall, SendEmail
8. **Tail UPDATE BATCH_STATUS** — sets terminal state value (2/3/4/5 based on outcome).

### Rule Catalog

The ~22 rules define the full set of configurable decision points in MAIN. This is the complete catalog:

| Rule Name | ProcessData Field(s) Examined | Triggers |
|-----------|-------------------------------|----------|
| `AnyMoreDocs?` | `currentdoc <= noofdocs` | Loop iteration control |
| `Prep?` | `Client/PREPARE_SOURCE = 'Y'` | Invoke FA_CLIENTS_PREP_SOURCE |
| `PreArchive?` | `PRE_ARCHIVE != 'N'` AND (files exist OR FSA docs > 0) | Invoke FA_CLIENTS_ARCHIVE (pre-archive) |
| `Translate?` | `TRANSLATION_MAP != ''` | Invoke FA_CLIENTS_TRANS |
| `DupCheck?` | `DUP_CHECK != '' AND != 'N'` AND files exist | Invoke FA_CLIENTS_DUP_CHECK |
| `WorkersComp?` | `WORKERS_COMP = 'Y'` AND files AND no duplicate | Invoke FA_CLIENTS_WORKERS_COMP |
| `PostArchive?` | `POST_ARCHIVE != 'N' OR != ''` AND (files OR OUTBOUND) | Invoke FA_CLIENTS_ARCHIVE (post-archive, ASYNC) |
| `SendEmail?` | `MAIL_TO != ''` AND files and not empty, OR outbound with docs | Invoke FA_CLIENTS_EMAIL |
| `CommCall?` | `COMM_CALL = 'Y'` | Invoke FA_CLIENTS_COMM_CALL |
| `MergeFiles?` | NB or PAYMENT + TRANSLATION_MAP set + no POST_TRANSLATION_MAP + files | Invoke FA_CLIENTS_FILE_MERGE |
| `PrepCommCall?` | Complex: non-NB/PAY with PREPARE_COMM_CALL=Y or OUTBOUND; OR NB/PAY with files and no duplicate | Invoke FA_CLIENTS_PREP_COMM_CALL |
| `VITAL?` | `PROCESS_TYPE != 'SFTP_PULL'` | Invoke FA_CLIENTS_VITAL (first of two invocations — in-loop) |
| `PostArchive2?` | `POST_ARCHIVE != 'N'` AND files AND (NB or PAY) | Invoke FA_CLIENTS_ARCHIVE (second post-archive, mode depends on PV_FN_ADDRESS) |
| `Wait?` | `PREV_SEQ != ''` AND BATCH_STATUS in polling range | Enter polling loop |
| `Continue?` | BATCH_STATUS in done range | Exit polling loop and proceed with processing |
| `NB?` | `PROCESS_TYPE = 'NEW_BUSINESS'` | Invoke FA_CLIENTS_ACCOUNTS_LOAD (inside VITAL choice) |
| `Encounter?` | `ENCOUNTER_MAP != ''` | Invoke FA_CLIENTS_ENCOUNTER_LOAD |
| `AddressLookup?` | `PV_FN_ADDRESS != '' AND != 'N'` AND files | Invoke FA_CLIENTS_ADDRESS_CHECK |
| `SaveDoc?` | `FILE_RENAME = 'Y'` | Save document filename handling |
| `PostTranslation?` | `POST_TRANSLATION = 'Y'` | Invoke FA_CLIENTS_POST_TRANSLATION |
| `PostTranslationVITAL?` | `POST_TRANSLATION_VITAL = 'Y'` | Invoke FA_CLIENTS_VITAL (second of two — post-loop) |
| `TranslationStaging?` | `TRANSLATION_STAGING = 'Y'` | Invoke FA_CLIENTS_TRANSLATION_STAGING |
| `RemoveSpecialCharacters?` | `FILE_CLEAN_UP = 'Y'` AND no PREP_TRANSLATION_MAP | Invoke Python exe via CommandLineAdapter2 |

**Rule coverage depends on configuration, not on dispatch pattern.** A NEW_BUSINESS process will typically trigger: Prep, PreArchive, Translate, VITAL, NB/AccountsTbl, PostArchive, MergeFiles, WorkersComp, DupCheck, PostArchive2, PrepCommCall, CommCall, SendEmail. A FILE_DELETION process will typically trigger: none of the translation / NB rules, only GET_DOCS (which internally does the SFTP deletes). An SFTP_PULL OUTBOUND process triggers a minimal set: GET_DOCS, PrepCommCall, CommCall, PostArchive.

### Sub-Workflow Invocation Map

Every sub-workflow invocation in MAIN, with its gating rule:

| Sub-workflow | Invocation Context | Gating Rule | INVOKE_MODE |
|-------------|-------------------|-------------|-------------|
| `FA_CLIENTS_GET_DOCS` | Top of processing block | Always (after Continue?) | INLINE |
| `FA_CLIENTS_PREP_SOURCE` | Inside loop | `Prep?` | INLINE |
| `FA_CLIENTS_ARCHIVE` (PreArchive) | Inside loop | `PreArchive?` | INLINE |
| `FA_CLIENTS_TRANS` | Inside loop | `Translate?` | INLINE |
| `FA_CLIENTS_VITAL` (in-loop) | Inside loop | `VITAL?` (under NotPostTranslation path) | ASYNC |
| `FA_CLIENTS_ACCOUNTS_LOAD` (in-loop) | Inside loop | `NB?` | INLINE |
| `FA_CLIENTS_ENCOUNTER_LOAD` (in-loop) | Inside loop | `Encounter?` | ASYNC |
| `FA_CLIENTS_ARCHIVE` (PostArchive) | Inside loop | `PostArchive?` | ASYNC |
| `FA_CLIENTS_TRANSLATION_STAGING` | Inside loop | `TranslationStaging?` | INLINE |
| `FA_CLIENTS_FILE_MERGE` | Inside loop | `MergeFiles?` | INLINE |
| `FA_CLIENTS_POST_TRANSLATION` | Inside loop | `PostTranslation?` | INLINE |
| `FA_CLIENTS_VITAL` (post-loop) | Under PostTranslationVITAL branch | `PostTranslationVITAL?` AND `VITAL?` | ASYNC |
| `FA_CLIENTS_ACCOUNTS_LOAD` (post-loop) | Under PostTranslationVITAL branch | `PostTranslationVITAL?` AND `NB?` | INLINE |
| `FA_CLIENTS_ENCOUNTER_LOAD` (post-loop) | Under PostTranslationVITAL branch | `PostTranslationVITAL?` AND `Encounter?` | ASYNC |
| `FA_CLIENTS_WORKERS_COMP` | Tail (after loop) | `WorkersComp?` | INLINE |
| `FA_CLIENTS_DUP_CHECK` | Tail (after loop) | `DupCheck?` | INLINE |
| `FA_CLIENTS_ARCHIVE` (PostArchive2) | Tail (after loop) | `PostArchive2?` | depends on PV_FN_ADDRESS (INLINE or ASYNC) |
| `FA_CLIENTS_ADDRESS_CHECK` | Tail (after loop) | `AddressLookup?` | INLINE |
| `FA_CLIENTS_PREP_COMM_CALL` | Tail (after loop) | `PrepCommCall?` | INLINE |
| `FA_CLIENTS_COMM_CALL` | Tail (after loop) | `CommCall?` | INLINE |
| `FA_CLIENTS_EMAIL` | Tail (after loop) | `SendEmail?` | ASYNC |
| `EmailOnError` | onFault only | Faults | ASYNC |

**FA_CLIENTS_ARCHIVE is invoked up to 3 times per MAIN run** (PreArchive, PostArchive, PostArchive2). This explains why we see ARCHIVE children appearing multiple times in WORKFLOW_LINKAGE for a single MAIN run.

**FA_CLIENTS_VITAL has two invocation points** — one inside the file loop (once per file processed) and one optionally after the loop. A MAIN processing 5 files with `PostTranslationVITAL=Y` will show 6 VITAL children (5 in-loop + 1 post-loop). This is why VITAL's run count in `WF_INST_S` typically exceeds MAIN's run count.

### External Executable Invocation

MAIN directly invokes an external Python executable via `CommandLineAdapter2` when `RemoveSpecialCharacters?` evaluates true:

```
\\kingkong\Data_Processing\Pervasive\Python_EXE_files\FA_INT_Tools\FA_FILE_REMOVE_SPECIAL_CHARACTERS.exe
```

Parameters include `DATABASE_SERVER` (from Settings), archive path, file filter, CLIENT_ID, SEQ_ID, CLIENT_NAME, INVOKE_ID, and the FILE_CLEAN_UP flag. A separate Python exe (`FA_MERGE_PLACEMENT_FILES.exe`) is invoked via COMM_CALL in specific SPECIAL_PROCESS pipelines (ACADIA EO orchestration).

### Tail UPDATE BATCH_STATUS Value Logic

After all tail sub-workflows complete, MAIN UPDATEs its own BATCH_STATUS row:

```
param2 = if(PROCESS_TYPE != 'BDL',
    if(count(Files/File) != 0 AND DUPLICATE_FILE = '',
        if(PROCESS_TYPE != 'NEW_BUSINESS' AND PROCESS_TYPE != 'PAYMENT', 3, 2),
        if(DUPLICATE_FILE != '', 5, 4)),
    2)
```

Interpretation:
- BDL → `2`
- Files processed successfully, no duplicate:
  - Not NB/PAY → `3`
  - NB or PAY → `2`
- No files processed (or duplicate):
  - DUPLICATE_FILE flag set → `5`
  - Otherwise → `4`

### onFault Handler

Three operations:

1. **UPDATE BATCH_STATUS = -1** for this MAIN run's row.
2. **INSERT into `tbl_B2B_CLIENTS_TICKETS`** with type `'MAP ERROR'`, capturing CLIENT_ID, SEQ_ID, RUN_ID, CLIENT_NAME.
3. **Invoke `EmailOnError`** workflow (ASYNC).

**Note:** MAIN's onFault only fires for faults propagating OUT of MAIN's main sequence. Sub-workflows have their own onFault handlers — if they handle the fault and return success, MAIN's onFault does not fire and no ticket is written. This is one source of the "failed in b2bi but nothing in Integration" scenarios.

---

## `FA_CLIENTS_GET_DOCS` Detail

`FA_CLIENTS_GET_DOCS` is MAIN's file acquisition sub-workflow. It's always invoked when MAIN's `Continue?` rule evaluates true. Reading its BPML (version 37 — heavily edited over time) reveals that it handles three distinct file-acquisition methods and is the actual home of the `FILE_DELETION` cleanup logic (which earlier revisions had attributed to MAIN directly).

### Three `GET_DOCS_TYPE` Variants

GET_DOCS branches at its top level on the `GET_DOCS_TYPE` field from the current Client block:

**1. `SFTP_PULL`** — The most complex branch. Opens an SFTP session to the Joker server (FAC's SFTP endpoint), lists the remote directory, loops through discovered files (up to `noofdocs`), and for each file either retrieves it or skips it based on the `ZeroSize?` rule. Each file is then either deleted from the remote source or moved to a remote archive path based on the `DocDelete?` vs `DocArchive?` rules.

**2. `FSA_PULL`** — File System Adapter pickup from a local or network folder path. Simple — just invokes `AS3FSAdapter` with `FS_COLLECT` action, using the Client's `GET_DOCS_LOC` as the collection folder and `FILE_FILTER` as the filter pattern.

**3. `API_PULL`** — Invokes a Python executable via `CommandLineAdapter2` to fetch files (the exe path comes from the Client's `GET_DOCS_API` field), then calls `FS_COLLECT` against the landing folder to pick up what was downloaded. After completion, GET_DOCS mutates `GET_DOCS_TYPE` from `API_PULL` to `FSA_PULL` — so downstream references in MAIN see `FSA_PULL`, not `API_PULL`. API_PULL is effectively a "Python download prelude to FSA_PULL."

Python working directory for API_PULL: `\\kingkong\Data_Processing\Pervasive\Python_EXE_files\!Python_Working`. Timeout: 36,000,000 ms (10 hours).

### The SFTP_PULL Loop

1. Begin SFTP session using `GET_DOCS_PROFILE_ID` if set, else a hardcoded default profile `FA-INT-APPT:node1:17b98dc642f:105916` (which references the dev-env app server node ID — appears to be a legacy default left in production).
2. `CD` to `GET_DOCS_LOC`.
3. `LIST` to enumerate remote files into `//Files/File[]`.
4. Invoke `JavaTaskFS` running `E:\Utilities\FA_FILE_CHECK.java` — **Sterling-server-side Java utility** (source not yet read) that performs file validation or filtering on the listed files.
5. Set `noofdocs = count(//Files/File)`.
6. Loop through files up to `noofdocs` (or just once if `FILE_ID > 0`, for single-file mode):
   - Evaluate `ZeroSize?`:
     - **True path (`ZeroSize` branch):** file is zero-size AND not a `*_PULL` process type (without `GET_EMPTY_DOCs=Y` override), OR `PROCESS_TYPE = 'FILE_DELETION'`. Skip the SFTPClientGet. Go directly to delete-or-archive. Insert a row into `tbl_B2B_CLIENTS_BATCH_FILES` with `COMM_METHOD='SFTP_GET'` for audit.
     - **False path (`PickupDoc` branch):** `SFTPClientGet` to retrieve the file. Then delete-or-archive based on `GET_DOCS_DLT` value.
7. End SFTP session.
8. If `BatchFileInsert?` rule evaluates true (`PROCESS_TYPE != 'SFTP_PULL'`), invoke a final translation using map `FA_CLIENTS_BATCH_FILES_X2S` — apparently generates an insert-set for the batch/files in structured form. Translation map source not yet analyzed.

### How `FILE_DELETION` Works

**Resolution of Integration Team Questions #1 and #9. Confirmed by File Processing Supervisor:** FILE_DELETION is only configured for clients that submit un-needed files. Files are picked up by GET_LIST and deleted from the Joker SFTP server (but remain in ftpbackup).

Mechanically, `FILE_DELETION` is NOT a separate code path. It operates by setting `PROCESS_TYPE = 'FILE_DELETION'`, which causes the `ZeroSize?` rule to evaluate true for EVERY file regardless of actual size:

```
ZeroSize? condition: 
    (not(contains(PROCESS_TYPE, '_PULL')) 
     AND GET_EMPTY_DOCS != 'Y' 
     AND Files[currentdoc]/Size = 0 
     AND FILE_ID = 0) 
    OR PROCESS_TYPE = 'FILE_DELETION'
```

The trailing `OR PROCESS_TYPE = 'FILE_DELETION'` forces every file into the ZeroSize branch. That branch does NOT retrieve the file — it only performs the remote delete (or archive move) and logs to `BATCH_FILES`. So a `FILE_DELETION` run that encounters 112 remote files issues 112 SFTPClientDelete operations and writes 112 rows to BATCH_FILES, but never downloads any content.

This is a clever reuse of the same loop structure — not a special code path. Which also means **FILE_DELETION lifecycle is universal to SFTP-pull inbound processes with FILE_DELETION configured**, since it's just a configuration-driven behavior of the standard SFTP_PULL branch.

### The `ZeroSize?` Rule — Multi-Purpose

The `ZeroSize?` rule combines two unrelated conditions into one branch target:

1. **Actual zero-size skip logic** — for normal processes, if a listed file is zero bytes AND `GET_EMPTY_DOCS` is not set to `Y`, skip retrieval (but still delete/archive on the remote side). Prevents downstream translation from receiving empty payloads.
2. **`FILE_DELETION` deletion logic** — forces skip-retrieve-then-delete for all files regardless of size.

Reusing the same branch for both cases means both record a BATCH_FILES row and both follow the same delete/archive decision. This is why BATCH_FILES has scope-limited coverage — it only sees files that took this branch.

### Fields in Play (ProcessData)

New or previously-undocumented fields identified:
- `GET_DOCS_TYPE` — one of `SFTP_PULL`, `FSA_PULL`, `API_PULL` (and mutated from `API_PULL` → `FSA_PULL` after API retrieval)
- `GET_DOCS_API` — Python exe path for `API_PULL`
- `CUSTOM_FILE_FILTER` — `Y` flag triggering dynamic XPath evaluation of `FILE_FILTER`
- `GET_EMPTY_DOCS` — `Y` flag overriding the zero-size skip
- `FILE_ID` — when nonzero, forces single-pass mode (no iterative loop)
- `GET_DOCS_DLT` — delete-vs-archive flag. Values:
  - `'Y'` or empty string → delete the remote file after retrieval (or instead of retrieval in ZeroSize branch)
  - `'N'` → do nothing to the remote (keep the file)
  - Any other value → treat as a remote archive path prefix; MOVE the file to that path instead of deleting

### No onFault Handler

`FA_CLIENTS_GET_DOCS` does NOT have its own onFault handler. Any fault during SFTP operations (SSH disconnect, session timeouts, missing files, etc.) propagates up to MAIN's onFault — which writes BATCH_STATUS=-1 and the 'MAP ERROR' TICKETS row. So SFTP failures we see logged as 'MAP ERROR' tickets in MAIN's context are typically GET_DOCS failures bubbling up.

### External Utilities Referenced

- `E:\Utilities\FA_FILE_CHECK.java` — Java file validator on the Sterling app server. Source not yet read.
- Python executables (for API_PULL) — paths come from per-Client `GET_DOCS_API` config, staged in `\\kingkong\Data_Processing\Pervasive\Python_EXE_files\!Python_Working`.

---

## `FA_CLIENTS_ETL_CALL` Detail (Deprecated — Reference Only)

`FA_CLIENTS_ETL_CALL` is the alternative dispatch target `FA_CLIENTS_GET_LIST` uses when the current Client block has `ETL_PATH` populated. **Confirmed deprecated by File Processing Supervisor** — no `CLIENTS_PARAM` rows currently have `ETL_PATH` populated, so this code path is never taken in practice. Retained in this document for reference and to support rapid re-integration should it ever be revived.

### What It Does (If Invoked)

ETL_CALL is a thin wrapper that invokes Pervasive Cosmos 9's Design Engine (`djengine.exe`) to execute a macro-based ETL transformation. It is NOT a SQL stored procedure executor. The command line invoked:

```
"C:\Program Files (x86)\Pervasive\Cosmos9\Common\djengine.exe" -mf $MARCOS_PATH $ETL_PATH
```

Where:
- `$MARCOS_PATH` — the `MARCOS_PATH` setting from `tbl_B2B_CLIENTS_SETTINGS` via the Settings/Values node. Likely a typo of "MACROS" that became canonical. Presumed to be a root directory path for Pervasive macro files.
- `$ETL_PATH` — per-Client path to the specific Pervasive transformation file (likely a `.tf.xml` or `.djm` macro). This is a file path, not a SP name.

FAC has a Pervasive Cosmos 9 installation (`C:\Program Files (x86)\Pervasive\Cosmos9\`) on the Sterling app server — a legacy ETL subsystem. Pervasive Cosmos was later rebranded as Actian DataConnect.

### Execution Flow

1. Release `INVOKE_ID_LIST` and capture own `thisProcessInstance`.
2. INSERT own row into `tbl_B2B_CLIENTS_BATCH_STATUS` (same pattern as MAIN).
3. If `PREV_SEQ` is set, enter `StatusUpdate` polling loop:
   - Wait 1 second
   - SELECT BATCH_STATUS from predecessor row (via CLIENT_ID + PREV_SEQ + PARENT_ID)
   - Loop while `Ready != 3`
4. Invoke `djengine.exe` with MARCOS_PATH and ETL_PATH parameters.
5. UPDATE own BATCH_STATUS to `1` on success.
6. If any fault, onFault sets own BATCH_STATUS = -1 and invokes `EmailOnError`.

### Known Divergences From MAIN

ETL_CALL differs from MAIN in several ways that may be deliberate design choices or quirks/bugs. Documented here for completeness should ETL_CALL ever be revived:

1. WAIT? condition is more restrictive — only exits on BATCH_STATUS=3 (MAIN exits on 3, 4, or 5)
2. No `-2` to `-1` conversion in the SELECT
3. Success terminal state is `1`, not a value in the 3-5 "done" range — so ETL_CALL cannot be a PREV_SEQ predecessor without causing an infinite polling loop
4. No `TICKETS` insert in onFault

If ETL_CALL ever gets revived, the collector will need dedicated handling for these divergences. Currently moot.

---

## Run Classification — File Process vs. Internal Operation

Not every MAIN run is a file process. Some MAIN runs exist to execute Integration stored procedures. The collector must distinguish these.

**Note:** PROCESS_TYPE alone cannot distinguish. `SPECIAL_PROCESS` is used by both legitimate entity processes (ACADIA SEQ_ID 6 and ACADIA EO SEQ_ID 1) and internal housekeeping (CLIENT_ID 328). Per File Processing Supervisor clarification, **SPECIAL_PROCESS is a catch-all for process configurations that "don't fit the standard process types"** — so expect variety in what SPECIAL_PROCESS runs actually do. The classification signal is the **configuration signature**, not the process type name.

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

**Process type field:** `<PROCESS_TYPE>` (sourced from CLIENTS_FILES).

### Multi-Client ProcessData — Clarified

Earlier revisions treated multi-Client ProcessData as a distinct case with subtleties. The BPML reads have clarified this: **MAIN only ever operates on `//Result/Client[1]`.** The presence of multiple `<Client>` blocks in a ProcessData document does not mean MAIN processes multiple clients.

**How multi-Client ProcessData arises:**

Looking at `FA_CLIENTS_GET_LIST`'s loop:
```xml
<operation name="This Service">
  <participant name="This"/>
  <output message="assignRequest">
    <assign to="from" from="concat('DocToDOM(PrimaryDocument)//Client[',//ClientCounter/text(),']')"></assign>
    <assign to="to" from="'//Result'"></assign>
  </o>
  ...
</operation>
```

Each iteration of the loop **copies one Client block** from `PrimaryDocument` (the full SP result set) into `//Result`. When MAIN is invoked, its inherited ProcessData contains:
- `//PrimaryDocument` — the full multi-Client result set from the SP
- `//Result` — only the current iteration's single Client block
- `//Result/Client[1]` — the single Client this MAIN invocation is responsible for

**So each MAIN invocation processes exactly one Client.** The multiple `<Client>` blocks we've observed in decompressed ProcessData are in `PrimaryDocument`, not `//Result`. They exist for reference / historical context, but MAIN doesn't act on them.

**Implication for execution tracking:** The grain is naturally one row per `(WORKFLOW_ID, Client[1].CLIENT_ID, Client[1].SEQ_ID)` — which for MAIN is effectively **one row per MAIN run** (the Client[1] is a function of the WORKFLOW_ID). No special handling needed for "multi-Client" cases.

### PREV_SEQ Semantics

`PREV_SEQ` is a **declaratively enforced sequential dependency reference**. It is NOT metadata-only.

When MAIN's `//Result/Client[1]/PREV_SEQ` is populated, MAIN's `Wait?` rule evaluates true and MAIN enters a polling loop against `tbl_B2B_CLIENTS_BATCH_STATUS`. The poll queries for the row matching `(CLIENT_ID = Client[1].CLIENT_ID, SEQ_ID = Client[1].PREV_SEQ, PARENT_ID = MAIN's parent_workflow_id)`. The loop waits until the BATCH_STATUS value exits the in-progress range.

When BATCH_STATUS = -1 (prior phase failed), the `Continue?` rule evaluates false and MAIN short-circuits — skipping all processing, running directly to the tail UPDATE, and exiting. This is a normal and expected behavior for failure cascade in sequential pipelines.

PREV_SEQ is populated in the result set by `USP_B2B_CLIENTS_GET_LIST` via `LAG(SEQ_ID) OVER (...)` window functions. The chaining conditions differ between the SP's two branches — see "`FA_CLIENTS_GET_LIST` Detail" section above.

### Failed Runs Have ProcessData

When a MAIN workflow fails (STATUS=1), ProcessData is still written at Step 0, BEFORE the failure occurs. The collector can extract ProcessData for failed runs normally — observed across multiple failure types (PGP decrypt failure, SSH disconnect, translation errors).

### Failure Signal — Nuanced

Real failure detection requires understanding three things:

**1. The reported failure step** — the step where `BASIC_STATUS` first becomes > 0. This is where Sterling records the failure state transition. Example: in a DENVER HEALTH NB failure, step 77 (Translation) had `BASIC_STATUS=1`.

**2. The root cause step** — may be earlier than the reported failure, and may have `BASIC_STATUS=0` despite being the real cause. Some services encode errors in `ADV_STATUS` without setting `BASIC_STATUS`. Example: in that same DENVER HEALTH failure, step 54 (`FA_CLA_UNPGP`) had `BASIC_STATUS=0` but `ADV_STATUS="255"` — the PGP decrypt exit code, which is the actual root cause. The later Translation failure was a downstream consequence of having nothing to translate.

**3. Base Sterling services can fail directly** — services like `SFTPClientBeginSession`, `AS3FSAdapter`, `AS2LightweightJDBCAdapter`, and `Translation` are base Sterling services, not FA_CLIENTS_* sub-workflows. They do NOT have `Inline Begin` markers. Failures at this level show up in `WORKFLOW_CONTEXT` but scanning only for sub-workflow invocations will miss them.

**Collector implication:** capture the failure **span** — the first error-coded step (by ADV_STATUS or BASIC_STATUS) through the final BASIC_STATUS>0 step. Record both the root cause step and the reported failure step. Don't rely solely on `BASIC_STATUS > 0`.

### Known Fields (Partial Inventory — ~70+ fields)

Detail retained from prior revisions. Sections on Identity, Process categorization, File input/output, Translation, SQL hooks, Sub-workflow flags, Archive, Processing helpers, Notification, Executable paths, Custom BP hooks, DM config.

**Notable fields:**
- `PREV_SEQ` — sequential phase dependency reference (see PREV_SEQ semantics above)
- `COMM_CALL_CLA_EXE_PATH` — external executable invocation (ACADIA EO uses `FA_MERGE_PLACEMENT_FILES.exe`)
- `COMM_CALL_WORKING_DIR` — working directory for the external exe
- `MISC_REC1` — observed as pipe-delimited FILE_FILTER list for SPECIAL_PROCESS pipeline orchestration; also passed as parameter to API_PULL Python exes
- `GET_DOCS_DLT` — delete-vs-archive flag (see GET_DOCS Detail for full semantics including archive-path variant)
- `ENCOUNTER_MAP` — specific translation map for ENCOUNTER process type
- `SEND_EMPTY_FILES` — whether to push even if no file was pulled (observed in SFTP_PULL OUTBOUND)
- `GET_DOCS_PROFILE_ID` / `PUT_DOCS_PROFILE_ID` — references to stored SFTP connection profiles
- `ETL_PATH` — deprecated; if populated would route to ETL_CALL, but no configurations currently use it
- `GET_DOCS_TYPE` — one of `SFTP_PULL`, `FSA_PULL`, `API_PULL`; note that GET_DOCS may mutate `API_PULL` to `FSA_PULL` mid-workflow
- `GET_DOCS_API` — Python exe path used by GET_DOCS when `GET_DOCS_TYPE = 'API_PULL'`
- `CUSTOM_FILE_FILTER` — `Y` flag that triggers dynamic XPath evaluation of `FILE_FILTER`
- `GET_EMPTY_DOCS` — `Y` flag that overrides the zero-size skip in GET_DOCS
- `FILE_ID` — when nonzero, forces GET_DOCS into single-file mode (no iterative loop)

### Settings Block

ProcessData also includes a `//Settings/Values/...` node populated by `USP_B2B_CLIENTS_GET_SETTINGS`. Fields include:

- `DATABASE_SERVER` — used by Python exe parameters
- `API_PORT`
- `DM_NB_PATH`, `DM_PAY_PATH`, `DM_BDL_PATH` — standard delivery paths per process type
- `DEF_PRE_ARCHIVE`, `DEF_POST_ARCHIVE` — default archive roots, concatenated when entity's PRE/POST_ARCHIVE is set to `'Y'`
- `PYTHON_KEY` — **plaintext credential**
- `MARCOS_PATH` — root directory for Pervasive Cosmos 9 macro files, passed to `djengine.exe -mf` as the first argument by `FA_CLIENTS_ETL_CALL`. Moot in current operation since ETL_CALL is deprecated.

### Sensitive Data in ProcessData

ProcessData may contain credentials in plaintext:

- `PGP_PASSPHRASE` — populated for entities sending PGP-encrypted files. Contains the decryption passphrase in plaintext. Example observed: DENVER HEALTH NB.
- `PYTHON_KEY` (in Settings) — plaintext Python API key per the GET_SETTINGS SP inventory.
- Other plaintext secrets may appear in less-commonly-set fields.

**Architectural decision on credential handling (resolved):** Capture ProcessData raw — the full decompressed XML is stored in `SI_ExecutionTracking.process_data_xml` as an NVARCHAR(MAX) column alongside the parsed field columns. Rationale:

- These credentials already exist in plaintext in Integration's `tbl_B2B_CLIENTS_SETTINGS` and in Sterling's own configuration — all under the same backup/DR scope as xFACts
- Capturing in xFACts does not meaningfully expand exposure
- Redaction belongs at the UI layer (Phase 5), not at storage — the forensic value of the raw XML is significant and should not be lost to pre-processing

This decision moots the earlier-planned `SI_ProcessDataCache` table. One row per execution, raw XML inline.

---

## Empty-Run and Short-Run Behavior

Multiple varieties of "nothing happened" MAIN runs have been observed:

**~49-step Internal Operation skeleton** (CLIENT_ID=328 SP executors): MAIN enters processing but most rules evaluate false; the SP executes and MAIN exits. Low step count reflects the fact that PREP_SOURCE, TRANS, VITAL, etc. all don't fire.

**Short-circuit runs** (PREV_SEQ dependency failed): `Continue?` evaluates false, entire processing block is skipped. Run goes straight from StatusUpdate loop to tail UPDATE. Step counts in the 15-35 range, very short duration. **Previously called "Path E"; reframed as "short-circuit due to upstream failure."**

**Failed runs**: step count depends on when the failure occurs. ProcessData is written normally. The failing step's `BASIC_STATUS` and `ADV_STATUS` identify the failure (with caveats — see Failure Signal section).

**Real File Processes with no files** (Pattern 4 pullers where GET_DOCS finds nothing): likely resembles the Internal Op skeleton. Specific anatomy still to be traced.

**Collector implication:** "no work happened" is not a single condition. Different short-run signatures correspond to different reasons. The collector should capture:

- Count of `FA_CLIENTS_TRANS` invocations — if 0, no data was translated
- Count of each major sub-workflow invocation
- Whether `Continue?` was taken (deduce from presence or absence of downstream sub-workflow invocations)
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

The 16:00 hour is the largest observed cluster. Clustering at hours 6 apart (04, 10, 16) is suggestive but not fully understood — could indicate remote-server scheduled activity or Sterling-side periodic events.

**Scope note:** SFTPClientBeginSession is a base Sterling service, not a FA_CLIENTS_* sub-workflow. It has NO `Inline Begin` marker. Scanning only for sub-workflow invocations will miss this failure.

**Corresponding TICKETS row:** when this failure propagates out of MAIN's onFault, a TICKETS row is inserted with type `'MAP ERROR'`. The ticket type name is misleading for this failure class (it's a transport error, not a translation error).

### FA_CLA_UNPGP Exit Code 255

**Signature:**
- Step ~54 (within PREP_SOURCE phase), `SERVICE_NAME = FA_CLA_UNPGP`, `BASIC_STATUS = 0`, `ADV_STATUS = "255"`
- Step ~55: `AS3FSAdapter` with `ADV_STATUS = "No files to collect"`
- Later in the workflow: Translation fails with `BASIC_STATUS = 1`

**Cause:** PGP decryption via `FA_CLA_UNPGP` command-line adapter failed. 255 is a generic process failure exit code.

**Only applies to configurations where `PGP_PASSPHRASE` is populated** in ProcessData. Observed on DENVER HEALTH NB.

**Critical detection nuance:** The root cause step has `BASIC_STATUS = 0`. The `BASIC_STATUS > 0` signal only fires later at Translation. Collectors scanning for `BASIC_STATUS > 0` will detect the workflow failed but will point to the wrong step.

---

## Execution Tracking Design

This section is the build spec for `SI_ExecutionTracking` — the core v1 deliverable of the B2B module. Complemented by forward-looking design notes for `SI_ExecutionDetail` (future).

### Design Principles

**"Collect everything possible up front."** We do not process the same things each day, so sampling-based column design is unreliable. There will almost certainly be runs in the next few weeks representing configurations we haven't looked at yet. It's much easier to drop a column after the fact than to add one on the fly because a new execution crashed the collector and we have to do a fix while it's live. So every known ProcessData field gets its own parsed column AND the raw ProcessData XML is stored on the same row for future-proofing against fields we don't yet recognize.

**Single-table design.** Raw ProcessData XML lives as an `NVARCHAR(MAX)` column on `SI_ExecutionTracking` itself — no separate cache table. This aligns with the "as few scripts and tables as possible" principle and simplifies the collector (one write path, one MERGE).

**Forward-looking columns for future detail table.** The design includes columns that will become useful when `SI_ExecutionDetail` (Phase 3 Block 3) is built — notably `merged_output_file_name` (the single post-merge file that downstream Batch Monitoring will see) and `has_detail_captured` (bit, supports incremental backfill when detail extraction turns on). This avoids retrofit pain later.

### Header Level — `SI_ExecutionTracking`

**Grain:** one row per `FA_CLIENTS_MAIN` `WORKFLOW_ID`.

Since each MAIN run processes exactly one Client (at `//Result/Client[1]`), the natural grain is simply "one row per MAIN run." Client[1]'s CLIENT_ID and SEQ_ID become columns on that row. There is no multi-Client grain explosion because MAIN doesn't operate on multiple Clients per run.

**Parent-child clustering:** the collector will capture `parent_workflow_id` (the MAIN's immediate parent — typically a Pattern 4 wrapper or GET_LIST) and `root_workflow_id` (the dispatcher root — typically the named wrapper). This allows rolling up "a pipeline invocation" (e.g., all 4 phases of an ACADIA EO run) without denormalization.

### Grain Question — Resolved

The prior open question about Pattern 5 grain (one row per Client block × one row per worker = 16 rows for 1 conceptual pipeline) is **no longer relevant**. That framing was based on the incorrect model of "4 workers sharing one multi-Client ProcessData." The correct model is "GET_LIST loops over 4 SP result rows, invoking MAIN once per row, each with single-Client ProcessData." So 4 MAIN runs = 4 rows in SI_ExecutionTracking. One row per conceptual phase. Clean.

### Columns

The column design reflects the Source of Truth stance: b2bi fields are authoritative, Integration fields are enrichment, and several derived "disagreement" flags turn the b2bi-vs-Integration gap into actionable alert signals rather than silent data loss.

**Core execution identity (from `b2bi.dbo.WF_INST_S` — AUTHORITATIVE):**
- `workflow_id` — PK
- `workflow_start_time`, `workflow_end_time`, `duration_ms`
- `b2bi_status` (WF_INST_S.STATUS)
- `b2bi_state` (WF_INST_S.STATE)
- `step_count` (count of WORKFLOW_CONTEXT rows)

**Workflow tree (from `b2bi.dbo.WORKFLOW_LINKAGE`):**
- `parent_workflow_id` — immediate parent (typically a Pattern 4 wrapper or GET_LIST)
- `root_workflow_id` — dispatcher root (useful for pipeline rollup)

**Process identity (from ProcessData / `TRANS_DATA` — AUTHORITATIVE for "what Sterling actually processed"):**
- `client_id`, `seq_id` — from `//Result/Client[1]`
- `client_name`
- `process_type`, `comm_method`, `business_type`
- `translation_map`, `file_filter`, `get_docs_type`
- `run_class` — derived classification: `FILE_PROCESS` / `INTERNAL_OP` / `UNCLASSIFIED`
- All other ~70 parsed ProcessData fields (per the Known Fields inventory above) — one column each, captured every time for "collect everything" coverage

**Raw ProcessData (forensic — from ProcessData / `TRANS_DATA`):**
- `process_data_xml` — NVARCHAR(MAX), the full decompressed ProcessData XML. Credentials are captured raw per the architectural decision documented above; UI-layer redaction planned for Phase 5.

**Failure detail (from `b2bi.dbo.WORKFLOW_CONTEXT` — AUTHORITATIVE):**
- `root_cause_step_id`, `root_cause_service_name`, `root_cause_adv_status`
- `failure_step_id`, `failure_service_name`
- `status_message` (summary of failure context)

**Sub-workflow invocation summary (from `b2bi.dbo.WORKFLOW_CONTEXT`):**
- `had_trans`, `had_vital`, `had_accounts_load`, `had_comm_call`, `had_archive` — bit flags indicating which major sub-workflows were invoked
- `trans_invocation_count` — proxy for file count processed
- `archive_invocation_count` — proxy for archive phase activity (pre/post/post2)

**Integration enrichment (SUPPLEMENTARY — never gating; populated via live-join in collector):**
- `int_batch_status` — BATCH_STATUS.BATCH_STATUS value, or NULL if row missing
- `int_batch_parent_id` — BATCH_STATUS.PARENT_ID (Integration-side dispatcher RUN_ID)
- `int_batch_finish_date` — BATCH_STATUS.FINISH_DATE
- `int_ticket_type` — TICKETS.TICKET_TYPE if a matching ticket exists (e.g., `'MAP ERROR'`, `'CLIENTS GET LIST'`)
- `int_ticket_created_date`

**Disagreement flags (DERIVED — the alert-generating signal):**
- `int_status_missing` — BATCH_STATUS row not present for this RUN_ID
- `int_status_inconsistent` — b2bi reports FAILED but Integration doesn't reflect failure state
- `alert_infrastructure_failure` — b2bi FAILED + Integration blind (either missing or in-progress); this is the "Sterling crashed before reporting" signal

**Forward-looking for detail/lifecycle (populated when identifiable):**
- `merged_output_file_name` — the single output filename produced by `FA_CLIENTS_FILE_MERGE` (for NB/PAYMENT file processes). This is the bridge to Batch Monitoring — DM sees this merged file, not the individual source files. Source file list lives in `SI_ExecutionDetail` when that table is built.
- `merged_output_file_size` — if extractable
- `has_detail_captured` — bit, default 0; flipped to 1 when Block 3 detail extraction processes this row. Supports incremental backfill when detail collection turns on.

**Lookback optimization (completion tracking):**
- `is_complete` — BIT NOT NULL DEFAULT 0. Flipped to 1 when the row has reached a terminal state in both b2bi and Integration. Enables the lookback query to exclude already-finalized rows on every cycle. See "Lookback Optimization" subsection below.
- `completed_dttm` — DATETIME2(3) NULL. When the row transitioned to `is_complete = 1`.
- `completed_status` — NVARCHAR(50) NULL. Snapshot of the terminal status at completion (e.g., `'SUCCESS'`, `'FAILED'`, `'INFRASTRUCTURE_FAILURE'`). Lets alert evaluation skip rows without re-reading all the status columns.

**Metadata:**
- `collected_dttm` — when the collector wrote this row
- `last_enriched_dttm` — last time Integration enrichment was attempted (supports re-enrichment windows for lagging BATCH_STATUS updates)

### Lookback Optimization (`is_complete` pattern)

Every cycle, the collector queries `b2bi.dbo.WF_INST_S` for `FA_CLIENTS_MAIN` runs within a 3-day lookback window. At ~2,300 MAIN runs/day, a naïve implementation would reprocess ~6,900 workflow_ids per cycle — most of which are already in `SI_ExecutionTracking` in a terminal state and have no new information to capture.

The `is_complete` flag short-circuits that waste. Every cycle's workload scales with "new + in-flight" runs, not total lookback volume:

```sql
-- Step 1 query pattern (conceptual)
SELECT w.WORKFLOW_ID, w.WFD_ID, ...
FROM b2bi.dbo.WF_INST_S w
WHERE w.START_TIME >= @lookback_start
  AND w.WFD_ID = 798  -- FA_CLIENTS_MAIN
  AND NOT EXISTS (
      SELECT 1 FROM B2B.SI_ExecutionTracking t
      WHERE t.workflow_id = w.WORKFLOW_ID
        AND t.is_complete = 1
  )
```

**Terminal-state criteria** for flipping `is_complete = 1`:

| b2bi state | Integration state | Transition to is_complete = 1? |
|---|---|---|
| SUCCESS | BATCH_STATUS in (2, 3, 4, 5) | Yes — both sides agree on terminal success |
| FAILED | BATCH_STATUS = -1 | Yes — both sides agree on terminal failure |
| FAILED | NULL / in-progress / row missing | Yes — but with `completed_status = 'INFRASTRUCTURE_FAILURE'` (the disagreement is itself terminal for this row; no further Integration update will change our interpretation) |
| SUCCESS | NULL / in-progress | **No** — wait for Integration to catch up (re-enrichment will retry on subsequent cycles) |
| RUNNING / LAUNCHED | any | **No** — workflow still in progress on Sterling side |

**Manual override:** setting `is_complete = 1` on any row excludes it from future processing AND future alert evaluation. This is the intended escape hatch for known-bad workflows that would otherwise generate repeated alerts — a row manually flipped is "we've seen this, we've decided it doesn't need attention, move on."

The collector will not automatically flip `is_complete` back from 1 to 0 under any circumstances. Manual intervention is required to re-examine a row (which is rare and appropriate — a completed workflow is a settled historical record, not a live target).

### Integration Source Trust Matrix

Different Integration tables have different trust levels based on their population mechanism. The collector must not treat them uniformly. All queries are **live-joined** from the collector; no tables are mirrored locally.

| Integration Table | Trust as Execution Source | Trust as Enrichment | How the Collector Uses It |
|---|---|---|---|
| `tbl_B2B_CLIENTS_MN` | — (not an execution source) | HIGH | Live-join for entity name enrichment on captured execution rows |
| `tbl_B2B_CLIENTS_FILES` | — (not an execution source) | HIGH | Live-join if additional process-level classification needed; typically ProcessData already has it |
| `tbl_B2b_CLIENTS_PARAM` | — (not an execution source) | HIGH | Not routinely queried — ProcessData captures the same values at runtime |
| `tbl_B2B_CLIENTS_SETTINGS` | — (not an execution source) | MEDIUM | Not routinely queried — Settings/Values node in ProcessData captures the active settings |
| `tbl_B2B_CLIENTS_BATCH_STATUS` | **LOW** — never use as primary | MEDIUM | Live-join for enrichment; monitor for disagreement with b2bi as alert signal |
| `tbl_B2B_CLIENTS_TICKETS` | LOW (incomplete coverage) | MEDIUM as classification signal | Live-join for ticket_type enrichment; never treat absence as "no failure" |
| `tbl_B2B_CLIENTS_BATCH_FILES` | LOW (scope-limited) | HIGH **within its scope** (zero-size + FILE_DELETION) | Potentially live-joined for FILE_DELETION activity metrics; decision pending Block 3 design |
| `tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` | — (it's discovery input, not execution) | Reference only | Possible future "expected vs. processed" comparison downstream |

**Key principle:** Integration tables that are HIGH trust are config-derived (static, human-maintained) or scope-limited-but-complete-within-scope. Integration tables that are LOW trust are written by Sterling BPMLs at runtime and can be missed when those BPMLs fail in specific ways.

### Disagreement Interpretation Matrix

The combinations of b2bi state and Integration state, interpreted as actionable signals:

| b2bi state | Integration BATCH_STATUS | Interpretation | Action |
|---|---|---|---|
| SUCCESS | 2, 3, 4, or 5 | Normal — everything cooperated | None |
| FAILED | -1 | Normal failure — fault handler fired, cleaned up properly | Standard failure alerting via WORKFLOW_CONTEXT detail |
| FAILED | NULL or 0/1/2 (in-progress) | **Sterling crashed before fault handler could update Integration** | High-severity alert: infrastructure-level failure |
| FAILED | Row missing entirely | **Sterling crashed before BATCH_STATUS INSERT** | High-severity alert: early-phase crash |
| SUCCESS | NULL or in-progress | **Anomaly** — b2bi says done but Integration wasn't updated | Medium-severity investigation flag |
| Row missing in b2bi | Any value | **Shouldn't happen** — BATCH_STATUS row exists for workflow that doesn't | Anomaly to investigate (indicates a collection-lag or deeper issue) |

The "Sterling crashed before reporting" row is the one that directly addresses the historical concern of "failures that weren't reflected in Integration." Under the old architecture these weren't surfaced. Under the new architecture they become named alert classes with their own severity.

### Collector Flow — `Collect-B2BExecution.ps1`

The planned collector follows a b2bi-primary-then-enrich pattern, handling both schedule sync and execution tracking in a single script.

```
Per collection cycle (target frequency: every 5 minutes):

0. [Schedule sync] Query b2bi.SCHEDULE for all schedules; decompress TIMINGXML
   for any new or changed entries; issue per-row INSERT/UPDATE/DELETE to match
   SI_ScheduleRegistry against b2bi. Cheap; runs every cycle but typically
   reports 0 changes after initial populate.

1. [b2bi primary] Query WF_INST_S for FA_CLIENTS_MAIN runs that started within
   the 3-day lookback window AND whose workflow_id is NOT already marked
   is_complete = 1 in SI_ExecutionTracking.
   -> Anti-join against is_complete = 1 rows so terminal workflows are
      invisible to subsequent cycles. Per-cycle workload scales with
      "new + in-flight" count, not total lookback volume.
   -> This produces the list of workflow_ids that need a (new) row or a
      (still-in-flight) refresh in SI_ExecutionTracking.

2. [b2bi enrichment] For each captured workflow_id:
   a. Query WORKFLOW_LINKAGE for parent_workflow_id + root_workflow_id.
   b. Query WORKFLOW_CONTEXT for step count + sub-workflow invocation markers.
   c. If the workflow failed: deep-scan WORKFLOW_CONTEXT for root-cause and
      reported-failure steps (capturing the failure span, not just the final step).
   d. Query TRANS_DATA for ProcessData; decompress gzip; parse //Result/Client[1]
      fields into their columns; store raw decompressed XML in process_data_xml.
   e. Extract merged_output_file_name if FA_CLIENTS_FILE_MERGE was invoked.

3. [Integration enrichment — bulk live-join] After accumulating a batch of b2bi results:
   a. Bulk query Integration.BATCH_STATUS for matching RUN_IDs.
   b. Bulk query Integration.TICKETS for matching RUN_IDs.
   c. (As needed) Bulk query Integration.CLIENTS_MN for entity name lookups.
   d. In-memory hash-join in PowerShell onto the b2bi-keyed rows.
   e. Compute int_status_missing, int_status_inconsistent,
      alert_infrastructure_failure flags.

4. [Completion assessment] For each row, evaluate whether both sides have
   reached a terminal state per the Lookback Optimization criteria above.
   Rows meeting the terminal criteria get is_complete = 1, completed_dttm =
   GETDATE(), and completed_status set to the appropriate terminal label.
   Rows still in flight (e.g., b2bi SUCCESS but Integration still in-progress)
   remain is_complete = 0 for re-evaluation on a later cycle.

5. [Write] MERGE into SI_ExecutionTracking.

6. [Advance] Update high-water mark.
```

**Why this ordering:** b2bi is polled first and independently so Integration-side failures can never cause us to miss execution data. Integration is queried in bulk at the end rather than per-row for efficiency. The disagreement flags are computed from the joined result rather than requiring a separate reconciliation pass. Schedule sync runs first because it's cheap and independent — if it fails, execution collection still proceeds.

**Initial operation:** manual runs first (pre-schedule) to validate correctness and timing. Once observed stable, cron at 5-minute intervals.

**One-time historical backfill:** after the collector is validated, a one-time backfill run will pull whatever history is still available against Integration tables (BATCH_STATUS, TICKETS) for runs that have already been purged from b2bi but still have Integration traces. This is expected to be partial — b2bi's aggressive purging means most history is already gone — but every row we recover is value. Rows recovered via backfill will have `b2bi_status`, `b2bi_state`, ProcessData, and WORKFLOW_CONTEXT detail all NULL (because b2bi no longer has them), but `int_*` columns will be populated.

### Operational Risks to Monitor During Build

Things to watch for once the collector is running:

1. **Volume.** Roughly 2,300 MAIN runs/day observed. Each requires WF_INST_S row + 5-200 WORKFLOW_CONTEXT rows + 1 ProcessData blob. Batch sizes and collection cadence need tuning.
2. **ProcessData decompression cost.** Compressed blobs are typically 5-20 KB; decompression is cheap per-blob but accumulates. Raw XML column storage is estimated ~40GB at 3-year retention — acceptable.
3. **Cross-server latency.** b2bi (FA-INT-DBP) and Integration (AVG-PROD-LSNR) are separate servers with no linked server. Each collection cycle makes separate DB calls. Acceptable for batch collection.
4. **Disagreement rate calibration.** If `alert_infrastructure_failure` fires on 5%+ of runs, it's noise. If it fires on <0.1%, it's high-signal. Rate is unknowable until we're collecting. Threshold tuning happens after initial observation period.
5. **High-water mark robustness.** Collection restart, clock skew, or a collector crash mid-cycle shouldn't produce duplicate or missed rows. The MERGE pattern handles duplicates; the 3-day lookback handles missed rows within b2bi retention.
6. **Enrichment lag.** BATCH_STATUS and TICKETS may be updated after the initial b2bi row capture (e.g., a late tail UPDATE). The `is_complete` flag handles this naturally — rows where b2bi is SUCCESS but Integration is still in-flight remain `is_complete = 0` and get re-enriched on subsequent cycles until Integration catches up. `last_enriched_dttm` supports re-enrichment budgeting (e.g., "don't re-query rows enriched within the last 2 minutes").
7. **Manual override of `is_complete`.** Operators may flip `is_complete = 1` on individual rows to silence repeated alerts from known-bad workflows. This is by design — the manual override treats a row as settled regardless of what the data says. Monitor for overuse: if many rows are being manually flipped, investigate whether the alert logic itself needs tuning rather than using manual flips as a patch.

### Detail Level — `SI_ExecutionDetail` (Future — Phase 3 Block 3)

Middle-grain extraction layer for per-file and per-creditor-within-file summary information. **Design deferred** until the "skinny" Translation output pattern is reliably identified across process types — this is a prerequisite investigation item.

**Current working understanding:**
- Source: Translation output documents per MAIN run. Each run produces multiple DOCUMENT rows in TRANS_DATA (~12 observed in one NB run); 3-4 of those are XML outputs containing different segments of import data.
- Target: the **"skinny" output** — characterized by a file-name header followed by individual account rows with balance and intended creditor keys. This is distinct from the denser demographic/full-data XML outputs which carry much more than we need for summary grain.
- Identification across process types: not yet established. NB observations are a starting point; each other process type's Translation output structure needs investigation as anatomies are traced.

**Grain (working assumption):** one row per `(workflow_id, file_index, dm_creditor_key)`, with an "unmatched" bucket for records not matched to a creditor. The single merged output filename lives on `SI_ExecutionTracking` (not duplicated here) — the detail table focuses on the per-source-file breakdown.

**Collector integration:** the same `Collect-B2BExecution.ps1` gains a toggleable detail-extraction pipeline step when this block activates. The `has_detail_captured` bit on `SI_ExecutionTracking` supports incremental backfill — rows with `has_detail_captured = 0` are eligible for extraction.

**Role in lifecycle bridging:** this table (plus the merged-output-filename on `SI_ExecutionTracking`) is the B2B module's contribution to the File Monitoring → B2B → Batch Monitoring lifecycle view. Upstream File Monitoring has the source file list with submission timestamps; `SI_ExecutionDetail` will tie those source files to MAIN runs that processed them; `SI_ExecutionTracking.merged_output_file_name` will tie each run to the single merged output that Batch Monitoring will see on the DM side.

---

## SI_ScheduleRegistry — Schedule Catalog

This section documents the other Sterling data asset the collector maintains: a structured mirror of Sterling's own schedule registry. This is distinct from execution tracking — it's about *when things are supposed to run*, not *what has run*. Putting it in its own top-level section reflects the multi-functional nature of `Collect-B2BExecution.ps1`: the collector is the home for any b2bi data that needs to land in xFACts, not just execution data.

**Status:** ✅ Built and populated as of April 22, 2026.

### Purpose

Sterling's `b2bi.dbo.SCHEDULE` table stores timing definitions for every scheduled workflow in the environment. The timing information is encoded in a gzip-compressed XML blob (`TIMINGXML` column, resolved via `DATA_TABLE`) with its own small grammar. `SI_ScheduleRegistry` captures each schedule as one row, with the TIMINGXML parsed into structured query-friendly columns plus a human-readable description string.

This registry serves three near-term and long-term purposes:

1. **Reference for the Control Center** — a queryable catalog of what schedules exist and when they fire, without every CC page needing to crack TIMINGXML itself.
2. **Foundation for Phase 4 schedule-adherence monitoring** — comparing actual runs (captured in `SI_ExecutionTracking`) against expected schedules (captured here) surfaces the "this daily process didn't run today" case that's currently invisible to the Apps team.
3. **Operational visibility into Sterling-native services** — the registry captures Sterling's own internal maintenance schedules (BackupService, BPExpirator, IndexBusinessProcessService, etc.) alongside FAC-owned workflows. If Sterling's housekeeping stops running, we see it.

### Grain and Naming Convention

**Grain:** one row per `b2bi.dbo.SCHEDULE.SCHEDULEID`.

**Naming convention:** `FA_*` prefix identifies FAC-owned workflows; all other names are Sterling-native services. The registry captures both — it's a full mirror of Sterling's schedule population. Consumers (CC pages, monitoring logic) filter by naming convention or by `source_status` as needed.

### Column Design

25 columns total. Grouped by role:

**Source identity (from `b2bi.dbo.SCHEDULE` — authoritative):**
- `schedule_id` — PK, maps directly to SCHEDULE.SCHEDULEID
- `service_name` — workflow name that this schedule fires
- `schedule_type`, `schedule_type_id`, `execution_timer` — Sterling's internal schedule-type identifiers
- `source_status` — SCHEDULE.STATUS (`ACTIVE` / `INACTIVE` — used by CC filtering)
- `execution_status` — SCHEDULE.EXECUTIONSTATUS (Sterling's live status)
- `timing_xml_handle` — the raw TIMINGXML foreign key (SCHEDULE.TIMINGXML, an int that references DATA_TABLE)
- `source_system_name` — SCHEDULE.SYSTEMNAME
- `source_user_id` — SCHEDULE.USERID (who last modified)

**Parsed timing structure (from decompressed TIMINGXML):**
- `timing_pattern_type` — one of `DAILY`, `WEEKLY`, `MONTHLY`, `INTERVAL`, `MIXED`, `UNKNOWN`. Classification is derived from which XML elements are present (see Pattern Classification below).
- `run_day_mask` — CHAR(7). Week-day mask in Sun-Mon-Tue-Wed-Thu-Fri-Sat position order. Letter for day present, `-` for day absent. Examples: `SMTWTFS` = every day; `-MTWTF-` = Mon-Fri; `S-----S` = weekends only. Position is authoritative, not the letter (the two S's for Sun/Sat share a letter but different positions).
- `run_days_of_month` — comma-separated day numbers for MONTHLY patterns (e.g., `1,15` or `5`)
- `run_times_explicit` — comma-separated HH:MM times for DAILY/WEEKLY/MONTHLY patterns (e.g., `05:00,06:00,07:00,08:00,09:00,10:00,11:00,12:00,13:00,14:00,15:00,16:00,17:00,18:00`)
- `run_interval_minutes` — integer interval in minutes for INTERVAL/MIXED patterns
- `run_range_start`, `run_range_end` — HH:MM window bounds for INTERVAL/MIXED patterns
- `run_on_minute` — minute offset for INTERVAL patterns (currently always 0 or NULL in observed data; captured for completeness)
- `excluded_dates` — comma-separated MM-DD dates to skip (e.g., `01-01,12-25` for New Year's and Christmas)

**Derived / computed columns:**
- `first_run_time_of_day`, `last_run_time_of_day` — earliest and latest HH:MM in the day (supports "does this run during business hours?" queries without parsing the detail columns)
- `expected_runs_per_day` — estimated daily run count based on pattern + times (supports volume comparison against `SI_ExecutionTracking`)
- `schedule_description` — human-readable rendering of the full schedule. Built from the parsed columns per pattern-type rules. Example: `"Every 60 min at :05, 05:05-15:05, Mon-Fri (excl. 01-01,12-25)"` for `FA_CLIENTS_GET_LIST`.

**Preservation:**
- `timing_xml` — NVARCHAR(MAX) storing the raw decompressed TIMINGXML for any schedule the parser couldn't fully classify (`timing_pattern_type = 'UNKNOWN'`) or for forensic inspection. Not indexed.

**Metadata:**
- `last_modified_dttm` — when the collector last wrote this row

### Pattern Classification

Sterling's TIMINGXML grammar supports several timing patterns. The parser classifies each into one of six types based on element presence:

| Pattern Type | TIMINGXML Indicators | Meaning | Example |
|---|---|---|---|
| `DAILY` | `<day ofWeek="-1">` (every day) with `<time>` entries (no `<timeRange>`) | Runs every day at one or more fixed times | `FA_FROM_REVSPRING_IB_BD_PULL` — 14 explicit times 05:00-18:00 |
| `WEEKLY` | `<day ofWeek="N">` for specific days, with `<time>` entries | Runs on specific weekdays at fixed times | `FA_TO_JEFFERSON_DAVIS_OB_BD_S2P_RM` — Mondays at 11:06 |
| `MONTHLY` | `<day ofMonth="N">` entries, with `<time>` entries | Runs on specific days of the month | `FA_TO_FAST_PACE_OB_BD_S2D_NT` — day 3 at 10:00 |
| `INTERVAL` | `<day ofWeek="-1">` with `<timeRange>` (range+interval+onMinute) | Runs repeatedly across a time range every day | `BPExpirator` — every 15 min, 00:00-23:59, daily |
| `MIXED` | `<day ofWeek="N">` for specific days with `<timeRange>` | Runs at intervals within a range on specific days | `FA_CLIENTS_GET_LIST` — every 60 min, 05:05-15:05, Mon-Fri |
| `UNKNOWN` | Anything the parser doesn't recognize — malformed, truncated, or novel pattern structure | Fallback bucket. `timing_xml` column preserves the raw payload for manual review. |

**Current distribution** (604 rows as of April 22, 2026):

| Type | Count |
|---|---:|
| DAILY | 231 |
| WEEKLY | 172 |
| MONTHLY | 167 |
| INTERVAL | 29 |
| MIXED | 5 |
| UNKNOWN | 0 |

Zero UNKNOWN rows across the full population — the parser handles every observed TIMINGXML variant cleanly. This is a meaningful confidence signal: Sterling's TIMINGXML grammar is narrower than it could be in theory, and Sterling's schedule authoring surface reliably produces parseable output.

### Collection Pattern

The collector fetches schedules via a single JOIN query against `b2bi.dbo.SCHEDULE` and `b2bi.dbo.DATA_TABLE`:

```sql
SELECT s.SCHEDULEID, s.SERVICENAME, s.SCHEDULETYPE, s.SCHEDULETYPEID,
       s.EXECUTIONTIMER, s.STATUS, s.EXECUTIONSTATUS, s.TIMINGXML,
       s.SYSTEMNAME, s.USERID,
       dt.DATA_OBJECT AS TIMING_BLOB
FROM dbo.SCHEDULE s
LEFT JOIN dbo.DATA_TABLE dt ON dt.DATA_ID = s.TIMINGXML
WHERE s.TIMINGXML IS NOT NULL AND s.TIMINGXML <> ''
ORDER BY s.SCHEDULEID
```

One round trip retrieves all schedules and all their compressed blobs. This is a meaningful savings over the naïve approach (one query for schedules, then one per-schedule query for TIMINGXML); at 604 schedules, the savings is ~600 avoided round trips per cycle.

Each compressed blob is decompressed in-memory (gzip via `System.IO.Compression.GZipStream`) and parsed by the TIMINGXML parser. The collector then compares the decoded structure to the existing registry row and issues per-row `INSERT`, `UPDATE`, or `DELETE` as appropriate:

- **INSERT** — schedule_id not present in registry
- **UPDATE** — any of `timing_xml_handle`, `source_status`, `execution_status` differs (other derived columns are updated implicitly)
- **DELETE** — schedule_id in registry but no longer in source

The registry is idle-stable: on a cycle with no Sterling-side schedule changes, the collector reports 0/0/0/0 (inserts/updates/deletes/errors) without writing anything.

### Collection Performance

Observed in production (604 schedules, April 22, 2026):

- **First-run populate:** ~4.5 seconds (604 INSERTs including full XML parse for each row)
- **Idle cycle:** <1 second (reads source, compares, finds no changes, exits)
- **Typical change cycle:** 1-2 seconds (a handful of schedule updates between cycles is uncommon)

Runtime is dominated by the TIMINGXML decompression loop, not SQL round trips. At steady state, the collector's schedule-sync step is essentially free against the orchestrator's 5-minute cadence budget.

### Design Principles Applied

- **Lean registry design.** No `first_seen` / `last_seen` / `is_deleted_in_source` columns. Deletions are by row removal rather than flag; schedule_id disappearing from `b2bi.dbo.SCHEDULE` triggers an explicit DELETE rather than a logical delete. This reflects a design philosophy: when the source table authoritatively says "this schedule exists now," audit columns tracking "when we first saw it" are unneeded complexity.
- **Capture everything Sterling has.** Both ACTIVE and INACTIVE schedules are captured; both FAC-owned and Sterling-native services. Filtering happens at the query layer in the consumer (CC page, monitoring logic), not at the registry boundary. This avoids having to remember later "what did we choose to exclude, and would we want it back now?"
- **Raw TIMINGXML preservation.** For any row classified as `UNKNOWN`, the raw decompressed XML is retained in `timing_xml` for inspection. This is cheap insurance — if we ever encounter a schedule pattern the parser doesn't handle, we have the source material to extend the classifier.

---

## Integration Source Query Reference

Since no Integration tables are mirrored, the collector performs live queries against the Integration DB for enrichment. Key patterns (detailed query text in `B2B_Reference_Queries.md`):

- **Entity name lookup** — `SELECT CLIENT_ID, CLIENT_NAME FROM Integration.etl.tbl_B2B_CLIENTS_MN WHERE CLIENT_ID IN (...)` — bulk-query in cycle, hash-join in PowerShell memory
- **BATCH_STATUS enrichment** — `SELECT CLIENT_ID, SEQ_ID, RUN_ID, PARENT_ID, BATCH_STATUS, FINISH_DATE FROM Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS WHERE RUN_ID IN (...)` 
- **TICKETS enrichment** — `SELECT RUN_ID, TICKET_TYPE, TICKET_CREATED FROM Integration.ETL.tbl_B2B_CLIENTS_TICKETS WHERE RUN_ID IN (...)`

**Cross-server constraint:** no linked server exists between FA-INT-DBP (b2bi) and AVG-PROD-LSNR (Integration). All cross-server joining happens in PowerShell via in-memory hash-join after separate `Invoke-Sqlcmd` calls. This is the standing pattern for the collector.

---

## Process Type Investigation Status

Distinct PROCESS_TYPE × COMM_METHOD pairs observed in `tbl_B2B_CLIENTS_FILES` (observed-in-practice list, not authoritative lookup — new types may be added as teams configure them):

| # | PROCESS_TYPE | COMM_METHOD | Anatomy Status | Notes |
|--:|---|---|---|---|
| 1 | NEW_BUSINESS | INBOUND | ✅ Live-traced (ACADIA), ⚠️ PGP variant (DENVER HEALTH) | See `B2B_ProcessAnatomy_NewBusiness.md`. PGP variant needs separate documentation. |
| 2 | FILE_DELETION | INBOUND | ⚠️ Partially traced (ACADIA) | SFTP remote cleanup on Joker server. Only configured for clients that submit un-needed files. Delete logic lives in `FA_CLIENTS_GET_DOCS`, not MAIN. |
| 3 | SPECIAL_PROCESS | INBOUND | ⚠️ ProcessData seen (ACADIA EO) | Catch-all for non-standard processes. Seen as pipeline orchestration role with external Python exe; internal-op usage separately (CLIENT_ID 328). |
| 4 | ENCOUNTER | INBOUND | ⚠️ ProcessData seen (ACADIA EO) | Minimal config; GET_DOCS_DLT=Y; ENCOUNTER_MAP specific |
| 5 | PAYMENT | INBOUND | ⚠️ Prior session (PAY N SECONDS) + ProcessData seen (ACADIA EO) | Needs re-verification |
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
| 23 | SFTP_PULL | INBOUND | ⚠️ Dispatcher verified (Pattern 4 pullers target this type) | Pullers like ACCRETIVE/COACHELLA/MONUMENT filter by `PROCESS_TYPE='SFTP_PULL'` to match their configured SEQs. Anatomy of MAIN execution for these still to trace. |
| 24 | SFTP_PULL | OUTBOUND | ⚠️ Characterized (COACHELLA VALLEY, MSN HEALTHCARE) | File relay/passthrough — minimal sub-workflow invocations. |
| 25 | BDL | INBOUND | ❌ Not yet | Bulk Data Load |
| 26 | STANDARD_BDL | INBOUND | ❌ Not yet | Relationship to BDL unclear |
| 27 | NCOA | INBOUND | ❌ Not yet | National Change of Address |
| 28 | EMAIL_SCRUB | INBOUND | ❌ Not yet | |
| 29 | ITS | OUTBOUND | ❌ Not yet | Unknown acronym |
| 30 | FULL_INVENTORY | INBOUND | ❌ Not yet | |
| 31 | CORE_PROCESS | (empty) | ❌ Not yet | Empty COMM_METHOD — possibly state-mgmt process |

**Progress:** 1 fully traced (NB baseline), 7 partially characterized. 23 remaining.

---

## Sterling Infrastructure (Ignored by Collector)

Same as previous revisions — `FileGatewayReroute`, `Schedule_*`, `TimeoutEvent`, `Alert`, `Recover.bpml`, etc. all have 0% ProcessData and are not MAIN runs. The collector filters these out via `WFD.NAME = 'FA_CLIENTS_MAIN'`.

---

## Things Clarified Since Original Planning Doc

Cumulative list. Highlights only — revision log has per-revision detail.

| Topic | Planning Doc Said | Now Verified |
|-------|-------------------|-------------|
| ProcessData wrapper | `<r>` | `<r>` (verified) |
| Process type field | `PROCESS_TYPE` | `PROCESS_TYPE` (verified) |
| ProcessData lookup pattern | `CREATION_DATE <= Step0.START_TIME` | `ORDER BY CREATION_DATE ASC` (created ~10 ms after Step 0) |
| Multiple DOCUMENT rows per MAIN | Implied single | Multiple exist; ProcessData is the first chronologically; other rows include Translation outputs (target for future detail extraction) |
| PRE_ARCHIVE / POST_ARCHIVE | Y/N flags | Y / empty (not paths) |
| GET_DOCS_TYPE values | `SFTP_PULL` | Also `FSA_PULL` and `API_PULL` (mutates to FSA_PULL) |
| Collector grain | "per workflow run" | One row per MAIN WORKFLOW_ID (simplified given single-Client nature of MAIN) |
| MAIN execution paths | Polymorphic (5 paths) | **CORRECTED** — MAIN is a single linear sequence with ~22 conditional rules |
| FTP_FILES_LIST workflows | File scanners | SP-executor Internal Operations that populate the discovered-files table consumed by Pattern 2 |
| ProcessData field count | ~30 fields | ~70+ fields plus a Settings sub-block |
| Integration table role | Mostly deprecated | **CORRECTED** — Integration is an active coordination layer. Queried live by collector, not mirrored. |
| Entity terminology | "Client" | "Entity" more accurate |
| Three identity scopes | Not addressed | Sterling Entity (CLIENT_ID) ≠ Sterling Process ((CLIENT_ID, SEQ_ID)) ≠ DM Creditor |
| FILE_DELETION process type | Not addressed | Remote SFTP source cleanup on Joker server; logic lives in `FA_CLIENTS_GET_DOCS`. Only for clients submitting un-needed files. |
| Multi-Client ProcessData modes | Parallel vs. Sequential | **CORRECTED** — MAIN only ever operates on Client[1] |
| Pattern 5 coordination | Mysterious | **RESOLVED** — workers have different ProcessData; BATCH_STATUS + PREV_SEQ coordinate |
| Dispatch pattern count | 5 | **CORRECTED** — 4. Prior Pattern 5 was Pattern 4 with specific GET_LIST parameters |
| PREV_SEQ meaning | "Sequential dependency reference, enforcement unclear" | **RESOLVED** — declaratively enforced via BATCH_STATUS polling loop |
| `AUTOMATED` field values | Speculative | **RESOLVED** — 1=GET_LIST-dispatched (5:05am-3:05pm M-F hourly); 2=Scheduler-dispatched |
| `RUN_FLAG` field | Speculative | **RESOLVED** — "currently executing" flag for AUTOMATED=1 configs |
| GET_LIST schedule | "Hourly at :05" inferred | **RESOLVED** — 5:05am-3:05pm M-F every 1 hour (confirmed by File Processing Supervisor) |
| `SPECIAL_PROCESS` meaning | Unclear | **RESOLVED** — catch-all for process configurations that don't fit standard types (confirmed by File Processing Supervisor) |
| `tbl_B2B_CLIENTS_BATCH_STATUS` | Not known | **DISCOVERED** — per-run state machine table. Not authoritative (b2bi is); live-joined for enrichment. |
| `tbl_B2B_CLIENTS_TICKETS` | Not known | **DISCOVERED** — failure ticket log. Live-joined for classification enrichment. |
| `tbl_B2B_CLIENTS_SETTINGS` | Not known | **DISCOVERED** — global settings table injected into ProcessData via GET_SETTINGS SP |
| `FA_CLIENTS_ETL_CALL` workflow | Not known | **DISCOVERED — now deprecated.** Pervasive Cosmos macro executor. Not used in current production config. Excluded from v1 collector scope. |
| Settings contain credentials | Not considered | `PYTHON_KEY` stored plaintext in SETTINGS and flows into ProcessData. Captured raw; redaction at UI layer. |
| Failed MAIN runs have ProcessData | Unknown | ✅ Verified — ProcessData written at Step 0 before failure occurs |
| PGP decryption in NB | Not addressed | Inline within PREP_SOURCE when `PGP_PASSPHRASE` is populated |
| ProcessData contains plaintext credentials | Not addressed | `PGP_PASSPHRASE` and `PYTHON_KEY` both observed. **Captured raw** — already in plaintext in Integration/Sterling config, no meaningful exposure expansion. UI-layer redaction planned for Phase 5. |
| Failure signal nuance | Simple "BASIC_STATUS > 0" | Root cause may have `BASIC_STATUS=0` with error-coded `ADV_STATUS`. Collector captures failure span. |
| Base services fail without Inline markers | Not addressed | SFTPClientBeginSession, AS3FSAdapter, Translation, etc. fail directly. |
| Scheduling collision | Not addressed | Multiple independent Pattern 4 dispatchers often collide at round-hour schedules. |
| FA_CLIENTS_ARCHIVE invoked 3 times per MAIN | Not addressed | PreArchive, PostArchive, PostArchive2 |
| FA_CLIENTS_VITAL invoked up to N+1 times | Not addressed | N in-loop (one per file) + 1 post-loop when PostTranslationVITAL=Y |
| Integration as source of truth | Implicit assumption | **CORRECTED** — b2bi is the source of truth. |
| Integration mirroring strategy | Mirror INT_* tables | **CORRECTED** — no mirroring. Live-join from collector. |
| FILE_DELETION implementation | Assumed distinct MAIN path | **CORRECTED** — lives in GET_DOCS via ZeroSize? rule with `PROCESS_TYPE='FILE_DELETION'` |
| `MARCOS_PATH` setting | Purpose unclear | **RESOLVED** — Pervasive Cosmos macro root. Moot in current operation (ETL_CALL deprecated). |
| `ACADIA SEQ_ID 9` | Mystery | **RESOLVED** — Appears misconfigured; likely incomplete development work (confirmed by File Processing Supervisor) |
| `tbl_B2B_CLIENTS_BATCH_FILES` | Not known | **DISCOVERED** — file-level audit. Scope-limited to zero-size and FILE_DELETION files. |
| `SI_ExecutionDetail` (middle-grain detail layer) | Not addressed | **ADDED** as future Phase 3 Block 3 deliverable supporting file lifecycle bridging |
| `SI_ExecutionTracking` merged_output_file_name column | Not addressed | **ADDED** forward-looking column to support future lifecycle bridge without retrofit |
| TIMINGXML grammar coverage | Unknown whether parser would handle all production variants | **RESOLVED** — Block 1 deploy processed all 604 production schedules with zero parse errors across 73 distinct observed patterns. Grammar coverage is now considered solid for the operational scope. |
| Sterling-native schedules inclusion | Earlier drafts implicitly assumed FAC-only scope | **DECIDED** — registry captures both FAC-owned (`FA_*`) and Sterling-native (`BackupService`, `BPExpirator`, `IndexBusinessProcessService`, etc.) schedules. Naming convention filters at the consumer layer. |
| `is_complete` lookback flag on `SI_ExecutionTracking` | Not originally specified | **ADDED** — enables anti-join in the 3-day lookback query so per-cycle workload scales with "new + in-flight" count, not total lookback volume. Also serves as manual override to silence known-bad workflows. |

---

## Still Unverified — Open Investigation Items

| Item | Status | How to Resolve |
|------|--------|----------------|
| `FA_CLIENTS_MAIN` BPML read | ✅ Done (v48 read end-to-end) | — |
| `FA_CLIENTS_GET_LIST` BPML read | ✅ Done (v19 read end-to-end) | — |
| `FA_CLIENTS_GET_DOCS` BPML read | ✅ Done (v37 read end-to-end) | — |
| `FA_CLIENTS_ETL_CALL` BPML read | ✅ Done (v1 read end-to-end) — deprecated | — |
| `USP_B2B_CLIENTS_GET_LIST` SP read | ✅ Done | — |
| `USP_B2B_CLIENTS_GET_SETTINGS` SP read | ✅ Done | — |
| Representative Pattern 4 wrapper BPMLs read | ✅ Done (ACCRETIVE, COACHELLA, MONUMENT, ACADIA EO) | — |
| Pattern 5 coordination mechanism | ✅ Resolved | — |
| FILE_DELETION lifecycle details | ✅ Resolved | — |
| `FA_CLIENTS_ETL_CALL` role | ✅ Resolved (Pervasive Cosmos macro executor) — deprecated | — |
| Whether ETL_CALL is actually in use | ✅ Resolved — **confirmed deprecated** by File Processing Supervisor; no CLIENTS_PARAM rows with ETL_PATH | — |
| ACADIA SEQ_ID 9 purpose | ✅ Resolved — misconfigured / incomplete dev work (confirmed by File Processing Supervisor) | — |
| SPECIAL_PROCESS semantic meaning | ✅ Resolved — catch-all for non-standard process types (confirmed by File Processing Supervisor) | — |
| Joker SFTP server role | ✅ Resolved — FAC's SFTP endpoint; FILE_DELETION removes files from here; ftpbackup retains them | — |
| **"Skinny" Translation output row pattern** | ❌ **Key Block 3 prerequisite** — not yet identified across process types | Per process type, inspect the DOCUMENT rows produced per MAIN run; identify which one consistently contains file-name header + account-with-creditor rows vs. the denser demographic XMLs |
| `E:\Utilities\FA_FILE_CHECK.java` source | ❌ Not read | Read from the Sterling app server filesystem when access is available. Understand what it validates. |
| Translation map `FA_CLIENTS_BATCH_FILES_X2S` content | ❌ Not analyzed | Extract via SQL from Sterling's map storage. Understand what it produces from the batch-files document. |
| Empty-run behavior on File Process (Pattern 4 puller finds nothing) | ❌ Not verified | Find a Pattern 4 puller that ran with no files discovered and trace |
| Multi-Client prevalence in raw ProcessData | ⚠️ Partial | Sample ProcessData across process types to see how PrimaryDocument is typically shaped |
| Internal Entity IDs beyond 328 | ❌ Not verified | Build up list as encountered |
| SSH_DISCONNECT clustering pattern (hours 04, 10, 16) | ⚠️ Dispatcher-level data captured | Check `GET_DOCS_PROFILE_ID` across affected dispatchers to test "shared Sterling-side SFTP profile" hypothesis |
| BATCH_STATUS column default value (for 0/1 values the Wait? rule polls for) | ❌ Not verified | Query column definition in Integration DB |

---

## Document Relationship to Other Docs

- **`B2B_Module_Planning.md`** — direction and phase plan
- **`B2B_ProcessAnatomy_*.md`** — per-process-type companion documents
- **`B2B_Reference_Queries.md`** — investigation queries and snippets
- **`BPs_Flow.vsdx`** (Rober Makram, circa 2021) — historical architect's diagram

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Purpose | Architectural reference for Sterling B2B, shared by all Process Anatomy docs |
| Created | April 19, 2026 |
| Last Updated | April 22, 2026 |
| Status | Living document — updated iteratively as investigation progresses |
| Sources | Live `b2bi` database (FA-INT-DBP), Integration DB on AVG-PROD-LSNR, BPML definitions extracted from `WFD_XML` / `DATA_TABLE` (FA_CLIENTS_MAIN v48, FA_CLIENTS_GET_LIST v19, FA_CLIENTS_GET_DOCS v37, FA_CLIENTS_ETL_CALL v1, four dispatcher wrappers), Integration stored procedure definitions, `BPs_Flow.vsdx` (Rober Makram), clarifications from File Processing Supervisor (Melissa), prior xFACts investigation sessions |
| Maintainer | xFACts build (Dirk + Claude collaboration) |

### Revision Log

| Date | Revision |
|------|----------|
| April 19, 2026 (initial) | Initial creation. Four-pattern dispatch model, FA_CLIENTS_MAIN as universal grain, ProcessData schema uncertainties, inbound/outbound shapes, open items. |
| April 19, 2026 (rev 2) | Empty Internal Op MAIN run traced. Run Classification dimension added. Pattern 3 reclassified as SP executors. Field inventory expanded to ~70+. |
| April 20, 2026 (rev 3) | Live NB trace (ACADIA WF 7990812). Three Identity Scopes added. Configuration Source documented. Entity naming direction. |
| April 20, 2026 (rev 4) | Major revision after FILE_DELETION trace and ACADIA EO pipeline discovery. |
| April 20, 2026 (rev 5) | Major revision from failure trace session. Added Path D (File Relay), NB PGP variant, Known Failure Modes, failure signal nuance. |
| April 20, 2026 (rev 6) | Major revision from ACADIA EO Pattern 5 trace. BPML read added as top-priority investigation item. |
| April 20, 2026 (rev 7) | **MAJOR REWRITE after direct BPML and stored procedure reads.** Six BPMLs read end-to-end. Source of Truth stance formalized. Dispatch pattern count corrected to 4. MAIN reframed from polymorphic paths to single linear sequence with 22 rules. GET_LIST detail and SP branching logic documented. AUTOMATED/RUN_FLAG/SEQUENTIAL/PREV_SEQ resolved. New Integration tables documented. Grain resolved. |
| April 20, 2026 (rev 8) | Added GET_DOCS and ETL_CALL details. API_PULL variant documented. FILE_DELETION implementation resolved. BATCH_FILES table discovered. Pervasive Cosmos 9 ETL subsystem documented. |
| April 20, 2026 (rev 9) | Execution Tracking Design formalized. Trust Matrix and Disagreement Matrix added. Collector Flow pseudocode. Operational Risks listed. |
| April 22, 2026 (rev 10) | **Reset and realignment revision.** (1) Integration mirroring strategy removed entirely — docs now reflect live-join-only enrichment approach. The "Integration Source Table Mirrors (Proposed)" section deleted; Trust Matrix reframed for live-join usage. (2) File Processing Supervisor (Melissa) clarifications folded in: GET_LIST schedule is 5:05am-3:05pm M-F hourly; FILE_DELETION is Joker SFTP cleanup for clients submitting un-needed files (files retained in ftpbackup); SPECIAL_PROCESS confirmed as catch-all for non-standard process types; ACADIA SEQ_ID 9 confirmed as misconfigured/incomplete dev work; AUTOMATED/RUN_FLAG operational semantics confirmed; Sterling SCHEDULE table authority confirmed. (3) ETL_CALL confirmed deprecated (no CLIENTS_PARAM rows with ETL_PATH); marked as "Deprecated — Reference Only" in its section; excluded from v1 collector scope; ETL_PATH / MARCOS_PATH marked moot. (4) "Joker" SFTP server reference added throughout. (5) ProcessData credential handling resolved — capture raw; redact at UI layer in Phase 5. `SI_ProcessDataCache` table concept eliminated; raw XML stored inline in `SI_ExecutionTracking.process_data_xml`. (6) Execution Tracking Design section expanded with explicit Design Principles block ("collect everything possible up front", single-table design, forward-looking columns). (7) Forward-looking columns documented: `merged_output_file_name`, `merged_output_file_size`, `has_detail_captured`, `last_enriched_dttm`. (8) `SI_ExecutionDetail` (future Phase 3 Block 3) added as the middle-grain detail layer supporting the file lifecycle bridge between File Monitoring and Batch Monitoring. Grain and column design deferred pending "skinny" Translation output investigation across process types. (9) Collector flow updated to describe single-script design handling schedule sync + execution tracking + enrichment + disagreement flag computation in one pipeline. One-time historical Integration backfill documented. 3-day lookback window on every cycle documented. (10) New open investigation item: identifying the "skinny" Translation output row pattern across process types (Block 3 prerequisite). |
| April 22, 2026 (rev 11) | **Block 1 (Schedule Registry) deployed.** (1) New top-level section **"SI_ScheduleRegistry — Schedule Catalog"** added between Execution Tracking Design and Integration Source Query Reference. Documents the 25-column design, pattern classification scheme (DAILY/WEEKLY/MONTHLY/INTERVAL/MIXED/UNKNOWN), single-JOIN fetch pattern, per-row upsert logic, lean-registry design philosophy, and observed collection performance. Parser processed all 604 production schedules with zero errors across 73 distinct patterns. (2) **New `is_complete` / `completed_dttm` / `completed_status` columns** on `SI_ExecutionTracking` documented in the Columns section. New subsection **"Lookback Optimization"** added explaining the anti-join pattern and the terminal-state transition criteria. Manual override pattern documented (operator flip of `is_complete = 1` to silence known-bad workflow alerts). (3) **Collector flow pseudocode updated** to incorporate the `is_complete` anti-join on step 1 and the completion-assessment step at step 4. Enrichment lag operational risk updated to reference the `is_complete = 0` re-enrichment path naturally. New operational risk #7 added for manual override monitoring. (4) **Things Clarified table** extended with three Block 1 entries: TIMINGXML grammar coverage confirmed across 604 schedules, Sterling-native vs FAC-owned schedule inclusion decision, `is_complete` lookback flag rationale. Sections preserved verbatim: Core Architectural Insight, Coordination Layer (and all subsections), Three Identity Scopes, Dispatch Patterns, GET_LIST/MAIN/GET_DOCS/ETL_CALL details, ProcessData Document, Known Failure Modes, Integration Source Trust Matrix, Disagreement Interpretation Matrix, Process Type Investigation Status, Still Unverified items. |

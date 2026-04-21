# B2B Sterling Architecture Overview

## Purpose of This Document

Reference document capturing the architectural model of IBM Sterling B2B Integrator as it is configured and operated at FAC. Built from a combination of live `b2bi` database investigation, direct reads of the workflow BPML definitions stored in `WFD_XML` / `DATA_TABLE`, reads of the Integration stored procedures that assemble Sterling's execution state, the original architect's Visio flow document (`BPs_Flow.vsdx`, authored by Rober Makram circa April 2021), direct inspection of Integration configuration tables, and operational observations.

Intended audience: Dirk and the xFACts build effort. Eventually will serve as the source material for Control Center help pages under the B2B module. This is a reference document for understanding and building — not a finished publication.

Companion documents: `B2B_ProcessAnatomy_*.md` — one per process type, drilling into specifics.

---

## The Core Architectural Insight

**Every unit of work in Sterling corresponds to one execution of the `FA_CLIENTS_MAIN` workflow.**

This is the universal grain. Regardless of how a workflow was dispatched, and regardless of what the workflow does (NB inbound, payment, file cleanup, internal ops, etc.), the actual work is driven by `FA_CLIENTS_MAIN` (WFD_ID 798). Every MAIN execution carries its own `ProcessData` document that self-describes what that run is about — which entity, which process type, which files, which sub-workflows to invoke.

**MAIN is not polymorphic in structure — it's a single linear sequence with ~22 conditional rules.** Earlier revisions of this document described MAIN as having "polymorphic execution paths" based on PROCESS_TYPE. That framing was a useful approximation but structurally incorrect. Reading the BPML definition directly (WFD_ID 798, version 48) shows that MAIN is actually one `<sequence>` with many `<choice>` blocks — each sub-workflow invocation is individually gated by a rule evaluating ProcessData fields. What we previously called "Path A" (NB) vs. "Path C" (FILE_DELETION) vs. "Path D" (SFTP_PULL outbound) are different evaluations of the same rules producing different combinations of sub-workflow invocations.

From the xFACts collector's perspective, **the target is simple: every `FA_CLIENTS_MAIN` run in b2bi is a unit of work worth tracking. What that work IS varies based on configuration, but the collection target is consistent.**

Everything else in `b2bi.dbo.WF_INST_S` is either a **dispatcher** (invokes MAIN via `FA_CLIENTS_GET_LIST` or directly), a **sub-workflow** (invoked by MAIN), or **Sterling infrastructure** (unrelated to MAIN — utility, housekeeping, gateway plumbing).

---

## The Coordination Layer (Integration Database)

Sterling's workflow execution is coordinated by a set of tables and stored procedures in the **Integration database** (on AVG-PROD-LSNR). Sterling BPMLs write to and read from these tables via the `AVG_PROD_LSNR_INTEGRATION` JDBC pool. This layer was partially hypothesized before the BPML reads; direct reading of the workflow definitions has now revealed its full structure.

**Integration's role in the xFACts B2B module is live-join enrichment only.** xFACts does not mirror any Integration table. Specific Integration tables are queried live during collection to enrich b2bi-sourced execution rows with additional context (entity names, ticket types, batch status for disagreement detection). When the UI needs to display an entity name or other Integration-owned context, it joins live to Integration at render time. This avoids the ongoing burden of maintaining local mirrors of schemas we don't own.

### Integration Tables Used by Sterling Workflows

| Table | Purpose | Populated By |
|-------|---------|--------------|
| `etl.tbl_B2B_CLIENTS_MN` | Entity roster (CLIENT_ID, CLIENT_NAME, flags) | Human configuration |
| `etl.tbl_B2B_CLIENTS_FILES` | Process-level classification per (CLIENT_ID, SEQ_ID); includes `RUN_FLAG`, `AUTOMATED`, `FILE_MERGE`, `PROCESS_TYPE`, `COMM_METHOD`, `ACTIVE_FLAG` | Human configuration + `RUN_FLAG` updated by scheduler and `FA_CLIENTS_GET_LIST` at runtime |
| `etl.tbl_B2b_CLIENTS_PARAM` | Field-level configuration per (CLIENT_ID, SEQ_ID, PARAMETER_NAME) — the key-value store that feeds into ProcessData | Human configuration |
| `etl.tbl_B2B_CLIENTS_SETTINGS` | Global settings (DATABASE_SERVER, DM_*_PATH, DEF_*_ARCHIVE, PYTHON_KEY, etc.) | Human configuration |
| `ETL.tbl_B2B_CLIENTS_BATCH_STATUS` | Per-run execution state machine row | `FA_CLIENTS_GET_LIST` and `FA_CLIENTS_MAIN` at runtime |
| `ETL.tbl_B2B_CLIENTS_TICKETS` | Failure ticket log with ticket type classification | Sterling workflow `onFault` handlers |
| `ETL.tbl_B2B_CLIENTS_BATCH_FILES` | File-level audit log — scope-limited: only zero-size and `FILE_DELETION` files are recorded | `FA_CLIENTS_GET_DOCS` during file-collection loop (only the `ZeroSize?` branch writes here) |
| `DBO.tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` | List of files discovered on SFTP endpoints by Pattern 3 polling workflows | `FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` and variants every ~10 minutes |

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

**Note on missing ticket types:** Not every Sterling workflow's onFault handler writes to TICKETS. `FA_CLIENTS_ETL_CALL`, for example, updates BATCH_STATUS to -1 on fault but does NOT insert a TICKETS row. Ticket presence is a valid failure signal when present, but absence is not definitive evidence of success.

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
- Primary source: `b2bi.dbo.WF_INST_S` filtered to `FA_CLIENTS_MAIN` and `FA_CLIENTS_ETL_CALL` runs
- Enrichment (live-joined at collection time): `tbl_B2B_CLIENTS_BATCH_STATUS` on `RUN_ID = WORKFLOW_ID`
- Enrichment (live-joined at collection time): `tbl_B2B_CLIENTS_TICKETS` on `RUN_ID = WORKFLOW_ID`
- Enrichment (live-joined at collection or render time): `tbl_B2B_CLIENTS_MN` on `CLIENT_ID` for entity name resolution
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

See "Execution Tracking Design" below for how this maps to the collector schema.

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

`FA_CLIENTS_GET_LIST` fires on its own schedule (observed hourly at `:05` past the hour), with no `CLIENT_ID` / `SEQ_ID` / `PROCESS_TYPE` / `SEQUENTIAL` parameters set. Its stored procedure (`USP_B2B_CLIENTS_GET_LIST`) follows the "Branch 1" path (the `@CLIENT_ID IS NULL` code path), which:

1. Selects `CLIENTS_FILES` rows where `RUN_FLAG = 1 AND AUTOMATED = 1` (combined with either `FILE_MERGE = 1` or `COMM_METHOD = 'OUTBOUND'`) — these are the "merge-enabled inbound" or "outbound" configs.
2. Separately selects CLIENTS_FILES rows that have matching files discovered in `tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` (the Pattern 3-populated discovered-files table) — these are "per-file inbound" configs.
3. UNION ALLs both sets, PIVOTs CLIENTS_PARAM into ~65 Client-block columns, and returns them.

GET_LIST then loops over the returned rows and invokes `FA_CLIENTS_MAIN` (or `FA_CLIENTS_ETL_CALL`, if ETL_PATH is populated) **asynchronously** for each row. See "`FA_CLIENTS_GET_LIST` Detail" below.

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
| 2 | `FA_CLIENTS_GET_LIST` on schedule | Via GET_LIST → SP Branch 1 | No parameters set |
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
   - Branch on `ETL?` rule: if `ETL_PATH` is populated, invoke `FA_CLIENTS_ETL_CALL`; otherwise invoke `FA_CLIENTS_MAIN`
   - Both invocations use `InvokeBusinessProcessService` (NOT inline) with no `INVOKE_MODE` specified — Sterling's default is async, so **MAIN children are fired in rapid succession** (~100-200ms apart) rather than sequentially with wait
   - UPDATE `tbl_B2B_CLIENTS_FILES SET RUN_FLAG = 0 WHERE CLIENT_ID = ? AND SEQ_ID = ?` — releases the currently-executing flag
   - Increment `ClientCounter`
6. **Tail UPDATE**: `tbl_B2B_CLIENTS_BATCH_STATUS SET BATCH_STATUS = 2, FINISH_DATE = GETDATE()` for GET_LIST's own row.

### onFault Handler

Three operations:
1. UPDATE BATCH_STATUS = -1 for GET_LIST's row
2. INSERT into `tbl_B2B_CLIENTS_TICKETS` with ticket type `'CLIENTS GET LIST'`
3. Invoke `EmailOnError` workflow

### The `AUTOMATED` Field Semantics (Resolved)

- **`AUTOMATED = 1`** — Scheduler-dispatched. The SP's Branch 1 filters for these, combined with `RUN_FLAG = 1`. The scheduler's responsibility is to set `RUN_FLAG = 1` before dispatch; GET_LIST clears it to 0 after each MAIN completes.
- **`AUTOMATED = 2`** — Wrapper-dispatched. The SP's Branch 2 filters for these. No `RUN_FLAG` gating needed — the caller already knows exactly which SEQs to run.

### `RUN_FLAG` Semantics (Resolved)

`RUN_FLAG` is a "currently executing" flag for `AUTOMATED=1` configs only. Something external (scheduler? Integration-side code?) sets it to 1 to indicate "this SEQ is queued / running"; GET_LIST clears it to 0 in the loop after each corresponding MAIN invocation returns. Purpose: prevent concurrent dispatch of the same (CLIENT_ID, SEQ_ID).

### `SEQUENTIAL` Semantics (Resolved)

`SEQUENTIAL = 1` affects how the SP computes `PREV_SEQ` in the result set:

- **Without SEQUENTIAL=1:** `PREV_SEQ` is set only when consecutive rows share the same `CLIENT_ID` AND same `GET_DOCS_LOC`. Automatic serialization of same-folder pulls.
- **With SEQUENTIAL=1:** `PREV_SEQ` is set between consecutive rows sharing `CLIENT_ID` regardless of GET_DOCS_LOC. Forces a sequential pipeline.

The `PREV_SEQ` value then flows into MAIN's ProcessData, and MAIN's `Wait?` rule polls BATCH_STATUS for the dependency.

### Discovery of `FA_CLIENTS_ETL_CALL`

The BPML reveals a parallel dispatch target we had not previously characterized:

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

When a Client block has `ETL_PATH` populated, GET_LIST invokes `FA_CLIENTS_ETL_CALL` instead of `FA_CLIENTS_MAIN`. See `FA_CLIENTS_ETL_CALL` Detail below for its characterization.

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

**1. `SFTP_PULL`** — The most complex branch. Opens an SFTP session, lists the remote directory, loops through discovered files (up to `noofdocs`), and for each file either retrieves it or skips it based on the `ZeroSize?` rule. Each file is then either deleted from the remote source or moved to a remote archive path based on the `DocDelete?` vs `DocArchive?` rules.

**2. `FSA_PULL`** — File System Adapter pickup from a local or network folder path. Simple — just invokes `AS3FSAdapter` with `FS_COLLECT` action, using the Client's `GET_DOCS_LOC` as the collection folder and `FILE_FILTER` as the filter pattern.

**3. `API_PULL`** — **Newly discovered**. Invokes a Python executable via `CommandLineAdapter2` to fetch files (the exe path comes from the Client's `GET_DOCS_API` field), then calls `FS_COLLECT` against the landing folder to pick up what was downloaded. After completion, GET_DOCS mutates `GET_DOCS_TYPE` from `API_PULL` to `FSA_PULL` — so downstream references in MAIN see `FSA_PULL`, not `API_PULL`. API_PULL is effectively a "Python download prelude to FSA_PULL."

Python working directory for API_PULL: `\\kingkong\Data_Processing\Pervasive\Python_EXE_files\!Python_Working`. Timeout: 36,000,000 ms (10 hours).

### The SFTP_PULL Loop

1. Begin SFTP session using `GET_DOCS_PROFILE_ID` if set, else a hardcoded default profile `FA-INT-APPT:node1:17b98dc642f:105916` (which references the dev-env app server node ID — appears to be a legacy default left in production).
2. `CD` to `GET_DOCS_LOC`.
3. `LIST` to enumerate remote files into `//Files/File[]`.
4. Invoke `JavaTaskFS` running `E:\Utilities\FA_FILE_CHECK.java` — **Sterling-server-side Java utility** (source not yet read) that performs file validation or filtering on the listed files.
5. Set `noofdocs = count(//Files/File)`.
6. Loop through files up to `noofdocs` (or just once if `FILE_ID > 0`, for single-file mode):
   - Evaluate `ZeroSize?`:
     - **True path (`ZeroSize` branch):** file is zero-size AND not a `*_PULL` process type (without `GET_EMPTY_DOCS=Y` override), OR `PROCESS_TYPE = 'FILE_DELETION'`. Skip the SFTPClientGet. Go directly to delete-or-archive. Insert a row into `tbl_B2B_CLIENTS_BATCH_FILES` with `COMM_METHOD='SFTP_GET'` for audit.
     - **False path (`PickupDoc` branch):** `SFTPClientGet` to retrieve the file. Then delete-or-archive based on `GET_DOCS_DLT` value.
7. End SFTP session.
8. If `BatchFileInsert?` rule evaluates true (`PROCESS_TYPE != 'SFTP_PULL'`), invoke a final translation using map `FA_CLIENTS_BATCH_FILES_X2S` — apparently generates an insert-set for the batch/files in structured form. Translation map source not yet analyzed.

### How `FILE_DELETION` Works

**Resolution of Integration Team Questions #1 and #9.**

`FILE_DELETION` is NOT a separate code path. It operates by setting `PROCESS_TYPE = 'FILE_DELETION'`, which causes the `ZeroSize?` rule to evaluate true for EVERY file regardless of actual size:

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

## `FA_CLIENTS_ETL_CALL` Detail

`FA_CLIENTS_ETL_CALL` is the alternative dispatch target `FA_CLIENTS_GET_LIST` uses when the current Client block has `ETL_PATH` populated (see "`FA_CLIENTS_GET_LIST` Detail" — Discovery of `FA_CLIENTS_ETL_CALL"). Reading its BPML (version 1 — has never been edited since creation, suggesting either very stable or rarely used) reveals a significantly different processing model than MAIN.

### What It Actually Does

**ETL_CALL is a thin wrapper that invokes Pervasive Cosmos 9's Design Engine (`djengine.exe`) to execute a macro-based ETL transformation.** It is NOT a SQL stored procedure executor. The command line invoked:

```
"C:\Program Files (x86)\Pervasive\Cosmos9\Common\djengine.exe" -mf $MARCOS_PATH $ETL_PATH
```

Where:
- `$MARCOS_PATH` — the `MARCOS_PATH` setting from `tbl_B2B_CLIENTS_SETTINGS` via the Settings/Values node. Likely a typo of "MACROS" that became canonical. Presumed to be a root directory path for Pervasive macro files.
- `$ETL_PATH` — per-Client path to the specific Pervasive transformation file (likely a `.tf.xml` or `.djm` macro). This is a file path, not a SP name.

This reveals a **legacy ETL subsystem** we were previously unaware of. FAC has a Pervasive Cosmos 9 installation (`C:\Program Files (x86)\Pervasive\Cosmos9\`) on the Sterling app server that handles some class of transformations via macro-driven ETL. Pervasive Cosmos was later rebranded as Actian DataConnect.

### Execution Flow

1. Release `INVOKE_ID_LIST` and capture own `thisProcessInstance`.
2. INSERT own row into `tbl_B2B_CLIENTS_BATCH_STATUS` (same pattern as MAIN).
3. If `PREV_SEQ` is set, enter `StatusUpdate` polling loop:
   - Wait 1 second
   - SELECT BATCH_STATUS from predecessor row (via CLIENT_ID + PREV_SEQ + PARENT_ID)
   - Loop while `Ready != 3` (see caveat below)
4. Invoke `djengine.exe` with MARCOS_PATH and ETL_PATH parameters.
5. UPDATE own BATCH_STATUS to `1` on success.
6. If any fault, onFault sets own BATCH_STATUS = -1 and invokes `EmailOnError`.

### Divergences From MAIN — Flagged for Further Investigation

ETL_CALL differs from MAIN in several ways that may be deliberate design choices or may be quirks/bugs. We flag them rather than confidently calling them bugs:

**1. WAIT? condition is more restrictive.** ETL_CALL's `WAIT?` rule waits while `Ready != 3` — meaning it only exits the polling loop when the predecessor's BATCH_STATUS is exactly `3`. MAIN's equivalent exits on values 3, 4, or 5 (any "done" state) and short-circuits on -1 (upstream failed). ETL_CALL's logic would keep polling indefinitely if the predecessor ends at 2, 4, 5, or -1. **If ETL_CALL is only ever chained after processes that end at BATCH_STATUS=3 (non-NB/PAY file processes with files), it works as intended. Otherwise this is a hang risk.**

**2. No `-2` to `-1` conversion in the SELECT.** MAIN's Wait? SELECT has `CASE WHEN BATCH_STATUS = -2 THEN -1 ELSE BATCH_STATUS END`. ETL_CALL's is just `SELECT BATCH_STATUS` — so a predecessor at -2 gets returned literally. -2 != 3, so polling continues. Reinforces the hang risk above.

**3. Success terminal state is `1`, not a value in the 3-5 "done" range.** MAIN ends at values 2/3/4/5 depending on process type and outcome. ETL_CALL's tail UPDATE hardcodes `BATCH_STATUS = 1`, which is in MAIN's "in progress" polling range. This means: **any downstream MAIN or ETL_CALL run that uses this ETL_CALL as its PREV_SEQ predecessor will hang forever in its polling loop**, because `1` satisfies MAIN's `Wait?` condition (in 0-2 range) and doesn't satisfy ETL_CALL's exit condition (Ready == 3). So ETL_CALL cannot be a predecessor in a PREV_SEQ chain. It can only be a leaf.

**4. No `TICKETS` insert in onFault.** ETL_CALL's onFault only sets BATCH_STATUS=-1 and fires EmailOnError. No row goes into `tbl_B2B_CLIENTS_TICKETS`. So failures in ETL_CALL will NOT appear in the tickets table — they'll only be visible via BATCH_STATUS=-1 and via the EmailOnError outputs.

**Collector implication:** when building the monitoring layer, ETL_CALL runs need dedicated handling. They don't follow MAIN's BATCH_STATUS conventions and they don't leave TICKETS records on failure. If ETL_CALL is actually used anywhere in production, the collector must include an ETL-specific live join on BATCH_STATUS for `BATCH_STATUS = -1` as an alternate failure detection path.

**Question for the team:** does anyone actually use ETL_CALL? Version 1 has never been edited. If no configured Clients have `ETL_PATH` populated, ETL_CALL may be effectively dead code.

### Credential Exposure Note

`ETL_PATH` points to a Pervasive macro file on the Sterling app server filesystem. Those macro files themselves may contain embedded credentials for data source connections (database connection strings, FTP credentials, etc.). The xFACts collector does not read those macro files, so this is not a direct exposure surface for the module — but it's worth noting as part of the broader Sterling credential footprint when evaluating operational risk.

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

### PREV_SEQ Semantics (Resolved)

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
- `ETL_PATH` — when populated, GET_LIST routes to `FA_CLIENTS_ETL_CALL` instead of MAIN (path to Pervasive Cosmos macro file)
- `GET_DOCS_TYPE` — one of `SFTP_PULL`, `FSA_PULL`, `API_PULL`; note that GET_DOCS may mutate `API_PULL` to `FSA_PULL` mid-workflow
- `GET_DOCS_API` — Python exe path used by GET_DOCS when `GET_DOCS_TYPE = 'API_PULL'`
- `CUSTOM_FILE_FILTER` — `Y` flag that triggers dynamic XPath evaluation of `FILE_FILTER`
- `GET_EMPTY_DOCS` — `Y` flag that overrides the zero-size skip in GET_DOCS
- `FILE_ID` — when nonzero, forces GET_DOCS into single-file mode (no iterative loop)

### Settings Block (Newly Characterized)

ProcessData also includes a `//Settings/Values/...` node populated by `USP_B2B_CLIENTS_GET_SETTINGS`. Fields include:

- `DATABASE_SERVER` — used by Python exe parameters
- `API_PORT`
- `DM_NB_PATH`, `DM_PAY_PATH`, `DM_BDL_PATH` — standard delivery paths per process type
- `DEF_PRE_ARCHIVE`, `DEF_POST_ARCHIVE` — default archive roots, concatenated when entity's PRE/POST_ARCHIVE is set to `'Y'`
- `PYTHON_KEY` — **plaintext credential**
- `MARCOS_PATH` — root directory for Pervasive Cosmos 9 macro files, passed to `djengine.exe -mf` as the first argument by `FA_CLIENTS_ETL_CALL`. Name appears to be a typo of "MACROS" that became canonical.

### Sensitive Data in ProcessData

**ProcessData may contain credentials in plaintext.** Observed sensitive fields:

- `PGP_PASSPHRASE` — populated for entities sending PGP-encrypted files. Contains the decryption passphrase in plaintext. Example observed: DENVER HEALTH NB.
- `PYTHON_KEY` (in Settings) — plaintext Python API key per the GET_SETTINGS SP inventory.
- Other plaintext secrets may appear in less-commonly-set fields.

**Implications for architecture:**

- Any raw ProcessData persistence (e.g., `SI_ProcessDataCache`) will copy credentials from Sterling's own data into xFACts
- The Settings block is part of ProcessData for all GET_LIST-dispatched runs (Pattern 2 and 4), so credentials from Settings would also be persisted
- This extends the credential footprint — backups, disaster-recovery copies, user access, support screenshots all become potential exposure surfaces

**Design options for `SI_ProcessDataCache` to be decided before build:**

- **Redact known sensitive fields** before persistence (field allowlist — parse, strip sensitive tags, re-serialize)
- **Store only a parsed field subset** (never the raw XML)
- **Encrypt raw XML at rest** (column-level encryption or equivalent)
- **Shorten retention** (days rather than indefinite) for raw ProcessData
- Combination of the above

This is an open design question — see Open Design Questions in `B2B_Module_Planning.md`.

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

Based on the Three Identity Scopes and the now-understood dispatcher/MAIN model:

### Header Level — `SI_ExecutionTracking`

**Grain:** one row per `FA_CLIENTS_MAIN` or `FA_CLIENTS_ETL_CALL` `WORKFLOW_ID`.

Since each MAIN run processes exactly one Client (at `//Result/Client[1]`), the natural grain is simply "one row per MAIN run." Client[1]'s CLIENT_ID and SEQ_ID become columns on that row. There is no multi-Client grain explosion because MAIN doesn't operate on multiple Clients per run.

**Parent-child clustering:** the collector will capture `parent_workflow_id` (the MAIN's immediate parent — typically a Pattern 4 wrapper or GET_LIST) and `root_workflow_id` (the dispatcher root — typically the named wrapper). This allows rolling up "a pipeline invocation" (e.g., all 4 phases of an ACADIA EO run) without denormalization.

### Grain Question — Resolved

The prior open question about Pattern 5 grain (one row per Client block × one row per worker = 16 rows for 1 conceptual pipeline) is **no longer relevant**. That framing was based on the incorrect model of "4 workers sharing one multi-Client ProcessData." The correct model is "GET_LIST loops over 4 SP result rows, invoking MAIN once per row, each with single-Client ProcessData." So 4 MAIN runs = 4 rows in SI_ExecutionTracking. One row per conceptual phase. Clean.

### Columns

The column design reflects the Source of Truth stance: b2bi fields are authoritative, Integration fields are live-joined enrichment, and several derived "disagreement" flags turn the b2bi-vs-Integration gap into actionable alert signals rather than silent data loss.

**Core execution identity (from `b2bi.dbo.WF_INST_S` — AUTHORITATIVE):**
- `workflow_id` — PK
- `workflow_start_time`, `workflow_end_time`, `duration_ms`
- `b2bi_status` (WF_INST_S.STATUS)
- `b2bi_state` (WF_INST_S.STATE)
- `step_count` (count of WORKFLOW_CONTEXT rows)
- `workflow_class` — distinguishes `MAIN` runs from `ETL_CALL` runs (both are tracked, but have different semantic conventions)

**Workflow tree (from `b2bi.dbo.WORKFLOW_LINKAGE`):**
- `parent_workflow_id` — immediate parent (typically a Pattern 4 wrapper or GET_LIST)
- `root_workflow_id` — dispatcher root (useful for pipeline rollup)

**Process identity (from ProcessData / `TRANS_DATA` — AUTHORITATIVE for "what Sterling actually processed"):**
- `client_id`, `seq_id` — from `//Result/Client[1]`
- `client_name` — initially captured from ProcessData; definitive name resolution is via live join to Integration `tbl_B2B_CLIENTS_MN` on `client_id`
- `process_type`, `comm_method`, `business_type`
- `translation_map`, `file_filter`, `get_docs_type`
- `run_class` — derived classification: `FILE_PROCESS` / `INTERNAL_OP` / `UNCLASSIFIED`

**Failure detail (from `b2bi.dbo.WORKFLOW_CONTEXT` — AUTHORITATIVE):**
- `root_cause_step_id`, `root_cause_service_name`, `root_cause_adv_status`
- `failure_step_id`, `failure_service_name`
- `status_message` (summary of failure context)

**Sub-workflow invocation summary (from `b2bi.dbo.WORKFLOW_CONTEXT`):**
- `had_trans`, `had_vital`, `had_accounts_load`, `had_comm_call`, `had_archive` — bit flags indicating which major sub-workflows were invoked
- `trans_invocation_count` — proxy for file count processed
- `archive_invocation_count` — proxy for archive phase activity (pre/post/post2)

**Integration enrichment (LIVE-JOINED at collection time — SUPPLEMENTARY, never gating):**
- `int_batch_status` — BATCH_STATUS.BATCH_STATUS value, or NULL if row missing
- `int_batch_parent_id` — BATCH_STATUS.PARENT_ID (Integration-side dispatcher RUN_ID)
- `int_batch_finish_date` — BATCH_STATUS.FINISH_DATE
- `int_ticket_type` — TICKETS.TICKET_TYPE if a matching ticket exists (e.g., `'MAP ERROR'`, `'CLIENTS GET LIST'`)
- `int_ticket_created_date`

**Disagreement flags (DERIVED — the alert-generating signal):**
- `int_status_missing` — BATCH_STATUS row not present for this RUN_ID
- `int_status_inconsistent` — b2bi reports FAILED but Integration doesn't reflect failure state
- `alert_infrastructure_failure` — b2bi FAILED + Integration blind (either missing or in-progress); this is the "Sterling crashed before reporting" signal

**Metadata:**
- `collected_dttm` — when the collector wrote this row
- `processdata_cache_id` — pointer to `SI_ProcessDataCache` if that table is built and credential handling is resolved

### Integration Source Trust Matrix

Different Integration tables have different trust levels as enrichment sources based on their population mechanism. Under the live-join architecture (no xFACts mirrors of any Integration table), this matrix guides how the collector treats each table during its enrichment pass and how the UI should weight each when joining at render time.

| Integration Table | Enrichment Trust | Live-Join Usage |
|---|---|---|
| `tbl_B2B_CLIENTS_MN` | HIGH | Entity name resolution — joined on `CLIENT_ID` at collection time (stamp `client_name` on SI_ExecutionTracking) and/or at UI render time for display. Content is static-ish and human-maintained. |
| `tbl_B2B_CLIENTS_FILES` | HIGH | Process classification reference — joined for "configured but never runs" analysis and for resolving process type and flags. Live-queried only when needed; not captured per-row on SI_ExecutionTracking. |
| `tbl_B2b_CLIENTS_PARAM` | HIGH | Field-level configuration reference — queried live for drill-down and troubleshooting views. Not captured per-row on SI_ExecutionTracking. |
| `tbl_B2B_CLIENTS_SETTINGS` | MEDIUM | Global settings reference for drill-down views. **Contains credentials (`PYTHON_KEY`) — the UI must never surface raw credential values and any queries against this table must exclude known sensitive fields.** |
| `tbl_B2B_CLIENTS_BATCH_STATUS` | MEDIUM | Joined at collection time on `RUN_ID = WORKFLOW_ID` to populate `int_batch_*` columns on SI_ExecutionTracking. Monitor for disagreement with b2bi as alert signal — not as authoritative execution state. |
| `tbl_B2B_CLIENTS_TICKETS` | MEDIUM as classification signal | Joined at collection time on `RUN_ID = WORKFLOW_ID` to populate `int_ticket_*` columns when a ticket exists. Never treat absence as "no failure" — coverage is incomplete (ETL_CALL doesn't write tickets). |
| `tbl_B2B_CLIENTS_BATCH_FILES` | HIGH **within its scope** (zero-size + FILE_DELETION) | Joined on `RUN_ID` for FILE_DELETION activity metrics specifically. Do not treat as a comprehensive file inventory — normal file pickups are not recorded here. |
| `tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` | Reference only | Joined for "expected vs. processed" comparison analyses downstream. Not tied to execution records directly. |

**Key principles:**
- **No mirroring.** Every join above happens live against Integration at collection or render time. xFACts does not maintain local copies of any Integration table.
- **Trust asymmetry.** Config-derived tables (`CLIENTS_MN`, `CLIENTS_FILES`, `CLIENTS_PARAM`, `SETTINGS`) are HIGH trust because they are human-maintained and static. Runtime-written tables (`BATCH_STATUS`, `TICKETS`, `BATCH_FILES`) are lower trust because Sterling BPMLs may fail to write them under various failure conditions.
- **Disagreement is a feature.** The gap between b2bi's authoritative record and Integration's coordination tables is the direct source of the "infrastructure failure" alert class.

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

The "Sterling crashed before reporting" row is the one that directly addresses the historical concern of "failures that weren't reflected in Integration." Under the prior architecture these weren't surfaced. Under the new architecture they become named alert classes with their own severity.

### Collector Flow — `Collect-B2BExecution.ps1`

The planned collector follows a b2bi-primary-then-enrich pattern. This is the high-level structure (concrete implementation design is for Phase 3):

```
Per collection cycle (frequency TBD — likely 1-5 min):

1. [b2bi primary] Query WF_INST_S for FA_CLIENTS_MAIN and FA_CLIENTS_ETL_CALL
   runs that started since the last high-water mark.
   -> This produces the list of workflow_ids that need a row in SI_ExecutionTracking.
      Every real execution is captured here, regardless of whether Integration
      recorded it.

2. [b2bi enrichment] For each captured workflow_id:
   a. Query WORKFLOW_LINKAGE for parent_workflow_id + root_workflow_id.
   b. Query WORKFLOW_CONTEXT for step count + sub-workflow invocation markers.
   c. If the workflow failed: deep-scan WORKFLOW_CONTEXT for root-cause and
      reported-failure steps (capturing the failure span, not just the final step).
   d. Query TRANS_DATA for ProcessData; decompress gzip; parse //Result/Client[1]
      fields.
   e. [OPTIONAL, depends on credential decision] If SI_ProcessDataCache is built,
      cache the decompressed blob (or redacted subset) against processdata_cache_id.

3. [Integration live-join enrichment — bulk] After accumulating a batch of b2bi results:
   a. Bulk query Integration.BATCH_STATUS for matching RUN_IDs.
   b. Bulk query Integration.TICKETS for matching RUN_IDs.
   c. Bulk query Integration.CLIENTS_MN for display-name resolution on the set of
      client_ids captured in this batch.
   d. In-memory hash-join the result sets onto the b2bi-keyed rows.
   e. Compute int_status_missing, int_status_inconsistent,
      alert_infrastructure_failure flags.

4. [Write] MERGE into SI_ExecutionTracking.

5. [Advance] Update high-water mark.
```

**Why this ordering:** b2bi is polled first and independently so Integration-side failures can never cause us to miss execution data. Integration is queried in bulk at the end rather than per-row for efficiency. The disagreement flags are computed from the joined result rather than requiring a separate reconciliation pass.

### Operational Risks to Monitor During Build

Things to watch for once the collector is running:

1. **Volume.** Roughly 2,300 MAIN runs/day observed. Each requires WF_INST_S row + 5-200 WORKFLOW_CONTEXT rows + 1 ProcessData blob. Batch sizes and collection cadence need tuning.
2. **ProcessData decompression cost.** Compressed blobs are typically 5-20 KB; decompression is cheap per-blob but accumulates. May want to defer decompression until row-write rather than per-query.
3. **Cross-server latency.** b2bi (FA-INT-DBP) and Integration (AVG-PROD-LSNR) are separate servers with no linked server. Each collection cycle makes separate DB calls. Acceptable for batch collection; would need rethinking for real-time UI.
4. **Disagreement rate calibration.** If `alert_infrastructure_failure` fires on 5%+ of runs, it's noise. If it fires on <0.1%, it's high-signal. Rate is unknowable until we're collecting. Threshold tuning will happen after initial observation period.
5. **ETL_CALL inclusion semantics.** ETL_CALL runs share the SI_ExecutionTracking table but have different BATCH_STATUS conventions (terminal value is 1 rather than 3-5; no TICKETS writes on fault). The `workflow_class` column plus ETL_CALL-specific interpretation rules will be needed in the collector. If ETL_CALL turns out to be unused in practice, this simplifies.
6. **High-water mark robustness.** Collection restart, clock skew, or a collector crash mid-cycle shouldn't produce duplicate or missed rows. The MERGE pattern handles duplicates; for missed rows we'll need an overlap/reconciliation pass or a "collected" high-water that's advanced only after successful write.
7. **Integration availability.** Integration lives on the AG listener alongside xFACts, so availability is high — but if Integration is unreachable during a collection cycle, the b2bi-sourced rows must still be written with NULL Integration enrichment fields. The disagreement logic should treat "Integration unreachable this cycle" as a distinct signal from "Integration is reachable and has no row" (potential future refinement — initial build can treat both as `int_status_missing`).

### Detail Level — `SI_ExecutionDetail` (Deferred to Phase 4+)

Grain: one row per `(WORKFLOW_ID, FILE_INDEX, DM_CREDITOR_KEY)`. Source: Translation output XML parsed per MAIN run. Build first at header level; add detail when header is validated.

### ProcessData Cache — `SI_ProcessDataCache`

Grain: one row per MAIN run. Preserves decompressed XML. **See "Sensitive Data in ProcessData" above for credential-handling design options.** Deferring this table's build until the credential-handling decision is made; the core collector can operate without it.

---

## Integration Live-Join Usage

Under the xFACts B2B architecture, Integration tables are never mirrored locally. They are queried live at either collection time or render time depending on the use case.

**At collection time** (`Collect-B2BExecution.ps1`):
- `tbl_B2B_CLIENTS_BATCH_STATUS` — bulk-queried per batch of b2bi-captured workflow_ids; results populate `int_batch_*` columns and feed disagreement flag derivation.
- `tbl_B2B_CLIENTS_TICKETS` — bulk-queried per batch of b2bi-captured workflow_ids; results populate `int_ticket_*` columns when a matching ticket exists.
- `tbl_B2B_CLIENTS_MN` — queried per distinct set of client_ids in the batch to stamp `client_name` on new SI_ExecutionTracking rows for display purposes.

**At render time** (Control Center UI):
- `tbl_B2B_CLIENTS_MN` — joined for current entity name display when SI_ExecutionTracking's stamped `client_name` might be stale (entity renames post-collection).
- `tbl_B2B_CLIENTS_FILES`, `tbl_B2b_CLIENTS_PARAM` — joined for drill-down views showing full Sterling configuration for a specific (CLIENT_ID, SEQ_ID) pair.
- `tbl_B2B_CLIENTS_SETTINGS` — joined for settings drill-down views, with explicit field filtering to exclude known credentials (`PYTHON_KEY`).
- `tbl_B2B_CLIENTS_BATCH_FILES` — joined for FILE_DELETION activity detail views, scoped to the (CLIENT_ID, SEQ_ID, RUN_ID) of interest.
- `tbl_B2B_CLIENTS_BATCH_STATUS` / `tbl_B2B_CLIENTS_TICKETS` — re-queried at render time for drill-downs that need Integration-side detail beyond the collector-captured enrichment columns.

**Never mirrored in xFACts:** any Integration table. The collector and UI are the boundary consumers; Integration's schema and maintenance remain owned by the Developers and Integration team.

---

## Process Type Investigation Status

Distinct PROCESS_TYPE × COMM_METHOD pairs observed in `tbl_B2B_CLIENTS_FILES` (observed-in-practice list, not authoritative lookup — new types may be added as teams configure them):

| # | PROCESS_TYPE | COMM_METHOD | Anatomy Status | Notes |
|--:|---|---|---|---|
| 1 | NEW_BUSINESS | INBOUND | ✅ Live-traced (ACADIA), ⚠️ PGP variant (DENVER HEALTH) | See `B2B_ProcessAnatomy_NewBusiness.md`. PGP variant needs separate documentation. |
| 2 | FILE_DELETION | INBOUND | ⚠️ Partially traced (ACADIA) | SFTP remote cleanup. Actual delete logic lives in `FA_CLIENTS_GET_DOCS`, not MAIN. |
| 3 | SPECIAL_PROCESS | INBOUND | ⚠️ ProcessData seen (ACADIA EO) | Pipeline orchestration role with external Python exe; internal-op usage separately (CLIENT_ID 328) |
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

Same as previous revisions — `FileGatewayReroute`, `Schedule_*`, `TimeoutEvent`, `Alert`, `Recover.bpml`, etc. all have 0% ProcessData and are not MAIN runs. The collector filters these out via `WFD.NAME IN ('FA_CLIENTS_MAIN', 'FA_CLIENTS_ETL_CALL')`.

---

## Things Clarified Since Original Planning Doc

Cumulative list.

| Topic | Planning Doc Said | Now Verified |
|-------|-------------------|-------------|
| ProcessData wrapper | `<r>` | `<r>` (verified) |
| Process type field | `PROCESS_TYPE` | `PROCESS_TYPE` (verified) |
| ProcessData lookup pattern | `CREATION_DATE <= Step0.START_TIME` | `ORDER BY CREATION_DATE ASC` (created ~10 ms after Step 0) |
| Multiple DOCUMENT rows per MAIN | Implied single | Multiple exist; ProcessData is the first chronologically |
| PRE_ARCHIVE / POST_ARCHIVE | Y/N flags | Y / empty (not paths) |
| GET_DOCS_TYPE values | `SFTP_PULL` | Also `FSA_PULL` and `API_PULL` |
| Collector grain | "per workflow run" | One row per MAIN WORKFLOW_ID (simplified given single-Client nature of MAIN) |
| MAIN execution paths | Polymorphic (5 paths) | **CORRECTED** — MAIN is a single linear sequence with ~22 conditional rules. "Paths" were differing evaluations of the same rules, not structurally different branches. |
| FTP_FILES_LIST workflows | File scanners | SP-executor Internal Operations that populate the discovered-files table consumed by Pattern 2 |
| ProcessData field count | ~30 fields | ~70+ fields plus a Settings sub-block |
| Integration table role | Mostly deprecated | **CORRECTED** — Integration is an active coordination layer. CLIENTS_FILES/PARAM/MN/SETTINGS are config; BATCH_STATUS/TICKETS are runtime state. Live-joined by xFACts, never mirrored. |
| Entity terminology | "Client" | "Entity" more accurate |
| Three identity scopes | Not addressed | Sterling Entity (CLIENT_ID) ≠ Sterling Process ((CLIENT_ID, SEQ_ID)) ≠ DM Creditor |
| FILE_DELETION process type | Not addressed | Remote SFTP source cleanup; logic lives in `FA_CLIENTS_GET_DOCS`, not MAIN |
| Multi-Client ProcessData modes | Parallel vs. Sequential | **CORRECTED** — MAIN only ever operates on Client[1]. Multiple Client blocks appear in PrimaryDocument for reference but MAIN doesn't process them. |
| Pattern 5 coordination | Mysterious — workers execute differently despite "identical" ProcessData | **RESOLVED** — workers have different ProcessData (different Client[1]). GET_LIST loop copies one Client per iteration to //Result, then invokes MAIN async. BATCH_STATUS + PREV_SEQ coordinate the sequential dependency. |
| Pattern 5 ~90-second worker offsets | Mysterious external coordination | **RESOLVED** — natural consequence of each phase's actual runtime. Worker 2 polls for worker 1's completion in BATCH_STATUS; polling unblocks when worker 1 writes its tail UPDATE. |
| Path E (Short-Circuit) | "Polling worker pattern" | **CORRECTED** — not a pattern. It's any MAIN run where `Continue?` evaluates false, which only happens when PREV_SEQ dependency has BATCH_STATUS = -1. |
| Dispatch pattern count | 5 | **CORRECTED** — 4. Prior Pattern 5 was Pattern 4 with specific GET_LIST parameters (SEQUENTIAL=1 + multi-SEQ_IDS). |
| PREV_SEQ meaning | "Sequential dependency reference, enforcement unclear" | **RESOLVED** — declaratively enforced via BATCH_STATUS polling loop. Set by `USP_B2B_CLIENTS_GET_LIST` based on GET_DOCS_LOC adjacency or explicit SEQUENTIAL flag. |
| `AUTOMATED` field values | Speculative | **RESOLVED** — 1=scheduler-dispatched (SP Branch 1, needs RUN_FLAG), 2=wrapper-dispatched (SP Branch 2, no RUN_FLAG needed). |
| `RUN_FLAG` field | Speculative | **RESOLVED** — "currently executing" flag for AUTOMATED=1 configs. Set before dispatch; GET_LIST clears to 0 after MAIN completes. |
| `FA_CLIENTS_GET_LIST` iteration source | Unknown | **RESOLVED** — `USP_B2B_CLIENTS_GET_LIST` with two branches (AUTOMATED=1 vs AUTOMATED=2) plus joins to discovered-files table for per-file inbound cases. |
| `tbl_FA_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` table | Not known | **DISCOVERED** — the discovered-files table populated by Pattern 3 and consumed by Pattern 2 for per-file inbound dispatch. |
| `tbl_B2B_CLIENTS_BATCH_STATUS` | Not known | **DISCOVERED** — per-run state machine table. Not authoritative (b2bi is), but valuable live-join enrichment source. |
| `tbl_B2B_CLIENTS_TICKETS` | Not known | **DISCOVERED** — failure ticket log with ticket type classification. Includes 'MAP ERROR' from MAIN's onFault and 'CLIENTS GET LIST' from GET_LIST's onFault. |
| `tbl_B2B_CLIENTS_SETTINGS` | Not known | **DISCOVERED** — global settings table read at start of every GET_LIST run and injected into ProcessData as the Settings/Values node. Contains PYTHON_KEY. |
| `FA_CLIENTS_ETL_CALL` workflow | Not known | **DISCOVERED** — parallel dispatch target in GET_LIST. Invoked when Client block has ETL_PATH populated. |
| Settings contain credentials | Not considered | `PYTHON_KEY` is stored plaintext in tbl_B2B_CLIENTS_SETTINGS and flows into ProcessData via GET_SETTINGS SP. |
| Failed MAIN runs have ProcessData | Unknown | ✅ Verified — ProcessData written at Step 0 before failure occurs |
| Path D (File Relay) | Distinct path | **REFRAMED** — SFTP_PULL OUTBOUND processes trigger a minimal rule set. Not a distinct code path, just a specific rule evaluation pattern. |
| PGP decryption in NB | Not addressed | Inline within PREP_SOURCE when `PGP_PASSPHRASE` is populated (DENVER HEALTH observed). |
| ProcessData contains plaintext credentials | Not addressed | `PGP_PASSPHRASE` and `PYTHON_KEY` both observed. Design question for SI_ProcessDataCache. |
| Failure signal nuance | Simple "BASIC_STATUS > 0" | Root cause may have `BASIC_STATUS=0` with error-coded `ADV_STATUS`. Collector needs to capture the failure span. |
| Base services fail without Inline markers | Not addressed | SFTPClientBeginSession, AS3FSAdapter, Translation, etc. fail directly. Scanning for Inline Begin markers alone will miss these. |
| Scheduling collision | Not addressed | Multiple independent Pattern 4 dispatchers often collide at round-hour schedules. Simultaneity does not imply a single dispatcher. |
| FA_CLIENTS_ARCHIVE invoked 3 times per MAIN | Not addressed | PreArchive, PostArchive, PostArchive2 — all gated by different rules. |
| FA_CLIENTS_VITAL invoked up to N+1 times | Not addressed | N in-loop invocations (one per file) + 1 post-loop invocation when PostTranslationVITAL=Y. |
| Integration as source of truth | Implicit assumption | **CORRECTED** — b2bi is the source of truth. Integration is live-joined enrichment. See Source of Truth Stance section. |
| FILE_DELETION implementation | Assumed to be a distinct MAIN execution path | **CORRECTED** — FILE_DELETION lives entirely in `FA_CLIENTS_GET_DOCS`, not MAIN. Operates by configuration-driven reuse of the standard SFTP_PULL branch. |
| `tbl_B2B_CLIENTS_BATCH_FILES` table | Not known | **DISCOVERED** — file-level audit log populated by GET_DOCS. Scope-limited to zero-size and FILE_DELETION files. |
| `FA_CLIENTS_ETL_CALL` role | Not known | **DISCOVERED** — thin wrapper that invokes Pervasive Cosmos 9 `djengine.exe` to execute macro-based ETL transformations. |
| `MARCOS_PATH` setting | Purpose unclear | **RESOLVED** — root directory for Pervasive Cosmos macro files. Passed to `djengine.exe -mf` by ETL_CALL. |
| ETL_CALL BATCH_STATUS conventions | Assumed same as MAIN | **DIVERGENT** — ETL_CALL's Wait? rule only exits on BATCH_STATUS=3; its tail UPDATE sets BATCH_STATUS=1; its onFault does NOT write to TICKETS. ETL_CALL cannot be a PREV_SEQ predecessor for MAIN. |
| `E:\Utilities\FA_FILE_CHECK.java` utility | Not known | **DISCOVERED** — Java task invoked by GET_DOCS during SFTP_PULL after LIST but before iteration. |
| Pervasive Cosmos 9 dependency | Not known | **DISCOVERED** — FAC has a Pervasive Cosmos 9 installation on the Sterling app server used by ETL_CALL for macro-based ETL. |
| Translation map `FA_CLIENTS_BATCH_FILES_X2S` | Not known | **DISCOVERED** — invoked by GET_DOCS after the file loop completes for non-SFTP_PULL processes. |
| GET_DOCS has its own onFault | Assumed yes | **CORRECTED** — GET_DOCS does NOT have its own onFault. SFTP failures bubble up to MAIN's onFault. |
| Integration mirror tables in xFACts | Original plan: build them | **ABANDONED** — all Integration tables are live-joined. No `INT_*` tables in the xFACts B2B schema. |

---

## Still Unverified — Open Investigation Items

| Item | Status | How to Resolve |
|------|--------|----------------|
| `FA_CLIENTS_MAIN` BPML read | ✅ Done (v48 read end-to-end) | — |
| `FA_CLIENTS_GET_LIST` BPML read | ✅ Done (v19 read end-to-end) | — |
| `FA_CLIENTS_GET_DOCS` BPML read | ✅ Done (v37 read end-to-end) | — |
| `FA_CLIENTS_ETL_CALL` BPML read | ✅ Done (v1 read end-to-end) | — |
| `USP_B2B_CLIENTS_GET_LIST` SP read | ✅ Done | — |
| `USP_B2B_CLIENTS_GET_SETTINGS` SP read | ✅ Done | — |
| Representative Pattern 4 wrapper BPMLs read | ✅ Done (ACCRETIVE, COACHELLA, MONUMENT, ACADIA EO) | — |
| Pattern 5 coordination mechanism | ✅ Resolved | — |
| FILE_DELETION lifecycle details | ✅ Resolved (GET_DOCS ZeroSize? rule) | — |
| `FA_CLIENTS_ETL_CALL` role | ✅ Resolved (Pervasive Cosmos macro executor) | — |
| Whether ETL_CALL is actually in use anywhere | ❌ Unknown | Query CLIENTS_PARAM for rows with PARAMETER_NAME='ETL_PATH' to find any configured Clients using it. If count is 0, ETL_CALL is effectively dead code. |
| `E:\Utilities\FA_FILE_CHECK.java` source | ❌ Not read | Read from the Sterling app server filesystem when access is available. |
| Translation map `FA_CLIENTS_BATCH_FILES_X2S` content | ❌ Not analyzed | Extract via SQL from Sterling's map storage. |
| Pervasive macro files inventory (what's in `MARCOS_PATH`) | ❌ Not inventoried | Browse `MARCOS_PATH` if ETL_CALL is used anywhere. |
| ETL_CALL BATCH_STATUS convention divergences | ⚠️ Documented but not tested | Observe real ETL_CALL execution if any occurs; verify whether polling-hang risk is theoretical or ever manifests |
| Empty-run behavior on File Process (Pattern 4 puller finds nothing) | ❌ Not verified | Find a Pattern 4 puller that ran with no files discovered and trace |
| Multi-Client prevalence in raw ProcessData | ⚠️ Partial | Sample ProcessData across process types to see how PrimaryDocument is typically shaped |
| Internal Entity IDs beyond 328 | ❌ Not verified | Build up list as encountered |
| SSH_DISCONNECT clustering pattern (hours 04, 10, 16) | ⚠️ Dispatcher-level data captured | Check `GET_DOCS_PROFILE_ID` across affected dispatchers to test "shared Sterling-side SFTP profile" hypothesis |
| ProcessData credential handling for SI_ProcessDataCache | ❌ Design question | Decide among redact / parsed-subset-only / encrypt-at-rest / short-retention options |
| BATCH_STATUS column default value (for 0/1 values the Wait? rule polls for) | ❌ Not verified | Query column definition in Integration DB |
| Whether `@ETLAP` SP branch (currently commented out) hints at deprecated ETL paths | ⚠️ Observation only | Ask team if ETLAP tracking was a past pattern |

---

## Open Questions — Apps Team (Revised)

Many questions previously open have been resolved by the BPML and SP reads. Remaining for the team:

1. ~~FILE_DELETION lifecycle~~ — ✅ Resolved (GET_DOCS ZeroSize? rule with PROCESS_TYPE='FILE_DELETION')
2. ~~ACADIA EO pipeline coordination~~ — ✅ Resolved
3. ~~`PREV_SEQ` semantics~~ — ✅ Resolved
4. ~~`AUTOMATED` field values~~ — ✅ Resolved
5. ~~`RUN_FLAG` field~~ — ✅ Resolved
6. ~~`FA_CLIENTS_GET_LIST` dispatcher~~ — ✅ Resolved
7. **`SPECIAL_PROCESS` usage convention** — still unclear; ACADIA EO uses it for pipeline orchestration but other usages may exist
8. **External Python executable inventory** — `FA_FILE_REMOVE_SPECIAL_CHARACTERS.exe` and `FA_MERGE_PLACEMENT_FILES.exe` observed in MAIN; `GET_DOCS_API` per-Client Python exes in GET_DOCS's API_PULL branch. Full inventory of Python exes invoked by Sterling workflows would help scope maintenance.
9. ~~FILE_DELETION scope~~ — ✅ Resolved (universal to SFTP_PULL inbound processes with PROCESS_TYPE='FILE_DELETION')
10. **Internal CLIENT_IDs inventory** — still building
11. ~~Other Integration tables of interest~~ — much now known; BATCH_FILES added to inventory
12. **Legacy naming** (CLA, PV) — CLA confirmed = "Command Line Adapter"; PV meaning still unclear
13. **Sterling SCHEDULE table authority** — implicit; SCHEDULE fires named workflows that either invoke MAIN directly (Pattern 1) or wrap GET_LIST (Patterns 2 & 4)
14. **ACADIA SEQ_ID 9 mystery** — still open
15. **FA_PAYGROUND naming** — still open
16. **Process type definitions** — NCOA, ITS, ACKNOWLEDGMENT, CORE_PROCESS, EMAIL_SCRUB, FULL_INVENTORY, BDL vs STANDARD_BDL, REMIT, FILE_EMAIL, NOTES_EMAIL, NOTE vs NOTES — still open
17. ~~`FA_CLIENTS_ETL_CALL` role~~ — ✅ Resolved (Pervasive Cosmos macro executor)
18. **Known infrastructure-failure cases** (where BPML onFault did not write to Integration) — useful examples would help validate our "disagreement as alert" logic
19. **Is ETL_CALL actually in use?** — query CLIENTS_PARAM for any rows with PARAMETER_NAME='ETL_PATH'. If zero, ETL_CALL is dead code. If some exist, who uses it and for what?
20. **`MARCOS_PATH` location** — what's the actual filesystem path? Inventory of Pervasive macro files at that location would help understand what ETL_CALL does when it's used.
21. **`E:\Utilities\FA_FILE_CHECK.java`** — what does this Java utility validate? Source lives on the Sterling app server.
22. **Translation map `FA_CLIENTS_BATCH_FILES_X2S`** — invoked by GET_DOCS for non-SFTP_PULL processes. Purpose and output?

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
| Last Updated | April 21, 2026 |
| Status | Living document — updated iteratively as investigation progresses |
| Sources | Live `b2bi` database (FA-INT-DBP), Integration DB on AVG-PROD-LSNR, BPML definitions extracted from `WFD_XML` / `DATA_TABLE` (FA_CLIENTS_MAIN v48, FA_CLIENTS_GET_LIST v19, FA_CLIENTS_GET_DOCS v37, FA_CLIENTS_ETL_CALL v1, FA_FROM_ACADIA_HEALTHCARE_IB_EO v13, FA_FROM_ACCRETIVE_IB_BD_PULL v1, FA_FROM_COACHELLA_VALLEY_ANESTHESIA_IB_BD_SFTP_PULL v1, FA_FROM_MONUMENT_HEALTH_IB_EO_PULL v2), Integration stored procedure definitions (`USP_B2B_CLIENTS_GET_LIST`, `USP_B2B_CLIENTS_GET_SETTINGS`), `BPs_Flow.vsdx` (Rober Makram), prior xFACts investigation sessions |
| Maintainer | xFACts build (Dirk + Claude collaboration) |

### Revision Log

| Date | Revision |
|------|----------|
| April 19, 2026 (initial) | Initial creation. Four-pattern dispatch model, FA_CLIENTS_MAIN as universal grain, ProcessData schema uncertainties, inbound/outbound shapes, open items. |
| April 19, 2026 (rev 2) | Empty Internal Op MAIN run traced. Run Classification dimension added. Pattern 3 reclassified as SP executors. Field inventory expanded to ~70+. |
| April 20, 2026 (rev 3) | Live NB trace (ACADIA WF 7990812). Three Identity Scopes added. Configuration Source (CLIENTS_FILES + CLIENTS_PARAM) documented. Entity naming direction. |
| April 20, 2026 (rev 4) | Major revision after FILE_DELETION trace and ACADIA EO pipeline discovery. |
| April 20, 2026 (rev 5) | Major revision from failure trace session. Known Failure Modes documented. |
| April 20, 2026 (rev 6) | Major revision from ACADIA EO Pattern 5 trace. BPML read added as top-priority investigation item. |
| April 20, 2026 (rev 7) | **MAJOR REWRITE after direct BPML and stored procedure reads.** Six BPMLs, two Integration SPs. Coordination Layer, Source of Truth stance, MAIN rule catalog, dispatch patterns corrected to 4, GET_LIST detail added. |
| April 20, 2026 (rev 8) | Added after GET_DOCS and ETL_CALL BPML reads. FILE_DELETION resolved as GET_DOCS behavior, ETL_CALL characterized as Pervasive Cosmos macro executor, BATCH_FILES and MARCOS_PATH discovered. |
| April 20, 2026 (rev 9) | Formalized Execution Tracking Design. Integration Source Trust Matrix, Disagreement Interpretation Matrix, Collector Flow pseudocode, Operational Risks. |
| **April 21, 2026 (rev 10)** | **Integration mirror approach abandoned; architecture reframed for live-join.** Corrections in this revision: (1) **Coordination Layer section** gains a framing paragraph explicitly stating Integration is live-joined, not mirrored. (2) **Source of Truth Stance** tightened — Integration enrichments are explicitly live-joined at collection time. (3) **Execution Tracking Design — Columns** — Integration enrichment columns labeled "LIVE-JOINED at collection time"; `client_name` column description notes both initial stamp and live-join for name resolution. (4) **Integration Source Trust Matrix** reworked — dropped "as execution source" column (nothing but b2bi is an execution source); kept "Enrichment Trust" and rewrote "Live-Join Usage" column entirely to describe live-join patterns without any mirror references. Added explicit "no mirroring" key principle. (5) **"Integration Source Table Mirrors (Proposed)" section deleted entirely**; replaced with new "Integration Live-Join Usage" section that documents when and how each Integration table is queried at collection time vs. render time. (6) **Collector Flow pseudocode** — step 3 renamed from "Integration enrichment — bulk join" to "Integration live-join enrichment — bulk" and adds CLIENTS_MN to the bulk queries; step 3e (disagreement flag computation) is now a separate substep. (7) **Operational Risks** — added item 7 (Integration availability) to cover the cross-server live-join dependency. (8) **ETL_CALL Credential Exposure paragraph** reworded to drop the specific reference to mirroring INT_ProcessConfig; now frames the Pervasive macro credential question in general operational terms. (9) **Collector filter** in "Sterling Infrastructure" updated to include both MAIN and ETL_CALL. (10) **"Things Clarified" table** gains a row documenting the Integration mirror abandonment. |

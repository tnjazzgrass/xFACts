# B2B Module Roadmap

**Status:** Active — investigation phase
**Last updated:** 2026-04-23
**Supersedes:** `WorkingFiles/B2B_ArchitectureOverview.md`, `WorkingFiles/B2B_Module_Planning.md`, `WorkingFiles/B2B_Reference_Queries.md` (archived reference-only, partial picture)

---

## 1. Purpose

This document is the authoritative entry point for all B2B module work. Its purpose is to drive a thorough investigation of the IBM Sterling B2B Integrator (b2bi) workflow universe and the surrounding systems before any further architectural or implementation decisions are made.

**What this document is:**
- An investigation tracker — a catalog of what we need to understand
- A status board — what's been verified, what's still unknown
- A decision queue — pending architectural choices that follow from investigation findings
- The single visible reference point for B2B work going forward

**What this document is not:**
- An architecture specification
- An implementation plan
- A design document for tables, schemas, or collectors

Implementation decisions are explicitly out of scope until the relevant investigation area is resolved. This document's job is to resist the urge to build before we understand.

---

## 2. Operating Principles

These principles exist to prevent repeating mistakes identified in the initial build:

- **No new tables, columns, collectors, or filter-scope changes under the B2B schema** until the relevant investigation area has been resolved and any dependent pending decisions have been made. If an exception is operationally necessary, it must be an explicit decision recorded here, not a drift into premature building.
- **Every "known true" claim must be directly verified** against production data or an authoritative source, with the date of verification recorded. Claims inherited from prior documents are not "known true" until re-verified.
- **Uncertainty gets written down as an open question** rather than assumed away. If we don't know how something works, the roadmap says so.
- **Operational staff are first-class information sources.** Rober in particular holds institutional knowledge that isn't in any document. Questions for Rober are valid investigation steps, not fallbacks.
- **The existing SI_ScheduleRegistry and SI_ExecutionTracking stay as-is during investigation.** They are functional and collecting useful data. No changes to their scope or structure while we map the broader universe.

---

## 3. Current State — What Exists

Factual summary only. No rationale, no forward-looking intent.

### 3.1 Deployed Objects

**B2B.SI_ScheduleRegistry** (Block 1 — complete)
Schedule catalog sourced from b2bi.dbo.SCHEDULE. One row per SCHEDULEID. Parsed TIMINGXML structure. Synced each orchestrator cycle (INSERT new, UPDATE changed, DELETE removed). Currently populated.

**B2B.SI_ExecutionTracking** (Block 2 — complete for MAIN scope)
Per-workflow tracking for FA_CLIENTS_MAIN runs. 105 columns capturing core execution identity, workflow tree linkage, 73 parsed ProcessData fields, raw decompressed ProcessData XML, failure detail from WORKFLOW_CONTEXT, sub-workflow invocation summary, and derived run_class classification. Populated continuously by the collector. ~2,400 rows captured as of 2026-04-23.

**Collect-B2BExecution.ps1** (production)
Single collector running under the orchestrator in FIRE_AND_FORGET mode, dependency_group=10. Two workloads per cycle: Block 1 schedule sync, Block 2 execution collection. Uses is_complete anti-join for bounded per-cycle work. Alerting is stubbed.

**GlobalConfig settings**
`b2b_alerting_enabled` (BIT, currently 0), `b2b_collect_lookback_days` (INT, currently 3).

### 3.2 Scope of Coverage

Current coverage is limited to **FA_CLIENTS_MAIN workflows only**. Sub-workflows invoked by MAIN (TRANS, ARCHIVE, VITAL, ACCOUNTS_LOAD, COMM_CALL) are tracked as presence flags and invocation counts on the parent MAIN row, not as their own execution records. Dispatcher workflows, standalone report workflows, and all other FA_* workflow families are not currently captured.

This scope was established when the module was initially designed. The investigation work in this document will determine whether that scope is sufficient, needs expansion, or needs fundamental restructuring.

---

## 4. Known True

Facts verified against production data or authoritative sources. Each entry dated. Entries only added after direct verification.

**2026-04-23 — b2bi STATUS semantics (verified via production query)**
In `b2bi.dbo.WF_INST_S`, STATUS = 0 means completed successfully; STATUS = 1 means terminated with errors. STATE is a separate numeric state code observed uniformly as 1 on terminal rows and is not consulted for terminal-state classification.

**2026-04-23 — ProcessData storage format (verified via production parsing)**
ProcessData is stored gzip-compressed in `b2bi.dbo.TRANS_DATA.DATA_OBJECT` (VARBINARY(MAX)). The first DOCUMENT row (REFERENCE_TABLE='DOCUMENT', PAGE_INDEX=0, ordered by CREATION_DATE ASC, DATA_ID ASC) contains the ProcessData blob for a workflow. Invoke-Sqlcmd default MaxBinaryLength of 1024 bytes silently truncates the blob.

**2026-04-23 — b2bi write-at-termination model (verified via in-flight observation)**
Rows in `WF_INST_S` and `WF_INST_S_WRK` are not written during workflow execution. Both tables receive rows at or after workflow termination, with observed write-to-read latency of several minutes post-termination. As a consequence, in-flight workflow state cannot be observed via SQL polling of these tables. Data freshness floor for SI_ExecutionTracking is roughly 5-10 minutes (polling interval + b2bi write lag).

**2026-04-23 — WORKFLOW_CONTEXT is written in real time (verified via in-flight observation)**
`b2bi.dbo.WORKFLOW_CONTEXT` rows are written step-by-step during workflow execution. In-flight workflows can be identified by the presence of recent STEP_ID rows for a WORKFLOW_ID that has no corresponding row in WF_INST_S yet. Step volume varies widely (observed 2 to 1,287 steps per workflow in a single hour).

**2026-04-23 — WF_INST_S_WRK is not a live/in-flight alternative (verified via comparison)**
`WF_INST_S_WRK` holds the same data as `WF_INST_S` for recent workflows (observed ~126 rows vs. 2,400+ in S; all recent WRK rows also present in S with identical timestamps). WRK is a short-window buffer that rolls off after some retention period. It does NOT contain in-flight workflows. Querying either table yields the same information.

**2026-04-23 — ROOT_WF_ID accurately identifies the workflow tree root (verified via WORKFLOW_LINKAGE inspection)**
In `b2bi.dbo.WORKFLOW_LINKAGE`, the ROOT_WF_ID column is pre-computed by Sterling and does not require walking up the tree. FA_CLIENTS_MAIN workflows always have a parent — they are never root workflows themselves; root is always a dispatcher (FA_CLIENTS_GET_LIST or one of the FA_FROM_* / FA_TO_* families).

**2026-04-23 — FA_CLIENTS_MAIN is never a root workflow (verified via inventory query)**
All 2,395 observed MAIN executions over a 3-day window had parent workflows. The dispatchers that launch MAINs include FA_CLIENTS_GET_LIST, FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC / RC_ARC, and many client-specific FA_FROM_* / FA_TO_* workflows.

---

## 5. Investigation Areas

The main body of this document. Each area is a question, not an implementation plan. Findings accumulate over time.

Status tags:
- **NOT STARTED** — no investigation work yet
- **IN PROGRESS** — actively being explored
- **PARTIAL FINDINGS** — some findings recorded, incomplete
- **RESOLVED** — investigation complete, findings recorded, decisions can be made

Finding entries format:
`**YYYY-MM-DD — short summary — source:**` followed by detail.

---

### 5.1 The Sterling Workflow Universe

**Status:** PARTIAL FINDINGS

**Context**
Sterling hosts a large and heterogeneous set of workflows. As of 2026-04-23 inventory, there are 200+ distinct FA_*-prefixed workflow names that executed within a 3-day window, falling into rough families: pipeline orchestrators (MAIN), pipeline sub-workflows (TRANS, ARCHIVE, VITAL, EMAIL, ENCOUNTER_LOAD, ACCOUNTS_LOAD, POST_TRANSLATION), dispatchers (FA_CLIENTS_GET_LIST, FA_FROM_*, FA_TO_*), standalone reports and notification pushes, and various client-specific patterns. Current coverage is MAIN only.

**Open questions**
- What is the complete taxonomy of FA_* workflow families? How many distinct patterns exist?
- Which families have operational significance (warrant monitoring) vs. which are noise or implementation detail?
- What is the canonical definition of "B2B execution" for monitoring purposes? (every FA_* workflow? every schedule-fired root? every pipeline-relevant workflow?)
- Which workflows run as root vs. as sub-workflow vs. both? How should that distinction drive scope?
- Are there non-FA_* prefixed workflows in b2bi that are operationally relevant?
- Are there workflows that bypass the standard dispatcher → MAIN → sub-workflow hierarchy?

**Investigation steps**
- Review the full FA_* inventory captured on 2026-04-23 (in session transcript and preserved in WorkingFiles reference material)
- Classify each workflow name manually by family — likely requires Rober's input for the non-obvious cases
- For each family: identify operational significance, typical runtime profile, failure modes, and what "success" means operationally
- Cross-reference against B2B.SI_ScheduleRegistry to understand which workflows are scheduled vs. which are invoked dynamically
- Ask Rober about the history of naming conventions — some patterns (FA_FROM_*, FA_TO_*, IB/OB/BD/EO suffixes) clearly encode direction and business type; confirm semantics

**Findings**

**2026-04-23 — inventory captured, summary observations — source: production query**
Over a 3-day window, 200+ distinct FA_* workflow names were observed. FA_CLIENTS_MAIN, FA_CLIENTS_ARCHIVE, FA_CLIENTS_VITAL, FA_CLIENTS_EMAIL, and FA_CLIENTS_ENCOUNTER_LOAD all run exclusively as sub-workflows (times_as_root = 0). The dispatcher FA_CLIENTS_GET_LIST runs as root 35 times in the window and launches 462 MAIN executions. Thousands of sub-workflow executions (ARCHIVE 4,173; VITAL 4,049; EMAIL 243; ENCOUNTER_LOAD 31) are not currently captured in SI_ExecutionTracking except via presence flags on their parent MAIN row. All 9 of the 13 workflow failures observed in the 3-day window occurred in sub-workflows we do not track individually (VITAL: 7, ENCOUNTER_LOAD: 2).

---

### 5.2 VITAL

**Status:** NOT STARTED

**Context**
VITAL is a separate tracking database, not a Sterling component. It lives on `ATLAS-DB` and contains 2 tables. Its original purpose was workflow execution tracking, predating xFACts. History extends back to the Pervasive processing era — years of execution metadata that xFACts doesn't have and can't reconstruct from b2bi (which has ~48hr retention).

VITAL is no longer a reliable source of truth because newer ETLs omit the VITAL-write step — coverage has degraded over time. But for historical periods it may be authoritative for workflow execution data that is otherwise lost.

The stated long-term goal is for xFACts to capture much of what goes into VITAL today, making xFACts the authoritative source going forward. VITAL may be deprecated eventually. Understanding VITAL is valuable for both its potential historical-backfill role and as input to the xFACts design.

**Open questions**
- What are the two tables and their schemas?
- What is VITAL's retention? How far back does it go?
- Which ETLs do and don't write to VITAL? What's the coverage gap?
- What data does VITAL capture that b2bi doesn't? What does it capture that we wouldn't otherwise have?
- How does VITAL content overlap with what SI_ExecutionTracking captures today? Where is there overlap, where is there orthogonality?
- What is the cutoff point where VITAL history becomes valuable for backfill? (i.e., how far back is b2bi data unavailable?)
- Is VITAL queryable from the xFACts AG (no linked server to b2bi — same question for ATLAS-DB)?

**Investigation steps**
- Get schema of the two VITAL tables (column names, data types, row counts, date ranges)
- Sample data inspection — what does a typical row look like?
- Identify which workflow families / ETL paths currently write to VITAL vs. which don't
- Establish how far back VITAL data goes (useful vs. aged-out)
- Determine connectivity from FA-SQLDBB (xFACts orchestration host) to ATLAS-DB
- Compare VITAL record structure against SI_ExecutionTracking columns — identify the conceptual mapping

**Findings**
(none yet)

---

### 5.3 Integration Tables

**Status:** NOT STARTED

**Context**
The `Integration` database on AVG-PROD-LSNR contains `etl.tbl_B2B_*` tables with structured batch processing history. Prior investigation established that `WORKFLOW_ID` in b2bi equals `RUN_ID` in Integration (100% match over observed data). These tables have been collecting for 5+ years, substantially longer than b2bi's ~48-hour retention, and represent a second potential historical source.

Initial project thinking was to mirror Integration data into xFACts. That approach was later rejected in favor of keeping SI_ExecutionTracking pure-b2bi. Integration data was expected to be joined at read time when needed. Whether that decision holds up depends on what's actually in these tables and how we want to use them.

**Open questions**
- What are the complete schemas of the etl.tbl_B2B_* tables? How many tables and what does each represent?
- What's the retention in practice? Is the 5+ years claim accurate for all tables or just some?
- What does an Integration row represent semantically? What's the grain?
- How does Integration data relate to b2bi workflow data? Is it "what the workflow produced" vs. "what the workflow did"?
- What data is in Integration that b2bi doesn't have (and vice versa)?
- For historical backfill periods where b2bi no longer has data, is Integration sufficient? Is VITAL sufficient? Both? Neither?
- Does the RUN_ID → WORKFLOW_ID equivalence hold across all Integration tables or only some?

**Investigation steps**
- Enumerate all etl.tbl_B2B_* tables and their row counts
- Inspect schemas — column names, types, sample rows
- Correlate a set of recent workflows across b2bi and Integration to understand the mapping
- Establish retention in practice per table
- Map each Integration table to its conceptual purpose (is it per-batch? per-file? per-client? per-workflow?)

**Findings**
(none yet — prior understanding referenced in WorkingFiles documents; not considered current-verified)

---

### 5.4 Sub-workflow Families in Depth

**Status:** NOT STARTED

**Context**
SI_ExecutionTracking tracks presence of sub-workflows invoked from MAIN via had_* flags and *_invocation_count columns. The sub-workflows themselves — what they do, what they write, how they succeed or fail — are opaque. This is a significant gap: 9 of 13 observed workflow failures in a 3-day window occurred in sub-workflows we do not track.

Each family may have its own story worth understanding before deciding whether/how to track it.

**Open questions per family**

**FA_CLIENTS_TRANS (translation)** — no had_trans_failure tracking; no per-invocation detail; proxy for file count via trans_invocation_count
- What does a TRANS run actually do functionally?
- What does it read, write, produce?
- What constitutes success vs. failure?
- Is per-TRANS detail needed operationally, or is "it failed somewhere in TRANS" sufficient?

**FA_CLIENTS_ARCHIVE (archiving)** — currently tracked via had_archive / archive_invocation_count
- What does ARCHIVE do? Where does it archive to?
- Is per-archive detail needed, or is presence/count sufficient?
- Does ARCHIVE have its own failure modes we're missing?

**FA_CLIENTS_VITAL (VITAL writes)** — 4,049 executions in 3 days, 7 failures; we don't see the failures
- Is this the workflow that writes to the VITAL database from section 5.2? (strong hypothesis, needs confirmation)
- What's the relationship between the VITAL sub-workflow and the VITAL database?
- The 7 observed failures — what do they represent?

**FA_CLIENTS_EMAIL (email sending)** — 243 executions, not tracked at all
- When does this fire? What emails does it send?
- Do failures here matter operationally?

**FA_CLIENTS_ENCOUNTER_LOAD (healthcare encounter loading)** — 31 executions, 2 failures, not tracked
- What pipeline produces encounters, and what does ENCOUNTER_LOAD do with them?
- The 2 failures — what happened? Are these the kind of failures we'd want to alert on?

**FA_CLIENTS_ACCOUNTS_LOAD (new business accounts loading)** — tracked via had_accounts_load
- Already understood as the "new business pipeline" signal. What does it actually do? What does it write?
- Is per-invocation detail needed?

**FA_CLIENTS_POST_TRANSLATION** — referenced in ProcessData but not tracked as a had_* flag
- Is this a distinct sub-workflow or a phase within MAIN?
- Does it have its own execution pattern worth tracking?

**Investigation steps**
- For each family, inspect ProcessData and WORKFLOW_CONTEXT samples to understand what the workflow actually does
- Identify the failures (7 VITAL, 2 ENCOUNTER_LOAD) and look at their WORKFLOW_CONTEXT to understand root cause
- Ask Rober / operations staff: for each family, what's the operational consequence of a failure? What alerts would be valuable?
- Determine whether per-invocation tracking is needed for each family or whether parent-level flags suffice

**Findings**
(none yet)

---

### 5.5 Dispatcher Workflows

**Status:** NOT STARTED

**Context**
Dispatchers are the schedule-fired root workflows that launch MAINs and other pipelines. The inventory on 2026-04-23 identified 200+ distinct dispatcher-pattern workflows (FA_CLIENTS_GET_LIST, FA_FROM_*, FA_TO_*, various client-specific patterns). They run from schedule (visible in SI_ScheduleRegistry) and spawn child workflows.

Current xFACts coverage does not include dispatchers. There is no visibility into "did the scheduled work fire?" — only into what MAIN workflows produced downstream.

**Open questions**
- Is schedule adherence monitoring needed? (i.e., alerting when a scheduled dispatcher fails to fire at its expected time)
- If so, how should it be tracked? Row per dispatcher execution? Row per expected fire that actually fired? Derived signal from SI_ScheduleRegistry + observed child spawns?
- Do dispatchers fail in ways that aren't reflected in downstream MAINs? (observed data shows 0 dispatcher failures in 3 days, but sample size is small)
- Are all dispatchers created equal, or are some more operationally significant than others?
- Do standalone dispatchers exist (i.e., ones that complete their work directly without spawning MAINs)?

**Investigation steps**
- Review the FA_FROM_* / FA_TO_* naming convention with Rober — what do the suffixes mean (IB, OB, BD, EO, PULL, PUSH, D2S, S2D, etc.)?
- For each dispatcher family: sample a few executions and understand what they actually do
- Identify dispatchers that produce MAINs vs. those that do their work standalone
- Determine operational intent: are failures here critical, minor, or silent?

**Findings**
(none yet)

---

### 5.6 Process Type Semantics

**Status:** NOT STARTED

**Context**
SI_ExecutionTracking captures `process_type` from ProcessData with observed values including NEW_BUSINESS, PAYMENT, NOTES, SPECIAL_PROCESS, RECON, SFTP_PUSH, SFTP_PUSH_ED25519, EMAIL_SCRUB, and others. These are names, not documented semantics — we haven't traced what each actually does functionally.

**Open questions**
- What is the complete set of process_type values seen in production?
- For each: what does the pipeline actually do end-to-end?
- Are process_types orthogonal to workflow names, or do certain combinations always co-occur?
- Are there process_types that warrant their own monitoring patterns (e.g., PAYMENT might have different failure-tolerance expectations than NOTES)?

**Investigation steps**
- Query SI_ExecutionTracking for distinct process_type values and their frequencies
- For each process_type, trace a sample workflow through its ProcessData / WORKFLOW_CONTEXT
- Ask Rober about what each process_type means in business terms

**Findings**
(none yet)

---

### 5.7 WORKFLOW_CONTEXT as Real-Time Source

**Status:** PARTIAL FINDINGS

**Context**
Confirmed on 2026-04-23 that WORKFLOW_CONTEXT is written in real time during workflow execution, not at termination. This opens the possibility of real-time in-flight visibility — something impossible via WF_INST_S which has ~5-10 minute write lag. Not urgent for correctness (the current collector captures terminal state correctly), but valuable if real-time monitoring becomes a requirement.

**Open questions**
- What would it take to build a WORKFLOW_CONTEXT-based in-flight detector?
- How noisy is the table? (We observed one workflow with 1,287 steps in a short window — polling this table frequently could be expensive.)
- What retention does WORKFLOW_CONTEXT have? (Affects whether in-flight detection needs to run every N seconds or can tolerate longer gaps.)
- How do we reconcile an in-flight detection signal with later WF_INST_S appearance? (Same WORKFLOW_ID appears in CONTEXT first, then eventually in WF_INST_S — need to design the state machine.)
- Is there operational value in "workflow started but hasn't written a step in N minutes" as a hang detector?

**Investigation steps**
- Understand WORKFLOW_CONTEXT structure and volume characteristics
- Design a minimal in-flight detection query and measure its cost
- Identify edge cases (workflow that ends between CONTEXT last step and WF_INST_S appearance)

**Findings**

**2026-04-23 — WORKFLOW_CONTEXT is real-time — source: production observation**
Query run at ~08:24 returned 20 active workflows with recent step activity (most recent step within 16-250 seconds), where none of those WORKFLOW_IDs were yet present in WF_INST_S. Step counts varied from 2 to 1,287 per workflow. Confirmed real-time write behavior; confirmed table is suitable as an in-flight signal source.

---

### 5.8 b2bi Write Model and Retention

**Status:** PARTIAL FINDINGS

**Context**
b2bi's write model for workflow-related tables is non-obvious and has operational implications for any monitoring built on top. Initial confusion in the Block 2 investigation (was there in-flight state? Where did it live?) was ultimately resolved by observing actual write behavior.

**Open questions**
- What is the exact retention policy for each b2bi table we care about? (TRANS_DATA appears to have ~48hr; WF_INST_S has more; WORKFLOW_CONTEXT unknown)
- Is retention configurable? Can it be extended if operationally justified?
- Are there purge jobs we can observe to understand retention empirically?
- How does retention interact with our lookback window? (If TRANS_DATA purges at 48hr and we look back 3 days, we can see the WF_INST_S row for a workflow but not its ProcessData — what does the collector do in that case?)
- Are other Sterling tables relevant beyond the ones already investigated? (DOCUMENT, SERVICE_INSTANCE, various admin tables)

**Investigation steps**
- Measure actual retention per table by tracking min/max START_TIME over time
- Investigate Sterling purge configuration (documentation, admin console, DBA consultation)
- Enumerate other Sterling tables that might be relevant; filter to those with operational content

**Findings**

**2026-04-23 — write-at-termination for WF_INST_S and WF_INST_S_WRK — source: production observation**
Rows are not written while workflows run. They materialize at workflow termination, with additional lag of several minutes between termination and SQL visibility. The ~5-10 minute data freshness floor for SI_ExecutionTracking derives from this plus the 5-minute collector polling interval.

**2026-04-23 — WRK is not a live-state alternative — source: production comparison**
WF_INST_S_WRK contains the same data as WF_INST_S for recent workflows (observed ~126 rows in WRK vs. 2,400+ in S; all WRK rows also present in S with identical timestamps). WRK appears to be a short-window buffer that rolls off after retention, not a separate live/in-flight tracking mechanism.

---

### 5.9 Historical Coverage Strategy

**Status:** NOT STARTED

**Context**
A stated long-term goal for xFACts is to capture execution history comprehensively enough that older tracking systems (VITAL specifically, possibly others) can eventually be deprecated. b2bi's ~48hr retention means forward coverage from xFACts deployment onward is achievable — but coverage of history *before* xFACts deployment requires pulling from other sources.

This is a cross-cutting area that depends on findings from VITAL (5.2) and Integration tables (5.3).

**Open questions**
- What is the historical coverage goal? (all FA_CLIENTS_MAIN history? broader? how far back?)
- For pre-xFACts history: VITAL + Integration, or one or the other?
- What's the cutoff — how far back is it worth reconstructing history?
- Is backfilled history stored in the same SI_ExecutionTracking table, or in a separate historical table with different structure?
- Do we backfill once (one-time migration) or ongoing (for workflows that are still trickling through?)
- What accuracy can we guarantee for backfilled data? (Partial data is fine if labeled as such.)

**Investigation steps**
- Cannot start until 5.2 (VITAL) and 5.3 (Integration) have sufficient findings
- Once those are further along: design the historical backfill approach, then evaluate whether current SI_ExecutionTracking structure accommodates backfilled data or needs modification

**Findings**
(none yet — awaiting prerequisites)

---

## 6. Out of Scope

Things explicitly NOT being investigated, to prevent scope creep:

- **Sterling clustering / multi-node architecture** — single-node deployment at FAC
- **Sterling version upgrades or migration planning** — operational concern, not monitoring
- **b2bi admin console internals** — not a SQL data source
- **Direct integration with IBM Sterling REST APIs** — out of scope unless SQL-based monitoring proves fundamentally insufficient
- **Alerting evaluation and delivery** (Phase 4) — deferred until scope and collection approach are settled
- **Control Center UI for B2B** (Phase 5) — deferred until data model is settled
- **Anything related to pre-Sterling / Pervasive-era systems beyond what VITAL captures**

---

## 7. Pending Decisions

Decisions that cannot be made until investigation progresses. Each tagged with its dependency areas.

**SI_ExecutionTracking scope — stay as-is, broaden, or restructure?**
*Depends on:* 5.1 (workflow universe), 5.4 (sub-workflow families), 5.5 (dispatchers)
Options: keep MAIN-only and supplement with sibling tables; broaden to multi-family with a workflow_family discriminator; rename and redesign entirely as part of a unified execution model. No path chosen.

**VITAL integration approach — ingest, mirror, query-live, or ignore?**
*Depends on:* 5.2 (VITAL), 5.9 (historical strategy)
Options: pull VITAL data into a new xFACts table; leave VITAL in place and query it live for historical context; extract once for backfill and discard afterward; ignore entirely if overlap with other sources makes it redundant. No path chosen.

**Integration tables integration approach — same question as VITAL**
*Depends on:* 5.3 (Integration tables), 5.9 (historical strategy)

**Dispatcher tracking — own table, discriminator column, or derived signal?**
*Depends on:* 5.5 (dispatchers)
Options: SI_DispatcherTracking as a sibling; broaden SI_ExecutionTracking to include dispatchers with a workflow_family discriminator; derive schedule adherence from SI_ScheduleRegistry + observed MAIN spawns without separate dispatcher tracking. No path chosen.

**Sub-workflow execution detail — track or not?**
*Depends on:* 5.4 (sub-workflow families), possibly 5.2 (VITAL)
For each sub-workflow family: does it warrant its own execution rows, or is parent-level flag sufficient? Answers may differ per family.

**Real-time in-flight visibility — build or defer?**
*Depends on:* 5.7 (WORKFLOW_CONTEXT), and on operational demand
Options: build a WORKFLOW_CONTEXT-based in-flight detector; accept the 5-10 min lag; defer indefinitely until a concrete operational need arises. No path chosen.

**Block 3 (execution detail) — scope and approach**
*Depends on:* 5.4 (sub-workflow families), 5.6 (process types)
SI_ExecutionTracking reserves `merged_output_file_name`, `merged_output_file_size`, and `has_detail_captured` columns for a future detail-capture layer. Whether that layer is per-file, per-creditor, per-client, or something else depends on what we learn about the actual pipelines.

---

## 8. Reference Material

The following documents were produced during the initial Blocks 1 and 2 build. They contain genuinely useful content about Sterling table grammar, ProcessData parsing, schedule TIMINGXML structure, SQL query patterns, and early architectural reasoning. They are archived in `WorkingFiles/` rather than `Planning/` because their conclusions reflect an incomplete picture of the b2bi universe. Review them with fresh eyes and verify against current state before relying on any specific claim.

- `WorkingFiles/B2B_ArchitectureOverview.md` — Sterling table descriptions, ProcessData grammar, SI_ExecutionTracking design rationale (MAIN-scoped)
- `WorkingFiles/B2B_Module_Planning.md` — Block 1 and Block 2 planning and execution notes
- `WorkingFiles/B2B_Reference_Queries.md` — validated queries against b2bi and Integration (temporary working reference from module development)

Use these as starting points for investigation, not as specifications. When findings from this roadmap contradict them, this roadmap wins.

Current production artifacts (not archived — these are live):
- `B2B.SI_ScheduleRegistry` table and its Object_Metadata
- `B2B.SI_ExecutionTracking` table and its Object_Metadata
- `Collect-B2BExecution.ps1` production script
- B2B-related GlobalConfig entries

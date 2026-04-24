# B2B Module Roadmap

**Status:** Active — investigation phase (Steps 1-5 complete, Step 6 next)
**Version:** 2.1
**Last updated:** 2026-04-24
**Supersedes:** v2.0 (updated in-session); v1 (archived at `WorkingFiles/B2B_Investigation/Legacy/B2B_Roadmap_V1.md`)

---

## ⚡ Next Session — Start Here

**This section is the first thing to read when opening this document in a new session.**

### What's next

**Step 6 — FA_CLIENTS_MAIN Anatomy**

FA_CLIENTS_MAIN is the orchestrator for the majority of Sterling's actual business work. Two previous investigation passes got MAIN wrong or incomplete. This is the third pass and needs a clean, full-session focus — do not split across sessions.

### Approach

**Hybrid (aggregate → trace → refine):**

1. **Aggregate pass first:** Query `WORKFLOW_CONTEXT` across many recent MAIN runs to see what phases/steps appear, how often, in what order. Reveals structure without anchoring on one example.
2. **Targeted traces:** Pick one representative run per major process type flavor identified in the aggregate, do deep ProcessData extraction similar to the legacy `B2B_ProcessAnatomy_NewBusiness.md`.
3. **Refinement pass:** Post-trace, re-query the aggregate to check for patterns the trace surfaced.

### Open question to resolve at session start

**Which process types should be traced as representative examples?** The legacy `ProcessAnatomy_NewBusiness.md` covered NB (ACADIA). Candidates for additional traces: payment (highest volume), notes, returns, transfers, new business variant (non-ACADIA). Pick based on operational importance.

### Required context before starting

1. **This Roadmap** (you're reading it) — current state, Known True list, pending decisions
2. **`WorkingFiles/B2B_Investigation/Step_03_Workflow_Definition_Catalog+Active_Inventory/Step_03_Findings.md`** — MAIN's activity profile (2,354 runs/48h, 16% of Sterling volume)
3. **`WorkingFiles/B2B_Investigation/Step_02_Retention_and_Archive/Step_02_Findings.md`** — what data survives where (so trace queries know retention windows)
4. **`WorkingFiles/B2B_Investigation/Step_05_CORRELATION_SET/Step_05_Findings.md`** — the ~14% of MAIN runs that produce correlation data; useful enrichment layer for traces
5. **`WorkingFiles/B2B_Investigation/Legacy/B2B_ProcessAnatomy_NewBusiness.md`** — reference for NB process type; previously-verified trace structure

### What is NOT in scope for Step 6

- Standalone behavior of `FA_CLIENTS_ARCHIVE`, `FA_CLIENTS_VITAL`, `FA_CLIENTS_EMAIL` — they'll be referenced as "invoked by MAIN" but dedicated steps come later
- Dispatcher characterization (§5.8)
- Process type catalog against `CLIENTS_FILES` (§5.9)
- Integration DB re-verification (§5.10)
- Any collector design work

### Session start prompt template

When starting the next session, suggested opening message:

> Starting Step 6 - FA_CLIENTS_MAIN Anatomy. Cache-busted manifest URL: https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=<value>
>
> Process types I want traced: <list>

---

## 1. Purpose

Authoritative entry point for all B2B module work. Tracks investigation state, records what we've verified, and drives architectural decisions toward a comprehensive Sterling monitoring collector.

**What this document is:**
- An investigation tracker and status board
- A decision queue for architectural choices
- The orientation document for new sessions
- The single slim reference — detail lives in per-step findings docs

**What this document is NOT:**
- An architecture specification
- An implementation plan
- A detailed technical reference (that's in the step findings docs)

Implementation decisions remain out of scope until the investigation phase completes. This document resists the urge to build before we understand.

---

## 2. Operating Principles

- **No new tables, columns, or collectors under the B2B schema** until investigation is complete. Exceptions must be explicit decisions recorded here, not drift into premature building.
- **Every "Known True" claim must be directly verified** against production data, with date of verification recorded. Inherited claims don't count until re-verified.
- **Uncertainty gets written down as an open question** rather than assumed away.
- **Operational staff are first-class information sources** but are not the primary path — we're building documentation that never existed. Dirk is the customer of Sterling at FAC, not its architect. Rober has limited institutional knowledge and may or may not be able to answer specific questions.
- **Existing production artifacts** (`SI_ScheduleRegistry`, `SI_ExecutionTracking`, `Collect-B2BExecution.ps1`) stay as-is during investigation. They function for their narrow scope and are collecting data. All of them will be re-evaluated when investigation completes — they may fold into the eventual comprehensive collector, or be replaced.
- **The investigation documents (this Roadmap + step findings) are working documents, not permanent documentation.** Their purpose is to inform the module build. Once the module is built, these documents will eventually be archived and real HTML documentation will be authored from them.
- **High-stakes investigation steps must not be split across sessions.** FA_CLIENTS_MAIN is the highest-stakes step in this whole effort (two prior attempts failed). Investigations of that scope must fit in a single session with full context.

---

## 3. Current State

### 3.1 Production artifacts (in use, narrow scope)

| Artifact | Scope | Status |
|---|---|---|
| `B2B.SI_ScheduleRegistry` | Schedule catalog sync from `b2bi.dbo.SCHEDULE` | Functional, complete for its scope |
| `B2B.SI_ExecutionTracking` | Per-workflow tracking for FA_CLIENTS_MAIN only | Functional, but captures ~16% of total Sterling activity |
| `Collect-B2BExecution.ps1` | Single collector, FIRE_AND_FORGET mode, dependency_group 10 | Functional, narrow scope |
| GlobalConfig settings | `b2b_alerting_enabled` (BIT, 0), `b2b_collect_lookback_days` (INT, 3) | Alerting stubbed |

### 3.2 Scope of coverage

Current collector captures FA_CLIENTS_MAIN only. Investigation has shown MAIN is roughly 16% of total Sterling workflow activity — the other 84% is invisible. Sub-workflows (ARCHIVE, VITAL, EMAIL), dispatchers (GET_LIST, FA_FROM_*, FA_TO_*), Sterling infrastructure (FileGateway, Schedule_*), and most client-specific workflows are not captured.

The investigation underway is determining what a comprehensive collector should look like, not how to extend the current MAIN-only design.

---

## 4. Known True

Facts verified against production data. Each entry dated with source. Entries only added after direct verification.

### 4.1 Sterling environment

**2026-04-24 — Sterling B2B Integrator version 6.1.0.0** — source: `SI_VERSION` table
Installed 2021-03-23. Matches IBM docs at `ibm.com/docs/en/b2b-integrator/6.1.0`. Version-accurate reference.

**2026-04-24 — b2bi database shape** — source: Step 1 catalog
773 tables total, 186 populated, 587 empty. ~11.5M rows, ~33GB. Zero foreign keys (no DB-enforced referential integrity). 2 views, 1 stored procedure. Relationships are code-enforced.

**2026-04-24 — FAC uses pure BP-execution mode** — source: Step 1 catalog
File Gateway (SFG) tables are installed but effectively empty (0-6 rows across all FG_* tables). EDIINT/AS2/AS3/Mailbox features are present as workflow definitions but have zero runtime activity. FAC uses Sterling as a Business Process engine, not as a file gateway or EDI trading partner.

### 4.2 Workflow definitions and activity

**2026-04-24 — 1,433 distinct workflow definitions exist** — source: Step 3 (WFD deduplicated by NAME)
Not 200+ as previously believed. Not 2,467 either — that count includes version history.

**2026-04-24 — 332 distinct workflows are active in any 48-hour window** — source: Step 3
Remaining 1,101 are dormant (Sterling product features unused, deprecated flows, etc.). Investigation focuses on active workflows only.

**2026-04-24 — FA_CLIENTS_MAIN is 16% of total Sterling activity** — source: Step 3
Not the "universal grain" claimed in legacy `B2B_ArchitectureOverview.md`. FA_CLIENTS_ARCHIVE runs 26.5% and FA_CLIENTS_VITAL runs 26.2% of total — each more often than MAIN. Top 3 combined = 69% of all Sterling workflow volume.

**2026-04-24 — Four velocity tiers exist in the workflow universe** — source: Step 3
- Tier 1: pipeline sub-workflows (1000s/day): MAIN, ARCHIVE, VITAL
- Tier 2: infrastructure + dispatchers (100s/day): FileGateway*, TimeoutEvent, Schedule_*, Pattern 3 dispatchers, FA_CLIENTS_EMAIL, FA_CLIENTS_GET_LIST
- Tier 3: named scheduled pullers/pushers (10-50/day): FA_FROM_*_PULL, FA_TO_*_PUSH, client-specific wrappers
- Tier 4: daily workflows (1-2/day): vast majority of client-specific FA_FROM_*/FA_TO_*

### 4.3 Retention and archive

**2026-04-24 — Data horizon is ~30 days, not ~48 hours** — source: Step 2
`WF_INST_S`: ~7 days live. `WF_INST_S_RESTORE`: ~22 days archived. Combined: ~30 days. Clean archive model — live/restore are disjoint.

**2026-04-24 — Archive is transactional across related tables** — source: Step 2
`TRANS_DATA_RESTORE` has zero orphans relative to `WF_INST_S_RESTORE`. Payloads and workflows archive in lockstep.

**2026-04-24 — `ARCHIVE_INFO` drives purge, is forward-looking** — source: Step 2
4-column table with WF_ID, GROUP_ID, ARCHIVE_FLAG, ARCHIVE_DATE. `ARCHIVE_DATE` represents when Sterling *will* archive, not when it did. Four `GROUP_ID` values appear to represent archive table-group tiers. `ARCHIVE_FLAG = -1` is a post-purge bookkeeping state, not "never archive."

**2026-04-24 — `WORKFLOW_CONTEXT` and `TRANS_DATA` live tables have orphan rows** — source: Step 2 addendum
~0.02% of rows in each are from workflows whose `WF_INST_S` parent has been archived. Archive inconsistency at the edges. Benign but worth knowing for collector robustness.

### 4.4 Sterling table semantics

**2026-04-24 — `WF_INACTIVE` is an indefinite audit log, not a current-state table** — source: Step 4
1,745 of 1,746 rows are orphans from purged workflows. All rows have `REASON = 105`. 73% of rows come from two incident clusters (Nov 23-26, 2025 and Dec 9-16, 2025). Useless for retrospective queries. Could be a real-time alert trigger if combined with workflow-context capture at insert-time.

**2026-04-24 — `CORRELATION_SET` is SFTP/Translation event metadata** — source: Step 5
Per-document key-value pairs scoped to only 3 workflow families: MAIN (primary), ENCOUNTER_LOAD, DM_ENOTICE. Only ~14% of MAIN runs are instrumented (those doing actual SFTP pickup + translation). 12-key vocabulary dominated by SFTP transfer metadata. Retention matches WF_INST_S.

**2026-04-24 — WFD primary key is `(WFD_ID, WFD_VERSION)`** — source: Step 3 correction
Every workflow edit creates a new WFD row with incremented WFD_VERSION. Joining to WFD on WFD_ID alone produces cartesian products across version history. Collector code must join on `(WFD_ID, WFD_VERSION)` or use a one-row-per-WFD_ID lookup CTE.

### 4.5 Workflow identity and structure

**2026-04-24 — FA_FROM_* / FA_TO_* suffix convention encodes direction and business type** — source: Step 3
Active suffix codes observed: `_PULL`, `_PUSH`, `_S2D`, `_D2S`, `_IB`, `_OB`, `_BD`, `_EO`, `_NB`, `_NT`, `_RT`, `_RM`, `_SP`, `_TR`, `_RC`, `_FD`. This is the natural classification axis for client-specific workflows.

### 4.6 Carried forward from v1 (still verified)

**2026-04-23 — b2bi STATUS semantics in WF_INST_S:** STATUS = 0 means completed successfully; STATUS = 1 means terminated with errors.

**2026-04-23 — ProcessData is gzip-compressed in TRANS_DATA.DATA_OBJECT.** First DOCUMENT row (REFERENCE_TABLE='DOCUMENT', PAGE_INDEX=0, ordered by CREATION_DATE ASC) contains ProcessData.

**2026-04-23 — Write-at-termination for WF_INST_S.** Rows materialize at workflow termination with ~5-10 min lag. In-flight state cannot be observed via `WF_INST_S` polling.

**2026-04-23 — WORKFLOW_CONTEXT is written in real-time** during workflow execution. Can be used for in-flight detection.

**2026-04-23 — ROOT_WF_ID accurately identifies workflow tree roots** in `WORKFLOW_LINKAGE` without walking the tree manually.

---

## 5. Investigation Register

Each topic has a status, a short summary of what we know, and a link to the relevant findings doc. For detailed technical data, refer to the findings doc directly — this section intentionally stays slim.

### 5.1 b2bi Database Catalog

**Status:** ✅ Resolved
**Findings:** `Step_01_Database_Catalog/Step_01_Findings.md`

b2bi has 773 tables, 186 populated. Zero FKs. Full inventory of the workflow-execution surface identified. `_RESTORE` table family discovered. Sterling version 6.1.0.0 confirmed.

### 5.2 Retention and Archive

**Status:** ✅ Resolved
**Findings:** `Step_02_Retention_and_Archive/Step_02_Findings.md`

30-day data horizon across live + `_RESTORE` tables. Clean archive model. `ARCHIVE_INFO` drives forward-looking purge. No need for external historical sources (VITAL, Integration) for backfill as long as collector runs continuously.

### 5.3 Workflow Universe

**Status:** ✅ Resolved
**Findings:** `Step_03_Workflow_Definition_Catalog+Active_Inventory/Step_03_Findings.md`

1,433 distinct workflow definitions; 332 active in a 48-hour window. Four velocity tiers characterized. FA_* naming convention (FA_FROM_*, FA_TO_*, suffix codes) documented. MAIN is 16% of activity; ARCHIVE and VITAL each run more often than MAIN.

### 5.4 WF_INACTIVE

**Status:** ✅ Resolved — deprioritized
**Findings:** `Step_04_WF_INACTIVE/Step_04_Findings.md`

Halt audit log with indefinite retention. 99.94% orphan rate. Potentially useful as real-time alert signal if captured at insert-time, but not for retrospective queries.

### 5.5 CORRELATION_SET

**Status:** ✅ Resolved — role identified as enrichment
**Findings:** `Step_05_CORRELATION_SET/Step_05_Findings.md`

Per-document SFTP/translation metadata for a narrow subset of workflow families. Valuable enrichment layer for MAIN runs that do file ingestion. Not a universal workflow source.

### 5.6 FA_CLIENTS_MAIN Anatomy

**Status:** 🎯 **Next up (Step 6)** — highest priority, must complete in single session
**What we know:** MAIN orchestrates the file-processing pipeline. Runs ~2,354 times per 48 hours (16% of Sterling volume). Invokes ARCHIVE 1-3x, VITAL 0-N x, EMAIL conditionally. Uses ProcessData-driven routing. Has phase structure (GET_DOCS → TRANS → sub-workflow dispatch → cleanup). Some phase details in legacy `B2B_ProcessAnatomy_NewBusiness.md` but only verified for NB (ACADIA) scope.
**What's still open:**
- Full phase structure across all process types (not just NB)
- Which ProcessData fields drive which decisions
- Sub-workflow invocation conditions precisely mapped
- Failure mode inventory (what fails where, with what signature in WF_INST_S / WORKFLOW_CONTEXT)
- How MAIN behaves when SFTP pickup returns empty, when translation fails, when a file is malformed
**Approach (Step 6):** Hybrid — aggregate pass first to identify common phase/path structures, then traced examples of several representative process type flavors.

### 5.7 Sub-workflow Families (ARCHIVE, VITAL, EMAIL, ENCOUNTER_LOAD)

**Status:** 🔄 Deferred until after Step 6
**What we know:** ARCHIVE runs 3,881/48h; VITAL runs 3,844/48h; EMAIL 234/48h; ENCOUNTER_LOAD 30/48h. All currently tracked only as presence flags on MAIN rows. Their individual failure modes, outputs, and operational significance remain unexplored.
**Rationale for deferring:** These are invoked BY MAIN. Understanding MAIN first will reveal *how* and *when* each sub-workflow is called, which contextualizes their standalone investigation. Doing them before MAIN risks the same "incomplete understanding of context" problem that caused previous investigation passes to fail.
**Probable step ordering:** ARCHIVE first (highest volume), then VITAL, then EMAIL, then ENCOUNTER_LOAD.

### 5.8 Dispatcher Workflows

**Status:** 🔄 Partially addressed by Step 3; deeper dive deferred
**What we know:** Pattern 3 dispatchers (`FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC`/`_ARC`) run hundreds of times per 48h. `FA_CLIENTS_GET_LIST` runs 33 times. Many `FA_FROM_*_PULL` client-wrapper dispatchers run at client-specific cadences.
**What's still open:**
- Is schedule adherence monitoring needed ("scheduled dispatcher X failed to fire today")?
- How should dispatcher tracking relate to the MAIN executions they spawn?
- Do dispatchers fail in ways not reflected in downstream MAINs?
**Depends on:** sub-workflow family decisions (5.7) and MAIN anatomy (5.6)

### 5.9 Process Type Semantics

**Status:** 🔄 Deferred
**What we know:** Legacy `ArchitectureOverview` documents 31 distinct PROCESS_TYPE × COMM_METHOD combinations from `tbl_B2B_CLIENTS_FILES`. Process type is a ProcessData field (runtime), distinct from workflow family (name-based). The two are orthogonal axes.
**What's still open:**
- Verify the 31-pair list against current production data
- Understand each process type's pipeline behavior end-to-end
- Identify which process types warrant distinct monitoring patterns
**Likely step:** Some of this gets resolved as a side effect of Step 6 (tracing different process types). Remainder becomes a dedicated step after Step 6.

### 5.10 Integration Database Tables

**Status:** 🔄 Not yet addressed in investigation (prior understanding exists in archived docs, unverified)
**What we know (from legacy docs, not verified):** `Integration` DB on AVG-PROD-LSNR has `etl.tbl_B2B_*` tables with batch history. Claim: `WORKFLOW_ID` = `RUN_ID` across systems.
**What's still open:**
- Re-verify the RUN_ID = WORKFLOW_ID claim against current data
- Enumerate all `etl.tbl_B2B_*` tables and their contents/grains
- Determine role: authoritative source, enrichment, or historical reference
**Depends on:** MAIN scope decisions; may be deprioritized if Sterling's own retention (§4.3) is sufficient.

### 5.11 VITAL Database

**Status:** 🔄 Not yet addressed — likely deprioritized
**What we know:** VITAL is on ATLAS-DB. 2 tables. Pre-Sterling-era tracking database. No longer reliable as source of truth because newer ETLs omit VITAL writes.
**Revised assessment:** Given Sterling's own retention is ~30 days (vastly better than previously assumed), VITAL's role as historical-backfill source is weaker than originally framed.
**Depends on:** Historical coverage goal (5.13)

### 5.12 Other Unexamined Tables

**Status:** 🔄 Listed, not yet investigated
**Candidates:**
- `ACT_XFER` (33K rows), `ACT_NON_XFER` (48K rows), `ACTIVITY_INFO` (33K rows), `DATA_FLOW` (30K rows), `ACT_SESSION` (17K rows) — possible transfer-centric view
- `DOCUMENT` (348K rows), `DOCUMENT_EXTENSION` (235K rows) — document metadata, may relate to CORRELATION_SET's OBJECT_ID
- `SCHEDULE` (605 rows) — scheduler catalog, already partially understood from current `SI_ScheduleRegistry`
- `SERVICE_INSTANCE`, `SERVICE_DEF`, `SERVICE_PARM_LIST` — service configuration

**Proposed next step:** Investigation priorities to be determined based on what Step 6, 5.7, and 5.8 surface.

### 5.13 Historical Coverage Strategy

**Status:** 🔄 Reframed; simpler than previously thought
**Updated framing:** Sterling retains ~30 days natively across live + `_RESTORE`. For a continuously-running collector, external historical sources are unnecessary. They only matter if (a) collector ever stops for >30 days, or (b) some business requirement demands pre-xFACts history recovery.
**Decision needed:** Is there a business requirement for pre-xFACts-deployment history? If no, this investigation area can close with "Sterling retention is sufficient."

### 5.14 Real-Time In-Flight Visibility

**Status:** 🔄 Partial findings from v1 carry forward
**What we know:** `WORKFLOW_CONTEXT` is written in real-time. In-flight workflows visible via step activity without corresponding `WF_INST_S` row (yet).
**What's still open:** Whether to build in-flight detection into the collector, or accept ~5-10 min lag. No operational demand signal yet.
**Decision can wait:** until collector architecture is designed.

---

## 6. Out of Scope

- Sterling clustering / multi-node architecture — single-node deployment
- Sterling version upgrades or migration planning
- b2bi admin console internals — not a SQL data source
- Direct integration with Sterling REST APIs
- Alerting evaluation and delivery (Phase 4) — deferred
- Control Center UI for B2B (Phase 5) — deferred
- Anything pre-Sterling (Pervasive-era) beyond what VITAL captures, if we even pursue VITAL

---

## 7. Pending Decisions

Decisions that cannot be made until investigation progresses further.

### 7.1 SI_ExecutionTracking scope — rebuild or evolve?

**Depends on:** §5.6 (MAIN Anatomy), §5.7 (Sub-workflows), §5.8 (Dispatchers)
**Options:**
- Keep MAIN-only, add sibling tables for other workflow families
- Broaden to multi-family with a workflow_family discriminator
- Full redesign around a unified execution model covering all Tier 1-4 workflows
- Tear down `SI_ExecutionTracking` entirely and rebuild from first principles

**Current inclination (not yet decided):** Given the MAIN-only design misses 84% of activity and the "MAIN = universal grain" premise was wrong, a redesign feels more appropriate than an incremental broadening. Final decision should wait until MAIN anatomy and sub-workflow investigation is complete.

### 7.2 Collector architecture — one collector or many?

**Depends on:** §5.6, §5.7, §7.1
**Options:**
- Single collector (current pattern) targeting all workflow families
- Family-specific collectors (one for dispatchers, one for pipeline sub-workflows, etc.)
- Primary collector + enrichment collectors (e.g., CORRELATION_SET enrichment as a separate pass)

### 7.3 Sub-workflow execution detail — track or not?

**Depends on:** §5.6, §5.7
For each sub-workflow family (ARCHIVE, VITAL, EMAIL, ENCOUNTER_LOAD): does it warrant its own execution rows, or is parent-level flag sufficient? Answer likely differs per family.

### 7.4 Dispatcher tracking — own table, discriminator, or derived?

**Depends on:** §5.8
Options: sibling dispatcher tracking table; broaden SI_ExecutionTracking with a workflow_family discriminator; derive schedule adherence from SI_ScheduleRegistry + observed MAIN spawns.

### 7.5 VITAL / Integration integration — ingest, mirror, query-live, or ignore?

**Depends on:** §5.10, §5.11, §5.13
**Revised framing:** likely "ignore" for the general case. Integration might stay relevant as an enrichment join for MAIN specifically (since it has batch-status and ticket data). VITAL's role may be minimal.

### 7.6 Real-time in-flight visibility — build, defer, or skip?

**Depends on:** §5.14 and operational demand
No current signal that this matters. Can defer indefinitely.

### 7.7 Block 3 (execution detail extraction)

**Depends on:** §5.6, §5.9
Current `SI_ExecutionTracking` reserves columns for future per-file detail extraction from Translation output documents. Whether this ever gets built depends on MAIN anatomy and process-type findings.

---

## 8. Reference Material

### Investigation findings (chronological)

All under `xFACts-Documentation/WorkingFiles/B2B_Investigation/`:

1. `Step_01_Database_Catalog/Step_01_Findings.md` — 773 tables, Sterling 6.1 confirmed
2. `Step_02_Retention_and_Archive/Step_02_Findings.md` — 30-day horizon
3. `Step_03_Workflow_Definition_Catalog+Active_Inventory/Step_03_Findings.md` — workflow taxonomy + velocity tiers
4. `Step_04_WF_INACTIVE/Step_04_Findings.md` — audit log, deprioritized
5. `Step_05_CORRELATION_SET/Step_05_Findings.md` — enrichment role
6. **`Step_06_MAIN_Anatomy/` — next session**

Each findings doc includes: purpose, summary of change, detailed findings, implications for the collector, resolved questions, new questions, and document status.

### Legacy pre-investigation docs (reference-only, trust but verify)

Under `WorkingFiles/B2B_Investigation/Legacy/`:

- `B2B_ArchitectureOverview.md` — Contains both verified content and known-false claims. Roadmap wins any disagreement.
- `B2B_Module_Planning.md` — Block 1 and Block 2 planning notes. Historical.
- `B2B_Reference_Queries.md` — SQL queries against b2bi/Integration. Partial verification.
- `B2B_ProcessAnatomy_NewBusiness.md` — Still mostly accurate for its narrow scope (one NB trace); not a universal template. **Will be referenced as starting point for Step 6 traces.**
- `B2B_Roadmap_V1.md` — Pre-investigation Roadmap, preserved for audit trail.
- `B2BInvestigate-*.ps1`, `B2BScheduleTimingXml*.ps1`, etc. — Legacy PowerShell investigation scripts.

### External references

- IBM Sterling B2B Integrator 6.1.0 docs: https://www.ibm.com/docs/en/b2b-integrator/6.1.0
- SterlingSync blog (practitioner reference): https://sterlingsync.com/

---

## 9. Next Actions

Investigation priorities (in order):

1. **🎯 Step 6 — FA_CLIENTS_MAIN Anatomy (§5.6).** Highest priority. Third pass at understanding MAIN — must complete in a single session with full context. Approach: hybrid (aggregate → targeted traces → refinement). Session priming at top of this document.

2. **Step 7 — FA_CLIENTS_ARCHIVE deep-dive (§5.7).** Highest-volume sub-workflow (3,881 runs/48h). Best tackled after MAIN anatomy reveals its invocation pattern and context.

3. **Step 8 — FA_CLIENTS_VITAL deep-dive (§5.7).** Second-highest sub-workflow volume. Same reasoning.

4. **Step 9+ — Remaining sub-workflows (EMAIL, ENCOUNTER_LOAD) and dispatcher characterization (§5.8).** Priority driven by what earlier steps surface.

5. **Remaining table investigation (§5.12).** ACT_XFER, DOCUMENT, etc.

6. **Process type verification (§5.9).** May be partially resolved as side effect of MAIN traces.

7. **Integration DB re-verification (§5.10).** Deprioritized until core investigation complete.

8. **Decision phase.** Once investigation closes, resolve §7.x pending decisions and define collector architecture.

**Ordering note (v2.1):** MAIN anatomy was moved ahead of ARCHIVE deep-dive because sub-workflows are subordinate to MAIN. Investigating them first risks the same "incomplete context" failure pattern that undermined previous investigation passes.

---

## Document History

| Version | Date | Change |
|---|---|---|
| 2.1 | 2026-04-24 | Added "Next Session" priming section at top. Swapped §9 ordering — MAIN anatomy now precedes sub-workflow deep-dives. §5.6 reframed as active "next up" entry; §5.7 added for sub-workflow families as deferred. §2 Operating Principles added: high-stakes investigations must not split across sessions. Legacy file paths corrected to `Legacy/` subfolder. Step_03 and Step_05 findings paths corrected to match actual GitHub folder names. |
| 2.0 | 2026-04-24 | Full refresh after Steps 1-5. Slim structure; cross-references to findings docs. Significant updates to Known True, Investigation Register, Pending Decisions. v1 archived. |
| 1.0 | 2026-04-23 | Initial reset document after recognizing MAIN-only scope was incomplete. |

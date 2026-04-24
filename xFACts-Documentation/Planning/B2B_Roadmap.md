# B2B Module Roadmap

**Status:** Active — investigation phase (Steps 1-5 complete, Steps 6A-6B complete, Step 6C next)
**Version:** 2.3
**Last updated:** 2026-04-24
**Supersedes:** v2.2 (in-session); v2.1; v2.0; v1 (archived at `WorkingFiles/B2B_Investigation/Legacy/B2B_Roadmap_V1.md`)

---

## ⚡ Next Session — Start Here

**This section is the first thing to read when opening this document in a new session.**

### What's next

**Step 6C — Core Workflow BPML Analysis**

Step 6B extracted 429 BPML files into `WorkingFiles/B2B_Investigation/Step_06_MAIN_Anatomy/Step_06B_BPML_Bulk_Extraction/BPMLs/` organized by family. Step 6C deep-reads the FA_CLIENTS family (28 BPMLs: 11 active + 17 dormant/inline) plus representative dispatchers from FA_FROM/FA_TO to understand structure, sub-workflow invocation patterns, service calls, fault handlers, and external references.

### Approach (Step 6C specifics)

1. **Read FA_CLIENTS_MAIN v48 first** (the orchestrator). Document every rule, every sub-workflow invocation, every service call, every fault handler, every external reference (stored procs, scripts, files). Build a structural map of MAIN as the anchor document.
2. **Read the 17 dormant FA_CLIENTS inline sub-workflows next.** For each, capture: what triggers it from MAIN, what it does, what other workflows/services/scripts it touches. This is the set that's invisible at runtime — BPML is the only way to know what they do.
3. **Read the other 10 active FA_CLIENTS workflows** (VITAL, ARCHIVE, EMAIL, JIRA_TICKETS, GET_LIST, ENCOUNTER_LOAD, GROUP_KEYS_SP, INVALID_ACCOUNTS_OB_EOBD_D2S_RPT, CNSMR_ACCNT_AR_IB_BDEO_S2X_BDL, CNSMR_TAG_IB_BDEO_S2X_BDL).
4. **Read representative dispatcher BPMLs** — one FA_FROM_*_PULL (Pattern 4), one FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S (Pattern 3), one FA_TO_*_PUSH (Pattern 5 equivalent). Not comprehensive — just enough to validate dispatcher claims in the ArchitectureOverview.

Output: `Step_06C_Findings.md` — a structural map document organized around MAIN as the spine, with sub-workflow and dispatcher sections. Individual-workflow deep reads accumulate as sub-sections; the final doc is the canonical structural reference for the FA_CLIENTS world.

### Session start prompt template

When opening the next session:

> Starting Step 6C — Core Workflow BPML Analysis. Cache-busted manifest URL: https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=<value>

### Required context before starting 6C

1. **This Roadmap** (you're reading it) — current state, Known True list, pending decisions
2. **`WorkingFiles/B2B_Investigation/Step_06_MAIN_Anatomy/Step_06A_Active_Workflow_Catalog/Step_06A_Findings.md`** — workflow inventory (11 active + 17 dormant FA_CLIENTS; 413 active 30d overall)
3. **`WorkingFiles/B2B_Investigation/Step_06_MAIN_Anatomy/Step_06B_BPML_Bulk_Extraction/Step_06B_Findings.md`** — BPML storage model + extraction output
4. **`WorkingFiles/B2B_Investigation/Step_06_MAIN_Anatomy/Step_06B_BPML_Bulk_Extraction/BPMLs/`** — the 429 extracted BPML files (this is the primary input for 6C)
5. **`WorkingFiles/B2B_Investigation/Legacy/B2B_ArchitectureOverview.md`** — keep handy; 6C read patterns should note where BPML structure agrees/disagrees with ArchitectureOverview claims (full claim verification comes in 6D)

### What Step 6 is NOT

- A rebuild of the collector (that comes after investigation closes)
- A replacement of `SI_ExecutionTracking` or `SI_ScheduleRegistry` (they continue running; decisions about them come later)
- Process-type-specific traces (those come in a later step once structural understanding is solid)

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
- **Every "Known True" claim must be directly verified** against production data or BPML source, with date of verification recorded. Inherited claims don't count until re-verified.
- **BPML is an authoritative structural source** for what each workflow can do. Runtime observation (WORKFLOW_CONTEXT, ProcessData) verifies what workflows *actually did* in specific runs. Both are needed; neither alone is sufficient.
- **Uncertainty gets written down as an open question** rather than assumed away.
- **Operational staff are first-class information sources** but are not the primary path — we're building documentation that never existed. Dirk is the customer of Sterling at FAC, not its architect. The original architect (`rbmakram`) and other historical editors are no longer available for consultation.
- **Existing production artifacts** (`SI_ScheduleRegistry`, `SI_ExecutionTracking`, `Collect-B2BExecution.ps1`) stay as-is during investigation. They function for their narrow scope and are collecting data. All of them will be re-evaluated when investigation completes — they may fold into the eventual comprehensive collector, or be replaced. Nothing downstream consumes them yet (no alerting, no CC pages), so replacement is a clean-slate option.
- **The investigation documents (this Roadmap + step findings) are working documents, not permanent documentation.** Their purpose is to inform the module build. Once the module is built, these documents will eventually be archived and real HTML documentation will be authored from them.
- **Step 6 is checkpointed across multiple sessions.** The original "do it all in one session" framing was abandoned after scope expanded to cover the full workflow universe (not just MAIN). Each sub-step produces its own findings and Roadmap update.

---

## 3. Current State

### 3.1 Production artifacts (in use, narrow scope)

| Artifact | Scope | Status |
|---|---|---|
| `B2B.SI_ScheduleRegistry` | Schedule catalog sync from `b2bi.dbo.SCHEDULE` | Functional, complete for its scope |
| `B2B.SI_ExecutionTracking` | Per-workflow tracking for FA_CLIENTS_MAIN only | Functional, but captures ~16% of total Sterling activity |
| `Collect-B2BExecution.ps1` | Single collector, FIRE_AND_FORGET mode, dependency_group 10 | Functional, narrow scope |
| GlobalConfig settings | `b2b_alerting_enabled` (BIT, 0), `b2b_collect_lookback_days` (INT, 3) | Alerting stubbed |

No downstream consumers. No alerting. No Control Center pages. The collector is pure collection — replacing it carries no blast radius beyond losing the ~3-4 days of collected data, which has no historical weight.

### 3.2 Scope of coverage

Current collector captures FA_CLIENTS_MAIN only. Investigation has shown MAIN is roughly 16% of total Sterling workflow activity — the other 84% is invisible. Sub-workflows (ARCHIVE, VITAL, EMAIL), dispatchers (GET_LIST, FA_FROM_*, FA_TO_*), Sterling infrastructure (FileGateway, Schedule_*), and most client-specific workflows are not captured.

The investigation underway is determining what a comprehensive collector should look like, not how to extend the current MAIN-only design.

---

## 4. Known True

Facts verified against production data or BPML source. Each entry dated with source. Entries only added after direct verification.

### 4.1 Sterling environment

**2026-04-24 — Sterling B2B Integrator version 6.1.0.0** — source: `SI_VERSION` table
Installed 2021-03-23. Matches IBM docs at `ibm.com/docs/en/b2b-integrator/6.1.0`. Version-accurate reference.

**2026-04-24 — b2bi database shape** — source: Step 1 catalog
773 tables total, 186 populated, 587 empty. ~11.5M rows, ~33GB. Zero foreign keys (no DB-enforced referential integrity). 2 views, 1 stored procedure. Relationships are code-enforced.

**2026-04-24 — FAC uses pure BP-execution mode** — source: Step 1 catalog
File Gateway (SFG) tables are installed but effectively empty (0-6 rows across all FG_* tables). EDIINT/AS2/AS3/Mailbox features are present as workflow definitions but have zero runtime activity. FAC uses Sterling as a Business Process engine, not as a file gateway or EDI trading partner.

**2026-04-24 — Sterling is single-node** — source: Step 6A
All 413 active workflows in a 30-day window show `distinct_nodes_seen = 1` in `WF_INST_S.NODEEXECUTED`. No clustering.

### 4.2 Workflow definitions and activity

**2026-04-24 — 1,433 distinct workflow definitions exist** — source: Step 3 and re-confirmed Step 6A (WFD deduplicated by WFD_ID via MAX(WFD_VERSION))
Not 200+ as previously believed. Not 2,467 either — that count includes version history.

**2026-04-24 — 413 distinct workflows are active in any 30-day window** — source: Step 6A
Step 3's 332 active count was at 48h and undercounted weekly/monthly workflows. The 30-day window is the correct investigation lens. Remaining 1,020 WFDs are dormant.

**2026-04-24 — FA_CLIENTS_MAIN is 16.1% of total Sterling activity over 30 days** — source: Step 6A
Not the "universal grain" claimed in legacy `B2B_ArchitectureOverview.md`. `FA_CLIENTS_VITAL` runs 26.6% and `FA_CLIENTS_ARCHIVE` runs 26.6% of total — each more often than MAIN. Top 3 combined = 69.3% of all Sterling workflow volume over 30 days.

**2026-04-24 — Four velocity tiers exist in the workflow universe** — source: Step 3
- Tier 1: pipeline sub-workflows (1000s/day): MAIN, ARCHIVE, VITAL
- Tier 2: infrastructure + dispatchers (100s/day): FileGateway*, TimeoutEvent, Schedule_*, Pattern 3 dispatchers, FA_CLIENTS_EMAIL, FA_CLIENTS_GET_LIST
- Tier 3: named scheduled pullers/pushers (10-50/day): FA_FROM_*_PULL, FA_TO_*_PUSH, client-specific wrappers
- Tier 4: daily workflows (1-2/day): vast majority of client-specific FA_FROM_*/FA_TO_*

**2026-04-24 — 11 active FA_CLIENTS top-level workflows; 17 dormant FA_CLIENTS workflows run inline inside MAIN** — source: Step 6A
Active top-level: MAIN, VITAL, ARCHIVE, EMAIL, JIRA_TICKETS, GET_LIST, ENCOUNTER_LOAD, CNSMR_ACCNT_AR_IB_BDEO_S2X_BDL, CNSMR_TAG_IB_BDEO_S2X_BDL, GROUP_KEYS_SP, INVALID_ACCOUNTS_OB_EOBD_D2S_RPT.
Dormant (run inline inside MAIN, not visible in `WF_INST_S`): ACCOUNTS_LOAD, ADDRESS_CHECK, COMM_CALL, DUP_CHECK, ENCOUNTER_ID, ETL_CALL (deprecated), FILE_MERGE, GET_DOCS, POST_TRANSLATION, PREP_COMM_CALL, PREP_SOURCE, REMIT_DATA_VERIFICATION, TABLE_INSERT, TABLE_PULL, TRANS, TRANSLATION_STAGING, WORKERS_COMP. *Inline behavior to be verified in Step 6C from BPML.*

**2026-04-24 — MAIN currently at WFD_VERSION 48, ran at 2 distinct versions in the 30-day window** — source: Step 6A
Mid-flight version migration is the observed mechanism — when MAIN is edited, in-flight instances continue running the old version until they complete. BPML extraction must use MAX(WFD_VERSION) per WFD_ID.

**2026-04-24 — FA_CLIENTS_MAIN v48 has 23 top-level rules and 590 total elements** — source: Step 6B
Rule names verified from BPML source: AnyMoreDocs?, Prep?, PreArchive?, Translate?, DupCheck?, WorkersComp?, PostArchive?, SendEmail?, CommCall?, MergeFiles?, PrepCommCall?, VITAL?, PostArchive2?, Wait?, Continue?, NB?, Encounter?, AddressLookup?, SaveDoc?, PostTranslation?, PostTranslationVITAL?, TranslationStaging?, RemoveSpecialCharacters?. Not 22 rules as legacy ArchitectureOverview implied. Rule semantics to be characterized in Step 6C.

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

**2026-04-24 — WFD primary key is `(WFD_ID, WFD_VERSION)`** — source: Step 3 correction, confirmed Step 6A
Every workflow edit creates a new WFD row with incremented WFD_VERSION. Joining to WFD on WFD_ID alone produces cartesian products across version history. Collector code must join on `(WFD_ID, WFD_VERSION)` or use a one-row-per-WFD_ID lookup CTE.

**2026-04-24 — `WF_INST_S.STATUS` shows only values 0 and 1 in 30 days of production** — source: Step 6A
Across 38,211 instance rows, only STATUS values 0 and 1 are observed. Legacy framing "0 = success, 1 = terminated with errors" is consistent with this observation but semantic meaning has not been independently verified — noted as an open question for Step 6E.

**2026-04-24 — BPML storage model** — source: Step 6B
`b2bi.dbo.WFD_XML` is a thin 4-column lookup (one row per (WFD_ID, WFD_VERSION)). Its `XML` column is a handle (nvarchar(255)) joining to `b2bi.dbo.DATA_TABLE.DATA_ID`. The actual BPML lives in `DATA_TABLE.DATA_OBJECT` (image type), gzip-compressed, with a 6-32 byte Java serialization preamble before the XML content. No pagination — all blobs at PAGE_INDEX=0. Total corpus for 429 latest-version BPMLs: ~193 KB compressed, ~640 KB decompressed.

### 4.5 Workflow identity and structure

**2026-04-24 — FA_FROM_* / FA_TO_* suffix convention encodes direction and business type** — source: Step 3
Active suffix codes observed: `_PULL`, `_PUSH`, `_S2D`, `_D2S`, `_IB`, `_OB`, `_BD`, `_EO`, `_NB`, `_NT`, `_RT`, `_RM`, `_SP`, `_TR`, `_RC`, `_FD`. This is the natural classification axis for client-specific workflows. Step 6A's single-trailing-token suffix extraction proved insufficient for multi-suffix names; a more sophisticated parser will be developed in Step 6C.

**2026-04-24 — Every b2bi BPML has `<process>` as its root element** — source: Step 6B
All 429 extracted BPMLs parse as well-formed XML with root tag `<process name="...">`. Element counts range from 7 (smallest workflow) to 590 (FA_CLIENTS_MAIN v48). Median BPML has 16 elements. Corpus total: 11,045 elements.

**2026-04-24 — BPMLs can optionally include XML comment prologues** — source: Step 6B
Sterling-shipped workflows (AFT*, some Schedule_*) include copyright/documentation `<!-- ... -->` blocks before `<process>`. FAC-authored (FA_*) workflows do not. Not functionally significant but noted as a classification signal for 6F.

### 4.6 Retracted inherited claims (from prior investigation; to be re-verified)

The previous Roadmap §4.6 ("Carried forward from v1") included claims about ProcessData location, WORKFLOW_CONTEXT marker conventions, ROOT_WF_ID behavior, STATUS/STATE semantics, and MAIN sub-workflow invocation patterns. **These were inherited from pre-investigation documents and legacy single-run traces, not verified in Steps 1-5.** Per the reset, they are null-and-void until re-verified through BPML reading (Step 6C) or runtime observation (Step 6E).

Specifically retracted and requiring re-verification:
- ProcessData is gzip-compressed in TRANS_DATA.DATA_OBJECT, first DOCUMENT row by CREATION_DATE ASC
- Write-at-termination for WF_INST_S with ~5-10 min lag
- WORKFLOW_CONTEXT is written in real-time during workflow execution
- ROOT_WF_ID accurately identifies workflow tree roots in WORKFLOW_LINKAGE
- STATUS semantics (0 = success, 1 = error) — value range confirmed in Step 6A, semantics not verified

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

**Status:** ✅ Resolved (updated in Step 6A)
**Findings:** `Step_03_Workflow_Definition_Catalog+Active_Inventory/Step_03_Findings.md`, updated in `Step_06_MAIN_Anatomy/Step_06A_Active_Workflow_Catalog/Step_06A_Findings.md`

1,433 distinct workflow definitions; 413 active in a 30-day window (up from Step 3's 332 at 48h). Four velocity tiers characterized. FA_* naming convention documented. MAIN is 16% of activity; ARCHIVE and VITAL each run more often than MAIN. 11 active + 17 dormant FA_CLIENTS workflows catalogued for BPML extraction in Step 6B.

### 5.4 WF_INACTIVE

**Status:** ✅ Resolved — deprioritized
**Findings:** `Step_04_WF_INACTIVE/Step_04_Findings.md`

Halt audit log with indefinite retention. 99.94% orphan rate. Potentially useful as real-time alert signal if captured at insert-time, but not for retrospective queries.

### 5.5 CORRELATION_SET

**Status:** ✅ Resolved — role identified as enrichment
**Findings:** `Step_05_CORRELATION_SET/Step_05_Findings.md`

Per-document SFTP/translation metadata for a narrow subset of workflow families. Valuable enrichment layer for MAIN runs that do file ingestion. Not a universal workflow source.

### 5.6 FA_CLIENTS_MAIN Anatomy (Step 6 umbrella)

**Status:** 🎯 Active — Steps 6A-6B complete, 6C next
**Findings so far:**
- `Step_06_MAIN_Anatomy/Step_06A_Active_Workflow_Catalog/Step_06A_Findings.md`
- `Step_06_MAIN_Anatomy/Step_06B_BPML_Bulk_Extraction/Step_06B_Findings.md`

Step 6 has been restructured into checkpointed sub-steps after the scope expanded from "MAIN anatomy only" to "verify the full architecture described in the legacy ArchitectureOverview document." The legacy document contains both accurate and known-false content about MAIN, its sub-workflows, and the broader Sterling architecture. Step 6 extracts every factual claim into a verification checklist and resolves each against BPML source or runtime observation.

Sub-step sequence:

- **6A — Active Workflow Catalog** ✅ Complete. 1,433 WFDs catalogued, 413 active in 30d, extraction target list of 429 BPMLs identified (413 active + 17 dormant FA_CLIENTS, minus 1 overlap).
- **6B — BPML Bulk Extraction** ✅ Complete. BPML storage model discovered (WFD_XML → DATA_TABLE indirection, gzip+Java-preamble encoding). All 429 BPMLs extracted, parsed as well-formed XML, organized by family, and committed to the repo at `Step_06B_BPML_Bulk_Extraction/BPMLs/`. Extraction tool `Step_06B_Extract_BPMLs.ps1` available for re-extraction as b2bi evolves.
- **6C — Core Workflow BPML Analysis** 🎯 Next. Deep-read the FA_CLIENTS family (all 28 active + dormant) plus representative dispatchers (FA_FROM/FA_TO Pattern 1/3/4 examples). Document each workflow's sequence, rules, sub-workflow invocations (with INVOKE_MODE), service calls, fault handlers, and external executable references.
- **6D — Claim Verification against ArchitectureOverview.** Extract every factual claim from the legacy document into a markdown checklist. Resolve each: verified / corrected / discarded, with evidence reference.
- **6E — Runtime Verification.** Target the claims BPML can't answer — schedule frequencies, actual vs. expected invocation counts, STATUS semantics, TYPE/PERSISTENCE_LEVEL meanings, observed failure rates, etc. Queries against b2bi (primarily WORKFLOW_CONTEXT, WF_INST_S, and the existing SI_ExecutionTracking corpus).
- **6F — Light Catalog of remaining BPMLs.** The ~390 non-FA_CLIENTS active workflows. Not full structural analysis — just enough to classify, note sub-workflow invocations, and group by pattern.
- **6G — Consolidation.** Single Step 6 Summary document. Claim checklist finalized. ArchitectureOverview either reconciled into a revised authoritative document or retired. Clear handoff to post-Step-6 work.

**What comes after Step 6:** collector architecture decisions (§7) can finally be addressed with verified structural knowledge of every workflow in play.

### 5.7 Sub-workflow Families (ARCHIVE, VITAL, EMAIL, ENCOUNTER_LOAD)

**Status:** 🔄 Partially covered by Step 6C (inline sub-workflows from BPML source); standalone runtime deep-dives deferred
**What we know:** ARCHIVE runs 10,167/30d; VITAL runs 10,179/30d; EMAIL 620/30d; ENCOUNTER_LOAD 82/30d (with 6.1% fail rate — highest among FA_CLIENTS). Their BPMLs have been extracted (Step 6B) and will be deep-read in Step 6C alongside MAIN. Standalone runtime behavior analysis (failure modes across runs, content of their outputs) comes after Step 6 completes.

### 5.8 Dispatcher Workflows

**Status:** 🔄 Partially covered by Step 6C (BPML reads of representative dispatchers); comprehensive dispatcher analysis deferred
**What we know from Step 6A:** Pattern 3 (`FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC`/`_ARC`) runs 688+656 times per 30d. `FA_CLIENTS_GET_LIST` runs only 85 times in 30d — far fewer than the ArchitectureOverview's claimed 11×/business-day schedule (~242 expected). Hypothesis: Pattern 4 wrappers invoke GET_LIST inline and therefore don't generate WF_INST_S rows. Verifiable via BPML analysis in Step 6C.

### 5.9 Process Type Semantics

**Status:** 🔄 Deferred to a later step
**What we know (unverified):** Legacy `ArchitectureOverview` documents 31 distinct PROCESS_TYPE × COMM_METHOD combinations. Process type is a ProcessData field (runtime), distinct from workflow family (name-based). Verification happens after Step 6 provides the structural baseline.

### 5.10 Integration Database Tables

**Status:** 🔄 Not yet addressed in investigation
**What we know (unverified, from legacy docs):** `Integration` DB on AVG-PROD-LSNR has `etl.tbl_B2B_*` tables. Claim: `WORKFLOW_ID` = `RUN_ID` across systems. `USP_B2B_CLIENTS_GET_LIST` and `USP_B2B_CLIENTS_GET_SETTINGS` stored procedures are invoked from Sterling BPMLs.
**Deferred until after Step 6.** Step 6C's BPML analysis will verify which Integration artifacts Sterling actually references; then a later step can verify those artifacts exist and their contents.

### 5.11 VITAL Database

**Status:** 🔄 Not yet addressed — likely deprioritized

### 5.12 Other Unexamined Tables

**Status:** 🔄 Listed, not yet investigated
**Candidates:** `ACT_XFER` (33K rows), `ACT_NON_XFER` (48K rows), `ACTIVITY_INFO` (33K rows), `DATA_FLOW` (30K rows), `ACT_SESSION` (17K rows), `DOCUMENT` (348K rows), `DOCUMENT_EXTENSION` (235K rows), `SCHEDULE` (605 rows; already known via `SI_ScheduleRegistry`), `SERVICE_INSTANCE`, `SERVICE_DEF`, `SERVICE_PARM_LIST`.

### 5.13 Historical Coverage Strategy

**Status:** 🔄 Reframed; simpler than previously thought

### 5.14 Real-Time In-Flight Visibility

**Status:** 🔄 Deferred until after Step 6

### 5.15 Open questions raised by Step 6A/6B (to be resolved in 6C-6E)

1. Why do FA_CLIENTS_GET_LIST runs (85 in 30d) fall so far short of the claimed 11×/business-day schedule (~242)? Hypothesis: Pattern 4 inline invocation. Verifiable via BPML analysis in 6C.
2. What is WFD.TYPE? Why do 16 workflows have TYPE=101 vs 393 at TYPE=1?
3. What does WFD.STATUS = 2 mean for the three active workflows that have it?
4. Why does WFD.ONFAULT = 'false' universally? Likely indicates a default-fault-handler toggle separate from BPML-level `<onFault>` blocks.
5. How does FA_CLIENTS_ARCHIVE handle failure signaling if STATUS=1 is never set? Either extremely reliable, fails silently in a way invisible to WF_INST_S.STATUS, or has its own internal error-handling.
6. What does FA_CLIENTS_JIRA_TICKETS do? 120 runs in 30d, not mentioned in ArchitectureOverview.
7. What does FA_CLIENTS_ENCOUNTER_LOAD's 6% fail rate indicate? Highest fail rate among FA_CLIENTS workflows.
8. What is the `GBMDATA` handle in `WFD_XML`? NULL for most rows; suspected graphical BP designer data. Not required for structural analysis but worth understanding for completeness.

---

## 6. Out of Scope

- Sterling clustering / multi-node architecture — single-node deployment
- Sterling version upgrades or migration planning
- b2bi admin console internals — not a SQL data source
- Direct integration with Sterling REST APIs
- Alerting evaluation and delivery — deferred until investigation complete
- Control Center UI for B2B — deferred until investigation complete
- Anything pre-Sterling (Pervasive-era) beyond what VITAL captures, if we even pursue VITAL

---

## 7. Pending Decisions

Decisions that cannot be made until investigation progresses further. All §7 items remain deferred until Step 6 completes.

### 7.1 SI_ExecutionTracking scope — rebuild or evolve?

**Depends on:** §5.6 (Step 6 overall)
Current inclination (not yet decided): full rebuild. The existing collector has ~3-4 days of data, nothing downstream consumes it, and the conceptual foundation (MAIN as universal grain) proved wrong. Clean-slate design is viable without cost.

### 7.2 Collector architecture — one collector or many?
### 7.3 Sub-workflow execution detail — track or not?
### 7.4 Dispatcher tracking — own table, discriminator, or derived?
### 7.5 VITAL / Integration integration — ingest, mirror, query-live, or ignore?
### 7.6 Real-time in-flight visibility — build, defer, or skip?
### 7.7 Block 3 (execution detail extraction) — build or skip?

---

## 8. Reference Material

### Investigation findings (chronological)

All under `xFACts-Documentation/WorkingFiles/B2B_Investigation/`:

1. `Step_01_Database_Catalog/Step_01_Findings.md` — 773 tables, Sterling 6.1 confirmed
2. `Step_02_Retention_and_Archive/Step_02_Findings.md` — 30-day horizon
3. `Step_03_Workflow_Definition_Catalog+Active_Inventory/Step_03_Findings.md` — workflow taxonomy + velocity tiers
4. `Step_04_WF_INACTIVE/Step_04_Findings.md` — audit log, deprioritized
5. `Step_05_CORRELATION_SET/Step_05_Findings.md` — enrichment role
6. **`Step_06_MAIN_Anatomy/`** — umbrella folder for Step 6 sub-steps:
   - `Step_06A_Active_Workflow_Catalog/Step_06A_Findings.md` ✅ Complete
   - `Step_06B_BPML_Bulk_Extraction/Step_06B_Findings.md` ✅ Complete
     - `BPMLs/` — 429 extracted BPMLs organized by family (primary input for 6C)
   - `Step_06C_Core_Workflow_BPML_Analysis/` — next
   - `Step_06D_Claim_Verification/` — to follow
   - `Step_06E_Runtime_Verification/` — to follow
   - `Step_06F_Light_BPML_Catalog/` — to follow
   - `Step_06G_Consolidation/` — to follow

Each findings doc includes: purpose, summary of change, detailed findings, implications for the collector, resolved questions, new questions, and document status.

### Legacy pre-investigation docs (reference-only — reclassified)

Under `WorkingFiles/B2B_Investigation/Legacy/`:

- **`B2B_ArchitectureOverview.md`** — **Reclassified as "structured hypothesis document"** rather than reference-with-errors. Every factual claim in it will be extracted into a verification checklist in Step 6D and resolved against BPML or runtime evidence. The document's own deprecation notice calls out known-false claims (MAIN = universal grain, "~48hr retention", "200+ FA_ workflows", dispatch pattern count churn). Until Step 6D resolves the remaining claims, treat nothing in this document as authoritative.
- `B2B_Module_Planning.md` — Historical planning notes.
- `B2B_Reference_Queries.md` — SQL queries against b2bi/Integration. Partial verification.
- `B2B_ProcessAnatomy_NewBusiness.md` — Single ACADIA NB trace. Mostly accurate for its narrow scope but *not* a universal template.
- `B2B_Roadmap_V1.md` — Pre-investigation Roadmap, preserved for audit trail.
- `B2BInvestigate-*.ps1`, `B2BScheduleTimingXml*.ps1`, etc. — Legacy PowerShell investigation scripts. Useful for extraction patterns; not authoritative for conclusions.

### External references

- IBM Sterling B2B Integrator 6.1.0 docs: https://www.ibm.com/docs/en/b2b-integrator/6.1.0
- SterlingSync blog (practitioner reference): https://sterlingsync.com/

---

## 9. Next Actions

Investigation priorities (in order):

1. **🎯 Step 6C — Core Workflow BPML Analysis (§5.6).** Next up. Deep-read FA_CLIENTS family + representative dispatchers using the 429-file BPML corpus from Step 6B.
2. **Step 6D — Claim Verification.** Extract and resolve every ArchitectureOverview claim.
3. **Step 6E — Runtime Verification.** Runtime queries for claims BPML can't answer.
4. **Step 6F — Light BPML Catalog.** The remaining ~390 non-FA_CLIENTS active BPMLs.
5. **Step 6G — Consolidation.** Step 6 summary; claim checklist resolved; ArchitectureOverview reconciled.
6. **Post-Step-6 steps** — sub-workflow runtime deep-dives (ARCHIVE, VITAL, EMAIL, ENCOUNTER_LOAD); dispatcher runtime analysis; process type semantic verification (§5.9); Integration DB verification (§5.10); remaining table investigation (§5.12).
7. **Decision phase.** §7.x resolved; collector architecture defined.

---

## Document History

| Version | Date | Change |
|---|---|---|
| 2.3 | 2026-04-24 | Step 6B complete. §5.6 updated to show 6B ✅; §4.2 adds FA_CLIENTS_MAIN rule-count (23 rules) fact from BPML inspection; §4.4 adds BPML storage model as verified Known True; §4.5 adds `<process>` root confirmation + XML comment prologue observation. §5.7 and §5.8 note that BPML corpus is now available for 6C deep reads. §5.15 adds GBMDATA handle as new open question. §8 reference tree updated to show BPMLs folder. Next Session section rewritten for 6C start. |
| 2.2 | 2026-04-24 | Step 6A complete. §5.6 restructured to reflect Step 6 split into 6A-6G sub-steps. §4.2 updated to use 30-day active count (413) from Step 6A; added Step 6A findings about FA_CLIENTS active/dormant split and MAIN's version-48 current state. §4.6 "Carried forward from v1" entries retracted as inherited-and-unverified; moved to explicit "Retracted inherited claims" block to be re-verified. §4.4 expanded with Step 6A's STATUS-values-observed finding. §5.3 updated to reference Step 6A supplement. §5.7, §5.8, §5.10 reframed to note that Step 6C's BPML analysis will cover structural aspects. §5.15 added — seven new open questions raised by Step 6A. Legacy ArchitectureOverview reclassified in §8 as "structured hypothesis document" rather than "reference with errors." §7 items consolidated — all remain deferred until Step 6 closes. Operating Principles §2 adjusted: removed "must complete in single session" constraint; added "BPML is an authoritative structural source" principle. Next Session section rewritten for 6B start. Next Actions renumbered. |
| 2.1 | 2026-04-24 | Added "Next Session" priming section at top. Swapped §9 ordering — MAIN anatomy now precedes sub-workflow deep-dives. §5.6 reframed as active "next up" entry; §5.7 added for sub-workflow families as deferred. §2 Operating Principles added: high-stakes investigations must not split across sessions. Legacy file paths corrected to `Legacy/` subfolder. Step_03 and Step_05 findings paths corrected to match actual GitHub folder names. |
| 2.0 | 2026-04-24 | Full refresh after Steps 1-5. Slim structure; cross-references to findings docs. Significant updates to Known True, Investigation Register, Pending Decisions. v1 archived. |
| 1.0 | 2026-04-23 | Initial reset document after recognizing MAIN-only scope was incomplete. |

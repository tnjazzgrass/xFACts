# Step 1 Findings — b2bi Database Catalog

**Date:** 2026-04-24
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_01_Database_Catalog/`
**Query file:** `Step_01_Query.sql`
**Results file:** `Step_01_Results.txt`

## Purpose

First step in the B2B module investigation reset. Treat b2bi as a first-time discovery; no assumptions about contents. Inventory every table with row counts and basic structure so we can identify what's actually there before diving into specific areas.

---

## Sterling version

**IBM Sterling B2B Integrator 6.1.0.0** (installed 2021-03-23).

Confirmed from `SI_VERSION` table with supporting component rows for `B2BF`, `FileGateway`, `PLATFORM`, `SI_MOBILE`, `Translator`, `Standards`, `Ebics`, `EBICS_CLIENT`, `STDS_TX`, `STUDIO` (1.2.4), and various platform components. `SI_Install_Base` shows `6.1.0.0` with a "New Media" install note.

Matches IBM docs at https://www.ibm.com/docs/en/b2b-integrator/6.1.0 — use this as the version-accurate reference going forward.

---

## Database shape

| Metric | Value |
|---|---|
| User tables | 773 |
| Populated tables (rows > 0) | 186 |
| Empty tables | 587 |
| Total rows across all tables | ~11.5M |
| Total data size | ~32.8 GB |
| Foreign keys | **0** |
| Views | 2 (both CEB event related) |
| Stored procedures | 1 (`yfs_sp_getkey`) |

**Observations:**

- **Zero foreign keys.** Sterling does not enforce referential integrity at the database layer. All relationships are application-code enforced. This means we cannot rely on the DB catalog to tell us how tables relate — we have to discover join patterns from IBM docs, observed data, and BPML inspection.
- **Only 2 views, 1 stored procedure.** The database is a passive data store; Sterling's logic lives entirely in the application tier. There's no vendor-provided abstraction layer to lean on.
- **76% of tables are empty.** FAC uses a relatively small footprint of the total Sterling feature surface. The empty tables include things like File Gateway (SFG), EBICS, YFS order management, document lifespan tracking — features that exist in the product but aren't configured at FAC.

---

## The _RESTORE table family — previously unknown, potentially significant

Seven `*_RESTORE` tables exist, all populated. The naming convention suggests Sterling's archive/restore mechanism moves terminated workflow data from live tables to `_RESTORE` tables before eventual purge.

| Table | Rows | Live counterpart rows |
|---|--:|--:|
| `TRANS_DATA_RESTORE` | 3,435,924 | `TRANS_DATA`: 2,254,362 |
| `WFC_S_RESTORE` | 825,702 | *(no live base table named `WFC_S`)* |
| `DOCUMENT_RESTORE` | 511,332 | `DOCUMENT`: 348,951 |
| `DOC_EXT_RESTORE` | 328,298 | *(no live base table named `DOC_EXT`)* |
| `CORREL_SET_RESTORE` | 74,359 | *(no live base table named `CORREL_SET`)* |
| `WF_INST_S_RESTORE` | 23,468 | `WF_INST_S`: 14,499 |
| `SI_VERSION_RESTORE` | 96 | `SI_VERSION`: 32 |

**Critical observations:**

- In every case where a live counterpart exists, `_RESTORE` has *more* rows than the live table.
- Several `_RESTORE` tables have no matching live table (WFC_S, DOC_EXT, CORREL_SET). `WFC_S_RESTORE` in particular holds 825K rows — this almost certainly holds historical `WORKFLOW_CONTEXT` data that's been archived out of the live table.
- **Our prior assumption of "b2bi has ~48hr retention" may be badly incomplete.** That assumption was based on the live tables only. If `_RESTORE` tables hold significantly more history, the historical-coverage strategy in Roadmap §5.9 may simplify dramatically — we might not need VITAL or Integration for backfill at all, because Sterling is already retaining its own history.

**This is the highest-priority thing to verify in Step 2.**

---

## The _WRK table family — transient worktables

Four `*_WRK` and `*_WRK2` tables exist:

| Table | Rows | Purpose (inferred) |
|---|--:|---|
| `ARCHIVE_INFO_WRK2` | 7,379 | Worktable for the archive process |
| `BPMV_LS_WRK2` | 113 | BP Moving Linkage Sweep worktable |
| `BPMV_TM_WRK` | 24 | BP Moving Transaction Metadata worktable |
| `WF_INST_S_WRK` | 24 | Short-window buffer for WF_INST_S |

**Observation:** On 2026-04-23, `WF_INST_S_WRK` was observed with ~126 rows. Today it has 24. This confirms `_WRK` tables are transient buffers, not persistent stores. The earlier Roadmap finding ("WRK is a short-window buffer") stands.

---

## The workflow execution surface

Tables with clear workflow / execution purpose, populated:

### Execution state

| Table | Rows | Cols | Notes |
|---|--:|--:|---|
| `WF_INST_S` | 14,499 | 16 | Live workflow instance state |
| `WF_INST_S_RESTORE` | 23,468 | 16 | Archived instances — history window |
| `WF_INST_S_WRK` | 24 | 19 | Short-window buffer (not live state) |
| `WORKFLOW_CONTEXT` | 519,321 | 33 | Step-by-step execution log (live) |
| `WFC_S_RESTORE` | 825,702 | 33 | Archived context rows |
| `WORKFLOW_LINKAGE` | 11,225 | 4 | Parent/child BP linkage |
| `WF_INACTIVE` | 1,746 | 3 | Likely "halted/paused" workflows — unexplored |
| `WF_UNIQUEID` | 1 | 1 | ID generator sequence |

### Workflow definitions (BPML)

| Table | Rows | Cols | Notes |
|---|--:|--:|---|
| `WFD` | **2,467** | 26 | One row per workflow definition |
| `WFD_XML` | 2,466 | 4 | BPML XML content |
| `WFD_VERSIONS` | 1,432 | 6 | Version history per WFD |
| `WFD_GUID_UNIQUEID` | 1,545 | 2 | GUID mapping |

**Observation:** There are 2,467 workflow definitions — an order of magnitude higher than the "200+ FA_*" count we'd previously worked with. FA_* is one naming family among many. We've never enumerated the full WFD catalog.

### Payload and data storage

| Table | Rows | MB | Notes |
|---|--:|--:|---|
| `TRANS_DATA` | 2,254,362 | 12,319 | Live payloads (where ProcessData lives) |
| `TRANS_DATA_RESTORE` | 3,435,924 | 18,121 | Archived payloads |
| `DATA_TABLE` | 99,990 | 387 | TIMINGXML blobs + other large content |
| `DOCUMENT` | 348,951 | 182 | Document metadata |
| `DOCUMENT_RESTORE` | 511,332 | 187 | Archived document metadata |
| `DOCUMENT_EXTENSION` | 235,387 | 98 | Extended document attributes — unexplored |
| `DOC_EXT_RESTORE` | 328,298 | 114 | Archived extensions — unexplored |

### Services and adapters

| Table | Rows | Cols |
|---|--:|--:|
| `SERVICE_INSTANCE` | 476 | 14 |
| `SERVICE_DEF` | 450 | 18 |
| `SERVICE_PARM_LIST` | 3,025 | 13 |
| `SERVICE_INST_PARMS` | 2,337 | 4 |
| `ADAPTER_IMPL` | 59 | 4 |
| `SCHEDULE` | 605 | 19 |

### Housekeeping / archive drivers

| Table | Rows | Notes |
|---|--:|---|
| `ARCHIVE_INFO` | 80,646 | Per IBM docs, drives purge across ~40 tables |
| `ARCHIVE_INFO_WRK2` | 7,379 | Worktable for archive process |

### Transfer / activity tracking — unexamined

| Table | Rows | Notes |
|---|--:|---|
| `DATA_FLOW_GUID` | 1,206,239 | High volume; likely just an ID mapping |
| `ACT_SESSION_GUID` | 899,372 | High volume; likely ID mapping |
| `ACT_NON_XFER` | 48,812 | Activity records — not transfers |
| `ACT_XFER` | 33,822 | Activity records — transfers (likely file transfers) |
| `ACTIVITY_INFO` | 33,713 | Activity detail |
| `DATA_FLOW` | 30,185 | Data flow tracking |
| `ACT_SESSION` | 17,414 | Per-session tracking |
| `ACT_AUTHENTICATE` | 17,384 | Auth records |

**Observation:** The `ACT_*` / `DATA_FLOW` family holds substantial data we've never queried. `ACT_XFER` in particular (33K rows) may contain per-file-transfer records that could be a more direct answer to "what did Sterling actually do" than working up from `WF_INST_S`. Worth investigating.

### Correlation — unexamined

| Table | Rows | Cols |
|---|--:|--:|
| `CORRELATION_SET` | 47,550 | 11 |
| `CORREL_SET_RESTORE` | 74,359 | 11 |
| `CORREL_KEY` | 207 | 5 |

**Observation:** Per IBM docs, `CORRELATION_SET` holds key-value tracking data (EDI tracking, file transfer details, Connect:Direct details). We've never opened this table. 47K live rows + 74K restore suggests heavy use by some process type we haven't examined.

### File Gateway (SFG) — present but effectively unused

- `FG_C_FLR_TRANS`: 1 row
- `FG_P_FLR_TYPE` / `FG_C_FLR_TYPE`: 6 rows each
- All other `FG_*` tables: 0 rows

**Conclusion:** FAC is not using Sterling in File Gateway mode. The `FG_*` family can be deprioritized for investigation purposes.

### CEB / Events — low priority

228 rows in `CEB_EVENT_CD`, 211 in `CEB_ORD_TYPE`. These relate to B2B Integrator Visibility / event subscriptions. Possibly relevant for a future "real-time event stream" angle but not priority for understanding execution tracking.

### YFS family — platform infrastructure

33 populated `YFS_*` tables with ~29K total rows. The `YFS_` prefix is legacy Yantra (predecessor to Sterling). These are platform-level infrastructure (users, calendars, currencies, org structure). Almost certainly not workflow-execution-relevant.

### Notable empty tables

Features installed but not in use:

- `DOCUMENT_LIFESPAN`, `WORKFLOW_LIFESPAN`, `WORKFLOW_DATA` — 0 rows. Sterling's built-in lifespan tracking is not active.
- `PERF_WF_STATS` — 0 rows. No performance stats retained.
- `FIFO_WORKFLOW_TASK`, `WF_HINT`, `WF_DATA_RESTORE` — 0 rows.
- All `BPSS_*`, most `EB_*` and `EDIINT*` tables — 0 rows. EDI-integration-specific features not in use.
- Most `YFS_*` business-document tables — 0 rows.

---

## What this changes from the archived `B2B_ArchitectureOverview.md` claims

| Prior claim | Observed |
|---|---|
| "`WF_INST_S` has ~48hr retention" | Possibly true for *live* table only. `WF_INST_S_RESTORE` has 23,468 rows and may hold significantly more history. Step 2 will verify. |
| "Retention is unknown / unclear" | `ARCHIVE_INFO` (80K rows) drives it. Sterling has its own archive mechanism that retains data longer than previously assumed. |
| "b2bi has 200+ FA_* workflow names" | `WFD` has **2,467 workflow definitions total**. FA_* is one family among many; the rest are unenumerated. |
| "Integration is an active coordination layer" | Still true — but `CORRELATION_SET` is *also* a Sterling-native coordination/tracking layer we never mentioned. 47K live rows suggests heavy use. |
| (Nothing said about `CORRELATION_SET`) | 47,550 live + 74K restore rows. Unexplored. |
| (Nothing said about `ACT_*` / `DATA_FLOW`) | 1.2M rows in `DATA_FLOW_GUID`, 33K in `ACT_XFER`. Major data surface unexplored. |
| (Nothing said about `_RESTORE` family) | Seven populated tables, all with more rows than their live counterparts where applicable. Sterling is retaining its own history. |
| (Nothing said about `WF_INACTIVE`) | 1,746 rows. Likely halted/paused workflows. Unexplored. |

---

## Open questions raised by Step 1

These need to be addressed in subsequent investigation steps:

1. **How far back does data actually go** across live + `_RESTORE` tables? This is the most consequential question — answered by Step 2.
2. **Is the live/_RESTORE split clean** — are they disjoint, or overlapping? (Answered by Step 2.)
3. **What retention pattern does each table family follow?** Does `WF_INST_S_RESTORE` go back months while `TRANS_DATA_RESTORE` only goes back weeks? (Answered by Step 2.)
4. **What is `ARCHIVE_INFO` actually driving?** Can we see the Sterling-side purge policy from its contents? (Answered by Step 2.)
5. **What is `CORRELATION_SET` tracking** for our workflows? Does it correlate to `WORKFLOW_ID`? What process types use it? (Step 3 or later.)
6. **What's in `ACT_XFER` / `DATA_FLOW`** and do they represent per-transfer execution that might be a better anchor than `WF_INST_S`? (Step 3 or later.)
7. **What does `WF_INACTIVE` contain?** Are these workflows we should treat as "still running" for monitoring purposes? (Step 3 or later.)
8. **What's the relationship between `DOCUMENT` and `TRANS_DATA`?** Do all `TRANS_DATA` rows have corresponding `DOCUMENT` rows? Is `DOCUMENT_EXTENSION` where we'd find additional per-document attributes we've been missing? (Later.)
9. **What are the other ~2,200 workflow definitions in `WFD`** beyond the FA_* family? (Later — requires its own dedicated enumeration step.)

---

## Implications for the existing collector and build

**Do not act on these yet.** Captured here for forward reference.

- If `_RESTORE` tables hold significant history, the `is_complete` lookback optimization pattern in `Collect-B2BExecution.ps1` may need rethinking — we might not want to skip rows that have left the live table.
- The current `SI_ExecutionTracking` captures data from `WF_INST_S` only. If archived-but-not-yet-purged executions exist in `_RESTORE`, we may be missing data for recently-terminated workflows that Sterling has already moved out of the live table.
- VITAL and Integration-tables historical backfill strategies (Roadmap §5.9) may become unnecessary if Sterling's own `_RESTORE` retention is adequate.
- The entire "48-hour data horizon" framing needs to be replaced with a measured retention-per-table map.

---

## Document status

| Attribute | Value |
|---|---|
| Step | 01 — Database Catalog |
| Status | Complete |
| Next step | Step 02 — Retention and Archive Truth (focus on `_RESTORE` tables and `ARCHIVE_INFO`) |
| Roadmap impact | Multiple §5.x areas will be updated based on Step 1 + Step 2 combined findings |

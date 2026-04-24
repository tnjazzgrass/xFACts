# Step 2 Findings — Retention and Archive Truth

**Date:** 2026-04-24
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_02_Retention_and_Archive/`
**Query file:** `Step_02_Query.sql` (core + addendum)
**Results file:** `Step_02_Results.txt` (core + addendum)

## Purpose

Step 1 discovered `_RESTORE` tables that we'd never examined, and we hypothesized Sterling might be retaining significantly more history than the "~48hr" framing previously assumed. Step 2 verifies the actual data horizon across live and archived tables and exposes the archive mechanism.

---

## Summary of what changed

**The "b2bi has ~48-hour retention" framing was wrong.** Sterling retains data for longer than we believed, but less than initial Step 2 readings suggested. Real retention across all major workflow tables is ~7 days live + ~22 days in `_RESTORE` = **~30-day total horizon**. The 13-month "live" span seen in `WORKFLOW_CONTEXT` and `TRANS_DATA` was caused by a tiny handful of orphan rows (<0.02% of the data) and is not representative.

**The bigger finding:** our current collector is seeing roughly 13% of Sterling's daily workflow volume. On a busy day (Wed/Thu) b2bi processes 6,000-8,000 workflow instances; `FA_CLIENTS_MAIN` is only ~800 of those. Roughly **87% of what Sterling actually does is invisible to `SI_ExecutionTracking`.**

---

## Retention horizon — verified

### `WF_INST_S` family (workflow instances)

| Table | Rows | Oldest | Newest | Span |
|---|--:|---|---|---|
| `WF_INST_S` (live) | 14,820 | 2026-04-17 | 2026-04-24 | 7 days |
| `WF_INST_S_RESTORE` | 23,468 | 2026-03-25 | 2026-04-16 | 22 days |
| **Combined total** | **38,288** | **2026-03-25** | **2026-04-24** | **30 days** |
| Overlap | 0 | — | — | — |

`WF_INST_S` has a clean 30-day data horizon. After that, rows are purged entirely.

### `WORKFLOW_CONTEXT` family (step-level execution log)

| Table | Rows | Oldest | Newest | Span | Notes |
|---|--:|---|---|---|---|
| `WORKFLOW_CONTEXT` (live) | 527,123 | 2025-03-11 | 2026-04-24 | 9,800 hours raw | See age distribution |
| `WFC_S_RESTORE` | 825,702 | 2026-03-25 | 2026-04-16 | 22 days | |

**Live `WORKFLOW_CONTEXT` age distribution (addendum verified):**

| Age bucket | Row count | % of total |
|---|--:|--:|
| Last 7 days | 527,380 | 99.996% |
| Last 30 days | 2 | 0.000% |
| Last 180 days | 4 | 0.001% |
| Older than 365 | 13 | 0.002% |

**The 13-month span is an orphan-row artifact.** 99.996% of live `WORKFLOW_CONTEXT` data is in the last 7 days. The 19 total orphan rows are from workflows whose `WF_INST_S` rows have already been archived but whose step-level records never got cleaned up. These represent an archive inconsistency at the edge, not true retention.

### `TRANS_DATA` family (payloads)

| Table | Rows | Oldest | Newest | Span | Notes |
|---|--:|---|---|---|---|
| `TRANS_DATA` (live) | 1,142,548 | 2025-03-11 | 2026-04-24 | 9,800 hours raw | See age distribution |
| `TRANS_DATA_RESTORE`* | 1,717,962 | 2026-03-25 | 2026-04-16 | 22 days | Date via `WF_INST_S_RESTORE` join |

\* `TRANS_DATA_RESTORE` lacks a `CREATION_DATE` column (only 6 columns vs. 8 on live); age was inferred by joining `WF_ID` to `WF_INST_S_RESTORE.WORKFLOW_ID`.

**Live `TRANS_DATA` age distribution (addendum verified):**

| Age bucket | Row count | % of total |
|---|--:|--:|
| Last 7 days | 1,143,587 | 99.982% |
| Last 30 days | 3 | 0.000% |
| Last 180 days | 6 | 0.001% |
| Last 365 days | 29 | 0.003% |
| Older than 365 | 163 | 0.014% |

Same pattern as `WORKFLOW_CONTEXT`: 201 orphan rows out of 1.14M (0.018%). Real retention is 7 days live.

**One confirming finding:** `TRANS_DATA_RESTORE` has **zero orphans** relative to `WF_INST_S_RESTORE` — every archived payload row maps cleanly to an archived workflow. This tells us Sterling archives these two tables in lockstep: if a workflow is archived, its payloads are archived in the same operation. 1.7M payload rows correspond to the 23,468 archived workflows (~73 payload rows per workflow on average).

### `TRANS_DATA_RESTORE` row count discrepancy

| Source | Count |
|---|--:|
| Step 1 (`sys.partitions` estimate) | 3,435,924 |
| Step 2 (actual `SELECT COUNT`) | 1,717,962 |

**Not a data change.** `sys.partitions.rows` is documented as an approximate counter that SQL Server updates lazily. The accurate count is 1.7M. For high-volume tables the estimate can be off by 2x or more. Step 1 row counts are useful for relative sizing but should not be trusted for absolute counts.

---

## Daily workflow volume pattern

Daily breakdown from query 2.4 (combined live + restore, last 30 days):

| Date | Day | Live rows | Restore rows | Total |
|---|---|--:|--:|--:|
| 2026-04-24 | Fri | 1,351 | 0 | 1,351 (partial day) |
| **2026-04-23** | **Thu** | **7,377** | **0** | **7,377** |
| **2026-04-22** | **Wed** | **6,079** | **0** | **6,079** |
| 2026-04-21 | Tue | 4 | 0 | 4 |
| 2026-04-20 | Mon | 4 | 0 | 4 |
| 2026-04-19 | Sun | 1 | 0 | 1 |
| 2026-04-18 | Sat | 1 | 0 | 1 |
| 2026-04-17 | Fri | 3 | 0 | 3 |
| 2026-04-16 | Thu | 0 | 178 | 178 |
| **2026-04-15** | **Wed** | **0** | **7,507** | **7,507** |
| (gap 04-03 to 04-14) |  | — | — | — |
| 2026-04-02 | Thu | 0 | 178 | 178 |
| **2026-04-01** | **Wed** | **0** | **7,864** | **7,864** |
| (gap 03-29 to 03-31) |  | — | — | — |
| 2026-03-28 | Sat | 0 | 185 | 185 |
| **2026-03-27** | **Fri** | **0** | **7,553** | **7,553** |
| 2026-03-26 | Thu | 0 | 2 | 2 |
| 2026-03-25 | Wed | 0 | 1 | 1 |

**Observations:**

1. **Wed/Thu are high-volume days (6K-8K workflow instances).** Normal business-day operational profile.
2. **Other days have 1-4 rows.** These are "holdouts" — workflows that couldn't be archived yet (still in-flight, have dependencies, or archive scheduling hasn't caught up).
3. **The 2.4 query filters to `START_TIME >= DATEADD(DAY, -30, GETDATE())`**, but only shows 16 dates total in the 30-day window. This is because the archive has already moved normal-day bulk to `_RESTORE` or purged it, leaving only a few representative days in the live window at any given time.
4. **Weekends have near-zero activity.** Sat/Sun consistently show 1 row, confirming FAC operates b2bi on business-day schedule primarily.

**MAIN vs. total volume:**

- Roadmap previously observed 2,395 MAIN runs over 3 days = ~800 MAIN/day
- Total workflow volume on a normal Wed: 6,079
- **MAIN is ~13% of total Sterling workflow activity**
- **~87% of Sterling's work is NOT captured by the current collector**

This verifies the MAIN-only collector is badly incomplete and justifies the full investigation reset.

---

## `ARCHIVE_INFO` — structure and semantics

### Structure

| Column | Type | Nullable |
|---|---|---|
| `WF_ID` | numeric(9) | No |
| `GROUP_ID` | int | No |
| `ARCHIVE_FLAG` | int | Yes |
| `ARCHIVE_DATE` | datetime | Yes |

4 columns. Simple table but drives the entire archive mechanism.

### Totals and behavior

`ARCHIVE_INFO` has ~81,000 rows. Date range (where not NULL): 2026-04-24 (today) to 2026-05-08 (14 days forward).

**`ARCHIVE_DATE` is a FORWARD-looking scheduling column, not a historical log.** It represents when Sterling *will* archive the row, not when it did.

### `GROUP_ID` and `ARCHIVE_FLAG` distribution (addendum)

| `GROUP_ID` | `ARCHIVE_FLAG` | Row count | Date range |
|---:|---:|--:|---|
| 1 | -1 | 1,677 | NULL |
| 1 | 0 | 1,426 | 2026-04-26 (1 day) |
| 1 | 2 | 13,367 | 2026-04-24 to 2026-04-26 (2 days) |
| 2 | -1 | 1,677 | NULL |
| 2 | 0 | 1,426 | 2026-04-26 to 2026-04-27 (1 day) |
| 2 | 2 | 13,797 | 2026-04-24 to 2026-04-27 (3 days) |
| 3 | 1 | 17,422 | 2026-04-24 to 2026-05-08 (14 days) |
| 4 | 1 | 30,206 | 2026-04-24 to 2026-05-08 (14 days) |

**`GROUP_ID` appears to represent archive table-group tiers.** Groups 1 and 2 have identical row counts for `FLAG=-1` and `FLAG=0` (1,677 each and 1,426 each), and near-identical `FLAG=2` counts (13,367 vs. 13,797). This strongly suggests Groups 1 and 2 are paired — likely representing a "live table + its `_RESTORE` table" partnership, tracked together through the archive lifecycle.

Groups 3 and 4 only have `FLAG=1` and much higher counts (17K and 30K). These appear to be different archive tiers — possibly related to lower-tier tables (extensions, correlations, etc.) that purge on a longer cadence.

**Per-workflow mapping:** Total workflows in `WF_INST_S` + `WF_INST_S_RESTORE` = 38,288. Total `ARCHIVE_INFO` rows ≈ 81,000. Ratio: ~2.1 archive rows per workflow. If 4 table-group tiers exist, most workflows have multiple `ARCHIVE_INFO` entries at any given time (one per applicable table group).

### `ARCHIVE_FLAG = -1` — "archive complete" marker, not "never archive" (addendum)

Initial Step 2 hypothesis: `FLAG=-1` meant "never archive" (in-flight or parked workflows).

**The hypothesis was wrong.** Addendum queries revealed:

- **Only 2 of 3,354 `FLAG=-1` rows correlate with `WF_INACTIVE`** (the halted/paused workflow table). So these are not halted workflows.
- **3,354 of 3,354 `FLAG=-1` rows reference workflow IDs that exist in NEITHER `WF_INST_S` nor `WF_INST_S_RESTORE`.** The underlying workflows have been fully purged already.

**Revised interpretation:** `ARCHIVE_FLAG = -1` appears to mean "archive complete — awaiting final cleanup." `ARCHIVE_INFO` is bookkeeping that outlives the workflow itself. Sterling keeps these rows around until some final purge cleanup pass removes them. The NULL `ARCHIVE_DATE` reflects that there's no future archive scheduled (because the workflow is already gone).

This is a significant correction to Step 2's initial reading.

### Retention mechanism — confirmed model

Combining everything:

1. Workflow terminates → row(s) inserted into `ARCHIVE_INFO` with future `ARCHIVE_DATE` (typically 2-14 days out), flagged by `GROUP_ID` tier
2. Scheduled archive job runs → moves rows from live tables (`WF_INST_S`, `TRANS_DATA`, `WORKFLOW_CONTEXT`, `DOCUMENT`, etc.) to their `_RESTORE` counterparts
3. Workflow ages out of `_RESTORE` → rows deleted, `ARCHIVE_FLAG` transitions to -1 (cleanup bookkeeping state)
4. Final cleanup pass → eventually removes `FLAG=-1` rows from `ARCHIVE_INFO`

**Confirmed archive mechanism properties:**

- Archive is a **true move** (overlap = 0 between live and `_RESTORE`)
- Archive is **transactional across related tables** (`TRANS_DATA_RESTORE` has zero orphans relative to `WF_INST_S_RESTORE`)
- Archive is **scheduled, not continuous** — `ARCHIVE_INFO` queues future dates
- Multiple `GROUP_ID` tiers exist, each with its own archive cadence
- `ARCHIVE_FLAG = -1` is a post-purge bookkeeping state, not a "never archive" marker

---

## Implications for the collector

**Observations only. No implementation decisions at this stage.**

1. **Our realistic data horizon is ~7 days in live tables.** Anything older requires querying `_RESTORE`. Once more than ~30 days old, it's gone entirely.

2. **The live/restore split is clean.** A collector that queries both tables with `UNION ALL` can see the full ~30 days without duplicate rows.

3. **No need for VITAL or Integration historical backfill** (Roadmap §5.9) — as long as the collector runs continuously, Sterling's own ~30-day retention covers the gap. VITAL/Integration only become relevant if the collector stops for >30 days and we need to recover older history. Given the collector has been running for weeks, this changes our sense of what §5.9 needs to address.

4. **Our collector is capturing ~13% of workflow activity.** This is the core finding that justifies the full reset.

5. **Collection cadence:** b2bi generates 6K-8K new rows per business day. A 5-minute polling interval means ~30-40 new rows per cycle on average. Completely manageable.

6. **`ARCHIVE_INFO` is a useful forward-looking signal.** Rows with `ARCHIVE_FLAG = 0, 1, or 2` with near-future `ARCHIVE_DATE` let us know what's about to disappear from live tables. If the collector misses its polling window for some reason, `ARCHIVE_INFO` tells us what we need to query from `_RESTORE` to recover.

7. **Archive inconsistencies exist at the edges.** The 19 `WORKFLOW_CONTEXT` orphans and 201 `TRANS_DATA` orphans are benign today but indicate Sterling's archive mechanism isn't perfectly transactional across all related tables. Worth being aware of for collector robustness — we may want to handle "step exists but parent workflow doesn't" gracefully.

---

## Resolved questions (originally open)

1. ✅ **Is the 13-month `WORKFLOW_CONTEXT` / `TRANS_DATA` live retention real?** No — 99.98%+ of data is in last 7 days. The old rows are archive-inconsistency orphans.

2. ✅ **What does `GROUP_ID` represent in `ARCHIVE_INFO`?** Four archive tier groups. Groups 1 & 2 appear paired (live + `_RESTORE` pair tracking); Groups 3 & 4 represent different table-group archive cadences.

3. ✅ **Are `ARCHIVE_FLAG = -1` rows correlated to `WF_INACTIVE` or live workflows?** Neither. `FLAG=-1` represents post-purge bookkeeping state, not "never archive."

---

## Document status

| Attribute | Value |
|---|---|
| Step | 02 — Retention and Archive Truth |
| Status | **Complete** (core + addendum) |
| Next | Step 3 — Unexamined workflow surface (`CORRELATION_SET`, `ACT_XFER`, `DATA_FLOW`, `WF_INACTIVE`) |
| Roadmap impact | §5.8 (b2bi Write Model and Retention) substantially updated. §5.9 (Historical Coverage Strategy) simplified — no need for VITAL/Integration backfill if collector runs continuously. §5.4 implicated — MAIN is ~13% of total activity, confirming the sub-workflow gap is larger than previously framed. |

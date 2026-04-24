# Step 4 Findings — WF_INACTIVE

**Date:** 2026-04-24
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_04_WF_INACTIVE/`
**Query file:** `Step_04_Query.sql` (core + addendum)
**Results file:** `Step_04_Results.txt` (core + addendum)

## Purpose

Step 1 discovered `WF_INACTIVE` (1,746 rows) as an unexplored table. IBM documentation describes it as holding "halted" business processes — workflows that stopped mid-execution. This step determines what the table actually contains at FAC, whether it represents currently-stuck work, and whether it's useful for monitoring.

---

## Summary of what changed

**`WF_INACTIVE` is a halt audit log with permanent retention, not a current-state table.** It accumulates one row per historical halt event and never purges those rows — even after the underlying workflow is completely deleted from the system. 99.94% of its current contents reference workflows that were purged months or years ago.

**Pattern observed:** 73% of all rows come from two incident clusters (Nov 23-26, 2025: 864 rows; Dec 9-16, 2025: 419 rows) — classic "Sterling outage or crash event" signatures. The rest of the 18-month history shows a background rate of ~25 halts per month with occasional small clusters.

**Operational implication:** `WF_INACTIVE` is not useful for retrospective queries because the workflow context is gone. But it *could* be useful as a real-time alert signal if we watch for new inserts and capture workflow context before archival moves the data out of our reach.

---

## Structure

| Column | Type | Nullable |
|---|---|---|
| `WF_ID` | numeric(9) | No |
| `WF_DATE` | datetime | No |
| `REASON` | int | No |

Only 3 columns. No WFD_ID, no workflow name, no step context, no recovery state. The table is just *"workflow X halted at time Y for reason code Z."* To get any meaningful context we have to join `WF_ID` back to `WF_INST_S` or `WF_INST_S_RESTORE` — if those rows still exist.

---

## The orphan problem

Query 4.3 revealed the core issue:

| Status | Row count |
|---|--:|
| ORPHAN (no match in WF_INST_S or WF_INST_S_RESTORE) | **1,745** |
| ARCHIVED_WF_INST_S | 1 |
| LIVE_WF_INST_S | 0 |

Only **one** `WF_INACTIVE` row links to a workflow we can still see in the database. The other 1,745 reference workflows that have been fully purged.

The one match: `FA_CLIENTS_MAIN`, WFD_ID 798, started 2026-04-01 05:14:28 — part of the 24-row April 1 halt cluster. Within the 30-day archive window, so still visible in `WF_INST_S_RESTORE`.

**Interpretation:** `WF_INACTIVE` retention is **completely decoupled** from workflow retention. Where `WF_INST_S` and `WF_INST_S_RESTORE` together hold ~30 days of history, `WF_INACTIVE` holds ~18 months — the oldest row is from 2024-10-21, ~18 months old as of today.

This matches a pattern we observed in Step 2 with `ARCHIVE_FLAG = -1` bookkeeping rows: Sterling writes audit/tracking records that outlive the workflows they reference.

---

## REASON distribution

| REASON | Row count | Oldest | Newest |
|---|--:|---|---|
| 105 | 1,746 | 2024-10-21 09:37:30 | 2026-04-06 19:42:36 |

**Every single row has REASON = 105.** No other reason codes are represented.

The semantic meaning of 105 is not known from the data alone. Sterling documents reason codes in internal references we don't have access to, and Rober likely won't know. What we can infer operationally: it's the only reason code Sterling has ever used in this installation, over 18+ months, suggesting it's either:
- A generic "halted" catch-all code
- A specific failure mode that's the *only* one producing halts at FAC
- Possibly: "BP was running when the engine restarted"

Worth flagging for a Rober question later, but low priority — regardless of what 105 means, it hasn't varied enough to provide operational signal.

---

## Temporal distribution — the incident pattern

Date-by-date halt counts reveal clear clustering:

### Major incident clusters

**November 2025 cluster (864 rows, 4 days):**

| Date | Halts |
|---|--:|
| 2025-11-23 | 259 |
| 2025-11-24 | 414 |
| 2025-11-25 | 180 |
| 2025-11-26 | 11 |

**December 2025 cluster (419 rows, 8 days):**

| Date | Halts |
|---|--:|
| 2025-12-09 | 121 |
| 2025-12-10 | 4 |
| 2025-12-11 | 68 |
| 2025-12-16 | 226 |

**Combined: 1,283 rows over 12 days = 73% of all halt history.**

These clustering patterns are characteristic of infrastructure incidents — Sterling crashes, forced restarts, network outages, deployment failures, or similar events that leave many in-flight workflows stranded. Without context from ops records, we can't say what specifically happened on those dates, but the data shape is unambiguous.

### Background rate

Outside the two clusters, halts occur at ~25 per month in 2026 YTD:

| Month | Halts |
|---|--:|
| 2026-04 (through 4/6) | 2 |
| 2026-03 | 10 |
| 2026-02 | 36 |
| 2026-01 | 24 |
| Rolling average | ~25/month |

Two small notable sub-clusters in 2026: **April 1 had 24 halts in one day**, and **June 23-29, 2025** had 55 halts over 7 days. These smaller clusters likely represent minor incidents.

---

## Implications for monitoring design

**Observations only. No decisions at this stage.**

1. **`WF_INACTIVE` is useless for retrospective queries.** The workflow context (name, client, SEQ_ID, ProcessData, failure details) is long gone for 99.94% of halt rows. We can't look at this table and ask *"which workflows have been stuck?"* in any meaningful sense.

2. **`WF_INACTIVE` could be useful as a real-time alert trigger.** If we detect new rows being inserted within a narrow time window (say, last 5 minutes), we can simultaneously query `WF_INST_S` and `WORKFLOW_CONTEXT` to capture full workflow context before the archive removes it. Without that real-time capture, the halt is effectively a ghost — we know *something* got stuck but have no idea what.

3. **Cluster detection is the high-value signal.** The normal background rate is ~1 halt per day. A spike of 20+ halts in a day is an infrastructure event. Alert logic: "Sterling halted N workflows in the last hour, where N > threshold" would catch what we can see in the historical data.

4. **REASON=105 is the only halt reason observed.** We can't build multi-branch alerting based on reason codes; it's a single-state signal. Whether the code means "engine restart" or "deadlock detected" or something else, we'd need operational context to decode — but for now, treating "WF_INACTIVE row appeared" as the whole signal is sufficient.

5. **Cross-referencing against workflow family taxonomy isn't practical.** Since 1,745 of 1,746 rows have no WFD_ID link (workflow is purged), we can't classify halts by family or client historically. A real-time collector that captured this at halt time could build that classification going forward.

---

## Resolved questions (originally open)

1. ✅ **What's the structure of WF_INACTIVE?** 3 columns: WF_ID, WF_DATE, REASON. Minimal.
2. ✅ **What workflows are currently halted?** Only 1 has workflow context available (FA_CLIENTS_MAIN from 2026-04-01). All others are orphan references.
3. ✅ **Is this ancient backlog or recent stuck work?** Both — 73% ancient incident backlog, 27% recent background halts over 18+ months.
4. ✅ **Do halted rows correspond to live workflows?** Almost never (1 of 1,746).

---

## New questions raised

1. **What does REASON = 105 mean?** Low priority — all rows have this value so it doesn't help differentiate. Could add to a future Rober question batch.
2. **Does the April 1, 2026 cluster correspond to anything your team remembers?** If so, this gives us ground truth: "24 workflows halted + [incident you recall] = this is what a cluster looks like."
3. **What are the Nov 23-26 and Dec 9-16, 2025 incidents?** Two major outages that your team may or may not have records of. Significant enough to halt 1,283 workflows combined. Historical curiosity unless we want to retroactively understand past incidents.

---

## Closure for this table

**`WF_INACTIVE` can be deprioritized as a collector target.** It's effectively dormant as a data source — new rows arrive ~25 per month plus the occasional incident cluster. If we eventually build real-time halt monitoring, we'd want an incremental collector that watches for new `WF_INACTIVE` inserts and immediately captures workflow context from `WF_INST_S`. But that's a Phase 4+ feature, not an MVP concern.

The table is added to the "investigated and understood" list. We can move on.

---

## Document status

| Attribute | Value |
|---|---|
| Step | 04 — WF_INACTIVE |
| Status | **Complete** (core + addendum) |
| Next | Step 5 — CORRELATION_SET |
| Roadmap impact | §5.1 (Workflow Universe) — WF_INACTIVE characterized, deprioritized. §5.5 (Dispatchers) and §5.7 (WORKFLOW_CONTEXT) — unaffected. New angle: if real-time halt monitoring is wanted later, WF_INACTIVE provides the trigger but requires capture-at-halt-time to be useful. |

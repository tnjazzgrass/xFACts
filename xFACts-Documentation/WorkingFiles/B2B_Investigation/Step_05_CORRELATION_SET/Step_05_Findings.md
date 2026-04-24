# Step 5 Findings — CORRELATION_SET

**Date:** 2026-04-24
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_05_Correlation_Set/`
**Query file:** `Step_05_Query.sql`
**Results file:** `Step_05_Results.txt`

## Purpose

Step 1 identified `CORRELATION_SET` (47,550 live rows, 74,359 restore rows) as an unexplored table. IBM documentation describes it as Sterling's key-value tracking layer for EDI, file transfers, Connect:Direct events, and similar metadata. Step 5 determines what it actually contains at FAC, how it relates to workflows, and whether it provides monitoring-relevant data that our current collector misses.

---

## Summary of what changed

**`CORRELATION_SET` is a per-document event metadata store for SFTP and translation activity, scoped to a subset of FA_CLIENTS_MAIN runs** (plus small numbers of ENCOUNTER_LOAD and DM_ENOTICE workflows).

The table contains genuinely useful metadata that the current collector doesn't capture — SFTP transfer details (remote host, username, protocol, file size), translation outcomes (map version, status), and action types (Get, Translate). However, coverage is narrower than initial reading suggested:

- **Only 3 workflow families** produce correlation rows: `FA_CLIENTS_MAIN`, `FA_CLIENTS_ENCOUNTER_LOAD`, `FA_DM_ENOTICE`
- **Not even every MAIN run** produces correlations — approximately 14-20% of MAIN runs are instrumented (the ones doing actual file acquisition and translation work)
- **Retention matches WF_INST_S** (~7 days live) — does not extend workflow history
- **`TYPE` column is always 'DOCUMENT'** — dead dimension, no variety
- **`ARCHIVE_FLAG` is always -1** and `ARCHIVE_DATE` is always NULL — the archive model here differs from `ARCHIVE_INFO`'s flag semantics

**Value proposition:** CORRELATION_SET enriches the picture for a specific slice of workflows (file-ingestion/translation MAIN runs) with per-document transfer and map details. It's not the universal workflow-enrichment layer I initially thought it was.

---

## Structure

Identical schema across live (`CORRELATION_SET`) and archive (`CORREL_SET_RESTORE`) tables — 11 columns each.

| Column | Type | Purpose |
|---|---|---|
| `CORRELATION_ID` | nvarchar(510) | Unique ID of the correlation record. Sterling internal format: `FA-INT-APPP:node1:<timestamp>:<sequence>` |
| `NAME` | nvarchar(256) | The key in the key-value pair (e.g., `ACTION`, `Status`, `DocumentSize`) |
| `VALUE` | nvarchar(510) | The value for that key |
| `TYPE` | nvarchar(256) | Category — always `DOCUMENT` in current data |
| `OBJECT_ID` | nvarchar(510) | ID of the document/object this correlation describes |
| `ARCHIVE_FLAG` | int | Archive state flag — always -1 in current data |
| `ARCHIVE_DATE` | datetime | Archive schedule — always NULL in current data |
| `WF_ID` | numeric(9) | Workflow ID — **direct link to `WF_INST_S.WORKFLOW_ID`** |
| `REC_TIME` | datetime | When this correlation row was written |
| `KEY_ID` | int | Internal key-type identifier (correlates 1:1 with `NAME`) |
| `VALUE_UPPER` | nvarchar(510) | Pre-uppercased `VALUE` for case-insensitive lookups |

Schema parity between live and restore is notable — unlike `TRANS_DATA_RESTORE` which dropped `CREATION_DATE` and `CUM_SIZE`, correlation archives preserve full structure.

---

## NAME vocabulary — what Sterling captures

Only 12 distinct `NAME` values appear in all 48,787 rows. The vocabulary is tightly focused on SFTP file transfers and translation:

### File transfer metadata (the bulk of entries)

| NAME | Row count | Distinct workflows | Meaning |
|---|--:|--:|---|
| `ACTION` | 6,262 | 1,201 | What operation happened (e.g., `Get`, `Translate`) |
| `Direction` | 5,406 | 1,175 | `inbound` or `outbound` |
| `Username` | 5,394 | 1,175 | SFTP username used for transfer |
| `RemoteHostAddress` | 5,386 | 1,175 | Remote host IP |
| `RemoteHostName` | 5,386 | 1,175 | Remote host DNS name |
| `Protocol` | 4,853 | 1,175 | Transport protocol (`SFTP` observed) |
| `DocumentSize` | 4,640 | 1,137 | File size in bytes (zero-padded) |
| `TRACKINGID` | 4,857 | 1,179 | Sterling-generated tracking ID |
| `Status` | 4,883 | 1,205 | `SUCCESS` or failure indicator |

### Translation metadata

| NAME | Row count | Distinct workflows | Meaning |
|---|--:|--:|---|
| `Map` | 830 | 53 | Translation map name used |
| `MapVersion` | 860 | 83 | Version of the translation map |

### Event linkage

| NAME | Row count | Distinct workflows | Meaning |
|---|--:|--:|---|
| `PARENTID` | 30 | 30 | Link to a parent correlation event |

**Observations:**

1. **SFTP transfer metadata dominates.** 9 of the 12 NAME values are SFTP-transfer-related, together representing 93% of rows.
2. **Translation metadata covers only 83 workflows** (vs. 1,175+ for SFTP). Not every SFTP-ingesting workflow also translates — some just move files.
3. **PARENTID appears in only 30 rows.** Parent-child event linking is rare — most correlations are "leaf" events without parent references.
4. **No outbound push metadata observed.** The sample and vocabulary both suggest correlations are for inbound ingestion (GET/SFTP pull) and post-ingestion translation only. Outbound SFTP pushes don't appear to generate correlation rows.

---

## Workflow coverage — which workflow families produce correlations?

Results from query 5.7 (joined to `WFD` via `WF_INST_S + WF_INST_S_RESTORE`):

| Workflow name | WFD_ID | Distinct workflows | Correlation rows | Avg rows per workflow |
|---|--:|--:|--:|--:|
| **FA_CLIENTS_MAIN** | 798 | 1,158 | 47,872 | ~41 |
| **FA_CLIENTS_ENCOUNTER_LOAD** | 829 | 28 | 116 | ~4 |
| **FA_DM_ENOTICE** | 818 | 2 | 54 | ~27 |
| *(orphan - workflow purged)* | — | — | 745 | — |
| **Total** | | **1,188 distinct workflows** | **48,787** | |

**This is the key finding.** Correlation instrumentation is extremely narrow:

- **Only 3 FA_* workflow families produce correlation rows:** MAIN, ENCOUNTER_LOAD, DM_ENOTICE
- **Zero correlations from:** FA_CLIENTS_ARCHIVE, FA_CLIENTS_VITAL, FA_CLIENTS_EMAIL, FA_CLIENTS_GET_LIST, any FA_FROM_* dispatcher/wrapper, any FA_TO_* dispatcher/wrapper, any Schedule_* housekeeping, any Sterling infrastructure workflow (FileGatewayReroute, TimeoutEvent, etc.)
- **Even MAIN coverage is partial.** MAIN ran ~2,354 times in the 48-hour window per Step 3. CORRELATION_SET has rows for 1,158 distinct MAIN workflows across the 7-day window (extrapolating, ~8,200 MAIN runs in 7 days). That's roughly 14% of MAIN runs getting correlation rows.

**Hypothesis for why only some MAIN runs are instrumented:** Sterling's correlation-capture appears to be tied to specific service invocations within a MAIN execution. Workflows that actually perform SFTP pickups (via `FA_CLIENTS_GET_DOCS`) or run translations (`FA_CLIENTS_TRANS`) generate correlation rows. MAIN runs that short-circuit (prior phase failed), handle `FILE_DELETION` (no file retrieval), or hit empty-file conditions might not generate correlations at all.

This matches the sample data: every correlation group we saw was for `ACTION=Get` (SFTP pickup) or `ACTION=Translate`. No correlations for pure-flag-check or configuration-only MAIN executions.

---

## Archive model — CORRELATION_SET is different from ARCHIVE_INFO

Query 5.5 results:

| `ARCHIVE_FLAG` | Row count | Oldest `ARCHIVE_DATE` | Newest `ARCHIVE_DATE` |
|---:|--:|---|---|
| -1 | 48,787 | NULL | NULL |

**All rows have `ARCHIVE_FLAG = -1` with NULL `ARCHIVE_DATE`.**

This looks superficially like the `ARCHIVE_INFO` pattern where `-1` meant "archive complete, bookkeeping cleanup." But the semantics here are different:

- In `ARCHIVE_INFO`, `-1` marked rows whose workflows had already been fully purged
- In `CORRELATION_SET`, `-1` is the only flag value that exists, and 99.96% of rows are actively linked to workflows still in `WF_INST_S` or `WF_INST_S_RESTORE`

**Revised interpretation:** In `CORRELATION_SET`, `ARCHIVE_FLAG = -1` with `ARCHIVE_DATE = NULL` is the **normal state for live correlations**. The archive mechanism for `CORRELATION_SET` may not use the `ARCHIVE_FLAG`/`ARCHIVE_DATE` columns at all — instead, correlations may simply be moved to `CORREL_SET_RESTORE` (which has 74K rows per Step 1) when the corresponding workflow is archived, without ever transitioning the flag.

This is a different archive model than `ARCHIVE_INFO` and worth recording as a distinction.

---

## Retention — matches WF_INST_S, doesn't extend it

Query 5.6 results:

| Age bucket | Row count | Distinct workflows |
|---|--:|--:|
| Last 7 days | 48,783 | 1,204 |
| Last 180 days | 4 | 1 |

**Effectively 100% of live CORRELATION_SET data is from the last 7 days.** The 4 older rows are orphans from a workflow that was purged before its correlations cleared.

This overturns my initial hypothesis that CORRELATION_SET might provide extended history. Retention matches `WF_INST_S` — correlations live as long as their workflow and get archived together.

**Combined with `CORREL_SET_RESTORE` (74,359 rows per Step 1):** total correlation data horizon is ~30 days, same as workflow instances. No additional historical value.

---

## Orphan rate

Query 5.8 results:

| Workflow status | Correlation rows | Distinct workflows |
|---|--:|--:|
| LIVE_WF_INST_S | 48,042 | 1,188 |
| ORPHAN (neither live nor archived) | 745 | 17 |

**98.5% of correlation rows link to workflows still in the system.** Only 17 workflows worth of correlations (~2% of rows) are orphaned from purged workflows.

This is much better than `WF_INACTIVE`'s 99.94% orphan rate. CORRELATION_SET is a **well-maintained, live data source** — rows track their workflows closely.

---

## Sample row interpretation

For reference, the 20 sample rows broke into three workflow groups:

**Group 1 — WF_ID 7281522** (2026-01-14, orphaned from purged workflow, likely from 4.1 orphan analysis in Step 2):
- `ACTION = Translate`
- `MapVersion = 7`
- `Status = SUCCESS`
- `PARENTID = <another correlation_id>`

A translation event. The parent-child link (`PARENTID`) suggests this translation was a sub-event of another correlation.

**Group 2 — WF_ID 8010766** (2026-04-21, active workflow, most common pattern):
- `TRACKINGID`, `Status = SUCCESS`, `ACTION = Get`
- `Direction = inbound`, `Protocol = SFTP`
- `RemoteHostAddress = 10.1.20.20`, `RemoteHostName = 10.1.20.20`
- `Username = dataproc`
- `DocumentSize = 000005595804` (5.6 MB)

Classic SFTP inbound pickup. File came from internal host `10.1.20.20` as user `dataproc`, 5.6 MB. Transfer completed successfully.

**Group 3 — WF_ID 8014000** (2026-04-22, active workflow):
- Same pattern as Group 2 — another SFTP inbound Get from the same host

The data tells a consistent story: each correlation row is one attribute of one event, and events cluster by workflow.

---

## Implications for the collector

**Observations only. No implementation decisions at this stage.**

1. **CORRELATION_SET provides genuine value for instrumented workflows.** For MAIN runs that do actual SFTP pickup or translation, we can capture rich per-transfer details (source host, username, file size, translation map version) — data the current collector doesn't have. This would enrich SI_ExecutionTracking meaningfully for file-ingestion workflows.

2. **Coverage is narrower than we'd want for full monitoring.** Most of Sterling's workflow families produce zero correlation rows. If we design a collector around correlation data as the authoritative source, we'd cover maybe 15% of total Sterling activity — less than the current MAIN-only approach.

3. **The natural role for CORRELATION_SET is enrichment, not primary signal.** Think of it as adding columns to existing MAIN tracking rows, not replacing any tracking source. For workflows where correlations exist, pull the file-transfer and translation metadata and attach it to the existing execution tracking row. For workflows without correlations, carry on as normal.

4. **Collection cost is modest.** 48K live rows = ~500 rows per MAIN workflow on average when grouped (~41 per instrumented MAIN). A collector pass that joins by `WF_ID` and pivots the key-value rows into attributes would produce clean per-workflow enrichment data.

5. **The SFTP transfer details are particularly valuable for compliance/audit.** Knowing which user and host transferred which file at what size is exactly the kind of detail that gets requested during audits. Currently this data is effectively invisible to anyone without direct DB access.

6. **Translation map version tracking is useful for debugging.** If a translation starts failing, knowing which map version was in use (vs. the latest WFD version) can pinpoint a recent config change as the cause.

7. **`TRACKINGID` is worth investigating further.** Each row has a `TRACKINGID` value that appears to be another Sterling-generated ID. This may link to FAC's internal document tracking systems. Noting but not chasing right now.

---

## Resolved questions (originally open)

1. ✅ **What's in CORRELATION_SET?** Per-document SFTP transfer and translation metadata, key-value format, 12 NAME values.
2. ✅ **How does it link to workflows?** `WF_ID` column maps directly to `WF_INST_S.WORKFLOW_ID`.
3. ✅ **Is the grain per-workflow, per-file, per-transaction, per-step?** Per-document-event. One row per (workflow, document, attribute) combination.
4. ✅ **Which workflows produce correlation rows?** FA_CLIENTS_MAIN (primary), FA_CLIENTS_ENCOUNTER_LOAD and FA_DM_ENOTICE (minor). Only workflows doing DOCUMENT-level operations.
5. ✅ **Does it extend our historical horizon?** No — retention matches WF_INST_S at ~30 days combined live + restore.
6. ✅ **Is the `ARCHIVE_FLAG` pattern the same as ARCHIVE_INFO?** No. In CORRELATION_SET, all live rows have `ARCHIVE_FLAG = -1` with `ARCHIVE_DATE = NULL` as the normal state.

---

## New questions raised (low priority for now)

1. **Why doesn't FA_CLIENTS_ARCHIVE produce correlations?** The sub-workflow runs 3,881 times in 48 hours, mostly doing SFTP-related archive moves, but has zero correlation rows. Possibly because archive operations don't go through Sterling's standard DOCUMENT service.
2. **Do outbound pushes (ACTION=Put) ever appear in this table?** The vocabulary and sample only show `Get` actions. Might need broader sampling to confirm, but our top-20 sample suggests inbound-only instrumentation.
3. **What is `TRACKINGID` used for?** Multiple rows per workflow share it — it may be a per-document grouping ID within a multi-document MAIN run.

---

## Document status

| Attribute | Value |
|---|---|
| Step | 05 — CORRELATION_SET |
| Status | **Complete** |
| Next | Step 6 — Roadmap refresh (consolidate Steps 1-5 into updated investigation state) |
| Roadmap impact | §5.4 (Sub-workflow families) — CORRELATION_SET identified as enrichment source for MAIN-family workflows. §5.7 (WORKFLOW_CONTEXT as real-time source) — CORRELATION_SET is a parallel real-time signal source worth noting. New concept: **enrichment tables** (tables that don't define workflow existence but add metadata to existing tracking). |

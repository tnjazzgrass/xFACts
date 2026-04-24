# Step 3 Findings — Workflow Definition Catalog + Active Inventory

**Date:** 2026-04-24
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_03_Workflow_Universe/`
**Query file:** `Step_03_Query.sql` (original + corrections)
**Results file:** `Step_03_Results.txt` (original + corrections)

## Purpose

With retention understood from Step 2, Step 3 catalogs the full workflow definition space in b2bi and cross-references it against actual 48-hour instance activity. Goal: answer *"what workflows exist in Sterling and what's actively running?"* This is the foundation for identifying what the current collector is missing.

---

## Summary of what changed

**The workflow universe is much larger than previously understood:**

- **1,433 distinct workflow definitions** exist in b2bi (not 200+ or 2,467 — see correction note)
- **332 distinct workflows are active** in any given 48-hour period
- **Four velocity tiers** are observable in the workflow activity pattern
- **MAIN is 16% of total workflow volume;** ARCHIVE and VITAL each run *more* often than MAIN

**Our current collector captures FA_CLIENTS_MAIN only, which represents roughly 16% of total Sterling workflow activity** (confirming but slightly raising the Step 2 estimate of 13%). The top three high-volume workflows (ARCHIVE, VITAL, MAIN) together account for 69% of all Sterling activity, and two of those three are currently invisible to us except as presence flags on MAIN rows.

---

## Methodology note — WFD versioning quirk (important)

**Step 3's initial queries contained a join bug** that inflated all instance counts by the number of WFD versions per workflow. Root cause: WFD's primary key is `(WFD_ID, WFD_VERSION)`. Every workflow edit creates a new WFD row with the same `WFD_ID` but incremented `WFD_VERSION`. Joining `WF_INST_S.WFD_ID` to `WFD.WFD_ID` alone produces a cartesian product across all versions of that workflow. For MAIN, which has ~70 versions in WFD, every MAIN instance was counted 70 times.

**Corrections:**
- 3.3C counts distinct NAME (eliminates version multiplication)
- 3.4C and 3.5C use a CTE that returns one row per WFD_ID (any version's name works since all versions share the same name)
- 3.6's original result used `DISTINCT WFD_ID` in its CTE so the numerator was correct, but the "total" denominator (2,467) is WFD rows including all version history

**Implication for any future collector code:** Always match on `(WFD_ID, WFD_VERSION)` when pulling workflow metadata for a specific instance; or use the "one-row-per-WFD_ID" CTE pattern when only the name is needed.

---

## The workflow definition catalog

### Total distinct workflows by family

| Family | Distinct workflows | % of total |
|---|--:|--:|
| **OTHER** | 737 | 51.4% |
| **FA_\*** | 643 | 44.9% |
| Schedule_* | 24 | 1.7% |
| EDIINT/AS2/AS3 | 15 | 1.0% |
| Mailbox | 12 | 0.8% |
| Housekeeping | 2 | 0.1% |
| **Total** | **1,433** | **100%** |

### The "OTHER" family

737 workflow definitions don't match our naming patterns. Only 11 of these are actually active in the 48-hour window, so the vast majority (~726) are dormant. The active ones observed:

- `FileGatewayListeningProducer` and `FileGatewayReroute` — Sterling's File Gateway infrastructure workflows (high volume, 574 each)
- `TimeoutEvent`, `Alert`, `AlertNotification`, `EmailOnError` — Sterling infrastructure
- `Recover.bpml` — Sterling crash recovery workflow
- `AFTPurgeArchiveMailboxes` — Adaptive File Transfer housekeeping
- `CheckExpireCertsEmailNotif`, `CheckActiveSessionService` — Sterling health check workflows
- `FILE_REMOVE_VANDERBILT_NEWLIGHT` — a custom one-off (not following FA_ prefix convention)

**The other 726 dormant "OTHER" workflows** are likely a mix of: Sterling product workflows for unused features (AS2/AS3/EDIINT inbound/outbound trading partner scenarios), historical/deprecated wrappers, template workflows installed by Sterling, and test/dev workflows left in production. These don't need systematic investigation; if they're dormant, they're not part of operational concern.

---

## Active workflow distribution (48-hour window)

### By family

| Family | Active instances | Distinct workflow names active | Avg instances per name |
|---|--:|--:|--:|
| FA_* | 11,822 | 304 | 39 |
| OTHER | 1,525 | 11 | 139 |
| Schedule_* | 1,314 | 17 | 77 |
| **Total** | **14,661** | **332** | **44** |

14,661 instances over 48 hours ≈ 7,330/day. **This matches the ~6-8K/day observed in Step 2**, confirming the corrected counts are right.

Note: EDIINT/AS2/AS3 (15 defined), Mailbox (12), Housekeeping (2) had zero activity in the 48-hour window.

### Top 25 workflows by volume

From query 3.4C:

| Workflow | WFD_ID | Instances (48h) | Tier |
|---|--:|--:|---|
| **FA_CLIENTS_ARCHIVE** | 795 | **3,881** | Sub-workflow |
| **FA_CLIENTS_VITAL** | 800 | **3,844** | Sub-workflow |
| **FA_CLIENTS_MAIN** | 798 | **2,354** | Pipeline orchestrator ← *currently captured* |
| FileGatewayListeningProducer | 789 | 574 | Sterling infrastructure |
| FileGatewayReroute | 791 | 574 | Sterling infrastructure |
| Schedule_AssociateBPsToDocs | 3 | 287 | Housekeeping |
| Schedule_IndexBusinessProcessService | 11 | 287 | Housekeeping |
| FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC_ARC | 1352 | 274 | Pattern 3 dispatcher |
| FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC | 1321 | 261 | Pattern 3 dispatcher |
| **FA_CLIENTS_EMAIL** | 794 | 234 | Sub-workflow |
| TimeoutEvent | 18 | 191 | Sterling infrastructure |
| Schedule_BPExpirator | 6 | 191 | Housekeeping |
| Schedule_PurgeService | 8 | 144 | Housekeeping |
| Schedule_MessagePurge | 330 | 96 | Housekeeping |
| Schedule_DocumentStatsArchive | 332 | 96 | Housekeeping |
| Schedule_Scheduled_AlertService | 680 | 96 | Housekeeping |
| Alert | 682 | 96 | Sterling infrastructure |
| Schedule_BPRecovery | 5 | 63 | Housekeeping |
| Recover.bpml | 12 | 63 | Sterling infrastructure |
| FA_CLIENTS_JIRA_TICKETS | 821 | 47 | Integration utility |
| FA_FROM_REVSPRING_SIMPLE_EMAIL | 1403 | 38 | Client-specific puller |
| FA_TO_LIVEVOX_IVR_CNSMR_LIST_OB_BD_S2D_NT | 1420 | 34 | Client-specific pusher |
| FA_CLIENTS_GET_LIST | 797 | 33 | Pattern 2 dispatcher |
| **FA_CLIENTS_ENCOUNTER_LOAD** | 829 | 30 | Sub-workflow |
| FA_FROM_REVSPRING_IB_BD_PULL | 1289 | 28 | Client-specific puller |

**Bold rows** are FA_CLIENTS_* sub-workflows. Three (ARCHIVE, VITAL, EMAIL) are known from the existing Roadmap but not tracked as standalone workflows. ENCOUNTER_LOAD is tracked only via presence flag.

### Volume share

- **FA_CLIENTS_MAIN** (the only workflow currently captured by `SI_ExecutionTracking`): **16.1%** of total Sterling activity
- **FA_CLIENTS_ARCHIVE**: **26.5%** (largest single contributor, runs ~1.65x per MAIN due to pre/post/post2 invocations)
- **FA_CLIENTS_VITAL**: **26.2%** (runs ~1.63x per MAIN due to per-file + optional post-loop invocations)
- **Top 3 combined**: **68.7%** of all Sterling workflow activity

---

## Velocity tiers in the workflow universe

Different workflow types operate at radically different volumes. This categorization matters for monitoring strategy:

### Tier 1 — Pipeline sub-workflows (thousands per day)

`FA_CLIENTS_ARCHIVE`, `FA_CLIENTS_VITAL`, `FA_CLIENTS_MAIN` each run 1,000+ times per day. Combined ~69% of total volume. These are high-frequency components of the file-processing pipeline. Each MAIN invocation generates 1-3 ARCHIVE and 0-N VITAL sub-workflow executions.

### Tier 2 — Sterling infrastructure + dispatchers (hundreds per day)

`FileGatewayListeningProducer`, `FileGatewayReroute`, `TimeoutEvent`, the `Schedule_*` housekeeping services, Pattern 3 FTP file-list dispatchers, `FA_CLIENTS_EMAIL`, and `Alert`/`AlertNotification`. Most fire on 5-15 minute intervals.

### Tier 3 — Named scheduled pullers/pushers (10-50 per day)

Client-specific wrapper workflows like `FA_FROM_REVSPRING_IB_BD_PULL`, `FA_FROM_WOMANS_HOSPITAL_EPIC_IB_BD_PULL`, `FA_TO_LIVEVOX_IVR_CNSMR_LIST_OB_BD_S2D_NT`. Fire every 1-3 hours. Also includes `FA_CLIENTS_GET_LIST` (the hourly scheduled dispatcher, 33 observed = ~16.5/day, exceeds the 11 schedule fires/business day noted in the Roadmap because some inline invocations from Pattern 4 wrappers also count).

### Tier 4 — Daily workflows (1-2 per day)

The vast majority of named `FA_FROM_*` and `FA_TO_*` workflows fire exactly twice in the 48-hour window (once per business day). These represent specific per-client daily file processes: outbound remittance, daily dialer lists, batch pushes, etc. Many client-specific wrappers in this tier. Each is operationally important as an individual business process — failure of any one affects a specific client-directional flow.

### Velocity implications for monitoring design

- **Tier 1** (sub-workflows): likely too high-volume to track every instance individually; monitor aggregate health + failures. May not need per-instance tracking rows, or may need compact summary rows.
- **Tier 2** (infrastructure): primarily presence/heartbeat monitoring — "is Sterling still doing housekeeping?"
- **Tier 3** (pullers/pushers): standard per-instance tracking — similar to what SI_ExecutionTracking does for MAIN
- **Tier 4** (daily workflows): **highest-value** per-instance tracking. These are named business processes that operations genuinely care about. "Did the Acadia outbound notice file get pushed today?" is a Tier 4 question.

---

## WFD table structure

From query 3.1:

| Column | Type | Notes |
|---|---|---|
| WFD_ID | int | Part of PK |
| WFD_VERSION | int | Part of PK; increments on every edit |
| NAME | nvarchar(510) | Workflow definition name |
| DESCRIPTION | nvarchar(510) | |
| EDITED_BY | nvarchar(72) | Who modified this version |
| STATUS | int | Presumed active/disabled indicator |
| TYPE | int | Workflow type code |
| MOD_DATE | datetime | When this version was created |
| LIFE_SPAN | numeric(9) | Data retention hint |
| REMOVAL_METHOD | int | Per IBM docs: controls how data is removed (archive vs. purge) |
| PERSISTENCE_LEVEL | int | Controls what step data is retained |
| ENCODING | nvarchar(48) | |
| RECOVERY_LEVEL | int | |
| SOFTSTOP_RECOVER | int | |
| ONFAULT | nvarchar(20) | Handler configuration |
| PRIORITY | int | Queue priority |
| DOCTRACKING | nvarchar(20) | Document tracking level |
| WFDOPTIONS | int | Bitfield of options |
| DEADLINE_INTVL | int | |
| FIRST_NOTE, SECOND_NOTE | int | |
| EVENT_LEVEL | int | Event subscription level |
| EXECNODE | nvarchar(64) | Execution node (cluster) |
| CATEGORY | nvarchar(128) | Categorization — mostly NULL in sample |
| ORGANIZATION_KEY | nvarchar(510) | Per-org scoping |
| EXPEDITE | nvarchar(20) | |

**Meaningful columns for our purposes:** `WFD_ID`, `WFD_VERSION`, `NAME`, `STATUS`, `TYPE`, `MOD_DATE`, `PERSISTENCE_LEVEL`, `ONFAULT`, `DOCTRACKING`. The rest are Sterling internals we likely won't need.

**Unexplored but potentially useful:** `STATUS` codes and `TYPE` codes. Mapping these to values would let us filter "active definitions" vs "disabled definitions" directly rather than inferring from runtime activity.

---

## Active vs. dormant distribution

Corrected interpretation of query 3.6 (original result was at the WFD-row level, not distinct workflow level):

Approximately **23% of distinct workflow definitions are active** in any 48-hour window:

- **332 of 1,433** distinct workflow names ran at least once in the last 48 hours
- **1,101 of 1,433** distinct workflow names were dormant (no activity)

The dormant majority includes:
- All 12 Mailbox-family workflows (unused feature)
- All 15 EDIINT/AS2/AS3 workflows (unused — FAC doesn't trade EDI)
- 726 "OTHER" family workflows (Sterling templates, deprecated flows, etc.)
- ~339 FA_* workflows (legacy/seasonal flows, disabled clients, etc.)

For investigation purposes, **the 332 active workflows are the population that matters**. The 1,101 dormant ones can be set aside.

---

## FA_* sub-family patterns observed

Scanning the FA_* active workflows reveals several sub-prefix patterns worth recognizing:

| Pattern | Role | Examples |
|---|---|---|
| `FA_CLIENTS_*` | Pipeline sub-workflow family | MAIN, ARCHIVE, VITAL, EMAIL, ENCOUNTER_LOAD, GET_LIST |
| `FA_FROM_*` | Inbound client wrappers/pullers | FA_FROM_ACADIA_HEALTHCARE_IB_EO, FA_FROM_REVSPRING_IB_BD_PULL |
| `FA_TO_*` | Outbound client wrappers/pushers | FA_TO_LIVEVOX_IVR_CNSMR_LIST_OB_BD_S2D_NT, FA_TO_CCI_LEGAL_OB_BD_S2D_NT |
| `FA_DM_*` | DM integration flows | FA_DM_ENOTICE, FA_DM_ENOTICE_ARCHIVE, FA_DM_ITS_REQST |
| `FA_B2B_*` | Internal B2B operations | FA_B2B_CLIENTS_PLACEMENT_EMAILS_OB_BDEO_S2S_RPT |
| `FA_INTEGRATION_*` | Integration team internal | FA_INTEGRATION_TOOLS_API_FAILURES_EMAIL |
| `FA_CUSTOM_*` | Custom integrations | FA_CUSTOM_INT_CONSUMER_ACCOUNTS_MERGE_CLA |
| `FA_HSS_*`, `FA_AMSURG_*`, etc. | Client-specific flows not using FROM/TO prefix | FA_HSS_PB_IB_EO, FA_AMSURG_MHS_IB_BD_NB |
| `FILE_REMOVE_*` | Custom cleanup (non-standard naming) | FILE_REMOVE_VANDERBILT_NEWLIGHT |

Within `FA_FROM_*` and `FA_TO_*`, there's a rich suffix convention:
- `_PULL` = active SFTP pull
- `_PUSH` = active SFTP push  
- `_S2D` = Sterling-to-destination transfer
- `_D2S` = destination-to-Sterling
- `_IB` = inbound
- `_OB` = outbound
- `_BD` = bad debt
- `_EO` = early-out
- `_NB` = new business
- `_NT` = notes
- `_RT` = returns
- `_RM` = remit
- `_SP` = special process
- `_TR` = translation-only
- `_RC` = recon
- `_FD` = file deletion

These suffixes encode business type and directional flow. The existing ArchitectureOverview mentioned some of these but didn't catalog them comprehensively. For future monitoring classification work, this convention is the natural axis.

---

## Implications for the collector

**Observations only. No implementation decisions at this stage.**

1. **The "MAIN is the universal grain" claim from the archived ArchitectureOverview is definitively wrong.** MAIN is 16% of activity; the other 84% runs through workflows MAIN doesn't touch. Two of the three highest-volume workflows are MAIN's sub-workflows, which the existing design treats as bit flags — but those sub-workflows have their own failure modes, retention, and operational meaning.

2. **A comprehensive collector should target at minimum the 332 active workflows**, not just the 1 currently captured. Most of the 332 are Tier 3 or Tier 4, which is manageable volume (tens to hundreds of instances per day each).

3. **Tier 1 sub-workflows (ARCHIVE, VITAL) need a different approach than Tier 3/4.** At 3,800 instances in 48 hours each, individual row-per-instance tracking may be excessive. But we can't ignore them — they contain the failure signals we currently miss (9 of 13 failures in the Roadmap's prior observation window were in these sub-workflows).

4. **Dispatchers (Pattern 1/2/3/4) are first-class citizens.** `FA_CLIENTS_GET_LIST` runs 33 times in 48 hours; `FA_FROM_CLIENTS_FTP_FILES_LIST_IB_D2S_RC` runs 261 times. These currently aren't captured, but a "did scheduled work fire?" signal needs them.

5. **Sterling's own housekeeping workflows** (`Schedule_PurgeService`, `Schedule_BPExpirator`, `Schedule_AssociateBPsToDocs`) running at expected intervals is a "Sterling is healthy" signal. Breaks in these heartbeats would indicate Sterling itself has problems.

6. **Most of the workflow universe (1,101 of 1,433 definitions) is dormant noise.** Filtering to the 332 active workflows makes the problem dramatically smaller than the raw WFD count suggests.

---

## Open questions raised by Step 3

1. **What do `STATUS` and `TYPE` values in WFD mean?** If Sterling has a definitive "enabled/disabled" flag, we can filter definitions without relying on runtime observation.

2. **Which workflows have `ONFAULT` handlers?** Workflows without fault handlers have different failure-propagation behavior. This may affect how we infer failure cause.

3. **What does `PERSISTENCE_LEVEL` mean?** Per SterlingSync blog, persistence levels affect what step data is retained. Could explain why some workflows have dense WORKFLOW_CONTEXT history and others don't.

4. **How are the 332 active workflows distributed across clients?** FA_FROM_* and FA_TO_* contain client names in the workflow name itself. We should be able to enumerate the client population from the FA_* inventory.

5. **How does the workflow family taxonomy map to "process type"?** The existing Roadmap / ArchitectureOverview lists 31 PROCESS_TYPE × COMM_METHOD combinations. Process type is a runtime ProcessData field; workflow family is a name pattern. These are orthogonal axes and both matter.

6. **What's in `WF_INACTIVE`?** (1,746 rows as of Step 1.) This is the next investigation target for Step 4.

7. **What's in `CORRELATION_SET`?** (47,550 live + 74,359 restore as of Step 1.) Sterling's own tracking layer, unexplored.

---

## Document status

| Attribute | Value |
|---|---|
| Step | 03 — Workflow Definition Catalog + Active Inventory |
| Status | **Complete** (after corrections) |
| Next | Step 4 — `WF_INACTIVE` + `CORRELATION_SET` |
| Roadmap impact | §5.1 (Workflow Universe) substantially revised — 1,433 total, 332 active; velocity tiers now characterized. §5.4 (Sub-workflow families) — ARCHIVE and VITAL confirmed as higher-volume than MAIN; investigation priority. §5.5 (Dispatchers) — Pattern 2/3/4 dispatchers identified in the active inventory. |

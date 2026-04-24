# Step 6A Findings — Active Workflow Catalog

**Date:** 2026-04-24
**Investigation folder:** `xFACts-Documentation/WorkingFiles/B2B_Investigation/Step_06_MAIN_Anatomy/Step_06A_Active_Workflow_Catalog/`
**Query file:** `Step_06A_Query.sql`
**Results file:** `Step_06A_Results.txt`

## Purpose

Produce a complete catalog of every workflow definition (WFD) in b2bi, classified by family, suffix, and direction, with 48h / 7d / 30d instance counts across `WF_INST_S` (live) and `WF_INST_S_RESTORE`. This catalog is the "universe" for BPML extraction in Step 6B and anchors every downstream investigation.

Scope decision: **capture everything** — including dormant workflows, Sterling-native infrastructure, and anything else defined in the system. The investigation's charter is to understand everything Sterling runs, not just FAC-owned workflows.

---

## Summary of what changed

**Step 3 saw 332 active workflows in a 48-hour window; Step 6A sees 413 active in 30 days.** The difference (~80 more workflows) is workflows that fire weekly or less frequently. Step 3 undercounted active workflows because its window was too narrow. **The 30-day window is the correct lens for investigation scope** — anything firing at least monthly matters to the collector.

**Step 3 stated 1,433 distinct WFDs. Step 6A confirms 1,433** (rounding: 1,433 rows after dedup on WFD_ID). The Step 3 count is unchanged and solid.

**The critical volume story is even more concentrated than Step 3 suggested.** Using the 30-day window:

- **FA_CLIENTS_VITAL: 10,179 instances (26.6%)**
- **FA_CLIENTS_ARCHIVE: 10,167 instances (26.6%)**
- **FA_CLIENTS_MAIN: 6,153 instances (16.1%)**
- **Top 3 = 69.3% of all Sterling activity** over the 30-day window

This matches Step 3's finding at a longer horizon: ARCHIVE and VITAL each run *more* than MAIN, and the three together are the overwhelming majority of what Sterling does.

---

## Catalog composition

### By family (FA_* subfamilies granular)

| Family | Active (30d) | Dormant | Total |
|---|--:|--:|--:|
| **FA_TO** | 228 | 193 | 421 |
| **FA_FROM** | 104 | 31 | 135 |
| **FA_OTHER** (FA_* without sub-prefix) | 31 | 18 | 49 |
| **Schedule** | 17 | 7 | 24 |
| **FA_CLIENTS** | 11 | 17 | 28 |
| **Sterling_Infra** | 7 | 0 | 7 |
| **FA_DM** | 5 | 1 | 6 |
| **OTHER** (non-FA, non-Sterling-known) | 3 | 711 | 714 |
| **FileGateway** | 2 | 12 | 14 |
| **FA_INTEGRATION** | 1 | 0 | 1 |
| **FA_B2B** | 1 | 0 | 1 |
| **AFT** | 1 | 11 | 12 |
| **FA_CUSTOM** | 1 | 1 | 2 |
| **FILE_REMOVE** | 1 | 0 | 1 |
| **AS3** | 0 | 4 | 4 |
| **EDIINT** | 0 | 2 | 2 |
| **Mailbox** | 0 | 12 | 12 |
| **TOTAL** | **413** | **1,020** | **1,433** |

**Observations:**

1. **FA_TO is the largest family by count** (421 defined) but only 228 are active in 30d. FA_TO workflows tend to be Tier 4 (daily/weekly) client-specific pushers — so many definitions, low per-workflow volume. Matches Step 3.

2. **The "OTHER" bucket contains 714 dormant workflows** — almost entirely Sterling product-feature workflows for capabilities FAC doesn't use (mostly empty FG_*, AS2/AS3, Mailbox, EDIINT templates). Only 3 are active: `RestoreService` (3 runs), `GG_TEST_BP` (2 runs, "testing"), `SSHKeyGrabberProcess` (1 run, failed). The dormant OTHER population is noise for investigation purposes but worth knowing exists.

3. **FA_CLIENTS has only 11 active workflows** — the shared pipeline/sub-workflow family. Dormant FA_CLIENTS workflows (17) include ones the ArchitectureOverview references as invoked by MAIN: `FA_CLIENTS_ACCOUNTS_LOAD`, `FA_CLIENTS_GET_DOCS`, `FA_CLIENTS_PREP_SOURCE`, `FA_CLIENTS_TRANS`, `FA_CLIENTS_FILE_MERGE`, `FA_CLIENTS_ADDRESS_CHECK`, `FA_CLIENTS_DUP_CHECK`, `FA_CLIENTS_WORKERS_COMP`, `FA_CLIENTS_COMM_CALL`, `FA_CLIENTS_PREP_COMM_CALL`, `FA_CLIENTS_POST_TRANSLATION`, `FA_CLIENTS_TRANSLATION_STAGING`, `FA_CLIENTS_ETL_CALL` (deprecated), and others. **This is important:** these workflows being dormant at the top-level WF_INST_S layer means they run *inline* inside MAIN rather than as separate tracked workflows. Step 6C will verify this from the BPML.

4. **Schedule_* family has 17 active.** These are Sterling's native housekeeping workflows (BPExpirator, PurgeService, IndexBusinessProcessService, etc.). They run on Sterling's own schedules, not FAC's. They're potentially a "Sterling is healthy" heartbeat signal.

5. **Sterling_Infra: 7 active.** TimeoutEvent, Alert, Recover.bpml, AlertNotification, EmailOnError, CheckExpireCertsEmailNotif, CheckActiveSessionService. Sterling product infrastructure.

6. **No active AS2/AS3/EDIINT/Mailbox workflows.** Confirms "FAC uses pure BP-execution mode" from Step 1.

### Active FA_CLIENTS workflows (11)

These are the only FA_CLIENTS definitions that appear as top-level `WF_INST_S` rows. Anything else in the family executes inline inside MAIN (or in an `InvokeBusinessProcessService` call that appears as a child, depending on INVOKE_MODE — unverified).

| NAME | WFD_ID | Latest Ver | 30d | ST=1 | Fail Rate |
|---|---|---|--:|--:|--:|
| FA_CLIENTS_VITAL | 800 | 9 | 10,179 | 14 | 0.1% |
| FA_CLIENTS_ARCHIVE | 795 | 12 | 10,167 | 0 | 0% |
| FA_CLIENTS_MAIN | 798 | 48 | 6,153 | 31 | 0.5% |
| FA_CLIENTS_EMAIL | 794 | 24 | 620 | 1 | 0.2% |
| FA_CLIENTS_JIRA_TICKETS | 821 | 4 | 120 | 0 | 0% |
| FA_CLIENTS_GET_LIST | 797 | 19 | 85 | 0 | 0% |
| FA_CLIENTS_ENCOUNTER_LOAD | 829 | 2 | 82 | 5 | 6.1% |
| FA_CLIENTS_CNSMR_ACCNT_AR_IB_BDEO_S2X_BDL | 1171 | 1 | 5 | 0 | 0% |
| FA_CLIENTS_CNSMR_TAG_IB_BDEO_S2X_BDL | 1170 | 1 | 5 | 0 | 0% |
| FA_CLIENTS_GROUP_KEYS_SP | 1034 | 2 | 5 | 0 | 0% |
| FA_CLIENTS_INVALID_ACCOUNTS_OB_EOBD_D2S_RPT | 1499 | 1 | 5 | 0 | 0% |

**Observations:**

- `FA_CLIENTS_ENCOUNTER_LOAD` has a notable 6.1% failure rate in 30d (5 of 82) — highest among FA_CLIENTS workflows.
- `FA_CLIENTS_JIRA_TICKETS` runs 120 times in 30d — a significant workflow not mentioned in the legacy ArchitectureOverview. Worth checking what it does.
- `FA_CLIENTS_GET_LIST` ran 85 times in 30d. For a workflow the ArchitectureOverview says runs 11x per business day (5:05am-3:05pm M-F every hour = 11 fires/day), 85/30 = 2.8/day average. Business-day 11 fires × ~22 business days = 242 expected; observed 85 is much lower. Either:
  - The schedule doesn't fire as described (ArchitectureOverview claim to verify)
  - Many GET_LIST invocations are inline (Pattern 4 wrappers use `InlineInvokeBusinessProcessService`) and therefore don't produce `WF_INST_S` rows
  - Both

  The ArchitectureOverview says Pattern 4 uses inline invocation. That would explain the discrepancy — Pattern 2 scheduler fires produce standalone GET_LIST rows; Pattern 4 wrapper-embedded GET_LIST does not. Needs verification against BPMLs in Step 6C.
- `FA_CLIENTS_MAIN` latest version = 48. The ArchitectureOverview claimed to have read MAIN v48 end-to-end. That claim is consistent with current state.

### Active FA_DM workflows (5)

| NAME | WFD_ID | 30d |
|---|---|--:|
| FA_DM_ENOTICE | 818 | 45 |
| FA_DM_ACCOUNTS_RETURN_IB_BDEO_S2X_BDL | 1456 | 10 |
| FA_DM_ENOTICE_ARCHIVE | 823 | 5 |
| FA_DM_INCEPTION_HOLD_TAG | 815 | 5 |
| FA_DM_ITS_REQST | 811 | 5 |

DM integration flows — Step 5 found `FA_DM_ENOTICE` was one of three workflow families producing CORRELATION_SET rows (alongside MAIN and ENCOUNTER_LOAD).

### Active Sterling_Infra workflows (7)

| NAME | WFD_ID | 30d |
|---|---|--:|
| TimeoutEvent | 18 | 481 |
| Alert | 682 | 241 |
| Recover.bpml | 12 | 160 |
| AlertNotification | 683 | 81 |
| EmailOnError | 685 | 36 |
| CheckExpireCertsEmailNotif | 32 | 5 |
| CheckActiveSessionService | 773 | 3 |

Sterling's product infrastructure workflows. They fire at Sterling-determined cadence and are a "Sterling is running" heartbeat.

### Suffix codes observed for FA_FROM / FA_TO (active only)

FA_FROM common suffixes: PULL (62), RC (10), FD (4), BDL (3), NT (3), SP (3), TR (3)
FA_TO common suffixes: RM (46), NT (39), RT (37), RPT (22), RTNT (21), BD (20), NTRT (6), SP (6)

Other observed suffixes (frequencies 1-3): ARC, D2S, EO, EOBD, EMAIL, MDOS, NB, PY, RESP, FILES, RTRM, SBDL, SE, TR, PUSH, S2D, DIALER, FILE, DEC, DETAIL, INV, ITS

**The suffix extraction is partially working but not robustly.** Many workflows have multi-suffix names (e.g., `FA_TO_LIVEVOX_IVR_CNSMR_LIST_OB_BD_S2D_NT` → extracted suffix is just `NT`, missing the `OB_BD_S2D` context). The legacy Step 3 findings described a richer suffix vocabulary than my pattern captured. **The single-trailing-token approach is insufficient.** Suffix classification will need a more sophisticated parser when we do BPML analysis in 6B-6C. For 6A, the simple extraction is noted as a starting point; we'll refine.

---

## WFD metadata — active population

### WFD.STATUS

| Value | Count |
|---:|--:|
| 1 | 410 |
| 2 | 3 |

410 of 413 active workflows have `wfd_status = 1`. The three with `wfd_status = 2` may represent a different definition state (disabled? archived? draft?) — worth investigating.

### WFD.TYPE

| Value | Count |
|---:|--:|
| 1 | 393 |
| 101 | 16 |
| 102, 103, 104 | 1 each |
| 204 | 1 |

The `TYPE` column has variation. 393 type-1 workflows dominate; 16 are type-101; handful of 102/103/104/204. **TYPE semantics are unknown.** To be investigated in Step 6C or via BPML reading.

### WFD.PERSISTENCE_LEVEL

| Value | Count |
|---:|--:|
| 0 | 396 |
| 3 | 17 |

Two distinct persistence levels in active use. **PERSISTENCE_LEVEL semantics are unknown** but IBM docs describe this field controlling step-data retention granularity.

### WFD.RECOVERY_LEVEL

| Value | Count |
|---:|--:|
| 3 | 412 |
| 4 | 1 |

Nearly universal `RECOVERY_LEVEL = 3`.

### WFD.ONFAULT

| Value | Count |
|---:|--:|
| 'false' | 412 |
| 'TRUE' | 1 |

Nearly universal `ONFAULT = 'false'` with one outlier. **Likely represents a default "no explicit fault handler at BPML metadata level"** — but BPML-level onFault handlers are definitely in use (ArchitectureOverview describes MAIN's and GET_LIST's onFault handlers). So this field may indicate a *different* level of fault configuration than the BPML `<onFault>` block. To be investigated in Step 6C.

### WFD.DOCTRACKING

| Value | Count |
|---:|--:|
| 'false' | 412 |
| 'true' | 1 |

Same pattern as ONFAULT.

### NODEEXECUTED (distinct_nodes_seen)

**All 413 active workflows show `distinct_nodes_seen = 1`.** Sterling is running on a single node — no clustering. Consistent with "single-node deployment" noted in the Roadmap's Out of Scope section.

---

## STATUS outcomes across 30 days

| STATUS value | Run count | % |
|---:|--:|--:|
| 0 | 38,154 | 99.85% |
| 1 | 57 | 0.15% |
| other | 0 | 0.00% |

**Only two STATUS values appear across 30 days of production data: 0 and 1.** No other values. The legacy "STATUS = 0 is success, STATUS = 1 is terminated with errors" framing is consistent with this observation but still unverified semantically — we haven't *proven* what 0 and 1 mean, only that they're the only values.

### Workflows with any failures (30d)

| NAME | OK | Fail | Fail Rate |
|---|--:|--:|--:|
| FA_CLIENTS_MAIN | 6,122 | 31 | 0.5% |
| FA_CLIENTS_VITAL | 10,165 | 14 | 0.1% |
| FA_CLIENTS_ENCOUNTER_LOAD | 77 | 5 | 6.1% |
| Schedule_IndexBusinessProcessService | 718 | 3 | 0.4% |
| FA_CLIENTS_EMAIL | 619 | 1 | 0.2% |
| FA_DM_ENOTICE | 44 | 1 | 2.2% |
| FA_TO_PHIN_SOLUTIONS_OB_BD_S2D_RT | 5 | 1 | 16.7% |
| SSHKeyGrabberProcess | 0 | 1 | 100% |

**Only 8 distinct workflows saw any failures in the 30-day window.** The 57 failures are clustered:

- **MAIN + VITAL account for 45 of 57 (79%)** of all failures. These are our highest-volume workflows, and most of the failure signal lives in them.
- **ENCOUNTER_LOAD at 6.1% fail rate** is notable given low volume — may indicate a specific integration issue worth investigating.
- **SSHKeyGrabberProcess: 1 run, 1 failure, 100%** — described as "created via command line" — likely a one-off debug/test artifact.
- **ARCHIVE has zero failures in 10,167 runs.** Either extremely reliable, fails at a level not reflected in STATUS, or its failure handling is different.

---

## Edge observations

### Multi-version workflows running simultaneously

Seven workflows show `distinct_versions_seen_running > 1` — meaning multiple WFD_VERSIONs of the same workflow fired within the 30-day window:

| NAME | Versions | 30d Runs |
|---|--:|--:|
| FA_CLIENTS_MAIN | 2 | 6,153 |
| FA_FROM_SENDRIGHT_ACK_RESP_IB_BDEO_D2X_BDL | 3 | 7 |
| FA_MONUMENT_HEALTH_IB_EO | 3 | 7 |
| FA_FROM_VANDERBILT_NEWLIGHT_IB_EO_TR_RT | 2 | 6 |
| FA_FULL_INVENTORY_MEDEVOLVE_IB_EO | 2 | 6 |
| FA_TO_PHIN_SOLUTIONS_OB_BD_S2D_RT | 2 | 6 |
| FA_FROM_LINK_DHS_SCORE_IB_EOBD_D2S_RC | 2 | 2 |

**MAIN ran as two distinct WFD_VERSIONs in 30d.** This is mid-flight version migration — MAIN was edited during the 30-day window, and both the old and new versions continued to execute after the edit (existing running instances didn't restart). This is relevant for BPML extraction: we want the *latest* version's BPML, not an older one. **Confirmed path: extract via `MAX(WFD_VERSION)` per `WFD_ID`.**

### OTHER active workflows

Three active workflows in the catchall OTHER family:

| NAME | 30d | Description |
|---|--:|---|
| RestoreService | 3 | "created via command line" |
| GG_TEST_BP | 2 | "testing" |
| SSHKeyGrabberProcess | 1 | "created via command line" |

Test/debug artifacts. Not operational. Can likely be ignored for future collection scope.

### Workflow editors

Not extensively analyzed here but noted for future reference:

- `rbmakram` — the original architect (Rober Makram). Many workflows still have him as latest editor, some dating to 2021.
- `pskorth`, `vxbandekar` — other historical editors
- No xFACts-era edits observed

This matters for authority questions during investigation — when BPMLs contain logic we don't understand, we know who touched it last (though the original architect is gone per the Roadmap).

---

## Implications for Steps 6B through 6G

**Observations only. No implementation decisions at this stage.**

### For 6B — BPML Bulk Extraction

**Extraction scope: 413 active WFDs as the primary target.** The 1,020 dormant WFDs are out of scope for deep analysis (not running, not operational). Extract BPMLs for the 413 active ones; catalog the dormant ones without BPMLs.

**Bonus extraction candidates: 17 dormant FA_CLIENTS workflows.** These are the suspected inline-invocation targets from MAIN (GET_DOCS, TRANS, PREP_SOURCE, etc.). They don't appear in `WF_INST_S` because they run inline, but their BPMLs are absolutely required for 6C's BPML analysis. Extract these too, even though they're classified as dormant. That brings the 6B extraction target to approximately **430 BPMLs**.

**Use `(WFD_ID, latest_WFD_VERSION)` for each extract.** Multi-version edge case is known; latest version is what we want.

### For 6C — Core Workflow BPML Analysis

**Priority workflows for deep BPML reading:**

- **Tier 1:** All 11 active FA_CLIENTS workflows (MAIN, VITAL, ARCHIVE, EMAIL, JIRA_TICKETS, GET_LIST, ENCOUNTER_LOAD, and the 4 lower-volume ones) — these are the core pipeline definitions
- **Tier 2:** All 17 dormant FA_CLIENTS workflows (GET_DOCS, PREP_SOURCE, TRANS, etc.) — the inline sub-workflows invoked by MAIN
- **Tier 3:** Representative FA_FROM and FA_TO dispatchers — covering Pattern 1 (direct), Pattern 3 (FTP files list), and Pattern 4 (inline GET_LIST) wrappers
- **Tier 4:** Sterling-native FileGateway, Schedule_*, and infrastructure workflows — less critical, but we should at least glance at them

**28 FA_CLIENTS BPMLs in total (11 active + 17 dormant) is the core deep-read set.** Plus ~10-15 representative dispatchers. Probably ~40 BPMLs total for deep reading.

### For 6D — Claim Verification

The ArchitectureOverview will have many MAIN-related claims (22 rules, sub-workflow invocation map, failure modes, etc.) that are testable against the extracted BPML. Several claims about schedule frequency and sub-workflow counts can be tested against the Step 6A metrics already collected.

**Example claim already testable:**
- *Claim:* "FA_CLIENTS_GET_LIST fires 11x per business day (5:05am-3:05pm M-F hourly)"
- *Observation:* 85 GET_LIST WF_INST_S rows in 30d. 11/day × ~22 business days = 242 expected. **Observed is 35% of expected.**
- *Tentative interpretation:* Pattern 4 wrappers invoke GET_LIST inline and therefore don't generate WF_INST_S rows. 85 standalone + N inline = actual count. Requires WORKFLOW_LINKAGE analysis to confirm.

### For 6E — Runtime Verification

Several runtime-verification targets surface from 6A:

- What do STATUS values 0 and 1 actually mean at the step-context level? (WORKFLOW_CONTEXT analysis)
- What does TYPE = 101, 102, 103, 104, 204 differentiate? (WFD metadata deep read)
- What does PERSISTENCE_LEVEL = 0 vs 3 affect in WORKFLOW_CONTEXT row counts?
- Why does ENCOUNTER_LOAD have 6% fail rate? (Targeted failure analysis)

---

## Resolved questions (originally open for this step)

1. ✅ **Total WFD count in b2bi** — 1,433 (matches Step 3 precisely)
2. ✅ **Active workflow count over 30 days** — 413 (Step 3's 332 at 48h was an undercount)
3. ✅ **Sterling is single-node** — every active workflow shows `distinct_nodes_seen = 1`
4. ✅ **STATUS column range in production** — only 0 and 1 observed in 30d; no other values
5. ✅ **FA_CLIENTS top-level workflows** — 11 active (MAIN, VITAL, ARCHIVE, EMAIL, JIRA_TICKETS, GET_LIST, ENCOUNTER_LOAD, CNSMR_ACCNT_AR_IB_BDEO_S2X_BDL, CNSMR_TAG_IB_BDEO_S2X_BDL, GROUP_KEYS_SP, INVALID_ACCOUNTS_OB_EOBD_D2S_RPT)
6. ✅ **ARCHIVE has zero STATUS=1 failures** in 10,167 runs — ARCHIVE failure semantics must be different from MAIN/VITAL
7. ✅ **FA_CLIENTS_MAIN is currently at version 48** — matches the ArchitectureOverview's claim of "v48 read end-to-end"

---

## New open questions raised

1. **Why do FA_CLIENTS_GET_LIST runs (85 in 30d) fall so far short of the claimed 11×/business-day schedule (~242)?** Hypothesis: Pattern 4 inline invocation. Needs BPML analysis.

2. **What is WFD.TYPE? Why do 16 workflows have TYPE=101 vs 393 at TYPE=1?** Examples of TYPE=101 workflows would help distinguish semantics.

3. **What does WFD.STATUS = 2 mean for the three active workflows that have it?** Possibly "disabled" but they're showing activity — so maybe not disabled.

4. **Why does WFD.ONFAULT = 'false' universally?** The ArchitectureOverview describes BPML-level `<onFault>` handlers in MAIN and GET_LIST. This WFD column appears to describe something else. Likely a default-fault-handler toggle separate from BPML-level onFault blocks.

5. **How does FA_CLIENTS_ARCHIVE handle failure signaling if STATUS=1 is never set?** Either genuinely always succeeds, fails silently in a way invisible to WF_INST_S.STATUS, or has its own internal error-handling that reports success-with-errors.

6. **What does FA_CLIENTS_JIRA_TICKETS do?** 120 runs in 30d, not mentioned in ArchitectureOverview.

7. **What does FA_CLIENTS_ENCOUNTER_LOAD's 6% fail rate indicate?** Highest fail rate among FA_CLIENTS workflows; worth targeted failure analysis.

---

## Document status

| Attribute | Value |
|---|---|
| Step | 06A — Active Workflow Catalog |
| Status | **Complete** |
| Next | Step 6B — BPML Bulk Extraction (~430 BPMLs: all 413 active + 17 dormant FA_CLIENTS) |
| Roadmap impact | §5.6 (MAIN Anatomy) — narrowed scope decision for BPML extraction. §5.3 (Workflow Universe) — 30d active count updated to 413 (from 48h's 332). New workflow catalog doc produced that all subsequent steps can reference. |

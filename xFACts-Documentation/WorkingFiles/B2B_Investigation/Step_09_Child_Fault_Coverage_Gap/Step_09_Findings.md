# Step 09 -- Child-Fault Silent Coverage Gap: Findings

## 1. Context and goal

An FA_CLIENTS_ENCOUNTER_LOAD run failed at translation, yet nothing surfaced:
no fault report, no alert, and a parent pipeline run that read fully COMPLETE.
The goal of this step was to establish whether that was a one-off data-quality
miss, a collector defect, or a structural coverage boundary -- and to settle
the long-parked R12 question (does a child workflow's fault propagate to its
parent?). This is a documentation-only step: no schema, collector, BPML, or CC
change. It records what was found and the decision it drove (Roadmap section
7.10).

## 2. The anchor incident (8651070)

FA_CLIENTS_ENCOUNTER_LOAD instance **8651070** is an invoked subprocess of
tracked MAIN run **8651060**. It faulted at its **Translation** step at
**12:15:27 on 2026-07-22** and terminated with Sterling **Status: Error,
State: Completed**; the Sterling BPD screenshot's ERROR_SERVICE names
**Translation step 2**.

Its footprint in the tracking surfaces:

- **No row** in Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS.
- **No row** in B2B.INT_PipelineTracking (the mirror).
- The **parent MAIN run 8651060 closed batch_status 3 (COMPLETE)** -- green.

So a real Sterling-internal translation failure left no trace on any surface
the B2B module can see, and its parent reported success.

## 3. The sweep (Section 1 of Step_09_Query.sql)

To size the pattern, a WORKFLOW_CONTEXT failed-step sweep was run:

```sql
SELECT WFD.NAME, WC.WORKFLOW_ID, WC.SERVICE_NAME, WC.START_TIME
FROM b2bi.dbo.WORKFLOW_CONTEXT WC
JOIN (SELECT WFD_ID, NAME FROM b2bi.dbo.WFD GROUP BY WFD_ID, NAME) WFD
  ON WFD.WFD_ID = WC.WFD_ID
WHERE WC.BASIC_STATUS = 1
  AND WC.START_TIME >= DATEADD(DAY, -5, GETDATE())
ORDER BY WC.START_TIME DESC;
```

It returned **23 distinct failed instances**. The five-day lookback was
deliberately wider than needed: b2bi holds only ~48 hours of data live in its
primary tables, so the returned rows span roughly two days (oldest hit
2026-07-20 05:37) -- see section 7 on retention. By family:

| Family | Distinct instances |
|---|--:|
| Inline-in-MAIN (FA_CLIENTS_TRANS / POST_TRANSLATION steps under a MAIN instance) | 9 |
| GET_LIST dispatcher (own instance) | 1 |
| FA_CLIENTS_VITAL (Translation) | 11 |
| FA_CLIENTS_ENCOUNTER_LOAD (Translation) | 2 |
| **Total** | **23** |

The failing SERVICE_NAME varies by class: BPExceptionService (the escalated
map-succeeds/BPML-raises shape from Step 08), Translation (a direct map fault),
and AS2LightweightJDBCAdapter (a JDBC/SQL fault). The failure *mechanism* is not
the point of this step; *whether the failure is tracked* is.

## 4. The discriminator: a clean tracked/untracked split (Section 2)

The 23 distinct ids were checked against both tracking surfaces at once:

```sql
SELECT s.WORKFLOW_ID, s.family, t.BATCH_STATUS AS src_status, p.status_classification
FROM (VALUES ... 23 rows ...) s(WORKFLOW_ID, family)
LEFT JOIN Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS t ON t.RUN_ID = s.WORKFLOW_ID
LEFT JOIN xFACts.B2B.INT_PipelineTracking p ON p.run_id = s.WORKFLOW_ID
ORDER BY s.family, s.WORKFLOW_ID;
```

The result split with no ambiguity:

| Class | Count | src_status | mirror classification |
|---|--:|---|---|
| Inline-in-MAIN | 9 | -1 | STERLING_FAULT |
| GET_LIST dispatcher | 1 | -1 | STERLING_FAULT |
| FA_CLIENTS_VITAL | 11 | NULL | NULL |
| FA_CLIENTS_ENCOUNTER_LOAD | 2 | NULL | NULL |

- **Tracked (10):** every inline-in-MAIN failure and the GET_LIST fault carry
  -1 / STERLING_FAULT on both surfaces -- the fault handlers work.
- **Untracked (13):** every separate-instance invoked child (11 VITAL + 2
  ENCOUNTER_LOAD) is absent from both the Integration table and the mirror,
  and every one of their parents reads green.
- The anchor **8651070** sits in the untracked set (NULL / NULL), as expected.

Across the ~3 days of returned data, 13 untracked failures is on the order of
**four silent failures per day**.

The real discriminator is **whether the faulting instance's workflow
self-reports to BATCH_STATUS**. MAIN writes its own BATCH_STATUS row (and its
inline sub-steps -- TRANS, POST_TRANSLATION -- run under MAIN's WORKFLOW_ID, so
they ride MAIN's -1). GET_LIST writes its own row on fault. VITAL and
ENCOUNTER_LOAD, when invoked as their own instances, write no BATCH_STATUS row
at all -- so when they fault, there is nothing to see.

## 5. Root cause: a source-instrumentation coverage boundary

The child workflows' BPMLs contain **no status-write steps**. A tracking row
exists only for workflows that self-report; a workflow that never writes to
BATCH_STATUS is invisible whether it succeeds or fails. This is **not** an
Integration data-quality failure (the reconciler and the mirror faithfully
represent every row that exists) and **not** a collector defect (the collector
mirrors what BATCH_STATUS holds). It is a coverage boundary in the *source*
instrumentation, and it matches the Step 6G section 6 known-blind-spots list
directly: "inline invocations are runtime-invisible" and
"VITAL/ACCOUNTS/BATCH_FILES/ENCOUNTER writes hide in translation maps."

## 6. R12 closed: child faults do not propagate

R12 (child-onFault vs parent NOTIFY_PARENT_ON_ERROR propagation) was raised in
Step 6D 6.10, carried in Step 6E, and parked in **Step 6G section 6** as an
opportunistic inspection awaiting a natural anchor run. **8651070 is that
anchor.** The child faulted and terminated in error; the parent MAIN run
completed green with batch_status 3 and no fault of its own. Verdict:

**A child workflow's fault does NOT propagate to its parent's Integration
status.** The parent completes normally and the faulting child leaves no
tracking row. R12 is CLOSED. (Cross-reference: Step 6G section 6.)

## 7. Interim mitigation and the retention ceiling

Until the execution census (section 8) is built, the **sweep in Section 1 is
the interim manual check** the team can run to surface silent child faults. It
reads live b2bi WORKFLOW_CONTEXT for BASIC_STATUS = 1; the untracked classes
(VITAL, ENCOUNTER_LOAD, and any other non-self-reporting workflow) are the ones
that will never appear on the B2B page.

Retention bounds how far back it can see, and this is the reason to run it
**at least every couple of days**:

- b2bi holds only about **48 hours** of data live in its primary tables
  (Dirk, 2026-07-22). The five-day lookback used here was deliberately wide to
  be certain nothing available was missed; the returned rows span roughly two
  days, consistent with that window.
- The history / _RESTORE equivalents were not queried in this step and may
  extend the reachable window; that outer ceiling is unquantified here.

Practical consequence: a failure that is not captured within the live window is
unrecoverable from the primary tables, so the check is time-sensitive until the
census closes the gap by construction.

## 8. Implication: the execution-census decision (Roadmap section 7.10)

This step is the direct evidence behind the DECIDED (2026-07-22) execution
census. Because the silent gap is structural -- rows exist only for
self-reporting workflows -- no amount of collector tuning on the BATCH_STATUS
mirror can close it. The decision is to build a **b2bi-native execution
census** as the primary tracking surface: one row per workflow instance sourced
from b2bi existence (WF_INST_S and its restore sibling), enriched with
Integration/DM lifecycle content for the subset that has it. Completeness by
construction -- a row exists because the instance existed in Sterling.

Recorded scope guards (design not started): INT_PipelineTracking's disposition
(absorbed vs. retained as an enrichment source) is the first design-phase
question; the mirror stays necessary for DM reconciliation and is not
deprecated. Tracked as backlog B-109. The separate GET_LIST v20 fault-ticket
fix (tracked but ticket-invisible faults) was raised to High as B-110 on the
strength of the 2026-07-21 GET_LIST dispatcher fault in the same window.

## Artifacts in this step folder

| File | Purpose |
|---|---|
| Step_09_Query.sql | The sweep (Section 1) and the tracker discriminator (Section 2) |
| Step_09_Results.txt | Raw result sets from both sections (pasted from SSMS) |
| Step_09_Findings.md | This document |

## Document status

| Attribute | Value |
|---|---|
| Step | 09 -- Child-Fault Silent Coverage Gap |
| Status | **Complete** |
| Next | Execution-census design (backlog B-109, Roadmap section 7.10) -- not started |
| Roadmap impact | New section 4.2d (four Known True entries); section 5.15 R12 marked CLOSED; new section 7.10 (execution-census decision); section 8 gains Step 09; status line, Next Session, and section 9 updated; version 3.4. Backlog B-109 (census) opened and B-110 (GET_LIST v20) raised to High. |

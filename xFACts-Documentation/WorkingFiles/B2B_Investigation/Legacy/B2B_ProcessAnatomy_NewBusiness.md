> ### ⚠️ Scope Notice — Narrow Reference
>
> **This document remains accurate for its scope** — a live trace of one FA_CLIENTS_MAIN New Business workflow run (ACADIA HEALTHCARE, WF 7990812, 2026-04-19). The ProcessData content, sub-workflow invocation pattern, timing profile, and CLIENTS_FILES / CLIENTS_PARAM source mapping documented here are verified for that specific run.
>
> **However, this is NOT a universal template.** The initial investigation assumed FA_CLIENTS_MAIN was the grain for all Sterling work at FAC. Subsequent investigation (Step 3) showed MAIN is only ~16% of activity and that 643 distinct FA_* workflow definitions exist — the NB pattern documented here is one of many process anatomies, not a model for how everything works.
>
> **Authoritative sources:** `Planning/B2B_Roadmap.md` and `WorkingFiles/B2B_Investigation/` step findings.
>
> This document is a useful reference *for FA_CLIENTS_MAIN New Business executions specifically*. Do not generalize its conclusions to other process types or workflow families without separate verification.

---

# B2B Process Anatomy — New Business (NB)

## Purpose of This Document

Reference document for the NEW_BUSINESS (NB) process type in Sterling B2B Integrator as configured at FAC. Documents what distinguishes an NB file process from other process types in terms of ProcessData content, sub-workflow invocation pattern, file-loop behavior, and performance profile.

Intended audience: Dirk and the xFACts build effort; eventually source material for a Control Center B2B module help page.

**Prerequisite reading:** `B2B_ArchitectureOverview.md` — the shared architectural foundation for all process type anatomies. That document covers concepts referenced throughout this one (Three Identity Scopes, the Configuration Source, Run Classification, Four Dispatch Patterns, ProcessData structure, etc.).

---

## What NB Is

"New Business" refers to the inbound placement of new accounts from a client into FAC's DM platform. When a client places new debt with FAC for collections, the NB file is the mechanism for that placement to flow into DM.

NB is **inbound** only. `PROCESS_TYPE = NEW_BUSINESS` + `COMM_METHOD = INBOUND` — this pair is the canonical NB signature.

NB is distinguished from other process types primarily by:
- It invokes `FA_CLIENTS_ACCOUNTS_LOAD` — the sub-workflow that stages records for DM's CLIENTS_ACCTS loading mechanism
- It typically invokes `FA_CLIENTS_WORKERS_COMP`, `FA_CLIENTS_DUP_CHECK`, and `FA_CLIENTS_ADDRESS_CHECK` — consumer validation steps
- It does NOT invoke `FA_CLIENTS_POST_TRANSLATION` — unlike PMT, NB does not call Integration stored procedures after translation

---

## The Canonical NB Run — ACADIA HEALTHCARE, WF 7990812

Live trace of a working NB run, used throughout this doc as the reference example.

**Context:**
- WORKFLOW_ID: 7990812
- Root workflow: `FA_FROM_ACADIA_HEALTHCARE_IB_BD_P2X_NB` (Pattern 1 — schedule-fired named workflow)
- Parent: same (root is the immediate parent — direct invocation of MAIN)
- CLIENT_ID: 10557 (ACADIA HEALTHCARE)
- SEQ_ID: 1
- Start time: 2026-04-19 07:35:04
- End time: ~2026-04-19 07:37:05 (derived from last step at step 1203)
- Duration: ~2 minutes 1 second
- Total steps: 1,210
- Files processed: 14
- STATUS: 0 (success), STATE: 1

### ProcessData (decompressed)

```xml
<?xml version='1.0' encoding='UTF-8'?>
<r>
  <Client>
    <CLIENT_ID>10557</CLIENT_ID>
    <SEQ_ID>1</SEQ_ID>
    <CLIENT_NAME>ACADIA HEALTHCARE</CLIENT_NAME>
    <PROCESS_TYPE>NEW_BUSINESS</PROCESS_TYPE>
    <COMM_METHOD>INBOUND</COMM_METHOD>
    <FILE_ID>0</FILE_ID>
    <PRE_ARCHIVE>Y</PRE_ARCHIVE>
    <TRANSLATION_MAP>FA_ACADIA_HEALTHCARE_IB_BD_P2X_NB</TRANSLATION_MAP>
    <WORKERS_COMP>Y</WORKERS_COMP>
    <DUP_CHECK>Y</DUP_CHECK>
    <PREPARE_SOURCE>Y</PREPARE_SOURCE>
    <POST_ARCHIVE>Y</POST_ARCHIVE>
    <FILE_FILTER>acadia.*FRSPF2*</FILE_FILTER>
    <GET_DOCS_TYPE>SFTP_PULL</GET_DOCS_TYPE>
    <GET_DOCS_LOC>acadia</GET_DOCS_LOC>
    <PREPARE_COMM_CALL>Y</PREPARE_COMM_CALL>
    <COMM_CALL>Y</COMM_CALL>
    <BUSINESS_TYPE>BD</BUSINESS_TYPE>
    <AUTO_RELEASE>Y</AUTO_RELEASE>
    <PV_FN_ADDRESS>ADDRESS</PV_FN_ADDRESS>
    <FILE_CLEAN_UP>N</FILE_CLEAN_UP>
    <!-- ~50 other empty fields omitted for brevity -->
  </Client>
</r>
```

**Single `<Client>` block** — this NB run is not multi-Client. Whether any NB configurations use multi-Client is unknown; ACADIA's is not.

**Populated flags:**
- `PRE_ARCHIVE=Y`, `POST_ARCHIVE=Y` → archiving enabled
- `PREPARE_SOURCE=Y` → pre-translation prep sub-workflow
- `WORKERS_COMP=Y` → workers comp check
- `DUP_CHECK=Y` → duplicate consumer detection
- `PREPARE_COMM_CALL=Y`, `COMM_CALL=Y` → DM API push
- `AUTO_RELEASE=Y` → auto-release batches in DM after load

**Empty (NB does not use these):**
- `POST_TRANSLATION` empty → no Integration SP call after translation
- `POST_TRANSLATION_MAP` empty → no secondary translation
- `POST_TRANS_SQL_QUERY` empty → no Integration stored procedure invocation
- `PUT_DOCS_TYPE` empty, `PUT_DOCS_LOC` empty → inbound, no push
- `MAIL_TO` / `MAIL_CC` empty → no notification at this stage

---

## Configuration Source Mapping

The ProcessData above is assembled from these rows in the Integration configuration tables.

### `tbl_B2B_CLIENTS_FILES` row for (10557, 1)

| Column | Value |
|---|---|
| ACTIVE_FLAG | 1 |
| RUN_FLAG | 0 |
| PROCESS_TYPE | NEW_BUSINESS |
| COMM_METHOD | INBOUND |
| AUTOMATED | 2 |
| FILE_MERGE | 1 |

### `tbl_B2b_CLIENTS_PARAM` rows for (10557, 1)

| PARAMETER_NAME | PARAMETER_VALUE |
|---|---|
| DUP_CHECK | Y |
| FILE_FILTER | acadia.*FRSPF2* |
| GET_DOCS_LOC | acadia |
| GET_DOCS_TYPE | SFTP_PULL |
| POST_ARCHIVE | Y |
| PRE_ARCHIVE | Y |
| PREPARE_COMM_CALL | Y |
| PREPARE_SOURCE | Y |
| AUTO_RELEASE | Y |
| WORKERS_COMP | Y |
| BUSINESS_TYPE | BD |
| TRANSLATION_MAP | FA_ACADIA_HEALTHCARE_IB_BD_P2X_NB |
| PV_FN_ADDRESS | ADDRESS |
| COMM_CALL | Y |
| FILE_CLEAN_UP | N |

**Every value in ProcessData ties directly back to one of these two tables.** Sterling reads both at runtime and assembles the XML document.

---

## Sub-Workflow Invocation Pattern (Live)

From WORKFLOW_CONTEXT, `ADV_STATUS LIKE '%Inline Begin%'` markers:

```
Step 9:   FA_CLIENTS_GET_DOCS         (SFTP pull, once — happens before the loop)
Step 188: FA_CLIENTS_ARCHIVE          (pre-archive, once, OUTSIDE the loop)

─── Loop iteration 1 (file 1) ───
Step 195: FA_CLIENTS_PREP_SOURCE
Step 212: FA_CLIENTS_TRANS
Step 223: FA_CLIENTS_ACCOUNTS_LOAD
Step 238: FA_CLIENTS_FILE_MERGE
Step 250: FA_CLIENTS_ARCHIVE           (per-iteration archive)

─── Loop iteration 2 (file 2) ───
Step 257: FA_CLIENTS_PREP_SOURCE
Step 274: FA_CLIENTS_TRANS
Step 285: FA_CLIENTS_ACCOUNTS_LOAD
Step 300: FA_CLIENTS_FILE_MERGE
Step 321: FA_CLIENTS_ARCHIVE

... iterations 3 through 14 (same pattern) ...

─── Post-loop tail ───
Step 1173: FA_CLIENTS_WORKERS_COMP
Step 1180: FA_CLIENTS_DUP_CHECK
Step 1190: FA_CLIENTS_ARCHIVE          (final post-archive)
Step 1197: FA_CLIENTS_ADDRESS_CHECK
Step 1203: FA_CLIENTS_COMM_CALL        (push to DM via FA_CLA_DM_API)
(workflow ends)
```

### Observed Counts for 14 Files

| Sub-Workflow | Invocations | Notes |
|---|--:|---|
| FA_CLIENTS_GET_DOCS | 1 | Once, pulls all files |
| FA_CLIENTS_PREP_SOURCE | 14 | Once per file in loop |
| FA_CLIENTS_TRANS | 14 | Once per file in loop |
| FA_CLIENTS_ACCOUNTS_LOAD | 14 | **NB-distinctive** — once per file in loop |
| FA_CLIENTS_FILE_MERGE | 14 | Once per file in loop |
| FA_CLIENTS_ARCHIVE | 16 | 1 pre-archive + 14 per-iteration + 1 final post-archive |
| FA_CLIENTS_WORKERS_COMP | 1 | Once, after loop |
| FA_CLIENTS_DUP_CHECK | 1 | Once, after loop |
| FA_CLIENTS_ADDRESS_CHECK | 1 | Once, after loop |
| FA_CLIENTS_COMM_CALL | 1 | Once, pushes consolidated output to DM |

### Sub-Workflows NOT Invoked in NB

- `FA_CLIENTS_POST_TRANSLATION` — NB doesn't need post-translation (no Integration SP call)
- `FA_CLIENTS_VITAL` — not invoked at the MAIN level (likely fires inside ACCOUNTS_LOAD as a deeper child — Q2.2 data showed 888 VITAL runs vs. 820 MAIN runs, consistent with VITAL being called inside ACCOUNTS_LOAD for each file)
- `FA_CLIENTS_EMAIL` — MAIL_TO is empty in this configuration, so no email notification

### Sub-Workflow That Fires Without a Marker

`PREPARE_COMM_CALL=Y` in ProcessData, but no `Inline Begin FA_CLIENTS_PREP_COMM_CALL` marker appears in WORKFLOW_CONTEXT between ADDRESS_CHECK (step 1197) and COMM_CALL (step 1203). Possibilities:
- PREP_COMM_CALL is inline without a sub-workflow invocation (executes as non-named steps within MAIN)
- PREP_COMM_CALL was deprecated but the flag is still honored as a no-op
- Marker naming may differ from the sub-workflow name

Needs verification — inspect steps 1197-1202 for any non-"Inline Begin" indication of PREP_COMM_CALL work.

---

## NB Distinguishing Markers

For the collector to recognize an NB run (even without parsing PROCESS_TYPE directly), the following signatures are reliable:

**Positive indicators:**
- `PROCESS_TYPE = NEW_BUSINESS` in ProcessData (authoritative from CLIENTS_FILES)
- One or more `FA_CLIENTS_ACCOUNTS_LOAD` invocations in WORKFLOW_CONTEXT (the strongest structural marker — other process types don't invoke ACCOUNTS_LOAD)
- TRANSLATION_MAP name contains `_NB` suffix (convention, not guaranteed)
- `COMM_METHOD = INBOUND`

**Negative indicators (what NB does NOT have):**
- No POST_TRANSLATION_MAP
- No POST_TRANS_SQL_QUERY with Integration stored procedure
- No PUT_DOCS_LOC / PUT_DOCS_TYPE (not outbound)

---

## File Count Determination

For any NB MAIN run, the file count can be derived from the invocation counts of the loop-body sub-workflows. All four give the same answer:

- `count(FA_CLIENTS_PREP_SOURCE invocations)`
- `count(FA_CLIENTS_TRANS invocations)`
- `count(FA_CLIENTS_ACCOUNTS_LOAD invocations)`
- `count(FA_CLIENTS_FILE_MERGE invocations)`

TRANS is the most universal (all inbound types use it) so it's the recommended signal.

---

## Performance Profile

Breakdown of the 2-minute ACADIA NB run timing:

| Phase | Start | End | Duration | Notes |
|---|---|---|---|---|
| Startup + GET_DOCS | 07:35:04 | 07:35:05 | ~1 sec | SFTP pull of 14 files |
| Pre-archive | 07:35:06 | 07:35:06 | <1 sec | |
| **Loop (14 iterations × 5 sub-workflows)** | **07:35:06** | **07:35:13** | **~7 sec** | **~500ms per iteration — very fast** |
| WORKERS_COMP | 07:35:12 | 07:35:22 | ~10 sec | |
| DUP_CHECK | 07:35:22 | ~07:35:38 | ~16 sec | Expensive — queries DM for consumer matches |
| Final archive + ADDRESS_CHECK | 07:35:38 | 07:35:39 | <1 sec | |
| **COMM_CALL** | **07:37:05** | (end) | **~86 sec** | **DM API push with 14 files of records** |

**Key observations:**
- The actual file-processing loop is lightning fast — Sterling translation is not the bottleneck
- **DUP_CHECK and COMM_CALL dominate runtime** together accounting for ~100 seconds of the ~120-second total
- COMM_CALL is network + DM-side processing time — pushing records via `FA_CLA_DM_API`
- For monitoring, "slow NB runs" should flag when total duration significantly exceeds ~2 minutes for a typical volume

**Rough heuristics (to refine with more samples):**
- NB run with 5-20 files: 1-3 minutes normal
- NB run with 50+ files: may be 5+ minutes due to COMM_CALL scaling
- A 10-minute+ NB run likely indicates DM-side issues or massive file volume

---

## Variations to Expect (Unverified)

These are hypotheses to verify as more NB clients are traced:

| Variation | Likely Source | Status |
|---|---|---|
| Single-file vs. multi-file (ACADIA had 14; some clients may send 1) | Client-specific file patterns + scheduling frequency | Not verified |
| With/without WORKERS_COMP | Per-client WORKERS_COMP flag in CLIENTS_PARAM | Not verified across clients |
| With/without DUP_CHECK | Per-client DUP_CHECK flag | Not verified |
| EO (Early Out) vs. BD (Bad Debt) | BUSINESS_TYPE in ProcessData | Not verified |
| TRANSLATION_MAP variations | Each client has its own translation map | Confirmed different per client |
| Multi-Client NB | Multiple `<Client>` blocks in ProcessData | Not observed — may not occur for NB |
| Failure modes | Translation errors, DM push failures, SFTP timeouts | Not yet observed |

---

## ACADIA HEALTHCARE Context

ACADIA is a heavy-volume NB client, with multiple configured processes. Their NB-specific configuration is `SEQ_ID 1`. Other ACADIA processes include:

| SEQ_ID | PROCESS_TYPE | FILE_FILTER | Notes |
|--:|---|---|---|
| 1 | NEW_BUSINESS | `acadia.*FRSPF2*` | **This doc** |
| 2 | FILE_DELETION | `acadia.*FRSCMT*` | Companion cleanup for another file type |
| 3 | FILE_DELETION | `acadia.*FRSPFT*` | Companion cleanup |
| 4 | RECON | `acadia.*FRSRCN*` | Daily recon process with TRUNCATE SQL hook |
| 5 | FILE_DELETION | `acadia.*FRSPFC*` | Companion cleanup |
| 6 | SPECIAL_PROCESS | `acadia.*FRSTRN*` | Transactions |
| 7 | FILE_EMAIL | `Acadia_Healthcare_Payments_<%m%d%y>.csv` | Outbound with MAIL_TO notification |
| 8 | RETURN | `FRSCLOSED_<%Y_%m_%d>.txt` | Outbound returns |
| 9 | RETURN | (unknown — no CLIENTS_PARAM rows visible in inspected data) | Configured but potentially misconfigured |

NB for ACADIA flows from their NB file (matching `acadia.*FRSPF2*`), gets translated via `FA_ACADIA_HEALTHCARE_IB_BD_P2X_NB`, and is pushed into DM with standard NB processing.

---

## Observed TRANS_DATA Structure (Beyond ProcessData)

In addition to the ProcessData document at the start, WF 7990812 generated many DOCUMENT-type TRANS_DATA rows throughout execution. Sampling the first 10 by CREATION_DATE:

| CREATION_DATE | DATA_TYPE | Size | Likely Content |
|---|--:|--:|---|
| 07:35:04.047 | 2 | 846 | **ProcessData** (the configuration document) |
| 07:35:04.077 | 2 | 99 | Sub-workflow result (likely POST-translation stored result) |
| 07:35:04.830 | 2 | 13,088 | Raw pulled file content — one of the 14 NB files |
| 07:35:05.060 | 2 | 428 | Small status / config payload |
| 07:35:05.100 | 10 | 56 | Metadata |
| 07:35:05.163 | 10 | 36 | Metadata |
| 07:35:05.223 | 10 | 36 | Metadata |
| 07:35:05.290 | 10 | 61 | Metadata |
| 07:35:05.333 | 10 | 63 | Metadata |
| 07:35:05.390 | 10 | 57 | Metadata |

`DATA_TYPE=2` appears to be content/payload documents; `DATA_TYPE=10` appears to be metadata/status payloads. Exact semantics unconfirmed.

**Implication for detail extraction (future phase):** to extract record counts per file or DM Creditor breakdowns, the collector would need to find the Translation output documents among these TRANS_DATA rows and decompress them. The 14 files correspond to 14 TRANS invocations, each producing (per prior session notes) approximately three Translation outputs — one CSV, one full XML, one VITAL XML. The VITAL XML is the DM-targeted format with `<TRANSACTION>` elements containing creditor breakdowns.

---

## Open Questions Specific to NB

| Question | How to Resolve |
|---|---|
| Does every NB run have the same sub-workflow pattern? Or does it vary by client configuration? | Trace 2-3 more NB runs from different clients (LIFESPAN R1, MEDICAL_CENTER_HEALTH, RADIOLOGY_PARTNERS) |
| Can NB be multi-Client? | Sample many NB runs across clients; inspect `<Client>` block counts |
| How does NB behave for a failure? Does translation error produce a different sub-workflow pattern? Does ProcessData still exist? | Find a failed NB run and trace it |
| How does NB behave for an empty run (scheduled fire, no files)? | Find an NB scheduler run where no files arrived and trace it |
| Exact location of FA_CLIENTS_VITAL invocations — inside ACCOUNTS_LOAD? | Trace an ACCOUNTS_LOAD child workflow's own WORKFLOW_CONTEXT |
| What's in the PREPARE_COMM_CALL "gap" between ADDRESS_CHECK (step 1197) and COMM_CALL (step 1203)? | Inspect steps 1198-1202 in WORKFLOW_CONTEXT for the ACADIA run |
| What does the Translation output VITAL XML look like for NB? | Decompress a Translation output from a TRANS step in WF 7990812 |
| For clients with different NB patterns (LIFESPAN R1 multi-file), are iteration counts predictable? | Trace LIFESPAN R1 NB and compare |

---

## Document Status

| Attribute | Value |
|-----------|-------|
| Purpose | NB-specific process anatomy reference |
| Created | April 19, 2026 |
| Last Updated | April 20, 2026 |
| Status | Populated with live ACADIA trace — additional NB clients and edge cases to be added |
| Companion to | `B2B_ArchitectureOverview.md` |
| Primary Reference Run | WF 7990812 (ACADIA HEALTHCARE NB, 2026-04-19 07:35) |

### Revision Log

| Date | Revision |
|------|----------|
| April 19, 2026 (initial) | Initial shell creation with placeholders. Noted NB as target process type; referenced prior-session knowledge about LIFESPAN R1 from memory. |
| April 20, 2026 (full rewrite) | Fully replaced placeholder content with live ACADIA NB trace (WF 7990812). Real ProcessData, real sub-workflow pattern (14-iteration loop), performance profile, CLIENTS_FILES + CLIENTS_PARAM source mapping, distinguishing markers, ACADIA context with all 9 configured processes, open questions. Removed all prior-session-recollection content in favor of live-verified detail. |

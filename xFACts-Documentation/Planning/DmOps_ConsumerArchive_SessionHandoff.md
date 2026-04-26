# DmOps Consumer Archive — Session Handoff

**Date:** 2026-04-26
**Status:** Phase 1 (infrastructure) deployed. Script consolidation deferred to next session — will start over cleanly.

---

## Background / Why We Pivoted

Account-level archiving via `Execute-DmArchive.ps1` (TA_ARCH tag) revealed a structural problem: when distributed payments span multiple accounts on the same consumer and only some of those accounts are archived, the `cnsmr_pymnt_jrnl` row remains but its account-level distribution detail is partial. This breaks the DM UI's distributed-payment view.

**Decision:** Pivot from account-level (TA_ARCH) to consumer-level (TC_ARCH) archiving. A consumer is only eligible for archive when ALL of its accounts qualify, ensuring `cnsmr_pymnt_jrnl` and its distribution chain are always handled atomically.

**Architectural decision:** Merge `Execute-DmArchive.ps1` and `Execute-DmShellPurge.ps1` into a single unified script (`Execute-DmConsumerArchive.ps1`) that performs:
1. Account-level deletes (orders 1–117 from Execute-DmArchive Phase 2, unchanged)
2. BIDATA P→C migration (unchanged)
3. Consumer-level deletes (orders 1–110 from Execute-DmShellPurge Phase 2, unchanged)

The unified flow eliminates the gap where shell consumers wait for next-day shell purge processing.

---

## Phase 1 Infrastructure — DEPLOYED

All Phase 1 SQL deployed to production AVG-PROD-LSNR / xFACts. Files were generated, edited by Dirk during deployment (removing speculative content), and applied. The current state in production reflects Dirk's edits, not the original generated content.

### Phase1_Prerequisites.sql (deployed)

**New table: `DmOps.Archive_ConsumerExceptionLog`** — captures consumers excepted from a batch by Step 3.5 runtime re-verification. Pattern mirrors `ShellPurge_ExclusionLog` (no FK to BatchLog — batch_id stored as audit context only).

Columns:
- `exception_id` BIGINT IDENTITY PK
- `batch_id` BIGINT (audit-only, no FK)
- `cnsmr_id` BIGINT
- `cnsmr_idntfr_agncy_id` BIGINT
- `detected_dttm` DATETIME
- `tag_removed` BIT (best-effort confirmation flag)
- `ar_event_written` BIT (best-effort confirmation flag)

**Four GlobalConfig entries** (module='DmOps', category='Archive'):
- `tag_removal_actn_cd` — value: `CC` — action code for cnsmr_accnt_ar_log event when removing TC_ARCH from excepted consumer
- `tag_removal_rslt_cd` — value: `CC` — result code, same context
- `tag_removal_user` — value: `sqlmon` — username string written to ar_log event
- `tag_removal_msg_txt` — value/format set during deployment

All four required `description` field per platform standards.

### Phase1_ObjectRegistry_Metadata.sql (deployed, Dirk edited content)

Object_Registry entry + Object_Metadata baselines for `Archive_ConsumerExceptionLog` (description, columns, data_flow, design_notes, relationship_notes). Content reflects Dirk's edits during deployment, which removed:
- Volume predictions
- Future-tense speculation
- Operational interpretation that doesn't belong in structural metadata

### Phase1_Prerequisites_Adjustments.sql (deployed)

- Dropped `FK_Archive_ConsumerExceptionLog_BatchLog` (FK to BatchLog removed; batch_id remains as audit-only)
- Added column `exception_count INT NOT NULL DEFAULT 0` to `DmOps.Archive_BatchLog`
- Updated Object_Metadata for new column and revised relationship_note

---

## Existing Components Already in Place (Pre-Session)

These were built before this session and are functioning:

- **TC_ARCH tag job** — already deployed and tagging consumers nightly in crs5_oltp where ALL their accounts meet archive criteria
- **`DmOps.Archive_BatchLog`** — exists, with the new `exception_count` column added this session
- **`DmOps.Archive_BatchDetail`** — exists, used for per-table operation logging
- **`DmOps.Archive_ConsumerLog`** — exists, captures per-consumer audit trail with `bidata_migrated` flag
- **`DmOps.ShellPurge_ExclusionLog`** — exists, used as pattern reference for the new ConsumerExceptionLog
- **`DmOps.Archive_Schedule`** — 7 rows, hourly mode values (0=blocked, 1=full, 2=reduced)
- **`Execute-DmArchive.ps1`** — production account-level archive script (still deployed, will be retired when unified script replaces it)
- **`Execute-DmShellPurge.ps1`** — production consumer-level shell purge script (still deployed, will be retired when unified script replaces it)

---

## Settled Design Decisions

These were agreed during this session and should carry into the next:

### Unified script structure
- Single batch flow: account-level deletes → BIDATA P→C migration → consumer-level deletes
- TC_ARCH-driven consumer batch selection (not TA_ARCH account selection)
- Batch consumers come from `cnsmr_Tag` for `tag_shrt_nm = 'TC_ARCH'`, then expand to all their `cnsmr_accnt` rows (no per-account tag filter — at consumer level we archive everything the consumer owns)

### Step 3.5 — Runtime Re-Verification (NEW step, between batch selection and deletes)
- Pattern B: mirror the apply-job eligibility logic, inverted, to find batch members whose state has changed since they were tagged
- For each excepted consumer:
  1. **First:** unconditionally remove from current batch
  2. Soft-delete the TC_ARCH tag on `cnsmr_Tag` (uses 4 `tag_removal_*` GlobalConfig values)
  3. Write an AR event to `cnsmr_accnt_ar_log` (CC/CC, consumer-level row with NULL `cnsmr_accnt_id`)
  4. Insert a row to `Archive_ConsumerExceptionLog`
- Steps 2–4 are best-effort with confirmation flags on the exception log row
- **Retry path skips Step 3.5 entirely** — documented assumption that prior verification was valid; if any deletes already started, retry is past the point of no return

### batch_size_used semantics
- Stored value = actual candidate count returned (post-TOP-N, pre-exception filter)
- Math: `batch_size_used = consumer_count + exception_count`
- Slight semantic shift from existing archive script (which stored the configured TOP-N) — accepted

### All-excepted batch
- If 100% of candidates are excepted, finalize BatchLog as Success with `consumer_count = 0` and continue loop

### BIDATA failure halts batch
- Failed BIDATA migration causes batch to fail and Step 7 (consumer-level deletes) does not run
- Protects against worst-case: consumer-level deletes succeed but BIDATA never moves the financial record

### GlobalConfig parameterization with fail-fast
- Five lookups happen at script startup: 4 GlobalConfig values + runtime-resolved TC_ARCH tag_id
- All five required — any NULL = fail-fast exit
- `data_type='VARCHAR'` for the four GlobalConfig entries
- `description` column required on every GlobalConfig row (per Section 2.7 standards)

### Exception Log has NO FK to BatchLog
- Mirrors `ShellPurge_ExclusionLog` pattern
- `batch_id` column preserved as audit context only
- Allows exception rows to outlive their originating batch if needed

---

## What Production Sources Look Like (for next session)

Both source scripts retrieved fresh from GitHub during this session and verified:

### Execute-DmArchive.ps1 (production)
- Step 4 materialization uses these exact tables/columns:
  - `cnsmr_accnt_ar_log.cnsmr_accnt_ar_log_id`
  - `cnsmr_accnt_trnsctn.cnsmr_accnt_trnsctn_id`
  - `cnsmr_accnt_pymnt_jrnl.cnsmr_accnt_pymnt_jrnl_id`
  - `cnsmr_accnt_trnsctn` (via cnsmr_accnt_pymnt_jrnl_id, alias `#batch_pmtjrnl_trnsctn_ids`)
  - `hc_encntr.hc_encntr_id`
- Index pattern: `CREATE UNIQUE CLUSTERED INDEX CIX ON #table (column)`
- Step 5 has 117 numbered orders + Phase 1 dynamic UDEF discovery (column='cnsmr_accnt_id')
- Uses inline `Step-Delete` and `Step-JoinDelete` wrapper functions
- Where-clause variables: `$wAcct`, `$wArLog`, `$wTrnsctn`, `$wPmtJrnl`, `$wPmtTrnsctn`, `$wEncntr`, `$wPrgrmPlan`
- Step 6 BIDATA: 4 P→C migrations with three different anonymization column lists:
  - `GenAccountTblC` — full PII set including `ssn`
  - `GenAccPayTblC` and `GenAccPayAggTblC` — share PII list (no ssn)
  - `GenPaymentTblC` — only `is_purged = 'Y'`, `purge_date = GETDATE()`
- `-NoAnonymize` parameter (negation switch) — purge flags always set even when not anonymizing

### Execute-DmShellPurge.ps1 (production)
- Step 3 includes WFAPURGE workgroup resolution + 7 exclusion checks:
  - `cnsmr_pymnt_jrnl`
  - `agnt_crdtbl_actvty` (direct)
  - `agnt_crdtbl_actvty_via_smmry`
  - `agnt_crdt`
  - `bnkrptcy`
  - `schdld_pymnt_smmry`
  - `sspns_unresolved_cross_consumer`
- Note: `dcmnt_rqst` exclusion check is COMMENTED OUT in production (do not include unless re-enabled)
- Step 4 materializes: `#shell_pymnt_instrmnt_ids`, `#shell_pymnt_jrnl_ids`, `#shell_cntct_trnsctn_ids`, `#shell_smmry_ids`, `#shell_ar_log_ids`
- Step 5 has 110 numbered orders + Phase 1 dynamic UDEF discovery (column='cnsmr_id')
- Order 86 is a `Step-Update` (not Step-Delete) — NULLs `cpj.sspns_cnsmr_imprt_trnsctn_id` for resolved cross-consumer suspense (statuses 3, 5, 7, 10)
- Uses inline `Step-Delete`, `Step-JoinDelete`, `Step-Update` wrapper functions
- Where-clause variables: `$wCnsmr`, `$wCntctLog`, `$wInstrmnt`, `$wJrnl`, `$wSmmry`, `$wArLog`

---

## On the Horizon (carry-forward backlog)

These were noted earlier in the broader DmOps workstream and remain pending:

- Fresh clone of crs5_oltp on DM-TEST-APP to resolve performance degradation (PAGEIOLATCH waits from 860+ batches without index maintenance)
- Re-enable shell purge exclusion checks after FK chain validation
- `#shell_ar_log_ids` optimization deployment
- `Invoke-BidataTableMigration` CommandTimeout bump 300s → 900s (not yet deployed)
- ProcessRegistry entry for the new unified script (Pattern 3, time-based with polling)
- After unified script is in place: move `Execute-DmArchive.ps1` to `E:\xFACts-PowerShell\Reference\Execute-DmArchive_AccountLevel.ps1`
- CC page touch-ups (DmOperations.ps1, DmOperations-API.ps1, dm-operations.css, dm-operations.js)
- Documentation page rewrites (dmops.html, dmops-arch.html)
- `.\Generate-DDLReference.ps1 -Execute` to regenerate JSON
- Version bump on DmOps.Archive component via Admin UI

---

## Recommended Approach for Next Session

Start clean. Do not attempt to salvage the script from this session. Pull both production source scripts at session start, verify the agreed Phase 1 deployments are intact, and rebuild from scratch using the production scripts as the verbatim source for materialization SQL, delete sequences, BIDATA migration, and wrapper functions. The infrastructure (table, columns, GlobalConfig entries, FK adjustments) is in place and ready.

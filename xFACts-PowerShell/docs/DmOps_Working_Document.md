# DmOps — Archive & Shell Purge Working Document

Consolidated from planning doc, delete sequence reference, and four session carry-forwards (March 23-26, 2026). This is the single source of truth for the current state of both DmOps components. Replaces all prior carry-forward documents.

---

## 1. What We Built

Two PowerShell-driven processes that permanently delete aged data from `crs5_oltp` (Debt Manager production OLTP database, ~10TB). Both run from FA-SQLDBB via the xFACts orchestrator, targeting any crs5_oltp instance via configuration.

### Execute-DmArchive.ps1 — Account-Level Archive (~1,643 lines)

**Purpose:** Deletes account-level data for consumers tagged `TA_ARCH`, then migrates financial reporting snapshots from BIDATA production tables to static/completed tables.

**Scale:** ~19M tagged accounts, with ongoing daily tagging of newly eligible accounts.

**Batch flow:**
1. Configuration — GlobalConfig (DmOps/Archive), ServerRegistry enable check, schedule mode, abort flag
2. Open Connection — persistent SqlConnection to crs5_oltp
3. Select Batch — find N consumers with TA_ARCH-tagged accounts (no ORDER BY — 2ms)
4. Load Temp Tables — consumer IDs into `#archive_batch_consumers`, expand to tagged accounts via temp table JOIN, load `#archive_batch_accounts`, write ConsumerLog, materialize 5 intermediate ID sets (ar_log, trnsctn, pmtjrnl, pmtjrnl_trnsctn, encntr)
5. Execute Deletions — 109-order FK-validated delete sequence (dynamic UDEFs + account-level tables) with SNAPSHOT isolation, deadlock retry, chunked deletes
6. BIDATA Migration — P→C for 4 Gen table pairs (GenAccount, GenAccPay, GenAccPayAgg, GenPayment), transaction-wrapped with count validation. Post-migration: anonymize PII (when `-NoAnonymize` is not set) and set `is_purged`/`purge_date` flags on all C tables.
7. Finalize — update batch log, session counters, Teams alert on failure via Send-TeamsAlert
8. Loop Check — abort flag, schedule re-check with GlobalConfig batch size refresh, mode transition, or exit

**Key design decisions:**
- Delete sequence hardcoded in script (not registry-driven) — validated by testing, changes require script update
- Pre-materialized intermediate ID temp tables for deep FK chains — 1,846x performance improvement over original approach
- Persistent SqlConnection for entire session — temp tables survive across all operations
- Separate BIDATA connection opened/closed per batch
- Stop-on-failure pattern — `$StopProcessing` flag halts sequence on first table failure
- Dynamic UDEF discovery via `sys.tables` + `sys.columns` at runtime
- Consumer IDs inserted in batches of 900 (SQL Server 1000 VALUES limit)
- Chunked deletes with configurable chunk size (default 5000)
- Account expansion via `#archive_batch_consumers` temp table JOIN (replaces IN clause — eliminates 50K query plan resource limit)
- Anonymization defaults to ON; use `-NoAnonymize` switch for testing with full PII visible
- GlobalConfig `batch_size` and `batch_size_reduced` re-read from database on every loop iteration (allows in-flight tuning without restart)

### Execute-DmShellPurge.ps1 — Shell Consumer Purge (~1,338 lines)

**Purpose:** Removes orphaned consumer records ("shells") — consumers with no remaining `cnsmr_accnt` records. These accumulate from account archiving and consumer merge operations.

**Scale:** Test environment fully cleared — 6.4M shells purged to completion. Only ~134K exclusion list consumers remain. Production has a similar profile.

**Batch flow:**
1. Configuration — GlobalConfig (DmOps/ShellPurge), ServerRegistry enable check, schedule mode, abort flag
2. Open Connection — persistent SqlConnection to crs5_oltp
3. Select Shell Consumers — resolve WFAPURGE wrkgrp_id (cached), load exclusion log into temp table (cached per session), select candidates not in exclusions and not in cnsmr_accnt, validate batch against exclusion tables, log new discoveries
4. Load Temp Tables — core consumer ID table + 4 pre-materialized intermediate ID sets (pymnt_instrmnt, pymnt_jrnl, cntct_trnsctn_log, schdld_pymnt_smmry)
5. Execute Deletions — 58-order delete sequence (dynamic UDEFs + consumer-level tables from Matt's sp_Delete_EmptyShell_Consumers)
6. Finalize — update batch log, session counters, Teams alert on failure via Send-TeamsAlert
7. Loop Check — abort flag, schedule re-check with GlobalConfig batch size refresh, mode transition, or exit

**Key design decisions:**
- Delete sequence derived from Matt's proc (authoritative for shell definition), not vendor archive proc's Phase 3/4
- Exclusion log pattern — consumers with data in tables not covered by the delete sequence are excluded rather than partially deleted. Seeded once, cached per session in temp table, discovered incrementally.
- WFAPURGE workgroup as sole selection criteria — DM nightly job controls eligibility, decouples criteria from script
- `crdtr_srvc_evnt` moved to order 12 (before `cnsmr_accnt_ar_log`) to satisfy FK dependency discovered during testing
- Pre-delete UPDATEs (U1-U5) skipped — no FK enforcement from `cnsmr_pymnt_btch` or `crdtr_invc` back to `cnsmr`, orphaned references acceptable for hard-delete
- `dcmnt_rqst` excluded from delete sequence — no FK to `cnsmr`, 107M rows, left as orphaned historical records
- Suspense exclusion (`sspns_trnsctn_cnsmr_idntfr`) toggleable via GlobalConfig `exclude_suspense`
- GlobalConfig `batch_size` and `batch_size_reduced` re-read from database on every loop iteration (allows in-flight tuning without restart)
- **Production validated:** 6.4M shells purged across ~4,800 batches with 1 early failure (FK ordering fix applied). Zero failures after fix.

---

## 2. Performance History

### Account-Level Archive Optimization Progression

| Run | Consumers | Accounts | Rows | Duration | Per-Consumer |
|-----|-----------|----------|------|----------|-------------|
| Original script | 1 | ~8 | ~few | ~120s | 120s |
| Persistent connection | 10 | 25 | 1,174 | 187s | 18.7s |
| + 23 FK indexes on cnsmr_accnt | 100 | 219 | 14,902 | 391s | 3.9s |
| + Existence check elimination | 100 | 193 | 13,128 | 215s | 2.15s |
| + 10 more FK indexes (trnsctn + ar_log) | 100 | 193 | 13,128 | ~215s | ~2.15s |
| + Pre-materialized temp tables + 23 more FK indexes | 100 | 179 | 12,055 | 64.9s | 0.65s |
| Batch of 1,000 | 1,000 | 3,040 | 202,944 | 109.7s | 0.11s |
| Batch of 10,000 | 10,000 | 23,063 | 1,513,875 | 649.1s | 0.065s |
| + Batch selection optimization (ORDER BY removal) | 100 | 165 | 10,995 | 9.6s | 0.096s |

**Total improvement: 1,846x** (120s → 0.065s per consumer at 10K batch).

### Account-Level Archive Batch Size Scaling (DM-TEST-APP)

| Batch Size | Batches | Avg Consumers | Avg Accounts | Avg Rows | Avg Duration | ms/Consumer | Rows/Consumer |
|-----------|---------|---------------|--------------|----------|-------------|-------------|---------------|
| 100 | 784 | 100 | 208 | 12,897 | 10.7s | 106.8 | 129.0 |
| 1,000 | 1 | 1,000 | 2,205 | 147,099 | 63.8s | 63.8 | 147.1 |
| 10,000 | 15 | 10,000 | 19,985 | 1,304,601 | 768.2s | 76.8* | 130.5 |
| 25,000 | 12 | 25,000 | 54,706 | 3,496,931 | 991.7s | 39.7 | 139.9 |
| 50,000 | 1 | 50,000 | 102,949 | 6,666,398 | 2,701.7s | 54.0 | 133.3 |

*10K average inflated by console output overhead before log fix — true cost ~86ms based on clean batches.

**Sweet spot: 25,000 consumers per batch.** 50K shows regression (54ms vs 39.7ms per consumer) likely due to temp table materialization overhead. 25K clears ~3.5M rows in ~16.5 minutes.

**50K IN clause ceiling (resolved):** At 50K consumers, the account expansion query's `IN ($consumerIdList)` clause exceeded SQL Server's query plan compiler limits ("ran out of internal resources"). Refactored to use `INNER JOIN #archive_batch_consumers` temp table — eliminates the ceiling entirely. The 50K regression is performance-based, not a hard limit.

### Shell Purge Batch Size Scaling (DM-TEST-APP)

| Batch Size | Batches | Avg Consumers | Avg Rows | Avg Duration | ms/Consumer | Rows/Consumer |
|-----------|---------|---------------|----------|-------------|-------------|---------------|
| 100 | 1,608 | 99 | 496 | 3.7s | 44.7 | 5.0 |
| 1,000 | 3,135 | 991 | 5,118 | 11.7s | 12.0 | 5.2 |
| 10,000 | 14 | 10,000 | 46,183 | 34.5s | 3.4 | 4.6 |
| 25,000 | 3 | 25,000 | 106,278 | 75.5s | 3.0 | 4.3 |
| 50,000 | 48 | 49,441 | 223,850 | 112.0s | 2.3 | 4.5 |

**Sweet spot: 50,000 consumers per batch.** Per-consumer cost continues to drop through 50K with no issues. Shell purge uses temp table joins throughout (no IN clause), so no query plan limits.

### Shell Purge Full Test Run (DM-TEST-APP)

| Metric | Value |
|--------|-------|
| Total consumers purged | ~6,400,000 |
| Remaining in WFAPURGE | ~134,000 (exclusion list) |
| Total batches | ~4,800 |
| Failed batches | 1 (early, FK ordering fix applied) |
| Status | **Fully cleared** |

---

## 3. Database Objects

### DmOps.Archive Component

| Object | Type | Purpose |
|--------|------|---------|
| `DmOps.Archive_BatchLog` | Table | One row per archive batch — counts, timing, status, bidata_status |
| `DmOps.Archive_BatchDetail` | Table | One row per table operation per batch — delete order, rows, duration, status |
| `DmOps.Archive_ConsumerLog` | Table | One row per account archived — audit trail with bidata_migrated flag |
| `DmOps.Archive_Schedule` | Table | 7×24 weekly schedule grid (0=blocked, 1=full, 2=reduced) |
| `DmOps.Archive_TableRegistry` | Table | Master catalog of crs5_oltp tables with classification and FK ordering (used for initial analysis, not runtime) |
| `dbo.ServerRegistry.dmops_archive_enabled` | Column | Per-server enable flag |

**GlobalConfig entries (DmOps / Archive):** target_instance, bidata_instance, batch_size (25000), batch_size_reduced (100), chunk_size (5000), alerting_enabled (0), archive_abort (0)

### DmOps.ShellPurge Component

| Object | Type | Purpose |
|--------|------|---------|
| `DmOps.ShellPurge_BatchLog` | Table | One row per shell purge batch — counts, timing, status |
| `DmOps.ShellPurge_BatchDetail` | Table | One row per table operation per batch |
| `DmOps.ShellPurge_ConsumerLog` | Table | One row per consumer purged |
| `DmOps.ShellPurge_Schedule` | Table | 7×24 weekly schedule grid |
| `DmOps.ShellPurge_ExclusionLog` | Table | Consumers excluded from purge with reason codes (composite PK: cnsmr_id, exclusion_reason) |
| `dbo.ServerRegistry.dmops_shell_purge_enabled` | Column | Per-server enable flag |

**GlobalConfig entries (DmOps / ShellPurge):** target_instance, batch_size (50000), batch_size_reduced (100), chunk_size (5000), alerting_enabled (0), shell_purge_abort (0), exclude_suspense (1)

### ExclusionLog Seed Results (Production crs5_oltp)

| Exclusion Reason | Consumer Count |
|-----------------|----------------|
| dcmnt_rqst | 69,871 |
| bnkrptcy | 39,784 |
| sspns_trnsctn_cnsmr_idntfr | 9,095 |
| schdld_pymnt_smmry | 5,639 |
| agnt_crdtbl_actvty_via_smmry | 5,428 |
| agnt_crdtbl_actvty | 494 |
| cnsmr_pymnt_jrnl | 87 |

**Total excluded:** 116,174 distinct consumers (130,398 exclusion rows). **Eligible:** 6,410,855 shells.

### Infrastructure Fix

`UQ_GlobalConfig_setting` updated from `(module_name, setting_name)` to `(module_name, category, setting_name)` to support same setting names across different categories within a module.

---

## 4. FK Supporting Indexes (crs5_oltp)

### For cnsmr_accnt DELETE (41 indexes — Archive script)

All deployed to both DM-TEST-APP and production with `FA_ncl_idx_for_arc_*` naming convention.

**23 indexes for cnsmr_accnt children:**
bal_rdctn_plan, ca_case_accnt_assctn, cb_rpt_assctd_cnsmr_data, cb_rpt_base_data, cb_rpt_emplyr_data, cb_rpt_rqst_btch_log, cnsmr_accnt_frwrd_rcll, cnsmr_accnt_rehab_dtl, cnsmr_accnt_rehab_pymnt_tier, cnsmr_accnt_rndm_nmbr, cnsmr_accnt_spplmntl_info, cnsmr_accnt_srvc_rqst, cnsmr_accnt_strtgy_log, cnsmr_accnt_wrkgrp_assctn, cnsmr_chck_rqst, crdt_Bureau_Trnsmssn, invc_crrctn_trnsctn, invc_crrctn_trnsctn_stgng, job_file, schdld_pymnt_accnt_dstrbtn, sttlmnt_offr_accnt_assctn, tax_jrsdctn_accnt_assctn, UDEFAccount_Notes_1

**5 indexes for cnsmr_accnt_trnsctn children:**
invc_crrctn_trnsctn, rcvr_fnncl_trnsctn_exprt_dtl, rcvr_sttmnt_of_accnt_dtl, wash_assctn (×2 — nsf_trnsctn_id + pymnt_trnsctn_id)

**5 indexes for cnsmr_accnt_ar_log children:**
agncy_accnt_trnsctn, agncy_accnt_trnsctn_stgng, agnt_crdtbl_actvty, cnsmr_task_itm_cnsmr_accnt_ar_log_assctn, hc_prgrm_plan_trnsctn_log

**6 indexes for dcmnt_rqst children (fixed the "undeletable" table):**
cnsmr_chck_trnsctn, dcmnt_rqst (self-ref dcmnt_re_rqst_id), dcmnt_rqst_edit_data, pymnt_schdl_notice_rqst_assctn, schdld_pymnt_instnc, schdld_pymnt_smmry

**2 indexes for cnsmr_chck_rqst children (added March 26):**
cnsmr_accnt_bckt_chck_rqst (on cnsmr_chck_rqst_id), cnsmr_chck_btch_log (on cnsmr_chck_rqst_id)

### For cnsmr DELETE (25 indexes — ShellPurge script)

All deployed to both DM-TEST-APP and production with `FA_ncl_idx_for_arc_*` naming.

asst, bal_rdctn_plan, ca_case, cb_rpt_assctd_cnsmr_data (×2 — cnsmr_id + cnsmr_accnt_pri_ownr_id), cb_rpt_base_data, cb_rpt_emplyr_data, cb_rpt_rqst_dtl, cmpgn_trnsctn_log, cnsmr_accnt_spplmntl_info, cnsmr_chck_rqst, cnsmr_crdt, cnsmr_pymnt_mthd, cnsmr_Rvw_rqst, invc_crrctn_trnsctn, invc_crrctn_trnsctn_stgng, jdgmnt, job_file, job_skptrc_cnsmr, job_skptrc_instnc_log, sttlmnt_offr, UDEFLNSkptrMotorVehInfo, UDEFTest, UDEFVUMC, usr_rmndr (usr_rmndr_cnsmr_id)

---

## 5. Key Discoveries & Decisions

### dcmnt_rqst Is Deletable (But We're Not Deleting It)

The old DBA gave up on `dcmnt_rqst` (107M rows) due to PAGEIOLATCH_SH buffer saturation. Root cause: 6 child tables had no supporting FK index, causing full table scans during every DELETE's FK validation. Adding the 6 indexes made deletes fast. However, for shell purge we chose not to delete from `dcmnt_rqst` — no FK back to `cnsmr`, so orphaning is safe. Consumers with `dcmnt_rqst` data are excluded from the shell purge via the ExclusionLog.

### Pre-Delete UPDATEs Not Needed

The vendor archive proc and old DBA's shell proc included 5 UPDATE statements (U1-U5) to flag records as archived in `lnkd_cnsmr`, `cnsmr_pymnt_btch`, and `crdtr_invc`. These are artifacts of the vendor's soft-archive (transfer to archive database) approach. For hard-delete: no FK enforcement from these tables back to `cnsmr` (confirmed via sys.foreign_keys query), so orphaned references are acceptable.

### cnsmr_accnt_ownrs Drives App Visibility

Deleting from `cnsmr_accnt_ownrs` makes accounts disappear from the DM application GUI even though `cnsmr_accnt` records still exist. Discovered during first failed test run — consumers appeared to have no accounts in the app. This is by design in the delete sequence (ownrs deleted before cnsmr_accnt).

### Dummy Consumers in WFAPURGE

~4-5 consumers with ~40K accounts are parked in the WFAPURGE workgroup as error-correction holding tanks (erroneous data loads reassigned here). Not shells — they have accounts deliberately assigned. The candidate query's LEFT JOIN naturally excludes them. Not tracked in ExclusionLog.

### crdtr_srvc_evnt FK Ordering Fix

`crdtr_srvc_evnt` has an FK on `cnsmr_accnt_ar_log_id`. Matt's proc had it after `cnsmr_accnt_ar_log` in the sequence, causing FK violations. Fixed by moving it to order 12 (before `cnsmr_accnt_ar_log` at 13). Discovered on batch 4 of first 1000-consumer test.

### cnsmr_chck_rqst FK Chain (Added March 26)

`cnsmr_chck_rqst` has FK on `cnsmr_accnt_id` — was missing from archive delete sequence. Discovered at batch 359 after 256 successful batches (batch #63 of the session). Two child tables: `cnsmr_accnt_bckt_chck_rqst` and `cnsmr_chck_btch_log`. Fix: added orders 106 (bckt_chck_rqst), 107 (btch_log), 108 (chck_rqst) before cnsmr_accnt at 109. Two supporting indexes deployed. Production table counts are tiny (55 and 6 rows).

### Transaction Log Not a Concern

Production crs5_oltp has a 2TB transaction log file with only 25GB used (1.2%). Log backups every 15 minutes. The chunked delete pattern (5000 rows per DELETE) generates steady, manageable log volume. No special log management needed.

### Console Output Performance Impact

Writing per-account detail to console/log file added measurable overhead at scale. At 50K consumers the console output alone added ~5 minutes per batch. Commented out the per-account loop; summary count retained. Full detail is captured in Archive_ConsumerLog table.

### IN Clause Query Plan Limit

At 50,000 consumer IDs, the account expansion query's `IN ($consumerIdList)` exceeded SQL Server's query plan compiler resource limits. Refactored to `INNER JOIN #archive_batch_consumers` temp table, eliminating the ceiling. The temp table pattern (already used by shell purge) scales without limit.

---

## 6. BIDATA Reporting Tables

The archive process preserves financial reporting data by migrating it from production to static tables before deleting the source records.

| P Table (Production) | C Table (Static) | Key | Purpose |
|----------------------|-------------------|-----|---------|
| `GenAccountTblP` | `GenAccountTblC` | `cnsmr_accnt_id` | Account demographics + status snapshot |
| `GenAccPayTblP` | `GenAccPayTblC` | `cnsmr_accnt_id` + `pmt_loc` | Account + payment detail combined |
| `GenAccPayAggTblP` | `GenAccPayAggTblC` | `cnsmr_accnt_id` | Account + aggregated payment summary |
| `GenPaymentTblP` | `GenPaymentTblC` | `pmt_loc` + `cnsmr_accnt_id` | Individual payment transactions |

- P tables rebuilt nightly from OLTP in BIDATA build (1:00 AM, truncate + full reload from crs5_oltp)
- C tables are permanent — purged records preserved for reporting
- P and C tables fronted by UNION views — reports read from views, see both live and archived data
- Migration is INSERT INTO C SELECT * FROM P, DELETE FROM P, transaction-wrapped with count validation
- Post-migration: PII anonymization (default ON, `-NoAnonymize` to disable) + `is_purged`/`purge_date` flag updates on all 4 C tables

### Anonymization (Wired March 26)

When anonymization is active (default), the following PII columns are set to `'Y'` on GenAccountTblC, GenAccPayTblC, GenAccPayAggTblC after P→C migration:

`first_name`, `last_name`, `middle_name`, `name_prefix`, `name_suffix`, `ssn`, `cnsmr_idntfr_ssn_txt`, `commericial_name`, `regarding`, `city`, `county`, `address1`, `address2`, `address3`, `zip_code`, `state`, `patient_city`, `patient_address`, `patient_state`, `patient_zip`, `patient_first_name`, `patient_last_name`, `cnsmr_idntfr_drvr_lcns_txt`, `cnsmr_idntfr_drvr_lcns_issr_txt`

Date columns set to NULL: `patient_dob`, `cnsmr_brth_dt`

All 4 C tables receive: `is_purged = 'Y'`, `purge_date = GETDATE()`

GenPaymentTblC has no PII columns — receives only purge flags.

Anonymization failure is logged but does not fail the batch — data is migrated, just not scrubbed.

---

## 7. PENDING

### FK Dependency Analysis — Required vs Optional Deletions (PRIORITY — Next Session)

**Background:** The current delete sequences (109 steps for archive, 58 for shell purge) were derived from vendor and internal procedures designed for a soft-archive (move to second database) model. Our process is a hard delete. Many tables in the sequences may have no FK constraint requiring their deletion before the terminal record can be removed — they were included because the vendor proc moved everything, not because SQL Server requires it.

**Testing data supports this:** Across all testing (800+ archive batches, 4,800+ shell purge batches), 72 of 109 archive steps and 59 shell purge steps have never deleted a single row. Roughly two-thirds of the work the scripts do is existence checks that always return zero.

**Goal:** For every table in both delete sequences, verify whether an FK chain exists back to the terminal table (`cnsmr_accnt` for archive, `cnsmr` for shell purge). Tables with no FK dependency are candidates for removal from the sequence — their data would remain as orphaned historical records, preserving reporting value.

**Method:**
1. Query `sys.foreign_keys` to map every table in both delete sequences to its FK chain back to the terminal table
2. Cross-reference with the "never touched" data from BatchDetail tables
3. Produce a three-column classification: table name, FK status (REQUIRED/OPTIONAL), data status (HAS_DATA/NEVER_TOUCHED)
4. Tables that are OPTIONAL + NEVER_TOUCHED are immediate comment-out candidates
5. Tables that are OPTIONAL + HAS_DATA go to Matt and Finance for the business decision
6. Implementation: comment out OPTIONAL steps in the script (preserves ordering for easy re-enablement)

**Archive_TableRegistry evolution:** The registry table was originally built for delete sequence analysis and classification, then became "obsolete" when the sequence was hardcoded. It now has a new permanent role: the authoritative FK chain reference for the delete sequence design. New columns to add:
- `fk_chain_status` — REQUIRED (FK enforced, must delete), OPTIONAL (no FK, can orphan), NONE (not in any delete sequence)
- `fk_terminal_table` — which terminal table the FK chain leads to (`cnsmr_accnt`, `cnsmr`, or NULL)
- `in_archive_sequence` / `in_shell_sequence` — whether the table is currently in each delete sequence

This transforms the registry from a one-time analysis artifact into the permanent reference for why each table is or isn't in the sequence. When DM upgrades introduce new tables, the registry is where you look: does the new table have an FK chain to the terminal table? If yes, add it to the sequence. If no, ignore it.

**Benefits:**
- Fewer DELETEs per batch = faster throughput
- Historical data preserved for direct DM reporting (operational costs, payment history, correspondence records)
- Reduced risk — fewer tables touched per batch = fewer failure points
- Already proven safe by `dcmnt_rqst` precedent (107M orphaned rows, no issues)

**Decision required before production:** Which OPTIONAL tables should stay deleted vs orphaned. This is a business decision, not a technical one. The script handles either approach — it's just a matter of which Step-Delete calls are active.

**Preliminary findings:** `dcmnt_rqst` (313K blocked shells) and `cnsmr_pymnt_jrnl` (127K blocked shells) have no FK back to `cnsmr`. Both are currently exclusion reasons in the shell purge but may be candidates for removal from the exclusion checks entirely — allowing shells to be deleted while orphaning the historical records. `dcmnt_rqst` contains operational correspondence costs; `cnsmr_pymnt_jrnl` contains payment history. Business review pending with Matt and Finance/Accounting.

### Execute-DmArchive.ps1 Script Changes (Session: March 28, 2026)

**Delete sequence overhaul (Phase 2 replacement):**
- Full renumber from 1 (previously started at 7 after UDEF refactor left a gap)
- 11 new FK-required tables added (identified via `sys.foreign_keys` recursive FK chain walk):
  - `tax_jrsdctn_trnsctn` (2 passes: via `cnsmr_accnt_trnsctn` for 914K rows + via `crdtr_trnsctn` FK for 794 rows — mutually exclusive data paths)
  - `bal_rdctn_plan_stpdwn` + `bal_rdctn_plan` (0 rows, FK safety)
  - `cnsmr_cntct_addrs_log` + `cnsmr_cntct_phn_log` + `cnsmr_cntct_email_log` (account-level ar_log entries only — consumer-level handled by shell purge)
  - `agnt_crdtbl_actvty_spprssn` (0 rows, FK safety)
  - `cnsmr_task_itm_cnsmr_accnt_ar_log_assctn` (0 rows, FK safety)
  - `sspns_cnsmr_accnt_bckt_imprt_trnsctn` + `sspns_cnsmr_accnt_imprt_trnsctn` (suspense chain — 138K + 354K rows)
  - `sttlmnt_offr_accnt_assctn` (accidentally dropped during UDEF refactor — 6 rows)
- `cnsmr_accnt_ar_log` safety re-delete added at order 115 (immediately before terminal) — catches concurrent DM activity during batch window
- `$wPrgrmPlan` variable moved to WhereClause variable block with other `$w*` variables
- Total sequence: 116 numbered steps + dynamic UDEFs, terminal `cnsmr_accnt` at order 116

**Concurrency issue discovered:** At 25K consumer batches (~8 minute execution), DM application and overnight jobs write new `cnsmr_accnt_ar_log` entries for accounts in the batch between step 64 (ar_log delete) and step 116 (terminal). Caused FK violation on batch 850 (25K consumers, 4,247 new ar_log rows created during the 8-minute window). Safety re-delete at order 115 resolves this.

**Failed batch reprocessing gap discovered:** `cnsmr_Accnt_Tag` deleted at order 22 and `cnsmr_accnt_ownrs` deleted at order 107 make failed batch accounts permanently invisible — cannot be re-selected by tag, cannot be seen in DM GUI. Accounts become permanent orphans with partially deleted child data. Resolved by BIDATA staging + failed batch retry design (see BIDATA Integrity section).

**Retry logic implemented:**
- Restructured batch loop: failed batch check (`status = 'Failed' AND batch_retry = 0`) runs at the top of every loop iteration, before normal tag-based selection
- Retry path: loads consumers/accounts from `Archive_ConsumerLog` for the failed batch, populates temp tables directly from arrays
- Normal path: unchanged tag-based selection
- Once temp tables are loaded, Step 4 materialization and Steps 5-6 are identical for both paths
- `New-BatchLogEntry` accepts optional `RetryOfBatchId` parameter — immediately marks the original failed batch (`batch_retry = 1, retry_batch_id = @newBatchId`) at retry creation time, unconditionally
- Retry batches logged with `schedule_mode = 'Retry'` and batch summary includes `[retry of batch_id X]` note
- If a retry fails, the loop stops (existing behavior) — next restart finds the retry batch as the new unresolved failure
- Tested against 3 failed batches on DM-TEST-APP: all completed successfully

**Anonymization bug fix:** Shared `$piiSetClause` applied across GenAccountTblC, GenAccPayTblC, and GenAccPayAggTblC, but `ssn` column only exists on GenAccountTblC. Replaced with per-table SET clauses — each table gets its own column list matching its actual schema.

**Duplicate temp table load bug fix:** Normal path was inserting into `#archive_batch_accounts` twice — once inside the account expansion else block (from the restructured Step 4) and once from the original code that wasn't removed during the replacement. Removed the duplicate block.

**Supporting indexes added:**
- `FA_ncl_idx_for_arc_tax_jrsdctn_trnsctn_cnsmr_accnt_trnsctn_id` on `tax_jrsdctn_trnsctn(cnsmr_accnt_trnsctn_id)` — soft-link column, no FK, was causing 600s timeout
- `FA_ncl_idx_for_arc_tax_jrsdctn_trnsctn_crdtr_trnsctn_id` on `tax_jrsdctn_trnsctn(crdtr_trnsctn_id)` — FK column, no existing index
- `FA_ncl_idx_for_arc_crdtr_invc_sctn_trnsctn_dtl_tax_jrsdctn_trnsctn_id` on `crdtr_invc_sctn_trnsctn_dtl(tax_jrsdctn_trnsctn_id)` — FK column, no existing index

**Archive_TableRegistry dropped:** Superseded by `DmOps.OLTP_TableRegistry` (temporary analysis table, not registered). Used for FK dependency analysis to identify the 11 missing tables. Will be dropped once delete sequence changes are finalized.

- [ ] Update Object_Registry description (remove "registry-driven")
- [ ] Update Component_Registry description for DmOps.Archive (remove "and consumer shell cleanup")

### BIDATA Integrity on Batch Failure (Preliminary Design — March 28, 2026)

**Problem:** When a batch fails partway through the delete sequence, child data is deleted from OLTP but `cnsmr_accnt` survives. BIDATA migration is skipped. The 1:00 AM nightly rebuild truncates P tables and regenerates from OLTP — producing degraded financial snapshots (missing balance/transaction data from deleted child tables). Additionally, failed batches cannot be re-selected through normal means because `cnsmr_Accnt_Tag` (deleted at order 22) and `cnsmr_accnt_ownrs` (deleted at order 107) are gone — accounts are invisible to both the selection query and the DM application GUI.

**Hard deadline:** Failed batches must complete (including P→C migration) before the next 1:00 AM BIDATA rebuild. After that rebuild, P rows are regenerated from degraded OLTP data and the clean financial snapshot is lost permanently.

**Constraints:**
- P and C tables are unioned into views — accounts cannot exist in both simultaneously (double-counting)
- P tables are rebuilt nightly from OLTP — any clean P data is overwritten with degraded data after a partial failure
- Accounts must remain in financial reporting at all times (either P or C, never a gap)
- The BIDATA migration can only safely commit to C after the OLTP delete is fully complete
- Failed batch accounts cannot be re-selected via TA_ARCH tag (tags deleted early in sequence)

**Mitigation in place:** Archive schedule blocks processing from 11pm onward, providing a 2-hour buffer before the 1am BIDATA rebuild.

**Preliminary design (two components):**

**1. P Table Staging (safety net):**
- At the START of each batch (before any OLTP deletes), snapshot the 4 P table rows for the batch's accounts into staging tables in BIDATA: `GenAccountTblStaging`, `GenAccPayTblStaging`, `GenAccPayAggTblStaging`, `GenPaymentTblStaging`
- Staging tables mirror P table structures — same columns, transient data
- On successful batch: migrate from staging → C (not P → C), delete from P, clear staging rows
- On failed batch: staging rows persist as the known-good financial snapshot, available for retry regardless of when the next BIDATA rebuild runs
- This eliminates the 1:00 AM deadline as a hard constraint — the staging copy is independent of the P table rebuild cycle

**2. Failed Batch Retry (on script restart):**
- On script start (before normal batch selection), query `Archive_BatchLog` for batches with `status = 'Failed'`
- If found, pull account list from `Archive_ConsumerLog` for the failed batch (cnsmr_id + cnsmr_accnt_id already captured)
- Load `#archive_batch_consumers` and `#archive_batch_accounts` from ConsumerLog data instead of from TA_ARCH tag selection
- Materialize intermediate temp tables (`#batch_ar_log_ids`, etc.) from those accounts — same as normal path
- Run the full delete sequence (most steps will be no-ops since data was already deleted in the failed run)
- On success: migrate from staging → C, clear staging, update batch status
- On failure of retry: stop completely, alert, do NOT proceed to new batches — avoid compounding failures
- New column on `Archive_BatchLog`: `retry_of_batch_id` (BIGINT, NULL) — links retry batch to original failed batch for audit trail

**Open items for implementation:**
- [x] `batch_retry` and `retry_batch_id` columns on `Archive_BatchLog` (deployed)
- [x] Script modification: failed batch check at loop start
- [x] Script modification: ConsumerLog-based temp table loading (retry path)
- [x] CK_Archive_BatchLog_schedule_mode updated to include 'Retry'
- [x] Object_Metadata for new columns and Retry status value
- [x] Testing against 3 failed batches on DM-TEST-APP (all successful)
- [ ] DDL for 4 staging tables in BIDATA
- [ ] Script modification: P table staging before delete sequence
- [ ] Script modification: migrate from staging instead of P on success
- [ ] CC UI: representation of failed + retried batches in execution history

**Documentation blocked by this resolution:**
- **Failure Safety narrative** (arch page section + design notes): Complete failure/recovery story — what happens when a batch fails, what state the data is in, how staging preserves BIDATA integrity, and how retry recovers automatically.
- **Irreversibility and Preservation** (arch page section + design notes): Hard deletes are permanent, but BIDATA C tables preserve the financial snapshot, staging guarantees data integrity through failures, and the ConsumerLog provides a complete audit trail.

### Orchestrator Integration (Design Required)

**Pattern 3 (time-based with polling)** is the intended model — same as BIDATA monitoring. Scheduled at 7am, polls hourly, stops when `last_successful_date` is set for today.

**Open design questions:**
- BIDATA pre-flight check: script should verify `BIDATA.BuildExecution` shows `COMPLETED` for today before starting. If `IN_PROGRESS`, wait. If `FAILED`/`NOT_STARTED`, delay.
- Abort/restart lifecycle: when abort flag is set and script exits, how does the orchestrator know not to retry? Need an `ABORTED` status that sets `last_successful_date` to prevent re-polling.
- UI-triggered launch: "Restart" button in CC should clear abort flag AND immediately launch the script, mimicking orchestrator behavior (create cycle log, task log, set running_count, send engine event). Requires self-registration path in the script for non-orchestrator launches.
- Engine indicators: long-running process visibility. Options: periodic heartbeat events, or derive running state from `Archive_BatchLog` (row with `status = 'Running'` and `batch_end_dttm IS NULL`).
- ProcessRegistry entries for both scripts (not yet created)

### Production Deployment

- [ ] Verify ShellPurge_ExclusionLog seed data against production (already contains production data)
- [ ] Set archive GlobalConfig: target_instance → AVG-PROD-LSNR, bidata_instance → DM-PROD-REP
- [ ] Set shell purge GlobalConfig: target_instance → AVG-PROD-LSNR
- [ ] Enable `dmops_archive_enabled` and `dmops_shell_purge_enabled` on production server
- [ ] Tune schedules for production: Archive 7am-11pm (full evenings/weekends, reduced business hours, blocked overnight). Shell purge similar.
- [ ] `sp_SyncColumnOrdinals` on ServerRegistry (for new columns)
- [ ] Recommended batch sizes: Archive full=25000, reduced=100. Shell purge full=50000, reduced=100.

### CC Page & UI

- [x] DM Operations CC page built (DmOperations.ps1, DmOperations-API.ps1, dm-operations.css, dm-operations.js)
- [x] Lifetime totals with remaining counts (cached from crs5_oltp, subtractive math between refreshes)
- [x] Today stats section
- [x] Execution history accordion (Year → Month → Day)
- [x] Archive/shell purge abort buttons (admin-only, ActionAuditLog)
- [x] Archive/shell purge schedule modals (three-color drag grid: blocked/full/reduced, admin-only)
- [x] Refresh button spin animation (shared `pageRefresh` in engine-events.js, page defines `onPageRefresh` hook)
- [x] API math fix: all 6 aggregate queries (3 archive + 3 shell purge) use CASE WHEN to count only successful batches toward consumer/account/row totals; failed batch counts retained separately for future UI use
- [ ] CC guide page (dmops-cc.html) — deferred until page design stabilizes
- [ ] Exclusion log summary display
- [ ] UI-triggered process launch/restart (dependent on orchestrator integration design)
- [ ] Failed batch tracking display (design TBD)

### Documentation & Registration

- [x] DmOps narrative page (dmops.html) — first pass complete
- [x] DmOps architecture page (dmops-arch.html) — first pass complete
- [ ] Object_Registry / Component_Registry description cleanup
- [ ] Backlog updates
- [ ] Migrate other CC pages to shared `pageRefresh` / `onPageRefresh` pattern (engine-events.js) — DBCC, Server Health, JBoss, Replication, Batch, BIDATA, File, Index, JobFlow, Platform

---

## 8. Design Exploration: Database Size Tracking

Stakeholders keep asking how much smaller crs5_oltp will get from archiving. This is an opportunity to replace the existing ad-hoc growth trend stored procedure with a proper xFACts component for daily database size tracking.

### Concept

**Daily snapshot table** — one row per database per day with scalar summary columns plus a JSON column holding per-table detail.

**Possible structure:**

| Column | Purpose |
|--------|---------|
| snapshot_date | DATE |
| database_id | FK to DatabaseRegistry |
| total_rows | BIGINT |
| total_size_mb | BIGINT — total reserved space |
| data_size_mb | BIGINT — data pages only |
| index_size_mb | BIGINT — index pages only |
| table_detail_json | NVARCHAR(MAX) — per-table breakdown |

**JSON payload** — all tables in the database (~150KB per day for crs5_oltp's 1,529 tables). A year of daily snapshots across multiple databases stays well under 500MB.

**Archive/shell purge impact** becomes a filtered view of the crs5_oltp data — compare JSON snapshots to see per-table deltas over any time range.

### Open Questions

- **Component home:** ServerOps.DataGrowth? ServerOps.DatabaseSize? Database-level monitoring belongs under ServerOps, not DmOps.
- **Scope:** All databases in DatabaseRegistry, or just crs5_oltp initially?
- **JSON content:** Rows + total size, or also data vs index size split per table? Index split explains why deleting rows doesn't shrink the database proportionally.
- **Capture timing:** Early morning after overnight archive/purge runs gives cleanest post-delete picture.
- **Collection method:** Standalone lightweight script on orchestrator schedule. Query `sys.dm_db_partition_stats` joined to `sys.allocation_units`.
- **Historical migration:** Existing growth trend stored procedure has some data. Migrate or start fresh?
- **Archive_TableRegistry reuse:** Already catalogs all crs5_oltp tables with classification. Could serve as the "what to track" master list.
- **CC display:** Growth trend charts, space reclaimed dashboard, per-table before/after. Ties into DM Operations CC page and potentially a broader ServerOps database health page.

---

## 9. Production Timeline Estimate

**Archive:** ~19M tagged accounts across ~9.5M consumers. At 25K consumers per batch (~16.5 minutes per batch):

| Window | Hours/Day | Batch Size | Throughput | Daily Consumers |
|--------|-----------|-----------|------------|-----------------|
| Weekday full (7-8am, 6-11pm) | 6h | 25,000 | ~22 batches | ~550K |
| Weekday reduced (8am-6pm) | 10h | 100 | ~3,360 batches | ~336K |
| Weekend full | 14h | 25,000 | ~51 batches | ~1,275K |
| Weekend reduced | 2h | 100 | ~672 batches | ~67K |

**Weekly estimate:** ~7.1M consumers/week. **Backlog clearance: ~2 weeks** (conservative: 3-4 weeks allowing for failures, ramp-up, and cautious initial runs).

**Shell purge:** Follows archive. As accounts are archived, new shells accumulate. Shell purge at 50K batch size processes ~367 consumers/second. Expected to keep pace with archive output easily.

**Target production start:** Weekend of March 28-29, 2026.

---

## 10. Infrastructure Changes (Session: March 26, 2026)

### xFACts-Helpers.psm1

- `Get-CRS5Connection` — new optional `-TargetInstance` parameter. When target doesn't match AGListenerName, routes directly to standalone instance (non-AG). When target matches or is omitted, uses existing AG-aware read/write split.
- `Invoke-CRS5ReadQuery` / `Invoke-CRS5WriteQuery` — new optional `-TargetInstance` parameter (passes through to `Get-CRS5Connection`).
- `Get-RemainingCounts` — new function + `$script:DmOpsRemainingCache`. Queries crs5_oltp for TA_ARCH account count and WFAPURGE consumer count. Cached 60 minutes. Target-instance-aware via GlobalConfig.
- `AGListenerName` GlobalConfig entry added under `Shared` module — replaces hardcoded `AVG-PROD-LSNR` fallback.
- `Get-RemainingCounts` added to `Export-ModuleMember` list.

### Control Center Files (New)

| File | Destination | Purpose |
|------|------------|---------|
| `DmOperations.ps1` | `scripts\routes\` | Page controller |
| `DmOperations-API.ps1` | `scripts\routes\` | API endpoints (lifetime totals, today, execution history, schedules, abort) |
| `dm-operations.css` | `public\css\` | Page styles |
| `dm-operations.js` | `public\js\` | Client-side logic |

### Documentation Pages (Updated)

| File | Destination | Status |
|------|------------|--------|
| `dmops.html` | `public\docs\pages\` | First pass complete (replaces stub) |
| `dmops-arch.html` | `public\docs\pages\arch\` | First pass complete (replaces stub) |

---

## 11. Version Bumps

### Session: March 25, 2026

**Module: DmOps → Component: DmOps.Archive**
`Refactored Teams alert from sp_QueueAlert to Send-TeamsAlert with alerting_enabled GlobalConfig check. Removed ORDER BY from batch selection query (49s to 2ms). Added AlertingEnabled script-level state variable and config extraction. Updated Execute-DmArchive.ps1 Object_Metadata description (removed registry-driven reference). Added data_flow, design_notes, relationship_notes enrichment for Execute-DmArchive.ps1. Added common queries for Archive_BatchLog and Archive_ConsumerLog.`

**Module: DmOps → Component: DmOps.ShellPurge**
`Initial build. Created ShellPurge_BatchLog, ShellPurge_BatchDetail, ShellPurge_ConsumerLog, ShellPurge_Schedule, ShellPurge_ExclusionLog tables with full DDL, indexes, constraints, and seed data. Added ServerRegistry.dmops_shell_purge_enabled column. Added 7 GlobalConfig entries. Created Execute-DmShellPurge.ps1 with exclusion log pattern, 58-step consumer-level delete sequence, schedule-aware batch loop, full audit trail logging, and Send-TeamsAlert integration. Full Object_Metadata baselines, column descriptions, status values, data_flow, design_notes, relationship_notes, and common queries for all objects. Seeded ExclusionLog with 116K excluded consumers across 7 exclusion reasons.`

**Module: Engine → Component: Engine.SharedInfrastructure**
`Fixed UQ_GlobalConfig_setting unique constraint — added category column to support same setting_name across different categories within a module.`

### Session: March 26, 2026

**Module: DmOps → Component: DmOps.Archive**
`Added cnsmr_chck_rqst FK chain to delete sequence (orders 106-108: cnsmr_accnt_bckt_chck_rqst, cnsmr_chck_btch_log, cnsmr_chck_rqst) with 2 supporting indexes. Refactored account expansion from IN clause to temp table JOIN (eliminates 50K query plan limit). Added anonymization/purge flag wiring: post-migration UPDATE sets PII columns to 'Y' and is_purged/purge_date on all C tables. Default ON; -NoAnonymize switch for testing. In-flight GlobalConfig re-read for batch_size/batch_size_reduced in loop continuation. Removed per-account console output (commented out, summary count retained).`

**Module: DmOps → Component: DmOps.ShellPurge**
`In-flight GlobalConfig re-read for batch_size/batch_size_reduced in loop continuation.`

**Module: Engine → Component: Engine.SharedInfrastructure**
`Added AGListenerName to GlobalConfig (Shared module). Enhanced Get-CRS5Connection with optional -TargetInstance parameter for AG vs direct routing. Added -TargetInstance passthrough to Invoke-CRS5ReadQuery and Invoke-CRS5WriteQuery. Added Get-RemainingCounts function with 60-minute cached query for DmOps remaining counts.`

**Module: ControlCenter → Component: ControlCenter.DmOperations**
`Initial build. DM Operations CC page with lifetime totals (cached remaining counts with subtractive math), today stats, execution history accordion (Year/Month/Day), abort buttons with ActionAuditLog, three-state schedule modals (blocked/full/reduced drag-to-paint). API endpoints: lifetime-totals, today, execution-history, archive/shellpurge schedules, schedule update-batch, abort toggle.`

### Session: March 28, 2026

**Module: DmOps → Component: DmOps.Archive**
`Delete sequence overhaul: full renumber from 1 (118 steps). Added 11 FK-required tables identified via sys.foreign_keys recursive chain walk: tax_jrsdctn_trnsctn (two-pass — cnsmr_accnt_trnsctn + crdtr_trnsctn paths, with crdtr_invc_sctn_trnsctn_dtl passes 3-4 preceding it), bal_rdctn_plan_stpdwn, bal_rdctn_plan, cnsmr_cntct_addrs_log, cnsmr_cntct_phn_log, cnsmr_cntct_email_log, agnt_crdtbl_actvty_spprssn, cnsmr_task_itm_cnsmr_accnt_ar_log_assctn, sspns_cnsmr_accnt_bckt_imprt_trnsctn, sspns_cnsmr_accnt_imprt_trnsctn, sttlmnt_offr_accnt_assctn. Added cnsmr_accnt_ar_log safety re-delete at order 117. Added 3 supporting indexes for tax_jrsdctn chain. Failed batch retry logic: restructured batch loop with ConsumerLog-based reprocessing, batch_retry and retry_batch_id columns on Archive_BatchLog, CK constraint updated for Retry schedule_mode. Fixed anonymization bug (per-table SET clauses replacing shared clause — ssn only on GenAccountTblC). Fixed duplicate #archive_batch_accounts load.`

**Module: ControlCenter → Component: ControlCenter.DmOperations**
`Refresh button spin animation via shared pageRefresh in engine-events.js (DM Operations page uses onPageRefresh hook). API math fix: all 6 aggregate queries (3 archive + 3 shell purge) wrapped with CASE WHEN status = Success for consumer/account/row/duration SUMs — failed batches no longer inflate totals.`

**Module: ControlCenter → Component: ControlCenter.SharedInfrastructure**
`Added shared pageRefresh function to engine-events.js with spinning animation and onPageRefresh page hook. Guarded with typeof check so pages with existing pageRefresh are unaffected until migrated.`

---

## 12. Reference Files

| File | Location | Purpose |
|------|----------|---------|
| Execute-DmArchive.ps1 | `E:\xFACts-PowerShell\` | Account-level archive script (~1,643 lines) |
| Execute-DmShellPurge.ps1 | `E:\xFACts-PowerShell\` | Shell consumer purge script (~1,338 lines) |
| DmOperations.ps1 | `E:\xFACts-ControlCenter\scripts\routes\` | CC page controller |
| DmOperations-API.ps1 | `E:\xFACts-ControlCenter\scripts\routes\` | CC API endpoints |
| dm-operations.css | `E:\xFACts-ControlCenter\public\css\` | CC page styles |
| dm-operations.js | `E:\xFACts-ControlCenter\public\js\` | CC client-side logic |
| dmops.html | `E:\xFACts-ControlCenter\public\docs\pages\` | Narrative documentation |
| dmops-arch.html | `E:\xFACts-ControlCenter\public\docs\pages\arch\` | Architecture documentation |
| Master_BIDATA_script.sql | Reference | BIDATA build procedures (GenAccount, GenAccPay, GenAccPayAgg, GenPayment) |
| CRS5-Functions-Replacement.ps1 | Session output | Get-CRS5Connection, Invoke-CRS5ReadQuery, Invoke-CRS5WriteQuery replacement block |
| Helpers-DmOpsCache-Insert.ps1 | Session output | Get-RemainingCounts + cache variable insert block |
| Deploy-DmShellPurge-DDL.sql | Prior session output | ShellPurge table/index/config DDL |
| Deploy-DmShellPurge-ObjectMetadata.sql | Prior session output | Baseline Object_Metadata for ShellPurge objects |
| Deploy-DmShellPurge-ObjectMetadata-HrFix.sql | Prior session output | Missing hr01-hr23 column descriptions |
| Deploy-DmOps-ObjectMetadata-Enrichment.sql | Prior session output | Enrichment for both Archive and ShellPurge |
| Seed-ShellPurge-ExclusionLog.sql | Prior session output | One-time exclusion log population |
| xFACts_DM_Operations_Ref.md | Project files | Auto-generated reference documentation for DmOps tables |
| sp_Delete_EmptyShell_Consumers.sql | Matt's proc | Authoritative source for shell delete sequence |
| Archive_Phase2_Replacement.ps1 | Session output (March 28) | Drop-in replacement for Phase 2 delete sequence — 118 steps, 11 new tables |
| Deploy-OLTP_TableRegistry.sql | Session output (March 28) | DDL + population for temporary analysis table (all crs5_oltp tables, FK chains, soft links) |
| DmOps_Table_Catalog_Query.sql | Session output (March 28) | Standalone query version of the catalog analysis (all schemas, corrected row counts) |
| Test-NewArchiveTables-Targeted.sql | Session output (March 28) | Targeted validation script for new table WhereClause subqueries |
| Deploy-BatchLog-RetryColumns.sql | Session output (March 28) | DDL for batch_retry and retry_batch_id on Archive_BatchLog |
| Replacement3_Lines842-995.ps1 | Session output (March 28) | Restructured batch loop with retry logic (replaces Steps 3-4) |

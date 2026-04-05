# BatchOps Module Rebuild Plan

> Forward-looking roadmap for remaining BatchOps implementation: BDL dashboard integration, open batch summary expansion, and open investigations.

**Created:** February 7, 2026
**Last Updated:** April 4, 2026

---

## Completed Work

NB, PMT, and BDL collectors are deployed and operational with full lifecycle tracking, stall detection, and multi-channel alerting. The Control Center Batch Monitoring page provides active batch dashboards and historical views for NB and PMT. Send-OpenBatchSummary covers NB and PMT batches.

For implementation details, refer to the authoritative documentation pages:

| Component | Documentation Page |
|-----------|-------------------|
| NB collector and alerting | [BatchOps - Collect-NBBatchStatus] |
| NB tracking table and status reference | [BatchOps - NB_BatchTracking] |
| PMT collector and alerting | [BatchOps - Collect-PMTBatchStatus] |
| PMT tracking table and status reference | [BatchOps - PMT_BatchTracking] |
| BDL collector and alerting | [BatchOps - Collect-BDLBatchStatus] |
| BDL tracking table and status reference | [BatchOps - BDL_BatchTracking] |
| Open batch summary | [BatchOps - Send-OpenBatchSummary] |
| Status dashboard table | [BatchOps - Status] |
| Batch Monitoring UI | [Control Center - Batch Monitoring] |
| Module overview | [xFACts - BatchOps Module] |

Outstanding bugs, enhancements, and deferred items for NB, PMT, and BDL are tracked in the xFACts Backlog Items list.

---

## Open Investigations

| Item | Notes | Status |
|------|-------|--------|
| DM concurrency caps | Investigate all DM processing thread caps via env_prfl_cnfg_ovrrd and config_item tables. PMT import override currently set to 2 (default 5). Determine caps for NB upload, BDL, and other batch types. Findings impact stall detection logic across all collectors. | Open |
| Notice processing tables | Identify tables for detecting active notice processing. dcmnt_rqst is the main table but in-flight detection needs further research. Needed for Send-OpenBatchSummary expansion. | Open |
| Stuck BDL files | 15 incomplete BDL files identified during initial deployment (April 4, 2026). Several show all partitions completed but file-level status never advanced to IMPORTED. Requires investigation with Matt to determine root cause and whether manual intervention in DM is needed. | Open |

---

## Resolved Investigations (April 4, 2026)

Items originally listed as open that were resolved during the BDL implementation session.

### BDL Grouping Key
**Resolution:** `file_registry_id` is the trackable unit. Partitions (`bdl_prttn_nmbr`) are DM's internal work decomposition — each partition represents approximately 100 operational units. Partitions are not independently tracked; they serve as progress indicators and stall detection signals within a file's lifecycle.

### BDL Batch Concept
**Resolution:** No separate batch header table exists for BDL. `bdl_log` contains two types of rows distinguished by `sub_entty_nm_txt`: file-level rows (`sub_entty_nm_txt IS NULL`) track the overall lifecycle, and partition-level rows (`sub_entty_nm_txt IS NOT NULL`, e.g., CONSUMER_TAG, CONSUMER_PHONE) track individual processing chunks. The `bdl_prttn_flg` column is NOT a reliable discriminator — individual record failures (status 4) also carry `bdl_prttn_flg = 'N'` but have partition numbers and entity types.

### File_Registry Status Codes
**Resolution:** `file_stts_cd` values confirmed: 5 = processed successfully, 6 = failed, 8 = completed/cleaned state. `file_typ_cd` 13 = BDL files. `file_err_msg_txt` contains error details on failures. `file_name_full_txt` contains Sterling's output filename (not the original client filename).

### BDL Record Count and Summary Metrics Source
**Resolution:** Two previously unknown tables discovered during investigation:
- **`file_rgstry_dtl`** — Stores BDL XML file header metadata. `file_rgstry_dtl_rec_ttl_cnt` contains the total record count parsed from `<total_count>` in the XML header. Also contains `btch_idntfr_txt` (batch identifier) and `sndr_idntfr_txt` (sender). Links to `File_Registry` via `file_registry_id`.
- **`file_rgstry_cstm_dtl`** — Stores DM's calculated summary counts as name-value pairs, linked through `file_rgstry_dtl` via `file_rgstry_dtl_id`. Five metrics captured: `Dm_staging_success_count`, `Dm_staging_failed_count`, `Dm_import_processed_count`, `Dm_import_success_count`, `Dm_import_failed_count`. These are populated by DM at or near import completion, not during processing. These values match exactly what DM displays in its BDL logging screen "Custom Details" column.

The staging failed count represents records from the XML that failed validation and were never written to the entity-specific staging tables (`bdl_*_stgng`). It is calculated by DM as `total_record_count - staging_success_count`.

---

## Source System Analysis: BDL

### DM Source Tables (crs5_oltp)

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| bdl_log | Combined status/partition log — file-level rows track lifecycle, partition-level rows track processing chunks | bdl_log_id (PK), file_registry_id, bdl_prttn_nmbr, bdl_prcss_stss_cd, bdl_stgng_cnt, bdl_prcssd_cnt, bdl_log_msg, crtd_dttm, sub_entty_nm_txt, bdl_prttn_flg, bdl_log_src_cd |
| ref_entty_async_stts_cd | Shared async status reference | entty_async_stts_cd → entty_async_stts_val_txt (joined via bdl_prcss_stss_cd) |
| File_Registry | File tracking — common FK across all batch types | File_registry_id (PK), file_name_full_txt, file_crt_dttm, file_stts_cd, file_typ_cd, file_err_msg_txt |
| file_rgstry_dtl | File header metadata — total record count, batch identifier | file_rgstry_dtl_id (PK), file_registry_id (FK), file_rgstry_dtl_rec_ttl_cnt, btch_idntfr_txt, sndr_idntfr_txt |
| file_rgstry_cstm_dtl | DM summary counts — name-value pairs for staging/import metrics | file_rgstry_cstm_dtl_id (PK), file_rgstry_dtl_id (FK), file_rgstry_cstm_dtl_nm, file_rgstry_cstm_dtl_val_txt |

**Important:** File_Registry contains Sterling's OUTPUT filename, not the original client filename. Files from the xFACts BDL Import tool use user-specified filenames (e.g., `xFACts_PHONE_dhirt_20260403_152228.txt`). Files from Sterling ETL pipelines use Sterling naming conventions (e.g., `SENDRIGHT_ACK_CNSMR_TAG.DM.20260404_7887374.BDL.txt`).

### BDL File Lifecycle (Confirmed)

Three distinct lifecycle paths confirmed against historical data:

**Happy path:** `PROCESSING (2) → STAGED (10) → IMPORTED (12)`
- PROCESSING always appears as two file-level rows approximately 1-3 seconds apart (DM internal threading)
- Processing to IMPORTED typically completes in under 10 minutes for normal files, up to ~48 minutes for large files
- After IMPORTED, a scheduled cleanup phase runs: `DELETING (13) → DELETED (14)`. The gap between IMPORTED and DELETING varies from minutes to weeks — cleanup is not part of the import lifecycle

**Stage failure:** `PROCESSING (2) → STAGEFAILED (8)`
- 21 historical occurrences
- Error message stored in `bdl_log.bdl_log_msg` and `File_Registry.file_err_msg_txt`
- Common cause: XML validation failure or unconfigured entity type in DM import metadata

**Import failure:** `PROCESSING (2) → STAGED (10) → IMPORT_FAILED (11)`
- 7 historical occurrences
- File content was parsed and staged successfully but import processing failed
- Some historical cases show a second PROCESSING row before IMPORT_FAILED (DM retry behavior)

### BDL Status Codes (Confirmed)

Status codes from `ref_entty_async_stts_cd`. Investigation confirmed a clean split between file-level and partition-level statuses — no overlap except DELETED (14) which appears at both levels.

**File-level statuses (tracked by collector):**

| Code | Value | Historical Count | Role |
|------|-------|-----------------|------|
| 2 | PROCESSING | 11,124 | In-flight — file picked up (always 2 rows per file) |
| 8 | STAGEFAILED | 21 | **Terminal failure** |
| 10 | STAGED | 5,494 | In-flight — content staged, awaiting import |
| 11 | IMPORT_FAILED | 7 | **Terminal failure** |
| 12 | IMPORTED | 5,421 | **Terminal success** |
| 13 | DELETING | 5,798 | Cleanup (not monitored) |
| 14 | DELETED | 6,249 | Cleanup (not monitored) |
| 15 | DELETE_FAILED | 2 | Cleanup failure (not monitored) |

**Partition-level statuses (used for progress tracking, not individually tracked):**

| Code | Value | Historical Count | Role |
|------|-------|-----------------|------|
| 3 | PROCESSED | 2,433,509 | Partition processing complete |
| 4 | FAILED | 62,601 | Individual record failures within partitions |
| 5 | SUCCESS | 811,448 | Partition success (alternate terminal) |
| 7 | PARTIALLYPROCESSED | 3,665 | Partition partially complete |
| 9 | INVALID | 34,869 | Individual record validation failures |
| 14 | DELETED | 1,164,034 | Partition cleanup |
| 17 | IMPORTING | 1,219,638 | Partition picked up for processing |

**Statuses never observed in BDL data:** 1 (PENDING), 6 (RETRYINITIATED), 16 (CANCELED).

### Partition Row Structure

Each partition generates multiple rows through its own lifecycle within `bdl_log`:

1. **IMPORTING (17)** — partition picked up (`bdl_stgng_cnt = NULL`, `bdl_prcssd_cnt = NULL`)
2. **PROCESSED (3)** with `bdl_log_src_cd = 1` — staging phase complete (`bdl_stgng_cnt` populated, `bdl_prcssd_cnt = NULL`)
3. **PROCESSED (3)** with `bdl_log_src_cd = 3` — import phase complete (`bdl_stgng_cnt` and `bdl_prcssd_cnt` both populated)
4. **DELETED (14)** — cleanup (`bdl_prcssd_cnt` populated)

The `bdl_log_src_cd` column distinguishes staging-phase rows (src_cd = 1) from import-phase rows (src_cd = 3). This is important for accurate count derivation — naive SUM operations produce doubled counts because each partition has two PROCESSED rows.

Within import-phase PROCESSED rows, `bdl_stgng_cnt - bdl_prcssd_cnt` represents records that failed within an otherwise-successful partition. FAILED (4) and PARTIALLYPROCESSED (7) partition rows capture partitions where failures occurred.

---

## NB and PMT Status Code Reference

These tables are retained as the DM ground truth reference. The authoritative documentation for how xFACts uses these codes (terminal detection, completed_status values, alert conditions) is in the NB_BatchTracking and PMT_BatchTracking documentation pages.

### NB Batch Status (Ref_new_bsnss_btch_stts_cd)

| Code | Value | Category |
|------|-------|----------|
| 1 | EMPTY | Initial |
| 2 | UPLOADING | Transitional |
| 3 | UPLOADFAILED | **Failure** |
| 4 | UPLOADED | Transitional |
| 5 | DELETED | **Terminal** |
| 6 | RELEASENEEDED | Transitional |
| 7 | RELEASING | Transitional |
| 8 | RELEASED | Transitional |
| 9 | RELEASEFAILED | **Failure** |
| 10 | ACTIVE | Transitional |
| 11 | PARTIALRELEASED | **Warning** |
| 12 | UPLOAD_WRAP_UP | Transitional |
| 13 | FAILED | **Failure** |
| 14 | GENERATING | Transitional |
| 15 | GENERATED | Transitional |

Collector terminal batch statuses: 5 (DELETED), 13 (FAILED).

### NB Merge Status (ref_cnsmr_mrg_lnk_stts_cd)

| Code | Value | Category |
|------|-------|----------|
| 1 | NONE | Initial |
| 2 | POST_RELEASE_MERGING | Transitional |
| 3 | POST_RELEASE_MERGE_COMPLETE | **Terminal** |
| 4 | POST_RELEASE_LINKING | Transitional (not in use) |
| 5 | POST_RELEASE_LINK_COMPLETE | Terminal (not in use) |
| 6 | POST_RELEASE_PRTL_MRGD_WTH_ERS | **Warning/Terminal** |
| 7 | POST_RELEASE_MERGING_WITH_ERRORS | Transitional |
| 8 | POST_RELEASE_MERGE_CMPLT_WTH_ERS | **Warning/Terminal** |
| 9 | POST_RELEASE_PARTIAL_LINKED | Transitional (not in use) |
| 10 | POST_RELEASE_PARTIAL_MERGED | **Warning/Terminal** |

Collector terminal merge statuses: 3, 5, 6, 8, 10. Linking statuses (4, 5, 9) are not in use at Frost Arnett. If linking is enabled, POST_RELEASE_MERGE_COMPLETE (3) becomes transitional and POST_RELEASE_LINK_COMPLETE (5) becomes the primary success terminal.

### PMT Status (ref_pymnt_btch_stts_cd)

| Code | Value | Path | Category |
|------|-------|------|----------|
| 1 | ACTIVE | Manual | Transitional |
| 2 | RELEASED | Manual | Transitional |
| 3 | INPROCESS | General | Transitional |
| 4 | POSTED | General | **Terminal** |
| 5 | PARTIAL | General | **Warning** (not terminal in xFACts) |
| 6 | FAILED | General | **Failure/Terminal** |
| 7 | ARCHIVED | Manual | **Terminal** (not detected by collector) |
| 8 | NEWIMPORT | Import | Initial |
| 9 | WAITINGFORIMPORT | Import | Transitional |
| 10 | IMPORTING | Import | Transitional |
| 11 | IMPORTFAILED | Import | **Failure/Terminal** |
| 12 | NEWSCHEDULE | Schedule | Initial |
| 13 | CONVERTINGPAYMENTS | Schedule | Transitional |
| 14 | SCHEDULEFAILED | Schedule | **Failure/Terminal** (not detected by collector) |
| 15 | WAITINGFORCONVERSION | Schedule | Transitional |
| 16 | DELETEREQUESTED | Import | Transitional |
| 17 | DELETING | Import | Transitional |
| 18 | WAITINGFORVIRTUAL | Virtual | Transitional |
| 19 | PROCESSINGVIRTUAL | Virtual | Transitional |
| 20 | VIRTUALFAILED | Virtual | **Failure/Terminal** (not detected by collector) |
| 21 | WAITINGTOAUTHORIZE | Authorization | Transitional |
| 22 | AUTHORIZING | Authorization | Transitional |
| 23 | IMPORTWRAPUP | Import | Transitional |
| 24 | POSTWRAPUP | General | Transitional |
| 25 | PENDINGREVERSAL | Reversal | Transitional |
| 26 | PROCESSINGREVERSAL | Reversal | Transitional |
| 27 | REVERSALFAILED | Reversal | **Failure/Terminal** |
| 28 | REVERSALWRAPUP | Reversal | Transitional |
| 29 | PROCESSED | Import | **Terminal** (not detected by collector) |
| 30 | ACTIVEWITHSUSPENSE | Import | **Warning** |
| 31 | PROCESSEDWITHSUSPENSE | Import | **Terminal** (not detected by collector) |

Collector terminal statuses: 4 (POSTED), 6 (FAILED), 11 (IMPORTFAILED), 27 (REVERSALFAILED). Terminal statuses not detected by collector (7, 14, 20, 29, 31) have zero occurrences in historical data.

---

## Phase 4: BDL Collector

| Step | Deliverable | Status |
|------|------------|--------|
| 4a | BDL investigation | **Complete** — lifecycle, status codes, grouping key, data sources all confirmed. See Resolved Investigations section. |
| 4b | BatchOps.BDL_BatchTracking table | **Complete** — 29 columns, deployed with 5,840 historical rows. Object_Registry and full Object_Metadata (baselines, column descriptions, data flow, 7 design notes, 4 status values, 4 queries, 4 relationship notes). |
| 4c | Collect-BDLBatchStatus.ps1 | **Complete** — bulk query pattern matching NB/PMT. Three-step execution (Collect, Update, Evaluate). Partition-based stall detection. Three alert conditions (STAGEFAILED, IMPORT_FAILED, stall). Object_Registry and Object_Metadata. |
| 4d | ProcessRegistry registration | **Complete** — 600-second interval, WAIT mode, dependency group 10, matching NB/PMT. |
| 4e | GlobalConfig settings | **Complete** — 6 rows under BatchOps/BDL category. Alerting disabled for monitoring period. |
| 4f | Send-OpenBatchSummary BDL section | Not started — implement Get-OpenBDLImports function. |
| 4g | Control Center BDL integration | Not started — add BDL section to Batch Monitoring page active and history views. **Next session priority.** |
| 4h | Documentation | Object_Metadata complete. Architecture/narrative/CC guide page updates not started. |

### Additional Completed Items (not in original plan)

| Item | Notes |
|------|-------|
| BatchOps.Status seed row | `Collect-BDLBatchStatus` row added for dashboard proof-of-life. |
| Historical backfill | SQL-based bulk load of 5,840 files. Handles cleanup-only files (inferred IMPORTED status) and ancient orphans (ABANDONED status with alert suppression). |
| System_Metadata version bump | Component: BatchOps — full description of all deliverables. |

### Implementation Notes

**Data source architecture:** The BDL collector reads from five DM source tables in two bulk queries (one for Collect, five for Update). This differs from NB (one header table + one log table) and PMT (one header table + one log table + one journal table) because BDL has no dedicated header table — file metadata is distributed across `bdl_log`, `File_Registry`, `file_rgstry_dtl`, and `file_rgstry_cstm_dtl`.

**Stall detection approach:** Unlike NB (which monitors `new_bsnss_log` for merge activity) and PMT (which switches between `cnsmr_pymnt_btch_log` and `cnsmr_pymnt_jrnl` based on lifecycle phase), the BDL collector uses partition-level rows in `bdl_log` itself as the activity indicator. The max `bdl_log_id` across partition rows for a file serves as the stall detection watermark.

**Cleanup phase exclusion:** The collector excludes DELETING (13), DELETED (14), and DELETE_FAILED (15) from file-level status detection. These are scheduled cleanup operations that run days to weeks after import completion. IMPORTED (12) is the terminal success state for monitoring purposes. Historical files that only had cleanup rows remaining in `bdl_log` were loaded during the backfill with `completed_status = 'IMPORTED'` inferred from the cleanup evidence.

**Source-agnostic collection:** The collector tracks all BDL files regardless of origin: Sterling/IBM ETL pipelines (`SENDRIGHT_*`, `CLIENTS_*`, `DM_ACCNTS_*`, `LINK_DHS_*`, `ACRNT_*`), manual IT imports (`SD-*` filenames), and xFACts BDL Import tool submissions (`xFACts_*` filenames).

---

## Phase 5: Dashboard Enhancements

| Step | Deliverable | Status |
|------|------------|--------|
| 5a | BatchOps Control Center page | Complete for NB and PMT. BDL integration is Phase 4g (next session). |
| 5b | Duration metrics and failure trending | Tracked in backlog as Batch Monitoring cosmetic overhaul. |
| 5c | Notice processing investigation | Open — required for Send-OpenBatchSummary expansion. |

---

## Strategic Vision: File Lifecycle Pipeline

The long-term vision connects three xFACts modules to track a file from receipt to final processing:

```
FileOps                    Sterling (future)              BatchOps
(file received)    →    (file processed/renamed)    →    (file loaded/outcome)
Scan-SFTPFiles             Sterling collector             NB/PMT/BDL collectors
original filename    →    input→output mapping      →    File_Registry filename
```

Sterling provides the filename transformation bridge. Without it, FileOps and BatchOps cannot correlate directly because DM's File_Registry contains Sterling's output filename, not the original client filename.

Within DM, `File_Registry.File_registry_id` is the common FK across all three batch types, enabling correlation of any batch back to its source file entry.

### File_Registry and Cross-Module Correlation

The NB collector already uses File_Registry for upload filename resolution. The BDL collector uses File_Registry for filename capture and `file_rgstry_dtl` / `file_rgstry_cstm_dtl` for record counts and summary metrics.

Broader File_Registry integration (capturing additional data points for lifecycle correlation across FileOps → Sterling → BatchOps) is dependent on the Sterling module buildout and is tracked in the Sterling backlog items.

### BDL Import Tool Cross-Module Integration

BDL files originated from the xFACts BDL Import tool carry a `file_registry_id` returned by the DM API at submission time, stored in `Tools.BDL_ImportLog`. This enables correlation between the import tool (Tools schema) and the monitoring collector (BatchOps schema) via `file_registry_id`. Future enhancement: the BDL collector will write completion status back to `Tools.BDL_ImportLog` for xFACts-originated imports, closing the visibility loop between submission and processing outcome.

---

## Dependencies

| Dependency | Impact | Notes |
|------------|--------|-------|
| Sterling Module | Lifecycle correlation | Without Sterling, cannot map FileOps filenames to BatchOps filenames. BatchOps does not depend on Sterling but the end-to-end lifecycle view does. |
| DM-PROD-REP availability | Collection reliability | All collectors read from secondary replica. Synchronous replication keeps lag negligible. |
| Notice processing investigation | Send-OpenBatchSummary scope | Implementing the Notice section in the summary card depends on identifying notice processing detection tables. |
| DM concurrency cap investigation | Stall detection accuracy | Understanding DM's processing thread caps is required before implementing stall/time-based alerting for any batch type. Tracked in backlog. |

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| BDL structure doesn't fit tracking model | ~~Low~~ | ~~Medium~~ | **Resolved** — investigation confirmed BDL fits the tracking model. `file_registry_id` as grouping key, partition rows for progress, `file_rgstry_dtl`/`file_rgstry_cstm_dtl` for summary counts. |
| Source table schema changes (DM upgrades) | Low | High | Collectors read specific columns, not SELECT *. Document expected schema per collector. |
| DM concurrency caps create false positive stall alerts | Medium | Medium | Full investigation before implementing stall detection. Currently deferred for PMT; BDL uses partition-based stall detection which is less sensitive to concurrency constraints. |
| Stuck BDL files accumulate without auto-resolution | Medium | Low | 15 stuck files identified at initial deployment. Consider adding a `bdl_abandon_days` GlobalConfig setting for automatic ABANDONED classification of ancient incomplete files. |

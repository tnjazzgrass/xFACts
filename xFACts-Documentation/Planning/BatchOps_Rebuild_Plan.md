# BatchOps Module Rebuild Plan

> Forward-looking roadmap for remaining BatchOps implementation: BDL collector, dashboard enhancements, and open investigations.

**Created:** February 7, 2026
**Last Updated:** February 19, 2026

---

## Completed Work

NB and PMT collectors are deployed and operational with full lifecycle tracking, stall detection, and multi-channel alerting. The Control Center Batch Monitoring page provides active batch dashboards and historical views. Send-OpenBatchSummary covers NB and PMT batches.

For implementation details, refer to the authoritative documentation pages:

| Component | Documentation Page |
|-----------|-------------------|
| NB collector and alerting | [BatchOps - Collect-NBBatchStatus] |
| NB tracking table and status reference | [BatchOps - NB_BatchTracking] |
| PMT collector and alerting | [BatchOps - Collect-PMTBatchStatus] |
| PMT tracking table and status reference | [BatchOps - PMT_BatchTracking] |
| Open batch summary | [BatchOps - Send-OpenBatchSummary] |
| Status dashboard table | [BatchOps - Status] |
| Batch Monitoring UI | [Control Center - Batch Monitoring] |
| Module overview | [xFACts - BatchOps Module] |

Outstanding bugs, enhancements, and deferred items for NB and PMT are tracked in the xFACts Backlog Items list.

---

## Open Investigations

Items that require resolution before or during BDL implementation:

| Item | Notes | Status |
|------|-------|--------|
| BDL grouping key | Confirm that file_registry_id + bdl_prttn_nmbr uniquely identifies a BDL operation. Understand how partitions work in practice. | Open |
| BDL batch concept | Does BDL have a concept of "one import job" beyond individual log rows? Need to determine what constitutes a trackable unit. | Open |
| DM concurrency caps | Investigate all DM processing thread caps via env_prfl_cnfg_ovrrd and config_item tables. PMT import override currently set to 2 (default 5). Determine caps for NB upload, BDL, and other batch types. Findings impact stall detection logic across all collectors. | Open |
| Notice processing tables | Identify tables for detecting active notice processing. dcmnt_rqst is the main table but in-flight detection needs further research. Needed for Send-OpenBatchSummary expansion. | Open |
| File_Registry status codes | Pull ref table for file_stts_cd and file_typ_cd to understand file-level status tracking. | Open |

---

## Source System Analysis: BDL

### DM Source Tables (crs5_oltp)

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| bdl_log | Combined batch/log table — no separate header | bdl_log_Id (PK), file_registry_id, bdl_prttn_nmbr, bdl_prcss_stss_cd, bdl_stgng_cnt, bdl_prcssd_cnt, bdl_log_msg, crtd_dttm, sub_entty_nm_txt |
| ref_entty_async_stts_cd | Status reference | entty_async_stts_cd → status description (joined via bdl_prcss_stss_cd) |

**Lifecycle:** TBD — requires investigation against historical data to confirm which transitions actually occur in practice.

**Failure states:** TBD — determine from historical data which failure statuses have actual occurrences.

**Terminal states:** TBD — determine from historical data which statuses represent true terminal states in this environment.

**Note:** No separate batch header table. BDL uses partitions within the log table (bdl_prttn_nmbr, bdl_prttn_flg). Grouping key for "one BDL operation" is TBD — likely file_registry_id + bdl_prttn_nmbr but requires investigation to confirm.

### Common: File_Registry

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| File_Registry | File tracking — common FK across all batch types | File_registry_id (PK), file_name_full_txt, file_name_prcssd_txt, file_stts_cd, file_typ_cd, file_prcssd_dttm, file_err_msg_txt |

**Important:** File_Registry contains Sterling's OUTPUT filename, not the original client filename. Lifecycle correlation from FileOps → BatchOps requires the Sterling module to provide the input→output filename mapping.

### BDL Status Codes

Status codes from ref_entty_async_stts_cd (joined to bdl_log via bdl_prcss_stss_cd). Categories are TBD pending investigation against historical data to confirm which statuses actually occur and which represent terminal states in this environment.

| Code | Value | Category |
|------|-------|----------|
| 1 | PENDING | TBD |
| 2 | PROCESSING | TBD |
| 3 | PROCESSED | TBD |
| 4 | FAILED | TBD |
| 5 | SUCCESS | TBD |
| 6 | RETRYINITIATED | TBD |
| 7 | PARTIALLYPROCESSED | TBD |
| 8 | STAGEFAILED | TBD |
| 9 | INVALID | TBD |
| 10 | STAGED | TBD |
| 11 | IMPORT_FAILED | TBD |
| 12 | IMPORTED | TBD |
| 13 | DELETING | TBD |
| 14 | DELETED | TBD |
| 15 | DELETE_FAILED | TBD |
| 16 | CANCELED | TBD |
| 17 | IMPORTING | TBD |

**Note:** ref_entty_async_stts_cd is a shared async status reference table — confirm whether other DM subsystems use these same codes and whether all 17 codes are relevant to BDL.

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

**Dependent on open investigation items above.**

| Step | Deliverable | Notes |
|------|------------|-------|
| 4a | BDL investigation | Resolve grouping key and batch concept questions. Determine what constitutes a trackable unit in bdl_log. |
| 4b | BatchOps.BDL_BatchTracking table | Design based on BDL's single-table structure. Schema follows NB/PMT pattern adapted for BDL's partition-based model. |
| 4c | Collect-BDLBatchStatus.ps1 | Follow collector pattern with BDL-specific grouping logic. Three-step execution: Collect → Update → Evaluate. |
| 4d | Register in v2 ProcessRegistry | Same pattern as NB/PMT collectors. Interval TBD based on BDL processing frequency. |
| 4e | GlobalConfig settings | Lookback, alerting enabled, alert routing per condition. Following NB/PMT pattern. |
| 4f | Send-OpenBatchSummary BDL section | Implement Get-OpenBDLImports function for pre-maintenance summary card. |
| 4g | Control Center BDL integration | Add BDL to Batch Monitoring page active and history views. |
| 4h | Documentation | Confluence pages for BDL_BatchTracking, Collect-BDLBatchStatus, module page update. |

### Design Considerations

- **Single-table architecture:** BDL has no separate batch header — bdl_log serves as both batch and log table. The tracking table design needs to account for this.
- **Partition-based grouping:** BDL operations may span multiple partitions within a single file_registry_id. The grouping key (file_registry_id + bdl_prttn_nmbr vs. file_registry_id alone) determines whether we track per-partition or per-file.
- **Status reference table:** BDL uses ref_entty_async_stts_cd (shared async status codes), not a BDL-specific reference table. Confirm whether other DM subsystems share these codes.

---

## Phase 5: Dashboard Enhancements

| Step | Deliverable | Status |
|------|------------|--------|
| 5a | BatchOps Control Center page | Complete — active batches, daily summary, and history views for NB and PMT. BDL integration in Phase 4g. |
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

The NB collector already uses File_Registry for upload filename resolution. Broader File_Registry integration (capturing additional data points for lifecycle correlation across FileOps → Sterling → BatchOps) is dependent on the Sterling module buildout and is tracked in the Sterling backlog items.

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
| BDL structure doesn't fit tracking model | Low | Medium | Investigation phase before committing to design. BDL may need a different approach if partitioning is complex. |
| Source table schema changes (DM upgrades) | Low | High | Collectors read specific columns, not SELECT *. Document expected schema per collector. |
| DM concurrency caps create false positive stall alerts | Medium | Medium | Full investigation before implementing stall detection. Currently deferred for PMT; BDL assessment needed. |

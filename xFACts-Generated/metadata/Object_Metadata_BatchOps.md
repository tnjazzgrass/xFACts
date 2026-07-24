# Object_Metadata: BatchOps
Source: dbo.Object_Metadata
Generated: 2026-07-24 04:26:09

## BDL_BatchTracking (Table)

### category #0  [metadata_id: 4077]

BatchOps

### data_flow #0  [metadata_id: 4110]

Collect-BDLBatchStatus.ps1 queries the DM replica for BDL file data from multiple source tables: bdl_log for file-level status and partition progress, File_Registry and Ref_File_Stts_Cd for authoritative terminal state detection, file_rgstry_dtl for record counts, and file_rgstry_cstm_dtl for DM summary metrics. New files are inserted with terminal detection at insert time via File_Registry.file_stts_cd. Incomplete files are updated each polling cycle with current status from both bdl_log (bdl_log_status_code, bdl_log_status) and File_Registry (file_registry_status_code, file_registry_status). The collector writes to BDL_BatchTracking via the AG listener.

### description #0  [metadata_id: 4075]

BDL import lifecycle tracking table. Captures each BDL file from registration through terminal state with partition-based progress tracking, DM summary count capture from file_rgstry_cstm_dtl, and log-based stall detection. Tracks files from all BDL sources including Sterling ETL pipelines, manual IT imports, and xFACts BDL Import tool submissions.

### design_note #1  [metadata_id: 4111]
Title: Single-Table Source with Dual Row Types

BDL has no separate batch header table. bdl_log serves as both status log and partition tracker. File-level rows (sub_entty_nm_txt IS NULL) track processing progress: PROCESSING, STAGED, and optionally IMPORTED. However, bdl_log does not reliably reflect the true terminal state of a file — some files complete processing without DM writing the expected terminal rows. Terminal state is determined exclusively from File_Registry.file_stts_cd (stored as file_registry_status_code), which is the authoritative source DM uses to record file outcomes.

### design_note #2  [metadata_id: 4112]
Title: File-Level Row Identification

File-level rows in bdl_log are identified by sub_entty_nm_txt IS NULL. The bdl_prttn_flg column is not a reliable discriminator because individual record failures (status 4 FAILED) also carry bdl_prttn_flg = N but have partition numbers and entity types. The sub_entty_nm_txt IS NULL filter was validated against the full dataset and produces a clean separation between file lifecycle events and partition processing events.

### design_note #3  [metadata_id: 4113]
Title: Partition-Based Stall Detection

Unlike NB which uses a separate log table (new_bsnss_log) for stall detection, BDL uses the partition-level rows in bdl_log itself. The max bdl_log_id across partition rows serves as the activity indicator. If this value is unchanged between polling cycles, stall_poll_count increments. When new partition rows appear (new max log_id), stall_poll_count and alert_count reset to zero, enabling re-alerting on subsequent stall episodes. This approach detects genuine stalls without false positives from large files that process slowly.

### design_note #4  [metadata_id: 4114]
Title: DM Summary Counts from file_rgstry_cstm_dtl

Record-level success and failure counts are stored by DM as name-value pairs in file_rgstry_cstm_dtl, linked through file_rgstry_dtl via file_registry_id. Five metrics are captured: Dm_staging_success_count, Dm_staging_failed_count, Dm_import_processed_count, Dm_import_success_count, Dm_import_failed_count. These are populated by DM at or near import completion, not during processing. For in-flight files, partition counts provide progress indication until the summary counts become available.

### design_note #5  [metadata_id: 4115]
Title: Total Record Count from XML Header

The total_record_count column comes from file_rgstry_dtl.file_rgstry_dtl_rec_ttl_cnt, which DM populates by parsing the total_count element from the BDL XML file header at registration time. This provides the denominator for completion percentage. The staging_failed_count can be derived as total_record_count minus staging_success_count — records that failed XML validation and were never written to the entity-specific staging tables (bdl_*_stgng).

### design_note #6  [metadata_id: 4116]
Title: Cleanup Phase Not Monitored

BDL files go through a cleanup phase (DELETING status 13, DELETED status 14) after successful import. This cleanup purges staging table data and occurs on a scheduled basis, sometimes days or weeks after import completion. The collector does not monitor the cleanup phase — IMPORTED (12) is treated as the terminal success state. Historical files that only have cleanup rows remaining in bdl_log were loaded during the initial backfill with completed_status IMPORTED inferred from the cleanup evidence.

### design_note #7  [metadata_id: 4117]
Title: Source-Agnostic Collection

The collector tracks all BDL files regardless of origin. Sources include Sterling/IBM ETL pipelines (SENDRIGHT_*, CLIENTS_*, DM_ACCNTS_*, LINK_DHS_*, ACRNT_*), manual IT ticket imports (SD-* filenames), and xFACts BDL Import tool submissions (xFACts_* filenames). The tracking table does not distinguish between sources — all files follow the same lifecycle through bdl_log. The future BDL Import write-back feature will use file_registry_id to correlate xFACts-originated imports with their tracking rows.

### design_note #8  [metadata_id: 4145]
Title: File_Registry-Based Terminal Detection

Terminal state is determined by File_Registry.file_stts_cd (stored as file_registry_status_code) rather than bdl_log status codes. Investigation revealed that bdl_log file-level rows do not reliably reflect the true file outcome: files can complete processing in DM without receiving IMPORTED (12) rows in bdl_log, and files that DM marks as FAILED (file_stts_cd = 6) may still show IMPORTED in bdl_log. File_Registry.file_stts_cd is the single authoritative source DM uses for file lifecycle state. The file_registry_status_code and file_registry_status columns are updated from File_Registry each polling cycle, and completed_dttm is sourced from File_Registry.upsrt_dttm when a terminal status is detected.

### design_note #9  [metadata_id: 4146]
Title: Dual Status Column Naming

Two distinct status sources are tracked on each row. bdl_log_status_code and bdl_log_status reflect the latest file-level entry from bdl_log — used for progress display and partition timing. file_registry_status_code and file_registry_status reflect File_Registry.file_stts_cd — used for authoritative terminal detection and displayed as the primary status in the Control Center. Column names include their source system prefix to prevent confusion between the two.

### module #0  [metadata_id: 4076]

BatchOps

### query #1  [metadata_id: 4122]
Title: Active files with progress
Description: All incomplete BDL files with partition progress, total record count, and stall detection state.

SELECT file_registry_id, file_name, bdl_log_status, entity_type,
        file_registry_status_code, file_registry_status,
        total_record_count, partition_count, partitions_completed,
        stall_poll_count, last_log_dttm,
        DATEDIFF(MINUTE, file_created_dttm, GETDATE()) AS age_minutes
FROM BatchOps.BDL_BatchTracking
WHERE is_complete = 0
ORDER BY file_created_dttm DESC;

### query #2  [metadata_id: 4123]
Title: Recent completions with duration and record counts
Description: Completed BDL files from the last 7 days with processing duration and DM summary counts.

SELECT file_registry_id, file_name, entity_type, completed_status,
       total_record_count, import_success_count, import_failed_count,
       staging_failed_count,
       file_created_dttm, completed_dttm,
       DATEDIFF(MINUTE, processing_started_dttm, completed_dttm) AS total_minutes
FROM BatchOps.BDL_BatchTracking
WHERE is_complete = 1
  AND completed_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY completed_dttm DESC;

### query #3  [metadata_id: 4124]
Title: Stalled files
Description: Incomplete files with active stall counters — partition activity has stopped.

SELECT file_registry_id, file_name, bdl_log_status, entity_type,
        file_registry_status_code, file_registry_status,
        total_record_count, partition_count, partitions_completed,
        stall_poll_count, last_log_dttm,
        DATEDIFF(MINUTE, last_log_dttm, GETDATE()) AS minutes_since_activity
FROM BatchOps.BDL_BatchTracking
WHERE is_complete = 0
  AND stall_poll_count > 0
ORDER BY stall_poll_count DESC;

### query #4  [metadata_id: 4125]
Title: Daily BDL volume summary
Description: Seven-day trend of BDL file volume, outcomes, and total records processed.

SELECT CAST(file_created_dttm AS DATE) AS file_date,
        COUNT(*) AS total_files,
        SUM(CASE WHEN completed_status IN ('PROCESSED', 'PARTIALLY_PROCESSED') THEN 1 ELSE 0 END) AS succeeded,
        SUM(CASE WHEN completed_status IN ('FAILED', 'CANCELED') THEN 1 ELSE 0 END) AS failed,
        SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
        SUM(ISNULL(total_record_count, 0)) AS total_records
FROM BatchOps.BDL_BatchTracking
WHERE file_created_dttm >= DATEADD(DAY, -7, GETDATE())
GROUP BY CAST(file_created_dttm AS DATE)
ORDER BY file_date DESC;

### relationship_note #1  [metadata_id: 4126]
Title: Collect-BDLBatchStatus.ps1

The collector script creates, updates, and completes rows in this table. It also reads incomplete rows during alert evaluation to detect stall conditions and terminal failures. The stall_poll_count and alert_count columns are maintained exclusively by the collector.

### relationship_note #2  [metadata_id: 4127]
Title: Status

The collector updates its own row in BatchOps.Status at the start (RUNNING) and end (IDLE + SUCCESS/FAILED) of each execution cycle. Status provides the proof-of-life signal for the Control Center dashboard.

### relationship_note #3  [metadata_id: 4128]
Title: Teams.AlertQueue / Jira.TicketQueue

Alert evaluation inserts directly into Teams.AlertQueue and calls Jira.sp_QueueTicket for detected conditions. Deduplication checks Teams.RequestLog and Jira.RequestLog before firing to prevent duplicate alerts.

### relationship_note #4  [metadata_id: 4129]
Title: Tools.BDL_ImportLog

Future integration: BDL files originated from the xFACts BDL Import tool carry a file_registry_id that can be joined to Tools.BDL_ImportLog.file_registry_id. The collector will write completion status back to BDL_ImportLog for xFACts-originated imports, closing the loop between the import tool and the monitoring collector.

### description / alert_count #29  [metadata_id: 4104]

Number of alerts fired for this file. Used to prevent duplicate alerting. Resets to 0 when partition activity resumes, enabling re-alerting on subsequent stall episodes.

### description / batch_identifier #5  [metadata_id: 4082]

Batch identifier from file_rgstry_dtl.btch_idntfr_txt. The batch_id_txt value from the BDL XML file header.

### description / bdl_log_status #8  [metadata_id: 4085]

Human-readable file-level status text from ref_entty_async_stts_cd. Reflects bdl_log status for progress display. Terminal state is determined by file_registry_status_code from File_Registry.

### description / bdl_log_status_code #7  [metadata_id: 4084]

Current file-level status code from bdl_log (bdl_prcss_stss_cd). Only file-level rows are tracked (sub_entty_nm_txt IS NULL). Joined to ref_entty_async_stts_cd for status text. Used for progress display and timing — not for terminal state detection, which is driven by file_registry_status_code from File_Registry.

### description / collected_dttm #30  [metadata_id: 4105]

When this row was first inserted by the collector.

### description / completed_dttm #24  [metadata_id: 4099]

When the file reached terminal state. Sourced from File_Registry.upsrt_dttm when file_stts_cd transitions to a terminal value (5, 6, 7, or 8).

### description / completed_status #25  [metadata_id: 4100]

How the file completed. Set from Ref_File_Stts_Cd.file_stts_val_txt when File_Registry.file_stts_cd reaches a terminal value. Values align with DM file status terminology.

### status_value / completed_status #1  [metadata_id: 4118]
Title: PROCESSED

File successfully processed by DM (file_registry_status_code = 5). All records staged and imported without file-level failure. Individual record-level failures may still exist within partitions but the overall file outcome is success.

### status_value / completed_status #2  [metadata_id: 4119]
Title: PARTIALLY_PROCESSED

File processed by DM with partial success (file_registry_status_code = 8). Some records failed during staging or import. The import_failed_count and staging_failed_count columns indicate the scope of failures. Common for large ETL files where business rules reject a subset of records.

### status_value / completed_status #3  [metadata_id: 4120]
Title: FAILED

File failed processing in DM (file_registry_status_code = 6). Covers both staging failures (XML validation, unconfigured entity types) and import processing failures. The error_message column and File_Registry.file_err_msg_txt provide failure details.

### status_value / completed_status #4  [metadata_id: 4121]
Title: CANCELED

File was canceled in DM (file_registry_status_code = 7). Never observed in production data but exists as a valid terminal state in the DM reference table.

### status_value / completed_status #5  [metadata_id: 4144]
Title: RETRY

Historical edge case. Four files from the initial data backfill had file_registry_status_code = 11 (RETRY) and were manually marked complete. RETRY is not treated as a terminal state by the collector — if new files land on this status, the collector will continue polling them and stall-alert if no progress is detected.

### description / entity_type #4  [metadata_id: 4081]

BDL entity type from bdl_log partition rows (sub_entty_nm_txt). Values like CONSUMER_TAG, CONSUMER_PHONE, CONSUMER_ACCOUNT_AR_LOG. Identifies what type of data the file contains.

### description / error_message #20  [metadata_id: 4097]

Error message captured from bdl_log.bdl_log_msg on failure rows or from File_Registry.file_err_msg_txt. The collector checks bdl_log first, falling back to File_Registry if no log message exists.

### description / file_created_dttm #9  [metadata_id: 4086]

When the file was registered in DM (File_Registry.file_crt_dttm). Slightly precedes the first PROCESSING row in bdl_log.

### description / file_name #3  [metadata_id: 4080]

Source filename from File_Registry.file_name_full_txt. Contains Sterling output filename for ETL files or user-specified filename for manual/xFACts imports.

### description / file_registry_id #2  [metadata_id: 4079]

DM File_Registry ID. The trackable unit for BDL — one row per file. Unique constraint ensures no duplicates.

### description / file_registry_status #22  [metadata_id: 4143]

Human-readable File_Registry status text from Ref_File_Stts_Cd.file_stts_val_txt. Paired with file_registry_status_code. Displayed in the Control Center active batches view as the primary BDL status indicator.

### description / file_registry_status_code #21  [metadata_id: 4142]

File_Registry status code from DM (File_Registry.file_stts_cd joined to Ref_File_Stts_Cd). The authoritative source for terminal state detection. Updated from File_Registry each polling cycle. Terminal values: 5 (PROCESSED), 6 (FAILED), 7 (CANCELED), 8 (PARTIALLY_PROCESSED). Non-terminal values indicate the file is still in-flight.

### description / import_failed_count #17  [metadata_id: 4094]

Records that failed during import processing. From file_rgstry_cstm_dtl where file_rgstry_cstm_dtl_nm = Dm_import_failed_count.

### description / import_processed_count #15  [metadata_id: 4092]

Records processed during import phase. From file_rgstry_cstm_dtl where file_rgstry_cstm_dtl_nm = Dm_import_processed_count.

### description / import_success_count #16  [metadata_id: 4093]

Records successfully imported. From file_rgstry_cstm_dtl where file_rgstry_cstm_dtl_nm = Dm_import_success_count.

### description / imported_dttm #12  [metadata_id: 4089]

Timestamp of the IMPORTED (status 12) row in bdl_log, if one was written. Some files complete processing without DM writing an IMPORTED row to bdl_log. This column is informational — terminal state is determined by file_registry_status_code, not by the presence of this timestamp.

### description / is_complete #23  [metadata_id: 4098]

Whether the file has reached a terminal state in File_Registry. Incomplete files are updated each polling cycle. Terminal File_Registry statuses: PROCESSED (5), FAILED (6), CANCELED (7), PARTIALLY_PROCESSED (8).

### description / last_log_dttm #27  [metadata_id: 4102]

Timestamp of the most recent partition-level bdl_log entry. Provides human-readable recency of processing activity.

### description / last_log_id #26  [metadata_id: 4101]

Max bdl_log_id from partition-level rows for this file. Compared across polls to detect activity. Unlike NB which uses a separate log table, BDL stall detection uses the partition rows in bdl_log itself as the activity indicator.

### description / last_polled_dttm #31  [metadata_id: 4106]

When this row was last updated by the collector.

### description / partition_count #18  [metadata_id: 4095]

Count of distinct partitions created in bdl_log for this file. DM splits BDL files into partitions of approximately 100 operational units each. Used as progress denominator during in-flight processing.

### description / partitions_completed #19  [metadata_id: 4096]

Number of partitions that have reached PROCESSED (3) or PARTIALLYPROCESSED (7) status with bdl_prcssd_cnt populated. Used as progress numerator during in-flight processing.

### description / processing_started_dttm #10  [metadata_id: 4087]

Timestamp of the first PROCESSING (status 2) row in bdl_log for this file. Marks when DM began working on the file.

### description / staged_dttm #11  [metadata_id: 4088]

Timestamp of the STAGED (status 10) row in bdl_log. Marks when DM completed staging file content into partition tables and is ready for import processing.

### description / staging_failed_count #14  [metadata_id: 4091]

Records that failed staging validation. From file_rgstry_cstm_dtl where file_rgstry_cstm_dtl_nm = Dm_staging_failed_count. Calculated by DM as total_record_count minus staging_success_count.

### description / staging_success_count #13  [metadata_id: 4090]

Records successfully staged. From file_rgstry_cstm_dtl where file_rgstry_cstm_dtl_nm = Dm_staging_success_count. Populated at or near import completion.

### description / stall_poll_count #28  [metadata_id: 4103]

Consecutive polls with no new partition activity. Increments when last_log_id is unchanged, resets to 0 on new activity. Drives stall detection alerting when threshold is exceeded.

### description / total_record_count #6  [metadata_id: 4083]

Total record count from file_rgstry_dtl.file_rgstry_dtl_rec_ttl_cnt. Represents the total_count value parsed from the BDL XML file header at registration time. Serves as the denominator for completion percentage calculation.

### description / tracking_id #1  [metadata_id: 4078]

Unique xFACts identifier for each tracked BDL file.

## Collect-BDLBatchStatus.ps1 (Script)

### category #0  [metadata_id: 4109]

BatchOps

### data_flow #0  [metadata_id: 4130]

Reads GlobalConfig for AG replica settings, alert thresholds, and routing configuration. Reads bdl_log (file-level and partition-level rows), ref_entty_async_stts_cd, File_Registry, Ref_File_Stts_Cd, file_rgstry_dtl, and file_rgstry_cstm_dtl from the DM replica for BDL file status and progress data. Terminal state detection uses File_Registry.file_stts_cd as the authoritative source, stored as file_registry_status_code and file_registry_status on the tracking row. Writes to BatchOps.BDL_BatchTracking for lifecycle tracking. Queues alerts to Teams.AlertQueue and Jira.sp_QueueTicket with deduplication checks against Teams.RequestLog and Jira.RequestLog. Updates BatchOps.Status for proof-of-life monitoring.

### description #0  [metadata_id: 4107]

Monitors Debt Manager BDL file lifecycle from registration through terminal state. Collects new files, updates status for in-flight files with partition-based progress tracking, captures DM summary counts from file_rgstry_cstm_dtl, and evaluates alert conditions. Terminal state determined by File_Registry.file_stts_cd (PROCESSED, FAILED, CANCELED, PARTIALLY_PROCESSED). Two alert conditions: FAILED files and stalled partition processing.

### design_note #1  [metadata_id: 4131]
Title: Three-Step Execution Pattern

Follows the established BatchOps collector pattern: Step 1 (Collect) discovers new files via bdl_log and inserts tracking rows with terminal detection from File_Registry.file_stts_cd at insert time. Step 2 (Update) polls all incomplete files for current status from both bdl_log (progress info, partition counts, timestamps) and File_Registry (terminal state via file_registry_status_code). Step 3 (Evaluate) checks two alert conditions: FAILED completions and stalled processing.

### design_note #2  [metadata_id: 4132]
Title: Multi-Table DM Source Queries

Unlike NB which reads primarily from one batch header table and one log table, the BDL collector reads from five DM source tables per file: bdl_log for lifecycle status and partition progress, File_Registry for filename and timestamps, file_rgstry_dtl for XML header metadata (total record count, batch identifier), and file_rgstry_cstm_dtl for DM-calculated summary counts (staging/import success/failed/processed). This requires multiple queries per file but captures the complete picture that DM displays in its own BDL logging screen.

### design_note #3  [metadata_id: 4133]
Title: Bitwise Alert Routing

Each of the two alert conditions has an independent GlobalConfig routing value using bitwise flags: 0 = disabled, 1 = Teams only, 2 = Jira only, 3 = Both. The script checks routing -band 2 for Jira and -band 1 for Teams. Alert conditions: bdl_alert_failed_routing (covers all FAILED completions regardless of failure phase) and bdl_alert_stall_routing (partition processing stalls). Deduplication checks prevent duplicate alerts for the same trigger.

### design_note #4  [metadata_id: 4134]
Title: Stall Deduplication via Composite Trigger

Stall alerts use a composite trigger_value of fileRegId_lastLogId. This ensures one alert per stall episode — if the file resumes activity (new partition rows), alert_count resets to zero. If it stalls again at a different log position, the new trigger_value produces a fresh dedup key, enabling re-alerting. Terminal failure alerts (STAGEFAILED, IMPORT_FAILED) use fileRegId alone for one-time alerting.

### module #0  [metadata_id: 4108]

BatchOps

### relationship_note #1  [metadata_id: 4135]
Title: BDL_BatchTracking

Primary data store. The script inserts new tracking rows, updates all incomplete rows each cycle with status from bdl_log (bdl_log_status_code, bdl_log_status) and File_Registry (file_registry_status_code, file_registry_status), partition progress, DM summary counts, and stall detection counters. Terminal state detection uses File_Registry.file_stts_cd via file_registry_status_code.

### relationship_note #2  [metadata_id: 4136]
Title: Collect-NBBatchStatus.ps1 / Collect-PMTBatchStatus.ps1

Sibling collector following the same three-step architectural pattern for BDL files. All three collectors run independently under the orchestrator in the same dependency group.

### relationship_note #3  [metadata_id: 4137]
Title: Send-OpenBatchSummary.ps1

Complementary script for daily pre-maintenance summary. Currently has a BDL placeholder returning not-monitored status. Future enhancement: implement Get-OpenBDLImports function to include active BDL files in the summary card.

## Collect-NBBatchStatus.ps1 (Script)

### category #0  [metadata_id: 2342]

BatchOps

### data_flow #0  [metadata_id: 2349]

Reads GlobalConfig for AG replica settings, alert thresholds, and routing configuration. Reads new_bsnss_btch, Ref_new_bsnss_btch_stts_cd, ref_cnsmr_mrg_lnk_stts_cd, File_Registry, and new_bsnss_log from the DM secondary replica. Writes to BatchOps.NB_BatchTracking (inserts and updates), BatchOps.Status (execution state). Alert evaluation writes to Teams.AlertQueue (direct INSERT) and Jira.TicketQueue (via sp_QueueTicket). Reads Teams.RequestLog and Jira.RequestLog for deduplication checks. Calls Complete-OrchestratorTask for orchestrator callback.

### description #0  [metadata_id: 2340]

PowerShell script that monitors Debt Manager New Business batch lifecycle from creation through terminal state. Collects new batches, updates status for in-flight batches, tracks merge log activity for stall detection, and evaluates 8 alert conditions with configurable Jira/Teams routing.

### design_note #1  [metadata_id: 2350]
Title: Bitwise Alert Routing

Each of the 8 alert conditions has an independent GlobalConfig routing value using bitwise flags: 0 = disabled, 1 = Teams only, 2 = Jira only, 3 = Both. The script checks routing -band 2 for Jira and routing -band 1 for Teams. A master switch (nb_alerting_enabled) must be 1 for any alerts to fire regardless of individual routing.

### design_note #2  [metadata_id: 2351]
Title: Deduplication Strategy

Three deduplication patterns by alert type: batch_id only (checks 1, 2, 7) for one alert per stall episode; batch_id + last_log_id (check 3) for one alert per stall episode with re-alerting on new stall points; batch_id + date (checks 4, 5a, 5b, 6) for daily re-alerting on ongoing conditions.

### design_note #3  [metadata_id: 2352]
Title: Error Extraction for Upload Failures

Upload failure alerts (Check 1) include error details extracted from new_bsnss_log via CTE with STRING_AGG, showing up to 5 distinct errors with noise filtering. Messages matching known non-actionable patterns are excluded to keep alerts focused on actual problems.

### module #0  [metadata_id: 2341]

BatchOps

### relationship_note #1  [metadata_id: 2353]
Title: NB_BatchTracking

Primary data store. The script inserts new tracking rows, updates all incomplete rows each cycle, and sets terminal state when reached. Stall counters, alert counters, and reset counters are maintained exclusively by this script.

### relationship_note #2  [metadata_id: 2354]
Title: Collect-PMTBatchStatus.ps1

Sibling collector following the same architectural pattern for Payment batches. Both run independently under the orchestrator.

### relationship_note #3  [metadata_id: 2355]
Title: Send-OpenBatchSummary.ps1

Complementary script with a different purpose — daily summary rather than continuous monitoring. Queries DM directly rather than reading tracking tables.

## Collect-PMTBatchStatus.ps1 (Script)

### category #0  [metadata_id: 2345]

BatchOps

### data_flow #0  [metadata_id: 2356]

Reads GlobalConfig for AG replica settings, lookback window, and alert routing configuration. Reads cnsmr_pymnt_btch, ref_pymnt_btch_stts_cd, ref_pymnt_btch_typ_cd, cnsmr_pymnt_btch_log, and cnsmr_pymnt_jrnl from the DM secondary replica. Writes to BatchOps.PMT_BatchTracking (inserts and updates), BatchOps.Status (execution state). Terminal failure alerts write to Teams.AlertQueue and Jira.TicketQueue. Reads RequestLog tables for deduplication. Calls Complete-OrchestratorTask for orchestrator callback.

### description #0  [metadata_id: 2343]

PowerShell script that monitors Debt Manager Payment batch lifecycle from creation through terminal state. Tracks all batch types, updates status with log and journal-based progress, and evaluates terminal failure alert conditions with configurable Jira/Teams routing.

### design_note #1  [metadata_id: 2357]
Title: Config Source Tracking

The script logs whether each configuration setting loaded from GlobalConfig or fell back to the script default. Log entries tagged with "(GlobalConfig)" or "(default)" provide diagnostic visibility into which settings are active and whether any are missing from the database.

### design_note #2  [metadata_id: 2358]
Title: IMPORTFAILED Insert-Path Limitation

The insert-path terminal detection does not include IMPORTFAILED (status 11). Batches already in IMPORTFAILED when first discovered are inserted as incomplete and detected as terminal on the next polling cycle. This causes a one-cycle delay before the alert fires. The update path correctly handles all terminal failure states.

### module #0  [metadata_id: 2344]

BatchOps

### relationship_note #1  [metadata_id: 2359]
Title: PMT_BatchTracking

Primary data store. The script inserts new tracking rows, updates all incomplete rows each cycle with status, metrics, journal progress, and stall detection. Handles PARTIAL recovery by clearing completion fields and resetting alert_count.

### relationship_note #2  [metadata_id: 2360]
Title: Collect-NBBatchStatus.ps1

Sibling collector following the same architectural pattern for New Business batches. Both run independently under the orchestrator.

## NB_BatchTracking (Table)

### category #0  [metadata_id: 1665]

BatchOps

### data_flow #0  [metadata_id: 2289]

Collect-NBBatchStatus.ps1 queries the DM secondary replica for new_bsnss_btch rows within the configured lookback window and inserts one tracking row per new batch with initial state, metrics, and terminal detection. Each subsequent polling cycle updates all incomplete rows with current DM status codes, merge status, batch metrics, and log-based stall detection counters from new_bsnss_log. Terminal states (DELETED, FAILED, or merge statuses 3/5/6/8/10) set is_complete = 1 and record completed_status. The alert evaluation step reads incomplete rows to detect 8 alert conditions and increments alert_count after firing. Send-OpenBatchSummary.ps1 queries DM directly for its pre-maintenance card rather than reading this table. The Control Center BatchOps page reads this table for active batch status display and historical analysis.

### description #0  [metadata_id: 66]

New Business batch lifecycle tracking table. Captures each NB batch from creation through terminal state with dual state machine timing, log-based stall detection, and event counters for resets and alerts.

### design_note #1  [metadata_id: 2290]
Title: Dual State Machine

NB batches have two independent status progressions. batch_status_code tracks upload through release (UPLOADING to RELEASED). merge_status_code tracks post-release processing (POST_RELEASE_MERGING to POST_RELEASE_MERGE_COMPLETE). In practice, nearly all batches reach RELEASED (code 8) and remain there while the merge status drives the remaining lifecycle. The collector detects terminal states from both machines independently.

### design_note #2  [metadata_id: 2291]
Title: Log-Based Stall Detection

Stall detection monitors the new_bsnss_log table for activity rather than using static time thresholds. Each poll compares the current max log ID against the stored last_log_id. Unchanged means stall_poll_count increments. New activity resets both stall_poll_count and alert_count to zero, enabling re-alerting if the batch stalls again. This approach detects genuine stalls without false positives from large batches that process slowly.

### design_note #3  [metadata_id: 2292]
Title: Auto-Merge Aware Queue Waits

Batches with is_auto_merge = 1 use the shorter nb_queue_wait_minutes threshold because they should be merging automatically. Batches with is_auto_merge = 0 are intentionally held in RELEASED status pending manual merge initiation and use the longer nb_queue_wait_no_merge_minutes threshold to avoid false positive alerts. The no-auto-merge alerts generate INFO-level notifications rather than WARNING.

### design_note #4  [metadata_id: 2293]
Title: Source System Decoupling

All DM data is captured at collection time. Once a batch is in this table, monitoring queries never need to hit DM again for that batch's current state — only for detecting new log entries on incomplete batches. Completed batches are retained permanently for historical analysis, trend reporting, and duration benchmarking even if deleted from DM.

### module #0  [metadata_id: 1561]

BatchOps

### query #1  [metadata_id: 2302]
Title: Active batches with stall status
Description: All incomplete NB batches with time since release and stall detection state.

SELECT batch_id, batch_name, batch_status, merge_status, is_auto_merge,
       batch_created_dttm, stall_poll_count, last_log_dttm,
       DATEDIFF(MINUTE, release_completed_dttm, GETDATE()) AS minutes_since_release
FROM BatchOps.NB_BatchTracking
WHERE is_complete = 0
ORDER BY batch_created_dttm DESC;

### query #2  [metadata_id: 2303]
Title: Recent completions with duration
Description: Completed batches from the last 7 days with total and merge duration metrics.

SELECT batch_id, batch_name, completed_status, batch_created_dttm, completed_dttm,
       DATEDIFF(MINUTE, batch_created_dttm, completed_dttm) AS total_minutes,
       DATEDIFF(MINUTE, merge_started_dttm, merge_completed_dttm) AS merge_minutes,
       account_count, total_balance_amt
FROM BatchOps.NB_BatchTracking
WHERE is_complete = 1
  AND completed_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY completed_dttm DESC;

### query #3  [metadata_id: 2304]
Title: Stalled batches only
Description: Incomplete batches with active stall counters — merge has started but log activity has stopped.

SELECT batch_id, batch_name, stall_poll_count, last_log_id, last_log_dttm,
       last_polled_dttm,
       DATEDIFF(MINUTE, last_log_dttm, GETDATE()) AS minutes_since_activity
FROM BatchOps.NB_BatchTracking
WHERE is_complete = 0
  AND last_log_id IS NOT NULL
  AND stall_poll_count > 0
ORDER BY stall_poll_count DESC;

### query #4  [metadata_id: 2305]
Title: Monthly batch volume summary
Description: Six-month trend of batch volume, completion outcomes, and average account counts.

SELECT FORMAT(batch_created_dttm, 'yyyy-MM') AS month,
       COUNT(*) AS total_batches,
       SUM(CASE WHEN completed_status = 'POST_RELEASE_MERGE_COMPLETE' THEN 1 ELSE 0 END) AS merge_complete,
       SUM(CASE WHEN completed_status IN ('POST_RELEASE_PRTL_MRGD_WTH_ERS', 'POST_RELEASE_MERGE_CMPLT_WTH_ERS', 'POST_RELEASE_PARTIAL_MERGED') THEN 1 ELSE 0 END) AS merge_with_errors,
       SUM(CASE WHEN completed_status IN ('FAILED', 'DELETED') THEN 1 ELSE 0 END) AS failed_or_deleted,
       SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS still_active,
       AVG(account_count) AS avg_accounts
FROM BatchOps.NB_BatchTracking
WHERE batch_created_dttm >= DATEADD(MONTH, -6, GETDATE())
GROUP BY FORMAT(batch_created_dttm, 'yyyy-MM')
ORDER BY month DESC;

### relationship_note #1  [metadata_id: 2306]
Title: Collect-NBBatchStatus.ps1

The collector script creates, updates, and completes rows in this table. It also reads incomplete rows during alert evaluation to detect 8 alert conditions. The stall_poll_count, alert_count, and reset_count columns are maintained exclusively by the collector.

### relationship_note #2  [metadata_id: 2307]
Title: Status

The collector updates its own row in BatchOps.Status at the start (RUNNING) and end (IDLE + SUCCESS/FAILED) of each execution cycle. Status provides the proof-of-life signal for the Control Center dashboard.

### relationship_note #3  [metadata_id: 2308]
Title: Teams.AlertQueue / Jira.TicketQueue

Alert evaluation inserts directly into Teams.AlertQueue and calls Jira.sp_QueueTicket for detected conditions. Deduplication checks Teams.RequestLog and Jira.RequestLog before firing to prevent duplicate alerts.

### description / account_count #18  [metadata_id: 601]

Total accounts in batch

### description / alert_count #37  [metadata_id: 620]

Number of alerts fired for this batch. Used to prevent duplicate alerting. Resets to 0 when log activity resumes, enabling re-alerting on subsequent stall episodes

### description / batch_created_dttm #10  [metadata_id: 593]

When the batch was created in DM

### description / batch_id #2  [metadata_id: 585]

DM source batch ID (new_bsnss_btch_id). Unique constraint ensures one row per batch

### description / batch_name #3  [metadata_id: 586]

DM batch short name (new_bsnss_btch_shrt_nm)

### description / batch_status #9  [metadata_id: 592]

Human-readable batch status text

### description / batch_status_code #8  [metadata_id: 591]

Current DM batch status code (Ref_new_bsnss_btch_stts_cd)

### description / collected_dttm #38  [metadata_id: 621]

When this row was first inserted by the collector

### description / completed_dttm #30  [metadata_id: 613]

When the batch reached terminal state

### description / completed_status #31  [metadata_id: 614]

How the batch completed. Values are set from the DM merge status text for merge completions, or from the batch status for pre-merge terminals. See the completed_status values table in the Batch Status Reference section

### status_value / completed_status #1  [metadata_id: 2294]
Title: POST_RELEASE_MERGE_COMPLETE

Merge processing complete. Primary successful terminal state — represents the vast majority of completions.

### status_value / completed_status #2  [metadata_id: 2295]
Title: POST_RELEASE_PRTL_MRGD_WTH_ERS

Merge completed with partial errors. Terminal — manual resolution required for error accounts.

### status_value / completed_status #3  [metadata_id: 2296]
Title: POST_RELEASE_MERGE_CMPLT_WTH_ERS

Merge completed with errors. Terminal — manual resolution required.

### status_value / completed_status #4  [metadata_id: 2297]
Title: POST_RELEASE_PARTIAL_MERGED

Partial merge — processing stopped before completion. Terminal — manual resolution required.

### status_value / completed_status #5  [metadata_id: 2298]
Title: POST_RELEASE_LINK_COMPLETE

Link processing complete. Included in terminal detection for completeness but linking is not enabled in this environment — zero occurrences in historical data.

### status_value / completed_status #6  [metadata_id: 2299]
Title: DELETED

Batch deleted from DM (batch_status_code 5). Detected as terminal from the batch status state machine.

### status_value / completed_status #7  [metadata_id: 2300]
Title: FAILED

General failure (batch_status_code 13). Detected as terminal from the batch status state machine.

### status_value / completed_status #8  [metadata_id: 2301]
Title: INVESTIGATE

Historical batches marked for review during initial deployment. Internal value only.

### description / consumer_count #17  [metadata_id: 600]

Total consumers in batch

### description / excluded_balance_amt #23  [metadata_id: 606]

Excluded consumer balance amount

### description / excluded_consumer_count #22  [metadata_id: 605]

Consumers excluded during processing

### description / file_registry_id #4  [metadata_id: 587]

DM File_Registry reference for the uploaded file

### description / is_auto_merge #40  [metadata_id: 623]

Whether the batch is configured for automatic merge after release. Batches with auto-merge disabled are intentionally held in RELEASED status and use a longer queue wait threshold

### description / is_auto_release #7  [metadata_id: 590]

Whether the batch is configured for automatic release

### description / is_complete #29  [metadata_id: 612]

Whether the batch has reached a terminal state. Incomplete batches are updated each polling cycle

### description / is_manual_upload #6  [metadata_id: 589]

Whether the batch was manually uploaded (vs automated)

### description / last_log_dttm #33  [metadata_id: 616]

Timestamp of the most recent log entry

### description / last_log_id #32  [metadata_id: 615]

Max new_bsnss_log_id from DM for this batch. Compared across polls to detect activity

### description / last_polled_dttm #39  [metadata_id: 622]

When this row was last updated by the collector

### description / last_reset_dttm #36  [metadata_id: 619]

When the most recent reset occurred

### description / merge_completed_dttm #16  [metadata_id: 599]

When merge reached terminal state

### description / merge_started_dttm #15  [metadata_id: 598]

When merge activity began (derived from first log entry)

### description / merge_status #14  [metadata_id: 597]

Human-readable merge status text

### description / merge_status_code #13  [metadata_id: 596]

Current DM merge status code (ref_cnsmr_mrg_lnk_stts_cd)

### description / original_collection_charges_amt #26  [metadata_id: 609]

Original collection charges amount

### description / original_cost_amt #27  [metadata_id: 610]

Original cost amount

### description / original_interest_amt #25  [metadata_id: 608]

Original interest amount

### description / original_other_amt #28  [metadata_id: 611]

Original other charges amount

### description / original_principal_amt #24  [metadata_id: 607]

Original principal amount

### description / posted_account_count #20  [metadata_id: 603]

Accounts successfully posted

### description / posted_balance_amt #21  [metadata_id: 604]

Posted account balance amount

### description / release_completed_dttm #12  [metadata_id: 595]

When the batch was fully released (new_bsnss_btch_rlsd_dt)

### description / release_started_dttm #11  [metadata_id: 594]

When the release process began (new_bsnss_btch_rls_strt_dttm)

### description / reset_count #35  [metadata_id: 618]

Number of times the batch was reset back to RELEASED during merge processing

### description / stall_poll_count #34  [metadata_id: 617]

Consecutive polls with no new log activity. Increments when last_log_id unchanged, resets to 0 on new activity. Only active when last_log_id is not NULL (merge has started)

### description / total_balance_amt #19  [metadata_id: 602]

Total account balance amount

### description / tracking_id #1  [metadata_id: 584]

Unique xFACts identifier for each tracked batch

### description / upload_filename #5  [metadata_id: 588]

Source filename from File_Registry or batch upload text

## PMT_BatchTracking (Table)

### category #0  [metadata_id: 1666]

BatchOps

### data_flow #0  [metadata_id: 2309]

Collect-PMTBatchStatus.ps1 queries the DM secondary replica for cnsmr_pymnt_btch rows within the configured lookback window and inserts one tracking row per new batch with initial state, metrics, and terminal detection. Each subsequent polling cycle updates all incomplete rows with current DM status, log activity from cnsmr_pymnt_btch_log, and journal-based progress from cnsmr_pymnt_jrnl (posted/failed counts and last posted timestamp). Terminal states (POSTED, FAILED, IMPORTFAILED, REVERSALFAILED) and hard deletes set is_complete = 1. PARTIAL batches remain incomplete and continue polling since they can be re-fired in DM. Alert evaluation reads incomplete terminal batches and routes notifications to Jira and/or Teams via per-condition GlobalConfig routing. The Control Center BatchOps page reads this table for active batch status display and historical analysis.

### description #0  [metadata_id: 97]

Payment batch lifecycle tracking table. Captures all payment batch types (Import, Manual, Reversal, Reapply, etc.) from creation through terminal state with log-based and journal-based stall detection, real-time posting progress via the consumer payment journal, and event counters for alerts.

### design_note #1  [metadata_id: 2310]
Title: Track All Alert Selectively

All payment batch types (Import, Manual, Reversal, Reapply, Balance Adjustment, Virtual) are tracked for visibility, but stall detection and alerting only apply to IMPORT batches (batch_type_code = 3). Manual, Reversal, Reapply, and other batch types have unpredictable lifecycles that would generate false positives.

### design_note #2  [metadata_id: 2311]
Title: Dual Activity Indicators

IMPORT batches use different activity sources depending on lifecycle phase. During IMPORTING through RELEASED, the batch log table (cnsmr_pymnt_btch_log) tracks status transitions. During INPROCESS, the log goes quiet and real-time progress comes from the consumer payment journal (cnsmr_pymnt_jrnl) where individual payments transition from BATCHED to POSTED. The collector switches stall detection source accordingly.

### design_note #3  [metadata_id: 2312]
Title: Journal vs Header Counts

The table stores both the batch header posted_count (frozen snapshot from automated processing, only updates at terminal state) and journal_posted_count (real-time total from cnsmr_pymnt_jrnl including resolved suspense payments). Header counts match what DM displays for reconciliation. Journal counts provide the true operational picture for the Control Center. journal_posted_count is typically >= posted_count for batches with resolved suspense.

### design_note #4  [metadata_id: 2313]
Title: PARTIAL Non-Terminal Recovery

PARTIAL (batch_status_code 5) is not treated as terminal because batches can be re-fired in DM back to INPROCESS. When the collector detects a batch that was previously PARTIAL but now shows a non-PARTIAL status, it clears completed_status, completed_dttm, and resets alert_count to 0. This enables fresh alerting if the batch fails again after recovery.

### module #0  [metadata_id: 1562]

BatchOps

### query #1  [metadata_id: 2324]
Title: Active batches with journal progress
Description: All incomplete PMT batches with real-time posting progress and stall detection state.

SELECT batch_id, batch_name, batch_type, batch_status, active_count,
       journal_posted_count, journal_failed_count, stall_poll_count,
       last_posted_dttm,
       DATEDIFF(MINUTE, batch_created_dttm, GETDATE()) AS minutes_since_created
FROM BatchOps.PMT_BatchTracking
WHERE is_complete = 0
ORDER BY batch_created_dttm DESC;

### query #2  [metadata_id: 2325]
Title: Journal vs header count comparison
Description: Batches where journal posted count differs from header posted count — indicates resolved suspense payments.

SELECT batch_id, batch_name, batch_status, active_count,
       posted_count AS header_posted,
       journal_posted_count AS journal_posted,
       journal_posted_count - ISNULL(posted_count, 0) AS resolved_suspense_posted,
       suspense_count
FROM BatchOps.PMT_BatchTracking
WHERE journal_posted_count IS NOT NULL
  AND journal_posted_count <> ISNULL(posted_count, 0)
ORDER BY batch_id DESC;

### query #3  [metadata_id: 2326]
Title: IMPORT batch stall status
Description: Incomplete IMPORT batches with active stall counters showing minutes since last activity.

SELECT batch_id, batch_name, batch_status, stall_poll_count,
       journal_posted_count, last_posted_dttm, last_log_dttm, last_polled_dttm,
       DATEDIFF(MINUTE, COALESCE(last_posted_dttm, last_log_dttm), GETDATE()) AS minutes_since_activity
FROM BatchOps.PMT_BatchTracking
WHERE is_complete = 0
  AND batch_type_code = 3
  AND stall_poll_count > 0
ORDER BY stall_poll_count DESC;

### relationship_note #1  [metadata_id: 2327]
Title: Collect-PMTBatchStatus.ps1

The collector script creates, updates, and completes rows in this table. It also handles PARTIAL recovery detection (clearing completed fields and resetting alert_count when a re-fired batch leaves PARTIAL status). Stall detection counters and journal metrics are maintained exclusively by the collector.

### relationship_note #2  [metadata_id: 2328]
Title: Status

The collector updates its own row in BatchOps.Status at the start (RUNNING) and end (IDLE + SUCCESS/FAILED) of each execution cycle.

### relationship_note #3  [metadata_id: 2329]
Title: Teams.AlertQueue / Jira.TicketQueue

Terminal failure alert evaluation inserts directly into Teams.AlertQueue and calls Jira.sp_QueueTicket for IMPORTFAILED, FAILED, PARTIAL, and REVERSALFAILED conditions. Deduplication checks RequestLog tables before firing.

### description / active_count #20  [metadata_id: 1101]

Records sent to posting pipeline (cnsmr_pymnt_btch_actv_rec_cnt)

### description / active_total_amt #24  [metadata_id: 1105]

Active payment amount

### description / alert_count #33  [metadata_id: 1114]

Number of alerts fired for this batch. Used to prevent duplicate alerting

### description / assigned_userid #11  [metadata_id: 1092]

DM user assigned to the batch (cnsmr_pymnt_btch_assgnd_usrid)

### description / batch_created_dttm #14  [metadata_id: 1095]

When the batch was created in DM

### description / batch_id #2  [metadata_id: 1083]

DM source batch ID (cnsmr_pymnt_btch_id). Unique constraint ensures one row per batch

### description / batch_name #3  [metadata_id: 1084]

DM batch name (cnsmr_pymnt_btch_nm)

### description / batch_status #13  [metadata_id: 1094]

Human-readable batch status text

### description / batch_status_code #12  [metadata_id: 1093]

Current DM batch status code (ref_pymnt_btch_stts_cd)

### description / batch_type #7  [metadata_id: 1088]

Human-readable batch type (e.g., IMPORT, MANUAL, REVERSAL, REAPPLY)

### status_value / batch_type #1  [metadata_id: 2320]
Title: IMPORT

File-based payment import (batch_type_code 3). Primary batch type for automated processing. Stall detection and alerting apply to this type only.

### status_value / batch_type #2  [metadata_id: 2321]
Title: MANUAL

Manually entered payment batch. Tracked for visibility but no stall detection or alerting.

### status_value / batch_type #3  [metadata_id: 2322]
Title: REVERSAL

Payment reversal batch. Tracked for visibility but no stall detection.

### status_value / batch_type #4  [metadata_id: 2323]
Title: REAPPLY

Reapplied payment batch referencing an original_batch_id. Tracked for visibility but no stall detection.

### description / batch_type_code #6  [metadata_id: 1087]

DM batch type code (cnsmr_pymnt_btch_typ_cd)

### description / collected_dttm #34  [metadata_id: 1115]

When this row was first inserted by the collector

### description / completed_dttm #28  [metadata_id: 1109]

When the batch reached terminal state

### description / completed_status #29  [metadata_id: 1110]

How the batch completed. Currently set by the collector for: POSTED, FAILED, IMPORTFAILED, REVERSALFAILED, DELETED. PARTIAL may appear temporarily for batches that reached PARTIAL before being re-fired — the value is cleared if the batch recovers. See the completed_status values table in the Batch Status Reference section

### status_value / completed_status #1  [metadata_id: 2314]
Title: POSTED

All payments posted successfully (batch_status_code 4). Primary success terminal state — represents the vast majority of completions.

### status_value / completed_status #2  [metadata_id: 2315]
Title: FAILED

Batch processing failed (batch_status_code 6). Terminal failure requiring investigation.

### status_value / completed_status #3  [metadata_id: 2316]
Title: IMPORTFAILED

File import failed (batch_status_code 11). Terminal failure — source file could not be imported.

### status_value / completed_status #4  [metadata_id: 2317]
Title: REVERSALFAILED

Reversal processing failed (batch_status_code 27). Terminal failure requiring manual intervention.

### status_value / completed_status #5  [metadata_id: 2318]
Title: DELETED

Batch removed from DM. Detected via hard delete detection when the batch no longer exists in the source table.

### status_value / completed_status #6  [metadata_id: 2319]
Title: PARTIAL

Some payments posted, some failed (batch_status_code 5). Transitional only — not a true terminal state. Cleared if the batch is re-fired and recovers. May exist on historical batches from before the PARTIAL non-terminal fix.

### description / created_by_userid #10  [metadata_id: 1091]

DM user who created the batch (cnsmr_pymnt_btch_crt_usrid)

### description / external_name #4  [metadata_id: 1085]

External batch name for file-based imports (cnsmr_pymnt_btch_extrnl_nm)

### description / file_registry_id #5  [metadata_id: 1086]

DM File_Registry reference for the source file

### description / imported_count #19  [metadata_id: 1100]

Records successfully imported (cnsmr_pymnt_btch_imprtd_rec_cnt)

### description / is_auto_post #8  [metadata_id: 1089]

Whether the batch is configured for automatic posting (cnsmr_pymnt_btch_auto_post_flg)

### description / is_complete #27  [metadata_id: 1108]

Whether the batch has reached a terminal state. Incomplete batches are updated each polling cycle

### description / journal_failed_count #37  [metadata_id: 1118]

Failed count from cnsmr_pymnt_jrnl (status 4). Extremely rare in practice. NULL for batch types that do not use the payment journal

### description / journal_posted_count #36  [metadata_id: 1117]

Real-time posted count from cnsmr_pymnt_jrnl (status 5). Includes resolved suspense payments. NULL for batch types that do not use the payment journal

### description / last_log_dttm #31  [metadata_id: 1112]

Timestamp of the most recent batch log entry

### description / last_log_id #30  [metadata_id: 1111]

Max cnsmr_pymnt_btch_log_id from DM for this batch. Used for stall detection during pre-INPROCESS phases

### description / last_polled_dttm #35  [metadata_id: 1116]

When this row was last updated by the collector

### description / last_posted_dttm #38  [metadata_id: 1119]

Timestamp of the most recent posted payment in the journal. Provides real-time recency of posting activity

### description / original_batch_id #9  [metadata_id: 1090]

Source batch ID for REAPPLY batches (cnsmr_pymnt_btch_orgnl_id)

### description / payment_count #18  [metadata_id: 1099]

Total payments in batch (cnsmr_pymnt_btch_pymnt_cnt_nmbr)

### description / payment_total_amt #23  [metadata_id: 1104]

Total payment amount

### description / posted_count #21  [metadata_id: 1102]

Records posted per batch header (cnsmr_pymnt_btch_pstd_rec_cnt). Only updates at terminal state, not during INPROCESS

### description / posted_total_amt #25  [metadata_id: 1106]

Posted payment amount (batch header)

### description / processed_dttm #16  [metadata_id: 1097]

When batch processing completed (cnsmr_pymnt_btch_prcssd_dttm)

### description / released_dttm #15  [metadata_id: 1096]

When the batch was released for processing (cnsmr_pymnt_btch_rlsd_dttm)

### description / reversal_dttm #17  [metadata_id: 1098]

When a reversal was processed (cnsmr_pymnt_btch_rvrsl_dt)

### description / stall_poll_count #32  [metadata_id: 1113]

Consecutive polls with no new activity. Uses log_id during early phases, journal_posted_count during INPROCESS. Only tracks IMPORT batches (type_code = 3); non-IMPORT batches stay at 0

### description / suspense_count #22  [metadata_id: 1103]

Records routed to suspense (cnsmr_pymnt_btch_sspns_rec_cnt)

### description / suspense_total_amt #26  [metadata_id: 1107]

Suspense payment amount

### description / tracking_id #1  [metadata_id: 1082]

Unique xFACts identifier for each tracked batch

## Send-OpenBatchSummary.ps1 (Script)

### category #0  [metadata_id: 2348]

BatchOps

### data_flow #0  [metadata_id: 2361]

Reads GlobalConfig for AG replica settings. Queries new_bsnss_btch and cnsmr_pymnt_btch on the DM secondary replica for in-flight batches, filtering out terminal and idle states. Builds a complete Adaptive Card JSON with sectioned layout and inserts directly into Teams.AlertQueue with the card_json field populated. Process-TeamsAlertQueue.ps1 delivers the card to Teams. Updates BatchOps.Status at execution start and end.

### description #0  [metadata_id: 2346]

PowerShell script that generates a daily pre-maintenance processing summary across all Debt Manager batch types and sends a color-coded Adaptive Card notification to Teams before the nightly maintenance window.

### design_note #1  [metadata_id: 2362]
Title: Direct Card JSON Insert

Inserts directly into Teams.AlertQueue with the card_json field rather than calling sp_QueueAlert, because the pre-built Adaptive Card requires the card_json field for rich formatting. The TR_Teams_AlertQueue_QueueDepth trigger fires on INSERT, signaling the processor to deliver the card.

### design_note #2  [metadata_id: 2363]
Title: Modular Batch Check Functions

Each batch type has its own function (Get-OpenNBBatches, Get-OpenPMTBatches, etc.) returning a standardized result object. Adding a new batch type requires writing one function and calling it in the main flow. BDL and Notice Processing sections exist as placeholders returning not-monitored status.

### design_note #3  [metadata_id: 2364]
Title: State-Driven Card Colors

Card color is determined by overall severity: yellow (warning) if any batch type has active open batches, green (good) if all monitored sections are clear. Individual sections use matching colors. The goal is to keep the card green before maintenance begins.

### module #0  [metadata_id: 2347]

BatchOps

### relationship_note #1  [metadata_id: 2365]
Title: Teams.AlertQueue

Inserts one row per execution with the pre-built Adaptive Card JSON. Uses trigger_type = OpenBatchSummary and trigger_value = current date. No deduplication needed since this runs once daily on a schedule.

### relationship_note #2  [metadata_id: 2366]
Title: Collect-NBBatchStatus.ps1 / Collect-PMTBatchStatus.ps1

Complementary but independent — the summary queries DM directly for current state rather than reading the tracking tables. This means it reflects the live DM state at query time, which may differ slightly from the tracking table state depending on polling timing.

## Status (Table)

### category #0  [metadata_id: 1667]

BatchOps

### data_flow #0  [metadata_id: 2330]

Each BatchOps collector script updates its own row at execution start (processing_status = RUNNING, started_dttm) and at execution end (processing_status = IDLE, completed_dttm, last_duration_ms, last_status). Rows are pre-seeded with one entry per registered process. The Control Center BatchOps page reads this table for process health dashboard cards showing last run time, duration, and success/failure status.

### description #0  [metadata_id: 70]

Multi-row collector execution dashboard. One row per BatchOps process, tracking execution state and timing for Control Center summary cards and operational health checks.

### design_note #1  [metadata_id: 2331]
Title: Proof-of-Life Only

The table tracks execution metadata (timing, status) rather than business metrics. Batch counts, alert counts, and error details live in their respective tracking tables and the Orchestrator TaskLog. This avoids maintaining duplicate counters that drift out of sync.

### module #0  [metadata_id: 1563]

BatchOps

### query #1  [metadata_id: 2336]
Title: Process health check
Description: All BatchOps processes with health classification based on last status and recency.

SELECT collector_name,
       CASE
           WHEN last_status = 'SUCCESS' AND DATEDIFF(MINUTE, completed_dttm, GETDATE()) <= 15
               THEN 'HEALTHY'
           WHEN last_status = 'FAILED' THEN 'FAILED'
           WHEN DATEDIFF(MINUTE, completed_dttm, GETDATE()) > 15 THEN 'STALE'
           ELSE 'UNKNOWN'
       END AS health_status,
       last_status, completed_dttm, last_duration_ms
FROM BatchOps.Status;

### relationship_note #1  [metadata_id: 2337]
Title: Collect-NBBatchStatus.ps1

Updates the row where collector_name = 'Collect-NBBatchStatus' at execution start and end.

### relationship_note #2  [metadata_id: 2338]
Title: Collect-PMTBatchStatus.ps1

Updates the row where collector_name = 'Collect-PMTBatchStatus' at execution start and end.

### relationship_note #3  [metadata_id: 2339]
Title: Send-OpenBatchSummary.ps1

Updates the row where collector_name = 'Send-OpenBatchSummary' at execution start and end.

### description / batch_type #3  [metadata_id: 703]

Which batch type this process monitors: NB, PMT, BDL, or ALL

### description / collector_name #2  [metadata_id: 702]

Name of the collector or reporting script (e.g., Collect-NBBatchStatus, Send-OpenBatchSummary)

### description / completed_dttm #6  [metadata_id: 706]

When the most recent execution completed

### description / last_duration_ms #7  [metadata_id: 707]

Duration of the most recent execution in milliseconds

### description / last_status #8  [metadata_id: 708]

Result of the most recent execution: SUCCESS, FAILED

### status_value / last_status #1  [metadata_id: 2334]
Title: SUCCESS

Most recent execution completed without errors.

### status_value / last_status #2  [metadata_id: 2335]
Title: FAILED

Most recent execution encountered errors. Check Orchestrator TaskLog for details.

### description / processing_status #4  [metadata_id: 704]

Current state: RUNNING, IDLE

### status_value / processing_status #1  [metadata_id: 2332]
Title: RUNNING

Collector is currently executing. Set at the start of each execution cycle.

### status_value / processing_status #2  [metadata_id: 2333]
Title: IDLE

Collector is between execution cycles. Set at the end of each execution cycle.

### description / started_dttm #5  [metadata_id: 705]

When the current or most recent execution started

### description / status_id #1  [metadata_id: 701]

Unique row identifier

## xFACts-BatchOpsFunctions.ps1 (Script)

### category #0  [metadata_id: 5120]

BatchOps

### data_flow #0  [metadata_id: 5121]

Dot-sourced by Collect-BDLBatchStatus.ps1, Collect-NBBatchStatus.ps1, Collect-PMTBatchStatus.ps1, and Send-OpenBatchSummary.ps1 after xFACts-OrchestratorFunctions.ps1. Get-bat_SourceData runs read-only queries against the Debt Manager source database on the resolved read replica. Resolve-bat_ReadServer calls the shared Get-AGReplicaRoles to pick the read server by replica role. Set-bat_BatchStatus writes the RUNNING and IDLE rows to BatchOps.Status that the Control Center Process Status cards display. Send-bat_BatchAlert deduplicates against Jira.RequestLog, queues tickets via Jira.sp_QueueTicket, and posts Teams alerts via the shared Send-TeamsAlert. The functions hold no state of their own; they operate on the calling script's script-scope context ($script:ReadServer, $script:Config, $script:PollingIntervalMinutes).

### description #0  [metadata_id: 5118]

Shared scoped-function library for the BatchOps batch-status collectors. Centralizes the read-replica source querying, availability-group read-server resolution, stall-duration text formatting, BatchOps.Status run-state writes, and Jira/Teams alert dispatch that the collectors and the pre-maintenance summary previously duplicated. Dot-sourced after xFACts-OrchestratorFunctions.ps1, which supplies the Get-AGReplicaRoles it calls.

### design_note #1  [metadata_id: 5122]
Title: No self-import of the orchestrator

As a shared-library file it declares no IMPORTS section, so it does not dot-source xFACts-OrchestratorFunctions.ps1 even though Resolve-bat_ReadServer depends on Get-AGReplicaRoles from it. Consuming scripts dot-source the orchestrator first, then this helper. This keeps the load order explicit at the call site and avoids a shared library reaching back into platform infrastructure.

### design_note #2  [metadata_id: 5123]
Title: Caller-side execute gating

Set-bat_BatchStatus and Send-bat_BatchAlert do no preview or execute checking of their own. The calling script gates each invocation with its own execute guard. This keeps the functions as pure writers with one calling convention across all four scripts rather than each carrying its own preview awareness.

### design_note #3  [metadata_id: 5124]
Title: Alert dispatch owns the shared fields, callers own the counts

Send-bat_BatchAlert holds the invariant Jira ticket field set, the deduplication query, and the weekend-aware due-date calculation, taking only the per-alert values as parameters. The per-script alert_count increment stays at the call site because it keys each collector's own tracking table.

### module #0  [metadata_id: 5119]

BatchOps

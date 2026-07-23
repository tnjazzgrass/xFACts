# Object_Metadata: DmOps
Source: dbo.Object_Metadata
Generated: 2026-07-23 07:43:43

## Archive_BatchDetail (Table)

### category #0  [metadata_id: 3759]

Archive

### description #0  [metadata_id: 3757]

Per-table operation detail within each archive batch. One row per table in the delete sequence per batch, capturing the delete order, table name, rows affected, duration, and status. Provides a full replay of every batch execution for audit trails and troubleshooting. Multi-pass tables appear as separate rows with distinct delete_order values and pass descriptions.

### module #0  [metadata_id: 3758]

DmOps

### description / batch_id #2  [metadata_id: 3761]

FK to Archive_BatchLog. Identifies which batch this table operation belongs to.

### description / created_dttm #10  [metadata_id: 3769]

When this detail row was created. Defaulted to GETDATE().

### description / delete_order #3  [metadata_id: 3762]

Execution order from the delete sequence. Varchar to accommodate UDEF dynamic orders (U1, U2, etc.) alongside numeric orders (7, 8, 9...). Matches the order logged in the script output.

### description / detail_id #1  [metadata_id: 3760]

Auto-incrementing primary key.

### description / duration_ms #7  [metadata_id: 3766]

Time in milliseconds for this specific table operation. NULL for skipped tables.

### description / error_message #9  [metadata_id: 3768]

Error detail when status is Failed. NULL for successful and skipped operations.

### description / pass_description #5  [metadata_id: 3764]

Human-readable description of the FK path for this delete operation. NULL for single-pass tables. Examples: Pass 1: via direct trnsctn, Pass 2: via pymnt_jrnl, soft-deleted only.

### description / rows_affected #6  [metadata_id: 3765]

Number of rows deleted (execute mode) or that would be deleted (preview mode). Zero for skipped tables.

### description / status #8  [metadata_id: 3767]

Outcome of this individual table operation.

### status_value / status #1  [metadata_id: 3770]
Title: Success

Table operation completed successfully. rows_affected contains the count of deleted rows.

### status_value / status #2  [metadata_id: 3771]
Title: Skipped

Table had zero rows matching the WHERE clause. No delete was executed.

### status_value / status #3  [metadata_id: 3772]
Title: Failed

Table operation failed. error_message contains the exception detail. The script stops further processing after any failure.

### description / table_name #4  [metadata_id: 3763]

Target table name in crs5_oltp. Combined with delete_order and pass_description, uniquely identifies each operation in the delete sequence.

## Archive_BatchLog (Table)

### category #0  [metadata_id: 3734]

Archive

### description #0  [metadata_id: 3732]

One row per archive batch execution. Captures the full execution summary including schedule mode, batch size, consumer/account counts, row deletion totals, per-table processing counts, timing, and final status. Primary audit and reporting table for archive operations. The CC DM Operations page reads this table for execution history display and daily summary metrics.

### module #0  [metadata_id: 3733]

DmOps

### query #1  [metadata_id: 3923]
Title: Recent batch history
Description: Shows the last 20 archive batches with key metrics.

SELECT TOP 20
    batch_id,
    batch_start_dttm,
    schedule_mode,
    consumer_count,
    account_count,
    total_rows_deleted,
    tables_processed,
    tables_failed,
    duration_ms,
    status,
    bidata_status,
    executed_by
FROM DmOps.Archive_BatchLog
ORDER BY batch_id DESC;

### query #2  [metadata_id: 3924]
Title: Daily archive summary
Description: Aggregated daily totals for accounts archived and rows deleted.

SELECT
    CAST(batch_start_dttm AS DATE) AS archive_date,
    COUNT(*) AS batches,
    SUM(consumer_count) AS total_consumers,
    SUM(account_count) AS total_accounts,
    SUM(total_rows_deleted) AS total_rows,
    SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS failed_batches,
    SUM(duration_ms) / 1000 AS total_seconds
FROM DmOps.Archive_BatchLog
WHERE status IN ('Success', 'Failed')
GROUP BY CAST(batch_start_dttm AS DATE)
ORDER BY archive_date DESC;

### query #3  [metadata_id: 3925]
Title: BIDATA migration status summary
Description: Breakdown of BIDATA P-to-C migration outcomes across all batches.

SELECT
    bidata_status,
    COUNT(*) AS batch_count,
    SUM(account_count) AS total_accounts
FROM DmOps.Archive_BatchLog
WHERE bidata_status IS NOT NULL
GROUP BY bidata_status
ORDER BY batch_count DESC;

### description / account_count #8  [metadata_id: 3741]

Number of tagged accounts expanded from the selected consumers. Each consumer may have one or more TA_ARCH tagged accounts.

### description / batch_end_dttm #3  [metadata_id: 3737]

When this batch execution completed. NULL while the batch is still running. Updated on completion regardless of success or failure.

### description / batch_id #1  [metadata_id: 3735]

Auto-incrementing primary key. Referenced by Archive_BatchDetail and Archive_ConsumerLog as the parent batch identifier.

### description / batch_retry #17  [metadata_id: 3930]

Set to 1 when a retry batch has been created to reprocess this failed batch. Used by the retry check query (status = Failed AND batch_retry = 0) to identify unresolved failures. Set immediately at retry batch creation, not conditional on retry success.

### description / batch_size_used #5  [metadata_id: 3739]

Actual batch size (number of consumers) used for this batch. Reflects the GlobalConfig value corresponding to the schedule mode, or a manual override.

### description / batch_start_dttm #2  [metadata_id: 3736]

When this batch execution started. Defaulted to GETDATE() on insert. Used for daily summary aggregation and execution history display.

### description / bidata_status #19  [metadata_id: 3785]

Outcome of the BIDATA P-to-C migration step for this batch. NULL for batches that ran before this feature was added.

### status_value / bidata_status #1  [metadata_id: 3786]
Title: Success

All four BIDATA table pairs (GenAccount, GenAccPay, GenAccPayAgg, GenPayment) migrated successfully for the batch. ConsumerLog.bidata_migrated set to 1 for all accounts.

### status_value / bidata_status #2  [metadata_id: 3787]
Title: Failed

One or more BIDATA table migrations failed. ConsumerLog.bidata_migrated remains 0. Check Archive_BatchDetail for B1-B4 entries.

### status_value / bidata_status #3  [metadata_id: 3788]
Title: Skipped

BIDATA migration was not performed for this batch. Occurs when BIDATA instance is unavailable or during testing without the migration step enabled.

### description / consumer_count #7  [metadata_id: 3740]

Number of consumers selected in this batch. May be less than batch_size_used if fewer consumers have TA_ARCH tagged accounts remaining.

### description / duration_ms #14  [metadata_id: 3746]

Total batch execution time in milliseconds. NULL while the batch is still running. Measured from script start to completion of cleanup.

### description / error_message #16  [metadata_id: 3748]

Error detail when status is Failed. NULL on successful completion. Captures the first failure message from the delete sequence.

### description / exception_count #9  [metadata_id: 4906]

Number of consumers in the candidate batch that failed runtime TC_ARCH re-verification and were removed before the delete sequence ran. See DmOps.Archive_ConsumerExceptionLog for the per-consumer detail.

### description / executed_by #20  [metadata_id: 3749]

Windows identity that executed this batch. Defaulted to SUSER_SNAME(). Distinguishes service account execution from manual runs.

### description / retry_batch_id #18  [metadata_id: 3931]

Points to the batch_id that was created to retry this failed batch. NULL for non-failed batches and for failed batches that have not yet been retried. Populated at the same time as batch_retry. Provides audit trail linkage from original failure to retry attempt.

### description / schedule_mode #4  [metadata_id: 3738]

Which schedule mode was active when this batch ran. Determines the batch size used and provides historical context for performance analysis.

### status_value / schedule_mode #1  [metadata_id: 3750]
Title: Full

Batch ran during a full-mode schedule window using the standard batch_size from GlobalConfig.

### status_value / schedule_mode #2  [metadata_id: 3751]
Title: Reduced

Batch ran during a reduced-mode schedule window using batch_size_reduced from GlobalConfig.

### status_value / schedule_mode #3  [metadata_id: 3752]
Title: Manual

Batch ran with manual parameter overrides, outside of schedule-driven execution.

### status_value / schedule_mode #4  [metadata_id: 3932]
Title: Retry

Batch was created to reprocess a previously failed batch. Consumer and account list sourced from Archive_ConsumerLog for the original failed batch rather than from TA_ARCH tag selection.

### description / source_workgroup #6  [metadata_id: 5096]

The crs5_oltp consumer workgroup this batch selected from, identifying the line of business: WFAARCH1 (1st party) or WFAARCH3 (3rd party).

### description / status #15  [metadata_id: 3747]

Final outcome of the batch execution.

### status_value / status #1  [metadata_id: 3753]
Title: Running

Batch is currently executing. Set on initial insert, updated to final status on completion.

### status_value / status #2  [metadata_id: 3754]
Title: Success

Batch completed with zero table failures.

### status_value / status #3  [metadata_id: 3755]
Title: Failed

One or more tables in the delete sequence failed. The script stops on first failure. Check error_message and Archive_BatchDetail for specifics.

### status_value / status #4  [metadata_id: 3756]
Title: Aborted

Batch was terminated by the archive_abort emergency shutoff flag in GlobalConfig. The current batch completed but no further batches were started.

### description / tables_failed #13  [metadata_id: 3745]

Number of tables in the delete sequence where the DELETE operation failed. Any value greater than zero results in a Failed batch status.

### description / tables_processed #11  [metadata_id: 3743]

Number of tables in the delete sequence that had rows deleted (non-zero row count).

### description / tables_skipped #12  [metadata_id: 3744]

Number of tables in the delete sequence that had zero rows and were skipped.

### description / total_rows_deleted #10  [metadata_id: 3742]

Sum of all rows deleted across all tables in the delete sequence. In preview mode, this is the count of rows that would be deleted.

## Archive_ConsumerExceptionLog (Table)

### category #0  [metadata_id: 4891]

Archive

### data_flow #0  [metadata_id: 4899]

Execute-DmConsumerArchive.ps1 writes one row per consumer that fails runtime TC_ARCH re-verification within a batch. The script first inserts the row with both confirmation flags at 0, then performs the soft-delete UPDATE on crs5_oltp.dbo.cnsmr_Tag and the consumer-level AR event INSERT into crs5_oltp.dbo.cnsmr_accnt_ar_log, updating tag_removed and ar_event_written to 1 as each operation succeeds.

### description #0  [metadata_id: 4889]

Audit trail of consumers selected as TC_ARCH-eligible at the start of a batch but removed by runtime re-verification because one or more of their accounts no longer carry TA_ARCH. The DM tagging job was correct when it ran — the consumer state changed afterward, typically a new account merging in. This is a state-change audit, not an error log. Captures which batch detected the change plus confirmation flags that the cnsmr_Tag soft-delete and the cnsmr_accnt_ar_log AR event both succeeded.

### design_note #1  [metadata_id: 4900]
Title: State-Change Audit, Not Error Log

Exceptions captured here are not errors. The TC_ARCH apply-job correctly identified each consumer as eligible at the time it ran. Between that point and when the archive process picks the consumer up, the consumer state changed — typically a new account merged in without TA_ARCH. The runtime re-verification catches the drift and removes the consumer from the batch with full audit trail.

### design_note #2  [metadata_id: 4901]
Title: No Reason Column

Only one reason for an exception exists by design: at least one account on the consumer lacks TA_ARCH at runtime.

### design_note #3  [metadata_id: 4902]
Title: Two Confirmation Bits

tag_removed and ar_event_written are tracked separately because the operations target different tables in crs5_oltp.

### module #0  [metadata_id: 4890]

DmOps

### relationship_note #1  [metadata_id: 4903]
Title: Archive_BatchLog

Operational link via batch_id (no FK constraint). Every exception row carries the batch_id of the batch that detected it. Joining to Archive_BatchLog by batch_id provides the operational context (schedule mode, batch size, status, duration) for when the exception occurred. The exception_count column on Archive_BatchLog provides a pre-aggregated count for fast batch-level visibility.

### relationship_note #2  [metadata_id: 4904]
Title: cnsmr_Tag (crs5_oltp.dbo)

No FK constraint (cross-database) but operationally critical. tag_removed = 1 indicates Execute-DmConsumerArchive.ps1 successfully soft-deleted the consumer's active TC_ARCH row in crs5_oltp.dbo.cnsmr_Tag (cnsmr_tag_sft_delete_flg = 'Y'). After the soft-delete the consumer falls out of the candidate pool naturally on subsequent batches.

### relationship_note #3  [metadata_id: 4905]
Title: cnsmr_accnt_ar_log (crs5_oltp.dbo)

No FK constraint (cross-database) but operationally critical. ar_event_written = 1 indicates a consumer-level AR event was inserted.

### description / ar_event_written #7  [metadata_id: 4898]

Confirmation that the AR event INSERT into crs5_oltp.dbo.cnsmr_accnt_ar_log (consumer-level event with cnsmr_accnt_id = NULL, actn_cd/rslt_cd = CC) succeeded. 0 = insert failed or not yet attempted, 1 = insert confirmed.

### description / batch_id #2  [metadata_id: 4893]

Foreign key to Archive_BatchLog identifying the batch that detected this exception. Joins to Archive_BatchLog.batch_id.

### description / cnsmr_id #3  [metadata_id: 4894]

The consumer removed from the batch by re-verification. References crs5_oltp.dbo.cnsmr.cnsmr_id (no FK constraint — cross-database).

### description / cnsmr_idntfr_agncy_id #4  [metadata_id: 4895]

Standard agency identifier captured at exception time for cross-system reconciliation. Matches crs5_oltp.dbo.cnsmr.cnsmr_idntfr_agncy_id.

### description / detected_dttm #5  [metadata_id: 4896]

When the runtime re-verification check identified this consumer as no longer eligible. Defaults to GETDATE() at insert time.

### description / exception_id #1  [metadata_id: 4892]

Surrogate primary key for the exception row.

### description / tag_removed #6  [metadata_id: 4897]

Confirmation that the soft-delete UPDATE against crs5_oltp.dbo.cnsmr_Tag (setting cnsmr_tag_sft_delete_flg = 'Y' on the consumer's active TC_ARCH row) succeeded. 0 = update failed or not yet attempted, 1 = update confirmed.

## Archive_ConsumerLog (Table)

### category #0  [metadata_id: 3775]

Archive

### description #0  [metadata_id: 3773]

Audit trail of every consumer and account archived. One row per account per batch — tall and skinny by design. Captures the minimum identifying fields needed for BI cross-reference, creditor-level archive counts, and reconciliation to ensure no consumers are overlooked in the transition from live to static tables.

### module #0  [metadata_id: 3774]

DmOps

### query #1  [metadata_id: 3926]
Title: Archived accounts by creditor
Description: Count of archived accounts per creditor — useful for client reporting.

SELECT
    crdtr_id,
    COUNT(*) AS accounts_archived
FROM DmOps.Archive_ConsumerLog
GROUP BY crdtr_id
ORDER BY accounts_archived DESC;

### query #2  [metadata_id: 3927]
Title: Accounts not yet BIDATA migrated
Description: Accounts that were archived but whose BIDATA P-to-C migration has not been confirmed.

SELECT
    cl.batch_id,
    cl.cnsmr_id,
    cl.cnsmr_idntfr_agncy_id,
    cl.cnsmr_accnt_id,
    cl.cnsmr_accnt_idntfr_agncy_id,
    bl.batch_start_dttm
FROM DmOps.Archive_ConsumerLog cl
JOIN DmOps.Archive_BatchLog bl ON cl.batch_id = bl.batch_id
WHERE cl.bidata_migrated = 0
  AND bl.status = 'Success'
ORDER BY bl.batch_start_dttm;

### description / batch_id #1  [metadata_id: 3776]

FK to Archive_BatchLog. Identifies which batch this record was archived in. Part of the composite primary key.

### description / bidata_migrated #7  [metadata_id: 3784]

Whether this account's BIDATA records have been migrated from the P (production) tables to the C (static) tables. Set to 1 after successful P-to-C transaction for the batch. Default 0. Enables reconciliation queries to identify accounts archived but not yet migrated.

### description / cnsmr_accnt_id #4  [metadata_id: 3779]

Internal account ID from crs5_oltp. The system-generated primary key for the account record. Part of the composite primary key.

### description / cnsmr_accnt_idntfr_agncy_id #5  [metadata_id: 3780]

Agency-assigned account identifier visible in the Debt Manager GUI. The human-readable account number used by operations staff.

### description / cnsmr_id #2  [metadata_id: 3777]

Internal consumer ID from crs5_oltp. The system-generated primary key for the consumer record.

### description / cnsmr_idntfr_agncy_id #3  [metadata_id: 3778]

Agency-assigned consumer identifier visible in the Debt Manager GUI. The human-readable consumer number used by operations staff.

### description / crdtr_id #6  [metadata_id: 3781]

Creditor (client) ID from cnsmr_accnt.crdtr_id. Enables archive counts by client for reporting and business review.

### description / created_dttm #8  [metadata_id: 3782]

When this record was logged. Defaulted to GETDATE(). Represents the time the batch captured this record, not the time the account data was deleted.

## Archive_Schedule (Table)

### category #0  [metadata_id: 3699]

Archive

### description #0  [metadata_id: 3697]

Weekly schedule grid controlling archive execution mode per hour. Seven rows (one per day of week) with 24 tinyint columns representing hours. Each cell is 0 (blocked), 1 (full batch size), or 2 (reduced batch size). Execute-DmArchive.ps1 reads the current day/hour cell to determine whether to run and at what batch size. Managed via the DM Operations CC page schedule modal with drag-to-paint interaction.

### module #0  [metadata_id: 3698]

DmOps

### description / created_by #27  [metadata_id: 3726]

Who created this schedule row.

### description / created_dttm #26  [metadata_id: 3725]

When this schedule row was created.

### description / day_of_week #1  [metadata_id: 3700]

Day of week: 1=Sunday, 2=Monday, 3=Tuesday, 4=Wednesday, 5=Thursday, 6=Friday, 7=Saturday. Matches SQL Server DATEPART(dw) convention.

### description / hr00 #2  [metadata_id: 3701]

Execution mode for midnight to 1 AM. 0=blocked, 1=full batch, 2=reduced batch.

### status_value / hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 #1  [metadata_id: 3729]
Title: 0

Blocked. Archive processing will not run during this hour. Script exits cleanly if currently in a blocked window.

### status_value / hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 #2  [metadata_id: 3730]
Title: 1

Full. Archive processing runs at the full batch size configured in GlobalConfig (batch_size). Intended for off-hours and weekends.

### status_value / hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 #3  [metadata_id: 3731]
Title: 2

Reduced. Archive processing runs at the reduced batch size configured in GlobalConfig (batch_size_reduced). Intended for business hours to minimize end-user impact.

### description / hr01 #3  [metadata_id: 3702]

Execution mode for 1 AM to 2 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr02 #4  [metadata_id: 3703]

Execution mode for 2 AM to 3 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr03 #5  [metadata_id: 3704]

Execution mode for 3 AM to 4 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr04 #6  [metadata_id: 3705]

Execution mode for 4 AM to 5 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr05 #7  [metadata_id: 3706]

Execution mode for 5 AM to 6 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr06 #8  [metadata_id: 3707]

Execution mode for 6 AM to 7 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr07 #9  [metadata_id: 3708]

Execution mode for 7 AM to 8 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr08 #10  [metadata_id: 3709]

Execution mode for 8 AM to 9 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr09 #11  [metadata_id: 3710]

Execution mode for 9 AM to 10 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr10 #12  [metadata_id: 3711]

Execution mode for 10 AM to 11 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr11 #13  [metadata_id: 3712]

Execution mode for 11 AM to noon. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr12 #14  [metadata_id: 3713]

Execution mode for noon to 1 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr13 #15  [metadata_id: 3714]

Execution mode for 1 PM to 2 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr14 #16  [metadata_id: 3715]

Execution mode for 2 PM to 3 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr15 #17  [metadata_id: 3716]

Execution mode for 3 PM to 4 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr16 #18  [metadata_id: 3717]

Execution mode for 4 PM to 5 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr17 #19  [metadata_id: 3718]

Execution mode for 5 PM to 6 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr18 #20  [metadata_id: 3719]

Execution mode for 6 PM to 7 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr19 #21  [metadata_id: 3720]

Execution mode for 7 PM to 8 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr20 #22  [metadata_id: 3721]

Execution mode for 8 PM to 9 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr21 #23  [metadata_id: 3722]

Execution mode for 9 PM to 10 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr22 #24  [metadata_id: 3723]

Execution mode for 10 PM to 11 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr23 #25  [metadata_id: 3724]

Execution mode for 11 PM to midnight. 0=blocked, 1=full batch, 2=reduced batch.

### description / modified_by #29  [metadata_id: 3728]

Who last modified this schedule row.

### description / modified_dttm #28  [metadata_id: 3727]

When this schedule row was last modified.

## Archive_WorkgroupRegistry (Table)

### category #0  [metadata_id: 5099]

Archive

### description #0  [metadata_id: 5097]

Authoritative registry of the DM workgroups that constitute the archive candidate pool, per line of business (1P/3P). The DM nightly tagging jobs (account-level JA_ARCH* and consumer-level JC_ARCH*) filter their candidate selection against the active rows in this table via cross-database reference, so pool changes are a row insert/update here rather than a DM job edit. Deliberately excludes the archive destination workgroups (WFAARCH1/WFAARCH3): this table defines where candidates come FROM, never where the archive process operates.

### design_note #1  [metadata_id: 5111]
Title: Explicit List Over Pattern Matching

Workgroup membership is an explicit per-row decision rather than a name-pattern rule. Explicit rows make inclusion a deliberate act with an audit trail.

### module #0  [metadata_id: 5098]

DmOps

### description / created_by #7  [metadata_id: 5106]

Login that created the row.

### description / created_dttm #6  [metadata_id: 5105]

Row creation timestamp.

### description / description #4  [metadata_id: 5103]

Free-text rationale for the workgroup's inclusion in the candidate pool (client context, in-scope confirmation date, etc.).

### description / is_active #5  [metadata_id: 5104]

Soft enable/disable. Inactive rows are retained for history but excluded by all consumers.

### description / lob #3  [metadata_id: 5102]

Line of business this workgroup belongs to: 1P (first party) or 3P (third party). Each tagger job selects only its own LOB slice.

### status_value / lob #1  [metadata_id: 5109]
Title: 1P

First-party line of business. Candidate pool for the JA_ARCH1/JC_ARCH1 nightly jobs feeding WFAARCH1.

### status_value / lob #2  [metadata_id: 5110]
Title: 3P

Third-party line of business. Candidate pool for the JA_ARCH3/JC_ARCH3 nightly jobs feeding WFAARCH3.

### description / modified_by #9  [metadata_id: 5108]

Login that performed the most recent modification. NULL when never modified.

### description / modified_dttm #8  [metadata_id: 5107]

Timestamp of the most recent modification. NULL when never modified.

### description / registry_id #1  [metadata_id: 5100]

Surrogate identity key.

### description / wrkgrp_shrt_nm #2  [metadata_id: 5101]

DM workgroup short name, matching crs5_oltp.dbo.wrkgrp.wrkgrp_shrt_nm (VARCHAR(8)). Stored by name rather than wrkgrp_id because names are stable across environments while ids are environment-specific surrogates; consumers resolve the id at point of use.

## Execute-DmConsumerArchive.ps1 (Script)

### category #0  [metadata_id: 4907]

Archive

### data_flow #0  [metadata_id: 4912]

Reads execution options from dbo.GlobalConfig (module DmOps, category Archive). Reads server enable flag from dbo.ServerRegistry (dmops_archive_enabled). Reads schedule mode from DmOps.Archive_Schedule by current day and hour. Resolves four startup lookups against crs5_oltp (actn_cd, rslt_cd, usr, tag) to translate human-readable GlobalConfig values into internal IDs needed for the runtime re-verification path. Selects TC_ARCH-tagged consumers from crs5_oltp via cnsmr_Tag joined to tag. Re-verifies each candidate consumer at processing time using Pattern B eligibility logic (count of consumer accounts equals count of those accounts carrying TA_ARCH); excepted consumers are removed from the batch, soft-deleted from cnsmr_Tag, and an AR event is written to cnsmr_accnt_ar_log. Executes a 230-step delete sequence against crs5_oltp using a persistent SqlConnection — account-level Phase 1 UDEFs and Phase 2 deletes (orders A1-A117 and AU*), then BIDATA P-to-C migration (orders AB1-AB4) on a separate persistent connection, then consumer-level Phase 1 UDEFs and Phase 2 deletes (orders C1-C110 and CU*). Writes batch summaries to DmOps.Archive_BatchLog, per-table detail to DmOps.Archive_BatchDetail, per-consumer audit trail to DmOps.Archive_ConsumerLog, and excepted-consumer records to DmOps.Archive_ConsumerExceptionLog. Queues Teams alerts via Send-TeamsAlert on batch failure. Reports completion to the orchestrator via Complete-OrchestratorTask.

### description #0  [metadata_id: 4911]

PowerShell engine process for consumer-level archiving. Runs from FA-SQLDBB, targets any crs5_oltp instance via configuration. Selects consumers tagged TC_ARCH, performs runtime re-verification to confirm continued eligibility (excepting consumers whose account state has changed since tagging), and executes a unified hardcoded FK-ordered delete sequence covering both account-level and consumer-level removal. BIDATA P-to-C migration is interleaved between the account-level and consumer-level phases, ensuring financial reporting records are preserved with reentrant safety on partial failure. Replaces Execute-DmArchive.ps1, resolving the distributed-payment journal-mismatch issue inherent in account-level archiving. Schedule-aware with continuous batch loop, full batch/detail/consumer/exception logging, emergency abort, and Teams alerting. Preview mode by default.

### design_note #1  [metadata_id: 4913]
Title: Consumer-Level Archive Driver

The script archives at the consumer level rather than the account level. A consumer becomes archive-eligible only when every account on the consumer carries TA_ARCH; a separate nightly DM job evaluates this condition and applies TC_ARCH to qualifying consumers. xFACts then archives by consumer, removing every account, transaction, and consumer-level record in a single coordinated operation. This resolves the distributed-payment journal-mismatch issue that prevented safe account-level archiving — when a consumer payment was distributed across multiple accounts, account-level archiving could leave the consumer-level cnsmr_pymnt_jrnl row referencing a partial account set, putting the consumer into a state the DM UI rejects. Consumer-level archiving has no such intermediate state because there is no surviving account to mismatch with.

### design_note #2  [metadata_id: 4914]
Title: Runtime Re-Verification

TC_ARCH is point-in-time. Between when the apply-job tags a consumer and when xFACts processes the consumer, new accounts can merge in (new business loads, account splits, manual activity), invalidating eligibility. Each batch re-verifies every TC_ARCH candidate at processing time using Pattern B logic — the same eligibility check the apply-job uses, inverted to find candidates who no longer qualify. Excepted consumers are unconditionally removed from the batch first, then best-effort soft-deleted from cnsmr_Tag and a CC/CC AR event is written to cnsmr_accnt_ar_log noting the tag removal. A row is appended to Archive_ConsumerExceptionLog with confirmation flags. Excepted consumers are released back to the DM apply-job for future re-tagging once their account state changes; xFACts does no backfill. The batch processes whatever consumers pass the check.

### design_note #3  [metadata_id: 4915]
Title: Persistent SqlConnection

The script maintains a single persistent System.Data.SqlClient.SqlConnection to crs5_oltp for the entire session. Temp tables created on this connection persist across all delete operations within a batch — both the account-level and consumer-level halves operate on the same connection without re-establishing state. A separate persistent connection is opened to BIDATA for the P-to-C migration step and held open for the duration of the session. The xFACts database is accessed via the platform wrappers (Get-SqlData, Invoke-SqlNonQuery) which manage their own connections.

### design_note #4  [metadata_id: 4916]
Title: Pre-Materialized Intermediate ID Tables

Account-level intermediate temp tables are populated once per batch from the core account ID set: ar_log IDs, transaction IDs, payment journal IDs, payment journal transaction IDs, and encounter IDs — each gets a clustered index. After the BIDATA migration completes, consumer-level temp tables (#shell_*) are populated from the consumer ID set for use in the consumer-level delete sequence. Delete operations reference these temp tables instead of re-joining through the FK chains, reducing deep multi-table joins to simple IN clauses. This pattern carries over from the prior account-level script and was extended to cover consumer-level operations.

### design_note #5  [metadata_id: 4917]
Title: Hardcoded Delete Sequence with Prefix Scheme

The delete sequence is hardcoded in the script using a unified prefix scheme that distinguishes the four operational halves: A1-A117 for account-level Phase 2 deletes, AU* for account-level UDEF Phase 1, AB1-AB4 for BIDATA P-to-C migration, C1-C110 for consumer-level Phase 2 deletes, and CU* for consumer-level UDEF Phase 1. The single namespace via prefix lets the two halves evolve independently without renumbering each other, and Archive_BatchDetail rows can be filtered by prefix (e.g., WHERE delete_order LIKE C%) for halve-specific analysis. The sequence is static — changes require a script update — which eliminates the overhead and complexity of runtime registry reads and ensures the FK ordering is exactly as validated during testing.

### design_note #6  [metadata_id: 4918]
Title: BIDATA P-to-C Migration Mid-Batch Timing

BIDATA migration is placed between the account-level and consumer-level delete phases — not at start, not at end. Placing it at start would risk repopulation: if the OLTP delete fails, the next BIDATA daily build would regenerate P rows from OLTP (account still exists), creating duplicates against the C rows already migrated. Placing it at end would risk irrecoverable loss: if consumer-level deletes succeed but BIDATA migration fails, the consumer is gone from OLTP with no reporting record migrated. Mid-batch placement gives both safety properties — the next BIDATA build will not regenerate P rows for accounts no longer in OLTP, and a consumer-level delete failure leaves the consumer in a recoverable near-shell state that retry can complete. BIDATA migration failure halts the batch; consumer-level deletes are skipped to preserve recoverability.

### design_note #7  [metadata_id: 4919]
Title: Stop-on-Failure Pattern

A script-level $StopProcessing flag halts the delete sequence on the first table failure. Once a table fails, all subsequent tables are skipped to prevent cascading FK violations from attempting to delete parent tables when their children were not fully cleaned. The batch is logged as Failed and a Teams alert is queued. Abort flag is checked between full batches only — never mid-batch — so a partial batch always completes its current sequence before the script exits.

### design_note #8  [metadata_id: 4920]
Title: Non-Blocking Delete Strategy

Every DELETE in the sequence executes under SNAPSHOT isolation with DEADLOCK_PRIORITY LOW and chunked batching to ensure zero impact on production users. SNAPSHOT isolation means readers never wait for our deletes — they read from the version store (a point-in-time snapshot in tempdb) while we hold exclusive locks on rows being deleted. Users see a consistent view of the data completely unaware that rows are being removed underneath them. DEADLOCK_PRIORITY LOW ensures that if a deadlock occurs between our DELETE and any user operation, SQL Server always kills our session — never the user's. The script catches deadlock errors (1205), snapshot conflicts (3960), lock timeouts (1222), and resource limits (1204), waits 5 seconds, and retries up to 10 times. In practice deadlocks at SNAPSHOT isolation are rare — the retry exists as a safety net. Chunked deletes (DELETE TOP 5000) prevent any single statement from holding locks for extended periods. Between each chunk a 100ms pause gives other operations a window to acquire locks. The chunk size is configurable via GlobalConfig. After a retry, the isolation level is explicitly reset to READ COMMITTED to prevent a stuck session state on the persistent connection.

### module #0  [metadata_id: 4908]

DmOps

### relationship_note #1  [metadata_id: 4921]
Title: Archive_BatchLog

Primary output. One row inserted per batch after re-verification with Running status, updated on completion with consumer/account counts, exception count, row totals, timing, status, and BIDATA migration outcome.

### relationship_note #2  [metadata_id: 4922]
Title: Archive_BatchDetail

Detailed output. One row per table operation per batch, written inline during the delete sequence. Captures delete order (with prefix indicating halve and phase), table name, pass description, rows affected, duration, and status.

### relationship_note #3  [metadata_id: 4923]
Title: Archive_ConsumerLog

Audit trail output. One row per consumer-account pair written at the start of each batch before deletions begin. Includes consumer and account identifiers plus creditor ID for BI cross-reference. bidata_migrated flag updated after successful P-to-C migration.

### relationship_note #4  [metadata_id: 4924]
Title: Archive_ConsumerExceptionLog

Exception output. One row per consumer that failed runtime re-verification within a batch. Captures consumer ID, agency identifier, detection timestamp, and confirmation flags (tag_removed, ar_event_written) showing which downstream operations succeeded. The batch_id is retained for audit context but is not enforced as a foreign key — exception rows can outlive their originating batch.

### relationship_note #5  [metadata_id: 4925]
Title: Archive_Schedule

Schedule input. Read between batches to determine whether to continue processing and at what batch size. Mode transitions (Full to Reduced, etc.) are detected and logged.

### relationship_note #6  [metadata_id: 4926]
Title: GlobalConfig

Configuration input. Reads all DmOps/Archive settings at startup: target_instance, bidata_instance, batch_size, batch_size_reduced, chunk_size, alerting_enabled, archive_abort, bidata_build_job_name, plus four runtime re-verification parameters (tag_removal_actn_cd, tag_removal_rslt_cd, tag_removal_user, tag_removal_msg_txt) that are resolved against crs5_oltp lookup tables at startup.

### relationship_note #7  [metadata_id: 4927]
Title: crs5_oltp.dbo.cnsmr_Tag / cnsmr_accnt_ar_log

Runtime re-verification write target. For each excepted consumer, the script issues a soft-delete UPDATE against the active TC_ARCH row in cnsmr_Tag and an INSERT into cnsmr_accnt_ar_log recording the tag removal as a CC/CC internal-comment AR event. These are the only writes the script issues against crs5_oltp outside of the deletion sequence itself. Both operations are best-effort — the consumer is unconditionally removed from the in-memory batch first, so subsequent write failures cannot cause the consumer to be archived against current eligibility.

## Execute-DmShellPurge.ps1 (Script)

### category #0  [metadata_id: 3864]

ShellPurge

### data_flow #0  [metadata_id: 3900]

Reads execution options from dbo.GlobalConfig (module DmOps, category ShellPurge). Reads server enable flag from dbo.ServerRegistry (dmops_shell_purge_enabled). Reads schedule mode from DmOps.ShellPurge_Schedule by current day and hour. Loads known exclusions from DmOps.ShellPurge_ExclusionLog into a temp table on the target connection for per-batch filtering. Selects shell consumers from crs5_oltp in the WFAPURGE workgroup with no cnsmr_accnt records and not in the exclusion set. Validates batch candidates against exclusion tables and logs new discoveries. Executes a consumer-level delete sequence derived from sp_Delete_EmptyShell_Consumers with dynamic UDEF discovery. Writes batch summaries to DmOps.ShellPurge_BatchLog, per-table detail to DmOps.ShellPurge_BatchDetail, and per-consumer audit trail to DmOps.ShellPurge_ConsumerLog. Queues Teams alerts via Send-TeamsAlert on batch failure. Reports completion to the orchestrator via Complete-OrchestratorTask.

### description #0  [metadata_id: 3862]

PowerShell engine process for consumer shell purge. Runs from FA-SQLDBB, targets any crs5_oltp instance via configuration. Selects orphaned consumers in the WFAPURGE workgroup with no remaining accounts, validates against the ShellPurge_ExclusionLog, and executes a consumer-level delete sequence derived from Matt's sp_Delete_EmptyShell_Consumers. Schedule-aware with continuous batch loop, full batch/detail/consumer logging, emergency abort, and Teams alerting. Preview mode by default.

### design_note #1  [metadata_id: 3901]
Title: Exclusion Log Pattern

Consumers with data in tables not covered by the delete sequence (cnsmr_pymnt_jrnl, dcmnt_rqst, agnt_crdtbl_actvty, bnkrptcy, schdld_pymnt_smmry, sspns_trnsctn_cnsmr_idntfr) are excluded rather than partially deleted. The ShellPurge_ExclusionLog table is seeded by a one-time population script and maintained incrementally as the purge script discovers new exclusions during batch validation. At session start, the exclusion log is loaded into a temp table on the target connection for efficient per-batch filtering without cross-database queries.

### design_note #2  [metadata_id: 3902]
Title: Delete Sequence Source

The consumer-level delete sequence is derived from Matt's sp_Delete_EmptyShell_Consumers, which handles a streamlined subset of consumer-linked tables. This is a deliberate departure from the full Phase 3/4 sequence in the vendor archive proc — the vendor proc covers deep FK chains through tables like cnsmr_pymnt_instrmnt and schdld_pymnt_smmry that the exclusion pattern already filters out. Matt's approach is safer: if a shell has complex residual data, skip it.

### design_note #3  [metadata_id: 3903]
Title: Workgroup-Based Selection

Selection targets the WFAPURGE workgroup exclusively. A nightly DM scheduled job moves shell consumers (those with no cnsmr_accnt records) into WFAPURGE automatically. This decouples eligibility criteria from the purge script — modifying which consumers become eligible is a DM configuration change, not a script change.

### design_note #4  [metadata_id: 3904]
Title: Session-Cached Exclusions

The exclusion log is loaded from xFACts into a temp table on the target connection once per session. Subsequent batches reuse the temp table without re-querying xFACts. New exclusions discovered during batch validation are added to both the permanent ExclusionLog (for future sessions) and the temp table (for the current session). This eliminates cross-database query requirements and keeps batch selection fast.

### design_note #5  [metadata_id: 3905]
Title: FK Supporting Indexes

25 nonclustered indexes on child tables referencing dbo.cnsmr are required for acceptable DELETE performance on the terminal cnsmr delete. Without these, FK validation during the cnsmr DELETE triggers full table scans on every child table. With indexes, the terminal delete dropped from 121 seconds to 2.2 seconds for 100 consumers.

### design_note #6  [metadata_id: 3929]
Title: Non-Blocking Delete Strategy

Identical non-blocking pattern to Execute-DmArchive.ps1. Every DELETE executes under SNAPSHOT isolation (readers never blocked), DEADLOCK_PRIORITY LOW (user operations always win deadlock resolution), and chunked batching (DELETE TOP 5000 with 100ms inter-chunk pause). Retryable errors (1205 deadlock, 3960 snapshot conflict, 1222 lock timeout, 1204 resource limit) trigger up to 10 retries with 5-second waits. Isolation level is reset to READ COMMITTED after any retry to prevent stuck session state. The combination ensures that shell purge operations running during business hours at reduced batch sizes have no observable impact on the 200+ daily users of the Debt Manager application.

### module #0  [metadata_id: 3863]

DmOps

### relationship_note #1  [metadata_id: 3906]
Title: ShellPurge_BatchLog

Primary output. One row inserted per batch at start (Running), updated on completion with consumer counts, row totals, timing, and status.

### relationship_note #2  [metadata_id: 3907]
Title: ShellPurge_BatchDetail

Detailed output. One row per table operation per batch, written inline during the delete sequence. Captures delete order, table name, pass description, rows affected, duration, and status.

### relationship_note #3  [metadata_id: 3908]
Title: ShellPurge_ConsumerLog

Audit trail output. One row per consumer written at the start of each batch before deletions begin. Captures consumer ID and agency identifier.

### relationship_note #4  [metadata_id: 3909]
Title: ShellPurge_ExclusionLog

Exclusion filter and discovery target. Loaded into a session temp table at startup. New exclusions discovered during batch validation are appended here for future sessions.

### relationship_note #5  [metadata_id: 3910]
Title: ShellPurge_Schedule

Schedule input. Read between batches to determine whether to continue processing and at what batch size.

### relationship_note #6  [metadata_id: 3911]
Title: GlobalConfig

Configuration input. Reads all DmOps/ShellPurge settings at startup: target_instance, batch_size, batch_size_reduced, chunk_size, alerting_enabled, shell_purge_abort, exclude_suspense.

## ShellPurge_BatchDetail (Table)

### category #0  [metadata_id: 3815]

ShellPurge

### data_flow #0  [metadata_id: 3916]

Execute-DmShellPurge.ps1 inserts one row per table operation during the delete sequence. Written inline as each table is processed — not batch-inserted at the end. Status is set at write time based on whether the delete succeeded, was skipped (zero rows), or failed.

### description #0  [metadata_id: 3813]

Per-table operation detail within each shell purge batch. One row per table in the delete sequence per batch, capturing the delete order, table name, rows affected, duration, and status. Provides a full replay of every batch execution for audit trails and troubleshooting.

### module #0  [metadata_id: 3814]

DmOps

### query #1  [metadata_id: 3917]
Title: Batch detail replay
Description: Full detail for a specific batch — shows every table operation in execution order.

DECLARE @BatchId BIGINT = 0; -- Set to target batch_id

SELECT
    delete_order,
    table_name,
    pass_description,
    rows_affected,
    duration_ms,
    status,
    error_message
FROM DmOps.ShellPurge_BatchDetail
WHERE batch_id = @BatchId
ORDER BY detail_id;

### query #2  [metadata_id: 3918]
Title: Slowest table operations
Description: Tables with the longest delete times — candidates for index investigation.

SELECT TOP 20
    table_name,
    pass_description,
    AVG(duration_ms) AS avg_ms,
    MAX(duration_ms) AS max_ms,
    SUM(rows_affected) AS total_rows,
    COUNT(*) AS executions
FROM DmOps.ShellPurge_BatchDetail
WHERE status = 'Success'
  AND rows_affected > 0
GROUP BY table_name, pass_description
ORDER BY avg_ms DESC;

### description / batch_id #2  [metadata_id: 3817]

FK to ShellPurge_BatchLog. Identifies which batch this table operation belongs to.

### description / created_dttm #10  [metadata_id: 3825]

When this detail row was created. Defaulted to GETDATE().

### description / delete_order #3  [metadata_id: 3818]

Execution order from the delete sequence. Varchar to accommodate UDEF dynamic orders (U1, U2, etc.) alongside numeric orders. Matches the order logged in the script output.

### description / detail_id #1  [metadata_id: 3816]

Auto-incrementing primary key.

### description / duration_ms #7  [metadata_id: 3822]

Time in milliseconds for this specific table operation. NULL for skipped tables.

### description / error_message #9  [metadata_id: 3824]

Error detail when status is Failed. NULL for successful and skipped operations.

### description / pass_description #5  [metadata_id: 3820]

Human-readable description of the FK path for this delete operation. NULL for single-pass tables. Examples: via pymnt_jrnl, via smmry, Pass 1: direct, Pass 2: via pymnt_jrnl.

### description / rows_affected #6  [metadata_id: 3821]

Number of rows deleted (execute mode) or that would be deleted (preview mode). Zero for skipped tables.

### description / status #8  [metadata_id: 3823]

Outcome of this individual table operation.

### status_value / status #1  [metadata_id: 3826]
Title: Success

Table operation completed successfully. rows_affected contains the count of deleted rows.

### status_value / status #2  [metadata_id: 3827]
Title: Skipped

Table had zero rows matching the WHERE clause. No delete was executed.

### status_value / status #3  [metadata_id: 3828]
Title: Failed

Table operation failed. error_message contains the exception detail. The script stops further processing after any failure.

### description / table_name #4  [metadata_id: 3819]

Target table name in crs5_oltp. Combined with delete_order and pass_description, uniquely identifies each operation in the delete sequence.

## ShellPurge_BatchLog (Table)

### category #0  [metadata_id: 3791]

ShellPurge

### data_flow #0  [metadata_id: 3912]

Execute-DmShellPurge.ps1 inserts a Running row at batch start with schedule mode and batch size. On batch completion, updates the row with consumer count, total rows deleted, table processing counts, duration, and final status. The CC DM Operations page reads this table for execution history display and daily summary metrics.

### description #0  [metadata_id: 3789]

One row per shell purge batch execution. Captures the full execution summary including schedule mode, batch size, consumer counts, row deletion totals, per-table processing counts, timing, and final status. Primary audit and reporting table for shell purge operations.

### module #0  [metadata_id: 3790]

DmOps

### query #1  [metadata_id: 3913]
Title: Recent batch history
Description: Shows the last 20 shell purge batches with key metrics.

SELECT TOP 20
    batch_id,
    batch_start_dttm,
    schedule_mode,
    consumer_count,
    total_rows_deleted,
    tables_processed,
    tables_failed,
    duration_ms,
    status,
    executed_by
FROM DmOps.ShellPurge_BatchLog
ORDER BY batch_id DESC;

### query #2  [metadata_id: 3914]
Title: Daily purge summary
Description: Aggregated daily totals for consumers purged and rows deleted.

SELECT
    CAST(batch_start_dttm AS DATE) AS purge_date,
    COUNT(*) AS batches,
    SUM(consumer_count) AS total_consumers,
    SUM(total_rows_deleted) AS total_rows,
    SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS failed_batches,
    SUM(duration_ms) / 1000 AS total_seconds
FROM DmOps.ShellPurge_BatchLog
WHERE status IN ('Success', 'Failed')
GROUP BY CAST(batch_start_dttm AS DATE)
ORDER BY purge_date DESC;

### query #3  [metadata_id: 3915]
Title: Failed batches with error detail
Description: All failed batches with their error messages for investigation.

SELECT
    batch_id,
    batch_start_dttm,
    consumer_count,
    tables_failed,
    duration_ms,
    error_message
FROM DmOps.ShellPurge_BatchLog
WHERE status = 'Failed'
ORDER BY batch_start_dttm DESC;

### description / batch_end_dttm #3  [metadata_id: 3794]

When this batch execution completed. NULL while the batch is still running. Updated on completion regardless of success or failure.

### description / batch_id #1  [metadata_id: 3792]

Auto-incrementing primary key. Referenced by ShellPurge_BatchDetail and ShellPurge_ConsumerLog as the parent batch identifier.

### description / batch_size_used #5  [metadata_id: 3796]

Actual batch size (number of consumers) used for this batch. Reflects the GlobalConfig value corresponding to the schedule mode, or a manual override.

### description / batch_start_dttm #2  [metadata_id: 3793]

When this batch execution started. Defaulted to GETDATE() on insert. Used for daily summary aggregation and execution history display.

### description / consumer_count #6  [metadata_id: 3797]

Number of shell consumers selected in this batch. May be less than batch_size_used if fewer eligible consumers remain in the WFAPURGE workgroup.

### description / duration_ms #11  [metadata_id: 3802]

Total batch execution time in milliseconds. NULL while the batch is still running.

### description / error_message #13  [metadata_id: 3804]

Error detail when status is Failed. NULL on successful completion. Captures the first failure message from the delete sequence.

### description / executed_by #14  [metadata_id: 3805]

Windows identity that executed this batch. Defaulted to SUSER_SNAME(). Distinguishes service account execution from manual runs.

### description / schedule_mode #4  [metadata_id: 3795]

Which schedule mode was active when this batch ran. Determines the batch size used and provides historical context for performance analysis.

### status_value / schedule_mode #1  [metadata_id: 3810]
Title: Full

Batch ran during a full-mode schedule window using the standard batch_size from GlobalConfig.

### status_value / schedule_mode #2  [metadata_id: 3811]
Title: Reduced

Batch ran during a reduced-mode schedule window using batch_size_reduced from GlobalConfig.

### status_value / schedule_mode #3  [metadata_id: 3812]
Title: Manual

Batch ran with manual parameter overrides, outside of schedule-driven execution.

### description / status #12  [metadata_id: 3803]

Final outcome of the batch execution.

### status_value / status #1  [metadata_id: 3806]
Title: Running

Batch is currently executing. Set on initial insert, updated to final status on completion.

### status_value / status #2  [metadata_id: 3807]
Title: Success

Batch completed with zero table failures.

### status_value / status #3  [metadata_id: 3808]
Title: Failed

One or more tables in the delete sequence failed. The script stops on first failure. Check error_message and ShellPurge_BatchDetail for specifics.

### status_value / status #4  [metadata_id: 3809]
Title: Aborted

Batch was terminated by the shell_purge_abort emergency shutoff flag in GlobalConfig. The current batch completed but no further batches were started.

### description / tables_failed #10  [metadata_id: 3801]

Number of tables in the delete sequence where the DELETE operation failed. Any value greater than zero results in a Failed batch status.

### description / tables_processed #8  [metadata_id: 3799]

Number of tables in the delete sequence that had rows deleted (non-zero row count).

### description / tables_skipped #9  [metadata_id: 3800]

Number of tables in the delete sequence that had zero rows and were skipped.

### description / total_rows_deleted #7  [metadata_id: 3798]

Sum of all rows deleted across all tables in the delete sequence. In preview mode, this is the count of rows that would be deleted.

## ShellPurge_ConsumerExceptionLog (Table)

### category #0  [metadata_id: 3850]

ShellPurge

### data_flow #0  [metadata_id: 3919]

Maintained incrementally by Execute-DmShellPurge.ps1 which inserts new excluded consumers discovered during batch validation. Read by the script at session start to load into a temp table on the target connection for per-batch candidate filtering. A consumer may have multiple rows with different exception reasons.

### description #0  [metadata_id: 3848]

Consumers excluded from shell purge due to qualifying data in tables not covered by the delete sequence. One row per consumer per exception reason. Maintained incrementally as the shell purge script discovers new exceptions during batch validation. Used as a filter in the candidate selection query to avoid re-evaluating expensive NOT EXISTS checks against large tables on every batch.

### module #0  [metadata_id: 3849]

DmOps

### query #1  [metadata_id: 3920]
Title: Count of excluded consumers per exception reason — shows which tables block the most shells.
Description: Count of excluded consumers per exception reason — shows which tables block the most shells.

SELECT      exception_reason,      COUNT(*) AS consumer_count  FROM DmOps.ShellPurge_ConsumerExceptionLog  GROUP BY exception_reason  ORDER BY consumer_count DESC;

### query #2  [metadata_id: 3921]
Title: Consumers with multiple exception reasons
Description: Consumers blocked by more than one exception — may need different remediation approaches.

SELECT      cnsmr_id,      cnsmr_idntfr_agncy_id,      COUNT(*) AS reason_count,      STRING_AGG(exception_reason, ', ') AS reasons  FROM DmOps.ShellPurge_ConsumerExceptionLog  GROUP BY cnsmr_id, cnsmr_idntfr_agncy_id  HAVING COUNT(*) > 1  ORDER BY reason_count DESC;

### query #3  [metadata_id: 3922]
Title: Consumers with only dcmnt_rqst exceptions
Description: Consumers whose sole exception reason is dcmnt_rqst.

SELECT e.cnsmr_id, e.cnsmr_idntfr_agncy_id  FROM DmOps.ShellPurge_ConsumerExceptionLog e  WHERE e.exception_reason = 'dcmnt_rqst'    AND NOT EXISTS (        SELECT 1 FROM DmOps.ShellPurge_ConsumerExceptionLog e2        WHERE e2.cnsmr_id = e.cnsmr_id          AND e2.exception_reason <> 'dcmnt_rqst'    );

### description / cnsmr_id #1  [metadata_id: 3851]

Internal consumer ID from crs5_oltp. Part of the composite primary key with exception_reason.

### description / cnsmr_idntfr_agncy_id #2  [metadata_id: 3852]

Agency-assigned consumer identifier. Stored for human-readable reference during triage and reporting.

### description / created_dttm #4  [metadata_id: 3854]

SELECT      exception_reason,      COUNT(*) AS consumer_count  FROM DmOps.ShellPurge_ConsumerExceptionLog  GROUP BY exception_reason  ORDER BY consumer_count DESC;

### description / exception_reason #3  [metadata_id: 3853]

Which exception check flagged this consumer. Matches the table or condition name from the exception check list. A consumer may have multiple rows with different reasons.

### status_value / exception_reason #1  [metadata_id: 3855]
Title: cnsmr_pymnt_jrnl

Consumer has rows in cnsmr_pymnt_jrnl. Payment journal data exists that is not deleted by the shell purge sequence.

### status_value / exception_reason #2  [metadata_id: 3856]
Title: dcmnt_rqst

Consumer has rows in dcmnt_rqst (entity association code 2). Document request data exists that is intentionally left as orphaned historical records.

### status_value / exception_reason #3  [metadata_id: 3857]
Title: agnt_crdtbl_actvty

Consumer has rows in agnt_crdtbl_actvty via direct cnsmr_id reference.

### status_value / exception_reason #4  [metadata_id: 3858]
Title: agnt_crdtbl_actvty_via_smmry

Consumer has agnt_crdtbl_actvty records reachable through the schdld_pymnt_smmry chain.

### status_value / exception_reason #5  [metadata_id: 3859]
Title: bnkrptcy

Consumer has rows in bnkrptcy. Bankruptcy records are retained for legal compliance.

### status_value / exception_reason #6  [metadata_id: 3860]
Title: schdld_pymnt_smmry

Consumer has rows in schdld_pymnt_smmry. Scheduled payment summary data exists that is not safely deletable without cascading through child tables.

### status_value / exception_reason #7  [metadata_id: 3861]
Title: sspns_trnsctn_cnsmr_idntfr

Consumer has rows in sspns_trnsctn_cnsmr_idntfr. Suspense transaction data may indicate in-flight payment processing. This exception is controlled by the exclude_suspense GlobalConfig setting.

## ShellPurge_ConsumerLog (Table)

### category #0  [metadata_id: 3831]

ShellPurge

### description #0  [metadata_id: 3829]

Audit trail of every consumer purged. One row per consumer per batch. Captures the minimum identifying fields needed for reconciliation and historical reference.

### module #0  [metadata_id: 3830]

DmOps

### description / batch_id #1  [metadata_id: 3832]

FK to ShellPurge_BatchLog. Identifies which batch this consumer was purged in. Part of the composite primary key.

### description / cnsmr_id #2  [metadata_id: 3833]

Internal consumer ID from crs5_oltp. The system-generated primary key for the consumer record that was purged.

### description / cnsmr_idntfr_agncy_id #3  [metadata_id: 3834]

Agency-assigned consumer identifier visible in the Debt Manager GUI. The human-readable consumer number used by operations staff.

### description / created_dttm #4  [metadata_id: 3835]

When this record was logged. Defaulted to GETDATE(). Represents the time the batch captured this record, not the time the consumer data was deleted.

## ShellPurge_Schedule (Table)

### category #0  [metadata_id: 3838]

ShellPurge

### description #0  [metadata_id: 3836]

Weekly schedule grid controlling shell purge execution mode per hour. Seven rows (one per day of week) with 24 tinyint columns representing hours. Each cell is 0 (blocked), 1 (full batch size), or 2 (reduced batch size). Execute-DmShellPurge.ps1 reads the current day/hour cell to determine whether to run and at what batch size.

### module #0  [metadata_id: 3837]

DmOps

### description / created_by #27  [metadata_id: 3842]

Who created this schedule row.

### description / created_dttm #26  [metadata_id: 3841]

When this schedule row was created.

### description / day_of_week #1  [metadata_id: 3839]

Day of week: 1=Sunday, 2=Monday, 3=Tuesday, 4=Wednesday, 5=Thursday, 6=Friday, 7=Saturday. Matches SQL Server DATEPART(dw) convention.

### description / hr00 #2  [metadata_id: 3840]

Execution mode for midnight to 1 AM. 0=blocked, 1=full batch, 2=reduced batch.

### status_value / hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 #1  [metadata_id: 3845]
Title: 0

Blocked. Shell purge processing will not run during this hour. Script exits cleanly if currently in a blocked window.

### status_value / hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 #2  [metadata_id: 3846]
Title: 1

Full. Shell purge processing runs at the full batch size configured in GlobalConfig (batch_size). Intended for off-hours and weekends.

### status_value / hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 #3  [metadata_id: 3847]
Title: 2

Reduced. Shell purge processing runs at the reduced batch size configured in GlobalConfig (batch_size_reduced). Intended for business hours to minimize end-user impact.

### description / hr01 #3  [metadata_id: 3866]

Execution mode for 1 AM to 2 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr02 #4  [metadata_id: 3867]

Execution mode for 2 AM to 3 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr03 #5  [metadata_id: 3868]

Execution mode for 3 AM to 4 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr04 #6  [metadata_id: 3869]

Execution mode for 4 AM to 5 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr05 #7  [metadata_id: 3870]

Execution mode for 5 AM to 6 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr06 #8  [metadata_id: 3871]

Execution mode for 6 AM to 7 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr07 #9  [metadata_id: 3872]

Execution mode for 7 AM to 8 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr08 #10  [metadata_id: 3873]

Execution mode for 8 AM to 9 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr09 #11  [metadata_id: 3874]

Execution mode for 9 AM to 10 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr10 #12  [metadata_id: 3875]

Execution mode for 10 AM to 11 AM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr11 #13  [metadata_id: 3876]

Execution mode for 11 AM to noon. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr12 #14  [metadata_id: 3877]

Execution mode for noon to 1 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr13 #15  [metadata_id: 3878]

Execution mode for 1 PM to 2 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr14 #16  [metadata_id: 3879]

Execution mode for 2 PM to 3 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr15 #17  [metadata_id: 3880]

Execution mode for 3 PM to 4 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr16 #18  [metadata_id: 3881]

Execution mode for 4 PM to 5 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr17 #19  [metadata_id: 3882]

Execution mode for 5 PM to 6 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr18 #20  [metadata_id: 3883]

Execution mode for 6 PM to 7 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr19 #21  [metadata_id: 3884]

Execution mode for 7 PM to 8 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr20 #22  [metadata_id: 3885]

Execution mode for 8 PM to 9 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr21 #23  [metadata_id: 3886]

Execution mode for 9 PM to 10 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr22 #24  [metadata_id: 3887]

Execution mode for 10 PM to 11 PM. 0=blocked, 1=full batch, 2=reduced batch.

### description / hr23 #25  [metadata_id: 3888]

Execution mode for 11 PM to midnight. 0=blocked, 1=full batch, 2=reduced batch.

### description / modified_by #29  [metadata_id: 3844]

Who last modified this schedule row.

### description / modified_dttm #28  [metadata_id: 3843]

When this schedule row was last modified.

## xFACts-DmOpsFunctions.ps1 (Script)

### category #0  [metadata_id: 5114]

Shared

### description #0  [metadata_id: 5112]

Shared deletion engine dot-sourced by the DmOps consumer scripts (Execute-DmConsumerArchive.ps1 and Execute-DmShellPurge.ps1). Provides one definition of the connection management, chunked SQL primitives, and operation and step wrappers both scripts use to delete and update against the crs5_oltp target instance, plus the shared batch-detail audit writer. Each consuming script supplies its own script-level state through a fixed set of $script:dmo_ names: the target connection and resolved settings, the current batch id, the per-batch counters, and the audit detail table the writer targets. The engine operates on those names rather than defining them, so a single shared copy serves both consumers.

### module #0  [metadata_id: 5113]

DmOps

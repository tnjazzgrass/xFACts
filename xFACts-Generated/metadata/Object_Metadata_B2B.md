# Object_Metadata: B2B
Source: dbo.Object_Metadata
Generated: 2026-07-23 08:09:17

## Collect-B2BPipeline.ps1 (Script)

### category #0  [metadata_id: 5216]

B2B

### data_flow #0  [metadata_id: 5217]

Step 1 (schedule sync): single JOIN query against b2bi.dbo.SCHEDULE and b2bi.dbo.DATA_TABLE on FA-INT-DBP fetches all schedule rows with their gzip-compressed TIMINGXML blobs (-MaxBinaryLength 20971520). Each blob is decompressed in-memory and parsed into structured columns and a human-readable schedule_description; the step diffs against B2B.SI_ScheduleRegistry and INSERTs new schedules, UPDATEs changed ones, and DELETEs rows whose schedule_id no longer appears in b2bi.    Step 2 (workflow census): queries b2bi.dbo.WFD deduplicated to MAX(WFD_VERSION) per WFD_ID and compares against B2B.SI_WorkflowRegistry: new definitions INSERT, version bumps UPDATE (preserving previous_version, stamping last_version_change_dttm, logging at WARN as the Sterling-edit drift signal), unchanged rows get last_synced_dttm touched in chunked IN-list UPDATEs. Registry rows absent from the source are logged and retained.    Steps 3-4 (pipeline mirror): one shared classified-source CTE runs on the listener against Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS joined to the FILES config (PROCESS_TYPE/COMM_METHOD via CLIENT_ID + SEQ_ID, the same derivation the Integration reconciliation job uses), the MN clients master (client_name snapshot), the crs5_oltp DM batch tables per process type (DM outcome verification for the -1 split), and a BATCH_FILES nonzero-size pickup EXISTS (the status-4 split). Step 3 INSERTs classified rows for source runs not yet mirrored, bounded by b2b_collect_lookback_days; step 4 re-polls tracked rows with is_complete = 0 inside the same window via a set-based UPDATE, re-stamping status, enrichment, classification, and completion.    Step 5 (dispatcher resolution): tracked rows missing dispatcher_name resolve COALESCE(parent_id, run_id) against b2bi WF_INST_S/WF_INST_S_RESTORE joined to WFD on WFD_ID + WFD_VERSION, in 500-id chunks, and UPDATE per distinct resolved name.    Step 6 (Sterling cross-check): in-flight rows (batch_status 0) older than b2b_inflight_aging_minutes are checked against WF_INST_S/WF_INST_S_RESTORE: instance present with NULL END_TIME marks sterling_check_result RUNNING; terminated or absent instances classify DIED_UNHANDLED (is_complete = 1, completed_dttm from Sterling END_TIME when available).    Step 7 (fault-report enrichment): Sterling-internal failures (STERLING_FAULT, DIED_UNHANDLED) with fault_report_captured_dttm NULL inside b2b_collect_lookback_days are enriched from b2bi. For each, the failing step's STATUS_RPT handle (BASIC_STATUS <> 0 on a report-producing service - Translation, XSLTService, InlineInvokeBusinessProcessService, MailMimeService) is resolved in WORKFLOW_CONTEXT, the gzip status-report blob is read from TRANS_DATA (parameterized, native byte array) and decompressed, and the report is parsed into one of three shapes (TRANSLATION, SERVICE, MESSAGE). The full parsed report writes to B2B.SI_FaultReport (one row per run) and the summary columns (fault_report_type, fault_report_code, fault_report_summary, fault_report_captured_dttm) snapshot onto INT_PipelineTracking. Failures with no extractable report are marked NONE so they are not re-attempted.    Step 8 (alerts): queries INT_PipelineTracking for failure classifications (STERLING_FAULT, DM_REJECTED, FAULT_POST_HANDOFF, DIED_UNHANDLED, NO_HANDOFF) with alert_count = 0 inside the working window, logs every detection, and queues a Teams alert via Send-TeamsAlert (trigger B2B_<classification> / run_id) and increments alert_count. A second check queries SI_WorkflowRegistry for version changes inside the window and queues a WARNING alert per edit (trigger B2B_WorkflowVersionChange / wfd_id-version); Send-TeamsAlert dedup against Teams.RequestLog guarantees once-per-edit delivery. Orchestration context (TaskId, ProcessId) is passed in by the engine; on completion Complete-OrchestratorTask updates Orchestrator.TaskLog and Orchestrator.ProcessRegistry.

### description #0  [metadata_id: 5214]

Single collector for the B2B module. Eight steps per cycle: schedule sync from b2bi.dbo.SCHEDULE into SI_ScheduleRegistry; workflow version census from b2bi.dbo.WFD into SI_WorkflowRegistry, logging definition changes as the drift signal that Sterling workflows were edited; a set-based classified INSERT of new pipeline runs from Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS into INT_PipelineTracking; a set-based re-poll of incomplete runs in the lookback working window; dispatcher name resolution from b2bi instance linkage; a Sterling WF_INST_S cross-check that classifies aged in-flight runs whose instance terminated or vanished as DIED_UNHANDLED; fault-report enrichment that captures the Sterling translation status report for Sterling-internal failures into SI_FaultReport and snapshots summary columns onto INT_PipelineTracking; and Teams alert evaluation via the shared Send-TeamsAlert function - failure classifications alert once per run via alert_count and workflow version changes alert once per edit via trigger dedup, gated by b2b_alerting_enabled and bounded to the working window. Reads GlobalConfig settings b2b_alerting_enabled, b2b_collect_lookback_days, and b2b_inflight_aging_minutes.

### design_note #1  [metadata_id: 5218]
Title: One collector, seven steps

The script performs schedule sync, workflow census, pipeline mirror (insert + re-poll), dispatcher resolution, Sterling cross-check, fault-report enrichment, and alert evaluation in every cycle. The single-collector design keeps the orchestrator footprint minimal and shares the b2bi connection, config, and logging machinery. Steps are independent: a failure in one does not block the others, and the summary aggregates per-step results into the orchestrator callback.

### design_note #2  [metadata_id: 5219]
Title: Set-based T-SQL classification on the listener

Classification is not computed in PowerShell. Because Integration, crs5_oltp, and xFACts are all reachable through the AG listener, one CTE joins the batch-status source to config, client, DM, and pickup evidence and derives status_classification, is_complete, and completed_dttm entirely in T-SQL; the insert and re-poll steps are single cross-database DML statements built around that shared CTE. PowerShell orchestrates and logs; T-SQL classifies.

### design_note #3  [metadata_id: 5220]
Title: is_complete anti-join and the working window

New-run discovery anti-joins on run_id so mirrored rows are never re-inserted, and the re-poll is bounded to is_complete = 0 rows whose source INSERT_DATE falls inside the lookback window. The window bound matters because history contains permanently-incomplete populations (config-orphaned rows parked at status 2, dead in-flight rows) that would otherwise be re-evaluated every cycle forever: they remain honestly incomplete in the table but sit outside the working set. IX_INT_PipelineTracking_Incomplete supports the incomplete scan.

### design_note #4  [metadata_id: 5221]
Title: Dispatcher resolution via COALESCE(parent_id, run_id)

Wrapper-launched pipeline rows are written by the inline GET_LIST invocation, which executes in the wrapper's own workflow context - so the row's RUN_ID is the wrapper's WORKFLOW_ID and resolves directly to the wrapper WFD name. Dispatched MAIN children carry the dispatcher's WORKFLOW_ID in PARENT_ID instead. COALESCE(parent_id, run_id) therefore yields the correct lookup id for both shapes with no branching. Names resolve only within Sterling's ~30-day runtime retention; older rows keep dispatcher_name NULL.

### design_note #5  [metadata_id: 5222]
Title: Sterling cross-check semantics

The cross-check unions WF_INST_S and WF_INST_S_RESTORE so archived instances still resolve. Terminal state is detected from END_TIME populated (the same signal the retired collector used); an instance present with NULL END_TIME is genuinely executing and the row stays IN_FLIGHT with sterling_check_result RUNNING. Terminated or absent instances mean the run died without reaching a fault handler - its source row will never leave status 0 - so the row classifies DIED_UNHANDLED with completed_dttm taken from Sterling's END_TIME when available. The aging threshold (b2b_inflight_aging_minutes, default 720) is deliberately conservative because legitimate runs can carry 10-hour executable timeouts.

### design_note #6  [metadata_id: 5223]
Title: VARBINARY fetch uses -MaxBinaryLength

b2bi stores TIMINGXML as gzip-compressed VARBINARY(MAX). The schedule-sync fetch passes -MaxBinaryLength 20971520 (20MB) on Get-SqlData.

### design_note #7  [metadata_id: 5263]
Title: Fault-report enrichment

Step 7 processes only Sterling-internal failure classifications (STERLING_FAULT, DIED_UNHANDLED) whose fault_report_captured_dttm is NULL, so it is idempotent and each failure is handled once. It matches the failing step on BASIC_STATUS <> 0 for a configured set of report-producing services (Translation, XSLTService, InlineInvokeBusinessProcessService, MailMimeService), reads and gzip-decompresses the referenced TRANS_DATA blob, and parses one of three report shapes. A blob without the gzip magic bytes is skipped. Failures with no extractable report are stamped NONE rather than left unmarked, so the idempotent scan does not re-attempt them. The report text and the summary columns are written in the collector, not derived in the API, so the capture is permanent and read-time is join-free.

### module #0  [metadata_id: 5215]

B2B

### relationship_note #1  [metadata_id: 5224]
Title: B2B.SI_ScheduleRegistry

Sole writer. Step 1 issues per-row INSERT, UPDATE, and DELETE statements against this table based on diff with b2bi.dbo.SCHEDULE.

### relationship_note #2  [metadata_id: 5225]
Title: B2B.SI_WorkflowRegistry

Sole writer. Step 2 INSERTs newly appeared workflow definitions, UPDATEs version-changed ones (preserving previous_version and stamping last_version_change_dttm), and touches last_synced_dttm on unchanged rows in chunked IN-list UPDATEs.

### relationship_note #3  [metadata_id: 5226]
Title: B2B.INT_PipelineTracking

Primary writer. Steps 3-7 INSERT classified new runs, re-poll and reclassify incomplete rows, resolve dispatcher_name, apply Sterling cross-check results, and snapshot the fault-report summary columns (fault_report_type, fault_report_code, fault_report_summary, fault_report_captured_dttm) on Sterling-internal failures.

### relationship_note #4  [metadata_id: 5227]
Title: xFACts-OrchestratorFunctions.ps1

Dot-sourced at script startup. Provides Initialize-XFActsScript for SQL module loading and application identity tagging, Get-SqlData and Invoke-SqlNonQuery for database access (including -MaxBinaryLength for the TIMINGXML blob reads), Write-Log and the console helpers, and Complete-OrchestratorTask for the orchestrator completion callback.

### relationship_note #5  [metadata_id: 5228]
Title: b2bi (IBM Sterling B2B Integrator)

Reads from b2bi on FA-INT-DBP via Windows auth: dbo.SCHEDULE and dbo.DATA_TABLE (schedule sync), dbo.WFD (workflow census and name resolution), dbo.WF_INST_S and dbo.WF_INST_S_RESTORE (dispatcher resolution and the in-flight cross-check). All cross-server correlation happens in PowerShell memory; b2bi is never joined to listener databases in SQL.

### relationship_note #6  [metadata_id: 5229]
Title: Integration and crs5_oltp (via the AG listener)

The classified-source CTE reads Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS, tbl_B2B_CLIENTS_FILES, tbl_B2B_CLIENTS_MN, and tbl_B2B_CLIENTS_BATCH_FILES, plus the crs5_oltp DM batch tables (new_bsnss_btch, cnsmr_pymnt_btch, file_registry) as cross-database joins on the listener connection. The DM joins re-derive the same outcome evidence the Integration reconciliation job (FAINT.USP_B2B_CLIENTS_UPDATE_BATCH_STATUS) reads, so the mirror's -1 disambiguation matches production reconciliation semantics.

### relationship_note #7  [metadata_id: 5230]
Title: Orchestrator.ProcessRegistry

Registered in Orchestrator.ProcessRegistry as module B2B, process Collect-B2BPipeline (the entry repointed from the retired Collect-B2BExecution at transition). Scheduling and run mode are controlled there; runtime status fields (running_count, last_execution_status, last_duration_ms) are updated by the Complete-OrchestratorTask callback at the end of each run. dependency_group bucket = 10 (collectors).

### relationship_note #8  [metadata_id: 5262]
Title: SI_FaultReport

Sole writer. Step 7 (fault-report enrichment) INSERTs one row per Sterling-internal failure that carried an extractable status report, decompressed from b2bi TRANS_DATA via the failing step's STATUS_RPT handle. The summary of each report is also snapshotted onto INT_PipelineTracking for join-free display.

## INT_PipelineTracking (Table)

### category #0  [metadata_id: 5150]

B2B

### data_flow #0  [metadata_id: 5231]

Rows originate in Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS, the Sterling-to-DM lifecycle tracker written by the pipeline workflows and the Integration reconciliation job. Collect-B2BPipeline.ps1 mirrors them each cycle: step 3 INSERTs classified rows for source runs not yet mirrored (bounded by b2b_collect_lookback_days), step 4 re-polls tracked rows with is_complete = 0 inside the same window via a set-based UPDATE. Classification is computed in T-SQL on the listener at collection time - config enrichment (process_type, comm_method) from the FILES join, client_name from the MN clients master, DM outcome verification against the crs5_oltp batch tables for -1 rows, and the BATCH_FILES nonzero-size pickup check for the status-4 split. Step 5 stamps dispatcher_name from b2bi instance linkage (resolvable only within the ~30-day Sterling runtime window); step 6 sets sterling_check_result and promotes aged in-flight rows to DIED_UNHANDLED; step 7 increments alert_count when a failure alert is queued.

### description #0  [metadata_id: 5148]

Pipeline-run lifecycle tracking mirrored from Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS, the Sterling-to-DM lifecycle tracker. One row per pipeline run (RUN_ID unique), carrying the raw source status verbatim plus a disambiguated classification that resolves the dual-meaning source values (-1 and 4) via independent DM batch verification and BATCH_FILES pickup evidence. Enrichment columns snapshot client identity and process configuration at collection time. The INT_ prefix marks the table as mirrored from the Integration database, as opposed to SI_ tables sourced directly from b2bi.

### design_note #1  [metadata_id: 5195]
Title: Source Provenance Prefix Convention

B2B module tables carry a prefix declaring their source system: SI_ tables are sourced directly from the b2bi database on FA-INT-DBP (Sterling itself), while INT_ tables mirror rows written to the Integration database on the AG listener. The module is inherently a hybrid of the two source systems, and the prefix makes data provenance readable straight from the object name.

### design_note #2  [metadata_id: 5196]
Title: Raw Status Plus Classification

The table deliberately carries both the raw source status (batch_status, mirrored verbatim) and a derived classification (status_classification). Two source values are ambiguous by writer: -1 means either a Sterling workflow fault or a DM batch rejection, and 4 means either no files acquired or a handoff that never happened. The classification resolves these using independent evidence - the DM batch tables for -1 (the same tables the Integration reconciliation job reads) and BATCH_FILES pickup rows with nonzero size for 4. Keeping the raw value preserves the audit trail against the source; the classification is the operational reading.

### design_note #3  [metadata_id: 5197]
Title: Snapshot Enrichment

client_name, process_type, and comm_method are stamped onto the row at collection time rather than resolved by join at display time. Historical rows keep the values that were true when the run executed, so config renames and reconfigurations do not rewrite history. dispatcher_name is likewise a point-in-time resolution, and is additionally constrained by the Sterling runtime retention window - it is NULL for rows collected more than ~30 days after their run.

### design_note #4  [metadata_id: 5198]
Title: Terminal Means Classified

is_complete is driven by the classification, not the raw source status. A row at source status -1 is not complete until the DM verification has resolved which failure story it represents, and a row at source status 0 is not abandoned until the Sterling cross-check has determined whether it is running or dead. This keeps the incremental poll working the classification queue, not just mirroring status changes.

### module #0  [metadata_id: 5149]

B2B

### relationship_note #1  [metadata_id: 5232]
Title: Collect-B2BPipeline.ps1

Primary writer. Inserts classified new runs, re-polls and reclassifies incomplete rows inside the lookback working window, resolves dispatcher_name, applies Sterling cross-check results, and increments alert_count when alerts are queued. Rows outside the working window are never touched after reaching their final collected state.

### relationship_note #2  [metadata_id: 5233]
Title: Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS

The mirrored source (external, AVG-PROD-LSNR). One tracking row per source RUN_ID; batch_status, the source dates, and the identity columns are mirrored verbatim. The source row is written by the pipeline workflows themselves (first-party status writes verified from BPML source) and promoted by the reconciliation job FAINT.USP_B2B_CLIENTS_UPDATE_BATCH_STATUS, which runs every minute 00:15-18:59:59.

### relationship_note #3  [metadata_id: 5234]
Title: crs5_oltp DM batch tables

Classification evidence (external). The -1 disambiguation re-reads the same DM tables the reconciliation job reads: new_bsnss_btch (by batch short name), cnsmr_pymnt_btch and file_registry (by cast registry id). batch_id is the bridge to Debt Manager batch processing and joins to the BatchOps tracking tables (NB_BatchTracking, PMT_BatchTracking) for cross-module analysis of the same batches.

### relationship_note #4  [metadata_id: 5261]
Title: SI_FaultReport

On failure, the collector captures the Sterling status report into SI_FaultReport (one row per run, linked by run_id) and snapshots the summary fields (fault_report_type, fault_report_code, fault_report_summary, fault_report_captured_dttm) onto this row for join-free display. The full report is fetched from SI_FaultReport only on demand.

### description / alert_count #24  [metadata_id: 5169]

Number of alerts fired for this run. Used to prevent duplicate alerting.

### description / batch_id #6  [metadata_id: 5156]

Mirrors BATCH_STATUS.BATCH_ID - the DM batch identifier written back by COMM_CALL after handoff. The bridge between the B2B pipeline and Debt Manager batch processing. NULL when no handoff occurred.

### description / batch_status #7  [metadata_id: 5157]

The raw source status value, mirrored verbatim from BATCH_STATUS.BATCH_STATUS. Preserved as the audit trail against the source; see status_classification for the disambiguated reading.

### status_value / batch_status #1  [metadata_id: 5172]
Title: 0

In-flight (source column default; the workflow INSERT supplies no status). Also the permanent value for runs that died without reaching a fault handler.

### status_value / batch_status #2  [metadata_id: 5173]
Title: 2

Transitional: the B2B side is done. For NB/PAY/BDL runs, awaiting DM confirmation by the reconciliation job. For dispatcher rows with NULL SEQ_ID, permanent (the reconciliation join cannot promote them).

### status_value / batch_status #3  [metadata_id: 5174]
Title: 3

Fully complete. For NB/PAY/BDL runs this includes DM-side confirmation written by the reconciliation job.

### status_value / batch_status #4  [metadata_id: 5175]
Title: 4

Dual meaning at the source: no files acquired (workflow tail), or reached status 2 with NULL BATCH_ID meaning the handoff never happened (reconciliation job, NB/PAY/BDL only). Disambiguated in status_classification.

### status_value / batch_status #5  [metadata_id: 5176]
Title: 5

Duplicate file detected; processing suppressed.

### status_value / batch_status #6  [metadata_id: 5177]
Title: -1

Dual meaning at the source: a Sterling-side workflow fault (onFault handler), or a DM-side batch rejection written by the reconciliation job. Disambiguated in status_classification.

### status_value / batch_status #7  [metadata_id: 5178]
Title: -2

Cascade-skip: this run short-circuited because its predecessor in a SEQUENTIAL chain failed.

### status_value / batch_status #8  [metadata_id: 5179]
Title: 1

Defined for the retired ETL_CALL success path. Unreachable since 2024-08; zero rows exist in source history.

### description / client_id #4  [metadata_id: 5154]

Mirrors BATCH_STATUS.CLIENT_ID - the B2B client this run processed.

### description / client_name #12  [metadata_id: 5162]

Snapshotted from etl.tbl_B2B_CLIENTS_MN.CLIENT_NAME at collection time. Historical rows keep the name that was current when collected.

### description / collected_dttm #25  [metadata_id: 5170]

When this row was first inserted by the collector.

### description / comm_method #11  [metadata_id: 5161]

Snapshotted from etl.tbl_B2B_CLIENTS_FILES.COMM_METHOD via the CLIENT_ID + SEQ_ID join at collection time.

### description / completed_dttm #23  [metadata_id: 5168]

When the row reached its terminal classification.

### description / dispatcher_name #13  [metadata_id: 5163]

The wrapper workflow definition name that fired this pipeline run, resolved from b2bi runtime linkage. Resolvable only within the Sterling runtime retention window (~30 days), so NULL for backfilled history and aged rows.

### description / dm_batch_status_code #16  [metadata_id: 5165]

The DM-side batch status code observed when the collector performed the DM verification for this run. NULL when no BATCH_ID exists or no DM lookup applied.

### description / fault_report_captured_dttm #21  [metadata_id: 5256]

When the collector attempted fault-report capture for this run. Doubles as the look-back-and-fill guard: NULL means never attempted, so the enrichment pass is idempotent and only processes unattempted failures.

### description / fault_report_code #19  [metadata_id: 5254]

The primary error code from the fault report (e.g. 112 for Data Too Long, 721 for an UPDATE/INSERT/DELETE execution error). NULL for SERVICE/MESSAGE/NONE reports or when no single code applies.

### description / fault_report_summary #20  [metadata_id: 5255]

The one-line failure headline shown on the run row and slideout. For a single error it is the specific message (the downstream exception text when present, else the code label); for multiple errors it is a generic count pointing to the full report.

### description / fault_report_type #18  [metadata_id: 5253]

The shape of the captured Sterling fault report, or NONE when the failure carried no extractable report. Snapshotted from SI_FaultReport for join-free display; NONE is the sentinel marking that the collector looked and found nothing, so the run is not re-attempted. NULL until the collector has attempted capture. See Status Values.

### status_value / fault_report_type #1  [metadata_id: 5257]
Title: TRANSLATION

The run's fault report is a translation-map report with structured entries. Full report in SI_FaultReport.

### status_value / fault_report_type #2  [metadata_id: 5258]
Title: SERVICE

The run's fault report is a service report (e.g. XSLT Service) carrying a service-level exception. Full report in SI_FaultReport.

### status_value / fault_report_type #3  [metadata_id: 5259]
Title: MESSAGE

The run's fault report is a bare single-string message. Full report in SI_FaultReport.

### status_value / fault_report_type #4  [metadata_id: 5260]
Title: NONE

The collector attempted capture but the failure carried no extractable report. Sentinel that prevents re-attempting; no SI_FaultReport row exists.

### description / is_complete #22  [metadata_id: 5167]

1 when the run has reached a terminal classification and needs no further polling. Drives the collector incremental scan.

### description / last_polled_dttm #26  [metadata_id: 5171]

When this row was last updated by the collector.

### description / parent_id #3  [metadata_id: 5153]

Mirrors BATCH_STATUS.PARENT_ID - links a dispatched child run (FA_CLIENTS_MAIN) to the dispatcher run that launched it. NULL for dispatcher rows themselves.

### description / process_type #10  [metadata_id: 5160]

Snapshotted from etl.tbl_B2B_CLIENTS_FILES.PROCESS_TYPE via the CLIENT_ID + SEQ_ID join at collection time - the same derivation the Integration reconciliation job uses. NULL when the join cannot resolve (scheduler-fired dispatcher rows).

### description / run_id #2  [metadata_id: 5152]

The Sterling WORKFLOW_ID of the run. Mirrors BATCH_STATUS.RUN_ID. Unique - one tracking row per pipeline run.

### description / seq_id #5  [metadata_id: 5155]

Mirrors BATCH_STATUS.SEQ_ID - the client config sequence this run executed. NULL identifies a scheduler-fired GET_LIST dispatcher row (whole-client dispatch with no single sequence).

### description / source_finish_dttm #9  [metadata_id: 5159]

Mirrors BATCH_STATUS.FINISH_DATE - set by the workflow tail or fault handler. NULL for in-flight runs and runs that died without reaching a handler. Not updated by the reconciliation job.

### description / source_insert_dttm #8  [metadata_id: 5158]

Mirrors BATCH_STATUS.INSERT_DATE - when the run began (the source column defaults to GETDATE() at row creation). The age anchor for in-flight and stuck-at-status calculations.

### description / status_classification #15  [metadata_id: 5164]

The detailed final classification of the run, carrying the specific pipeline outcome including downstream disposition. The detail layer behind the sterling_status column.

### status_value / status_classification #1  [metadata_id: 5180]
Title: IN_FLIGHT

Source status 0 and the run is presumed executing (young row, or Sterling cross-check confirmed RUNNING).

### status_value / status_classification #2  [metadata_id: 5181]
Title: AWAITING_DM

Source status 2 on a non-dispatcher run: the B2B side is done and the run awaits promotion by the reconciliation job (DM batch confirmation for NB/PAY/BDL handoffs; immediate promotion for other process types). Rows whose DM batch never reaches a recognized terminal code remain here indefinitely - a small permanent-limbo population exists in history.

### status_value / status_classification #3  [metadata_id: 5182]
Title: COMPLETE

Fully complete. Source status 3, or a dispatcher/non-handoff run whose terminal state is success.

### status_value / status_classification #4  [metadata_id: 5183]
Title: NO_FILES

Source status 4 where the run genuinely acquired no files: either a non-NB/PAY/BDL process type (the reconciliation job never writes 4 for those), or an NB/PAY/BDL run with no nonzero-size pickup rows in BATCH_FILES.

### status_value / status_classification #5  [metadata_id: 5184]
Title: NO_HANDOFF

Source status 4 on an NB/PAY/BDL run that acquired files (nonzero-size pickups exist in BATCH_FILES) but never handed off to DM - it reached status 2 with NULL BATCH_ID and the reconciliation job demoted it.

### status_value / status_classification #6  [metadata_id: 5185]
Title: DUPLICATE

Source status 5: duplicate file detected, processing suppressed.

### status_value / status_classification #7  [metadata_id: 5186]
Title: CASCADE_SKIP

Source status -2: skipped because the predecessor in a SEQUENTIAL chain failed.

### status_value / status_classification #8  [metadata_id: 5187]
Title: STERLING_FAULT

Source status -1 where no DM rejection is possible: either NULL BATCH_ID (the workflow faulted before any DM handoff), or a process type outside NEW_BUSINESS/PAYMENT/BDL (the reconciliation job never writes -1 for those types, so the -1 is the workflow fault handler regardless of BATCH_ID).

### status_value / status_classification #9  [metadata_id: 5188]
Title: DM_REJECTED

Source status -1 with a BATCH_ID whose DM batch shows a failed or deleted terminal code: DM rejected the batch after handoff (the reconciliation job write, independently re-verified against the DM tables).

### status_value / status_classification #10  [metadata_id: 5189]
Title: FAULT_POST_HANDOFF

Source status -1 with a BATCH_ID whose DM batch is healthy: the data landed in DM but the pipeline faulted afterward (cleanup or notification steps died). A distinct triage category.

### status_value / status_classification #11  [metadata_id: 5190]
Title: DIED_UNHANDLED

Source status 0 past the aging threshold with a Sterling cross-check of TERMINATED or NOT_FOUND: the run died without reaching a fault handler and will never update its own row.

### status_value / status_classification #12  [metadata_id: 5191]
Title: UNCLASSIFIED

The collector could not resolve a classification (missing evidence, verification unavailable). A holding state that should be rare; persistent UNCLASSIFIED rows indicate a collector or source problem.

### description / sterling_check_result #17  [metadata_id: 5166]

Outcome of the b2bi WF_INST_S cross-check performed for in-flight rows aging past threshold. Distinguishes genuinely running instances from runs that died without reaching a fault handler. See Status Values.

### status_value / sterling_check_result #1  [metadata_id: 5192]
Title: RUNNING

The b2bi WF_INST_S instance for this RUN_ID was found and is still executing. The run is genuinely in flight.

### status_value / sterling_check_result #2  [metadata_id: 5193]
Title: TERMINATED

The b2bi instance was found but has ended. Combined with source status 0, the run died without writing a terminal status.

### status_value / sterling_check_result #3  [metadata_id: 5194]
Title: NOT_FOUND

No b2bi instance exists for this RUN_ID - the instance aged out of the Sterling runtime retention window (~30 days) or never registered.

### description / sterling_status #14  [metadata_id: 5264]

The overall status of the run at the Sterling Integrator level, independent of any downstream outcome. The primary status the Control Center surfaces for each run.

### status_value / sterling_status #1  [metadata_id: 5265]
Title: SUCCESS

The process reached a successful terminal state within Sterling Integrator.

### status_value / sterling_status #2  [metadata_id: 5266]
Title: FAILED

The process failed within Sterling Integrator.

### status_value / sterling_status #3  [metadata_id: 5267]
Title: NO_ACTION

The run performed no processing - there was nothing to act on.

### status_value / sterling_status #4  [metadata_id: 5268]
Title: IN_PROGRESS

The run has not yet reached a terminal state within Sterling Integrator.

### status_value / sterling_status #5  [metadata_id: 5269]
Title: UNDEFINED

The Sterling-level status has not been determined.

### description / tracking_id #1  [metadata_id: 5151]

Clustered identity primary key.

## INT_RunFiles (Table)

### category #0  [metadata_id: 5299]

B2B

### data_flow #0  [metadata_id: 5282]

Collect-B2BPipeline.ps1 mirrors file rows from Integration etl.tbl_B2B_CLIENTS_BATCH_FILES for runs present in INT_PipelineTracking, inserting any source rows not yet captured and keyed on source_file_id, on each cycle, within the collection lookback period.

### description #0  [metadata_id: 5271]

One row per file associated with a Sterling run: the Integration file listing (etl.tbl_B2B_CLIENTS_BATCH_FILES) mirrored for tracked runs, covering both pickups and deliveries.

### module #0  [metadata_id: 5296]

B2B

### description / captured_dttm #10  [metadata_id: 5281]

When the mirror captured the row.

### description / client_id #4  [metadata_id: 5275]

Client identifier as recorded on the source file row.

### description / comm_method #8  [metadata_id: 5279]

Transfer method recorded on the source row (observed values: SFTP_GET, SFTP_PUT).

### description / file_name #6  [metadata_id: 5277]

File name or path as recorded at pickup or delivery.

### description / file_size #7  [metadata_id: 5278]

File size in bytes as recorded on the source row.

### description / run_file_id #1  [metadata_id: 5272]

Surrogate identity key.

### description / run_id #2  [metadata_id: 5273]

Sterling workflow/run id the file is associated with; joins INT_PipelineTracking.run_id.

### description / seq_id #5  [metadata_id: 5276]

Client sequence identifier as recorded on the source file row.

### description / source_file_id #3  [metadata_id: 5274]

Source row ID from etl.tbl_B2B_CLIENTS_BATCH_FILES; the mirror's idempotency key.

### description / source_insert_dttm #9  [metadata_id: 5280]

Source row INSERT_DATE from Integration.

## INT_RunTickets (Table)

### category #0  [metadata_id: 5300]

B2B

### data_flow #0  [metadata_id: 5294]

Collect-B2BPipeline.ps1 aggregates etl.tbl_B2B_CLIENTS_TICKETS rows with a populated RUN_ID for tracked runs to (run_id, ticket_reason) grain each cycle within the collection lookback: new pairs are inserted, existing pairs are updated when the ticket number, ticket date, or row count changes, and ticket_status is set from the assignment state (GENERATED when a ticket number is present, PENDING while unassigned within 24 hours of the first source row, AGED_OUT after). The Control Center B2B Pipeline run-detail slideout reads this table on demand.

### description #0  [metadata_id: 5283]

One row per (run, ticket reason): the Jira ticket outcomes recorded against a Sterling run, aggregated from the per-failed-account rows in Integration etl.tbl_B2B_CLIENTS_TICKETS.

### module #0  [metadata_id: 5297]

B2B

### description / captured_dttm #9  [metadata_id: 5292]

When the capture first recorded the row.

### description / first_inserted_dttm #8  [metadata_id: 5291]

Earliest source row INSERTED_DATE for the run and reason.

### description / run_id #2  [metadata_id: 5285]

Sterling workflow/run id the ticket rows are recorded against; joins INT_PipelineTracking.run_id.

### description / run_ticket_id #1  [metadata_id: 5284]

Surrogate identity key.

### description / ticket_date #5  [metadata_id: 5288]

Assignment timestamp recorded with the ticket number.

### description / ticket_num #4  [metadata_id: 5287]

Jira ticket number assigned by the ticket generator.

### description / ticket_reason #3  [metadata_id: 5286]

Ticket reason text as recorded at the source; free text.

### description / ticket_row_count #6  [metadata_id: 5289]

Count of source ticket rows aggregated into this row.

### description / ticket_status #7  [metadata_id: 5290]

Assignment state of the ticket row: GENERATED, PENDING, or AGED_OUT.

### description / updated_dttm #10  [metadata_id: 5293]

When the capture last refreshed the row (ticket assignment or count growth).

## SI_FaultReport (Table)

### category #0  [metadata_id: 5240]

B2B

### data_flow #0  [metadata_id: 5248]

Collect-B2BPipeline.ps1 enriches failed runs in a look-back-and-fill pass: for each INT_PipelineTracking failure within the retention window lacking a captured report, it resolves the failing step's STATUS_RPT handle in b2bi.dbo.WORKFLOW_CONTEXT, reads the gzip blob from b2bi.dbo.TRANS_DATA, decompresses and parses it, then inserts one row here (report_json + raw_report_text) and snapshots the summary fields onto INT_PipelineTracking. When the failing step's report parses as a bare one-line MESSAGE, the collector falls back to the run's last successful Translation step, captures that step's full report instead (fault_report_type = TRANSLATION_ESCALATED), and preserves the one-line message in escalation_message. The Control Center B2B Pipeline run-detail slideout reads this table on demand when the user opens the full report.

### description #0  [metadata_id: 5238]

Per-run capture of the Sterling translation status report for failed B2B pipeline runs. One row per failed run that carried an extractable report, sourced from b2bi.dbo.TRANS_DATA via the failing step's STATUS_RPT handle in WORKFLOW_CONTEXT. Stores the full parsed report as JSON plus the raw decompressed text, captured once at collection time and retained permanently.

### module #0  [metadata_id: 5239]

B2B

### relationship_note #1  [metadata_id: 5252]
Title: INT_PipelineTracking

run_id links each report to its failed pipeline run (unique, foreign-keyed). The prefixes differ intentionally: SI_ marks Sterling-sourced content while the parent INT_ row is spined on Integration data. The summary fields (fault_report_type, fault_report_code, fault_report_summary, fault_report_captured_dttm) are snapshotted onto INT_PipelineTracking so the run row and slideout headline need no join; this table holds the full report for on-demand display.

### description / captured_dttm #8  [metadata_id: 5247]

When the collector decompressed and captured this report.

### description / escalation_message #5  [metadata_id: 5270]

The failing step's one-line status message, preserved when the run's report was recovered from the last successful Translation step in the same run (fault_report_type = TRANSLATION_ESCALATED). NULL for reports captured directly from the failing step.

### description / fault_report_id #1  [metadata_id: 5241]

Surrogate key.

### description / fault_report_type #3  [metadata_id: 5243]

The report shape captured, which determines how the JSON is structured and rendered. See Status Values.

### status_value / fault_report_type #1  [metadata_id: 5249]
Title: TRANSLATION

A translation-map report with structured entries (section, severity, code, field/exception detail). The richest shape.

### status_value / fault_report_type #2  [metadata_id: 5250]
Title: SERVICE

A service report (e.g. XSLT Service): timestamped message lines and an error total, carrying a service-level exception rather than translation codes.

### status_value / fault_report_type #3  [metadata_id: 5251]
Title: MESSAGE

A bare single-string message with no further structure (e.g. the terse wrapper text an inline invoke records).

### description / raw_report_text #7  [metadata_id: 5246]

The decompressed report text as extracted from the blob, before parsing. Preserved as a fallback so no source content is lost even if the parse model changes.

### description / report_json #6  [metadata_id: 5245]

The full parsed report as JSON: every report entry with its section, severity, code, and detail. The complete record for on-demand display, independent of the summary fields snapshotted onto INT_PipelineTracking.

### description / run_id #2  [metadata_id: 5242]

The failed pipeline run this report belongs to. One-to-one with INT_PipelineTracking.run_id (enforced by a unique constraint and a foreign key). Cross-prefix by design: SI_ marks Sterling provenance, the parent INT_ row is Integration-spined.

### description / source_name #4  [metadata_id: 5244]

The translation map name (TRANSLATION) or service name (SERVICE) the report came from. NULL for a bare MESSAGE report.

## SI_ScheduleRegistry (Table)

### category #0  [metadata_id: 4590]

B2B

### data_flow #0  [metadata_id: 4616]

Collect-B2BExecution.ps1 fully synchronizes this table with b2bi.dbo.SCHEDULE on every collection cycle. The collector queries all rows from SCHEDULE, fetches each TIMINGXML blob from b2bi.dbo.DATA_TABLE, decompresses the gzip content, parses the XML into the structured columns (run_day_mask, run_times_explicit, run_range_start/end, run_interval_minutes, excluded_dates, etc.), generates the human-readable schedule_description, and MERGEs the result. New schedules are INSERTed; existing schedules are re-parsed if the timing_xml_handle has changed; schedules no longer present in b2bi are DELETEd from the registry. The Control Center B2B page (future) reads this table to display the schedule modal/panel. No other xFACts components currently read this table; it will become a join target for SI_ExecutionTracking in Phase 3 Block 2 to correlate observed workflow runs against their expected schedules.

### description #0  [metadata_id: 4588]

Master catalog of IBM Sterling B2B Integrator schedules. Stores one row per SCHEDULEID from b2bi.dbo.SCHEDULE with parsed TIMINGXML structure and a human-readable schedule description. The collector fully synchronizes this table with b2bi on each cycle: new schedules are inserted, changed schedules are re-parsed and updated, and schedules no longer present in b2bi are removed. This table is the authoritative source for "what schedules exist in Sterling, when they run, and their current operational status" for the xFACts B2B module.

### design_note #1  [metadata_id: 4617]
Title: Raw XML Stored Inline
Description: The decompressed TIMINGXML is always stored inline in the timing_xml column alongside the parsed structural columns. This is a deliberate redundancy choice.

The grammar variety observed across 506 active schedules in b2bi produced 73 distinct structural patterns. The parser handles the documented grammar (timingxml/TimingXML root elements, ofWeek/ofMonth day specifiers, <time> and <timeRange> time specifiers, excludedDates), but Sterling has been observed to evolve schedule configurations over time, and a future schedule may introduce grammar that the parser does not recognize. By capturing the raw decompressed XML on every row, the forensic record is preserved regardless of parser coverage. If the parser ever needs to be extended, historical rows can be re-parsed against the same timing_xml column without re-fetching from b2bi, which purges aggressively.

### design_note #2  [metadata_id: 4618]
Title: Full Sync, Not Soft Delete
Description: The collector fully synchronizes this table with b2bi.dbo.SCHEDULE on each cycle. Schedules that disappear from b2bi are DELETEd from this registry rather than soft-marked.

Schedules are master data, not operational history. The registry's purpose is to represent "what is configured in Sterling right now" for join and display purposes. If schedule X is removed from Sterling, we do not need to retain a row here — execution history is tracked separately in SI_ExecutionTracking via captured WORKFLOW_ID values, which are independent of the schedule registry. A DELETE on this table does not lose anything that matters, and it keeps the table lean with no lifecycle audit columns (no first_seen, last_seen, is_deleted_in_source, deleted_in_source_dttm). If operational interest in "when did schedule X go away" ever arises, that tracking belongs in a different table with explicit audit semantics.

### design_note #3  [metadata_id: 4619]
Title: run_day_mask as CHAR(7) Bitmap
Description: The run_day_mask column uses a fixed-width CHAR(7) string where each position represents a day of the week, rather than separate BIT columns or an integer bitmap.

Position order is Sun-Mon-Tue-Wed-Thu-Fri-Sat. Each position is either the first letter of that day (S/M/T/W/T/F/S) when the schedule runs that day, or a dash (-) when it does not. This format is directly human-readable in ad-hoc queries (a Mon-Fri schedule shows as "-MTWTF-") and supports fast LIKE-based filtering (e.g., "schedules that run Monday" becomes WHERE run_day_mask LIKE '_M_____'). Seven separate BIT columns would have been more normalized but produce wider rows and noisier query output; an integer bitmap would have been more compact but unreadable without decoding. CHAR(7) with letter-or-dash is the readable compromise.

### design_note #4  [metadata_id: 4620]
Title: Parsed Structure vs. Raw XML: Intent
Description: The parsed structural columns (run_day_mask, run_times_explicit, run_range_start/end, run_interval_minutes, excluded_dates) and the schedule_description column are both derived from timing_xml at parse time.

Why duplicate the information? Different access patterns. Structured columns support fast queries ("which schedules run in the next hour", "which schedules are weekday-only", "which schedules exclude holidays"). The schedule_description supports display — Control Center modal, report output, ad-hoc investigation — without requiring UI-side parse logic. Raw timing_xml supports forensic re-parse if the grammar evolves. All three views of the same information, each serving a distinct use case. Because the source of truth is b2bi.dbo.SCHEDULE and the collector owns all derivation, the three representations cannot drift.

### design_note #5  [metadata_id: 4621]
Title: onMinute is Vestigial in Practice
Description: The run_on_minute column captures the <onMinute> value from TIMINGXML timeRange patterns, but observed values across all active schedules are uniformly 0.

The <onMinute> element appears in every <timeRange> block in every observed schedule, always with value 0. The actual minute marker of fire times (e.g., 05:05 hourly firing at :05 past each hour) is anchored by the minute portion of the range_start value, not by onMinute. This appears to be a Sterling grammar element that is either vestigial, reserved for future use, or overridden by the range definition in practice. The column is retained for lineage completeness, but the schedule_description generator uses the range_start minute rather than run_on_minute to describe the actual fire pattern.

### design_note #6  [metadata_id: 4622]
Title: Columns Dropped From Source SCHEDULE Table
Description: Nine columns from b2bi.dbo.SCHEDULE are intentionally not captured in this table.

Dropped columns (all verified constant across 506 active schedules): PARAMS (never populated), EXECUTIONDATE (always 0), EXECUTIONHOUR (always 0), EXECUTIONMINUTE (always 0), EXECUTIONCOUNT (always -1), EXECUTIONCURCOUNT (always 0), ORGANIZATIONKEY (always a single space character — a Sterling multi-tenancy field not used at FAC), XAPIMETHOD (always NULL), XAPIXML (always NULL). Capturing them would add width with no information value. If any of these ever becomes populated with meaningful data in the future, the raw timing_xml column does not help — these live directly on the SCHEDULE row, not in TIMINGXML. They would need to be added to both the table schema and the collector projection. Low-risk given their observed uniformity, but flagged here for future review if Sterling behavior changes.

### module #0  [metadata_id: 4589]

B2B

### description / excluded_dates #19  [metadata_id: 4609]

Comma-delimited list of MM-DD dates the schedule skips, when <excludedDates> is populated. Example: "01-01,12-25" for a schedule that excludes New Year's Day and Christmas. NULL when no exclusions configured.

### description / execution_status #7  [metadata_id: 4597]

EXECUTIONSTATUS value from b2bi.dbo.SCHEDULE. Sterling scheduler state for the schedule's execution pipeline — not xFACts-managed. Typical value observed is WAIT. Pass-through from Sterling.

### description / execution_timer #5  [metadata_id: 4595]

EXECUTIONTIMER from b2bi.dbo.SCHEDULE. Sterling-internal execution mode flag. Has three distinct observed values across all active schedules (0, 1, 2) — value 1 is dominant. Semantics defined by Sterling; captured for classification research.

### description / expected_runs_per_day #22  [metadata_id: 4612]

Total number of times per day this schedule is expected to fire. For explicit-time patterns, count of <time> entries. For interval patterns, derived from range span and interval. Useful for volume planning and Phase 4 schedule-adherence monitoring.

### description / first_run_time_of_day #20  [metadata_id: 4610]

HH:MM of the earliest run time on any active day, derived from either the minimum <time> value or the start of the <timeRange>. Useful for "will this run in the next hour" queries. NULL only when parsing cannot determine a value (i.e., timing_pattern_type = UNKNOWN).

### description / last_modified_dttm #25  [metadata_id: 4615]

Timestamp of the most recent change to any column on this row. Set to GETDATE() on INSERT by default; updated by the collector on every detected change.

### description / last_run_time_of_day #21  [metadata_id: 4611]

HH:MM of the latest run time on any active day. Useful for "when is the last fire of the day" queries. NULL only when timing_pattern_type = UNKNOWN.

### description / run_day_mask #12  [metadata_id: 4602]

CHAR(7) bitmap-style string representing days of week the schedule runs. Position order: Sun-Mon-Tue-Wed-Thu-Fri-Sat. Each position is either the first letter of that day (S/M/T/W/T/F/S) if the schedule runs that day, or a dash (-) if it does not. Examples: "SMTWTFS" = every day (ofWeek=-1), "-MTWTF-" = Mon-Fri, "S-----S" = Sat and Sun. NULL when timing_pattern_type is MONTHLY (ofMonth only).

### description / run_days_of_month #13  [metadata_id: 4603]

Comma-delimited list of days of month the schedule runs, when ofMonth is used in TIMINGXML. Example: "1,15" for a twice-monthly schedule. NULL when the schedule uses ofWeek instead.

### description / run_interval_minutes #15  [metadata_id: 4605]

Interval in minutes between runs, parsed from <interval> inside <timeRange>. Example: 60 for hourly. NULL for schedules using explicit <time> entries.

### description / run_on_minute #18  [metadata_id: 4608]

Value from <onMinute> inside <timeRange>, captured for lineage completeness. Observed value is 0 for virtually every schedule; the actual minute marker of fire times is derived from run_range_start. Retained for forensic purposes.

### description / run_range_end #17  [metadata_id: 4607]

HH:MM end of the run window, parsed from the last four chars of <range> inside <timeRange>. Example: "15:05". NULL for schedules using explicit <time> entries.

### description / run_range_start #16  [metadata_id: 4606]

HH:MM start of the run window, parsed from the first four chars of <range> inside <timeRange>. Example: "05:05". NULL for schedules using explicit <time> entries.

### description / run_times_explicit #14  [metadata_id: 4604]

Comma-delimited list of explicit HH:MM times the schedule runs, when the TIMINGXML contains <time> elements. Example: "05:00,06:00,07:00,...,18:00" for a schedule with 14 hourly fire times. NULL when the schedule uses <timeRange> instead.

### description / schedule_description #23  [metadata_id: 4613]

Human-readable summary generated at parse time. Intended for Control Center display (schedule modal) and ad-hoc query results. Examples: "Daily at 04:00", "Mon-Fri at 14:00", "Every 60 min at :05, 05:05-15:05, Mon-Fri (excl. 01-01, 12-25)", "Days 1,15 of month at 09:00".

### description / schedule_id #1  [metadata_id: 4591]

Primary key. SCHEDULEID value from b2bi.dbo.SCHEDULE. Immutable identifier assigned by Sterling.

### description / schedule_type #3  [metadata_id: 4593]

SCHEDULETYPE from b2bi.dbo.SCHEDULE. Sterling-internal integer classifying schedule type. Semantics defined by Sterling, not xFACts; captured for lineage and future correlation.

### description / schedule_type_id #4  [metadata_id: 4594]

SCHEDULETYPEID from b2bi.dbo.SCHEDULE. Sterling-internal secondary classifier. Semantics defined by Sterling; captured for lineage.

### description / service_name #2  [metadata_id: 4592]

SERVICENAME from b2bi.dbo.SCHEDULE. Name of the Sterling workflow (business process) this schedule fires. Examples: "FA_CLIENTS_GET_LIST", "FA_AMSURG_MHS_IB_BD_NB", "BackupService".

### description / source_status #6  [metadata_id: 4596]

STATUS value from b2bi.dbo.SCHEDULE. Sterling-managed state of the schedule itself — not xFACts-managed. Observed values include ACTIVE, HOLD. Pass-through from Sterling; interpret against Sterling documentation if needed.

### description / source_system_name #9  [metadata_id: 4599]

SYSTEMNAME from b2bi.dbo.SCHEDULE. Sterling cluster node that owns the schedule (e.g., "node1"). Relevant if Sterling is ever run multi-node.

### description / source_user_id #10  [metadata_id: 4600]

USERID from b2bi.dbo.SCHEDULE. User account that created or owns the schedule in Sterling (typically "admin").

### description / timing_pattern_type #11  [metadata_id: 4601]

Derived classifier for the schedule's timing pattern. See status_value entries for valid values and their meanings. Used for UI filtering and classification. Derived by collector from timing_xml structure.

### status_value / timing_pattern_type #1  [metadata_id: 4623]
Title: DAILY

Schedule runs every day (ofWeek="-1"), one or more explicit <time> fire points per day. Most common pattern; covers schedules like "Daily at 04:00" or "Daily at 05:00, 06:00, ..., 18:00".

### status_value / timing_pattern_type #2  [metadata_id: 4624]
Title: WEEKLY

Schedule runs on specific days of the week (ofWeek="1" through "7") with one or more explicit <time> fire points. Covers patterns like "Mon-Fri at 14:00" or "Sundays at 11:00".

### status_value / timing_pattern_type #3  [metadata_id: 4625]
Title: MONTHLY

Schedule runs on specific days of the month (ofMonth="N") with one or more explicit <time> fire points. Covers patterns like "1st of month at 10:41" or "1st and 15th at 09:00".

### status_value / timing_pattern_type #4  [metadata_id: 4626]
Title: INTERVAL

Schedule uses <timeRange> pattern with <interval> and <onMinute> — fires every N minutes within a defined HH:MM-HH:MM window. Covers patterns like "Every 60 min, 05:35-23:35, daily" and "Every 5 min, 00:00-23:59, daily".

### status_value / timing_pattern_type #5  [metadata_id: 4627]
Title: MIXED

Schedule uses <timeRange> pattern on specific days of week. Example: the FA_CLIENTS_GET_LIST schedule fires every 60 min from 05:05-15:05 on Mon-Fri only.

### status_value / timing_pattern_type #6  [metadata_id: 4628]
Title: UNKNOWN

TIMINGXML content did not match any of the documented grammar patterns the parser handles. The raw XML is captured in timing_xml for inspection and parser extension. Rows with this classification should be investigated — either the grammar has evolved or the parser has a gap.

### description / timing_xml #24  [metadata_id: 4614]

Full decompressed TIMINGXML content from b2bi.dbo.DATA_TABLE, captured at collection time. Stored raw as the forensic safety net: if the grammar evolves beyond what the parser handles, or the parser has a bug, the raw content is preserved for re-parse without re-fetching from b2bi (which purges aggressively).

### description / timing_xml_handle #8  [metadata_id: 4598]

TIMINGXML handle from b2bi.dbo.SCHEDULE — a DATA_ID pointer into b2bi.dbo.DATA_TABLE where the gzip-compressed TIMINGXML blob is stored. Captured for lineage traceability; the collector decompresses this at collection time and stores the result in timing_xml.

## SI_WorkflowRegistry (Table)

### category #0  [metadata_id: 5298]

B2B

### data_flow #0  [metadata_id: 5235]

Populated and maintained solely by Collect-B2BPipeline.ps1 step 2. Each cycle queries b2bi.dbo.WFD deduplicated to MAX(WFD_VERSION) per WFD_ID and compares against this table: definitions not yet catalogued INSERT (first_captured_dttm stamps their appearance), version bumps UPDATE current_version while preserving previous_version and stamping last_version_change_dttm, and unchanged rows receive a chunked last_synced_dttm touch. Definitions that disappear from the source are logged and retained - a stale last_synced_dttm marks them. Version changes recorded here feed the collector alert step, which queues a Teams alert per edit (deduped by wfd_id + version).

### design_note #1  [metadata_id: 5211]
Title: Version Census Memory

The census works by comparison: each sync computes MAX(WFD_VERSION) per WFD_ID at the source and compares it to current_version here. A higher source version means the workflow was edited - previous_version preserves what it changed from, last_version_change_dttm records when the change was observed, and the change is logged. A WFD_ID absent from the registry means a new workflow appeared in Sterling. Both conditions are operationally significant: Sterling definition changes alter pipeline behavior with no other notification path.

### design_note #2  [metadata_id: 5212]
Title: Latest Version Only

The registry deduplicates to one row per definition. The WFD table primary key is (WFD_ID, WFD_VERSION) and Sterling retains every historical version; joining WFD on WFD_ID alone produces cartesian products across version history. The registry deliberately carries only the latest version and the immediately prior one - full version forensics remain a b2bi query. Sterling engine-tuning attributes (persistence, recovery, priority, lifespan) are deliberately not mirrored; they carry no monitoring value.

### design_note #3  [metadata_id: 5213]
Title: Source Provenance Prefix Convention

B2B module tables carry a prefix declaring their source system: SI_ tables are sourced directly from the b2bi database on FA-INT-DBP (Sterling itself), while INT_ tables mirror rows written to the Integration database on the AG listener. This table is b2bi-sourced: its content comes from Sterling internal definition storage, not from anything the Integration process writes.

### module #0  [metadata_id: 5295]

B2B

### relationship_note #1  [metadata_id: 5236]
Title: Collect-B2BPipeline.ps1

Sole writer. Step 2 performs the census sync every cycle; step 7 reads recent version changes from this table to queue workflow-change alerts.

### relationship_note #2  [metadata_id: 5237]
Title: b2bi.dbo.WFD

The source (external, FA-INT-DBP). The WFD primary key is (WFD_ID, WFD_VERSION) with a new version row per workflow edit; the census reads only the latest version per definition. Full version history remains queryable in b2bi and is not mirrored here.

### description / current_version #5  [metadata_id: 5203]

MAX(WFD_VERSION) for this WFD_ID as of the last sync. Sterling increments the version on every edit of the workflow.

### description / edited_by #8  [metadata_id: 5206]

The Sterling account that saved the current version (WFD.EDITED_BY of the latest version row).

### description / first_captured_dttm #11  [metadata_id: 5209]

When this definition was first captured into the registry. For definitions present at initial deployment this is the deployment date; afterward it marks when a new workflow appeared in Sterling.

### description / last_synced_dttm #12  [metadata_id: 5210]

When the census last confirmed this row against the source. Every sync cycle touches this.

### description / last_version_change_dttm #7  [metadata_id: 5205]

When the collector observed the most recent version change. NULL until the first change is captured.

### description / previous_version #6  [metadata_id: 5204]

The version this definition held before its most recent observed change. NULL until the first version change is captured. Holds the immediately prior version only - multiple edits between sync cycles record the net change; full version history remains queryable in b2bi.

### description / source_mod_date #10  [metadata_id: 5208]

When Sterling recorded the current version being saved (WFD.MOD_DATE of the latest version row).

### description / source_status #9  [metadata_id: 5207]

The definition status code from the source (WFD.STATUS), mirrored verbatim.

### description / wfd_id #2  [metadata_id: 5200]

The Sterling workflow definition id (b2bi.dbo.WFD.WFD_ID). Unique - one catalog row per definition, independent of version history.

### description / workflow_description #4  [metadata_id: 5202]

The definition description text from the source, when populated.

### description / workflow_name #3  [metadata_id: 5201]

The workflow definition name (e.g. FA_CLIENTS_MAIN, FA_FROM_ACADIA_HEALTHCARE_PULL).

### description / workflow_registry_id #1  [metadata_id: 5199]

Clustered identity primary key.

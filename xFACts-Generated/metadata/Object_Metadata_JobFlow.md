# Object_Metadata: JobFlow
Source: dbo.Object_Metadata
Generated: 2026-07-23 21:14:44

## ErrorCategory (Table)

### category #0  [metadata_id: 1703]

JobFlow

### description #0  [metadata_id: 77]

Classification reference table for job record-level error patterns, used by Monitor-JobFlow.ps1 to determine whether total job failures should trigger alerts or be suppressed as expected business behavior.

### design_note #1  [metadata_id: 2429]
Title: Alert Suppression for Business Rejections
Description: Most DM job failures are expected business behavior

DM marks a job as Failed when any record is rejected. Most rejections are expected business behavior — consumers that do not meet mailing criteria, stale data from concurrent access, etc. ErrorCategory classifies each error pattern so validation can distinguish TRUE_FAILURE (alert) from BUSINESS_REJECTION (log only). Only 2 of 16 error types generate alerts; 13 are suppressed as business rejections.

### design_note #2  [metadata_id: 2430]
Title: Pattern Extraction
Description: How error_type values are derived from DM error messages

DM error messages follow two patterns: action-based ("Failed to execute action: ActionName (ENTITY)") where the action name is extracted, and non-action patterns matched directly (e.g., "Data is stale" ? StaleData, "User with Id:" ? UserInitiated). The error_type column stores the extracted pattern for lookup.

### module #0  [metadata_id: 1599]

JobFlow

### query #1  [metadata_id: 2728]
Title: Alertable Error Types
Description: Shows error types that will generate a Jira ticket on total job failure.

SELECT error_type, description
FROM JobFlow.ErrorCategory
WHERE alert_on_total_failure = 1;

### query #2  [metadata_id: 2729]
Title: Simulate Alert Decision
Description: Tests the alert-vs-suppress logic for a given error type and failure count, matching what Monitor-JobFlow uses in Step-ValidateCompletedFlows.

DECLARE @error_type VARCHAR(100) = 'CallRuleSet';
DECLARE @failed_count INT = 15;

SELECT 
    error_type,
    classification,
    alert_on_total_failure,
    CASE 
        WHEN alert_on_total_failure = 1 
         AND @failed_count >= min_failure_threshold 
        THEN 'ALERT'
        ELSE 'SUPPRESS'
    END AS action
FROM JobFlow.ErrorCategory
WHERE error_type = @error_type;

### description / alert_on_total_failure #4  [metadata_id: 812]

Whether to generate a Jira ticket when this error type causes a total job failure. 1 = alert, 0 = suppress

### description / category_id #1  [metadata_id: 809]

PK

### description / classification #3  [metadata_id: 811]

Category classification: TRUE_FAILURE, BUSINESS_REJECTION, or UNCLASSIFIED

### status_value / classification #1  [metadata_id: 2431]
Title: TRUE_FAILURE

Genuine system or configuration error requiring investigation. Generates Jira ticket on total failure.

### status_value / classification #2  [metadata_id: 2432]
Title: BUSINESS_REJECTION

Records rejected due to expected business rule conditions. System is working correctly. No ticket generated.

### status_value / classification #3  [metadata_id: 2433]
Title: UNCLASSIFIED

Unknown error pattern. Alerts to ensure new patterns are investigated and classified.

### description / created_dttm #7  [metadata_id: 815]

When this category was created

### description / description #6  [metadata_id: 814]

Human-readable description of the error type. Used in Jira ticket content to provide immediate context

### description / error_type #2  [metadata_id: 810]

Pattern identifier extracted from error message. For action-based errors, this is the action name (e.g., CallRuleSet, SendNotice). For non-action errors, this is a pattern key (e.g., StaleData, UserInitiated)

### description / min_failure_threshold #5  [metadata_id: 813]

Minimum number of failed records before alerting. Prevents noise from low-volume sporadic failures

### description / modified_dttm #8  [metadata_id: 816]

When this category was last modified

## FlowConfig (Table)

### category #0  [metadata_id: 1704]

JobFlow

### data_flow #1  [metadata_id: 2376]
Title: Written by Monitor-JobFlow.ps1 (ConfigSync)
Description: Step-ConfigSync inserts new flows and updates sync fields

Monitor-JobFlow.ps1 Step-ConfigSync: INSERT new flows (is_monitored=0, expected_schedule=UNCONFIGURED) | UPDATE dm_is_active and dm_last_sync_dttm for existing flows | Queues Jira ticket for new/deactivated flows.

### data_flow #2  [metadata_id: 2377]
Title: Read by Monitor-JobFlow.ps1 (all steps)
Description: Multiple steps reference FlowConfig for monitoring decisions

Step-DetectFlows reads is_monitored to filter which flows to track. Step-ValidateCompletedFlows reads alert_on_critical_failure. Step-DetectMissingFlows reads alert_on_missing. All steps filter on is_monitored = 1.

### description #0  [metadata_id: 65]

Per-flow monitoring configuration including active status, scheduling expectations, alert settings, and synchronization with Debt Manager.

### design_note #1  [metadata_id: 2371]
Title: ConfigSync Integration
Description: How FlowConfig stays synchronized with Debt Manager

FlowConfig is automatically maintained by Monitor-JobFlow.ps1 Step-ConfigSync, which runs as the first step of every monitoring cycle. New flows detected in DM are inserted with is_monitored = 0 and expected_schedule = UNCONFIGURED, triggering a Jira ticket for configuration. Deactivated flows get dm_is_active set to 0 with a Jira ticket. Reactivated flows get dm_is_active reset to 1 silently. The dm_last_sync_dttm field tracks when each flow was last verified against DM.

### design_note #2  [metadata_id: 2372]
Title: Effective Dating
Description: Future-dated configuration and historical tracking

effective_start_date and effective_end_date support future-dated configuration changes. A configuration with an end date can be superseded by a new row with a later start date. NULL effective_end_date means no expiration. Check constraints enforce end_date >= start_date when end_date is populated.

### module #0  [metadata_id: 1600]

JobFlow

### query #1  [metadata_id: 2730]
Title: Active Monitored Flows
Description: Lists all flows that are both monitored by xFACts and active in Debt Manager, with their alert settings.

SELECT 
    job_sqnc_shrt_nm AS flow_code,
    job_sqnc_nm AS flow_name,
    expected_schedule,
    alert_on_missing,
    alert_on_critical_failure
FROM JobFlow.FlowConfig
WHERE is_monitored = 1
  AND dm_is_active = 1
ORDER BY job_sqnc_shrt_nm;

### query #2  [metadata_id: 2731]
Title: Sync Status Check
Description: Shows when each flow was last verified against Debt Manager. Large hours_since_sync values indicate ConfigSync may not be running.

SELECT 
    job_sqnc_shrt_nm,
    dm_is_active,
    dm_last_sync_dttm,
    DATEDIFF(HOUR, dm_last_sync_dttm, GETDATE()) AS hours_since_sync
FROM JobFlow.FlowConfig
ORDER BY dm_last_sync_dttm DESC;

### query #3  [metadata_id: 2732]
Title: Flows Not In DM
Description: Finds flows that are deactivated or have never been synced with Debt Manager — useful for drift detection.

SELECT 
    job_sqnc_shrt_nm,
    dm_is_active,
    notes
FROM JobFlow.FlowConfig
WHERE dm_is_active = 0 OR dm_is_active IS NULL
ORDER BY job_sqnc_shrt_nm;

### relationship_note #1  [metadata_id: 2373]
Title: Parent of FlowExecutionTracking
Description: FK on job_sqnc_id links execution instances to flow configuration

FlowExecutionTracking.job_sqnc_id references FlowConfig.job_sqnc_id (UQ). Each flow config can have many execution tracking records over time — one per execution instance.

### relationship_note #2  [metadata_id: 2374]
Title: Parent of Schedule
Description: FK on job_sqnc_id links expected schedules to flow configuration

Schedule.job_sqnc_id references FlowConfig.job_sqnc_id. A flow can have multiple schedule rows (e.g., weekday schedule + weekend schedule).

### relationship_note #3  [metadata_id: 2375]
Title: Source: crs5_oltp.dbo.job_sqnc
Description: ConfigSync reads flow definitions from DM

The job_sqnc_id and job_sqnc_shrt_nm columns originate from crs5_oltp.dbo.job_sqnc. ConfigSync queries DM for active flows (job_sqnc_actv_flg = Y) and synchronizes dm_is_active and dm_last_sync_dttm each cycle.

### description / alert_on_critical_failure #12  [metadata_id: 576]

Generate alerts if critical jobs fail within this flow

### description / alert_on_missing #11  [metadata_id: 575]

Generate alerts if flow doesn't start within expected window

### description / config_id #1  [metadata_id: 566]

Unique identifier for this configuration row

### description / created_by #16  [metadata_id: 580]

Who created this row

### description / created_dttm #15  [metadata_id: 579]

When this row was created

### description / dm_is_active #5  [metadata_id: 570]

Whether flow is active in DM (job_sqnc_actv_flg = 'Y'). NULL if never synced

### description / dm_last_sync_dttm #6  [metadata_id: 571]

When ConfigSync last verified this flow against DM

### description / effective_end_date #14  [metadata_id: 578]

When this configuration expires. NULL = no expiration

### description / effective_start_date #13  [metadata_id: 577]

When this configuration becomes active

### description / expected_max_duration_hours #9  [metadata_id: 574]

Expected maximum runtime for duration alerting. Reserved for future use

### description / expected_schedule #8  [metadata_id: 573]

Human-readable schedule description (e.g., 'DAILY', 'WEEKDAYS', 'WEEKLY')

### status_value / expected_schedule #1  [metadata_id: 2378]
Title: DAILY

Flow runs every day.

### status_value / expected_schedule #2  [metadata_id: 2379]
Title: WEEKDAYS

Flow runs Monday through Friday.

### status_value / expected_schedule #3  [metadata_id: 2380]
Title: WEEKLY

Flow runs on a specific day of the week.

### status_value / expected_schedule #4  [metadata_id: 2381]
Title: MONTHLY

Flow runs on a specific day of the month.

### status_value / expected_schedule #5  [metadata_id: 2382]
Title: EVERY_N_HOURS

Flow runs multiple times per day at a fixed interval.

### status_value / expected_schedule #6  [metadata_id: 2383]
Title: VARIABLE

Flow has a non-standard schedule.

### status_value / expected_schedule #7  [metadata_id: 2384]
Title: ON-DEMAND

Flow runs only when manually triggered.

### status_value / expected_schedule #8  [metadata_id: 2385]
Title: UNCONFIGURED

New flow detected by ConfigSync — awaiting schedule configuration. Not included in missing flow detection.

### description / is_monitored #7  [metadata_id: 572]

Whether xFACts should monitor this flow. Set to 0 to exclude from processing

### description / job_sqnc_id #2  [metadata_id: 567]

Flow ID from crs5_oltp.dbo.job_sqnc. Unique constraint

### description / job_sqnc_nm #4  [metadata_id: 569]

Full flow name

### description / job_sqnc_shrt_nm #3  [metadata_id: 568]

Flow short name (e.g., JFDNEV). Denormalized for convenience

### description / modified_by #18  [metadata_id: 582]

Who last modified this row

### description / modified_dttm #17  [metadata_id: 581]

Last modification timestamp

### description / notes #19  [metadata_id: 583]

Free-form notes about this flow configuration

## FlowExecutionTracking (Table)

### category #0  [metadata_id: 1705]

JobFlow

### data_flow #1  [metadata_id: 2393]
Title: Written by Monitor-JobFlow.ps1
Description: Multiple steps create and update tracking rows

Step-DetectFlows: INSERT new rows (state=DETECTED). Step-UpdateFlowProgress: UPDATE job counts. Step-TransitionFlowStates: UPDATE execution_state. Step-ValidateCompletedFlows: UPDATE is_validated and validation_dttm. Step-DetectStalls: UPDATE execution_state to STALLED or back to EXECUTING.

### data_flow #2  [metadata_id: 2394]
Title: Read by Control Center
Description: Dashboard queries for active flow status

The Control Center JobFlow page queries FlowExecutionTracking for currently active flows (DETECTED/EXECUTING states), completion summaries, and historical trend data.

### description #0  [metadata_id: 49]

The core state machine table that tracks each flow execution instance from detection through completion.

### design_note #1  [metadata_id: 2386]
Title: Tracking via job_sqnc_log_id
Description: Why execution instances use the source system log ID

Each flow can execute multiple times per day. The job_sqnc_log_id from crs5_oltp.dbo.job_sqnc_log uniquely identifies each execution instance, preventing incorrect aggregation of multiple daily runs. Added in v1.1.0 after discovering that tracking by job_sqnc_id alone merged separate executions.

### design_note #2  [metadata_id: 2387]
Title: State Machine
Description: Flow state transitions from detection through validation

States: DETECTED ? EXECUTING ? COMPLETE ? VALIDATED (happy path). EXECUTING can also transition to STALLED (no progress for 30+ minutes), which returns to EXECUTING when progress resumes. ABANDONED is a manual terminal state. State transitions are managed by Monitor-JobFlow.ps1 Step-TransitionFlowStates.

### design_note #3  [metadata_id: 2388]
Title: Backfilled Records
Description: Historical data distinguished by tracking_id = 0

Records with tracking_id = 0 were backfilled from dm_history and represent executions that occurred before real-time monitoring began. These rows have NULL job_sqnc_log_id and may have incomplete job counts.

### module #0  [metadata_id: 1601]

JobFlow

### query #1  [metadata_id: 2733]
Title: Currently Executing Flows
Description: Shows all flow executions currently in progress with job counts and start time.

SELECT 
    tracking_id,
    job_sqnc_shrt_nm AS flow_code,
    execution_state,
    executing_job_count,
    pending_job_count,
    completed_job_count,
    execution_window_start
FROM JobFlow.FlowExecutionTracking
WHERE execution_state IN ('DETECTED', 'EXECUTING')
ORDER BY execution_window_start;

### query #2  [metadata_id: 2734]
Title: Today's Flow Summary
Description: Daily overview of all flow executions with state, job counts, record totals, and duration.

SELECT 
    job_sqnc_shrt_nm AS flow_code,
    execution_sequence,
    execution_state,
    expected_job_count,
    completed_job_count,
    failed_job_count,
    aggregate_completed_records,
    DATEDIFF(MINUTE, execution_window_start, ISNULL(completion_dttm, GETDATE())) AS duration_minutes
FROM JobFlow.FlowExecutionTracking
WHERE execution_date = CAST(GETDATE() AS DATE)
ORDER BY execution_window_start;

### query #3  [metadata_id: 2735]
Title: Flows With Multiple Daily Runs
Description: Identifies flows that executed more than once on the same day over the past 30 days — useful for understanding scheduling patterns and detecting anomalies.

SELECT 
    job_sqnc_shrt_nm,
    execution_date,
    COUNT(*) AS run_count
FROM JobFlow.FlowExecutionTracking
WHERE execution_date >= DATEADD(DAY, -30, GETDATE())
GROUP BY job_sqnc_shrt_nm, execution_date
HAVING COUNT(*) > 1
ORDER BY execution_date DESC, run_count DESC;

### query #4  [metadata_id: 2736]
Title: Flows Pending Validation
Description: Finds completed flow executions that have not yet been validated — indicates Step-ValidateCompletedFlows may need attention.

SELECT 
    tracking_id,
    job_sqnc_shrt_nm,
    execution_date,
    completion_dttm
FROM JobFlow.FlowExecutionTracking
WHERE execution_state = 'COMPLETE'
  AND validation_dttm IS NULL
  AND completion_dttm IS NOT NULL
ORDER BY completion_dttm;

### relationship_note #1  [metadata_id: 2389]
Title: Child of FlowConfig
Description: FK on job_sqnc_id links to flow definition

FlowExecutionTracking.job_sqnc_id references FlowConfig.job_sqnc_id. Many execution rows per flow config — one per execution instance.

### relationship_note #2  [metadata_id: 2390]
Title: Parent of JobExecutionLog
Description: FK on tracking_id links individual jobs to their flow execution

JobExecutionLog.tracking_id references FlowExecutionTracking.tracking_id. One execution can have many job completion records.

### relationship_note #3  [metadata_id: 2391]
Title: Parent of ValidationLog
Description: FK on tracking_id links validation results to the validated execution

ValidationLog.tracking_id references FlowExecutionTracking.tracking_id. One validation per completed execution.

### relationship_note #4  [metadata_id: 2392]
Title: Source: crs5_oltp.dbo.job_sqnc_log
Description: Flow execution detection reads from DM execution log

The job_sqnc_log_id column links to crs5_oltp.dbo.job_sqnc_log. Step-DetectFlows queries this table for new execution instances not yet tracked in xFACts.

### description / aggregate_completed_records #22  [metadata_id: 353]

Total records processed across all completed jobs in this execution

### description / cancelled_job_count #20  [metadata_id: 351]

Jobs that were cancelled

### description / completed_job_count #16  [metadata_id: 347]

Jobs with terminal success status

### description / completion_dttm #10  [metadata_id: 341]

When execution_state transitioned to COMPLETE

### description / created_dttm #24  [metadata_id: 355]

When this tracking record was created

### description / executing_job_count #17  [metadata_id: 348]

Jobs currently running (job_stts_cd = 1)

### description / execution_date #5  [metadata_id: 336]

Calendar date of the execution. Used with execution_sequence for daily uniqueness

### description / execution_sequence #6  [metadata_id: 337]

Sequential run number for this flow on this date (1st run = 1, 2nd run = 2, etc.)

### description / execution_state #7  [metadata_id: 338]

Current state: DETECTED, EXECUTING, COMPLETE, FAILED, CANCELLED

### status_value / execution_state #1  [metadata_id: 2395]
Title: DETECTED

Flow execution found in source system. Jobs not yet started.

### status_value / execution_state #2  [metadata_id: 2396]
Title: EXECUTING

At least one job has begun processing.

### status_value / execution_state #3  [metadata_id: 2397]
Title: COMPLETE

All expected jobs have finished. Awaiting validation.

### status_value / execution_state #4  [metadata_id: 2398]
Title: VALIDATED

Post-execution validation has run. Terminal state for happy path.

### status_value / execution_state #5  [metadata_id: 2399]
Title: STALLED

No system-wide progress detected for 30+ minutes. Returns to EXECUTING on recovery.

### status_value / execution_state #6  [metadata_id: 2400]
Title: ABANDONED

Flow manually abandoned. Terminal state.

### description / execution_window_end #14  [metadata_id: 345]

When the last job in the flow completed

### description / execution_window_start #13  [metadata_id: 344]

When the flow execution began in the source system (from job_sqnc_exctn_dttm)

### description / expected_job_count #15  [metadata_id: 346]

Number of jobs defined in the flow at detection time

### description / expected_jobs_json #21  [metadata_id: 352]

JSON array of expected jobs captured at detection time. Preserves flow definition even if it changes later

### description / failed_job_count #19  [metadata_id: 350]

Jobs that failed (job_stts_cd = 2 with zero records processed)

### description / first_detected_dttm #8  [metadata_id: 339]

When sp_StateMonitor first detected this execution

### description / is_validated #12  [metadata_id: 343]

Set to 1 after Step-ValidateCompletedFlows processes the flow. Prevents duplicate validation

### description / job_sqnc_id #3  [metadata_id: 334]

The flow definition ID from crs5_oltp.dbo.job_sqnc. Does not change between executions

### description / job_sqnc_log_id #2  [metadata_id: 333]

FK

### description / job_sqnc_shrt_nm #4  [metadata_id: 335]

Flow short name (e.g., JFDNEV, JFD4HR). Denormalized for query convenience

### description / last_activity_dttm #9  [metadata_id: 340]

Last time any change was recorded for this execution

### description / last_poll_completed_records #23  [metadata_id: 354]

Records completed as of the previous poll. Used to calculate throughput

### description / modified_dttm #25  [metadata_id: 356]

Last modification timestamp. Updated on every poll that touches this row

### description / pending_job_count #18  [metadata_id: 349]

Jobs waiting to start (job_stts_cd = 6)

### description / tracking_id #1  [metadata_id: 332]

PK

### description / validation_dttm #11  [metadata_id: 342]

When post-completion validation was run (if applicable)

## JobConfig (Table)

### category #0  [metadata_id: 1706]

JobFlow

### description #0  [metadata_id: 46]

Job-level configuration including DM synchronization, criticality classification, and fixed date logic detection for prioritized alerting.

### design_note #1  [metadata_id: 2401]
Title: Dual Criticality Model
Description: Two independent reasons a job can be critical

has_fixed_date_logic flags jobs whose SQL filters use today-only date logic — records are permanently missed if the job does not run on schedule. is_business_critical flags jobs essential to daily operations regardless of date logic. The computed is_critical column (persisted) is 1 if either flag is set, simplifying queries while preserving the reason.

### design_note #2  [metadata_id: 2402]
Title: Population and Maintenance
Description: Initial load from DM history, ongoing via ConfigSync

Initial population from 313 historical jobs found in DM execution history. Criticality flags populated through team review of job filter logic and business requirements. ConfigSync maintains dm_is_active and dm_last_sync_dttm for drift detection.

### module #0  [metadata_id: 1602]

JobFlow

### query #1  [metadata_id: 2751]
Title: Critical Jobs Summary
Description: Lists all jobs marked critical (either fixed date logic or business critical) with their classification reason.

SELECT 
    job_shrt_nm,
    job_nm,
    has_fixed_date_logic,
    is_business_critical,
    criticality_reason
FROM JobFlow.JobConfig
WHERE is_critical = 1
ORDER BY job_shrt_nm;

### query #2  [metadata_id: 2752]
Title: Jobs by Criticality Type
Description: Distribution of jobs across criticality categories — helps assess alert coverage.

SELECT 
    CASE 
        WHEN has_fixed_date_logic = 1 AND is_business_critical = 1 THEN 'Both'
        WHEN has_fixed_date_logic = 1 THEN 'Fixed Date Logic'
        WHEN is_business_critical = 1 THEN 'Business Critical'
        ELSE 'Not Critical'
    END AS criticality_type,
    COUNT(*) AS job_count
FROM JobFlow.JobConfig
GROUP BY 
    CASE 
        WHEN has_fixed_date_logic = 1 AND is_business_critical = 1 THEN 'Both'
        WHEN has_fixed_date_logic = 1 THEN 'Fixed Date Logic'
        WHEN is_business_critical = 1 THEN 'Business Critical'
        ELSE 'Not Critical'
    END
ORDER BY job_count DESC;

### query #3  [metadata_id: 2753]
Title: Jobs Not Recently Executed
Description: Finds active jobs that haven't executed in 30+ days — may indicate deactivated or orphaned job definitions.

SELECT 
    job_shrt_nm,
    last_execution_dttm,
    DATEDIFF(DAY, last_execution_dttm, GETDATE()) AS days_since_execution
FROM JobFlow.JobConfig
WHERE dm_is_active = 1
  AND (last_execution_dttm IS NULL OR last_execution_dttm < DATEADD(DAY, -30, GETDATE()))
ORDER BY last_execution_dttm;

### relationship_note #1  [metadata_id: 2403]
Title: Referenced by ValidationException
Description: Criticality lookup during flow validation

Step-ValidateCompletedFlows joins JobConfig to determine if a missing or failed job is critical. The is_critical flag and criticality_reason drive alert severity and Jira ticket content.

### relationship_note #2  [metadata_id: 2404]
Title: Source: crs5_oltp.dbo.job
Description: Job definitions and activity status from DM

The job_id and job_shrt_nm columns originate from crs5_oltp.dbo.job. ConfigSync synchronizes dm_is_active status from DM.

### description / config_id #1  [metadata_id: 286]

PK

### description / created_by #13  [metadata_id: 297]

Who created this row

### description / created_dttm #12  [metadata_id: 296]

When this row was created

### description / criticality_reason #9  [metadata_id: 293]

Explanation of why job is marked critical

### description / dm_is_active #5  [metadata_id: 290]

Whether job is active in DM. NULL if never synced

### description / dm_last_sync_dttm #6  [metadata_id: 291]

When last verified against DM

### description / effective_end_date #11  [metadata_id: 295]

When this configuration expires. NULL = no expiration

### description / effective_start_date #10  [metadata_id: 294]

When this configuration becomes active

### description / has_fixed_date_logic #17  [metadata_id: 301]

Job filter uses fixed dates (e.g., WHERE date = TODAY). Records permanently lost if missed

### description / is_business_critical #18  [metadata_id: 302]

Job is essential for daily operations regardless of date logic

### description / is_critical #19  [metadata_id: 303]

1 if either flag is set, 0 otherwise. Computed persisted column

### description / job_id #2  [metadata_id: 287]

UQ

### description / job_nm #4  [metadata_id: 289]

Full job name

### description / job_shrt_nm #3  [metadata_id: 288]

Job short name (e.g., NBIMPORT). Denormalized

### description / last_execution_dttm #7  [metadata_id: 292]

When job last executed (from DM history)

### description / modified_by #15  [metadata_id: 299]

Who last modified this row

### description / modified_dttm #14  [metadata_id: 298]

Last modification timestamp

### description / notes #16  [metadata_id: 300]

Free-form notes about this job configuration

## JobExecutionLog (Table)

### category #0  [metadata_id: 1707]

JobFlow

### data_flow #1  [metadata_id: 2410]
Title: Written by Monitor-JobFlow.ps1 (CaptureJobs)
Description: Step-CaptureCompletedJobs inserts rows for newly completed jobs

Queries crs5_oltp.dbo.job_log for jobs with terminal status codes (2, 3, 4) not already in JobExecutionLog (dedup via NOT EXISTS on job_log_id). Calculates job_status using status translation rules, captures record counts, timing metrics, and error messages.

### data_flow #2  [metadata_id: 2411]
Title: Read by Step-ValidateCompletedFlows
Description: Validation references captured jobs for outcome analysis

Step-ValidateCompletedFlows reads JobExecutionLog for all jobs associated with a completed flow to determine validation status — comparing expected jobs against actual outcomes and classifying error patterns via ErrorCategory.

### description #0  [metadata_id: 88]

Captures detailed execution history for individual jobs within flow executions, preserving metrics at the moment of completion.

### design_note #1  [metadata_id: 2405]
Title: Status Translation
Description: xFACts job status differs from raw DM status codes

DM marks a job as Failed (status 2) if any record fails validation. xFACts uses PARTIAL when records were successfully processed despite some rejections, reserving FAILED for true technical failures where no work was done. This prevents false alarms on jobs that are working correctly but have expected business rule rejections.

### design_note #2  [metadata_id: 2406]
Title: Capture Timing
Description: captured_dttm vs actual completion time

Rows are inserted when Monitor-JobFlow.ps1 Step-CaptureCompletedJobs detects a terminal status. captured_dttm is when xFACts recorded the event, not when the job actually finished. The job_reported_complete_dttm from DM is the actual completion time. The gap depends on polling interval (up to ~5 minutes).

### design_note #3  [metadata_id: 2407]
Title: Data Volume
Description: Continuous growth table

Approximately 200-400 new rows per night during normal operations. Historical data spans back to June 2020 via backfill from dm_history. Records with tracking_id = 0 indicate pre-monitoring backfill.

### module #0  [metadata_id: 1603]

JobFlow

### query #1  [metadata_id: 2737]
Title: Jobs Completed Today
Description: All job completions for today with status, record counts, and duration.

SELECT 
    job_shrt_nm,
    job_sqnc_shrt_nm AS flow_code,
    job_status,
    total_records,
    succeeded_count,
    failed_count,
    execution_time_seconds
FROM JobFlow.JobExecutionLog
WHERE execution_date = CAST(GETDATE() AS DATE)
ORDER BY captured_dttm DESC;

### query #2  [metadata_id: 2738]
Title: Failed Jobs in Date Range
Description: Shows jobs with FAILED or PARTIAL status over the past 7 days with error messages for troubleshooting.

SELECT 
    execution_date,
    job_shrt_nm,
    job_sqnc_shrt_nm AS flow_code,
    job_status,
    error_message
FROM JobFlow.JobExecutionLog
WHERE job_status IN ('FAILED', 'PARTIAL')
  AND execution_date >= DATEADD(DAY, -7, GETDATE())
ORDER BY execution_date DESC, captured_dttm DESC;

### query #3  [metadata_id: 2739]
Title: Job Execution Trends
Description: Aggregated performance metrics per job over the past 30 days — execution count, average duration, throughput, and total records processed.

SELECT 
    job_shrt_nm,
    COUNT(*) AS execution_count,
    AVG(execution_time_seconds) AS avg_duration_sec,
    AVG(records_per_second) AS avg_throughput,
    SUM(succeeded_count) AS total_records_processed
FROM JobFlow.JobExecutionLog
WHERE execution_date >= DATEADD(DAY, -30, GETDATE())
GROUP BY job_shrt_nm
ORDER BY execution_count DESC;

### relationship_note #1  [metadata_id: 2408]
Title: Child of FlowExecutionTracking
Description: FK on tracking_id links jobs to their flow execution

JobExecutionLog.tracking_id references FlowExecutionTracking.tracking_id. NULL or 0 tracking_id indicates backfilled or orphaned records not captured by real-time monitoring.

### relationship_note #2  [metadata_id: 2409]
Title: Source: crs5_oltp.dbo.job_log
Description: Job execution records with metrics from DM

The job_log_id column links to crs5_oltp.dbo.job_log. Record counts come from job_entty_log aggregation. IX_JobExecutionLog_JobLogId supports NOT EXISTS deduplication during capture.

### description / captured_dttm #25  [metadata_id: 969]

When xFACts captured this completion record

### description / error_message #24  [metadata_id: 968]

Error text from DM if job failed. Sanitized of PII

### description / executed_by #11  [metadata_id: 955]

Username that initiated the execution

### description / execution_date #12  [metadata_id: 956]

Calendar date of execution. Used for daily aggregations

### description / execution_detail_id #1  [metadata_id: 945]

Unique identifier for each job execution record

### description / execution_order_nmbr #9  [metadata_id: 953]

Order position within the flow (1st job, 2nd job, etc.)

### description / execution_time_seconds #21  [metadata_id: 965]

Total execution duration in seconds

### description / execution_type #10  [metadata_id: 954]

How the job was triggered: SCHEDULED or AD_HOC

### description / failed_count #19  [metadata_id: 963]

Records that failed business rule validation

### description / job_end_dttm #15  [metadata_id: 959]

When the last record finished processing

### description / job_exec_dttm #13  [metadata_id: 957]

When the job execution was initiated (from job_log)

### description / job_id #4  [metadata_id: 948]

Job definition ID from crs5_oltp.dbo.job

### description / job_log_id #3  [metadata_id: 947]

Links to crs5_oltp.dbo.job_log. The source system execution ID

### description / job_nm #6  [metadata_id: 950]

Full job name. May be NULL for older records

### description / job_reported_complete_dttm #16  [metadata_id: 960]

When DM marked the job complete (status change timestamp)

### description / job_shrt_nm #5  [metadata_id: 949]

Job short name (e.g., NBIMPORT, INTCALC). Denormalized for convenience

### description / job_sqnc_id #7  [metadata_id: 951]

Flow ID this job executed within. NULL if job ran outside a flow

### description / job_sqnc_shrt_nm #8  [metadata_id: 952]

Flow short name. NULL if job ran outside a flow

### description / job_start_dttm #14  [metadata_id: 958]

When the first record began processing

### description / job_status #22  [metadata_id: 966]

xFACts status: EXECUTING, PENDING, CANCELLED, CANCELLING, FAILED, COMPLETED, PARTIAL, UNKNOWN

### status_value / job_status #1  [metadata_id: 2412]
Title: COMPLETED

Job completed successfully. All records processed or DM status 3 with no failures.

### status_value / job_status #2  [metadata_id: 2413]
Title: PARTIAL

Job processed some records but some failed business validation. DM status 2 or 3 with both succeeded and failed counts.

### status_value / job_status #3  [metadata_id: 2414]
Title: FAILED

True technical failure — DM status 2 with zero records successfully processed.

### status_value / job_status #4  [metadata_id: 2415]
Title: CANCELLED

Job cancelled by user. DM status 4.

### status_value / job_status #5  [metadata_id: 2416]
Title: EXECUTING

Job still running. DM status 1. Should not appear in completed job log under normal operation.

### status_value / job_status #6  [metadata_id: 2417]
Title: PENDING

Job queued, waiting to start. DM status 6.

### status_value / job_status #7  [metadata_id: 2418]
Title: UNKNOWN

Unmapped DM status code. Indicates a new status not yet added to translation logic.

### description / job_stts_cd #23  [metadata_id: 967]

Raw DM status code (1=Started, 2=Failed, 3=Complete, etc.)

### description / records_per_second #20  [metadata_id: 964]

Calculated throughput rate

### description / succeeded_count #18  [metadata_id: 962]

Records that processed without errors

### description / total_records #17  [metadata_id: 961]

Total records assigned to this job (job_entty_ttl_nmbr). NULL if job had no records

### description / tracking_id #2  [metadata_id: 946]

Links to FlowExecutionTracking. NULL or 0 for backfilled/orphaned records

## JobStatus (Table)

### category #0  [metadata_id: 1708]

JobFlow

### description #0  [metadata_id: 92]

Reference table mapping Debt Manager job status codes to human-readable descriptions and xFACts-effective status interpretations.

### design_note #1  [metadata_id: 2419]
Title: Reference Lookup Table
Description: Maps DM numeric codes to human-readable status descriptions

Static reference table with 6 rows — one per DM job_stts_cd value (1-6). The xfacts_effective_status column provides the xFACts interpretation which can differ from DM. For example, DM status 2 (Failed) maps to either PARTIAL or FAILED in xFACts depending on whether any records processed successfully. The is_terminal flag indicates final vs in-progress states.

### module #0  [metadata_id: 1604]

JobFlow

### description / is_terminal #5  [metadata_id: 1026]

1 if this is a final state, 0 if job is still in progress

### description / job_stts_cd #1  [metadata_id: 1022]

Primary key. DM status code (1-6)

### description / job_stts_dscrptn_txt #3  [metadata_id: 1024]

Full description of what this status means

### description / job_stts_val_txt #2  [metadata_id: 1023]

Short status name from DM (e.g., 'Started', 'Failed')

### description / xfacts_effective_status #4  [metadata_id: 1025]

xFACts interpretation: COMPLETED, PARTIAL, FAILED, CANCELLED, EXECUTING, PENDING

## Monitor-JobFlow.ps1 (Script)

### category #0  [metadata_id: 2461]

JobFlow

### data_flow #1  [metadata_id: 2465]
Title: Reads from Debt Manager (crs5_oltp)
Description: Source system tables via AG secondary replica

Reads: job_sqnc_log (flow executions), job_sqnc (flow definitions for ConfigSync), job_sqnc_exctn_log (flow-to-job linkage), job_log (job executions), job_entty_log (record-level results), job (job definitions), usr (user identification). All reads via AG secondary replica by default.

### data_flow #2  [metadata_id: 2466]
Title: Writes to JobFlow schema
Description: Updates tracking, logging, and status tables

Writes: FlowConfig (ConfigSync updates), FlowExecutionTracking (state machine), JobExecutionLog (job captures), Status (step health), StallDetectionLog (stall events), ValidationLog (validation results), ValidationException (validation details).

### data_flow #3  [metadata_id: 2467]
Title: Queues to Teams and Jira
Description: Alert delivery via integration modules

Stall alerts, missing flow alerts, and critical validation failures queue to Teams.AlertQueue (via sp_QueueAlert or direct INSERT) and Jira.TicketQueue (via sp_QueueTicket). Uses cascading field: Debt Manager > DM Configuration Issues.

### description #0  [metadata_id: 2459]

Core monitoring engine for Debt Manager job flows. Detects new flow executions, captures job completions, manages flow state transitions, detects system stalls, validates completed flows, and identifies missing scheduled flows. Runs every 5 minutes via the Orchestrator.

### design_note #1  [metadata_id: 2462]
Title: Eight-Step Processing Pipeline
Description: Two execution paths depending on job activity

Step 0: ConfigSync — synchronize FlowConfig with DM. Step 1: DetectFlows — find new executions. Step 2: CaptureJobs — record completed jobs. Step 3: UpdateProgress — update flow job counts. Step 4: TransitionStates — manage state machine. Step 5: DetectStalls — snapshot comparison. Step 6: ValidateFlows — analyze completed flows. Step 7: DetectMissing — check for no-show flows. Each step updates its own row in JobFlow.Status. Not all steps run on every cycle — see the Early Exit design note.

### design_note #2  [metadata_id: 2463]
Title: AG-Aware Architecture
Description: Reads from configurable replica, writes to listener

Automatically detects AG replica roles at startup via the listener. Uses GlobalConfig SourceReplica setting to select read server (PRIMARY or SECONDARY). Always writes to the xFACts listener. ForceSourceServer parameter can override for testing. If replica is unavailable, the script logs the failure and exits — retried on next orchestrator cycle.

### design_note #3  [metadata_id: 2464]
Title: Preview Mode
Description: Default execution is read-only

Without the -Execute switch, the script runs in preview mode — reads all source data, evaluates all conditions, and displays what would happen without making any changes. Essential for testing and troubleshooting. The -Execute switch must be present for any writes to occur.

### design_note #4  [metadata_id: 3084]
Title: Early Exit on No Job Activity
Description: Skips Steps 1-6 when DM has no active or pending jobs

After ConfigSync, the script queries crs5_oltp.dbo.job_log for jobs in status 1 (Started) or 6 (Pending). If none are found, Steps 1 through 6 are skipped and only Step 7 (DetectMissing) runs before exit. This eliminates the heavy join against dbo.job_entty_log in Step 2 — a table with hundreds of millions of rows that generated significant read load on the DM secondary replica on every cycle regardless of whether any flows were executing. ConfigSync always runs because flow definition drift is independent of job activity. DetectMissing always runs because it specifically targets flows that have not started — gating it on job activity would prevent it from ever alerting.

### module #0  [metadata_id: 2460]

JobFlow

### relationship_note #1  [metadata_id: 2468]
Title: Orchestrator.ProcessRegistry
Description: Scheduled execution via the xFACts Orchestrator

Registered as module_name=JobFlow, process_name=Monitor-JobFlow, execution_mode=FIRE_AND_FORGET, interval_seconds=300. Reports completion via Complete-OrchestratorTask callback using TaskId and ProcessId parameters.

### relationship_note #2  [metadata_id: 2469]
Title: Reads: FlowConfig, JobConfig, Schedule, ErrorCategory, JobStatus
Description: Configuration and reference tables drive monitoring behavior

FlowConfig controls which flows are monitored and alert settings. JobConfig provides criticality flags for validation. Schedule defines expected execution windows. ErrorCategory classifies error patterns for alert decisions. JobStatus maps DM codes to xFACts statuses.

### relationship_note #3  [metadata_id: 2470]
Title: GlobalConfig settings
Description: AG configuration and stall threshold from shared config

Reads dbo.GlobalConfig for: AGName (AG identification), SourceReplica (which replica to read from), StallThreshold (polls before stall alert, default 6).

## Schedule (Table)

### category #0  [metadata_id: 1709]

JobFlow

### description #0  [metadata_id: 74]

Expected execution schedules for job flows, used by missing flow detection to identify when flows should have started.

### design_note #1  [metadata_id: 2420]
Title: Multiple Schedules Per Flow
Description: A flow can have different schedules for different days

A flow can have multiple schedule rows. For example, a flow might run at 10 PM on weekdays and 8 AM on weekends. Each schedule row has its own tolerance window, active flag, and alert setting. The Schedule table supports DAILY, WEEKDAYS, WEEKLY, MONTHLY, and EVERY_N_HOURS schedule types.

### design_note #2  [metadata_id: 2421]
Title: Tolerance Window
Description: Buffer time before missing flow alert fires

start_time_tolerance_minutes provides buffer after the expected start time before a missing flow alert fires. Default is 60 minutes. Critical nightly flows might use 60 min, hourly flows 15 min. The detection logic evaluates: current time > expected_start_time + tolerance AND no execution exists for today.

### module #0  [metadata_id: 1605]

JobFlow

### query #1  [metadata_id: 2740]
Title: Active Schedules with Deadlines
Description: All active schedules configured for missing flow alerts, with calculated deadline times.

SELECT 
    job_sqnc_shrt_nm AS flow_code,
    schedule_type,
    expected_start_time,
    start_time_tolerance_minutes,
    DATEADD(MINUTE, start_time_tolerance_minutes, 
            CAST(expected_start_time AS DATETIME)) AS deadline_time
FROM JobFlow.Schedule
WHERE is_active = 1
  AND alert_on_missing = 1
ORDER BY expected_start_time;

### query #2  [metadata_id: 2741]
Title: Today's Expected Flows
Description: Evaluates schedule types and day-of-week rules to show which flows should execute today.

DECLARE @today_dow INT = DATEPART(WEEKDAY, GETDATE());

SELECT 
    job_sqnc_shrt_nm AS flow_code,
    schedule_type,
    expected_start_time
FROM JobFlow.Schedule
WHERE is_active = 1
  AND (
      schedule_type = 'DAILY'
      OR (schedule_type = 'WEEKDAYS' AND @today_dow BETWEEN 2 AND 6)
      OR (schedule_type = 'WEEKLY' AND schedule_day_of_week = @today_dow)
      OR (schedule_type = 'MONTHLY' AND schedule_day_of_month = DAY(GETDATE()))
      OR schedule_type = 'EVERY_N_HOURS'
  )
ORDER BY expected_start_time;

### query #3  [metadata_id: 2742]
Title: Flows Past Deadline
Description: Identifies flows that should have started by now but have no execution recorded today — the same logic Step-DetectMissingFlows uses.

SELECT 
    s.job_sqnc_shrt_nm,
    s.expected_start_time,
    s.start_time_tolerance_minutes,
    DATEADD(MINUTE, s.start_time_tolerance_minutes, 
            CAST(CAST(GETDATE() AS DATE) AS DATETIME) + CAST(s.expected_start_time AS DATETIME)) AS deadline
FROM JobFlow.Schedule s
WHERE s.is_active = 1
  AND GETDATE() > DATEADD(MINUTE, s.start_time_tolerance_minutes, 
            CAST(CAST(GETDATE() AS DATE) AS DATETIME) + CAST(s.expected_start_time AS DATETIME))
  AND NOT EXISTS (
      SELECT 1 FROM JobFlow.FlowExecutionTracking t
      WHERE t.job_sqnc_id = s.job_sqnc_id
        AND t.execution_date = CAST(GETDATE() AS DATE)
  );

### relationship_note #1  [metadata_id: 2422]
Title: Child of FlowConfig
Description: FK on job_sqnc_id links schedules to flow configuration

Schedule.job_sqnc_id references FlowConfig.job_sqnc_id. Multiple schedule rows per flow are supported. Only active schedules (is_active = 1) with alert_on_missing = 1 trigger missing flow detection.

### description / alert_on_missing #12  [metadata_id: 775]

Whether to alert if flow misses this schedule

### description / created_by #16  [metadata_id: 779]

Who created this row

### description / created_dttm #15  [metadata_id: 778]

When this row was created

### description / effective_end_date #14  [metadata_id: 777]

When this schedule expires. NULL = no expiration

### description / effective_start_date #13  [metadata_id: 776]

When this schedule becomes active

### description / expected_start_time #9  [metadata_id: 772]

Time of day the flow should start

### description / is_active #11  [metadata_id: 774]

Whether this schedule is currently active

### description / job_sqnc_id #2  [metadata_id: 765]

Flow ID from Config table

### description / job_sqnc_shrt_nm #3  [metadata_id: 766]

Flow short name. Denormalized for convenience

### description / modified_by #18  [metadata_id: 781]

Who last modified this row

### description / modified_dttm #17  [metadata_id: 780]

Last modification timestamp

### description / notes #19  [metadata_id: 782]

Free-form notes about this schedule

### description / schedule_day_of_month #7  [metadata_id: 770]

For MONTHLY: day of month (1-31)

### description / schedule_day_of_week #6  [metadata_id: 769]

For WEEKLY: 1=Sunday through 7=Saturday

### description / schedule_frequency #5  [metadata_id: 768]

For EVERY_N_HOURS: interval in hours

### description / schedule_id #1  [metadata_id: 764]

Unique identifier for this schedule row

### description / schedule_type #4  [metadata_id: 767]

Type: DAILY, WEEKDAYS, WEEKLY, MONTHLY, EVERY_N_HOURS

### status_value / schedule_type #1  [metadata_id: 2423]
Title: DAILY

Runs every day at expected_start_time.

### status_value / schedule_type #2  [metadata_id: 2424]
Title: WEEKDAYS

Runs Monday through Friday at expected_start_time.

### status_value / schedule_type #3  [metadata_id: 2425]
Title: WEEKLY

Runs on schedule_day_of_week at expected_start_time.

### status_value / schedule_type #4  [metadata_id: 2426]
Title: MONTHLY

Runs on schedule_day_of_month at expected_start_time.

### status_value / schedule_type #5  [metadata_id: 2427]
Title: EVERY_N_HOURS

Runs every schedule_frequency hours starting at expected_start_time.

### status_value / schedule_type #6  [metadata_id: 2428]
Title: CUSTOM

Non-standard schedule requiring manual evaluation.

### description / schedule_week_of_month #8  [metadata_id: 771]

For MONTHLY: week of month (1-5)

### description / start_time_tolerance_minutes #10  [metadata_id: 773]

Minutes after expected time before alerting

## StallDetectionLog (Table)

### category #0  [metadata_id: 1710]

JobFlow

### description #0  [metadata_id: 56]

Append-only audit log capturing stall detection events with diagnostic XML snapshots for troubleshooting and historical analysis.

### design_note #1  [metadata_id: 2438]
Title: Append-Only Audit Trail
Description: Complete history of stall detection events

Rows are never updated or deleted. Events are only logged when the counter changes (INCREMENT, RESET, ALERT, STALLED), not on every poll. This keeps the table manageable while capturing all meaningful stall detection activity. Normal nights produce 0-2 rows. Actual stall events produce 7+ rows.

### design_note #2  [metadata_id: 2439]
Title: Deduplication Source (v1.8.0+)
Description: Authoritative source for stall alert deduplication

Stall alerts are suppressed if an ALERT event exists today with no subsequent RESET. This allows multiple alerts per day when a stall-recovery-stall cycle occurs — a second stall after recovery generates a fresh ticket. Replaces the previous stall_alert_sent_dttm approach.

### module #0  [metadata_id: 1606]

JobFlow

### query #1  [metadata_id: 2743]
Title: Today's Stall Events
Description: All stall detection events for today — shows the counter progression and whether alerts were fired.

SELECT 
    poll_dttm,
    event_type,
    counter_before,
    counter_after,
    jira_queued,
    teams_queued
FROM JobFlow.StallDetectionLog
WHERE CAST(poll_dttm AS DATE) = CAST(GETDATE() AS DATE)
ORDER BY poll_dttm;

### query #2  [metadata_id: 2744]
Title: Recent ALERT Events
Description: Shows actual stall alerts fired in the past 7 days with diagnostic snapshot XML for investigation.

SELECT 
    poll_dttm,
    counter_before,
    counter_after,
    jira_queued,
    teams_queued,
    snapshot_comparison_xml
FROM JobFlow.StallDetectionLog
WHERE event_type = 'ALERT'
  AND poll_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY poll_dttm DESC;

### query #3  [metadata_id: 2745]
Title: Check Active Stall Status
Description: Determines whether there is an active stall right now (ALERT fired today with no subsequent RESET) — matches the deduplication logic in Monitor-JobFlow.

SELECT 
    CASE 
        WHEN EXISTS (
            SELECT 1 FROM JobFlow.StallDetectionLog sdl
            WHERE CAST(sdl.poll_dttm AS DATE) = CAST(GETDATE() AS DATE)
              AND sdl.event_type = 'ALERT'
              AND NOT EXISTS (
                  SELECT 1 FROM JobFlow.StallDetectionLog r
                  WHERE r.poll_dttm > sdl.poll_dttm
                    AND r.event_type = 'RESET'
              )
        )
        THEN 'Active stall - alerts suppressed'
        ELSE 'No active stall - new alert would fire'
    END AS stall_status;

### query #4  [metadata_id: 2746]
Title: Extract Jobs from XML Snapshot
Description: Shreds the diagnostic XML to show individual jobs that were executing/pending during a stall event. Replace @log_id with the target log entry.

SELECT 
    log_id,
    poll_dttm,
    event_type,
    j.value('@id', 'INT') AS job_log_id,
    j.value('@status', 'INT') AS job_status,
    j.value('@count', 'INT') AS processed_count
FROM JobFlow.StallDetectionLog
CROSS APPLY snapshot_comparison_xml.nodes('//Snapshot1/Job') AS t(j)
WHERE log_id = @log_id;

### relationship_note #1  [metadata_id: 2444]
Title: Links to Orchestrator execution
Description: detail_id references the poll cycle that generated this event

The detail_id column links to the Orchestrator execution detail for the monitoring cycle that detected the stall event. Enables correlation with orchestrator timing and other module activity during the same cycle.

### description / counter_after #5  [metadata_id: 453]

no_progress_poll_count value after this event

### description / counter_before #4  [metadata_id: 452]

no_progress_poll_count value before this event

### description / created_dttm #12  [metadata_id: 460]

When this log entry was created

### description / event_type #8  [metadata_id: 456]

Event classification: INCREMENT, ALERT, STALLED, RESET

### status_value / event_type #1  [metadata_id: 2440]
Title: INCREMENT

No progress detected. Counter increased by 1. Building toward threshold.

### status_value / event_type #2  [metadata_id: 2441]
Title: ALERT

Counter reached threshold (default: 6). Stall confirmed. Jira ticket and Teams alert queued.

### status_value / event_type #3  [metadata_id: 2442]
Title: STALLED

Continuing stall after ALERT. Counter still incrementing. No additional alerts.

### status_value / event_type #4  [metadata_id: 2443]
Title: RESET

Progress detected. Counter reset to 0. Stall episode ended.

### description / jira_queued #10  [metadata_id: 458]

1 if a Jira ticket was queued for this event

### description / log_id #1  [metadata_id: 449]

Unique identifier for each log entry

### description / poll_dttm #3  [metadata_id: 451]

When the poll occurred

### description / snapshot_comparison_xml #9  [metadata_id: 457]

Full snapshot data including job lists, cross-poll comparison, and progress indicators

### description / stall_threshold #6  [metadata_id: 454]

Configured threshold at time of event (typically 6)

### description / task_id #2  [metadata_id: 450]

Links to Orchestrator_ExecutionDetail for the poll that generated this event

### description / teams_queued #11  [metadata_id: 459]

1 if a Teams alert was queued for this event

### description / threshold_reached #7  [metadata_id: 455]

1 if counter_after >= stall_threshold

## Status (Table)

### category #0  [metadata_id: 1711]

JobFlow

### data_flow #1  [metadata_id: 2436]
Title: Written by Monitor-JobFlow.ps1
Description: Each step updates its own row at start and completion

At step start: UPDATE started_dttm. At step end: UPDATE completed_dttm, last_status (SUCCESS/FAILED), last_result_count, last_error_message. DetectStalls additionally updates stall_snapshot_xml and stall_no_progress_count.

### data_flow #2  [metadata_id: 2437]
Title: Read by Control Center
Description: Dashboard health monitoring

The Control Center queries Status for at-a-glance monitoring health. If completed_dttm for any step is more than 10 minutes old, the monitoring script may not be running.

### description #0  [metadata_id: 45]

Tracks execution state and health metrics for each step of the Monitor-JobFlow.ps1 script, including stall detection snapshots.

### design_note #1  [metadata_id: 2434]
Title: Fixed Row Set
Description: Exactly 8 rows — one per processing step

The table contains exactly 8 rows corresponding to the processing steps in Monitor-JobFlow.ps1: ConfigSync (0), DetectFlows (1), CaptureJobs (2), UpdateProgress (3), TransitionStates (4), DetectStalls (5), ValidateFlows (6), DetectMissing (7). Rows are never inserted or deleted during normal operation — only updated.

### design_note #2  [metadata_id: 2435]
Title: Stall State Storage
Description: DetectStalls row carries inter-cycle state

The DetectStalls row stores stall_snapshot_xml (XML snapshot of executing/pending job_log_ids) and stall_no_progress_count (consecutive polls with no change). This state persists between Monitor-JobFlow.ps1 invocations, enabling cross-poll comparison without additional tables.

### module #0  [metadata_id: 1607]

JobFlow

### query #1  [metadata_id: 2747]
Title: Current Step Status
Description: Dashboard view of all eight processing steps — last status, result count, and minutes since last run.

SELECT 
    process_name,
    last_status,
    last_result_count,
    completed_dttm,
    DATEDIFF(MINUTE, completed_dttm, GETDATE()) AS minutes_ago
FROM JobFlow.Status
ORDER BY status_id;

### query #2  [metadata_id: 2748]
Title: Recent Step Failures
Description: Shows any processing steps that failed in the past 24 hours with error details.

SELECT 
    process_name,
    last_status,
    last_error_message,
    completed_dttm
FROM JobFlow.Status
WHERE last_status = 'FAILED'
  AND completed_dttm >= DATEADD(HOUR, -24, GETDATE());

### query #3  [metadata_id: 2749]
Title: Stall Detection State
Description: Quick check of the current stall counter and snapshot without digging into StallDetectionLog.

SELECT 
    stall_no_progress_count,
    stall_snapshot_xml,
    completed_dttm AS last_check
FROM JobFlow.Status
WHERE process_name = 'DetectStalls';

### query #4  [metadata_id: 2750]
Title: Verify Script Is Running
Description: Health check — if DetectFlows completed more than 10 minutes ago, Monitor-JobFlow may not be running.

SELECT 
    process_name,
    completed_dttm,
    DATEDIFF(MINUTE, completed_dttm, GETDATE()) AS minutes_since_last_run
FROM JobFlow.Status
WHERE process_name = 'DetectFlows'
  AND DATEDIFF(MINUTE, completed_dttm, GETDATE()) > 10;

### description / completed_dttm #4  [metadata_id: 279]

When the step finished execution

### description / created_dttm #11  [metadata_id: 285]

When the row was created

### description / last_error_message #7  [metadata_id: 282]

Error details if last_status = FAILED

### description / last_result_count #6  [metadata_id: 281]

Number of items processed (flows detected, jobs captured, etc.)

### description / last_status #5  [metadata_id: 280]

Result of last execution: SUCCESS or FAILED

### description / process_name #2  [metadata_id: 277]

Step name: ConfigSync, DetectFlows, CaptureJobs, UpdateProgress, TransitionStates, DetectStalls, ValidateFlows, DetectMissing

### description / stall_last_progress_dttm #9  [metadata_id: 3661]

When meaningful progress was last detected during stall evaluation. Updated each poll cycle when the executing job snapshot differs from the previous cycle. Used with stall_no_progress_count to determine whether a flow has stalled.

### description / stall_no_progress_count #8  [metadata_id: 283]

Counter of consecutive polls with no progress. Resets to 0 when progress detected

### description / stall_snapshot_xml #10  [metadata_id: 284]

XML snapshot of current executing/pending job_log_ids for comparison

### description / started_dttm #3  [metadata_id: 278]

When the step began execution

### description / status_id #1  [metadata_id: 276]

Unique identifier for each status row

## ValidationException (Table)

### category #0  [metadata_id: 1712]

JobFlow

### description #0  [metadata_id: 80]

Detailed exception records for individual job-level issues found during flow execution validation, including missing jobs, failed jobs, and order discrepancies.

### design_note #1  [metadata_id: 2454]
Title: Normalized Exception Detail
Description: One row per discrepancy found during validation

Each exception is a separate row, enabling flexible querying and aggregation across flows and exception types. The is_critical flag is set based on JobConfig.is_critical for the referenced job_id. The job_exctn_msg_txt field preserves DM error messages sanitized of PII.

### module #0  [metadata_id: 1608]

JobFlow

### query #1  [metadata_id: 2756]
Title: Recent Exceptions
Description: All validation exceptions from the past 7 days with flow context from ValidationLog.

SELECT 
    vl.job_sqnc_shrt_nm AS flow_code,
    vl.execution_date,
    ve.exception_type,
    ve.job_shrt_nm,
    ve.is_critical,
    ve.job_exctn_msg_txt
FROM JobFlow.ValidationException ve
INNER JOIN JobFlow.ValidationLog vl ON vl.validation_id = ve.validation_id
WHERE ve.created_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY ve.created_dttm DESC;

### query #2  [metadata_id: 2757]
Title: Critical Exceptions Only
Description: Filtered view showing only exceptions on critical jobs — the ones that generate high-priority alerts.

SELECT 
    vl.job_sqnc_shrt_nm AS flow_code,
    vl.execution_date,
    ve.exception_type,
    ve.job_shrt_nm,
    ve.job_exctn_msg_txt
FROM JobFlow.ValidationException ve
INNER JOIN JobFlow.ValidationLog vl ON vl.validation_id = ve.validation_id
WHERE ve.is_critical = 1
ORDER BY ve.created_dttm DESC;

### query #3  [metadata_id: 2758]
Title: Exception Counts by Type
Description: Aggregated exception counts over the past 30 days by type — shows which categories of issues are most common.

SELECT 
    exception_type,
    COUNT(*) AS exception_count,
    SUM(CAST(is_critical AS INT)) AS critical_count
FROM JobFlow.ValidationException
WHERE created_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY exception_type
ORDER BY exception_count DESC;

### query #4  [metadata_id: 2759]
Title: Frequently Failing Jobs
Description: Identifies jobs with repeated FAILED exceptions over the past 30 days — pattern detection for recurring issues.

SELECT 
    job_shrt_nm,
    COUNT(*) AS failure_count,
    MAX(created_dttm) AS last_failure
FROM JobFlow.ValidationException
WHERE exception_type = 'FAILED'
  AND created_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY job_shrt_nm
ORDER BY failure_count DESC;

### relationship_note #1  [metadata_id: 2455]
Title: Child of ValidationLog
Description: FK on validation_id links exceptions to their validation summary

ValidationException.validation_id references ValidationLog.validation_id. Many exceptions per validation — one per discrepant job.

### description / actual_order_nmbr #9  [metadata_id: 856]

Actual position if job executed

### description / created_dttm #12  [metadata_id: 859]

When this exception was recorded

### description / exception_id #1  [metadata_id: 848]

Unique identifier for this exception record

### description / exception_type #6  [metadata_id: 853]

Type: MISSING, FAILED, UNEXPECTED, ORDER_MISMATCH, DUPLICATE

### status_value / exception_type #1  [metadata_id: 2456]
Title: MISSING_JOB

Job was expected from flow definition but did not execute.

### status_value / exception_type #2  [metadata_id: 2457]
Title: FAILED_JOB

Job executed but failed with zero records processed (true technical failure).

### status_value / exception_type #3  [metadata_id: 2458]
Title: UNEXPECTED_JOB

Job executed but was not in the expected job list from flow definition.

### description / expected_order_nmbr #8  [metadata_id: 855]

Expected position in flow execution order

### description / is_critical #7  [metadata_id: 854]

1 if this job is marked critical in JobConfig

### description / job_exctn_msg_txt #11  [metadata_id: 858]

Error message from DM (sanitized of PII)

### description / job_id #3  [metadata_id: 850]

Job definition ID from crs5_oltp.dbo.job

### description / job_nm #5  [metadata_id: 852]

Full job name

### description / job_shrt_nm #4  [metadata_id: 851]

Job short name

### description / job_stts_cd #10  [metadata_id: 857]

DM status code if job executed

### description / notes #13  [metadata_id: 860]

Additional context or investigation notes

### description / validation_id #2  [metadata_id: 849]

Links to parent ValidationLog record

## ValidationLog (Table)

### category #0  [metadata_id: 1713]

JobFlow

### description #0  [metadata_id: 72]

Post-execution validation results capturing job count verification, missing job detection, and Jira ticket references for completed flow executions.

### design_note #1  [metadata_id: 2445]
Title: Post-Completion Validation
Description: Runs after all jobs finish, not during execution

Validation only runs after a flow reaches COMPLETE state (executing_job_count = 0, pending_job_count = 0). It compares expected_jobs_json from FlowExecutionTracking against actual job outcomes in JobExecutionLog. Missing, unexpected, and failed jobs are counted and classified. The flow then transitions to VALIDATED.

### design_note #2  [metadata_id: 2446]
Title: Jira Integration
Description: Validation failures can generate Jira tickets

When validation detects critical failures (critical_jobs_missing = 1 or critical_jobs_failed = 1), a Jira ticket is created. The ticket key and URL are stored in jira_ticket_key and jira_ticket_url for cross-reference.

### module #0  [metadata_id: 1609]

JobFlow

### query #1  [metadata_id: 2754]
Title: Recent Validation Results
Description: Validation outcomes for the past 7 days with job count comparisons and Jira ticket references.

SELECT 
    job_sqnc_shrt_nm AS flow_code,
    execution_date,
    validation_status,
    expected_job_count,
    actual_job_count,
    missing_job_count,
    failed_job_count,
    jira_ticket_key
FROM JobFlow.ValidationLog
WHERE validation_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY validation_dttm DESC;

### query #2  [metadata_id: 2755]
Title: Failed Validations
Description: Shows validations with FAILED or PARTIAL status including critical job flags and detail JSON for investigation.

SELECT 
    job_sqnc_shrt_nm,
    execution_date,
    validation_status,
    critical_jobs_missing,
    critical_jobs_failed,
    missing_jobs_json,
    failed_jobs_json
FROM JobFlow.ValidationLog
WHERE validation_status IN ('FAILED', 'PARTIAL')
ORDER BY validation_dttm DESC;

### relationship_note #1  [metadata_id: 2447]
Title: Child of FlowExecutionTracking
Description: FK on tracking_id links validation to the flow execution

ValidationLog.tracking_id references FlowExecutionTracking.tracking_id. One validation per completed execution.

### relationship_note #2  [metadata_id: 2448]
Title: Parent of ValidationException
Description: FK on validation_id links individual exceptions to the validation summary

ValidationException.validation_id references ValidationLog.validation_id. One summary row can have many exception detail rows.

### description / actual_job_count #9  [metadata_id: 729]

Number of jobs that actually executed

### description / created_dttm #20  [metadata_id: 740]

When this validation record was created

### description / critical_jobs_failed #14  [metadata_id: 734]

1 if any failed jobs are marked is_critical in JobConfig

### description / critical_jobs_missing #13  [metadata_id: 733]

1 if any missing jobs are marked is_critical in JobConfig

### description / execution_date #5  [metadata_id: 725]

Date of the execution being validated

### description / expected_job_count #8  [metadata_id: 728]

Number of jobs expected from flow definition

### description / failed_job_count #12  [metadata_id: 732]

Jobs that executed but failed

### description / failed_jobs_json #16  [metadata_id: 736]

JSON array of failed job details with error messages

### description / jira_ticket_created_dttm #19  [metadata_id: 739]

When the Jira ticket was created

### description / jira_ticket_key #17  [metadata_id: 737]

Ticket key if validation failure generated a ticket (e.g., SD-12345)

### description / jira_ticket_url #18  [metadata_id: 738]

Full URL to the Jira ticket

### description / job_sqnc_id #3  [metadata_id: 723]

Flow ID for direct queries without join

### description / job_sqnc_shrt_nm #4  [metadata_id: 724]

Flow short name. Denormalized

### description / missing_job_count #10  [metadata_id: 730]

Jobs expected but not executed

### description / missing_jobs_json #15  [metadata_id: 735]

JSON array of missing job details

### description / tracking_id #2  [metadata_id: 722]

Links to FlowExecutionTracking for the validated execution

### description / unexpected_job_count #11  [metadata_id: 731]

Jobs executed but not in expected list

### description / validation_dttm #6  [metadata_id: 726]

When validation was performed

### description / validation_id #1  [metadata_id: 721]

Unique identifier for this validation record

### description / validation_status #7  [metadata_id: 727]

Overall result: PASSED, FAILED, WARNING, PARTIAL

### status_value / validation_status #1  [metadata_id: 2449]
Title: SUCCESS

All expected jobs executed successfully. No discrepancies found.

### status_value / validation_status #2  [metadata_id: 2450]
Title: MISSING_JOBS

Expected jobs did not execute. May indicate cancelled flow or dependency failure.

### status_value / validation_status #3  [metadata_id: 2451]
Title: FLOW_NOT_RUN

Flow was detected but no jobs executed.

### status_value / validation_status #4  [metadata_id: 2452]
Title: PARTIAL_FAILURE

Some jobs had alertable failures but non-critical.

### status_value / validation_status #5  [metadata_id: 2453]
Title: CRITICAL_FAILURE

Critical jobs failed or were missing. Jira ticket generated.

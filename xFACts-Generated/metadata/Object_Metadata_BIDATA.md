# Object_Metadata: BIDATA
Source: dbo.Object_Metadata
Generated: 2026-07-23 21:14:44

## BuildExecution (Table)

### category #0  [metadata_id: 1668]

BIDATA

### data_flow #0  [metadata_id: 1926]

Monitor-BIDATABuild.ps1 polls the configured source server's msdb.dbo.sysjobhistory over a direct PowerShell connection and writes one row per execution attempt, keyed by instance_id. Status is set to IN_PROGRESS on first detection and updated to COMPLETED or FAILED when the job outcome row appears; a NOT_STARTED row is created when the build has not started within the configured grace period. notified_dttm is stamped after the Teams notification is queued via Send-TeamsAlert. The Control Center BIDATA Monitoring page reads this table for build status and duration display.

### description #0  [metadata_id: 34]

Primary tracking table for BIDATA Daily Build executions, holding per-attempt timing, status, and notification state.

### design_note #1  [metadata_id: 1927]
Title: One Row Per Execution Attempt

Each SQL Agent execution attempt gets its own row identified by instance_id. Multiple attempts on the same day (due to failures and restarts) result in multiple rows, preserving full attempt history.

### design_note #2  [metadata_id: 1928]
Title: NOT_STARTED Detection

When no job history exists within the configured grace period after the scheduled start time, a record is created with status NOT_STARTED to trigger alerting. If the build later starts, the NOT_STARTED record is marked SUPERSEDED.

### design_note #3  [metadata_id: 1929]
Title: Instance-Based Deduplication

Notification TriggerValue includes the instance_id (e.g., COMPLETED-12345) so each execution attempt can only trigger one alert regardless of how many monitoring cycles observe the completed state.

### design_note #5  [metadata_id: 5308]
Title: Job Name Stored as Free Text

job_name is stored as free text because the SQL Agent job name has changed across design generations; Control Center history reflects all variants.

### module #0  [metadata_id: 1564]

BIDATA

### query #1  [metadata_id: 1940]
Title: Today's Build Status
Description: Daily check — shows all build records for today including status and notification state.

SELECT build_id, build_date, instance_id, start_dttm, end_dttm, 
       total_duration_formatted, status, notified_dttm
FROM BIDATA.BuildExecution
WHERE build_date = CAST(GETDATE() AS DATE)
ORDER BY build_id;

### query #2  [metadata_id: 1941]
Title: Recent Builds
Description: Shows the last 20 completed or failed builds, excluding NOT_STARTED and SUPERSEDED noise.

SELECT TOP 20 
    build_id, build_date, job_name, instance_id, start_dttm, end_dttm,
    total_duration_formatted, step_count, status
FROM BIDATA.BuildExecution
WHERE status NOT IN ('NOT_STARTED', 'SUPERSEDED')
ORDER BY build_date DESC, start_dttm DESC;

### query #3  [metadata_id: 1942]
Title: Days with Multiple Attempts
Description: Identifies dates with more than one execution attempt — indicates failures and restarts.

SELECT build_date, COUNT(*) AS attempts
FROM BIDATA.BuildExecution
WHERE status IN ('COMPLETED', 'FAILED')
GROUP BY build_date
HAVING COUNT(*) > 1
ORDER BY build_date DESC;

### query #4  [metadata_id: 1943]
Title: Failed Builds Summary
Description: Lists all failed builds with the step that caused the failure.

SELECT 
    build_date, start_dttm, total_duration_formatted,
    failed_step_id, failed_step_name
FROM BIDATA.BuildExecution
WHERE status = 'FAILED'
ORDER BY build_date DESC;

### query #5  [metadata_id: 1944]
Title: Build Duration Trend
Description: Monthly aggregation of build duration for trending analysis.

SELECT 
    CONVERT(VARCHAR(7), build_date, 120) AS month,
    COUNT(*) AS builds,
    AVG(total_duration_seconds) / 3600.0 AS avg_hours,
    MIN(total_duration_seconds) / 3600.0 AS min_hours,
    MAX(total_duration_seconds) / 3600.0 AS max_hours
FROM BIDATA.BuildExecution
WHERE status = 'COMPLETED'
GROUP BY CONVERT(VARCHAR(7), build_date, 120)
ORDER BY month;

### relationship_note #1  [metadata_id: 1945]
Title: StepExecution

Each BuildExecution record is the parent for zero to many StepExecution rows containing step-level timing. Steps are captured incrementally as they complete during the build, enabling real-time progress display on the Control Center BIDATA Monitoring page.

### description / build_date #2  [metadata_id: 139]

Date of the build

### description / build_id #1  [metadata_id: 138]

Unique identifier for this build execution

### description / created_dttm #16  [metadata_id: 153]

When this record was created

### description / end_dttm #6  [metadata_id: 143]

When the build completed

### description / failed_step_id #12  [metadata_id: 149]

Step ID that failed (if status = FAILED)

### description / failed_step_name #13  [metadata_id: 150]

Name of the failed step

### description / instance_id #4  [metadata_id: 141]

SQL Agent instance_id from sysjobhistory. NULL for NOT_STARTED records

### description / is_backfill #15  [metadata_id: 152]

Reserved and currently unused; always 0, with no code path that sets or reads it.

### description / job_name #3  [metadata_id: 140]

SQL Agent job name.

### description / notified_dttm #14  [metadata_id: 151]

When the Teams build notification was queued; NULL until notified.

### description / run_status #11  [metadata_id: 148]

SQL Agent run_status code (1=Success, 0=Failed)

### status_value / run_status #1  [metadata_id: 1936]
Title: 0

Failed. The SQL Agent job outcome indicates the build did not complete successfully.

### status_value / run_status #2  [metadata_id: 1937]
Title: 1

Succeeded. The SQL Agent job outcome indicates the build completed successfully.

### status_value / run_status #3  [metadata_id: 1938]
Title: 2

Retry. The SQL Agent job is being retried.

### status_value / run_status #4  [metadata_id: 1939]
Title: 3

Canceled. The SQL Agent job was canceled.

### description / start_dttm #5  [metadata_id: 142]

When the build started

### description / status #10  [metadata_id: 147]

Build status: COMPLETED, FAILED, IN_PROGRESS, NOT_STARTED, SUPERSEDED

### status_value / status #1  [metadata_id: 1931]
Title: IN_PROGRESS

Build is currently running. Set when first step is detected in sysjobhistory but job outcome row (step_id=0) has not appeared.

### status_value / status #2  [metadata_id: 1932]
Title: COMPLETED

Build finished successfully. Set when job outcome row shows run_status=1.

### status_value / status #3  [metadata_id: 1933]
Title: FAILED

Build encountered an error. Set when job outcome row shows run_status=0. The failed_step_id and failed_step_name columns identify the failing step.

### status_value / status #4  [metadata_id: 1934]
Title: NOT_STARTED

Build did not start within the grace period after the scheduled start time. Created by NOT_STARTED detection logic when no sysjobhistory records exist for the target date.

### status_value / status #5  [metadata_id: 1935]
Title: SUPERSEDED

A NOT_STARTED record that was replaced when the build eventually started. The original NOT_STARTED alert was already sent.

### description / step_count #9  [metadata_id: 146]

Number of steps in the build

### description / total_duration_formatted #8  [metadata_id: 145]

Runtime as HH:MM:SS string

### description / total_duration_seconds #7  [metadata_id: 144]

Total runtime in seconds

## Monitor-BIDATABuild.ps1 (Script)

### category #0  [metadata_id: 1961]

BIDATA

### data_flow #0  [metadata_id: 1962]

Runs as a queue-driven orchestrator process. Reads configuration from dbo.GlobalConfig (job name, source server, grace period), then queries the configured source server's msdb (sysjobhistory and schedule tables) over a direct PowerShell connection for job execution and schedule data. Creates and updates BIDATA.BuildExecution rows for build-level tracking and inserts BIDATA.StepExecution rows as steps complete. Calls the shared Send-TeamsAlert function to queue completion, failure, and NOT_STARTED notifications, using an instance_id-based TriggerValue for deduplication.

### description #0  [metadata_id: 1959]

Monitors the BIDATA Daily Build SQL Agent job over a direct connection to the source server, capturing build start, incremental step completions, and final status. Creates NOT_STARTED records when the build has not started within the configured grace period. Queues Teams notifications on completion, failure, and not-started conditions.

### design_note #1  [metadata_id: 1963]
Title: Direct Connection vs Linked Server

Uses direct PowerShell connection to the source server via Invoke-Sqlcmd instead of linked server queries. This eliminates the linked server dependency, enables real-time step capture during build execution, and aligns with the platform direction of unified PowerShell orchestration.

### design_note #2  [metadata_id: 1964]
Title: Incremental Step Capture

Steps are captured as they complete during the build rather than batch-queried after the build finishes. Each monitoring cycle picks up newly completed steps and inserts them into StepExecution, enabling real-time progress display on the Control Center dashboard.

### design_note #3  [metadata_id: 1965]
Title: NOT_STARTED Detection

Queries the job schedule from msdb.dbo.sysschedules to determine the expected start time. If no job history exists for the target date and the current time exceeds the scheduled start plus the configured grace period, creates a NOT_STARTED record and fires an alert. If the build later starts, the NOT_STARTED record is marked SUPERSEDED.

### design_note #4  [metadata_id: 1966]
Title: Instance-Based Deduplication

Notification TriggerValue includes the instance_id or date (e.g., COMPLETED-12345, NOT_STARTED-2026-01-29) so each build attempt or not-started condition can only trigger one alert regardless of how many monitoring cycles observe the same state.

### design_note #5  [metadata_id: 1967]
Title: Notification Step Filtering

Infrastructure steps (disable users, enable replication) and legacy notification steps are excluded from the Teams message body to keep notifications focused on actual data processing steps. These steps are still captured in StepExecution for historical completeness.

### module #0  [metadata_id: 1960]

BIDATA

### relationship_note #1  [metadata_id: 1968]
Title: BIDATA.BuildExecution

Primary write target. Creates new rows on first detection of a build attempt, updates status and timing as the build progresses, and sets notified_dttm after Teams notification is sent.

### relationship_note #2  [metadata_id: 1969]
Title: BIDATA.StepExecution

Write target for step-level data. Inserts rows incrementally as each step completes during the build, capturing step name, duration, and run_status.

### relationship_note #3  [metadata_id: 1970]
Title: dbo.GlobalConfig

Read source for configuration. Retrieves bidata_build_job_name, bidata_build_source_server, and bidata_build_start_grace_minutes at script startup.

### relationship_note #4  [metadata_id: 1971]
Title: Send-TeamsAlert

Called through the local Send-bid_BuildNotification wrapper to queue notifications on build completion (INFO), failure (CRITICAL), and not-started conditions (WARNING). Passes BuildStatus as TriggerType with the instance_id or date in TriggerValue for deduplication.

## StepExecution (Table)

### category #0  [metadata_id: 1669]

BIDATA

### data_flow #0  [metadata_id: 1946]

Monitor-BIDATABuild.ps1 captures step completions incrementally from the source server's msdb.dbo.sysjobhistory as each step finishes. Each row records the step name, duration, and run_status for one step of one build attempt. The Control Center BIDATA Monitoring page joins this table to BuildExecution for step-level progress and historical duration analysis.

### description #0  [metadata_id: 38]

Step-level execution detail for the BIDATA Daily Build, one row per SQL Agent job step per build attempt.

### design_note #1  [metadata_id: 1947]
Title: Complete Step Capture

All SQL Agent job steps are captured including infrastructure steps (disable users, enable replication) and legacy notification steps, even though some are excluded from the Teams notification message. This preserves full execution history for analysis.

### design_note #2  [metadata_id: 1948]
Title: Incremental Capture

Steps are inserted as they complete during the build rather than batch-inserted at the end. This enables real-time progress tracking on the Control Center BIDATA Monitoring dashboard.

### module #0  [metadata_id: 1565]

BIDATA

### query #1  [metadata_id: 1953]
Title: Steps for Today's Build
Description: Shows step-level progress for today's completed build.

SELECT 
    s.step_id,
    s.step_name,
    s.run_status,
    s.duration_formatted
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE b.build_date = CAST(GETDATE() AS DATE)
  AND b.status = 'COMPLETED'
ORDER BY s.step_id;

### query #2  [metadata_id: 1954]
Title: Average Step Duration (30 Days)
Description: Identifies bottleneck steps by average duration over the last 30 days.

SELECT 
    s.step_name,
    COUNT(*) AS executions,
    AVG(s.duration_seconds) AS avg_seconds,
    MIN(s.duration_seconds) AS min_seconds,
    MAX(s.duration_seconds) AS max_seconds
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE b.build_date >= DATEADD(DAY, -30, GETDATE())
  AND b.status = 'COMPLETED'
  AND s.run_status = 1
GROUP BY s.step_name
ORDER BY AVG(s.duration_seconds) DESC;

### query #3  [metadata_id: 1955]
Title: Slowest Steps (All Time)
Description: Top 10 longest individual step executions across all builds.

SELECT TOP 10
    b.build_date,
    s.step_name,
    s.duration_formatted,
    s.duration_seconds
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE s.run_status = 1
ORDER BY s.duration_seconds DESC;

### query #4  [metadata_id: 1956]
Title: Failed Steps
Description: Lists all step-level failures with build date context.

SELECT 
    b.build_date,
    s.step_id,
    s.step_name,
    s.duration_formatted
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE s.run_status = 0
ORDER BY b.build_date DESC;

### query #5  [metadata_id: 1957]
Title: Step Duration Trend
Description: Tracks a specific step's duration over time for performance trending. Replace the step_name filter with the target step.

SELECT 
    b.build_date,
    s.duration_seconds,
    s.duration_formatted
FROM BIDATA.StepExecution s
INNER JOIN BIDATA.BuildExecution b ON s.build_id = b.build_id
WHERE s.step_name = 'Build Table X'  -- Replace with actual step name
  AND s.run_status = 1
ORDER BY b.build_date;

### relationship_note #1  [metadata_id: 1958]
Title: BuildExecution

Each StepExecution row belongs to one BuildExecution record via the build_id foreign key. Step data only has meaning in the context of its parent build — the build_date, status, and instance_id come from the parent row.

### description / build_id #2  [metadata_id: 211]

Foreign key to BuildExecution

### description / duration_formatted #8  [metadata_id: 217]

Duration as HH:MM:SS string

### description / duration_seconds #7  [metadata_id: 216]

Step duration in seconds

### description / run_status #5  [metadata_id: 214]

SQL Agent run_status: 1=Success, 0=Failed

### status_value / run_status #1  [metadata_id: 1949]
Title: 0

Failed. The step encountered an error during execution.

### status_value / run_status #2  [metadata_id: 1950]
Title: 1

Succeeded. The step completed normally.

### status_value / run_status #3  [metadata_id: 1951]
Title: 2

Retry. The step is being retried by SQL Agent.

### status_value / run_status #4  [metadata_id: 1952]
Title: 3

Canceled. The step was canceled.

### description / run_time #6  [metadata_id: 215]

Raw run_time value from sysjobhistory (HHMMSS format)

### description / step_execution_id #1  [metadata_id: 210]

Unique identifier for this step execution

### description / step_id #3  [metadata_id: 212]

Step number within the job (1-based)

### description / step_name #4  [metadata_id: 213]

Name of the step from SQL Agent

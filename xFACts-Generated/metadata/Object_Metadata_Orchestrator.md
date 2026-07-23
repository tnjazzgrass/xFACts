# Object_Metadata: Orchestrator
Source: dbo.Object_Metadata
Generated: 2026-07-23 17:27:28

## CycleLog (Table)

### category #0  [metadata_id: 1714]

Orchestrator

### data_flow #0  [metadata_id: 1994]

Start-xFACtsOrchestrator.ps1 inserts a row at the beginning of each heartbeat cycle that identifies processes due for execution. Empty heartbeats (no processes due) do not create rows. The engine updates the row at cycle completion with end_dttm, duration_ms, aggregate task counts, and cycle_status. The Control Center Engine Room page queries CycleLog for engine health indicators and cycle history.

### description #0  [metadata_id: 110]

Engine heartbeat cycle log capturing one row per orchestrator cycle that found work to do. Provides aggregate metrics for cycle duration, task counts, and overall status for operational monitoring and troubleshooting.

### design_note #1  [metadata_id: 1995]
Title: Work-Only Logging

Heartbeat cycles where no processes are due do not create CycleLog entries. This avoids filling the table with empty heartbeats and keeps every row meaningful for operational monitoring.

### design_note #2  [metadata_id: 1996]
Title: Aggregate Metrics

The tasks_due, tasks_executed, tasks_succeeded, tasks_failed, and tasks_skipped columns provide a complete cycle summary without requiring joins to TaskLog. This supports quick dashboard queries and health checks without touching the much larger task-level table.

### module #0  [metadata_id: 1610]

Orchestrator

### query #1  [metadata_id: 2001]
Title: Recent Cycle History
Description: Shows the most recent engine cycles with timing and task metrics.

SELECT TOP 20
    cycle_id,
    start_dttm,
    end_dttm,
    duration_ms,
    cycle_status,
    tasks_due,
    tasks_executed,
    tasks_succeeded,
    tasks_failed,
    tasks_skipped
FROM Orchestrator.CycleLog
ORDER BY start_dttm DESC;

### query #2  [metadata_id: 2002]
Title: Failed or Partial Cycles
Description: Isolates cycles with failures for troubleshooting.

SELECT 
    cycle_id,
    start_dttm,
    cycle_status,
    tasks_failed,
    tasks_succeeded,
    error_message
FROM Orchestrator.CycleLog
WHERE cycle_status IN ('FAILED', 'PARTIAL')
ORDER BY start_dttm DESC;

### query #3  [metadata_id: 2003]
Title: Cycle Performance Trend
Description: Average cycle duration by hour over the last 7 days for performance analysis.

SELECT 
    CAST(start_dttm AS DATE) AS cycle_date,
    DATEPART(HOUR, start_dttm) AS cycle_hour,
    COUNT(*) AS cycles,
    AVG(duration_ms) AS avg_duration_ms,
    MAX(duration_ms) AS max_duration_ms,
    SUM(tasks_executed) AS total_tasks
FROM Orchestrator.CycleLog
WHERE start_dttm >= DATEADD(DAY, -7, GETDATE())
  AND cycle_status != 'RUNNING'
GROUP BY CAST(start_dttm AS DATE), DATEPART(HOUR, start_dttm)
ORDER BY cycle_date DESC, cycle_hour DESC;

### relationship_note #1  [metadata_id: 2004]
Title: TaskLog

Each CycleLog row is the parent for one or more TaskLog entries via FK_TaskLog_CycleLog. Drilling down from a cycle to its tasks shows exactly which processes ran, their individual outcomes, and any error output.

### relationship_note #2  [metadata_id: 2005]
Title: ProcessRegistry

CycleLog does not directly reference ProcessRegistry. The cycle records aggregate metrics about what happened; the individual process linkage lives in TaskLog.

### description / cycle_id #1  [metadata_id: 1283]

Unique identifier for each engine cycle

### description / cycle_status #10  [metadata_id: 1292]

Overall cycle outcome: RUNNING, SUCCESS, PARTIAL, or FAILED

### status_value / cycle_status #1  [metadata_id: 1997]
Title: RUNNING

Cycle is currently executing tasks. Set on initial insert.

### status_value / cycle_status #2  [metadata_id: 1998]
Title: SUCCESS

All tasks in the cycle completed successfully (tasks_failed = 0).

### status_value / cycle_status #3  [metadata_id: 1999]
Title: PARTIAL

Some tasks succeeded and some failed within the same cycle.

### status_value / cycle_status #4  [metadata_id: 2000]
Title: FAILED

Engine-level error prevented normal task execution. Individual task failures produce PARTIAL, not FAILED.

### description / duration_ms #4  [metadata_id: 1286]

Total cycle duration in milliseconds. Calculated at completion

### description / end_dttm #3  [metadata_id: 1285]

When the cycle completed. NULL while cycle is running

### description / error_message #11  [metadata_id: 1293]

Engine-level error message if the cycle itself failed (not individual task errors)

### description / start_dttm #2  [metadata_id: 1284]

When the cycle began

### description / tasks_due #5  [metadata_id: 1287]

Number of processes identified as due at the start of the cycle

### description / tasks_executed #6  [metadata_id: 1288]

Number of processes the engine attempted to launch

### description / tasks_failed #8  [metadata_id: 1290]

Number of tasks that completed with FAILED or TIMEOUT status

### description / tasks_skipped #9  [metadata_id: 1291]

Number of processes that were due but skipped (e.g., still running from a previous cycle)

### description / tasks_succeeded #7  [metadata_id: 1289]

Number of tasks that completed with SUCCESS status

## ProcessRegistry (Table)

### category #0  [metadata_id: 1715]

Orchestrator

### data_flow #0  [metadata_id: 1972]

Rows are manually inserted when onboarding a new process to the orchestrator. Start-xFACtsOrchestrator.ps1 queries ProcessRegistry each heartbeat cycle to identify due processes based on run_mode, interval_seconds, scheduled_time, and running_count. After launching a process, the engine updates last_execution_dttm and increments running_count. On completion, either the engine (WAIT mode) or the Complete-OrchestratorTask callback (FIRE_AND_FORGET mode) updates last_execution_status, last_duration_ms, last_successful_date, and decrements running_count. Queue table INSERT triggers (e.g., TR_Teams_AlertQueue_QueueDepth, TR_Jira_TicketQueue_QueueDepth) increment running_count for queue-driven processes. The Control Center Engine Room page displays process status and scheduling information.

### description #0  [metadata_id: 40]

Configuration hub for all orchestrated processes. Defines scheduling, execution mode, dependency ordering, and tracks runtime status for each process managed by the Orchestrator v2 engine.

### design_note #1  [metadata_id: 1973]
Title: Dual Execution Targets

Each process populates either script_path (PowerShell launched as external process) or procedure_name (stored procedure via Invoke-Sqlcmd). CK_ProcessRegistry_execution_target ensures at least one is populated. This allows the engine to handle both execution styles without separate configuration tables.

### design_note #2  [metadata_id: 1974]
Title: Configuration and Live Status Combined

ProcessRegistry serves as both configuration table and runtime status tracker. The engine updates last_execution_dttm, last_execution_status, last_duration_ms, and running_count directly in the config row. This eliminates the need for a separate status table and ensures the engine always sees current state in a single query.

### design_note #3  [metadata_id: 1975]
Title: Three Scheduling Models

run_mode controls scheduling behavior: 0 = Disabled (never executes), 1 = Scheduled (interval-based when scheduled_time is NULL, time-based when scheduled_time is populated), 2 = Queue-driven (executes when running_count > 0, set by external triggers). Time-based processes use last_successful_date to prevent duplicate runs on the same day.

### design_note #4  [metadata_id: 1976]
Title: Running Count Semantics

running_count has different meanings by run_mode. For scheduled processes (run_mode=1), it tracks active instances to prevent overlap. For queue-driven processes (run_mode=2), it represents pending items to process — incremented by queue INSERT triggers and decremented by the processor script. Floor protection prevents the count from going below zero in case of mismatched decrements.

### module #0  [metadata_id: 1611]

Orchestrator

### query #1  [metadata_id: 1988]
Title: All Registered Processes with Schedule
Description: Complete process inventory showing execution targets, scheduling configuration, and current runtime status.

SELECT 
    process_id,
    module_name,
    process_name,
    COALESCE(script_path, procedure_name) AS execution_target,
    execution_mode,
    dependency_group,
    CASE run_mode
        WHEN 0 THEN 'Disabled'
        WHEN 1 THEN CASE 
            WHEN scheduled_time IS NOT NULL 
                THEN 'Daily @ ' + CAST(scheduled_time AS VARCHAR(5))
            ELSE CAST(interval_seconds AS VARCHAR) + 's interval'
        END
        WHEN 2 THEN 'Queue-driven'
    END AS schedule_desc,
    running_count,
    last_execution_status,
    last_execution_dttm,
    last_duration_ms
FROM Orchestrator.ProcessRegistry
ORDER BY run_mode, dependency_group, process_name;

### query #2  [metadata_id: 1989]
Title: Process Health Summary
Description: Prioritizes failed and timed-out processes for quick triage.

SELECT 
    module_name,
    process_name,
    run_mode,
    running_count,
    last_execution_status,
    last_execution_dttm,
    DATEDIFF(MINUTE, last_execution_dttm, GETDATE()) AS minutes_ago,
    last_duration_ms
FROM Orchestrator.ProcessRegistry
ORDER BY 
    CASE WHEN last_execution_status = 'FAILED' THEN 0 
         WHEN last_execution_status = 'TIMEOUT' THEN 1
         ELSE 2 END,
    module_name, process_name;

### query #3  [metadata_id: 1990]
Title: Queue-Driven Processes with Pending Work
Description: Shows queue-driven processes that have items waiting to be processed.

SELECT 
    process_name,
    module_name,
    running_count AS pending_items,
    last_execution_dttm,
    last_execution_status
FROM Orchestrator.ProcessRegistry
WHERE run_mode = 2
  AND running_count > 0
ORDER BY process_name;

### relationship_note #1  [metadata_id: 1991]
Title: CycleLog

Each engine heartbeat cycle that finds due processes creates a CycleLog row. ProcessRegistry is queried to determine which processes are due, but there is no direct foreign key — CycleLog captures aggregate metrics per cycle rather than linking to specific processes.

### relationship_note #2  [metadata_id: 1992]
Title: TaskLog

Every process execution creates a TaskLog row with FK_TaskLog_ProcessRegistry pointing back to the process_id. TaskLog denormalizes module_name, process_name, dependency_group, and execution_target at execution time so historical records remain accurate even if ProcessRegistry changes.

### relationship_note #3  [metadata_id: 1993]
Title: Queue Table Triggers

Queue-driven processes (run_mode=2) are triggered by INSERT triggers on their respective queue tables. TR_Teams_AlertQueue_QueueDepth and TR_Jira_TicketQueue_QueueDepth increment running_count when new items are queued, causing the engine to launch the processor on the next heartbeat.

### description / allow_concurrent #14  [metadata_id: 241]

When enabled, the engine launches new instances even when running_count > 0. Used for processes with batch claiming logic where multiple instances safely process different content

### description / cc_engine_label #20  [metadata_id: 5075]

Text shown in the engine card's label span on the Control Center page. The HTML populator validates each card's rendered label against this column. Required for active scheduled processes (run_mode = 1); NULL for queue processors (run_mode = 2) and inactive processes (run_mode = 0).

### description / cc_engine_slug #19  [metadata_id: 5074]

Short slug used in engine card DOM IDs on the Control Center page that displays this process. The slug forms part of three IDs per card: card-engine-<slug>, engine-bar-<slug>, and engine-cd-<slug>. Required for active scheduled processes (run_mode = 1); NULL for queue processors (run_mode = 2) and inactive processes (run_mode = 0). The HTML populator validates each engine card's slug against this column.

### description / cc_page_route #21  [metadata_id: 5076]

Control Center page route on which this process appears as an engine card. The HTML populator validates engine card placement against this column, emitting ENGINE_CARD_PAGE_MISMATCH when a card appears on a page whose route does not match. Required for active scheduled processes (run_mode = 1); NULL for queue processors (run_mode = 2) and inactive processes (run_mode = 0).

### description / cc_sort_order #22  [metadata_id: 5077]

Display order of this process's engine card within the page's engine row, ascending. Lower values render first (leftmost). The HTML populator validates declaration order against this column, emitting ENGINE_CARD_ORDER_MISMATCH when cards are emitted out of registry order. Required for active scheduled processes (run_mode = 1); NULL for queue processors (run_mode = 2) and inactive processes (run_mode = 0).

### description / created_by #24  [metadata_id: 247]

Who created the record

### description / created_dttm #23  [metadata_id: 246]

When the record was created

### description / dependency_group #8  [metadata_id: 235]

Numeric group controlling execution order. Lower groups execute first

### description / description #4  [metadata_id: 231]

Human-readable description of what the process does

### description / execution_mode #7  [metadata_id: 234]

How the engine handles process execution. WAIT or FIRE_AND_FORGET

### status_value / execution_mode #4  [metadata_id: 1980]
Title: WAIT

Engine launches the process and waits for completion, capturing stdout/stderr and exit code directly.

### status_value / execution_mode #5  [metadata_id: 1981]
Title: FIRE_AND_FORGET

Engine launches the process in the background and moves on. The process reports completion via the Complete-OrchestratorTask callback.

### description / interval_seconds #9  [metadata_id: 236]

Seconds between executions for interval-based scheduling. Ignored for queue-driven processes

### description / last_duration_ms #17  [metadata_id: 244]

Duration of the most recent execution in milliseconds

### description / last_execution_dttm #15  [metadata_id: 242]

When the process was last launched. Used by interval-based scheduling to determine if due

### description / last_execution_status #16  [metadata_id: 243]

Result of the most recent execution: SUCCESS, FAILED, RUNNING, or TIMEOUT

### status_value / last_execution_status #6  [metadata_id: 1982]
Title: SUCCESS

Most recent execution completed successfully.

### status_value / last_execution_status #7  [metadata_id: 1983]
Title: FAILED

Most recent execution completed with errors.

### status_value / last_execution_status #8  [metadata_id: 1984]
Title: RUNNING

Process is currently executing.

### status_value / last_execution_status #9  [metadata_id: 1985]
Title: TIMEOUT

Process exceeded its timeout_seconds threshold without completing.

### status_value / last_execution_status #10  [metadata_id: 1986]
Title: NOT_STARTED

Process has been registered but has not yet executed.

### status_value / last_execution_status #11  [metadata_id: 1987]
Title: POLLING

Process completed a cycle but reported no actionable work — used by collectors that found nothing new to process.

### description / last_successful_date #18  [metadata_id: 245]

Date of last successful execution. Used by time-based scheduling to prevent duplicate runs on the same day

### description / modified_by #26  [metadata_id: 249]

Who last modified the record

### description / modified_dttm #25  [metadata_id: 248]

When the record was last modified

### description / module_name #2  [metadata_id: 229]

Functional module the process belongs to (e.g., ServerOps, JobFlow, Jira)

### description / procedure_name #6  [metadata_id: 233]

Schema-qualified stored procedure name. Populated for SP-based processes

### description / process_id #1  [metadata_id: 228]

Unique identifier for each process configuration

### description / process_name #3  [metadata_id: 230]

Logical name for this process (e.g., Collect-ServerHealth, Monitor-JobFlow)

### description / run_mode #12  [metadata_id: 239]

How the process is scheduled: 0 = Disabled, 1 = Scheduled (interval/time-based), 2 = Queue-driven (triggered by running_count > 0)

### status_value / run_mode #1  [metadata_id: 1977]
Title: 0

Disabled — process is not executed by the engine.

### status_value / run_mode #2  [metadata_id: 1978]
Title: 1

Scheduled — process uses interval-based or time-based scheduling.

### status_value / run_mode #3  [metadata_id: 1979]
Title: 2

Queue-driven — process executes when running_count > 0, triggered by external queue INSERT triggers.

### description / running_count #13  [metadata_id: 240]

For scheduled processes: number of currently active instances. For queue-driven processes: number of pending items to process. Incremented before launch (scheduled) or by queue triggers (queue-driven), decremented/reset on completion

### description / scheduled_time #10  [metadata_id: 237]

Daily execution time for time-based scheduling. When populated, interval_seconds is ignored. Not used for queue-driven processes

### description / script_path #5  [metadata_id: 232]

Full path to PowerShell script. Populated for script-based processes

### description / timeout_seconds #11  [metadata_id: 238]

Maximum expected duration in seconds. NULL disables timeout monitoring

## Start-xFACtsOrchestrator.ps1 (Script)

### category #0  [metadata_id: 2023]

Orchestrator

### data_flow #0  [metadata_id: 2024]

Runs as the xFACtsOrchestrator NSSM Windows service on FA-SQLDBB. Reads heartbeat_interval_seconds and orchestrator_drain_mode from dbo.GlobalConfig. Each heartbeat cycle queries Orchestrator.ProcessRegistry to identify due processes. Inserts a CycleLog row per cycle and a TaskLog row per process launch. For WAIT mode processes, captures stdout/stderr and updates TaskLog and ProcessRegistry on completion. For FIRE_AND_FORGET processes, records LAUNCHED status and moves on. Sends CRITICAL Teams alerts directly to Teams.AlertQueue for WAIT mode timeout events.

### description #0  [metadata_id: 2021]

NSSM-hosted orchestrator engine providing heartbeat-driven process scheduling with dependency group execution, timeout enforcement, and drain mode support.

### design_note #1  [metadata_id: 2025]
Title: Dependency Group Execution

Processes are organized into numbered dependency groups. Groups execute sequentially (all processes in group 10 complete before group 20 starts). Within a group, processes currently execute sequentially. Queue-driven processes are evaluated separately after all scheduled groups complete.

### design_note #2  [metadata_id: 2026]
Title: Drain Mode

When orchestrator_drain_mode is set to 1 in GlobalConfig, the engine skips new process launches but allows in-flight processes to complete naturally. A WARNING Teams alert fires once per engine startup if drain mode is active. Used for controlled maintenance shutdowns.

### design_note #3  [metadata_id: 2027]
Title: WAIT Mode Timeout Enforcement

WAIT mode processes have their timeout_seconds enforced by the engine. If a process exceeds its timeout, the engine kills the process, sets TIMEOUT status in TaskLog and ProcessRegistry, and queues a CRITICAL Teams alert directly via INSERT to Teams.AlertQueue with Orchestrator_Timeout trigger type.

### module #0  [metadata_id: 2022]

Orchestrator

### relationship_note #1  [metadata_id: 2028]
Title: ProcessRegistry

Reads process configuration and scheduling data each heartbeat. Updates runtime status fields (running_count, last_execution_dttm, last_execution_status, last_duration_ms) for WAIT mode processes.

### relationship_note #2  [metadata_id: 2029]
Title: CycleLog

Creates one row per heartbeat cycle that finds due processes. Updates with aggregate metrics and final status at cycle completion.

### relationship_note #3  [metadata_id: 2030]
Title: TaskLog

Creates one row per process launch within a cycle. Updates with final results for WAIT mode processes. FIRE_AND_FORGET task rows are updated by the process callback instead.

### relationship_note #4  [metadata_id: 2031]
Title: xFACts-OrchestratorFunctions.ps1

Companion function library dot-sourced by managed scripts. Provides the Complete-OrchestratorTask callback that FIRE_AND_FORGET processes use to report completion back to TaskLog and ProcessRegistry.

## TaskLog (Table)

### category #0  [metadata_id: 1716]

Orchestrator

### data_flow #0  [metadata_id: 2006]

Start-xFACtsOrchestrator.ps1 inserts a row when launching each process within a cycle, capturing denormalized process identification and setting task_status to RUNNING (WAIT mode) or transitioning through RUNNING to LAUNCHED (FIRE_AND_FORGET mode). For WAIT mode, the engine updates the row upon process completion with end_dttm, duration_ms, task_status, exit_code, output_summary, and error_output. For FIRE_AND_FORGET mode, the Complete-OrchestratorTask callback in xFACts-OrchestratorFunctions.ps1 performs the update. The Control Center Engine Room page queries TaskLog for per-process execution history and troubleshooting detail.

### description #0  [metadata_id: 116]

Per-process execution log capturing individual task results within each engine cycle. Records timing, status, exit codes, and output/error content for every process execution, providing granular troubleshooting detail beneath the cycle-level [Orchestrator - CycleLog].

### design_note #1  [metadata_id: 2007]
Title: Denormalized Process Context

TaskLog stores module_name, process_name, dependency_group, and execution_target at execution time even though it has FK_TaskLog_ProcessRegistry. If a process is later renamed, reconfigured, or removed, historical log entries remain accurate and self-contained.

### design_note #2  [metadata_id: 2008]
Title: Two Update Patterns

WAIT mode tasks are updated by the engine after process exit. FIRE_AND_FORGET tasks are updated by the process itself via the Complete-OrchestratorTask callback. Both patterns converge on the same final state — the task row always ends with a terminal status, timing data, and any output or error content.

### design_note #3  [metadata_id: 2009]
Title: Output Truncation

output_summary and error_output are VARCHAR(MAX) but the callback function truncates content to 4000 characters before insertion. This prevents extremely verbose script output from consuming excessive storage while preserving enough detail for troubleshooting.

### module #0  [metadata_id: 1612]

Orchestrator

### query #1  [metadata_id: 2015]
Title: Recent Task History
Description: Shows the most recent task executions across all processes.

SELECT TOP 50
    t.task_id,
    t.cycle_id,
    t.module_name,
    t.process_name,
    t.execution_mode,
    t.task_status,
    t.start_dttm,
    t.duration_ms,
    t.exit_code
FROM Orchestrator.TaskLog t
ORDER BY t.start_dttm DESC;

### query #2  [metadata_id: 2016]
Title: Failed Tasks with Error Detail
Description: Isolates failed and timed-out tasks with error output for troubleshooting.

SELECT 
    t.task_id,
    t.process_name,
    t.module_name,
    t.task_status,
    t.start_dttm,
    t.exit_code,
    t.error_output,
    LEFT(t.output_summary, 500) AS output_preview
FROM Orchestrator.TaskLog t
WHERE t.task_status IN ('FAILED', 'TIMEOUT')
ORDER BY t.start_dttm DESC;

### query #3  [metadata_id: 2017]
Title: Execution History for a Specific Process
Description: Last 20 executions of a named process with timing and status.

SELECT TOP 20
    t.task_id,
    t.cycle_id,
    t.task_status,
    t.start_dttm,
    t.end_dttm,
    t.duration_ms,
    t.exit_code
FROM Orchestrator.TaskLog t
INNER JOIN Orchestrator.ProcessRegistry p ON t.process_id = p.process_id
WHERE p.process_name = 'Process-Name-Here'
ORDER BY t.start_dttm DESC;

### query #4  [metadata_id: 2018]
Title: Drill Down to Tasks for a Specific Cycle
Description: Shows all tasks within a given engine cycle ordered by dependency group and start time.

SELECT 
    t.task_id,
    t.process_name,
    t.dependency_group,
    t.execution_mode,
    t.task_status,
    t.duration_ms,
    t.exit_code,
    t.error_output
FROM Orchestrator.TaskLog t
WHERE t.cycle_id = @cycle_id
ORDER BY t.dependency_group, t.start_dttm;

### relationship_note #1  [metadata_id: 2019]
Title: CycleLog

Each task belongs to exactly one engine cycle via FK_TaskLog_CycleLog. The parent CycleLog row provides aggregate cycle-level metrics; TaskLog provides the per-process detail within that cycle.

### relationship_note #2  [metadata_id: 2020]
Title: ProcessRegistry

FK_TaskLog_ProcessRegistry links each task to its process configuration. However, TaskLog denormalizes key process fields at execution time, so the FK is primarily for joins rather than data integrity — historical accuracy is preserved in the denormalized columns.

### description / cycle_id #2  [metadata_id: 1347]

FK to [Orchestrator - CycleLog]. Links this task to the engine cycle that launched it

### description / dependency_group #6  [metadata_id: 1351]

Dependency group captured at execution time

### description / duration_ms #11  [metadata_id: 1356]

Task duration in milliseconds. Calculated at completion

### description / end_dttm #10  [metadata_id: 1355]

When the task completed. NULL while running or for LAUNCHED tasks awaiting callback

### description / error_output #15  [metadata_id: 1360]

Captured stderr from the process

### description / execution_mode #7  [metadata_id: 1352]

Execution mode used: WAIT or FIRE_AND_FORGET

### description / execution_target #8  [metadata_id: 1353]

Actual script path or procedure name that was executed

### description / exit_code #13  [metadata_id: 1358]

Process exit code (0 = success for PowerShell scripts). NULL for FIRE_AND_FORGET until callback

### description / module_name #4  [metadata_id: 1349]

Module name captured at execution time

### description / output_summary #14  [metadata_id: 1359]

Captured stdout from the process, truncated to 4000 characters

### description / process_id #3  [metadata_id: 1348]

FK to [Orchestrator - ProcessRegistry]. Links to the process configuration

### description / process_name #5  [metadata_id: 1350]

Process name captured at execution time

### description / start_dttm #9  [metadata_id: 1354]

When the task execution began

### description / task_id #1  [metadata_id: 1346]

Unique identifier for each task execution

### description / task_status #12  [metadata_id: 1357]

Current task state: RUNNING, SUCCESS, FAILED, TIMEOUT, or LAUNCHED

### status_value / task_status #1  [metadata_id: 2010]
Title: RUNNING

Task has been launched and is actively executing. Initial status for WAIT mode tasks.

### status_value / task_status #2  [metadata_id: 2011]
Title: LAUNCHED

FIRE_AND_FORGET task has been started in the background. Awaiting callback from the process.

### status_value / task_status #3  [metadata_id: 2012]
Title: SUCCESS

Task completed successfully (exit code 0 for scripts). Terminal state.

### status_value / task_status #4  [metadata_id: 2013]
Title: FAILED

Task completed with a non-zero exit code or threw an error. Terminal state.

### status_value / task_status #5  [metadata_id: 2014]
Title: TIMEOUT

Task exceeded its timeout_seconds threshold without completing. Engine kills the process and sets this status.

## xFACts-OrchestratorFunctions.ps1 (Script)

### category #0  [metadata_id: 2034]

Orchestrator

### data_flow #0  [metadata_id: 2035]

Dot-sourced by all xFACts PowerShell scripts at startup. Provides Initialize-XFActsScript for standardized SQL module loading, logging setup, and application identity tagging. The Complete-OrchestratorTask function updates Orchestrator.TaskLog (end_dttm, duration_ms, task_status, exit_code, output_summary, error_output) and Orchestrator.ProcessRegistry (running_count decrement, last_execution_status, last_duration_ms, last_successful_date). Also sends PROCESS_COMPLETED WebSocket events to the Control Center for real-time engine health indicator updates.

### description #0  [metadata_id: 2032]

PowerShell function library providing shared script infrastructure and task completion callback capabilities for scripts running under the Orchestrator v2 engine.

### design_note #1  [metadata_id: 2036]
Title: Fail-Safe Callback

Complete-OrchestratorTask catches all exceptions internally and writes a warning instead of throwing. A callback failure should not crash the calling script — the actual work was already done successfully.

### design_note #2  [metadata_id: 2037]
Title: Dot-Sourcing Pattern

Functions are loaded via dot-sourcing rather than a PowerShell module. This matches the pattern used by xFACts-IndexFunctions.ps1 and simplifies deployment — no module registration or path configuration required.

### design_note #3  [metadata_id: 2038]
Title: Running Count Floor Protection

The callback decrements running_count rather than setting it to zero, supporting concurrent execution scenarios. A CASE expression ensures running_count never goes below zero in case of mismatched decrements from race conditions or manual intervention.

### design_note #4  [metadata_id: 2039]
Title: Real-Time Engine Events

After updating database tables, Send-EngineEvent posts a PROCESS_COMPLETED event with scheduling metadata (interval_seconds, scheduled_time, run_mode) to the Control Center WebSocket endpoint. This enables live countdown timer updates on the Engine Room page without polling.

### module #0  [metadata_id: 2033]

Orchestrator

### relationship_note #1  [metadata_id: 2040]
Title: TaskLog

Complete-OrchestratorTask updates TaskLog with final execution results including timing, status, exit code, and captured output. This is the FIRE_AND_FORGET counterpart to the engine's direct WAIT mode updates.

### relationship_note #2  [metadata_id: 2041]
Title: ProcessRegistry

Complete-OrchestratorTask decrements running_count and updates last_execution_status, last_duration_ms, and last_successful_date on the process's ProcessRegistry row.

### relationship_note #3  [metadata_id: 2042]
Title: Start-xFACtsOrchestrator.ps1

The engine script passes TaskId and ProcessId parameters when launching FIRE_AND_FORGET processes. These IDs enable the callback function to update the correct TaskLog and ProcessRegistry rows.

### relationship_note #4  [metadata_id: 2043]
Title: xFACts-IndexFunctions.ps1

Uses the same dot-sourcing deployment pattern for shared function libraries. Both are loaded by their respective calling scripts via dot-source at the top of the file.

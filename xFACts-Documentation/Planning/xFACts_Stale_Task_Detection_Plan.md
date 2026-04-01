# xFACts Stale Task Detection and Startup Recovery

## Background

FIRE_AND_FORGET processes that hang or are killed (e.g., by a server reboot) remain in LAUNCHED/RUNNING status indefinitely in TaskLog. The `running_count` on ProcessRegistry stays at 1, which blocks the orchestrator from launching subsequent runs. This creates a silent failure — the process simply stops running with no alert, no error, and no indication until someone manually notices the data is stale.

### Known Incidents

- **2026-03-04:** Server reboot during Collect-ReplicationHealth execution. Task 90791 stuck in RUNNING, CycleLog 45409 stuck in RUNNING, running_count = 1. Replication monitoring went dark for ~16 hours until manually discovered and cleaned up.
- **Previous (undated):** Collect-XEEvents hung at 3:08 AM and silently blocked the orchestrator until manually found hours later.

## Requirements

### Component 1: Startup Recovery

**Trigger:** Orchestrator service start (in `Start-xFACtsOrchestrator.ps1` initialization, before the main loop begins).

**Behavior:**
1. Query TaskLog for any tasks in LAUNCHED or RUNNING status with no `end_dttm`
2. For each orphaned task:
   - Update TaskLog: set `task_status = 'FAILED'`, `end_dttm = GETDATE()`, calculate `duration_ms`, set `error_output = 'Orphaned task detected on orchestrator startup — process was likely terminated by a service stop or server reboot'`
   - Update ProcessRegistry: reset `running_count` to 0 for the affected `process_id`
3. Query CycleLog for any cycles in RUNNING status with no `end_dttm`
4. For each orphaned cycle:
   - Update CycleLog: set `cycle_status = 'FAILED'`, `end_dttm = GETDATE()`, calculate `duration_ms`, set `error_message = 'Orphaned cycle detected on orchestrator startup'`
5. If any orphaned tasks were found, send a single Teams alert summarizing what was cleaned up (process names, how long they were stuck)
6. Log the cleanup to the orchestrator log file

**Design considerations:**
- This runs once at startup, before the first cycle. It's not a recurring check.
- The alert should be informational, not critical — the recovery is automatic. But it's important to know it happened so the team can verify data continuity.
- Multiple tasks could be orphaned from the same cycle (if the reboot happened mid-cycle with parallel or sequential tasks in flight).

### Component 2: Heartbeat Stale Task Detection

**Trigger:** Runs on every orchestrator cycle (or every N cycles) as part of the main loop.

**Behavior:**
1. Query TaskLog for tasks in LAUNCHED or RUNNING status where elapsed time exceeds the `timeout_seconds` defined in ProcessRegistry for that process
2. For each stale task:
   - Update TaskLog: set `task_status = 'TIMEOUT'`, `end_dttm = GETDATE()`, calculate `duration_ms`, set `error_output = 'Task exceeded timeout_seconds threshold — marked as timed out by stale task detection'`
   - Update ProcessRegistry: reset `running_count` to 0
3. Send a Teams alert per stale task (or a consolidated alert if multiple are found in the same check). This should be a WARNING-level alert — a timeout is more concerning than a reboot cleanup.
4. Log to the orchestrator log file

**Design considerations:**
- Only applies to FIRE_AND_FORGET tasks. WAIT-mode tasks are managed directly by the orchestrator and have their own timeout handling.
- The check should use `timeout_seconds` from ProcessRegistry as the threshold. If `timeout_seconds` is NULL for a process, use a default (e.g., 600 seconds / 10 minutes).
- Consider adding a grace period beyond `timeout_seconds` before declaring a task stale, to avoid false positives when a process legitimately runs slightly longer than expected. Maybe `timeout_seconds * 1.5` or `timeout_seconds + 60`.
- The check should be lightweight — a single query per cycle, not per-process.

### Component 3: Alert Content

**Startup Recovery Alert:**
- Title: "Orchestrator Startup Recovery"
- Body: List of cleaned-up tasks with process name, original start time, and how long they were stuck
- Severity: INFO
- Destination: Standard operational alert channel

**Stale Task Alert:**
- Title: "Stale Task Detected: [ProcessName]"
- Body: Process name, start time, elapsed time, timeout threshold, action taken (marked as TIMEOUT, running_count reset)
- Severity: WARNING
- Destination: Standard operational alert channel

## Implementation Notes

- Startup recovery should be implemented first — it's simpler, directly prevents the reboot scenario, and provides immediate value.
- Heartbeat detection is the more complex piece and can follow once startup recovery is proven.
- Both components write to TaskLog/CycleLog/ProcessRegistry — they should use the same connection pattern as the orchestrator's main loop.
- The startup recovery query and the heartbeat query are nearly identical — the difference is the threshold (any orphan vs. exceeded timeout).
- Consider whether the heartbeat check should also clean up orphaned CycleLog entries or just TaskLog. An orphaned cycle with no orphaned tasks is unlikely but possible if the cycle row was written but tasks hadn't started yet.

## Relationship to Backlog

This document expands on the existing backlog item:
- **Orchestrator Module > Stale FIRE_AND_FORGET task detection** (High priority)

The backlog item can be updated to reference this document and split into two sub-items (Startup Recovery and Heartbeat Detection).

## Decision Log

| Date | Decision |
|------|----------|
| 2026-03-05 | Requirements captured after Replication Monitoring outage caused by server reboot orphaning a running task |
| 2026-03-05 | Two-component approach: startup recovery (immediate, automatic) + heartbeat detection (recurring, timeout-based) |
| 2026-03-05 | Startup recovery to be implemented first |

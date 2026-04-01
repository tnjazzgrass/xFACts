# DBCC Operations — Session Carry-Forward Items
**Session Date:** March 22, 2026
**Status:** Items to carry into next session(s)

---

## Completed This Session

### CHECKCATALOG AG Secondary Fix
CHECKCATALOG now always routes to PRIMARY on AG listener databases. Confirmed working — crs5_oltp CHECKCATALOG ran successfully on primary with full metrics captured including buffer pool scan (10 seconds, 66.8M scanned buffers).

### Replica Override Infrastructure
- `replica_override` column added to DBCC_ScheduleConfig (VARCHAR(10), CHECK constraint: PRIMARY/SECONDARY/NULL)
- Execute-DBCC.ps1 connection routing reads replica_override per database, CHECKCATALOG hardcoded to PRIMARY
- Connection cache keyed by server+replica for split routing (different operations can route to different replicas)
- Removed skippedServers mechanism (per-operation routing replaces blanket server skip)
- API endpoint POST `/api/dbcc/schedule/replica-override` for setting/clearing overrides
- Schedule and schedule-detail GET endpoints return `replica_override` and `server_type`
- CC page: segmented button control (Default/Primary/Secondary) in edit modal for AG listener databases only
- CC page: ⚠ badge with override count on schedule server rows, ⚠ icon per database in detail modal

### DBCC Metric Capture from Error Log
- Metrics (elapsed time, LSN, error counts, buffer pool stats) now extracted from SQL Server error log via xp_readerrorlog after each DBCC operation completes
- NO_INFOMSGS stays in the DBCC command — error log is the capture source
- New `dbcc_summary_output` VARCHAR(2000) column captures raw DBCC summary text as permanent record (error logs cycle nightly)
- PHYSICAL_ONLY output format parsing: "found X errors and repaired Y errors" (vs FULL's "allocation errors and consistency errors")
- Error log query uses exact database name match with parentheses to prevent substring collisions (e.g., ETLAP vs ETLAP_Hangfire)
- Buffer pool scan metrics only appear for large databases where the scan is significant enough for SQL Server to log
- Backfill script created and run for today's executions (yesterday's error logs had already cycled)

### Execution History Redesign
- Redesigned to match JobFlow pattern: year card with large blue label, month summary table, day rows with expand arrows
- No failure coloring on accordion levels (year/month cards are neutral)
- All levels load collapsed; each drill-down opens only the next level
- Day detail: columns reordered (Operation, Server, Database, Started, Completed, Duration, Status), sorted most recent first
- Expandable detail rows for both errors (red) AND successful operations with summary output (neutral)

### ERRORS_FOUND Visual Distinction
- ERRORS_FOUND now uses amber/yellow (#dcdcaa) instead of red — visually distinct from FAILED
- ERRORS_FOUND counts toward "succeeded" in history rollups (execution completed successfully)
- New "Warnings" column added at year, month, and day levels in execution history
- Year stats format: "52 executions · 50 succeeded · 1 warning · 1 failed"

### CC Page Cosmetic Updates
- Live progress running card: Option B layout — operation badge + database name header, check mode + MAXDOP subtitle
- "Running on" label changed to "Target"
- Last activity idle card: redesigned with labeled metric stats (Server, Completed, Duration), operation badge + database name, subtle teal tint for SUCCESS
- "Last Activity" label added above idle card for clarity
- Pending queue: converted from slideout to centered modal, onclick wired to button
- Today's Executions refresh badge: changed from ⚡ event to ● live polling

### Other Fixes
- Fixed trailing backslash on executed_on_server for non-AG servers (DBNull check for instance_name)
- Fixed Index Maintenance slideout display (migrated from .visible to .open class, removed duplicate CSS)
- Added .auto-height slideout variant to shared engine-events.css

### Tools.Utilities Component
- sp_SyncColumnOrdinals refactored: supports single table, schema, or full database scope
- Object_Metadata enrichment (10 rows: baselines, parameters, design notes, relationship note)
- System_Metadata v2.0.0 baseline
- Full database ordinal sync run — all tables aligned, 9 missing column descriptions added

---

## Known Issues to Fix

### Orchestrator Interval-from-Completion Drift
The ProcessRegistry countdown calculates from last completion time + interval_seconds, not from a fixed schedule anchor. This caused the 10 AM CHECKDB run to drift to ~9:54 because the prior run completed at 8:54. The countdown on the engine card also doesn't update when last_execution_dttm is manually adjusted — it requires a new WebSocket event or page reload. This is an Orchestrator-level architecture issue affecting all interval-based processes, not DBCC-specific.

---

## CC Page Refinements (Next Session)

### Remove Last Activity Card
Last activity display in Live Progress section is redundant with Today's Executions, Execution History, and engine cards. Remove it — show clean idle state when nothing is running.

### Check Mode at Database Level
Move check_mode (PHYSICAL_ONLY/FULL) from GlobalConfig to DBCC_ScheduleConfig as a per-database column. Enables mixed configurations — e.g., crs5_oltp runs FULL monthly while smaller databases stay PHYSICAL_ONLY. Needs: new column on ScheduleConfig, script change to read per-database instead of GlobalConfig, edit modal update to include check mode selector.

### Today's Executions — Future Metric Columns
The grid has room for additional columns. After several runs with the expanded DBCC metric capture, evaluate which metrics are worth displaying inline (e.g., allocation_errors, consistency_errors, dbcc_elapsed_seconds, pages_scanned). Deferred until we have real data to assess.

### Schedule Section — Calendar Icon Edit Flow
Calendar icon per database is implemented and functional. Future refinements may include:
- Bulk schedule changes (set all databases on a server to the same time)
- Visual indication of which databases have upcoming operations today
- Schedule conflict detection (overlapping heavy operations)

### General Cosmetic Polish
Minor visual tweaks still needed across all sections. Dirk wants to work with the page for a while before finalizing the look. Specific items TBD.

---

## Documentation (Next Session)

### Architecture Page (dbcc-arch.html) — Second Pass
- Add section on expanded DBCC metric capture (error log extraction approach, PHYSICAL_ONLY vs FULL output formats)
- Add section on replica routing (CHECKCATALOG always-primary, replica_override per-database)
- Update CHECKDB operation description to mention metric parsing from error log
- Update "How Everything Connects" to reference CC page's cross-server DMV query for live progress
- Note that CHECKTABLE on-demand modal is not yet built (future)
- Mention the PENDING → IN_PROGRESS transition updating executed_on_server with resolved physical server

### Narrative Page (dbcc.html) — Second Pass
- "The Control Center View" section is thin — expand now that the page exists (live progress with completion %, today's execution list, schedule management with admin editing)
- Add brief mention of "capture everything" metric philosophy
- Some paragraphs in "How It Works" read more like architecture than narrative — warm up the tone
- Overall: less dry, more personality in a few spots

### CC Guide Page (dbcc-cc.html) — Not Yet Built
Once the CC page layout stabilizes, build the interactive walkthrough guide following the established CC guide pattern (mockup diagram, callout markers, flip cards, slideout sections).

---

## Feature Enhancements (Backlog)

### Disabled/Untrusted Constraint Inventory
Add a catalog scan to the DBCC Operations page showing disabled (is_disabled = 1) and untrusted (is_not_trusted = 1) FK constraints across monitored databases. This is a separate concern from CHECKCONSTRAINTS — disabled constraints are never validated by DBCC. Could be a static section or a modal accessible from the schedule area.

### Live Progress — CHECKCONSTRAINTS Current Table
CHECKCONSTRAINTS doesn't populate percent_complete in dm_exec_requests. Enhance the live progress display to show the current table/constraint being evaluated by pulling sql_text from the DMV session. Gives operators a sense of progress even without a percentage.

### Duration Trending
Chart for CHECKDB durations over time, primarily for crs5_oltp drift detection. Selectable by database. Deferred from initial build. The execution history data is already captured — this is a visualization addition.

### On-Demand Operations Modal
Modal for executing CHECKTABLE, CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS on demand from the CC page. Pick server → database → operation (→ table for CHECKTABLE) → execute. Deferred from initial build.

### Replica Override Admin UI Enhancements
- Schedule overview: prominently show override count on AG listener server rows (implemented)
- Future: bulk override set/clear for all databases on a server

### Viewport Constraint Standardization
The DBCC Operations page uses `calc(100vh - 200px)` for viewport-constrained layout with no page scroll. This should be standardized across all CC pages as part of the shared CSS consolidation effort.

---

## Infrastructure Items

### Tools.Utilities — Admin Page Integration
sp_SyncColumnOrdinals has full SQL functionality (single table, schema, full database). Future: admin page integration with scope selector dropdown and preview/execute toggle. Backlog item.

### GlobalConfig Row
`refresh_dbcc-operations_seconds` = 5 (INT, ControlCenter/Refresh) — created and active.

### RBAC ActionRegistry
The POST endpoints `/api/dbcc/schedule/update` and `/api/dbcc/schedule/replica-override` use Test-ActionEndpoint for admin permission checks. Currently pass through as unregistered (allowed). Should be registered in ActionRegistry when RBAC registration is formalized for this page.

---

## Metrics Baseline

### CHECKDB — crs5_oltp
- Duration: 4h 45m (down from ~9h with Ola Hallengren)
- Contributing factors: increased RAM, running on secondary (no production contention)
- First run with error log metric capture: metrics populating correctly
- Buffer pool scan: 66.8M scanned buffers, 76.6M iterated (from CHECKCATALOG on primary — CHECKDB buffer pool data TBD on next run)

### CHECKCATALOG — AG Databases
- Fixed: now routes to PRIMARY. All AG database CHECKCATALOGs successful.
- crs5_oltp: 24 seconds, buffer pool scan 10 seconds

### CHECKCONSTRAINTS — crs5_oltp
- Duration: 6.5 hours
- One error noted — data available for review

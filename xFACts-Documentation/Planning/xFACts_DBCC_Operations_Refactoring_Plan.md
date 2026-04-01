# xFACts DBCC Operations — Refactoring Plan

**Created:** March 20, 2026  
**Status:** Ready for implementation  
**Context:** Expansion of the initial DBCC CHECKDB implementation to support the full DBCC operation family with per-server operation-level scheduling.

---

## Background

The initial DBCC implementation (Session: March 20, 2026) built a CHECKDB-only execution framework:

- `ServerOps.DBCC_ExecutionLog` — execution history table
- `Execute-DBCC.ps1` — execution script
- `serverops_dbcc_enabled` + `dbcc_run_day` on `dbo.ServerRegistry`
- GlobalConfig entries for check_type, max_dop, extended_logical_checks, alerting_enabled
- `ServerOps.DBCC` component registered under the `indexmaint` doc page (section 2)
- ProcessRegistry entry (disabled, FIRE_AND_FORGET, scheduled 08:00, group 30, 14hr timeout)

During design review, the scope expanded to include the full DBCC operation family with per-operation scheduling. This document captures the refactoring plan.

---

## Target Design

### Operations to Support

| Operation | Schedulable | On-Demand Modal | Duration | Included in CHECKDB | Notes |
|-----------|:-----------:|:---------------:|----------|:-------------------:|-------|
| CHECKDB | Yes (weekends) | No | Hours (crs5_oltp ~9hr) | — | Full database integrity. Already implemented. |
| CHECKALLOC | Yes (weekday) | Yes | Seconds to minutes | Yes | Allocation structure consistency. Lightweight mid-week check. |
| CHECKCATALOG | Yes (weekday) | Yes | Seconds | Yes | System catalog consistency. Very fast. |
| CHECKCONSTRAINTS | Yes (weekday) | Yes | Minutes to hours | **No** | FK/CHECK constraint data validation. Not part of CHECKDB. Most valuable weekday addition. Can be slow on large tables with many FKs. |
| CHECKTABLE | No | Yes | Seconds to minutes | Yes (per table) | Single-table integrity check. On-demand diagnostic only. |
| CHECKFILEGROUP | Future | Future | Varies | Yes (per FG) | Filegroup-scoped check. Relevant when crs5_oltp is partitioned. Not in initial scope. |

### Proposed Weekly Schedule Example

| Day | Operation | Servers | Time | Rationale |
|-----|-----------|---------|------|-----------|
| Monday | CHECKALLOC | All | 8 PM | Lightweight allocation check to start the week |
| Tuesday | CHECKCONSTRAINTS | All | 8 PM | FK/constraint validation — most valuable mid-week check |
| Wednesday | CHECKCATALOG | All | 8 PM | Quick catalog consistency sweep |
| Thursday | — | — | — | Rest day |
| Friday | — | — | — | Rest day |
| Saturday | CHECKDB | AVG-PROD-LSNR (AG) | 8 AM | crs5_oltp + all AG databases on secondary |
| Sunday | CHECKDB | All other servers | 8 AM | Non-AG databases |

Schedule is fully configurable via the config table — this is just the initial plan.

---

## Database Changes

### New Table: ServerOps.DBCC_OperationSchedule

Per-server, per-operation scheduling configuration. Each row defines one operation on one server on one day at one time.

**Proposed columns:**

| Column | Type | Nullable | Notes |
|--------|------|----------|-------|
| schedule_id | INT IDENTITY | No | PK |
| server_id | INT | No | FK to ServerRegistry |
| server_name | VARCHAR(128) | No | Denormalized |
| operation | VARCHAR(30) | No | CHECKDB, CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS, CHECKFILEGROUP |
| run_day | TINYINT | No | 1=Sun through 7=Sat |
| run_time | TIME | No | When to start this operation |
| is_enabled | BIT | No | Per-row enable/disable |
| created_dttm | DATETIME | No | Default GETDATE() |
| created_by | VARCHAR(100) | No | Default SUSER_SNAME() |

**Design decisions to confirm:**
- Should operation-specific options (PHYSICAL_ONLY, MAXDOP) live here or stay in GlobalConfig? Leaning toward GlobalConfig for MAXDOP (applies to all) and either GlobalConfig or this table for check_mode (only applies to CHECKDB/CHECKTABLE).
- Do we need a `run_time` per row, or can we simplify to two GlobalConfig values (`dbcc_weekday_start_time`, `dbcc_weekend_start_time`)?
- Unique constraint on (server_id, operation, run_day) to prevent duplicate scheduling.

### ALTER: ServerOps.DBCC_ExecutionLog

Split `check_type` into two columns:

| Change | From | To |
|--------|------|----|
| Rename/replace `check_type` | VARCHAR(20): PHYSICAL_ONLY, FULL | `operation` VARCHAR(30): CHECKDB, CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS, CHECKTABLE, CHECKFILEGROUP |
| Add column | — | `check_mode` VARCHAR(20) NULL: PHYSICAL_ONLY, FULL (NULL for operations that don't have modes) |
| Update CK constraint | CK_DBCC_ExecutionLog_CheckType | Replace with CK on operation and CK on check_mode |

**Alternative:** Keep `check_type` and expand its values to include all operations + modes as combined values (e.g., CHECKDB_PHYSICAL_ONLY, CHECKALLOC). Simpler but less clean. Discuss in session.

### ALTER: dbo.ServerRegistry

- `dbcc_run_day` becomes **obsolete** — scheduling moves to DBCC_OperationSchedule
- `serverops_dbcc_enabled` **stays** as the server-level master switch
- Decision needed: DROP `dbcc_run_day` or leave it inactive? Dropping a column we just added is fine since it hasn't been deployed yet.

### GlobalConfig Changes

Current entries and their disposition:

| Setting | Keep/Modify/Remove | Notes |
|---------|-------------------|-------|
| `dbcc_check_type` | Modify | Rename to `dbcc_checkdb_mode` or similar. Only applies to CHECKDB operations. |
| `dbcc_max_dop` | Keep | Applies to all operations |
| `dbcc_extended_logical_checks` | Keep | Only applies to CHECKDB FULL mode |
| `dbcc_alerting_enabled` | Keep | Applies to all operations |

Possible additions:
- `dbcc_weekday_start_time` / `dbcc_weekend_start_time` — if we simplify run_time out of the config table
- Per-operation alerting thresholds? Probably not needed initially.

---

## Script Changes

### Execute-DBCC.ps1 Refactoring

**Current flow:**
1. Load GlobalConfig
2. Find servers where `dbcc_run_day = today`
3. For each server → for each database → run CHECKDB

**New flow:**
1. Load GlobalConfig
2. Query DBCC_OperationSchedule for operations where `run_day = today` AND `run_time <= current time` AND `is_enabled = 1`
3. Check ExecutionLog to skip operations already completed today (prevents re-execution if script fires multiple times)
4. For each matching schedule row:
   - Resolve server connection (AG secondary for listeners, direct for others)
   - For each active database on that server:
     - Execute the scheduled operation (CHECKDB, CHECKALLOC, etc.)
     - Log to ExecutionLog with the operation type
     - Alert on non-SUCCESS
5. Report to orchestrator

**ProcessRegistry change:**
- Current: `scheduled_time = '08:00'`, fires once daily
- New: Either fire more frequently (hourly?) so it can catch both 8 AM and 8 PM start times, or keep once-daily and use a different mechanism
- **Recommended:** Change to interval-based (e.g., every 60 minutes) with no scheduled_time. The script checks the config table each invocation. If no operations are due, exits NO_WORK. This naturally handles different start times on different days.
- **Alternative:** Keep time-based at the earliest possible start (8 AM) and have the script loop/sleep until later operations come due. More complex, longer-running process.
- **Decision needed in session.**

### DBCC Command Differences

| Operation | Command Pattern | Applies To | Modes |
|-----------|----------------|------------|-------|
| CHECKDB | `DBCC CHECKDB ([db]) WITH options` | Whole database | PHYSICAL_ONLY, FULL |
| CHECKALLOC | `DBCC CHECKALLOC ([db]) WITH NO_INFOMSGS, ALL_ERRORMSGS` | Whole database | None |
| CHECKCATALOG | `DBCC CHECKCATALOG ([db]) WITH NO_INFOMSGS` | Whole database | None |
| CHECKCONSTRAINTS | `DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS, NO_INFOMSGS, ALL_ERRORMSGS` | Whole database | None (ALL_CONSTRAINTS checks all FKs + CHECKs) |
| CHECKTABLE | `DBCC CHECKTABLE ([table]) WITH options` | Single table | PHYSICAL_ONLY, FULL |
| CHECKFILEGROUP | `DBCC CHECKFILEGROUP (fg_id) WITH options` | Single filegroup | PHYSICAL_ONLY, FULL |

**Output parsing differences:**
- CHECKDB: "CHECKDB found X allocation errors and Y consistency errors"
- CHECKALLOC: "CHECKALLOC found X allocation errors and Y consistency errors"
- CHECKCATALOG: "DBCC execution completed. If DBCC printed error messages, contact your system administrator." (errors go to message stream)
- CHECKCONSTRAINTS: Returns a result set of constraint violations (not message-based)
- Each operation will need its own output parsing logic in the script.

### Live Progress Monitoring

`sys.dm_exec_requests.percent_complete` works for:
- CHECKDB ✓
- CHECKTABLE ✓
- CHECKALLOC ✓
- CHECKFILEGROUP ✓

Does NOT populate for:
- CHECKCONSTRAINTS (runs as a query, not a DBCC scan)
- CHECKCATALOG (too fast to matter)

The CC live progress view can use the same `dm_exec_requests` query for all operations that support it. CHECKCONSTRAINTS would show as "running" without a percentage.

---

## Control Center — DBCC Operations Page

### Page Decision

DBCC gets its own standalone page rather than sharing with Index Maintenance. The page would be called "DBCC Operations" and serve as the home for all DBCC activity.

This also means:
- `ServerOps.DBCC` component gets its own `doc_page_id` (e.g., `dbcc`) instead of sharing `indexmaint`
- The Index Maintenance page rename to "Database Maintenance" is a **separate** effort (may or may not still happen)
- Component_Registry UPDATE needed to change doc_page_id from `indexmaint` to the new value

### Proposed Page Sections

1. **Live Progress** — Shows active DBCC operations with percent complete, database name, elapsed time, ETA. Uses `sys.dm_exec_requests` polling. Visible when any DBCC operation is running (scheduled or on-demand).

2. **Recent Results** — Last execution result per database, per operation type. Quick "is everything healthy?" view. Color-coded: green = SUCCESS, red = ERRORS_FOUND/FAILED, gray = never run.

3. **Execution History** — Filterable table: by operation type, server, database, date range, status. Expandable rows for error details.

4. **Duration Trending** — Chart for CHECKDB durations over time, primarily for crs5_oltp drift detection. Selectable by database.

5. **On-Demand Operations** — Modal for executing CHECKTABLE, CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS on demand. Pick server → database → operation (→ table for CHECKTABLE) → execute. Results appear in the same execution history.

6. **Schedule Overview** — Visual display of the DBCC_OperationSchedule config. What runs when on which servers. Possibly editable via admin UI.

### On-Demand Execution

On-demand operations (from the modal) need a mechanism to reach the target server and execute. Options:
- **API-triggered:** CC API endpoint receives the request, executes DBCC via direct SQL connection, streams progress. Simpler but ties up a CC thread.
- **Queue-based:** CC inserts a row into a DBCC queue table, the script picks it up on next cycle. Decoupled but adds latency.
- **Direct script launch:** CC calls the script with parameters for a specific operation. Consistent with how Index Maintenance manual launch works.
- **Decision needed in session.**

---

## Implementation Order (Next Session)

1. **Create DBCC_OperationSchedule table** — DDL, constraints, Object_Metadata
2. **ALTER DBCC_ExecutionLog** — split check_type into operation + check_mode
3. **DROP or NULL dbcc_run_day on ServerRegistry** — replaced by config table
4. **Update GlobalConfig** — rename dbcc_check_type if needed
5. **Refactor Execute-DBCC.ps1** — multi-operation support, config table driven
6. **Update ProcessRegistry** — adjust scheduling approach
7. **Update Component_Registry** — change doc_page_id from indexmaint to new page
8. **Update Object_Registry / Object_Metadata / System_Metadata** — new table, modified objects
9. **Populate DBCC_OperationSchedule** — initial schedule for all servers
10. **Test inaugural CHECKDB run** — enable ProcessRegistry, verify execution

CC page build (DBCC Operations) can follow in a subsequent session after the backend is solid.

---

## Open Questions for Next Session

1. Should `run_time` live per-row in the config table, or as two GlobalConfig values (weekday/weekend)?
2. ProcessRegistry: interval-based (hourly) vs time-based (8 AM) with script-level time gating?
3. ExecutionLog: split check_type into two columns, or expand to combined values?
4. On-demand execution mechanism: API-triggered, queue-based, or direct script launch?
5. Should CHECKFILEGROUP be included in the initial config table design (columns ready, just not populated), or deferred entirely?
6. CHECKCONSTRAINTS output is a result set, not a message stream. How to capture/store the violations?
7. New doc_page_id for the DBCC Operations page — `dbcc`? `dbcc-ops`?

---

## Files Delivered (March 20 Session)

All files remain valid for the CHECKDB use case. The refactoring is additive — we're expanding, not replacing.

| # | File | Status |
|---|------|--------|
| 01 | ALTER_ServerRegistry_DBCC.sql | **Needs modification** — keep serverops_dbcc_enabled, drop/skip dbcc_run_day |
| 02 | CREATE_DBCC_ExecutionLog.sql | **Needs modification** — split check_type into operation + check_mode |
| 03 | INSERT_GlobalConfig_DBCC.sql | **May need modification** — rename dbcc_check_type |
| 04 | Execute-DBCC.ps1 | **Needs refactoring** — multi-operation, config table driven |
| 05 | INSERT_Object_Metadata_DBCC.sql | **Needs updates** — new table, modified columns |
| 06 | INSERT_Registry_DBCC.sql | **Needs updates** — doc_page_id change, new table in Object_Registry |
| 07 | UPDATE_Object_Metadata_QueryFormatting.sql | ✅ No changes needed |
| 09 | INSERT_ProcessRegistry_DBCC.sql | **May need modification** — scheduling approach |

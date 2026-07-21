# DBCC Operations

*Trust, but verify — because "the data looks fine" isn't an integrity strategy*

DBCC Operations runs scheduled integrity checks against every enrolled database, confirming that the data on disk is physically sound, the allocation structures are consistent, and the constraints your application depends on are actually being enforced. It doesn't fix problems — it finds them before they find you.






The Problem

Databases don't just break with a bang. They break quietly. A bit flips on a storage subsystem. A page gets corrupted during a firmware update nobody noticed. A foreign key that was supposed to protect referential integrity has been silently violated for months because something bypassed the application layer.

The insidious part? Everything keeps working. Queries return results. Reports generate on schedule. Users don't notice. And then one day, a backup restore fails, or a critical report returns garbage data, or someone discovers that 200,000 account records point to a client that doesn't exist anymore.

SQL Server has built-in tools to detect these problems. But they have to actually be *run*. On a schedule. Against every database. With someone paying attention to the results. That's what DBCC Operations does.






What Gets Checked

Not all integrity checks are created equal. Some take seconds. One takes nine hours. Mixing them together on the same schedule would be like scheduling a dental cleaning and open-heart surgery in the same appointment slot because they're both "medical procedures."

| Check | What It Verifies | How Long It Takes |
| --- | --- | --- |
| **Full Integrity Check** | Everything — physical page structure, allocation consistency, logical relationships between objects. The gold standard. | Hours for large databases |
| **Allocation Check** | Page and extent allocation structures. Makes sure the storage bookkeeping is consistent. | Seconds to minutes |
| **Catalog Check** | System catalog consistency. Verifies the database's internal table relationships are intact. | Seconds |
| **Constraint Check** | Foreign key and check constraint validation. Finds data that violates the rules your application assumes are being enforced. | Minutes to hours |


Each check type runs independently, on its own schedule, at the database level. The lightweight checks can run on weekday evenings without anyone noticing. The heavy integrity check runs on weekends when nobody's around to complain about the I/O.






How It Works



Schedule
Says Go
→
Claim
the Work
→
Run the
Check
→
Log the
Result
→
Alert if
Not Clean

From schedule trigger to result — lightweight checks finish in seconds, the big one takes hours


Each database has its own schedule — which checks to run, which day, what time. On each cycle, the system looks at what's due, claims all the pending work up front, then works through it from lightest to heaviest. Catalog checks go first (seconds), then allocation checks (minutes), then constraint checks (longer), and finally the big integrity check (hours).

The claim-first approach means multiple runs can overlap safely. If one run is still grinding through a nine-hour integrity check when the next cycle fires, the new run sees the work is already claimed and moves on. No duplicates, no conflicts, no wasted effort.

For databases in an Always On Availability Group, the checks run on the secondary replica rather than the primary. Same data, zero production impact. The system figures out which server is the secondary automatically — no manual reconfiguration needed when a failover happens.






When Things Go Wrong

A clean check produces a quiet log entry and moves on. A problem produces noise — deliberately.

| Situation | Response |
| --- | --- |
| **Physical corruption detected** | Teams alert and Jira ticket with recommended actions. This is the "stop what you're doing" scenario. |
| **Constraint violations found** | Teams alert with a count of affected constraints. Details available in the Control Center for investigation. |
| **Check failed to run** | Teams alert. Usually means a connectivity issue or the database wasn't available. Will be retried on the next scheduled cycle. |


Constraint violations are a different animal from physical corruption. Corruption means the storage layer has a problem. Constraint violations mean the *data* has a problem — rows that shouldn't exist, references that point nowhere. The Control Center page lets you drill into the specifics so you can figure out what happened and how to fix it.






The Control Center View

The DBCC Operations page in the Control Center provides a live view of integrity check activity. You can see what's running right now (with progress for long-running checks), what's waiting in the queue, what ran recently, and how long things are taking over time. For constraint checks, you can drill into the violations and investigate the actual offending data.






The Bottom Line

Databases are not self-policing. Data corruption and constraint violations happen silently, and they compound over time. The longer you go without checking, the bigger the surprise when you finally do.

DBCC Operations makes integrity verification automatic, scheduled, and visible. Every check is logged. Every problem generates an alert. And the heavy lifting happens on the secondary replica so production never feels it.

It's the database equivalent of a smoke detector. Boring when everything's fine. Invaluable the one time it isn't.

---

# DBCC Operations — Control Center Guide

---

## Architecture
# DBCC Operations Architecture

The narrative page tells you *what* DBCC Operations does and *why* it matters. This page tells you *how*. One PowerShell script, two tables, and a configurable schedule that handles everything from a two-second catalog check to a nine-hour full integrity scan — with concurrent execution safety and AG-aware server resolution.



Schema Overview

The DBCC component uses two tables: one for scheduling configuration, one for execution history. Configuration describes what *should* happen. The execution log records what *did* happen.



| Table | Role | Cardinality |
| --- | --- | --- |
| `DBCC_ScheduleConfig` | Per-database scheduling configuration — which operations run on which day at what time | One per enrolled database |
| `DBCC_ExecutionLog` | Execution history — one row per database per operation per run | Many per database over time |







Scheduling Model

Scheduling is per-database and per-operation. Each database enrolled in `DBCC_ScheduleConfig` has independent settings for four operation types: full integrity check, allocation check, catalog check, and constraint check. Each operation has its own enabled flag, day of week, and time of day.

This granularity exists because the operations have wildly different resource profiles. A catalog check takes seconds and can run any evening. A full integrity check on a large database takes hours and needs a weekend window. Forcing them onto the same schedule would either under-check or over-burden.

Three-Tier Enable Control

Three levels must all be active for an operation to execute:




Server Level
`serverops_dbcc_enabled`
on ServerRegistry

→

Database Level
`is_enabled`
on DBCC_ScheduleConfig

→

Operation Level
`checkdb_enabled`
`checkalloc_enabled`
etc.


All three tiers must be enabled — disable at any level to stop operations at that scope


This provides quick kill switches at every scope without losing schedule configuration. Disable the server-level flag to pause all DBCC across all databases on that server. Disable the database-level flag to pause one database. Disable a specific operation flag to stop just that check type.

Hour-Based Matching

The script matches the hour component of each operation's `run_time` against the current hour. A `run_time` of `20:00` triggers during the 8 PM hour (20:00–20:59). The script uses a *less-than-or-equal* comparison, so operations from earlier hours that weren't picked up (because a prior invocation was still running) are caught by the next available invocation.


No operations are silently skipped. If a long-running integrity check blocks an invocation from starting, the next invocation picks up any past-due operations from earlier hours. The already-claimed-today check on `DBCC_ExecutionLog` prevents duplicates while ensuring nothing falls through the cracks.







Execution Flow

`Execute-DBCC.ps1` runs on a configurable interval via `ProcessRegistry`. Each invocation follows a fixed sequence:




1. Config
Load GlobalConfig
settings

→

2. Discover
Query schedule for
operations due today

→

3. Claim
Insert PENDING rows
for unclaimed work

→

4. Execute
Process items
lightest to heaviest

→

5. Report
Update log, alert,
orchestrator callback




Status Lifecycle

| Status | Meaning | Timestamps |
| --- | --- | --- |
| **PENDING** | Claimed by an invocation, waiting in queue for its turn | `queued_dttm` set, `started_dttm` NULL |
| **IN_PROGRESS** | DBCC command is actively executing | `started_dttm` set, `executed_on_server` resolved |
| **SUCCESS** | Completed with no errors | `completed_dttm` and `duration_seconds` set |
| **FAILED** | Script or connection error prevented completion | `error_details` contains the error message |
| **ERRORS_FOUND** | DBCC completed but reported integrity or constraint violations | `error_count` and `error_details` populated |


The difference between `queued_dttm` and `started_dttm` represents time spent waiting in queue behind other operations. This metric is visible on the Control Center page and is useful for evaluating whether schedule windows need adjustment.

Execution Priority

When multiple operations are due in the same invocation, they execute in fixed priority order from lightest to heaviest:




CHECKCATALOG
Seconds

→

CHECKALLOC
Seconds to minutes

→

CHECKCONSTRAINTS
Minutes to hours

→

CHECKDB
Hours


Lightweight operations complete quickly even when a long-running CHECKDB is in the same batch







Batch Claim Pattern

The batch claim pattern is the concurrency safeguard. Before executing anything, the script inserts a PENDING row into `DBCC_ExecutionLog` for every operation it intends to process. This serves two purposes:

First, it prevents duplicate execution. When a concurrent invocation fires (because the orchestrator allows concurrent runs), it queries the ExecutionLog for existing rows today. Any operation that already has a row — whether PENDING, IN_PROGRESS, or completed — is skipped.

Second, it provides queue visibility. The Control Center page can show PENDING items as "waiting in queue" with elapsed wait time, giving operators a clear picture of what's running, what's waiting, and how long each item has been queued.


Claim time vs. execution time. `queued_dttm` records when the row was inserted (claim time). `started_dttm` records when the DBCC command actually began executing. For the first item in a batch, these are nearly identical. For the last item — which might wait hours behind a CHECKDB — the gap can be significant. `duration_seconds` measures actual execution time (from `started_dttm`), not time-in-queue.


Manual Override Mode

The `-TargetServer`, `-TargetDatabase`, and `-Operation` parameters bypass the schedule table entirely. Manual mode does not check for existing rows today, allowing re-execution of operations for diagnostic purposes. Connection details are still resolved from `ServerRegistry`, and results still log to `DBCC_ExecutionLog`.






Operation Types

CHECKDB

Full database integrity check. Verifies physical page structure, allocation consistency, and logical relationships between all objects. Supports two modes configured via GlobalConfig: `PHYSICAL_ONLY` (storage corruption, significantly faster) and `FULL` (complete logical and physical). MAXDOP is configurable. Extended logical checks for indexed views, XML indexes, and spatial indexes are available in FULL mode.

Output parsing looks for the standard error count pattern in the DBCC message stream. A clean check with `NO_INFOMSGS` produces no output. Any output indicates errors.

CHECKALLOC

Allocation structure consistency check. Verifies page and extent allocation bookkeeping. Lightweight — typically completes in seconds to minutes even on large databases. Output parsing follows the same error count pattern as CHECKDB.

CHECKCATALOG

System catalog consistency check. Verifies relationships between system tables. Very fast — seconds. With `NO_INFOMSGS`, any output at all indicates errors.

CHECKCONSTRAINTS

Foreign key and CHECK constraint validation. Unlike the other operations, CHECKCONSTRAINTS returns a *result set* rather than messages. Each row in the result set identifies a specific constraint violation with the table, constraint name, and a WHERE clause for the offending rows.

The script aggregates violations by table and constraint name, storing a summary in `error_details` with violation counts per constraint. `error_count` reflects distinct constraints with violations, not total violating rows. Detailed row-level investigation is handled by live queries from the Control Center page.

CHECKTABLE

Single-table integrity check. Unlike the four operations above, CHECKTABLE is not part of the schedule — it targets one table rather than a whole database, so it isn't enrolled in `DBCC_ScheduleConfig`. It runs only through Manual Override Mode (described above), by invoking the script with an explicit server, database, and table. Results log to `DBCC_ExecutionLog` like any other operation.


About `target_object`. `DBCC_ExecutionLog` carries a `target_object` column intended to hold the specific object a check targeted — the natural home for a CHECKTABLE table name. In current operation no code path populates it, so the column is present but NULL on every row. Database-wide operations have no single target object to record there.







AG Secondary Execution

For servers registered as AG listeners in `ServerRegistry`, the script resolves the appropriate physical replica through `sys.dm_hadr_availability_replica_states` and runs DBCC operations via a direct connection to it. Running on a secondary eliminates production I/O impact entirely — the secondary has identical data (minus redo lag, typically seconds) and supports all DBCC operations.

Where a check runs is decided *per database*, not globally. Each AG-listener database in `DBCC_ScheduleConfig` carries a `replica_override` setting with three values:

| replica_override | Where the check runs |
| --- | --- |
| **Default** | Follows the platform-wide preferred-replica setting from GlobalConfig — the normal case, typically the secondary |
| **Primary** | Pins this database's checks to the primary replica, overriding the global preference |
| **Secondary** | Pins this database's checks to the secondary replica, overriding the global preference |


So the GlobalConfig preferred replica is the default that applies to every AG database, and `replica_override` lets an individual database opt out of that default when it needs to run somewhere specific. This override is what the warning marker on the Schedule Overview flags. It applies only to AG-listener servers — on a standalone server there is no replica choice to make. The setting is editable per database from the schedule editor on the Control Center page.

Connection resolution results are cached per server within an invocation to avoid repeated AG topology queries. The physical server name actually used is recorded in `executed_on_server` on the ExecutionLog row, preserving accurate history even if the AG topology changes between runs.


AG resolution failure is not silent. If the secondary replica cannot be determined, all operations for that server are skipped with a FAILED status and a Teams alert. The next invocation will retry AG resolution fresh.







Alerting & Escalation

Alerting is controlled by the `dbcc_alerting_enabled` GlobalConfig setting. When enabled, any non-SUCCESS result generates a Teams alert. The severity and content vary by situation:

| Situation | Alert Level | Additional Action |
| --- | --- | --- |
| CHECKDB finds corruption | CRITICAL | Jira ticket with recommended remediation steps |
| CHECKCONSTRAINTS finds violations | CRITICAL | Teams alert with constraint count |
| Other ERRORS_FOUND | CRITICAL | Teams alert with error count |
| FAILED (script/connection error) | WARNING | Teams alert with error preview |
| AG resolution failed | WARNING | Teams alert, all operations for that server skipped |







Troubleshooting

**"An operation shows PENDING but never progresses to IN_PROGRESS."**
The invocation that claimed it may have failed or timed out before reaching that item in the queue. Check the script log file for errors. The orchestrator timeout on `ProcessRegistry` will eventually mark the task as timed out. A subsequent invocation will not pick up the stale PENDING row because it already exists for today — manual cleanup of the row may be needed, or wait until tomorrow when the date filter resets.

**"Operations aren't being scheduled."**
Verify all three enable tiers: `serverops_dbcc_enabled` on `ServerRegistry`, `is_enabled` on `DBCC_ScheduleConfig`, and the specific operation's `_enabled` flag. Check that `run_day` matches today's day of week (1=Sunday through 7=Saturday) and `run_time` hour has passed.

**"CHECKDB is taking longer than expected."**
Query the execution history for duration trending. Significant increases usually indicate database growth, increased fragmentation, or I/O contention on the secondary. Consider adjusting MAXDOP via GlobalConfig. For the main production database, durations of 8–10 hours are expected at current data volumes.

**"CHECKCONSTRAINTS found violations — now what?"**
The `error_details` field contains an aggregated summary listing each violated constraint and the violation count. Use the Control Center page to run a live diagnostic query that shows sample violating rows. The remedy depends on the constraint type: orphaned FK references may need data cleanup, and CHECK violations may need application-level investigation.

**"The script exited NO_WORK but operations should be due."**
Check the script log for the reported day and hour values. Verify the schedule config has matching `run_day` and `run_time` values. The hour comparison uses less-than-or-equal, so a `run_time` of `20:00` won't trigger during hour 19. Also confirm the `ProcessRegistry` entry has `run_mode = 1` (enabled) and verify `allow_concurrent = 1`.






How Everything Connects

Internal Flow

| From | To | Relationship |
| --- | --- | --- |
| `DBCC_ScheduleConfig` | `DBCC_ExecutionLog` | Schedule determines what operations to run; ExecutionLog records results and prevents duplicate claims |
| `Execute-DBCC.ps1` | `Teams.AlertQueue` | Non-SUCCESS results queued via shared `Send-TeamsAlert` function |
| `Execute-DBCC.ps1` | `Jira.sp_QueueTicket` | CHECKDB ERRORS_FOUND generates a Jira ticket with remediation steps |


External Dependencies

| Dependency | Module | Purpose |
| --- | --- | --- |
| `dbo.ServerRegistry` | Engine Room | Server-level enable flag (`serverops_dbcc_enabled`), server type, AG cluster name, instance name |
| `dbo.DatabaseRegistry` | Engine Room | Database enrollment — `DBCC_ScheduleConfig` has a FK to `DatabaseRegistry` |
| `dbo.GlobalConfig` | Engine Room | CHECKDB mode, MAXDOP, extended logical checks, alerting enabled, AG name, platform-wide preferred replica (the default a per-database `replica_override` can supersede) |
| `Orchestrator.ProcessRegistry` | Orchestrator | Interval-based scheduling with concurrent execution enabled; `TaskLog` provides task-level tracking |
| `sys.dm_hadr_availability_replica_states` | SQL Server | AG topology resolution for secondary replica targeting |
| `sys.databases` | SQL Server | Online state verification before executing DBCC on target server |
| `sys.dm_exec_requests` | SQL Server | Live progress monitoring (`percent_complete`) for running CHECKDB and CHECKALLOC operations, surfaced on the Control Center page |

---

## Reference

### DBCC_ExecutionLog

Execution history for DBCC integrity operations. One row per database per operation per execution. The script processes databases sequentially, so a single script invocation produces multiple rows grouped by run_id. Supports CHECKDB, CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS, CHECKTABLE, and CHECKFILEGROUP.

**Data Flow:** Execute-DBCC.ps1 inserts a PENDING row at claim time, transitions to IN_PROGRESS with the resolved physical server at execution start, and updates with final status, duration, error details, and DBCC output metrics on completion. One row per database per operation per run, grouped by run_id. CHECKDB and CHECKALLOC populate allocation_errors, consistency_errors, repaired_errors, dbcc_elapsed_seconds, LSN values, and buffer pool scan metrics from the DBCC summary output. CHECKCONSTRAINTS stores an aggregated violation summary in error_details. The Control Center DBCC Operations page reads this table for live progress, execution history, and duration trending. Teams alerts and Jira tickets are queued by the script on non-SUCCESS results.

**Self-Documenting Options:** [sort:1] operation, check_mode, max_dop, and extended_logical_checks are stored on every row even though they come from GlobalConfig. If GlobalConfig settings change between runs, the log still shows exactly what options were used for each execution. This eliminates the need to cross-reference GlobalConfig history.

**AG Listener vs Physical Server:** [sort:2] server_name and server_id capture the ServerRegistry entry that triggered the run (e.g., AVG-PROD-LSNR for AG databases). executed_on_server captures the physical server where DBCC actually ran (e.g., DM-PROD-REP as the resolved secondary). For non-AG servers both values are identical. This distinction matters for I/O contention analysis and troubleshooting.

**CHECKCONSTRAINTS Output Handling:** [sort:3] CHECKCONSTRAINTS returns a result set of constraint violations rather than a message stream. The script aggregates violations by table and constraint name, storing the summary in error_details with violation counts per constraint. error_count reflects the number of distinct constraints with violations, not the total number of violating rows. Detailed row-level investigation is done via live queries from the Control Center page.

**DBCC Output Metric Capture:** [sort:4] Every metric that DBCC reports in its summary output is captured per-row for historical trending and diagnostic analysis. CHECKDB and CHECKALLOC populate all metric columns; CHECKCATALOG and CHECKCONSTRAINTS leave them NULL since those operations produce different output formats. The metric columns are nullable specifically to accommodate this — NULL means the metric does not apply to that operation type, not that it was missed. The NO_INFOMSGS option remains enabled to suppress per-object informational messages (thousands of lines on large databases) while still capturing the summary output that contains all valuable metrics.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| log_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the log entry. |
| run_id | int | Yes | — | Groups all databases from one script invocation. Generated as MAX(run_id) + 1 at script start. |
| server_id | int | No | — | FK to ServerRegistry. The enabled entry that triggered the run — for AG databases this is the listener, not the physical execution target. |
| server_name | varchar(128) | No | — | Denormalized from ServerRegistry. Matches the server_name of the enabled entry (e.g., AVG-PROD-LSNR for AG databases). |
| executed_on_server | varchar(128) | No | — | Physical server where DBCC actually ran. For AG databases, this is the dynamically resolved secondary replica. For non-AG servers, matches server_name. |
| database_name | varchar(128) | No | — | Database name as enrolled in DatabaseRegistry. |
| operation | varchar(30) | No | — | Which DBCC command was executed: CHECKDB, CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS, CHECKTABLE, or CHECKFILEGROUP. |
| check_mode | varchar(20) | Yes | — | DBCC check mode for operations that support it: PHYSICAL_ONLY or FULL. NULL for operations without modes (CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS). Only meaningful for CHECKDB and CHECKTABLE. |
| target_object | varchar(256) | Yes | — | Schema-qualified object name for scoped operations. Populated with the table name for CHECKTABLE and filegroup name for CHECKFILEGROUP. NULL for database-level operations (CHECKDB, CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS). |
| max_dop | int | No | — | MAXDOP value used for this execution. Captured per-row for historical accuracy. |
| extended_logical_checks | bit | No | — | Whether EXTENDED_LOGICAL_CHECKS was enabled for this execution. Only meaningful when check_type is FULL. |
| queued_dttm | datetime | No | — | When this operation was claimed by the batch claim step. Set at claim time when the row is inserted as PENDING. The difference between queued_dttm and started_dttm represents time spent waiting in queue behind other operations. |
| started_dttm | datetime | Yes | — | When the DBCC operation actually began executing. NULL while status is PENDING (claimed but waiting in queue). Set when the operation transitions to IN_PROGRESS. Duration is measured from this timestamp, not from queued_dttm. |
| completed_dttm | datetime | Yes | — | When DBCC CHECKDB completed. NULL while still running. |
| duration_seconds | int | Yes | — | Total elapsed seconds. Measured at the PowerShell level around the DBCC command invocation. |
| dbcc_elapsed_seconds | int | Yes | — | Elapsed time as reported by DBCC itself in its summary output. Independent of the PowerShell-level duration_seconds which includes connection setup and overhead. Useful for comparing DBCC internal performance across runs without external timing variance. NULL for operations that do not report elapsed time. |
| dbcc_summary_output | varchar(2000) | Yes | — | Raw DBCC summary text captured from the SQL Server error log after execution completes. Contains the full informational message including error counts, elapsed time, LSN values, and buffer pool scan metrics. Preserved as a permanent record since error logs cycle nightly. The parsed metric columns (allocation_errors, dbcc_elapsed_seconds, etc.) are derived from this text. NULL for operations that do not produce error log summary entries or when the error log query fails. |
| status | varchar(20) | No | 'PENDING' | Execution result. IN_PROGRESS while running, SUCCESS for clean check, FAILED for script/connection errors, ERRORS_FOUND when DBCC reports corruption. |
| allocation_errors | int | Yes | — | Number of allocation errors reported by DBCC. Parsed separately from the DBCC summary output line. NULL for operations that do not report allocation errors (CHECKCATALOG, CHECKCONSTRAINTS). Combined with consistency_errors to produce error_count. |
| consistency_errors | int | Yes | — | Number of consistency errors reported by DBCC. Parsed separately from the DBCC summary output line. NULL for operations that do not report consistency errors (CHECKCATALOG, CHECKCONSTRAINTS). Combined with allocation_errors to produce error_count. |
| repaired_errors | int | Yes | — | Number of errors repaired by DBCC during execution. Parsed from the "repaired N errors" output. Typically 0 — DBCC does not repair unless explicitly run with REPAIR options. NULL for operations that do not report repair counts. |
| error_count | int | Yes | — | Number of errors reported by DBCC. Sum of allocation_errors and consistency_errors parsed from the DBCC output summary line. 0 for SUCCESS, 0 for FAILED (script-level errors do not produce DBCC error counts). Pre-calculated for convenience — avoids query math when you just need a total. |
| error_details | varchar(MAX) | Yes | — | Full DBCC error output text when errors are found, or exception message when the script fails. NULL for SUCCESS. Truncated to 8000 characters if excessively large. |
| split_point_lsn | varchar(50) | Yes | — | Internal database snapshot split point LSN used by DBCC during execution. Parsed from the DBCC summary output. Useful for correlating DBCC operations with backup and replication LSN chains. NULL for operations that do not create internal snapshots. |
| first_lsn | varchar(50) | Yes | — | First LSN of the internal database snapshot used by DBCC. Parsed from the DBCC summary output alongside split_point_lsn. NULL for operations that do not create internal snapshots. |
| buffer_pool_scan_seconds | int | Yes | — | Duration in seconds of the buffer pool scan performed at the start of DBCC execution. Parsed from the "Buffer Pool scan took N seconds" output. A long buffer pool scan indicates memory pressure or a very large buffer pool. NULL for operations that do not perform buffer pool scans. |
| pages_scanned | bigint | Yes | — | Number of database pages (buffers) scanned by DBCC during the buffer pool scan phase. Parsed from "scanned buffers N" in the DBCC output. Useful for trending database growth — if this count increases significantly between runs, the database is growing and future CHECKDB durations will increase. NULL for operations that do not report page counts. |
| pages_iterated | bigint | Yes | — | Total number of buffers iterated during the buffer pool scan phase. Parsed from "total iterated buffers N" in the DBCC output. Typically larger than pages_scanned as it includes pages examined but not belonging to the target database. NULL for operations that do not report page counts. |
| executed_by | varchar(100) | No | suser_sname() | Windows account that ran the script. Defaults to SUSER_SNAME() — typically the orchestrator service account. |

  - **PK_DBCC_ExecutionLog** (CLUSTERED): log_id -- PRIMARY KEY
  - **IX_DBCC_ExecutionLog_Database** (NONCLUSTERED): database_name, queued_dttm [includes: status, duration_seconds, executed_on_server]
  - **IX_DBCC_ExecutionLog_RunId** (NONCLUSTERED): run_id [includes: server_name, database_name, status]
  - **IX_DBCC_ExecutionLog_Server_Date** (NONCLUSTERED): server_id, queued_dttm [includes: database_name, status, duration_seconds]

**Check Constraints:**

  - **CK_DBCC_ExecutionLog_CheckMode**: `([check_mode] IS NULL OR ([check_mode]='FULL' OR [check_mode]='PHYSICAL_ONLY'))`
  - **CK_DBCC_ExecutionLog_Operation**: `([operation]='CHECKFILEGROUP' OR [operation]='CHECKTABLE' OR [operation]='CHECKCONSTRAINTS' OR [operation]='CHECKCATALOG' OR [operation]='CHECKALLOC' OR [operation]='CHECKDB')`
  - **CK_DBCC_ExecutionLog_Status**: `([status]='ERRORS_FOUND' OR [status]='FAILED' OR [status]='SUCCESS' OR [status]='IN_PROGRESS' OR [status]='PENDING')`

**Foreign Keys:**

  - **FK_DBCC_ExecutionLog_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| status | PENDING | Operation has been claimed by a script invocation and is waiting in queue. The row exists to prevent other concurrent invocations from claiming the same work. queued_dttm is populated; started_dttm is NULL. |  |
| check_mode | PHYSICAL_ONLY | Physical structure checks only — page checksums, torn pages, physical page integrity. Catches most real-world storage corruption. Significantly faster than FULL. | 1 |
| status | IN_PROGRESS | DBCC operation is actively executing. Transitioned from PENDING when the script begins processing this item. started_dttm and executed_on_server are populated at this transition. | 1 |
| operation | CHECKDB | Full database integrity check. Verifies physical and logical consistency of all objects. Longest-running operation — hours for large databases. | 1 |
| operation | CHECKALLOC | Allocation structure consistency check. Verifies page allocation and extent structures. Lightweight — seconds to minutes. | 2 |
| status | SUCCESS | DBCC CHECKDB completed with zero allocation errors and zero consistency errors. Database integrity verified. | 2 |
| check_mode | FULL | Complete logical and physical integrity check. Includes all PHYSICAL_ONLY checks plus cross-object logical consistency validation. | 2 |
| status | FAILED | Script or connection error prevented DBCC from completing. Typical causes: database not online, connection timeout, permissions issue. error_details contains the exception message. Teams alert is sent. | 3 |
| operation | CHECKCATALOG | System catalog consistency check. Verifies system table relationships. Very fast — seconds. | 3 |
| operation | CHECKCONSTRAINTS | FK and CHECK constraint data validation. Identifies rows that violate constraint rules. Duration varies — minutes to hours depending on table sizes and constraint count. Not included in CHECKDB. | 4 |
| status | ERRORS_FOUND | DBCC CHECKDB completed but reported allocation and/or consistency errors — corruption detected. error_count has the total, error_details has the full DBCC output. Teams alert and Jira ticket are sent. | 4 |
| operation | CHECKTABLE | Single-table integrity check. On-demand only via Control Center modal. Not scheduled. | 5 |
| operation | CHECKFILEGROUP | Filegroup-scoped integrity check. Future use — reserved in constraints but no execution logic implemented. | 6 |

**Non-success executions** [sort:1] -- Shows all executions that did not complete successfully — errors found, failures, or still in progress.

```sql
SELECT
    log_id, run_id, server_name, executed_on_server,
    database_name, operation, check_mode,
    started_dttm, duration_seconds, status,
    error_count, LEFT(error_details, 500) AS error_preview
FROM ServerOps.DBCC_ExecutionLog
WHERE status NOT IN ('SUCCESS')
ORDER BY started_dttm DESC;
```

**Last execution per database per operation** [sort:2] -- Shows the most recent result for each database and operation type. Quick health overview.

```sql
SELECT
    el.server_name, el.database_name, el.operation,
    el.check_mode, el.started_dttm, el.duration_seconds,
    el.status, el.error_count
FROM ServerOps.DBCC_ExecutionLog el
INNER JOIN (
    SELECT database_name, operation, MAX(log_id) AS max_log_id
    FROM ServerOps.DBCC_ExecutionLog
    GROUP BY database_name, operation
) latest ON el.log_id = latest.max_log_id
ORDER BY el.server_name, el.database_name, el.operation;
```

**CHECKDB duration trending** [sort:3] -- Shows CHECKDB execution durations over time for a specific database. Useful for detecting drift in crs5_oltp execution times.

```sql
SELECT
    started_dttm, duration_seconds,
    duration_seconds / 3600 AS duration_hours,
    check_mode, executed_on_server, status
FROM ServerOps.DBCC_ExecutionLog
WHERE operation = 'CHECKDB'
  AND database_name = 'crs5_oltp'
ORDER BY started_dttm DESC;
```

  - **ServerRegistry**: [sort:1] server_id references dbo.ServerRegistry. Only servers with serverops_dbcc_enabled = 1 are eligible for DBCC operations. For AG listeners, the script resolves the secondary replica dynamically and records the physical server in executed_on_server.
  - **DBCC_ScheduleConfig**: [sort:2] In scheduled mode, operations are driven by DBCC_ScheduleConfig entries matching the current day and hour. The ExecutionLog is checked for existing rows today to prevent duplicate execution of the same operation on the same database.
  - **GlobalConfig**: [sort:3] Execution options (checkdb_mode, max_dop, extended_logical_checks, alerting_enabled) are read from dbo.GlobalConfig at script startup under module ServerOps, category DBCC. Values are captured per-row in the log for historical accuracy.


### DBCC_ScheduleConfig

Per-database scheduling configuration for DBCC integrity operations. One row per database with independent enabled/day/time settings per operation type (CHECKDB, CHECKALLOC, CHECKCATALOG, CHECKCONSTRAINTS). The row-level is_enabled flag combines with serverops_dbcc_enabled on ServerRegistry for two-tier control. CHECKTABLE and CHECKFILEGROUP are on-demand only and do not appear in this table.

**Data Flow:** Rows are manually inserted when enrolling databases for DBCC operations, typically populated from DatabaseRegistry and ServerRegistry. Execute-DBCC.ps1 reads this table on each cycle to determine which operations are due based on the current day and hour. The script joins to ServerRegistry to enforce the serverops_dbcc_enabled master switch. The Control Center DBCC Operations page reads this table for the schedule overview display.

**Per-Database Granularity:** [sort:1] Each database gets its own schedule row with independent settings per operation. This allows staggering heavy operations like CHECKDB across different days while running lightweight operations (CHECKALLOC, CHECKCATALOG) together. A 10TB database can run CHECKDB on Saturday morning while smaller databases on the same server run Sunday.

**Two-Tier Enable Control:** [sort:2] Three levels of control exist: serverops_dbcc_enabled on ServerRegistry (server-level kill switch), is_enabled on this table (database-level kill switch), and individual operation _enabled flags (operation-level control). All three must be active for an operation to execute. This provides quick disable at any scope without losing schedule configuration.

**Hour-Based Schedule Matching:** [sort:3] The script matches the hour component of run_time against the current hour. A run_time of 20:00 triggers when the script fires during the 8 PM hour (20:00-20:59). Combined with the already-executed-today check on DBCC_ExecutionLog, this prevents duplicate execution if the script fires multiple times within the same hour.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| schedule_id (IDENTITY) | int | No | IDENTITY | Auto-incrementing primary key. |
| server_id | int | No | — | FK to ServerRegistry. Denormalized from DatabaseRegistry for direct server-level queries and joins. |
| server_name | varchar(128) | No | — | Denormalized server name from ServerRegistry. Avoids joins for display and logging. |
| database_id | int | No | — | FK to DatabaseRegistry. One schedule row per enrolled database. |
| database_name | varchar(128) | No | — | Denormalized database name from DatabaseRegistry. |
| checkdb_enabled | bit | No | 0 | Whether CHECKDB is scheduled for this database. 0 = disabled, 1 = enabled. When enabled, checkdb_run_day and checkdb_run_time control when it executes. |
| checkdb_run_day | tinyint | Yes | — | Day of week for CHECKDB execution. 1=Sunday through 7=Saturday, matching DATEPART(dw,...) convention. NULL when checkdb_enabled = 0. |
| checkdb_run_time | time | Yes | — | Time of day for CHECKDB execution. The script matches on the hour component. NULL when checkdb_enabled = 0. |
| checkalloc_enabled | bit | No | 0 | Whether CHECKALLOC is scheduled for this database. |
| checkalloc_run_day | tinyint | Yes | — | Day of week for CHECKALLOC execution. Same convention as checkdb_run_day. |
| checkalloc_run_time | time | Yes | — | Time of day for CHECKALLOC execution. |
| checkcatalog_enabled | bit | No | 0 | Whether CHECKCATALOG is scheduled for this database. |
| checkcatalog_run_day | tinyint | Yes | — | Day of week for CHECKCATALOG execution. Same convention as checkdb_run_day. |
| checkcatalog_run_time | time | Yes | — | Time of day for CHECKCATALOG execution. |
| checkconstraints_enabled | bit | No | 0 | Whether CHECKCONSTRAINTS is scheduled for this database. |
| checkconstraints_run_day | tinyint | Yes | — | Day of week for CHECKCONSTRAINTS execution. Same convention as checkdb_run_day. |
| checkconstraints_run_time | time | Yes | — | Time of day for CHECKCONSTRAINTS execution. |
| check_mode | varchar(20) | No | 'NONE' | DBCC check mode for operations that support it. PHYSICAL_ONLY checks storage corruption only — significantly faster. FULL performs complete logical and physical integrity validation. NONE indicates no check mode configured — CHECKDB cannot be enabled while check_mode is NONE. Applies to CHECKDB and on-demand CHECKTABLE. Other operations ignore this setting. |
| replica_override | varchar(10) | Yes | — | Replica routing override for AG listener databases. NULL uses the default routing (SECONDARY for all operations except CHECKCATALOG, which always routes to PRIMARY). PRIMARY forces all operations to the primary replica — used when primary-side integrity verification is needed after hardware events, bulk operations, or as periodic validation. SECONDARY explicitly targets the secondary. Persists until manually cleared. Non-AG servers ignore this column. |
| is_enabled | bit | No | 1 | Row-level master switch. When 0, no operations run for this database regardless of individual operation settings. Combines with serverops_dbcc_enabled on ServerRegistry for two-tier control. |
| created_dttm | datetime | No | getdate() | When this schedule row was created. |
| created_by | varchar(100) | No | suser_sname() | Who created this schedule row. |
| modified_dttm | datetime | Yes | — | When this schedule row was last modified. |
| modified_by | varchar(100) | Yes | — | Who last modified this schedule row. |

  - **PK_DBCC_ScheduleConfig** (CLUSTERED): schedule_id -- PRIMARY KEY
  - **IX_DBCC_ScheduleConfig_Enabled** (NONCLUSTERED): is_enabled [includes: server_id, server_name, database_id, database_name, checkdb_enabled, checkdb_run_day, checkdb_run_time, checkalloc_enabled, checkalloc_run_day, checkalloc_run_time, checkcatalog_enabled, checkcatalog_run_day, checkcatalog_run_time, checkconstraints_enabled, checkconstraints_run_day, checkconstraints_run_time, check_mode, replica_override]
  - **UQ_DBCC_ScheduleConfig_DatabaseId** (NONCLUSTERED): database_id

**Check Constraints:**

  - **CK_DBCC_ScheduleConfig_check_mode**: `([check_mode]='FULL' OR [check_mode]='PHYSICAL_ONLY' OR [check_mode]='NONE')`
  - **CK_DBCC_ScheduleConfig_checkalloc_run_day**: `([checkalloc_run_day] IS NULL OR [checkalloc_run_day]>=(1) AND [checkalloc_run_day]<=(7))`
  - **CK_DBCC_ScheduleConfig_checkcatalog_run_day**: `([checkcatalog_run_day] IS NULL OR [checkcatalog_run_day]>=(1) AND [checkcatalog_run_day]<=(7))`
  - **CK_DBCC_ScheduleConfig_checkconstraints_run_day**: `([checkconstraints_run_day] IS NULL OR [checkconstraints_run_day]>=(1) AND [checkconstraints_run_day]<=(7))`
  - **CK_DBCC_ScheduleConfig_checkdb_run_day**: `([checkdb_run_day] IS NULL OR [checkdb_run_day]>=(1) AND [checkdb_run_day]<=(7))`
  - **CK_DBCC_ScheduleConfig_replica_override**: `([replica_override] IS NULL OR ([replica_override]='SECONDARY' OR [replica_override]='PRIMARY'))`

**Foreign Keys:**

  - **FK_DBCC_ScheduleConfig_DatabaseRegistry**: database_id -> dbo.DatabaseRegistry.database_id
  - **FK_DBCC_ScheduleConfig_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Full schedule overview** [sort:1] -- Shows all scheduled operations across all databases with their day and time settings.

```sql
SELECT
    server_name, database_name, is_enabled,
    checkdb_enabled, checkdb_run_day, checkdb_run_time,
    checkalloc_enabled, checkalloc_run_day, checkalloc_run_time,
    checkcatalog_enabled, checkcatalog_run_day, checkcatalog_run_time,
    checkconstraints_enabled, checkconstraints_run_day, checkconstraints_run_time
FROM ServerOps.DBCC_ScheduleConfig
ORDER BY server_name, database_name;
```

**Operations due today** [sort:2] -- Shows which operations are scheduled to run today across all databases.

```sql
DECLARE @today TINYINT = DATEPART(dw, GETDATE());

SELECT
    server_name, database_name,
    CASE WHEN checkdb_enabled = 1 AND checkdb_run_day = @today THEN 'CHECKDB ' + CAST(checkdb_run_time AS VARCHAR(5)) ELSE '-' END AS checkdb,
    CASE WHEN checkalloc_enabled = 1 AND checkalloc_run_day = @today THEN 'CHECKALLOC ' + CAST(checkalloc_run_time AS VARCHAR(5)) ELSE '-' END AS checkalloc,
    CASE WHEN checkcatalog_enabled = 1 AND checkcatalog_run_day = @today THEN 'CHECKCATALOG ' + CAST(checkcatalog_run_time AS VARCHAR(5)) ELSE '-' END AS checkcatalog,
    CASE WHEN checkconstraints_enabled = 1 AND checkconstraints_run_day = @today THEN 'CHECKCONSTRAINTS ' + CAST(checkconstraints_run_time AS VARCHAR(5)) ELSE '-' END AS checkconstraints
FROM ServerOps.DBCC_ScheduleConfig
WHERE is_enabled = 1
ORDER BY server_name, database_name;
```

  - **ServerRegistry**: [sort:1] server_id references dbo.ServerRegistry. The serverops_dbcc_enabled flag on ServerRegistry acts as a server-level master switch — when disabled, all schedule rows for that server are effectively inactive regardless of their own is_enabled setting.
  - **DatabaseRegistry**: [sort:2] database_id references dbo.DatabaseRegistry with a unique constraint ensuring one schedule row per database. Databases must be enrolled in DatabaseRegistry before they can be scheduled for DBCC operations.
  - **DBCC_ExecutionLog**: [sort:3] The script checks ExecutionLog for existing rows today before executing a scheduled operation. If any row exists for the same operation + database + today, the operation is skipped. This prevents duplicate execution across multiple script invocations.


### Execute-DBCC.ps1

Executes scheduled DBCC integrity operations against databases per DBCC_ScheduleConfig. Supports CHECKDB, CHECKALLOC, CHECKCATALOG, and CHECKCONSTRAINTS. In scheduled mode, queries the schedule table for operations due in the current hour and executes them in priority order from lightest to heaviest. In manual override mode (-TargetServer + -Operation), bypasses the schedule table to run a specific operation on demand. Results are logged to DBCC_ExecutionLog with Teams alerting on non-SUCCESS and Jira tickets on CHECKDB corruption.

**Data Flow:** Reads execution options from dbo.GlobalConfig (module ServerOps, category DBCC). In scheduled mode, reads ServerOps.DBCC_ScheduleConfig joined to dbo.ServerRegistry for operations due this hour. In manual mode, reads dbo.ServerRegistry and dbo.DatabaseRegistry for the specified target. For AG listeners, resolves replica roles via sys.dm_hadr_availability_replica_states. Checks database online state via sys.databases on the target server. Executes DBCC commands and writes results to ServerOps.DBCC_ExecutionLog. Queues Teams alerts via Teams.AlertQueue on non-SUCCESS and Jira tickets via Jira.sp_QueueTicket on CHECKDB ERRORS_FOUND. Reports completion to the orchestrator via Complete-OrchestratorTask.

**Schedule-Driven Execution:** [sort:1] The script runs on a configurable interval via ProcessRegistry. Each invocation queries DBCC_ScheduleConfig for operations where the run_day matches today and the run_time hour matches the current hour. If no operations are due, exits NO_WORK immediately. The ExecutionLog is checked before each operation to prevent duplicate execution within the same day.

**Operation Priority Order:** [sort:2] Scheduled operations execute from lightest to heaviest: CHECKCATALOG (seconds), CHECKALLOC (seconds to minutes), CHECKCONSTRAINTS (minutes to hours), CHECKDB (hours). This ensures lightweight checks complete quickly even when a long-running CHECKDB is in the queue.

**Manual Override Mode:** [sort:3] The -TargetServer, -TargetDatabase, and -Operation parameters bypass the schedule table entirely. Manual mode skips the already-executed-today check, allowing re-execution for diagnostic purposes. Server connection details are still resolved from ServerRegistry.

**AG Secondary Execution:** [sort:4] For AG listener entries, the script uses the standard AG topology detection pattern to resolve the current secondary replica. DBCC operations run via a direct connection to the physical secondary. The physical server name is recorded in executed_on_server for accurate history. If the secondary cannot be resolved, the server is skipped with a Teams alert.

  - **DBCC_ScheduleConfig**: [sort:1] Primary input for scheduled mode. The script queries this table for enabled operations matching the current day and hour, joined to ServerRegistry for the server-level master switch.
  - **DBCC_ExecutionLog**: [sort:2] Primary output. One row inserted per database per operation at start (IN_PROGRESS), updated on completion with status, duration, and error details. Also checked before execution to prevent duplicate runs today.
  - **GlobalConfig**: [sort:3] Reads DBCC execution options at startup: checkdb_mode, max_dop, extended_logical_checks, alerting_enabled. AG topology settings (AGName, SourceReplica) are also loaded from GlobalConfig.



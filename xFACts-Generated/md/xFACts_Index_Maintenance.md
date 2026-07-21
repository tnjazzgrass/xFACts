# Index Maintenance

*Rebuilding indexes without stepping on production — the database equivalent of changing a tire at 60 mph*

Databases have indexes — think of them as the table of contents that makes looking things up fast instead of slow. Over time they get messy. Index Maintenance finds the messy ones, figures out which ones matter most, and fixes them overnight while nobody's using the system.






The Problem

Imagine a phone book. When it's new, everything's in order and finding a name takes seconds. Now imagine someone shuffles 30% of the pages. You can still find what you need, but it takes a lot longer. That's what happens to database indexes over time — normal daily activity gradually scrambles the internal structure until queries that used to be fast start getting slow.

The traditional fix is a maintenance plan: "rebuild everything Sunday night." Which works great until you have dozens of databases and the maintenance window isn't long enough. Or until a rebuild runs into Monday morning and suddenly the applications are competing with maintenance for resources. Or until someone forgets to add the new database to the maintenance plan and it goes six months without any attention at all.

Index Maintenance replaces the "rebuild everything and hope for the best" approach with something smarter. It figures out which indexes actually need work, puts them in order of importance, and only does the work during hours when nobody's using the system. If it runs out of time on Tuesday night, the big ones wait for the weekend. Nothing gets lost, nothing gets forgotten, and nothing runs into production.






How It Works



Find All
Indexes
→
Check Which
Need Work
→
Prioritize
& Queue
→
Rebuild During
Safe Hours
→
Refresh
Statistics

A pipeline that builds on itself — you can't fix what you haven't checked, and you can't check what you haven't found


First, every index across every enrolled database gets cataloged — a quick pass that finds new ones and notes any that have been removed. Then the deeper check: actually measuring how disorganized each index has gotten, which takes longer but gives the real picture.

The ones that need attention get queued up, ranked by how important the database is and how badly the index needs fixing. Then the rebuild phase works through the queue during safe hours, checking the clock before every single operation. If the maintenance window closes mid-batch, it stops immediately rather than running into business hours.






Smart Scheduling

The trickiest part isn't the rebuilding — it's knowing *when* you're allowed to rebuild. The answer depends on which database, which day, and whether anything unusual is happening.

If there's a deployment freeze, a month-end close, or a server maintenance window, those take priority and maintenance stands down. If it's a holiday and the office is empty, the system takes advantage of the extra time. Otherwise, the normal per-database schedule applies. All of this gets checked in real time, so you can freeze a single database without affecting anything else.

Weekdays are the tight windows. When time is limited, the system fits in as much useful work as possible — skipping the big jobs to squeeze in smaller ones, like packing a suitcase. Weekends and holidays are when the big ones finally get their turn. They've been waiting patiently all week, and now there's room.






Nothing Gets Forgotten

The priority system makes sure every index eventually gets its turn. Important databases go first, but indexes that keep getting passed over get an automatic boost each time. Eventually they rise high enough in the queue to get selected. No index is permanently ignored.






The Control Center View

The Index Maintenance page in the Control Center shows the state of the entire pipeline at a glance — what's queued, what's in progress, and what finished recently.






The Bottom Line

The best index maintenance is the kind nobody notices. Queries stay fast. The system handles the messy work overnight. The weekend run finishes the big jobs that accumulated during the week. And nobody gets paged at 7 AM because a maintenance job ran into production hours.

That's the goal. Let the system worry about it so you don't have to.

---

# Index Maintenance — Control Center Guide

---

## Architecture
# Index Maintenance Architecture

The narrative page tells you *what* Index Maintenance does and *why*. This page tells you *how*. Ten tables, two stored procedures, five PowerShell scripts, and a shared function library that manage the entire lifecycle of index maintenance across every enrolled database — from discovery through fragmentation scanning, priority-based rebuild execution, and targeted statistics updates.



Schema Overview

The Index component has the largest table footprint in ServerOps. That's because it manages three distinct concerns: *configuration* (what gets maintained, when, and how aggressively), *state* (what's fragmented, what's queued, what's in progress), and *history* (what happened, how long it took, and whether the estimates were right).



| Table | Role | Cardinality |
| --- | --- | --- |
| `Index_DatabaseConfig` | Per-database enrollment and feature flags | One per monitored database |
| `Index_DatabaseSchedule` | Default maintenance windows (24-hour × 7-day grid) | Seven per database (one per day of week) |
| `Index_HolidaySchedule` | Holiday maintenance windows | One per database |
| `Index_ExceptionSchedule` | Ad-hoc overrides for specific dates | Many per date/scope combination |
| `Index_Registry` | Central catalog of all tracked indexes | Many per database (one per index) |
| `Index_Queue` | Pending rebuild operations with priority scores | Many per database (indexes above threshold) |
| `Index_ExecutionLog` | Per-index rebuild execution details | Many per database over time |
| `Index_ExecutionSummary` | Per-database, per-run summary records | Many per process per run |
| `Index_StatsExecutionLog` | Statistics update execution details | Many per database over time |
| `Index_Status` | At-a-glance status for each process | Fixed: one row per process type |



Configuration vs. Scheduling vs. Execution. The four configuration tables (DatabaseConfig, DatabaseSchedule, HolidaySchedule, ExceptionSchedule) define the rules. Index_Registry and Index_Queue represent current state. The three execution log tables record history. This separation means you can change scheduling rules without affecting the queue, and queue state doesn't pollute execution history.







The Four Phases

Index maintenance operates as a pipeline with four phases, each handled by a dedicated script. The phases build on each other — you can't scan what hasn't been discovered, and you can't rebuild what hasn't been scanned.





Phase 1: Sync
Discover indexes
Refresh metadata
Mark dropped

→

Phase 2: Scan
Measure fragmentation
Manage queue
Calculate priority

→

Phase 3: Execute
Window-aware rebuilds
Best-fit selection
Continuous claiming

→

Phase 4: Stats
Targeted updates
Modification-based
Staleness-based


Each phase has a dedicated script. Sync and Stats run frequently; Scan runs on a configurable interval; Execute runs during maintenance windows.


Phase 1: Discovery (Sync)

`Sync-IndexRegistry.ps1` is the "cheap pass." It connects to each enrolled database and queries `sys.indexes`, `sys.dm_db_partition_stats`, and `sys.dm_db_index_usage_stats` to collect index metadata. New indexes are inserted into `Index_Registry`. Existing entries get refreshed metadata (page count, fill factor, usage statistics). Indexes that exist in the registry but not in the source are marked `is_dropped = 1`.

This phase deliberately avoids fragmentation scanning. Querying `sys.indexes` and usage DMVs is lightweight — it completes in seconds per database. Fragmentation scanning via `sys.dm_db_index_physical_stats` can take 30–60 minutes for large databases. Separating the two means you get frequent discovery without frequent fragmentation cost.


Replication system table exclusion. The sync script excludes known replication system tables by name (`sysarticles`, `sysschemaarticles`, etc.) and by pattern (`MSpeer_%`, `MSpub_%`). These have system-managed indexes that should never be touched by automated maintenance.


Phase 2: Scanning & Queue Population

`Scan-IndexFragmentation.ps1` is the "expensive pass." It queries `sys.dm_db_index_physical_stats` in `LIMITED` mode for each candidate index, updates `Index_Registry` with the current fragmentation percentage, and manages the `Index_Queue` as a living queue — adding indexes that exceed thresholds, updating existing entries, and removing entries that no longer qualify.

Candidates are selected from the registry with filters: not dropped, not excluded, above the minimum page count, not scanned recently (rescan interval), and not rebuilt recently (skip-rebuilt days). Each fragmentation query gets a scaled timeout: base seconds + (page count / pages per second). This prevents small indexes from waiting too long while giving large indexes adequate time.

The script supports both a configurable time limit and an abort flag in GlobalConfig. Both enable graceful termination of long-running scans, preserving all work completed before the stop.

Phase 3: Rebuild Execution

`Execute-IndexMaintenance.ps1` processes the queue during maintenance windows. Before each database, it evaluates the three-tier schedule hierarchy to confirm the window is open. Before each individual index, it re-evaluates the schedule — if the window closes mid-batch, processing stops gracefully.

The script uses a continuous work-claiming loop: after completing a batch of indexes, it re-queries the queue for more work if time remains. This maximizes throughput during long windows instead of processing one batch and exiting.

Each rebuild follows a strict sequence: claim the queue entry (set `IN_PROGRESS`), log the pre-rebuild state to `Index_ExecutionLog`, execute `ALTER INDEX REBUILD`, scan post-rebuild fragmentation, calculate estimate variance, update the execution log, update `Index_Registry`, and delete the queue entry. If the rebuild fails, the queue entry is marked `FAILED` with an incremented deferral count.


Edition-aware online/offline. The `online_option` on each queue entry respects the database's `index_allow_offline_rebuild` setting. But if the SQL Server edition is not Enterprise, the script overrides to OFFLINE regardless — online rebuilds require Enterprise Edition. The override is noted in the execution log for transparency.


Phase 4: Statistics Maintenance

`Update-IndexStatistics.ps1` runs independently from index rebuilds. It queries `sys.dm_db_stats_properties` for modification counters and evaluates each statistic against two criteria: modification threshold (percentage of rows modified) and staleness threshold (days since last update). Both thresholds are configurable via GlobalConfig.

Statistics exceeding the modification threshold are updated individually and logged with full details (table, stat name, row count, modification counter, percentage modified). Stale statistics are updated in batch and logged as one cumulative row per database — this avoids flooding the log with hundreds of low-value "it was old" entries.


~2% vs 100%. Traditional statistics maintenance updates all statistics weekly regardless of need. The targeted approach typically finds only ~2% of statistics need updating on any given run, completing in seconds instead of minutes. Modification-based updates catch actively changing data; staleness-based updates catch distribution drift.







Scheduling Hierarchy

Not all maintenance windows are created equal. The system evaluates three layers of schedule configuration in strict priority order, stopping at the first match:







Exception
DATABASE scope
↓ SERVER scope
↓ GLOBAL scope

→

Holiday
Is today a holiday?
Does this DB have
a holiday schedule?

→

Default
DatabaseSchedule
7 rows per DB
(one per weekday)

→

Result
24 hourly slots
allowed / blocked



First match wins. Exception overrides Holiday overrides Default. All three use the same 24-bit hourly structure.


| Priority | Schedule Type | Table | Example Use Case |
| --- | --- | --- | --- |
| 1 (highest) | Exception — DATABASE scope | `Index_ExceptionSchedule` | "Don't touch crs5_oltp Saturday — we have a release" |
| 2 | Exception — SERVER scope | `Index_ExceptionSchedule` | "Freeze all maintenance on DM-PROD-DB this weekend" |
| 3 | Exception — GLOBAL scope | `Index_ExceptionSchedule` | "No maintenance anywhere during month-end close" |
| 4 | Holiday | `dbo.Holiday` + `Index_HolidaySchedule` | Extended windows on holidays (offices empty, indexes happy) |
| 5 (lowest) | Database default | `Index_DatabaseSchedule` | Regular weekday/weekend maintenance windows |


All three schedule types use the same data structure: 24 bit columns (`hr00` through `hr23`) where 1 = allowed and 0 = blocked. `Get-EffectiveSchedule` in `xFACts-IndexFunctions.ps1` evaluates the hierarchy and returns a simple yes/no for the current hour.

Extended Windows

Weekends and holidays qualify as "extended window" days. This triggers a special behavior in `Execute-IndexMaintenance.ps1`: at startup, all `SCHEDULED` indexes (those too large for any weekday window) are reset to `PENDING` and become eligible for processing. This is the primary mechanism for handling large indexes that accumulate during the work week.


Holiday detection is a two-table check. `dbo.Holiday` defines which dates are holidays (shared across the platform). `Index_HolidaySchedule` defines per-database maintenance hours on those dates. Adding a new holiday only requires one Holiday row — all databases automatically get their existing HolidaySchedule applied.







Priority Scoring

Not all fragmented indexes are equal. A heavily fragmented 10-million-page index on the primary OLTP database matters more than a mildly fragmented 5,000-page index on a reporting database. The priority scoring system quantifies this.

Each queued index receives a score from four weighted components. All weights and tier boundaries are configurable via GlobalConfig (module `ServerOps`, category `Index`):

| Component | Factor | Tiers | Points |
| --- | --- | --- | --- |
| **Database Priority** | How critical is this database? | Priority 1 / 2 / 3 | 40 / 25 / 15 |
| **Fragmentation Severity** | How fragmented is this index? | Low / Medium / High | 10 / 15 / 20 |
| **Index Size** | How large is this index? | Small / Medium / Large | 10 / 20 / 30 |
| **Deferral Count** | How many times has this been skipped? | None / Some / Above threshold | 0 / 5 / 10 |


Maximum possible score: **100**. A priority-1 database with a huge, heavily fragmented index that's been deferred multiple times gets the full score and goes to the front of the line.

The deferral component is the anti-starvation mechanism. Without it, large indexes on low-priority databases could be perpetually skipped by smaller, higher-priority work. Each time an index is evaluated but doesn't fit in the remaining window, its deferral count increments and its priority score increases. Eventually it rises high enough to be selected.


Calculate-PriorityScore lives in Scan-IndexFragmentation.ps1 (defined inline, not in the shared function library). It reads all tier boundaries and point values from GlobalConfig at script startup, so adjusting the scoring model requires zero code changes — just update the config rows.







The Living Queue

The `Index_Queue` is not a static work list. It's a living reflection of what actually needs work right now. Indexes are added when they exceed thresholds, updated when rescanned, and automatically removed if they drop below threshold. If someone manually rebuilds an index, it drops off the queue on the next scan.

Status Transitions







PENDING
Awaiting
processing

→

IN_PROGRESS
Rebuild
running

→

Deleted
Success → removed
History in ExecutionLog






DEFERRED
Didn't fit in
remaining window

↑ reset to PENDING next run



SCHEDULED
Too large for any
weekday window

↑ reset to PENDING on extended days



FAILED
Rebuild error
Deferral count +1

↑ reset to PENDING next run



Success deletes the entry. All other terminal states reset to PENDING on the next applicable run. Below-threshold indexes are removed by the scanner.


| Status | Meaning | Set By |
| --- | --- | --- |
| `PENDING` | Awaiting processing | Scan (new entry), Execute (reset from DEFERRED/FAILED at startup) |
| `IN_PROGRESS` | Currently being rebuilt | Execute (before ALTER INDEX) |
| `DEFERRED` | Didn't fit in remaining window | Execute (best-fit algorithm skip) |
| `SCHEDULED` | Too large for any weekday window | Execute (exceeds max weekday window) |
| `FAILED` | Rebuild attempt failed | Execute (after error) |


On success, the queue entry is **deleted**, not status-updated. The history lives in `Index_ExecutionLog`. The queue only contains work that still needs to be done.

Best-Fit vs. Priority Selection

`Get-IndexesForWindow` in `xFACts-IndexFunctions.ps1` implements different selection strategies based on window type:

| Window Type | Algorithm | Rationale |
| --- | --- | --- |
| Weekday | Best-fit: iterate by priority, select indexes that fit, skip larger ones to try smaller ones | Maximize throughput in limited windows |
| Extended (weekend/holiday) | Straight priority order, including SCHEDULED indexes | Time is plentiful; process everything in importance order |



SCHEDULED indexes are the weekday overflow mechanism. When Get-IndexesForWindow finds an index whose estimated duration exceeds the largest contiguous weekday window (calculated by `Get-MaxWeekdayWindow`), it marks it SCHEDULED rather than repeatedly deferring it. SCHEDULED indexes are only eligible on extended window days, which is the designed mechanism for handling large indexes that accumulate during the week. If a SCHEDULED index doesn't fit even in an extended window, its deferral count is incremented to boost its priority for next time.







Statistics Maintenance

Statistics maintenance runs independently from index rebuilds on its own schedule. While index rebuilds automatically update statistics on the rebuilt index, indexes that don't need rebuilding can still develop stale statistics.

Two Update Strategies

| Strategy | Trigger | Logging | Purpose |
| --- | --- | --- | --- |
| **Modification-based** | modification_counter ≥ threshold % of rows | Individual row per statistic | Catch actively changing data |
| **Staleness-based** | Last update ≥ threshold days ago | One cumulative row per database | Catch distribution drift |


The dual logging strategy reflects the operational value of each update type. Modification-based updates are interesting — they tell you which tables are changing rapidly, how much, and how often. Staleness-based updates are routine housekeeping. Logging hundreds of individual "it was old, now it's not" entries would flood the table with noise.


Per-database sample rate override. `stats_sample_pct` in `Index_DatabaseConfig` overrides the GlobalConfig default. A value of 0 means FULLSCAN. Critical databases with skewed distributions can use full scans while less critical databases use sampling for speed.







Troubleshooting

**"Indexes aren't being rebuilt."**
Check the chain: Is `Index_DatabaseConfig.index_maintenance_enabled = 1`? Is `ServerRegistry.serverops_index_enabled = 1`? Is the scan running (check `Index_Status` for the SCAN process)? Is the queue populated (`SELECT COUNT(*) FROM ServerOps.Index_Queue`)? Is the schedule allowing maintenance right now (check `Index_DatabaseSchedule` for the current day/hour)?

**"The scan is taking forever."**
`sys.dm_db_index_physical_stats` is inherently expensive — it reads physical pages. Large databases with thousands of indexes can take 30–60 minutes. If it's running longer than expected, check whether the time limit is configured in GlobalConfig. You can also set the abort flag in GlobalConfig — the script checks it periodically and stops cleanly.

**"An index keeps showing up as FAILED."**
Check `Index_ExecutionLog` for the error message. Common causes: lock timeout during rebuild (someone's running a long query), online rebuild not supported (Standard Edition forces offline, but the index might require online), or the database is in a state that doesn't allow DDL. If an index fails repeatedly, consider excluding it (`Index_Registry.is_excluded = 1`) and investigating separately.

**"Huge indexes never get rebuilt."**
They're probably marked `SCHEDULED` in the queue — meaning they don't fit in any weekday window. They'll be processed on the next weekend or holiday when extended windows apply. Check `Index_Queue WHERE status = 'SCHEDULED'`. If they're not getting done even on weekends, the extended window might not be long enough, or the schedule might be more restrictive than expected.

**"Statistics are being updated but queries are still slow."**
Check whether the sample rate is appropriate. Small sample rates on skewed distributions can produce misleading statistics. The per-database override (`Index_DatabaseConfig.stats_sample_pct`) can be set to 0 for a FULLSCAN on critical databases. Also verify that the right statistics are being updated — the script only processes index-associated statistics, not manually created ones.






How Everything Connects

Internal Flow

| From | To | Relationship |
| --- | --- | --- |
| `Index_DatabaseConfig` | All scripts | Feature flags and per-database overrides control which scripts process which databases |
| `Index_Registry` | `Index_Queue` | Queue entries reference registry_id; registry provides scan data that determines queuing |
| `Index_Queue` | `Index_ExecutionLog` | Each rebuild operation logs pre/post state, duration, and variance |
| `Index_Registry` | `Index_StatsExecutionLog` | Registry provides the index list; stats log records each update |
| Schedule tables | `xFACts-IndexFunctions.ps1` | ExceptionSchedule, HolidaySchedule, and DatabaseSchedule evaluated in priority order |


External Dependencies

| Dependency | Module | Purpose |
| --- | --- | --- |
| `dbo.ServerRegistry` | Engine Room | Server-level master switch (`serverops_index_enabled`) and AG topology |
| `dbo.DatabaseRegistry` | Engine Room | Database enrollment and active status |
| `dbo.GlobalConfig` | Engine Room | All thresholds, intervals, scoring weights, abort flags, seconds-per-page coefficients |
| `dbo.Holiday` | Engine Room | Holiday calendar for extended window detection |
| `sys.dm_db_index_physical_stats` | SQL Server | Fragmentation data (expensive; LIMITED mode) |
| `sys.dm_db_stats_properties` | SQL Server | Modification counters for targeted statistics updates |

---

## Reference

### Index_DatabaseConfig

Per-database configuration for index rebuild/reorganize maintenance and statistics updates. Stores priority, thresholds, offline rebuild permissions, and maintenance enablement flags for each enrolled database.

**Data Flow:** Rows are manually inserted per database during enrollment. Sync-IndexRegistry.ps1 reads index_sync_enabled to filter target databases and respects the server-level master switch (ServerRegistry.serverops_index_enabled). Scan-IndexFragmentation.ps1 reads index_maintenance_enabled, index_fragmentation_threshold, index_min_page_count, index_allow_offline_rebuild, and index_maintenance_priority to apply per-database overrides during scanning and queue population. Execute-IndexMaintenance.ps1 reads index_maintenance_priority and index_allow_offline_rebuild for work selection and rebuild mode decisions. Update-IndexStatistics.ps1 reads stats_maintenance_enabled and stats_sample_pct for per-database statistics processing.

**Three Independent Feature Flags:** [sort:1] index_sync_enabled controls whether indexes are cataloged in Index_Registry (prerequisite for everything). stats_maintenance_enabled controls statistics updates. index_maintenance_enabled controls fragmentation scanning and index rebuilds. This allows progressive enrollment: catalog first, then enable stats, then enable rebuilds — each independently togglable.

**Per-Database Threshold Overrides:** [sort:2] index_fragmentation_threshold, index_min_page_count, and index_scan_interval_minutes are nullable — when NULL, the script uses GlobalConfig defaults. This provides sensible defaults with opt-in per-database customization. A large OLTP database might use a higher page count minimum to skip tiny indexes, while a smaller database might lower the fragmentation threshold for tighter maintenance.

**Priority-Based Scheduling:** [sort:3] index_maintenance_priority (1-3) drives two behaviors: priority scoring in the queue (higher priority databases get higher scores) and execution ordering (priority 1 databases are processed before priority 2 and 3). This ensures critical production databases get maintenance attention first when time is limited.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| database_config_id (IDENTITY) | int | No | IDENTITY | Identity primary key. |
| database_id | int | No | — | PK and FK to dbo.DatabaseRegistry.database_id |
| index_sync_enabled | bit | No | 0 | Whether database indexes are cataloged in Index_Registry. Prerequisite for index and stats maintenance |
| index_maintenance_enabled | bit | No | 0 | Whether index rebuild/reorganize maintenance is enabled |
| stats_maintenance_enabled | bit | No | 0 | Whether statistics maintenance is enabled for this database |
| index_maintenance_priority | int | No | 3 | Priority tier for maintenance scoring: 1=Critical (40 pts), 2=High (25 pts), 3=Normal (15 pts) |
| index_allow_offline_rebuild | bit | No | 0 | Whether offline rebuilds are permitted (0 = ONLINE only) |
| index_fragmentation_threshold | decimal(5,2) | Yes | — | Override fragmentation threshold (NULL = use global default) |
| index_min_page_count | int | Yes | — | Override minimum page count (NULL = use global default) |
| index_scan_interval_minutes | int | Yes | — | Override scan frequency in minutes (NULL = use global default) |
| stats_sample_pct | tinyint | Yes | — | Override sample percentage for UPDATE STATISTICS (NULL = use global default, 0 = FULLSCAN) |
| created_dttm | datetime | No | getdate() | When the configuration was created |
| created_by | varchar(100) | No | suser_sname() | Who created the configuration |
| modified_dttm | datetime | Yes | — | When the configuration was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified the configuration |

  - **PK_DatabaseConfig** (CLUSTERED): database_config_id -- PRIMARY KEY
  - **UQ_DatabaseConfig_DatabaseId** (NONCLUSTERED): database_id

**Check Constraints:**

  - **CK_DatabaseConfig_IndexMaintenancePriority**: `([index_maintenance_priority]=(3) OR [index_maintenance_priority]=(2) OR [index_maintenance_priority]=(1))`

**Foreign Keys:**

  - **FK_DatabaseConfig_DatabaseRegistry**: database_id -> dbo.DatabaseRegistry.database_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| index_maintenance_priority | 1 | Highest priority. Critical production databases. Receives the highest priority score component (default 40 points) and is processed first during execution. | 1 |
| index_maintenance_priority | 2 | Standard priority. Normal production databases. Receives a mid-range priority score component (default 25 points). | 2 |
| index_maintenance_priority | 3 | Lowest priority. Low-activity or non-critical databases. Receives the lowest priority score component (default 15 points). Also the default if not explicitly set. | 3 |

**Enrollment overview** [sort:1] -- Shows all enrolled databases with their feature flags and threshold overrides.

```sql
SELECT
    dr.database_name,
    sr.server_name,
    dc.index_sync_enabled,
    dc.index_maintenance_enabled,
    dc.stats_maintenance_enabled,
    dc.index_maintenance_priority,
    dc.index_allow_offline_rebuild,
    dc.index_fragmentation_threshold,
    dc.index_min_page_count,
    dc.stats_sample_pct
FROM ServerOps.Index_DatabaseConfig dc
JOIN dbo.DatabaseRegistry dr ON dc.database_id = dr.database_id
JOIN dbo.ServerRegistry sr ON dr.server_id = sr.server_id
ORDER BY sr.server_name, dc.index_maintenance_priority, dr.database_name;
```

  - **dbo.DatabaseRegistry**: [sort:1] Each row references a database_id from DatabaseRegistry. A database must be active in DatabaseRegistry (is_active = 1) and have a DatabaseConfig row with the appropriate feature flag enabled for any Index component script to process it.
  - **dbo.ServerRegistry**: [sort:2] ServerRegistry.serverops_index_enabled acts as a server-level master switch. Even if a database has all feature flags enabled in DatabaseConfig, no Index scripts will process it if the server's master switch is disabled. This allows emergency shutdown of all index maintenance on a server without touching individual database configurations.


### Index_DatabaseSchedule

Per-database default maintenance schedules defining allowed and blocked hours for each day of the week. Each database enrolled in index maintenance has 7 rows (one per day) with 24 hourly columns representing the weekly schedule template.

**Data Flow:** Rows are created by sp_Index_AddDatabaseSchedule during enrollment (7 rows per database, one per day of week). xFACts-IndexFunctions.ps1 reads this table via Get-EffectiveSchedule to determine whether the current hour is allowed for index maintenance. Get-MaxWeekdayWindow queries Monday through Friday rows to find the largest contiguous allowed block, which determines whether an index is too large for any weekday window (marking it SCHEDULED for weekend/holiday processing).

**Hourly Bit Grid:** [sort:1] Each row represents one day of the week with 24 bit columns (hr00 through hr23). A value of 1 means maintenance is allowed during that hour; 0 means blocked. This denormalized design enables single-row lookups for schedule checks — no joins, no pivots, and no interpretation needed. sp_Index_AddDatabaseSchedule generates these from simple block range parameters.

**Lowest Priority in Schedule Hierarchy:** [sort:2] This is the fallback schedule, checked only after Exception and Holiday schedules. Execute-IndexMaintenance.ps1 evaluates Exception (DATABASE ? SERVER ? GLOBAL scope) first, then Holiday (weekdays only, via dbo.Holiday + Index_HolidaySchedule), then DatabaseSchedule. This allows ad-hoc overrides without modifying the baseline schedule.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| database_id | int | No | — | FK to dbo.DatabaseRegistry.database_id |
| day_of_week | tinyint | No | — | 1=Sunday, 2=Monday, ..., 7=Saturday |
| hr00 | bit | No | 1 | Midnight to 1am |
| hr01 | bit | No | 1 | 1am to 2am |
| hr02 | bit | No | 1 | 2am to 3am |
| hr03 | bit | No | 1 | 3am to 4am |
| hr04 | bit | No | 1 | 4am to 5am |
| hr05 | bit | No | 1 | 5am to 6am |
| hr06 | bit | No | 1 | 6am to 7am |
| hr07 | bit | No | 1 | 7am to 8am |
| hr08 | bit | No | 1 | 8am to 9am |
| hr09 | bit | No | 1 | 9am to 10am |
| hr10 | bit | No | 1 | 10am to 11am |
| hr11 | bit | No | 1 | 11am to noon |
| hr12 | bit | No | 1 | Noon to 1pm |
| hr13 | bit | No | 1 | 1pm to 2pm |
| hr14 | bit | No | 1 | 2pm to 3pm |
| hr15 | bit | No | 1 | 3pm to 4pm |
| hr16 | bit | No | 1 | 4pm to 5pm |
| hr17 | bit | No | 1 | 5pm to 6pm |
| hr18 | bit | No | 1 | 6pm to 7pm |
| hr19 | bit | No | 1 | 7pm to 8pm |
| hr20 | bit | No | 1 | 8pm to 9pm |
| hr21 | bit | No | 1 | 9pm to 10pm |
| hr22 | bit | No | 1 | 10pm to 11pm |
| hr23 | bit | No | 1 | 11pm to midnight |
| created_dttm | datetime | No | getdate() | When this schedule was created |
| created_by | varchar(128) | No | suser_sname() | Who created this schedule |
| modified_dttm | datetime | Yes | — | When this schedule was last modified |
| modified_by | varchar(128) | Yes | — | Who last modified this schedule |

  - **PK_DatabaseSchedule** (CLUSTERED): database_id, day_of_week -- PRIMARY KEY

**Check Constraints:**

  - **CK_DatabaseSchedule_DayOfWeek**: `([day_of_week]>=(1) AND [day_of_week]<=(7))`

**Foreign Keys:**

  - **FK_DatabaseSchedule_DatabaseRegistry**: database_id -> dbo.DatabaseRegistry.database_id

  - **sp_Index_AddDatabaseSchedule**: [sort:1] The proc generates all 7 rows from simple parameters (weekday block start/end, weekend block start/end, optional Sunday override). Existing rows must be deleted before re-initialization — the proc validates no rows exist for the database.
  - **Index_ExceptionSchedule**: [sort:2] Exception overrides take priority over DatabaseSchedule. If an exception row exists for today's date at any scope (DATABASE, SERVER, GLOBAL), it completely replaces the DatabaseSchedule for that hour. This is evaluated in Get-EffectiveSchedule before DatabaseSchedule is checked.


### Index_ExceptionSchedule

Ad-hoc maintenance window exceptions with hierarchical scope (DATABASE ? SERVER ? GLOBAL). Provides one-time overrides to normal schedules and holidays, allowing temporary adjustment of maintenance windows without modifying recurring schedules.

**Data Flow:** Rows are manually inserted for planned events (deployments, emergency freezes, special maintenance windows). xFACts-IndexFunctions.ps1 reads this table first in the Get-EffectiveSchedule hierarchy, checking DATABASE scope, then SERVER scope, then GLOBAL scope. The first match at any scope determines whether the hour is allowed — no further schedule tables are consulted.

**Three-Scope Hierarchy with Constraint Enforcement:** [sort:1] The scope column (GLOBAL, SERVER, DATABASE) determines which resources are affected. CHECK constraints enforce referential consistency: DATABASE scope requires database_id and NULL server_id, SERVER scope requires server_id and NULL database_id, GLOBAL scope requires both NULL. The evaluation order (DATABASE ? SERVER ? GLOBAL) means a database-specific exception overrides a server-wide freeze, which overrides a global block.

**Same Hourly Bit Grid as DatabaseSchedule:** [sort:2] Uses the same hr00-hr23 bit column pattern as DatabaseSchedule and HolidaySchedule. A value of 1 means maintenance is allowed during that hour; 0 means blocked. An EMERGENCY_BLOCK exception with all hours set to 0 completely prevents maintenance for the specified date and scope.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| exception_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the exception |
| exception_date | date | No | — | The calendar date this exception applies to |
| exception_name | varchar(200) | No | — | Short name identifying this exception |
| exception_type | varchar(50) | No | — | MAINTENANCE_WINDOW, EMERGENCY_BLOCK, or SPECIAL_EVENT |
| scope | varchar(20) | No | — | DATABASE, SERVER, or GLOBAL |
| server_id | int | Yes | — | FK to dbo.ServerRegistry (required for SERVER scope) |
| database_id | int | Yes | — | FK to dbo.DatabaseRegistry (required for DATABASE scope) |
| hr00 | bit | No | 1 | Midnight to 1am |
| hr01 | bit | No | 1 | 1am to 2am |
| hr02 | bit | No | 1 | 2am to 3am |
| hr03 | bit | No | 1 | 3am to 4am |
| hr04 | bit | No | 1 | 4am to 5am |
| hr05 | bit | No | 1 | 5am to 6am |
| hr06 | bit | No | 1 | 6am to 7am |
| hr07 | bit | No | 1 | 7am to 8am |
| hr08 | bit | No | 1 | 8am to 9am |
| hr09 | bit | No | 1 | 9am to 10am |
| hr10 | bit | No | 1 | 10am to 11am |
| hr11 | bit | No | 1 | 11am to noon |
| hr12 | bit | No | 1 | Noon to 1pm |
| hr13 | bit | No | 1 | 1pm to 2pm |
| hr14 | bit | No | 1 | 2pm to 3pm |
| hr15 | bit | No | 1 | 3pm to 4pm |
| hr16 | bit | No | 1 | 4pm to 5pm |
| hr17 | bit | No | 1 | 5pm to 6pm |
| hr18 | bit | No | 1 | 6pm to 7pm |
| hr19 | bit | No | 1 | 7pm to 8pm |
| hr20 | bit | No | 1 | 8pm to 9pm |
| hr21 | bit | No | 1 | 9pm to 10pm |
| hr22 | bit | No | 1 | 10pm to 11pm |
| hr23 | bit | No | 1 | 11pm to midnight |
| is_enabled | bit | No | 1 | Whether this exception is currently active |
| notes | varchar(1000) | Yes | — | Business reason or additional context for this exception |
| created_dttm | datetime | No | getdate() | When this exception was created |
| created_by | varchar(128) | No | suser_sname() | Who created this exception |
| modified_dttm | datetime | Yes | — | When this exception was last modified |
| modified_by | varchar(128) | Yes | — | Who last modified this exception |

  - **PK_ExceptionSchedule** (CLUSTERED): exception_id -- PRIMARY KEY
  - **IX_Maintenance_Exception_Schedule_Date** (NONCLUSTERED): scope, server_id, database_id, exception_date, is_enabled

**Check Constraints:**

  - **CK_ExceptionSchedule_DatabaseScope**: `([scope]='DATABASE' AND [database_id] IS NOT NULL AND [server_id] IS NULL OR [scope]<>'DATABASE')`
  - **CK_ExceptionSchedule_GlobalScope**: `([scope]='GLOBAL' AND [server_id] IS NULL AND [database_id] IS NULL OR [scope]<>'GLOBAL')`
  - **CK_ExceptionSchedule_Scope**: `([scope]='DATABASE' OR [scope]='SERVER' OR [scope]='GLOBAL')`
  - **CK_ExceptionSchedule_ServerScope**: `([scope]='SERVER' AND [server_id] IS NOT NULL AND [database_id] IS NULL OR [scope]<>'SERVER')`
  - **CK_ExceptionSchedule_Type**: `([exception_type]='SPECIAL_EVENT' OR [exception_type]='EMERGENCY_BLOCK' OR [exception_type]='MAINTENANCE_WINDOW')`

**Foreign Keys:**

  - **FK_ExceptionSchedule_DatabaseRegistry**: database_id -> dbo.DatabaseRegistry.database_id
  - **FK_ExceptionSchedule_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| scope | DATABASE | Applies to a single database. Requires database_id to be populated and server_id to be NULL. Checked first in the hierarchy — overrides SERVER and GLOBAL exceptions. | 1 |
| exception_type | MAINTENANCE_WINDOW | A planned expanded or modified maintenance window. Typically opens additional hours for index rebuilds. | 1 |
| exception_type | EMERGENCY_BLOCK | An emergency freeze blocking all maintenance. Typically used during incidents, unexpected load, or deployment issues. All hr columns set to 0. | 2 |
| scope | SERVER | Applies to all databases on a specific server. Requires server_id to be populated and database_id to be NULL. Checked second — overrides GLOBAL exceptions but yields to DATABASE exceptions. | 2 |
| scope | GLOBAL | Applies to all databases across all servers. Requires both server_id and database_id to be NULL. Checked last — yields to SERVER and DATABASE exceptions. | 3 |
| exception_type | SPECIAL_EVENT | A known event requiring schedule adjustment (deployment, migration, audit). May block certain hours while opening others. | 3 |

**Active exceptions for the next 7 days** [sort:1] -- Shows upcoming exceptions that will affect maintenance scheduling.

```sql
SELECT
    exception_date,
    exception_name,
    exception_type,
    scope,
    COALESCE(sr.server_name, 'ALL') AS server_name,
    COALESCE(dr.database_name, 'ALL') AS database_name,
    (CAST(hr00 AS INT)+CAST(hr01 AS INT)+CAST(hr02 AS INT)+CAST(hr03 AS INT)+
     CAST(hr04 AS INT)+CAST(hr05 AS INT)+CAST(hr06 AS INT)+CAST(hr07 AS INT)+
     CAST(hr08 AS INT)+CAST(hr09 AS INT)+CAST(hr10 AS INT)+CAST(hr11 AS INT)+
     CAST(hr12 AS INT)+CAST(hr13 AS INT)+CAST(hr14 AS INT)+CAST(hr15 AS INT)+
     CAST(hr16 AS INT)+CAST(hr17 AS INT)+CAST(hr18 AS INT)+CAST(hr19 AS INT)+
     CAST(hr20 AS INT)+CAST(hr21 AS INT)+CAST(hr22 AS INT)+CAST(hr23 AS INT)) AS allowed_hours
FROM ServerOps.Index_ExceptionSchedule es
LEFT JOIN dbo.ServerRegistry sr ON es.server_id = sr.server_id
LEFT JOIN dbo.DatabaseRegistry dr ON es.database_id = dr.database_id
WHERE es.exception_date >= CAST(GETDATE() AS DATE)
  AND es.exception_date < DATEADD(DAY, 7, CAST(GETDATE() AS DATE))
  AND es.is_enabled = 1
ORDER BY es.exception_date, es.scope;
```


### Index_ExecutionLog

Per-index execution detail for Index component rebuild operations. Captures timing, variance, and before/after fragmentation for audit trails and estimate refinement.

**Data Flow:** Execute-IndexMaintenance.ps1 inserts an IN_PROGRESS row before each rebuild with pre-rebuild fragmentation, priority score, estimated duration, rebuild mode, and MAXDOP. After the rebuild completes (or fails), it updates the row with actual duration, post-rebuild fragmentation, variance percentage, and status. Each row is tied to a run_id (batch), queue_id (queue entry), and registry_id (index registry entry).

**Estimate vs Actual Variance Tracking:** [sort:1] variance_pct records the percentage difference between estimated and actual rebuild duration: ((actual - estimated) / estimated) * 100. Positive values indicate underestimation, negative values overestimation. This enables analysis of estimate accuracy by size tier and rebuild mode, which informs tuning of the seconds-per-page coefficients in GlobalConfig.

**Before/After Fragmentation Proof:** [sort:2] fragmentation_pct_before is captured from the queue at rebuild start. fragmentation_pct_after is captured via a fresh dm_db_index_physical_stats scan immediately after the rebuild. This provides auditable proof that each rebuild accomplished its goal and supports effectiveness reporting.

**Deferral Count at Execution:** [sort:3] deferral_count_at_execution captures how many times this index was skipped before finally being rebuilt. This metric identifies indexes that consistently get deferred — potential candidates for SCHEDULED status, fill factor adjustment, or priority tuning.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| detail_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the detail entry |
| run_id | int | No | — | Groups entries from the same execution cycle |
| queue_id | bigint | Yes | — | Original queue entry (NULL if manually triggered) |
| registry_id | bigint | No | — | FK to Index_Registry.registry_id |
| database_id | int | No | — | FK to dbo.DatabaseRegistry.database_id |
| server_name | varchar(128) | No | — | Server name from dbo.ServerRegistry |
| database_name | varchar(128) | No | — | Database name |
| schema_name | sysname | No | — | Schema containing the table |
| table_name | sysname | No | — | Table containing the index |
| index_name | sysname | No | — | Name of the index |
| page_count | bigint | No | — | Page count at time of rebuild |
| fragmentation_pct_before | decimal(5,2) | No | — | Fragmentation before rebuild |
| fragmentation_pct_after | decimal(5,2) | Yes | — | Fragmentation after rebuild (NULL if failed) |
| priority_score | int | Yes | — | Priority score at execution time |
| operation_type | varchar(20) | No | — | REBUILD or REORGANIZE |
| rebuild_mode | varchar(10) | No | — | Execution mode used: ONLINE or OFFLINE |
| fill_factor_used | tinyint | Yes | — | Fill factor applied (NULL = default) |
| maxdop_used | tinyint | Yes | — | MAXDOP setting used |
| estimated_seconds | int | No | — | Pre-calculated duration estimate (mode-specific) |
| duration_seconds | int | Yes | — | Actual duration (NULL if still running) |
| variance_pct | decimal(7,2) | Yes | — | ((actual - estimated) / estimated) * 100 |
| started_dttm | datetime | No | — | When the rebuild started |
| completed_dttm | datetime | Yes | — | When the rebuild completed (NULL if still running) |
| status | varchar(20) | No | 'IN_PROGRESS' | Current status (see Status Values) |
| error_message | varchar(MAX) | Yes | — | Error details if failed |
| deferral_count_at_execution | int | No | 0 | How many times this index was deferred before finally running |

  - **PK_Index_ExecutionLog** (CLUSTERED): detail_id -- PRIMARY KEY
  - **IX_Index_ExecutionLog_Database_Date** (NONCLUSTERED): database_id, started_dttm
  - **IX_Index_ExecutionLog_Registry_History** (NONCLUSTERED): registry_id, started_dttm
  - **IX_Index_ExecutionLog_RunID** (NONCLUSTERED): run_id
  - **IX_Index_ExecutionLog_Status** (NONCLUSTERED): status

**Check Constraints:**

  - **CK_Index_ExecutionLog_Status**: `([status]='SKIPPED' OR [status]='DEFERRED' OR [status]='FAILED' OR [status]='SUCCESS' OR [status]='IN_PROGRESS')`

**Foreign Keys:**

  - **FK_Index_ExecutionLog_DatabaseRegistry**: database_id -> dbo.DatabaseRegistry.database_id
  - **FK_Index_ExecutionLog_Registry**: registry_id -> ServerOps.Index_Registry.registry_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| status | IN_PROGRESS | Rebuild currently executing. Set at INSERT time before the ALTER INDEX command. If this status persists after the maintenance window closes, the rebuild may have timed out or the process crashed. | 1 |
| status | SUCCESS | Rebuild completed successfully. All metrics populated: duration_seconds, fragmentation_pct_after, variance_pct. | 2 |
| status | FAILED | Rebuild encountered an error. error_message contains the exception details (truncated to 4000 characters). The corresponding queue entry is set to FAILED with an incremented deferral_count. | 3 |
| status | DEFERRED | Index was evaluated but not rebuilt in this run — typically because it did not fit in the remaining maintenance window. | 4 |
| status | SKIPPED | Index was bypassed for a non-deferral reason (e.g., database skipped due to schedule). | 5 |

**Current run progress** [sort:1] -- Shows all operations from the most recent execution run with their status and timing.

```sql
SELECT
    database_name,
    schema_name,
    table_name,
    index_name,
    rebuild_mode,
    page_count,
    fragmentation_pct_before,
    fragmentation_pct_after,
    estimated_seconds,
    duration_seconds,
    variance_pct,
    status,
    started_dttm
FROM ServerOps.Index_ExecutionLog
WHERE run_id = (SELECT MAX(run_id) FROM ServerOps.Index_ExecutionLog)
ORDER BY started_dttm;
```

**Estimation accuracy by size tier** [sort:2] -- Analyzes how well the seconds-per-page coefficients predict rebuild duration across different index sizes.

```sql
SELECT
    CASE
        WHEN page_count < 10000 THEN 'Small (<10K)'
        WHEN page_count < 100000 THEN 'Medium (10K-100K)'
        WHEN page_count < 1000000 THEN 'Large (100K-1M)'
        ELSE 'Huge (>1M)'
    END AS size_tier,
    rebuild_mode,
    COUNT(*) AS rebuilds,
    AVG(estimated_seconds) AS avg_estimated,
    AVG(duration_seconds) AS avg_actual,
    AVG(variance_pct) AS avg_variance_pct
FROM ServerOps.Index_ExecutionLog
WHERE status = 'SUCCESS'
  AND variance_pct IS NOT NULL
GROUP BY
    CASE
        WHEN page_count < 10000 THEN 'Small (<10K)'
        WHEN page_count < 100000 THEN 'Medium (10K-100K)'
        WHEN page_count < 1000000 THEN 'Large (100K-1M)'
        ELSE 'Huge (>1M)'
    END,
    rebuild_mode
ORDER BY size_tier, rebuild_mode;
```

**Indexes that consistently fail** [sort:3] -- Indexes with 3 or more failures in the last 30 days — may need exclusion, investigation, or manual intervention.

```sql
SELECT
    database_name,
    index_name,
    COUNT(*) AS failure_count,
    MAX(started_dttm) AS last_failure,
    MAX(error_message) AS last_error
FROM ServerOps.Index_ExecutionLog
WHERE status = 'FAILED'
  AND started_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY database_name, index_name
HAVING COUNT(*) >= 3
ORDER BY failure_count DESC;
```


### Index_ExecutionSummary

Historical execution summary for Index component processes. One row per database per run captures timing, volume, and outcome for performance analysis and audit trails.

**Data Flow:** All four Index scripts write per-database summary rows to this table using a shared run_id per process per run. Sync-IndexRegistry.ps1 logs SYNC operations with items_processed (updated), items_added (new), and items_skipped (marked dropped). Scan-IndexFragmentation.ps1 logs SCAN operations with items_processed (scanned), items_added (queued), items_skipped (removed from queue). Execute-IndexMaintenance.ps1 logs EXECUTE operations per database with items_processed (attempted), items_added (succeeded), and items_failed. Update-IndexStatistics.ps1 logs STATS operations with items_processed (evaluated), items_added (updated), and items_failed.

**Per-Database Granularity:** [sort:1] Unlike Index_Status (one row per process updated in place), ExecutionSummary keeps per-database rows per run. This enables analysis of which databases take the longest, which fail most often, and how processing distributes across the fleet. run_id groups all databases processed in a single script invocation.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| log_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the log entry |
| run_id | int | Yes | — | Groups entries from the same execution cycle |
| process_name | varchar(20) | No | — | Process type: SYNC, SCAN, EXECUTE, STATS |
| server_name | varchar(128) | Yes | — | Server name from dbo.ServerRegistry |
| database_name | varchar(128) | Yes | — | Database name processed |
| started_dttm | datetime | No | — | When processing of this database started |
| completed_dttm | datetime | Yes | — | When processing completed (NULL if still running) |
| duration_ms | int | Yes | — | Duration in milliseconds |
| items_processed | int | Yes | — | Primary count - meaning varies by process |
| items_added | int | Yes | — | Secondary count - meaning varies by process |
| items_skipped | int | Yes | — | Skipped/deferred count - meaning varies by process |
| items_failed | int | Yes | — | Error count - meaning varies by process |
| status | varchar(20) | No | 'IN_PROGRESS' | IN_PROGRESS, SUCCESS, PARTIAL, FAILED, NO_WORK, SKIPPED |
| error_message | varchar(500) | Yes | — | Error details if failed |

  - **PK_Index_ExecutionSummary** (CLUSTERED): log_id -- PRIMARY KEY
  - **IX_Index_ExecutionSummary_Database** (NONCLUSTERED): database_name, started_dttm
  - **IX_Index_ExecutionSummary_Process_Date** (NONCLUSTERED): process_name, started_dttm
  - **IX_Index_ExecutionSummary_RunId** (NONCLUSTERED): run_id

**Check Constraints:**

  - **CK_Index_ExecutionSummary_Process**: `([process_name]='STATS' OR [process_name]='EXECUTE' OR [process_name]='SCAN' OR [process_name]='SYNC')`
  - **CK_Index_ExecutionSummary_Status**: `([status]='SKIPPED' OR [status]='NO_WORK' OR [status]='FAILED' OR [status]='PARTIAL' OR [status]='SUCCESS' OR [status]='IN_PROGRESS')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| process_name | SYNC | Sync-IndexRegistry.ps1 — daily discovery and metadata refresh of indexes across enrolled databases. | 1 |
| status | SUCCESS | All operations for this database completed without errors. | 1 |
| status | PARTIAL | Some operations succeeded but others failed. Check items_failed for the count. | 2 |
| process_name | SCAN | Scan-IndexFragmentation.ps1 — fragmentation assessment via dm_db_index_physical_stats and queue population. | 2 |
| process_name | EXECUTE | Execute-IndexMaintenance.ps1 — index rebuild execution during maintenance windows. | 3 |
| status | FAILED | All operations for this database failed or the database was unreachable. | 3 |
| status | NO_WORK | Database was evaluated but had no qualifying work items. | 4 |
| process_name | STATS | Update-IndexStatistics.ps1 — statistics maintenance for modification-based and staleness-based updates. | 4 |
| status | SKIPPED | Database was bypassed — typically because the schedule did not allow maintenance during the current hour. | 5 |
| status | IN_PROGRESS | Currently being processed. Set at the start of database processing. | 6 |

**Recent run summary by process** [sort:1] -- Shows the latest run for each process with aggregate metrics.

```sql
SELECT
    process_name,
    MAX(run_id) AS last_run_id,
    COUNT(*) AS databases_in_run,
    SUM(items_processed) AS total_processed,
    SUM(items_added) AS total_added,
    SUM(items_failed) AS total_failed,
    SUM(duration_ms) / 1000 AS total_seconds
FROM ServerOps.Index_ExecutionSummary
WHERE run_id IN (
    SELECT MAX(run_id)
    FROM ServerOps.Index_ExecutionSummary
    GROUP BY process_name
)
GROUP BY process_name
ORDER BY process_name;
```


### Index_HolidaySchedule

Per-database maintenance schedules for company holidays. Each database enrolled in index maintenance has one row defining which hours allow maintenance on any holiday. Works in conjunction with dbo.Holiday which provides the calendar of holiday dates.

**Data Flow:** Rows are created by sp_Index_AddDatabaseHolidaySchedule during enrollment (one row per database with default 9am-11pm allowed). xFACts-IndexFunctions.ps1 reads this table in Get-EffectiveSchedule on weekdays when the current date matches a dbo.Holiday entry — the two-table check (Holiday for date, HolidaySchedule for hours) determines whether the hour is allowed. Holidays trigger extended window detection via Test-IsExtendedWindow, which causes Execute-IndexMaintenance.ps1 to reset SCHEDULED indexes to PENDING.

**Two-Table Holiday Architecture:** [sort:1] dbo.Holiday defines which dates are holidays (shared across the platform). This table defines per-database maintenance hours on those holidays. This separation means new holidays only need one Holiday row — all databases automatically get their existing HolidaySchedule applied. If a database has no HolidaySchedule row, the regular DatabaseSchedule is used on holidays.

**Extended Window Trigger:** [sort:2] Holidays qualify as extended window days alongside weekends. Execute-IndexMaintenance.ps1 checks Test-IsExtendedWindow at startup — if true, all SCHEDULED indexes (those too large for weekday windows) are reset to PENDING and eligible for processing. This is the primary mechanism for handling large indexes that accumulate during the week.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| database_id | int | No | — | FK to dbo.DatabaseRegistry.database_id |
| hr00 | bit | No | 1 | Midnight to 1am |
| hr01 | bit | No | 1 | 1am to 2am |
| hr02 | bit | No | 1 | 2am to 3am |
| hr03 | bit | No | 1 | 3am to 4am |
| hr04 | bit | No | 1 | 4am to 5am |
| hr05 | bit | No | 1 | 5am to 6am |
| hr06 | bit | No | 1 | 6am to 7am |
| hr07 | bit | No | 1 | 7am to 8am |
| hr08 | bit | No | 1 | 8am to 9am |
| hr09 | bit | No | 1 | 9am to 10am |
| hr10 | bit | No | 1 | 10am to 11am |
| hr11 | bit | No | 1 | 11am to noon |
| hr12 | bit | No | 1 | Noon to 1pm |
| hr13 | bit | No | 1 | 1pm to 2pm |
| hr14 | bit | No | 1 | 2pm to 3pm |
| hr15 | bit | No | 1 | 3pm to 4pm |
| hr16 | bit | No | 1 | 4pm to 5pm |
| hr17 | bit | No | 1 | 5pm to 6pm |
| hr18 | bit | No | 1 | 6pm to 7pm |
| hr19 | bit | No | 1 | 7pm to 8pm |
| hr20 | bit | No | 1 | 8pm to 9pm |
| hr21 | bit | No | 1 | 9pm to 10pm |
| hr22 | bit | No | 1 | 10pm to 11pm |
| hr23 | bit | No | 1 | 11pm to midnight |
| created_dttm | datetime | No | getdate() | When this schedule was created |
| created_by | varchar(100) | No | suser_sname() | Who created this schedule |
| modified_dttm | datetime | Yes | — | When this schedule was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified this schedule |

  - **PK_HolidaySchedule** (CLUSTERED): database_id -- PRIMARY KEY

**Foreign Keys:**

  - **FK_HolidaySchedule_DatabaseRegistry**: database_id -> dbo.DatabaseRegistry.database_id

  - **dbo.Holiday**: [sort:1] Holiday stores the calendar of recognized holidays. Get-EffectiveSchedule first checks if today matches a Holiday row (is_active = 1), and only then looks up the per-database hours in HolidaySchedule. Both tables must have matching entries for the holiday schedule to apply.


### Index_Queue

Working queue of indexes awaiting maintenance, populated from Index_Registry based on fragmentation thresholds. Records are removed upon successful completion.

**Data Flow:** Scan-IndexFragmentation.ps1 manages the queue as a living reflection of reality: inserts new entries when indexes exceed the fragmentation threshold, updates existing entries with fresh scan data, resets FAILED entries to PENDING when re-qualifying, and deletes entries that drop below threshold. Execute-IndexMaintenance.ps1 claims entries by setting status to IN_PROGRESS, deletes them after successful rebuild, or sets them to FAILED on error. At startup, Execute-IndexMaintenance.ps1 resets DEFERRED and FAILED to PENDING, and on extended windows (weekends/holidays) also resets SCHEDULED to PENDING.

**Living Queue:** [sort:1] Unlike a static work list, the queue reflects current reality. Indexes are added when they exceed thresholds, updated when rescanned, and automatically removed if they no longer qualify (e.g., someone manually rebuilt an index). If it is in the queue, it needs work. No zombie entries.

**Priority Scoring System:** [sort:2] Each queue entry receives a calculated priority_score from four weighted components, all configurable via GlobalConfig: (1) Database Priority — tiered by index_maintenance_priority: priority 1 = 40 points, 2 = 25, 3 = 15; (2) Fragmentation Severity — tiered by fragmentation percentage: low = 10, medium = 15, high = 20 points; (3) Index Size — tiered by page count: small = 10, medium = 20, large = 30 points; (4) Deferral Anti-Starvation — indexes previously skipped due to time constraints get bonus points: base = 5, above threshold = 10 points. Maximum possible score is 100. The scoring ensures critical databases and large, heavily fragmented indexes are rebuilt first, while the deferral component prevents any index from being perpetually skipped.

**Best-Fit vs Priority Ordering:** [sort:3] Execute-IndexMaintenance.ps1 uses different selection strategies based on window type. On weekdays: best-fit algorithm — iterates through the queue by priority, selecting indexes whose estimated duration fits in the remaining window, skipping larger ones to try smaller ones (maximizes throughput). On extended windows (weekends/holidays): straight priority order — processes all indexes including SCHEDULED ones that were too large for weekday windows.

**SCHEDULED Status for Oversized Indexes:** [sort:4] When the best-fit algorithm encounters an index whose estimated duration exceeds the largest contiguous weekday window (calculated by Get-MaxWeekdayWindow), it marks it SCHEDULED rather than repeatedly deferring it. SCHEDULED indexes are only reset to PENDING on extended window days (weekends/holidays), which is the designed mechanism for handling large indexes that accumulate during the work week.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| queue_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the queue entry |
| registry_id | bigint | No | — | FK to Index_Registry.registry_id |
| database_id | int | No | — | FK to dbo.DatabaseRegistry.database_id (for quick filtering) |
| schema_name | sysname | No | — | Schema containing the table |
| table_name | sysname | No | — | Table containing the index |
| index_name | sysname | No | — | Name of the index |
| fragmentation_pct | decimal(5,2) | No | — | Fragmentation when queued |
| page_count | bigint | No | — | Page count when queued |
| estimated_seconds_online | bigint | Yes | — | Estimated rebuild duration using ONLINE factor |
| estimated_seconds_offline | bigint | Yes | — | Estimated rebuild duration using OFFLINE factor |
| operation_type | varchar(20) | No | 'REBUILD' | REBUILD or REORGANIZE |
| online_option | bit | No | 1 | Planned mode: ONLINE=ON (1) or ONLINE=OFF (0) |
| status | varchar(20) | No | 'PENDING' | Current status: PENDING, IN_PROGRESS, DEFERRED, SCHEDULED, or FAILED |
| deferral_count | int | No | 0 | Number of times this index has been skipped or failed |
| priority_score | int | No | 0 | Calculated priority for execution ordering (higher = more urgent) |
| queued_dttm | datetime | No | getdate() | When the entry was added to the queue |
| last_evaluated_dttm | datetime | Yes | — | When the entry was last considered for execution |

  - **PK_Index_Queue** (CLUSTERED): queue_id -- PRIMARY KEY
  - **IX_Index_Queue_Execution** (NONCLUSTERED): estimated_seconds_online, estimated_seconds_offline, database_id, status
  - **UQ_Index_Queue_RegistryLookup** (NONCLUSTERED): registry_id

**Check Constraints:**

  - **CK_Index_Queue_OperationType**: `([operation_type]='REORGANIZE' OR [operation_type]='REBUILD')`
  - **CK_Index_Queue_Status**: `([status]='FAILED' OR [status]='SCHEDULED' OR [status]='DEFERRED' OR [status]='IN_PROGRESS' OR [status]='PENDING')`

**Foreign Keys:**

  - **FK_Index_Queue_DatabaseRegistry**: database_id -> dbo.DatabaseRegistry.database_id
  - **FK_Index_Queue_Registry**: registry_id -> ServerOps.Index_Registry.registry_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| status | PENDING | Awaiting processing. Set when an index is first added to the queue by Scan-IndexFragmentation.ps1, or reset from DEFERRED/FAILED at the start of each Execute-IndexMaintenance.ps1 run. | 1 |
| operation_type | REBUILD | Full index rebuild (ALTER INDEX ... REBUILD). This is the standard operation for all queued indexes. | 1 |
| operation_type | REORGANIZE | Index reorganization (ALTER INDEX ... REORGANIZE). Reserved for future use — currently all operations are REBUILD. | 2 |
| status | IN_PROGRESS | Currently being rebuilt. Set by Execute-IndexMaintenance.ps1 immediately before issuing the ALTER INDEX command. Scan-IndexFragmentation.ps1 skips IN_PROGRESS entries to avoid interfering with active rebuilds. | 2 |
| status | DEFERRED | Skipped in the current run because it did not fit in the remaining window. Reset to PENDING at the start of the next Execute-IndexMaintenance.ps1 run. The deferral_count is incremented to boost priority scoring on subsequent runs. | 3 |
| status | SCHEDULED | Too large for any weekday maintenance window. Identified by comparing estimated duration against Get-MaxWeekdayWindow. Only reset to PENDING on extended window days (weekends/holidays). If a SCHEDULED index still does not fit even in an extended window, its deferral_count is incremented. | 4 |
| status | FAILED | Rebuild attempt failed. The error is logged to Index_ExecutionLog. deferral_count is incremented. Reset to PENDING at the start of the next Execute-IndexMaintenance.ps1 run. If the index re-qualifies on the next scan, Scan-IndexFragmentation.ps1 also resets FAILED to PENDING. | 5 |

**Queue depth by status** [sort:1] -- At-a-glance summary showing queue size, total pages, and estimated duration per status.

```sql
SELECT
    status,
    COUNT(*) AS index_count,
    SUM(page_count) AS total_pages,
    SUM(estimated_seconds_offline) / 60 AS est_minutes_offline,
    SUM(estimated_seconds_online) / 60 AS est_minutes_online
FROM ServerOps.Index_Queue
GROUP BY status;
```

**Queue by database** [sort:2] -- Breakdown showing how work is distributed across databases with deferral information.

```sql
SELECT
    dr.database_name,
    q.status,
    COUNT(*) AS index_count,
    SUM(q.page_count) AS total_pages,
    MAX(q.deferral_count) AS max_deferrals
FROM ServerOps.Index_Queue q
JOIN dbo.DatabaseRegistry dr ON q.database_id = dr.database_id
GROUP BY dr.database_name, q.status
ORDER BY dr.database_name, q.status;
```

**Most deferred indexes** [sort:3] -- Indexes repeatedly skipped due to time constraints — high deferral counts may indicate indexes that need SCHEDULED treatment or extended window attention.

```sql
SELECT
    dr.database_name,
    q.schema_name,
    q.table_name,
    q.index_name,
    q.status,
    q.deferral_count,
    q.page_count,
    q.priority_score,
    q.estimated_seconds_online / 60 AS est_min_online
FROM ServerOps.Index_Queue q
JOIN dbo.DatabaseRegistry dr ON q.database_id = dr.database_id
WHERE q.deferral_count > 0
ORDER BY q.deferral_count DESC, q.priority_score DESC;
```

**SCHEDULED indexes awaiting extended window** [sort:4] -- Indexes too large for weekday maintenance windows that will be processed on the next weekend or holiday.

```sql
SELECT
    dr.database_name,
    q.index_name,
    q.page_count,
    q.estimated_seconds_online / 60.0 AS est_minutes_online,
    q.deferral_count,
    q.queued_dttm
FROM ServerOps.Index_Queue q
JOIN dbo.DatabaseRegistry dr ON q.database_id = dr.database_id
WHERE q.status = 'SCHEDULED'
ORDER BY q.deferral_count DESC, q.page_count DESC;
```

  - **Index_Registry**: [sort:1] Each queue entry references a registry_id. The registry provides the scan data that determines whether an index qualifies for queuing, and receives updates (last_rebuild_dttm, lifetime_rebuild_count) after successful rebuilds. Queue entries are deleted on successful rebuild; registry entries persist for history.
  - **Index_ExecutionLog**: [sort:2] When Execute-IndexMaintenance.ps1 begins processing a queue entry, it inserts an IN_PROGRESS row into ExecutionLog with the queue_id and registry_id. On completion, the ExecutionLog row is updated with duration, fragmentation before/after, and variance. The queue entry is then deleted (success) or set to FAILED.


### Index_Registry

Persistent catalog of all indexes in enrolled databases, storing last-known fragmentation statistics, rebuild history, and metadata to enable efficient incremental scanning without expensive full catalog queries.

**Data Flow:** Sync-IndexRegistry.ps1 performs the daily "cheap pass" — queries sys.indexes, sys.dm_db_partition_stats, and sys.dm_db_index_usage_stats on each enrolled database, inserts new indexes, updates metadata (page count, fill factor, usage stats) for existing indexes, and marks missing indexes as is_dropped = 1. Scan-IndexFragmentation.ps1 reads scan candidates (not dropped, not excluded, above minimum page count, not recently scanned or rebuilt), then updates current_fragmentation_pct and last_scanned_dttm after scanning each index via sys.dm_db_index_physical_stats. Execute-IndexMaintenance.ps1 updates last_rebuild_dttm, last_rebuild_duration_seconds, lifetime_rebuild_count, and current_fragmentation_pct after successful rebuilds. Update-IndexStatistics.ps1 updates stats_last_updated after updating statistics.

**Central Catalog — Single Source of Truth:** [sort:1] All Index component scripts operate through the registry. An index must exist in the registry before it can be scanned, queued, rebuilt, or have its statistics updated. This prevents orphaned queue entries and enables comprehensive lifecycle tracking (discovery ? scanning ? rebuild ? statistics) for every index.

**Soft-Delete for Dropped Indexes:** [sort:2] When Sync-IndexRegistry.ps1 finds an index in the registry that no longer exists in the source database, it sets is_dropped = 1 and dropped_detected_dttm rather than deleting the row. This preserves the lifetime_rebuild_count and rebuild history for analysis. Dropped indexes are excluded from scanning and queue population.

**Exclusion Mechanism:** [sort:3] is_excluded = 1 with an optional exclusion_reason removes an index from scanning and queue population without affecting sync. This handles vendor-managed indexes, known problematic indexes, or indexes under temporary investigation. Unlike is_dropped, excluded indexes are still tracked and updated by sync.

**Usage Statistics Capture:** [sort:4] user_seeks, user_scans, user_lookups, user_updates, and the last_user_seek/last_user_scan timestamps are captured from sys.dm_db_index_usage_stats during sync. These are cumulative since the last service restart (tracked via usage_captured_dttm). The data supports identifying unused indexes — zero seeks and zero scans since service start suggests the index may be a deletion candidate.

**Average Daily Fragmentation Rate:** [sort:5] avg_daily_fragmentation_rate captures how quickly an index fragments between rebuilds. This enables predictive scheduling — indexes that fragment rapidly can be prioritized, while slow-fragmenting indexes can be scanned less frequently. Currently populated by Scan-IndexFragmentation.ps1 based on observed fragmentation growth between scans.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| registry_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the registry entry |
| database_id | int | No | — | FK to dbo.DatabaseRegistry.database_id |
| schema_name | sysname | No | — | Schema containing the table |
| table_name | sysname | No | — | Table containing the index |
| index_name | sysname | No | — | Name of the index |
| index_id | int | No | — | SQL Server index_id from sys.indexes |
| index_type | varchar(20) | No | — | CLUSTERED, NONCLUSTERED, or COLUMNSTORE variant |
| is_primary_key | bit | No | 0 | Whether this index backs a primary key constraint |
| is_unique | bit | No | 0 | Whether this is a unique index |
| current_page_count | bigint | Yes | — | Last-known page count from sys.dm_db_partition_stats |
| current_fragmentation_pct | decimal(5,2) | Yes | — | Last-known fragmentation from sys.dm_db_index_physical_stats |
| current_fill_factor | tinyint | Yes | — | Current fill factor setting (0 = 100%) |
| last_scanned_dttm | datetime | Yes | — | When fragmentation was last scanned |
| last_rebuild_dttm | datetime | Yes | — | When index was last rebuilt by this system |
| last_rebuild_duration_seconds | int | Yes | — | How long the last rebuild took |
| lifetime_rebuild_count | int | No | 0 | Total number of rebuilds performed by this system |
| stats_last_updated | datetime | Yes | — | When UPDATE STATISTICS was last run on this index |
| user_seeks | bigint | Yes | — | Cumulative user seeks since last service restart |
| user_scans | bigint | Yes | — | Cumulative user scans since last service restart |
| user_lookups | bigint | Yes | — | Cumulative user lookups since last service restart |
| user_updates | bigint | Yes | — | Cumulative user updates since last service restart |
| last_user_seek | datetime | Yes | — | Timestamp of last user seek operation |
| last_user_scan | datetime | Yes | — | Timestamp of last user scan operation |
| usage_captured_dttm | datetime | Yes | — | When usage statistics were last captured |
| avg_daily_fragmentation_rate | decimal(5,2) | Yes | — | Reserved for future trend analysis |
| is_excluded | bit | No | 0 | Whether index is excluded from maintenance |
| exclusion_reason | varchar(200) | Yes | — | Why the index is excluded |
| is_dropped | bit | No | 0 | Whether index no longer exists in source database |
| dropped_detected_dttm | datetime | Yes | — | When the drop was detected |
| created_dttm | datetime | No | getdate() | When the registry entry was created |
| modified_dttm | datetime | Yes | — | When the entry was last modified |

  - **PK_Index_Registry** (CLUSTERED): registry_id -- PRIMARY KEY
  - **IX_Index_Registry_MaintenanceCandidates** (NONCLUSTERED): database_id, is_dropped, is_excluded, current_fragmentation_pct [includes: schema_name, table_name, index_name, current_page_count, last_rebuild_dttm]
  - **IX_Index_Registry_Reconciliation** (NONCLUSTERED): database_id, schema_name, table_name, index_id [includes: index_name, is_dropped]
  - **IX_Index_Registry_ScanCandidates** (NONCLUSTERED): database_id, is_dropped, last_scanned_dttm, last_rebuild_dttm [includes: schema_name, table_name, index_name, index_id, current_page_count]
  - **UQ_Index_Registry_DatabaseIndex** (NONCLUSTERED): database_id, schema_name, table_name, index_name

**Foreign Keys:**

  - **FK_Index_Registry_DatabaseRegistry**: database_id -> dbo.DatabaseRegistry.database_id

**Registry summary by database** [sort:1] -- Overview showing total indexes, dropped count, unscanned count, and indexes above the fragmentation threshold per database.

```sql
SELECT
    dr.database_name,
    COUNT(*) AS total_indexes,
    SUM(CASE WHEN ir.is_dropped = 1 THEN 1 ELSE 0 END) AS dropped,
    SUM(CASE WHEN ir.current_fragmentation_pct IS NULL AND ir.is_dropped = 0 THEN 1 ELSE 0 END) AS never_scanned,
    SUM(CASE WHEN ir.current_fragmentation_pct >= 15 AND ir.is_dropped = 0 THEN 1 ELSE 0 END) AS above_threshold,
    MAX(ir.last_scanned_dttm) AS last_scan_activity
FROM ServerOps.Index_Registry ir
JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
GROUP BY dr.database_name
ORDER BY dr.database_name;
```

**Most frequently rebuilt indexes** [sort:2] -- Top 20 indexes by lifetime rebuild count — high-churn indexes that may benefit from fill factor adjustment or schema review.

```sql
SELECT TOP 20
    dr.database_name,
    ir.schema_name,
    ir.table_name,
    ir.index_name,
    ir.lifetime_rebuild_count,
    ir.last_rebuild_dttm,
    ir.current_page_count,
    ir.current_fragmentation_pct
FROM ServerOps.Index_Registry ir
JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
WHERE ir.is_dropped = 0
  AND ir.lifetime_rebuild_count > 0
ORDER BY ir.lifetime_rebuild_count DESC;
```

**Potentially unused indexes** [sort:3] -- Indexes with zero seeks and zero scans since service start — candidates for review and possible removal.

```sql
SELECT
    dr.database_name,
    ir.schema_name,
    ir.table_name,
    ir.index_name,
    ir.index_type,
    ir.current_page_count,
    ir.user_updates,
    ir.usage_captured_dttm
FROM ServerOps.Index_Registry ir
JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
WHERE ir.is_dropped = 0
  AND ir.usage_captured_dttm IS NOT NULL
  AND COALESCE(ir.user_seeks, 0) = 0
  AND COALESCE(ir.user_scans, 0) = 0
  AND ir.current_page_count >= 1000
ORDER BY ir.current_page_count DESC;
```

**Exclude an index from maintenance** [sort:4] -- Marks an index as excluded with a reason. Excluded indexes are still tracked by sync but skipped by scanning and queue population.

```sql
UPDATE ServerOps.Index_Registry
SET is_excluded = 1,
    exclusion_reason = 'Vendor-managed index - do not modify',
    modified_dttm = GETDATE()
WHERE database_id = @DatabaseID
  AND schema_name = 'dbo'
  AND table_name = 'TargetTable'
  AND index_name = 'IX_VendorManaged';
```

**Recently dropped indexes** [sort:5] -- Indexes detected as dropped in the last 30 days — useful for reviewing schema changes.

```sql
SELECT
    dr.database_name,
    ir.schema_name,
    ir.table_name,
    ir.index_name,
    ir.dropped_detected_dttm,
    ir.lifetime_rebuild_count
FROM ServerOps.Index_Registry ir
JOIN dbo.DatabaseRegistry dr ON ir.database_id = dr.database_id
WHERE ir.is_dropped = 1
  AND ir.dropped_detected_dttm >= DATEADD(DAY, -30, GETDATE())
ORDER BY ir.dropped_detected_dttm DESC;
```

  - **Index_Queue**: [sort:1] Queue entries reference registry_id as a foreign key. An index must exist in the registry before it can be queued. When an index is rebuilt successfully, the queue entry is deleted and the registry is updated with post-rebuild fragmentation and timing. When a registry entry is marked as dropped, any corresponding queue entry should be removed.
  - **Index_ExecutionLog**: [sort:2] ExecutionLog entries reference registry_id for per-index rebuild history. This links each rebuild operation back to the registry entry, enabling analysis of rebuild frequency, duration trends, and estimate accuracy over time for specific indexes.


### Index_StatsExecutionLog

Per-statistic execution detail for statistics maintenance operations. Supports individual tracking for modification-based updates and cumulative logging for staleness-based updates.

**Data Flow:** Update-IndexStatistics.ps1 writes two types of entries. MODIFICATION entries are logged individually per statistic when the modification counter exceeds the configured threshold (default 10% of rows modified) — each row captures the specific statistic name, row count, modification counter, and percentage modified. STALENESS entries are logged as one cumulative row per database when statistics exceed the age threshold (default 30 days) — the row captures stats_count, min_days_stale, and max_days_stale rather than individual statistic details.

**Dual Logging Strategy:** [sort:1] MODIFICATION updates are logged individually because they represent meaningful data changes worth investigating — which tables are changing rapidly, how much, and how often. STALENESS updates are logged as one cumulative row per database because they represent routine freshness maintenance — logging hundreds of individual "it was old, now it is not" entries would flood the table with low-value data.

**Targeted vs Blanket Statistics Updates:** [sort:2] Traditional maintenance updates all statistics weekly regardless of need. This approach evaluates each statistic individually: modification threshold catches actively changing data, staleness threshold catches distribution drift. In practice, only ~2% of statistics need updating on any given run, completing in seconds instead of minutes.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| detail_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the detail entry |
| run_id | int | No | — | Groups entries from the same execution cycle |
| database_id | int | No | — | FK to dbo.DatabaseRegistry.database_id |
| registry_id | bigint | Yes | — | FK to Index_Registry (NULL for STALENESS) |
| update_type | varchar(20) | No | — | 'MODIFICATION' or 'STALENESS' |
| server_name | varchar(128) | Yes | — | Server name (NULL for STALENESS) |
| database_name | varchar(128) | No | — | Database name |
| schema_name | sysname | Yes | — | Schema containing the table (NULL for STALENESS) |
| table_name | sysname | Yes | — | Table containing the statistic (NULL for STALENESS) |
| stat_name | sysname | Yes | — | Name of the statistic/index (NULL for STALENESS) |
| rows_at_update | bigint | Yes | — | Table row count when updated |
| modification_counter | bigint | Yes | — | Rows modified since last update (from sys.dm_db_stats_properties) |
| pct_modified | decimal(10,2) | Yes | — | (modification_counter / rows) * 100 |
| days_since_update | int | Yes | — | Days since stat was last updated |
| stats_count | int | Yes | — | Number of statistics updated in batch |
| min_days_stale | int | Yes | — | Age of youngest stat in batch |
| max_days_stale | int | Yes | — | Age of oldest stat in batch |
| sample_pct_used | tinyint | Yes | — | 0 = FULLSCAN, 1-100 = SAMPLE n PERCENT |
| started_dttm | datetime | No | — | When the update started |
| completed_dttm | datetime | Yes | — | When the update completed |
| duration_ms | int | Yes | — | Duration in milliseconds |
| status | varchar(20) | No | 'IN_PROGRESS' | Current status (see Status Values) |
| error_message | varchar(MAX) | Yes | — | Error details if failed |

  - **PK_Index_StatsExecutionLog** (CLUSTERED): detail_id -- PRIMARY KEY
  - **IX_Index_StatsExecutionLog_Database_Date** (NONCLUSTERED): database_id, started_dttm
  - **IX_Index_StatsExecutionLog_Registry_History** (NONCLUSTERED): registry_id, started_dttm
  - **IX_Index_StatsExecutionLog_RunID** (NONCLUSTERED): run_id
  - **IX_Index_StatsExecutionLog_Status** (NONCLUSTERED): status
  - **IX_Index_StatsExecutionLog_UpdateType** (NONCLUSTERED): update_type, started_dttm

**Check Constraints:**

  - **CK_Index_StatsExecutionLog_Status**: `([status]='SKIPPED' OR [status]='FAILED' OR [status]='SUCCESS' OR [status]='IN_PROGRESS')`
  - **CK_Index_StatsExecutionLog_UpdateType**: `([update_type]='STALENESS' OR [update_type]='MODIFICATION')`

**Foreign Keys:**

  - **FK_Index_StatsExecutionLog_DatabaseRegistry**: database_id -> dbo.DatabaseRegistry.database_id
  - **FK_Index_StatsExecutionLog_Registry**: registry_id -> ServerOps.Index_Registry.registry_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| update_type | MODIFICATION | Statistic updated because modification_counter exceeded the configured threshold (default 10% of rows). Logged individually with full details: schema, table, stat name, row count, modification counter, percentage modified. | 1 |
| update_type | STALENESS | Statistics updated because they exceeded the age threshold (default 30 days since last update) regardless of modification count. Logged as one cumulative row per database with stats_count, min_days_stale, and max_days_stale. | 2 |

**Most frequently modified statistics** [sort:1] -- Statistics that are updated most often due to high modification rates — indicates actively changing tables.

```sql
SELECT
    database_name,
    schema_name,
    table_name,
    stat_name,
    COUNT(*) AS update_count,
    AVG(pct_modified) AS avg_pct_modified,
    MAX(rows_at_update) AS max_rows
FROM ServerOps.Index_StatsExecutionLog
WHERE update_type = 'MODIFICATION'
  AND started_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY database_name, schema_name, table_name, stat_name
HAVING COUNT(*) >= 3
ORDER BY update_count DESC;
```


### Index_Status

Dashboard table providing at-a-glance status for all Index component processes. One row per process (SYNC, SCAN, EXECUTE, STATS) tracks last run timing, outcome, and metrics.

**Data Flow:** Rows are pre-seeded — one per process (SYNC, SCAN, EXECUTE, STATS). Each script updates its row using a two-phase pattern: at start, sets started_dttm and clears metrics; at completion, populates completed_dttm, last_status, last_duration_seconds, and item counts. Rows are updated in place, never inserted or appended.

**One Row Per Process — Update in Place:** [sort:1] Identical pattern to Backup_Status. Exactly four pre-seeded rows, updated in place after each run. Provides an instant dashboard answer to "when did each process last run and what was the result" without querying detailed logs.

**Real-Time Counter Updates During Execution:** [sort:2] Execute-IndexMaintenance.ps1 increments items_added (successes) and items_failed in real time after each index rebuild, before the overall run completes. This means the Status row reflects live progress during long execution runs, not just the final summary.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| process_name | varchar(20) | No | — | Process identifier: SYNC, SCAN, EXECUTE, STATS |
| started_dttm | datetime | Yes | — | When the process started (set at beginning of run) |
| completed_dttm | datetime | Yes | — | When the process completed (NULL if in progress) |
| last_status | varchar(20) | Yes | — | Outcome of last run: IN_PROGRESS, SUCCESS, PARTIAL, FAILED, NO_WORK |
| last_duration_seconds | int | Yes | — | Duration of last run in seconds |
| items_processed | int | Yes | — | Primary count - meaning varies by process |
| items_added | int | Yes | — | Secondary count - meaning varies by process |
| items_skipped | int | Yes | — | Skipped/deferred count - meaning varies by process |
| items_failed | int | Yes | — | Error count - meaning varies by process |
| last_error_message | varchar(500) | Yes | — | Error summary if last run had issues |

  - **PK_Index_Status** (CLUSTERED): process_name -- PRIMARY KEY

**Check Constraints:**

  - **CK_Index_Status_ProcessName**: `([process_name]='STATS' OR [process_name]='EXECUTE' OR [process_name]='SCAN' OR [process_name]='SYNC')`
  - **CK_Index_Status_Status**: `([last_status] IS NULL OR ([last_status]='NO_WORK' OR [last_status]='FAILED' OR [last_status]='PARTIAL' OR [last_status]='SUCCESS' OR [last_status]='IN_PROGRESS'))`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| process_name | SYNC | Sync-IndexRegistry.ps1 — daily discovery and metadata refresh. | 1 |
| last_status | IN_PROGRESS | Process is currently running. Set at script start; completed_dttm is NULL. | 1 |
| last_status | SUCCESS | Process completed all work without errors. | 2 |
| process_name | SCAN | Scan-IndexFragmentation.ps1 — fragmentation scanning and queue population. | 2 |
| process_name | EXECUTE | Execute-IndexMaintenance.ps1 — index rebuild execution. | 3 |
| last_status | PARTIAL | Process completed but some databases or operations had errors. Check items_failed for count. | 3 |
| last_status | FAILED | Process encountered critical errors across all databases. | 4 |
| process_name | STATS | Update-IndexStatistics.ps1 — statistics maintenance. | 4 |
| last_status | NO_WORK | Process ran but found no qualifying work. No databases matched the filter criteria or had eligible items. | 5 |

**Quick status check** [sort:1] -- At-a-glance dashboard view of all Index processes showing last run timing and outcome.

```sql
SELECT
    process_name,
    last_status,
    started_dttm,
    completed_dttm,
    last_duration_seconds,
    items_processed,
    items_added,
    items_skipped,
    items_failed,
    last_error_message
FROM ServerOps.Index_Status
ORDER BY process_name;
```


### sp_Index_AddDatabaseHolidaySchedule

Adds a holiday schedule row for a database into HolidaySchedule. Resolves database and server names to IDs and inserts with a standard default schedule.

**Data Flow:** Accepts database name and server name, resolves them to database_id via DatabaseRegistry and ServerRegistry. Checks Index_HolidaySchedule for existing entry (prevents duplicates). Inserts one row with a default schedule of 9am-11pm allowed (hr09-hr22 = 1, all others = 0).

**Name-Based Interface:** [sort:1] Accepts database_name and server_name rather than IDs, resolving internally. This is more user-friendly for ad-hoc enrollment since operators know database names, not integer IDs. The proc validates both exist and are active before proceeding.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @DatabaseName | nvarchar(128) | IN |  |  |
| @ServerName | nvarchar(128) | IN |  |  |
| @PreviewOnly | bit | IN |  |  |


### sp_Index_AddDatabaseSchedule

Adds the 7 default schedule rows (one per day of week) for a database in DatabaseSchedule. Provides flexible parameters for customizing blocking patterns during initial enrollment.

**Data Flow:** Reads dbo.DatabaseRegistry to validate the database_id. Checks Index_DatabaseSchedule for existing rows (prevents duplicate initialization). Inserts 7 rows into Index_DatabaseSchedule (one per day of week) using the provided block range parameters to generate the hr00-hr23 bit pattern. Supports separate configurations for weekdays, Saturday, and Sunday with optional override for Sunday differing from Saturday.

**Block Range to Bit Grid Conversion:** [sort:1] Accepts simple parameters (WeekdayBlockStart/End, WeekendBlockStart/End, optional SundayBlockStart/End) and generates the 24 bit columns per day. Hours within the block range are set to 0 (not allowed); hours outside are set to 1 (allowed). This avoids requiring callers to specify 168 individual bit values (7 days × 24 hours) while still producing the full granularity the schedule system requires.

**Validation-Heavy Design:** [sort:2] Validates hour ranges (0-23), paired parameters (both start and end must be specified or both NULL), and start-before-end ordering. Overnight windows (start > end) are not supported — this is an intentional simplification to avoid ambiguous cross-midnight logic.

**Parameters:**

| Parameter | Type | Direction | Default | Description |
| --- | --- | --- | --- | --- |
| @DatabaseID | int | IN |  |  |
| @WeekdayBlockStart | tinyint | IN |  |  |
| @WeekdayBlockEnd | tinyint | IN |  |  |
| @WeekendBlockStart | tinyint | IN |  |  |
| @WeekendBlockEnd | tinyint | IN |  |  |
| @SundayBlockStart | tinyint | IN |  |  |
| @SundayBlockEnd | tinyint | IN |  |  |
| @PreviewOnly | bit | IN |  |  |


### Execute-IndexMaintenance.ps1

Executes index rebuild operations from the Index_Queue during maintenance windows. Respects the three-tier schedule hierarchy (Exception ? Holiday ? DatabaseSchedule), uses best-fit selection on weekdays to maximize throughput, switches to priority ordering on extended windows (weekends/holidays), marks oversized indexes as SCHEDULED, and tracks estimate-vs-actual variance for duration refinement. Runs as a FIRE_AND_FORGET process under Orchestrator v2.

**Data Flow:** Reads GlobalConfig for rebuild settings (MAXDOP, lock timeout, seconds-per-page coefficients). Queries Index_Queue joined to DatabaseRegistry, ServerRegistry, and Index_DatabaseConfig for databases with queued work. Evaluates schedule via xFACts-IndexFunctions.ps1 (Get-EffectiveSchedule, Get-AvailableMinutes, Get-MaxWeekdayWindow, Get-IndexesForWindow). Resets queue statuses at startup (DEFERRED/FAILED ? PENDING; SCHEDULED ? PENDING on extended windows). For each selected index: sets queue status to IN_PROGRESS, inserts IN_PROGRESS row into Index_ExecutionLog, executes ALTER INDEX REBUILD, captures post-rebuild fragmentation, calculates variance, updates ExecutionLog and Index_Registry, and deletes the queue entry (success) or sets it to FAILED. Updates Index_Status (EXECUTE row) with real-time counter increments. Logs per-database results to Index_ExecutionSummary (EXECUTE). Reports to Orchestrator v2.

**Continuous Work Claiming:** [sort:1] Uses a WHILE loop per database that re-queries the queue after each batch of indexes. When a batch completes and time remains in the maintenance window, it claims more work. This maximizes throughput during long windows instead of processing one batch and exiting.

**Schedule Re-Check Before Each Index:** [sort:2] Before each individual rebuild, the script re-evaluates Get-EffectiveSchedule to confirm the window is still open. If the window closes mid-batch, the script stops gracefully rather than overrunning into production hours. This provides per-index granularity on schedule enforcement.

**Edition-Aware Online/Offline:** [sort:3] The online_option from Index_Queue respects the database's index_allow_offline_rebuild setting. However, if the SQL Server edition is not Enterprise, the script overrides to OFFLINE regardless — online rebuilds require Enterprise Edition. This is noted in the log for transparency.


### Scan-IndexFragmentation.ps1

Performs the "expensive pass" of index maintenance: queries sys.dm_db_index_physical_stats for fragmentation data on each candidate index, updates Index_Registry with current fragmentation percentages, and manages the Index_Queue as a living queue — adding qualifying indexes, updating existing entries, removing entries that drop below threshold, and respecting IN_PROGRESS entries. Includes configurable time limits, abort flag support, and batch-level abort checking. Runs as a FIRE_AND_FORGET process under Orchestrator v2.

**Data Flow:** Reads GlobalConfig for thresholds (fragmentation threshold, min page count, rescan interval, skip-if-rebuilt days, scan time limit, batch check size, seconds-per-page coefficients). Reads ServerRegistry, DatabaseRegistry, and Index_DatabaseConfig for per-database overrides (index_maintenance_enabled, index_fragmentation_threshold, index_min_page_count, index_maintenance_priority, index_allow_offline_rebuild). Queries Index_Registry for scan candidates (not dropped, not excluded, above minimum page count, not recently scanned/rebuilt). Scans each candidate via dm_db_index_physical_stats (LIMITED mode) with scaled timeouts. Updates Index_Registry (current_fragmentation_pct, last_scanned_dttm). Manages Index_Queue (insert/update/delete based on threshold evaluation). Logs per-database results to Index_ExecutionSummary (SCAN). Updates Index_Status (SCAN row). Reports to Orchestrator v2.

**Scaled Timeouts:** [sort:1] Each dm_db_index_physical_stats query gets a timeout calculated as: base_seconds + (page_count / pages_per_second). This prevents small indexes from waiting too long on timeout while giving large indexes adequate time. Both coefficients (base and pages_per_second) are configurable via GlobalConfig.

**Abort and Time Limit Safety:** [sort:2] Checks the GlobalConfig abort flag (index_scan_abort) both at startup and periodically during processing (every batch_check_size indexes). Also supports a configurable time limit (index_scan_time_limit_minutes). Both enable graceful termination of long-running scans without killing the process, preserving all work completed before the stop.

**Inline Priority Score Calculation:** [sort:3] Calculate-PriorityScore is defined inline rather than in the shared xFACts-IndexFunctions.ps1 library. It computes a weighted score from four components (database priority, fragmentation severity, index size, deferral count) with all weights and tier boundaries read from GlobalConfig. Maximum possible score is 100.


### Sync-IndexRegistry.ps1

Performs the daily "cheap pass" reconciliation of index metadata across all enrolled databases. Discovers new indexes and adds them to Index_Registry, updates metadata (page count, fill factor, usage statistics) for existing indexes, and marks dropped indexes (present in registry but absent from source) as is_dropped = 1. Runs as a FIRE_AND_FORGET process under Orchestrator v2. Does NOT scan for fragmentation — that expensive operation is handled by Scan-IndexFragmentation.ps1.

**Data Flow:** Reads dbo.ServerRegistry (serverops_index_enabled master switch) and dbo.DatabaseRegistry joined to Index_DatabaseConfig (index_sync_enabled) for target databases. For AG Listener servers, detects the primary replica via sys.dm_hadr_availability_group_states. Queries sys.indexes, sys.dm_db_partition_stats, and sys.dm_db_index_usage_stats on each target database. Inserts new indexes into Index_Registry, updates existing entries with refreshed metadata and usage stats, and marks missing indexes as is_dropped = 1. Logs per-database results to Index_ExecutionSummary (SYNC process). Updates Index_Status (SYNC row). Reports to Orchestrator v2 via callback.

**Cheap Pass vs Expensive Pass Separation:** [sort:1] Registry sync queries sys.indexes and sys.dm_db_index_usage_stats — lightweight catalog and DMV queries that complete quickly even on large databases. Fragmentation scanning via sys.dm_db_index_physical_stats is deliberately separated into Scan-IndexFragmentation.ps1 because it requires physical page reads that can take 30-60 minutes per large database. This separation allows daily discovery without daily fragmentation cost.

**Replication System Table Exclusion:** [sort:2] Excludes known replication system tables by name (sysarticles, sysschemaarticles, etc.) and by pattern (MSpeer_%, MSpub_%) from discovery. These tables have system-managed indexes that should not be maintained by xFACts.

**Dropped Index Detection:** [sort:3] After processing all source indexes, iterates through existing registry entries and marks any not seen in the current pass as is_dropped = 1. This detects index deletions without querying the source again. Previously dropped indexes that reappear (same schema.table.index_name) are automatically restored — is_dropped is reset to 0 and dropped_detected_dttm is cleared.


### Update-IndexStatistics.ps1

Updates statistics on indexes based on modification thresholds and staleness age. Queries sys.dm_db_stats_properties for modification counters, updates statistics exceeding the modification threshold (logged individually to Index_StatsExecutionLog), and updates stale statistics exceeding the age threshold (logged as one cumulative row per database). Works exclusively from Index_Registry — only index-associated statistics are processed. Runs as a FIRE_AND_FORGET process under Orchestrator v2.

**Data Flow:** Reads GlobalConfig for thresholds (modification threshold percentage, max days stale, min rows, global sample percentage). Reads ServerRegistry, DatabaseRegistry, and Index_DatabaseConfig (stats_maintenance_enabled, stats_sample_pct) for per-database overrides. Queries Index_Registry for enrolled indexes with their stats_last_updated timestamps. Queries sys.dm_db_stats_properties on each target database for current modification counters. Joins the two datasets to identify MODIFICATION candidates (pct_modified >= threshold) and STALENESS candidates (days since update >= threshold). Executes UPDATE STATISTICS with the appropriate sample rate. Updates Index_Registry (stats_last_updated). Logs to Index_StatsExecutionLog (individual MODIFICATION rows, cumulative STALENESS rows per database). Logs to Index_ExecutionSummary (STATS). Updates Index_Status (STATS row). Reports to Orchestrator v2.

**Per-Database Sample Rate Override:** [sort:1] stats_sample_pct in Index_DatabaseConfig overrides the GlobalConfig default. A value of 0 means FULLSCAN. This allows critical databases with skewed distributions to use full scans while less critical databases use sampling for speed.


### xFACts-IndexFunctions.ps1

Shared function library dot-sourced by Execute-IndexMaintenance.ps1 and Scan-IndexFragmentation.ps1. Provides schedule evaluation (Get-EffectiveSchedule), available window calculation (Get-AvailableMinutes, Get-MaxWeekdayWindow), extended window detection (Test-IsExtendedWindow), index selection for windows (Get-IndexesForWindow), abort flag checking (Test-AbortRequested), and AG primary detection (Get-AGPrimary).

**Data Flow:** Reads Index_ExceptionSchedule (DATABASE ? SERVER ? GLOBAL scope evaluation), dbo.Holiday and Index_HolidaySchedule (two-table holiday check), and Index_DatabaseSchedule (default schedule fallback) in the Get-EffectiveSchedule function. Reads GlobalConfig abort flags (index_scan_abort, index_execute_abort) in Test-AbortRequested. Reads Index_Queue and Index_DatabaseConfig in Get-IndexesForWindow for best-fit index selection. All reads are performed against the xFACts database via Invoke-Sqlcmd.

**Three-Tier Schedule Resolution:** [sort:1] Get-EffectiveSchedule evaluates schedules in strict priority order: Exception (DATABASE scope ? SERVER scope ? GLOBAL scope) ? Holiday (weekdays only, two-table check) ? DatabaseSchedule. The first match at any tier determines the result — no further tables are consulted. This enables surgical overrides (freeze one database for a deployment) without affecting the rest of the fleet.

**Best-Fit Index Selection:** [sort:2] Get-IndexesForWindow implements a bin-packing algorithm for weekday processing: iterates through the queue by priority, selecting indexes whose estimated duration fits in the remaining time, and skipping larger ones to try smaller ones. On extended windows, it uses simple priority ordering since time is not constrained. Returns three arrays: selected indexes, newly SCHEDULED indexes (too large for any weekday window), and deferred SCHEDULED indexes (too large even for the current extended window).



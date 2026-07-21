# DM Operations

*Direct operations on Debt Manager production data — because sometimes you have to reach in and clean house*

Debt Manager has been collecting data for years. A lot of it represents consumers who are long since done — every account paid, returned, settled, or otherwise closed. DM Operations is the systematic process of removing those finished consumers from the production system while preserving the financial reporting their accounts contributed to. Done right, it’s invisible: the database gets smaller, queries get faster, backups get shorter, and the reports don’t skip a beat.






The Problem

Debt Manager’s production database is around 10 terabytes. A meaningful chunk of that belongs to consumers who haven’t been actively worked in years — their accounts are returned, paid, settled, or otherwise closed and there’s simply nothing left to do with them. These records have been accumulating because there was never a safe, reliable way to remove them.

It’s not as simple as “just delete the old stuff.” Every account touches dozens of related tables — transactions, payment journals, credit bureau transmissions, balance snapshots, encounter records, tags, notes. Delete things in the wrong order and the database throws errors. Delete the wrong things and financial reports break. Don’t delete anything and the database keeps growing, backups keep getting bigger, and queries keep getting slower.

Adding to the challenge: all of this data feeds a reporting warehouse that hundreds of people use every day. The archived records need to disappear from production but their financial history has to survive in the reports. It’s like removing a chapter from a book while making sure the table of contents still works.






Why Consumers, Not Accounts

The intuitive way to design archiving is account-by-account: find the accounts that qualify, archive them, move on. That was the original plan, and it tested cleanly against millions of records. But a quirk of how Debt Manager handles money exposed a structural problem.

When a consumer makes a single payment that gets distributed across multiple accounts — routine stuff, like a $50 payment splitting $25 to each of two accounts — Debt Manager records it in two places. There’s one consumer-level entry for the full $50, and one account-level entry per receiving account for $25 each. The two views are linked and have to agree.

If you archive only one of those two accounts, you remove its $25 record but leave the $50 consumer-level record pointing at a single surviving account. The math no longer adds up, and Debt Manager’s UI — which checks for exactly this kind of inconsistency — refuses to display the consumer’s financial activity. There’s no clean way to fix it after the fact. You can’t adjust the journal without falsifying a financial record. You can’t delete it while another account still references it. And there’s no “split the journal” operation because it was never designed to be split.

The fix was to change what archiving actually means. Instead of “delete aged accounts,” the process now means “delete consumers who have nothing left worth keeping.” A consumer becomes archive-eligible only when *every* one of their accounts qualifies. When that’s true, the entire consumer is removed in one pass — every account, every transaction, every consumer-level record. There’s no mismatch state because there’s no surviving account to mismatch with.

This also turns out to be what archiving *should* structurally mean for a debt collection platform. A consumer with a single still-active account isn’t really a candidate for archiving, even if their other ten accounts have been closed for a decade. They become a candidate when they’re fully done.






How a Batch Works

The archive process runs as a continuous loop of self-contained batches. Each batch picks up a set of eligible consumers, processes them end-to-end, and only then moves on to the next.



Select
Consumers
→
Re-Verify
Eligibility
→
Remove
Account Data
→
Preserve
Financials
→
Remove
Consumer

A single batch handles a consumer’s entire footprint — accounts first, financial migration in the middle, consumer record last.


Eligibility is established by a Debt Manager job that runs nightly: it looks at every consumer, checks whether all of their accounts are tagged for archive, and tags the consumer itself when the answer is yes. The xFACts process then picks those tagged consumers up, batch by batch.

Tags can go stale between when they’re applied and when a batch processes them — a new account might come in overnight, a merge might add accounts to a previously eligible consumer, the situation changes. So before any data is touched, every consumer in the batch gets re-verified at the moment of processing. If something has changed and the consumer is no longer fully eligible, they’re quietly removed from the batch and the now-incorrect tag is taken off them. They’ll be picked up again later, when conditions change.

For the consumers that pass re-verification, the process removes their account data first, hands their financial snapshot off to the reporting warehouse, and then removes the consumer record itself. The order matters — doing the financial handoff before all the account data is cleared, or after the consumer record is gone, would either duplicate data in the reports or lose it entirely. Doing it in the middle is the only safe place.






Smart Scheduling

The archive process is schedule-aware. Every hour of every day has a designated mode: full speed, reduced speed, or blocked. During business hours the process runs at a reduced pace to minimize any impact on the people using the system. Evenings and weekends are full speed. Certain hours are blocked entirely — particularly the window around the nightly reporting warehouse rebuild, which has to complete undisturbed.

The schedule is a visual grid that administrators can adjust in the Control Center. Need to pause archiving for a deployment? Block those hours. Want to push harder on a weekend? Open up the reduced hours to full. The process checks the schedule after every batch and adjusts automatically.

There’s also an emergency stop button. If something unexpected happens — a report looks wrong, performance dips, anything seems off — one click sets the abort flag and the process stops cleanly after finishing its current batch. No consumer is ever left half-archived.






Protecting the Reports

This is the part that keeps everyone honest. The reporting warehouse is rebuilt every night from whatever’s in the production database. If we just deleted consumers from production, their financial history would vanish from the reports the next morning — and with it, the numbers clients and internal teams rely on.

The solution is a handoff. Before a consumer’s data is removed from production, their financial snapshot is copied into a permanent archive within the reporting warehouse. The reports are built from a view that combines both the live data and the archived data, so from the report’s perspective nothing changes. The numbers are still there, still accurate, still in the right client’s totals. They’re just being served from a different place.






What About Shells?

A “shell” is a consumer record with no remaining accounts — the consumer exists in the system but has nothing attached to it. Under the new archive process, shells aren’t typically created in the first place: the consumer record gets removed in the same batch that removes their accounts. Done correctly, the archive process leaves no shells behind.

Shells still happen for other reasons, though. Consumer merges within Debt Manager produce them naturally. So does the occasional historical artifact from earlier processes. A separate shell purge utility handles these — same scheduling model, same care around the reporting warehouse, same Control Center visibility — but it’s now a much smaller-volume operation than it once would have been.






The Control Center View

The DM Operations page in the Control Center is a real-time window into the process. At a glance you can see how many consumers and accounts have been archived to date, how many are still waiting their turn, and how many shells have been purged. Today’s activity shows what’s happening right now — live counters that tick upward as batches complete. The execution history tracks daily totals, so you can watch the steady progress as millions of records work their way through.

Both schedules — archive and shell purge — are accessible from the page, and the abort buttons are right where you need them. Click into a day to see the individual batches that ran, and click into a batch to see the per-table detail of what was processed. If something needs a closer look, the path from “something seems off” to “here’s exactly what happened in batch 4,712 last Tuesday” is short.






The Bottom Line

DM Operations is doing something that should have been done years ago but never had a safe, reliable way to happen. It’s removing millions of fully-finished consumer records while making sure their financial history is preserved exactly where it needs to be. The database gets smaller, queries get faster, backups get shorter, and the reports don’t skip a beat.

It’s the kind of cleanup you only notice when it’s not being done.

---

# DM Operations — Control Center Guide

---

## Architecture
# DM Operations Architecture

The narrative page tells you *what* DM Operations does and *why*. This page tells you *how*. One unified PowerShell script, a companion shell purge utility, eleven tables, and a carefully ordered sequence of DELETE operations that navigate the foreign key maze of a 1,500-table OLTP database — all while keeping the reporting warehouse intact.



Schema Overview

DM Operations has two components under the `DmOps` schema: **Archive** (consumer-level archiving with embedded BIDATA migration) and **ShellPurge** (orphaned consumer cleanup). Each has its own set of operational tables, but they share the same schedule grid pattern and GlobalConfig structure.



| Table | Role | Cardinality |
| --- | --- | --- |
| `Archive_BatchLog` | One row per archive batch execution — the primary audit table | Many (one per batch) |
| `Archive_BatchDetail` | Per-table operation detail within each batch, prefixed by phase (A/AB/C) | ~230 per batch (one per delete order) |
| `Archive_ConsumerLog` | Per-consumer audit trail with BIDATA migration status | Many (one per consumer archived) |
| `Archive_ConsumerExceptionLog` | Consumers ejected from a batch by runtime re-verification | Many (grows as eligibility drift is detected) |
| `Archive_Schedule` | 7×24 weekly schedule grid (blocked/full/reduced) | Fixed: 7 rows |




| Table | Role | Cardinality |
| --- | --- | --- |
| `ShellPurge_BatchLog` | One row per shell purge batch execution | Many (one per batch) |
| `ShellPurge_BatchDetail` | Per-table operation detail within each batch | ~58 per batch |
| `ShellPurge_ConsumerLog` | Per-consumer audit trail | Many (one per consumer purged) |
| `ShellPurge_Schedule` | 7×24 weekly schedule grid | Fixed: 7 rows |
| `ShellPurge_ConsumerExceptionLog` | Consumers excluded from purge with reason codes | Many (seeded from initial scan, grows with discoveries) |







Archive Process

The archive script (`Execute-DmConsumerArchive.ps1`) runs as a continuous batch loop. Each iteration selects a batch of archive-eligible consumers, re-verifies them at the moment of processing, removes their account data, migrates financial snapshots to the reporting warehouse, removes the consumer record itself, and logs everything before checking the schedule and starting the next batch.




Pre-Flight
Config, BIDATA check,
schedule, abort flag,
startup lookups

→

Select & Verify
TC_ARCH consumers,
re-verify eligibility,
handle exceptions

→

Account Deletes
Phase A:
UDEFs + ~117
ordered tables

→

BIDATA Migration
Phase AB:
P→C atomic for
4 table pairs

→

Consumer Deletes
Phase C:
UDEFs + ~110
ordered tables




Eligibility is established by a Debt Manager nightly job that applies the `TC_ARCH` consumer-level tag to any consumer whose accounts all carry the `TA_ARCH` account-level tag. The xFACts script trusts that tag at selection time but re-verifies it before doing any work — tag state can drift between when it’s applied and when a batch processes the consumer.

The script opens a single persistent connection to `crs5_oltp` at session start and keeps it open for the entire run. This is critical — the temp tables created during batch loading survive across all operations within the session. A separate connection opens for the BIDATA migration since that targets a different database on a potentially different server.


Preview mode is real. Without the `-Execute` switch, the script runs end-to-end with full console and log output but writes *nothing* to any database. Logging functions short-circuit. Database write functions emit a `[Preview]` line describing what they would have done. Re-verification still queries to identify exceptions for accurate reporting, but the corresponding tag-removal UPDATEs are skipped. BIDATA migration is skipped entirely. The single exception is the in-memory cleanup of session-local temp tables, which has to run for the count queries downstream to be accurate — that operates on data the script itself just put in temp tables, not on production.







Runtime Re-Verification

The `TC_ARCH` tag is applied based on a point-in-time evaluation of consumer state. Between application and processing — minutes, hours, sometimes longer if the script paused for blocked schedule windows — new accounts can merge into a consumer through new business loads, account splits, or manual activity. Any new account arrives without `TA_ARCH`, which immediately invalidates the consumer’s archive eligibility. The tag, however, stays in place until xFACts notices and removes it.

Every batch re-verifies each candidate consumer at the moment of processing using the same eligibility logic the apply-job uses (count of consumer’s accounts equals count carrying active `TA_ARCH`), inverted to find consumers who *no longer* satisfy that condition. Future changes to eligibility logic can be made in one place and the re-verification query updated to match without behavioral drift.

For each excepted consumer, the script does four things in order:

| # | Action | Why this order |
| --- | --- | --- |
| 1 | Remove from current batch | Unconditional and first — guaranteed even if subsequent best-effort writes fail |
| 2 | Soft-delete the `TC_ARCH` row in `cnsmr_Tag` | Best-effort. The tag is now wrong; remove it so the next nightly re-evaluation re-tags correctly when conditions allow |
| 3 | Write an internal AR event to `cnsmr_accnt_ar_log` | Best-effort. Audit trail of why the tag was removed, paired CC/CC so it’s excluded from outbound client reporting |
| 4 | Append to `Archive_ConsumerExceptionLog` | xFACts-side audit with confirmation flags for steps 2 and 3 |


The batch processes whatever consumers pass the check and finalizes normally with a non-zero `exception_count`. There’s no backfill — if 200 of 10,000 candidates fail re-verification, the batch processes 9,800 and the 200 are released back to the DM job for future re-tagging once their account state changes. A batch where every candidate fails re-verification finalizes as Success with zero consumers archived and the full exception count logged.


Direct SQL, not API or BDL. Tag removal could in principle go through the DM API or a BDL file, but neither makes sense at scale. API calls slow under load, DM Jobs require explicit triggering, and stacking small BDLs per batch creates cleanup problems. Two SQL operations against properly indexed tables — an UPDATE and an INSERT — are fast, predictable, and don’t need any external orchestration.



Configurable values resolved at startup. The action code, result code, service-account user, and AR message text are stored in GlobalConfig as human-readable values (`CC`, `sqlmon`, etc.) and resolved to internal IDs via single-query lookups during script initialization. The Admin UI stays legible — nobody’s editing raw `actn_cd` bigints — and operations can update values without code changes. Failed lookups (misconfigured short value, deleted user, missing tag) cause fail-fast exit before opening the persistent connection.







The Delete Sequence

This is the heart of the archive process. Debt Manager’s schema has deep foreign key chains — deleting a consumer record requires first deleting from every table that references it, and every table that references those tables, and so on. The delete sequence is a hardcoded, FK-validated order of operations that navigates this dependency tree from the leaves down to the root.

Because the unified script handles both the account-level and consumer-level halves of the work, all delete operations live in a single namespace distinguished by prefix:

| Prefix | Phase | Scope | Rough count |
| --- | --- | --- | --- |
| `AU*` | Account UDEFs | User-defined extension tables on accounts, discovered dynamically at runtime | Variable (~11) |
| `A1` – `A117` | Account Phase 2 | Standard tables with FK relationships to the account record | ~117 |
| `AB1` – `AB4` | BIDATA Migration | Atomic P→C migration for the four reporting table pairs | 4 |
| `CU*` | Consumer UDEFs | User-defined extension tables on consumers | Variable |
| `C1` – `C110` | Consumer Phase 2 | Standard tables with FK relationships to the consumer record | ~110 |


The single namespace lets the two halves evolve independently — orders can be added or removed within Phase A without renumbering Phase C, and vice versa. `Archive_BatchDetail` rows are queryable by prefix (`WHERE delete_order LIKE 'A%'` shows all account-level work for a batch), which makes time-cost analysis straightforward.

Every DELETE operation runs under SNAPSHOT isolation to avoid blocking production queries, uses chunked deletes (default 5,000 rows per chunk) to manage transaction log volume, and has automatic deadlock retry with exponential backoff. If any operation fails, the batch stops — no further orders are processed because the FK chain means later deletes against incomplete state could produce inconsistent results.


Pre-materialized intermediate ID sets. Several tables in the delete sequence don’t have a direct foreign key to the account or consumer record — they’re two or three joins away. Rather than embedding complex subqueries in every DELETE, the script pre-materializes the intermediate ID sets into temp tables at batch start. This is the single biggest reason the process can run at production scale: subqueries against billion-row parent tables become single-join lookups against a small temp table.



Account expansion drops the TA_ARCH filter. When the account-level temp tables are populated, the script intentionally pulls *every* account on each archive-eligible consumer — not just the ones tagged `TA_ARCH`. By the time a consumer reaches consumer-level archive eligibility, every account already qualifies on the merits, and treating them all uniformly is structurally correct. Filtering at this point would over-engineer a check that was already passed at the consumer level.







BIDATA Migration

The reporting warehouse (BIDATA) is rebuilt every night from production data. Four tables form the financial reporting core: account demographics, payment details, combined account-payment records, and aggregated payment summaries. Each exists as a pair — a “P” (production/live) table and a “C” (completed/archived) table — fronted by a UNION view that the reports read from.

When consumers are archived, their P-table rows must be migrated to the corresponding C tables before the next nightly rebuild. Otherwise, the rebuild would either regenerate P rows from degraded OLTP state (producing incorrect snapshots) or lose the financial history entirely.

The migration for each of the four table pairs is atomic: INSERT into C with anonymization and purge flags applied, DELETE from P, wrapped in a single transaction with count validation. If the INSERT count doesn’t match the expected source count, the entire transaction rolls back. All four pairs must succeed or the batch flags as failed.

Why the Migration Sits in the Middle

The placement of the BIDATA migration within the unified script is deliberate. It runs *after* the account-level deletes and *before* the consumer-level deletes — not at either end. Each alternative breaks a different invariant:

| Placement | What goes wrong |
| --- | --- |
| At the start, before any deletes | If migration runs first and the OLTP delete sequence then fails, the next nightly BIDATA build repopulates P from OLTP (the account still exists). C now duplicates P. The UNION view shows duplicate financials. Reporting integrity broken. |
| At the end, after all deletes | If consumer-level deletes succeed but BIDATA migration then fails, the consumer is gone from OLTP with no reporting record migrated. The next BIDATA build can’t regenerate what isn’t there. Account history is lost forever. Worst case. |
| In the middle (chosen) | Account-level deletes complete first, removing accounts from OLTP. BIDATA migrates the financial snapshot to C — safe because the next BIDATA build won’t regenerate P rows for accounts no longer in OLTP. If consumer-level deletes subsequently fail, the consumer is in a recoverable “near-shell” state. Retry can complete the consumer-level work without compromising BIDATA integrity. |



BIDATA failure halts the batch — deliberately. If the migration fails, the consumer-level deletes are skipped and the consumer is left in near-shell state (accounts gone, consumer record intact, financial snapshot still in P tables awaiting migration). This is recoverable. A retry path picks the consumer back up from `Archive_ConsumerLog`, skips re-verification (the consumer is past that gate), and completes the consumer-level work. There’s no mid-batch abort — abort flags are checked only between full batches, never partway through one.



Anonymization is on by default. The C-table INSERT scrubs PII columns (names, addresses, phone numbers, etc.) while preserving every financial figure. The reports never needed the personal data; they need the dollars. A `-NoAnonymize` switch exists for special cases but is off by default in production. Purge flags are set unconditionally to mark these rows as archived for downstream reporting filters.







Non-Blocking Design

Both the archive and shell purge processes operate on a live production database that hundreds of people use during business hours. The single most important design requirement is that these processes must never block a user from doing their job. Every DELETE could potentially interfere with someone running a query, pulling a report, or working an account — so the scripts use a layered strategy to ensure that never happens.

**SNAPSHOT isolation.** Every DELETE statement executes under `SET TRANSACTION ISOLATION LEVEL SNAPSHOT`. Under normal database operation, a DELETE takes locks on the rows it’s modifying, and any SELECT trying to read those same rows has to wait. SNAPSHOT changes this equation. When SNAPSHOT is active, readers don’t take shared locks at all — they read from a point-in-time version of the data maintained in the version store. The result: our DELETEs and user queries can operate on the same tables simultaneously without either one waiting for the other. Users see a consistent view of the data as of when their query started, completely unaware that rows are being deleted underneath them.

**DEADLOCK_PRIORITY LOW.** Even with SNAPSHOT isolation, deadlocks can still occur when two operations try to modify the same rows — for example, if a DM process updates a record that our script is also trying to delete. When a deadlock happens, SQL Server has to pick a victim. `SET DEADLOCK_PRIORITY LOW` tells SQL Server to always sacrifice our session, never the user’s. The user’s operation completes successfully without interruption. Our script catches the deadlock error (SQL Server error 1205), waits, and retries. It will retry several times before giving up on that chunk. In practice, deadlocks at SNAPSHOT isolation are rare — the retry exists as a safety net.

**Chunked deletes.** Rather than issuing a single `DELETE` that removes tens of thousands of rows in one statement (which would hold locks for the duration and generate a massive transaction log entry), every DELETE is wrapped with a chunked loop. The script deletes a configurable number of rows at a time, pauses briefly between chunks to give other operations a window, and continues until no qualifying rows remain. The chunk size is configurable via GlobalConfig.

**Version store consideration.** SNAPSHOT isolation relies on the version store in tempdb to maintain row versions for concurrent readers. At production batch sizes, the version store grows during each batch and releases after the transaction completes. Production tempdb is sized to accommodate this, but it’s worth monitoring during the initial production runs.


The retry error codes. The script recognizes four retryable SQL Server errors: 1204 (lock resource limit exceeded), 1205 (deadlock victim), 1222 (lock timeout), and 3960 (snapshot update conflict). Any other error is treated as a hard failure that stops the batch. After a retry, the isolation level is explicitly reset to READ COMMITTED to prevent a stuck session state on the persistent connection.







Shell Purge

A “shell” is a consumer record with no remaining accounts. Under the unified consumer-level archive, shells aren’t typically created by xFACts — the consumer record is removed in the same batch that removes their accounts. But shells still occur naturally from consumer merges within Debt Manager and from historical artifacts of earlier processes. The shell purge script (`Execute-DmShellPurge.ps1`) handles those.

Shell purge follows the same batch loop pattern as the archive script. Eligible shells are identified by their placement in the WFAPURGE workgroup — a Debt Manager nightly job moves qualifying consumers there automatically. The purge script selects from this workgroup, validates candidates against the exclusion log, and executes a consumer-level delete sequence derived from the vendor’s own shell deletion procedure but reorganized for batch processing, audit logging, and the platform’s scheduling and abort mechanisms.

The Exclusion Log

Not every shell can be safely deleted. Some consumers have data in tables that aren’t covered by the delete sequence — either because those tables have no foreign key relationship to the consumer record (orphaned rows are acceptable) or because the data has business significance that warrants preservation.

The exclusion log tracks these consumers with reason codes. It was seeded with an initial scan of production data and grows incrementally as the purge process discovers new exclusions during batch validation. Excluded consumers are never retried — once logged, they’re filtered out of all future batch selections via a session-cached temp table for performance.

Suspense transactions get special handling: consumers with records in suspense tracking tables can be optionally included or excluded via a GlobalConfig toggle, allowing the team to make a policy decision about disposition without changing the code.


Why not just call the vendor proc? The vendor’s stored procedure processes one consumer at a time, with no parallelism, no batch control, no scheduling awareness, and no audit trail. The xFACts implementation processes batches of hundreds or thousands, runs within a configurable schedule, logs every operation at the per-table level, handles exclusions the vendor proc doesn’t account for, and integrates with the platform’s alerting and orchestration. Same delete sequence, very different operational characteristics.







Schedule System

Both processes share the same scheduling model: a 7-day × 24-hour grid where each cell has one of three values. **Full** means the process runs at full batch size. **Reduced** means it runs at a smaller batch size to minimize system impact. **Blocked** means it stops and doesn’t restart until the next allowed window.

The scripts check the schedule after every batch. If the mode changes from Full to Reduced, the batch size adjusts immediately for the next batch. If the mode changes to Blocked, the script exits its batch loop and terminates. The next launch (via the Orchestrator or manual trigger) picks up where it left off.

The three-state model was chosen over a simple allow/block because the database serves hundreds of users during business hours. Running at full speed during the day would create noticeable contention. Reduced mode keeps the process moving without impacting users. Full mode is reserved for evenings and weekends when the system is quiet.


Schedule changes don’t interrupt batches. A schedule change made while a batch is in flight has no effect on that batch — it completes normally. The new mode applies starting with the next batch. This is intentional: pulling the rug out mid-batch could leave a consumer half-archived, and the operational complexity of safely cancelling mid-flight isn’t worth it when waiting for batch completion is measured in minutes.







Performance Notes

The archive process went through extensive optimization during development. The biggest single win came from pre-materializing intermediate ID sets into temp tables instead of embedding subqueries in every DELETE — that took per-consumer cost from minutes to fractions of a second at scale. Other significant gains came from the persistent SQL connection (eliminating per-query connection overhead), a set of supporting indexes added to crs5_oltp specifically for the FK validation paths used during DELETE, and removing ORDER BY from batch selection queries (which dropped selection time from tens of seconds to milliseconds).

At full mode batch size, throughput settles into a few thousand rows per second across the full delete sequence, translating to a fraction of a second of work per consumer. The dominant cost is the consumer-level AR log delete — the bulk of AR events in Debt Manager are consumer-level (no specific account), so the consumer-level cleanup necessarily handles several times the row volume of the account-level cleanup. Per-row performance is reasonable for a heavily-indexed parent table; it’s the row count that drives the time, and there’s no architectural fix.


The first batch of a session is slower. Cold buffer cache, plan compilation, and possible statistics updates triggered by the larger volume make the first batch take 3–4× longer than subsequent ones at the same size. This is expected and self-resolves once the working set is hot. Monitoring should be calibrated to expect this rather than alert on it.







How Everything Connects


GlobalConfig

Both processes read their configuration from GlobalConfig entries under module `DmOps` with category `Archive` or `ShellPurge`. Settings include target instance, batch sizes (full and reduced), chunk size for delete operations, alerting toggle, the abort flag used for emergency stops from the Control Center, and — for the archive process — the human-readable values used to identify the service-account user and AR event codes used during exception logging.




ServerRegistry

Each process has an enable flag on the ServerRegistry row for its target server (`dmops_archive_enabled`, `dmops_shell_purge_enabled`). The scripts check this on startup and exit immediately if the flag is off. This provides a server-level kill switch independent of the schedule and abort mechanisms — useful for taking a single environment offline without touching configuration.




Teams Integration

Both processes use the shared `Send-TeamsAlert` function to queue alerts on batch failures. Alerting is controlled by a per-process GlobalConfig flag (`alerting_enabled`) so it can be suppressed during testing without removing the alert logic.




BIDATA Dependency

The archive process depends on BIDATA for the P→C financial migration. The BIDATA nightly build status is tracked in `BIDATA.BuildExecution`. The archive script’s pre-flight check confirms the build is complete before the cycle begins, and the schedule blocks processing in the hours before the next build kicks off so no batch can ever start during a build window. Shell purge has no BIDATA dependency.




crs5_oltp (Debt Manager OLTP)

Both scripts target `crs5_oltp` via the AG-aware connection system in `xFACts-Helpers.psm1`. Read operations (batch selection, ID materialization, re-verification queries) use the secondary replica. Write operations (DELETEs, tag-removal UPDATEs, AR event INSERTs) target the primary. When targeting a standalone test instance, both read and write go to the same server via direct connection.




Shared Orchestrator Functions

The archive script uses the platform’s shared `xFACts-OrchestratorFunctions.ps1` module for common operations: SQL data access (`Get-SqlData`, `Invoke-SqlNonQuery`), logging (`Write-Log`), Teams alerts (`Send-TeamsAlert`), preview-mode handling via `Initialize-XFActsScript`, and orchestrator callback (`Complete-OrchestratorTask`). Functions defined locally in the script handle DmOps-specific concerns — persistent connection management, the delete sequence orchestration, BIDATA migration, runtime re-verification — and don’t duplicate platform infrastructure.

---

## Reference

### Archive_BatchDetail

Per-table operation detail within each archive batch. One row per table in the delete sequence per batch, capturing the delete order, table name, rows affected, duration, and status. Provides a full replay of every batch execution for audit trails and troubleshooting. Multi-pass tables appear as separate rows with distinct delete_order values and pass descriptions.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| detail_id (IDENTITY) | bigint | No | IDENTITY | Auto-incrementing primary key. |
| batch_id | bigint | No | — | FK to Archive_BatchLog. Identifies which batch this table operation belongs to. |
| delete_order | varchar(10) | No | — | Execution order from the delete sequence. Varchar to accommodate UDEF dynamic orders (U1, U2, etc.) alongside numeric orders (7, 8, 9...). Matches the order logged in the script output. |
| table_name | varchar(128) | No | — | Target table name in crs5_oltp. Combined with delete_order and pass_description, uniquely identifies each operation in the delete sequence. |
| pass_description | varchar(200) | Yes | — | Human-readable description of the FK path for this delete operation. NULL for single-pass tables. Examples: Pass 1: via direct trnsctn, Pass 2: via pymnt_jrnl, soft-deleted only. |
| rows_affected | bigint | No | 0 | Number of rows deleted (execute mode) or that would be deleted (preview mode). Zero for skipped tables. |
| duration_ms | int | Yes | — | Time in milliseconds for this specific table operation. NULL for skipped tables. |
| status | varchar(20) | No | — | Outcome of this individual table operation. |
| error_message | varchar(2000) | Yes | — | Error detail when status is Failed. NULL for successful and skipped operations. |
| created_dttm | datetime | No | getdate() | When this detail row was created. Defaulted to GETDATE(). |

  - **PK_Archive_BatchDetail** (CLUSTERED): detail_id -- PRIMARY KEY
  - **IX_Archive_BatchDetail_batch_id** (NONCLUSTERED): batch_id [includes: delete_order, table_name, rows_affected, status]

**Check Constraints:**

  - **CK_Archive_BatchDetail_status**: `([status]='Failed' OR [status]='Skipped' OR [status]='Success')`

**Foreign Keys:**

  - **FK_Archive_BatchDetail_BatchLog**: batch_id -> DmOps.Archive_BatchLog.batch_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| status | Success | Table operation completed successfully. rows_affected contains the count of deleted rows. | 1 |
| status | Skipped | Table had zero rows matching the WHERE clause. No delete was executed. | 2 |
| status | Failed | Table operation failed. error_message contains the exception detail. The script stops further processing after any failure. | 3 |


### Archive_BatchLog

One row per archive batch execution. Captures the full execution summary including schedule mode, batch size, consumer/account counts, row deletion totals, per-table processing counts, timing, and final status. Primary audit and reporting table for archive operations. The CC DM Operations page reads this table for execution history display and daily summary metrics.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| batch_id (IDENTITY) | bigint | No | IDENTITY | Auto-incrementing primary key. Referenced by Archive_BatchDetail and Archive_ConsumerLog as the parent batch identifier. |
| batch_start_dttm | datetime | No | getdate() | When this batch execution started. Defaulted to GETDATE() on insert. Used for daily summary aggregation and execution history display. |
| batch_end_dttm | datetime | Yes | — | When this batch execution completed. NULL while the batch is still running. Updated on completion regardless of success or failure. |
| schedule_mode | varchar(10) | No | — | Which schedule mode was active when this batch ran. Determines the batch size used and provides historical context for performance analysis. |
| batch_size_used | int | No | — | Actual batch size (number of consumers) used for this batch. Reflects the GlobalConfig value corresponding to the schedule mode, or a manual override. |
| source_workgroup | varchar(10) | Yes | — | The crs5_oltp consumer workgroup this batch selected from, identifying the line of business: WFAARCH1 (1st party) or WFAARCH3 (3rd party). |
| consumer_count | int | No | 0 | Number of consumers selected in this batch. May be less than batch_size_used if fewer consumers have TA_ARCH tagged accounts remaining. |
| account_count | int | No | 0 | Number of tagged accounts expanded from the selected consumers. Each consumer may have one or more TA_ARCH tagged accounts. |
| exception_count | int | No | 0 | Number of consumers in the candidate batch that failed runtime TC_ARCH re-verification and were removed before the delete sequence ran. See DmOps.Archive_ConsumerExceptionLog for the per-consumer detail. |
| total_rows_deleted | bigint | No | 0 | Sum of all rows deleted across all tables in the delete sequence. In preview mode, this is the count of rows that would be deleted. |
| tables_processed | int | No | 0 | Number of tables in the delete sequence that had rows deleted (non-zero row count). |
| tables_skipped | int | No | 0 | Number of tables in the delete sequence that had zero rows and were skipped. |
| tables_failed | int | No | 0 | Number of tables in the delete sequence where the DELETE operation failed. Any value greater than zero results in a Failed batch status. |
| duration_ms | int | Yes | — | Total batch execution time in milliseconds. NULL while the batch is still running. Measured from script start to completion of cleanup. |
| status | varchar(20) | No | 'Running' | Final outcome of the batch execution. |
| error_message | varchar(2000) | Yes | — | Error detail when status is Failed. NULL on successful completion. Captures the first failure message from the delete sequence. |
| batch_retry | bit | No | 0 | Set to 1 when a retry batch has been created to reprocess this failed batch. Used by the retry check query (status = Failed AND batch_retry = 0) to identify unresolved failures. Set immediately at retry batch creation, not conditional on retry success. |
| retry_batch_id | bigint | Yes | — | Points to the batch_id that was created to retry this failed batch. NULL for non-failed batches and for failed batches that have not yet been retried. Populated at the same time as batch_retry. Provides audit trail linkage from original failure to retry attempt. |
| bidata_status | varchar(20) | Yes | — | Outcome of the BIDATA P-to-C migration step for this batch. NULL for batches that ran before this feature was added. |
| executed_by | varchar(128) | No | suser_sname() | Windows identity that executed this batch. Defaulted to SUSER_SNAME(). Distinguishes service account execution from manual runs. |

  - **PK_Archive_BatchLog** (CLUSTERED): batch_id -- PRIMARY KEY
  - **IX_Archive_BatchLog_start_dttm** (NONCLUSTERED): batch_start_dttm [includes: status, schedule_mode, consumer_count, account_count, total_rows_deleted, duration_ms]
  - **IX_Archive_BatchLog_status_start** (NONCLUSTERED): status, batch_start_dttm [includes: consumer_count, account_count, total_rows_deleted]

**Check Constraints:**

  - **CK_Archive_BatchLog_bidata_status**: `([bidata_status]='Skipped' OR [bidata_status]='Failed' OR [bidata_status]='Success')`
  - **CK_Archive_BatchLog_schedule_mode**: `([schedule_mode]='Retry' OR [schedule_mode]='Manual' OR [schedule_mode]='Reduced' OR [schedule_mode]='Full')`
  - **CK_Archive_BatchLog_source_workgroup**: `([source_workgroup]='WFAARCH3' OR [source_workgroup]='WFAARCH1')`
  - **CK_Archive_BatchLog_status**: `([status]='Aborted' OR [status]='Failed' OR [status]='Success' OR [status]='Running')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| status | Running | Batch is currently executing. Set on initial insert, updated to final status on completion. | 1 |
| bidata_status | Success | All four BIDATA table pairs (GenAccount, GenAccPay, GenAccPayAgg, GenPayment) migrated successfully for the batch. ConsumerLog.bidata_migrated set to 1 for all accounts. | 1 |
| schedule_mode | Full | Batch ran during a full-mode schedule window using the standard batch_size from GlobalConfig. | 1 |
| schedule_mode | Reduced | Batch ran during a reduced-mode schedule window using batch_size_reduced from GlobalConfig. | 2 |
| bidata_status | Failed | One or more BIDATA table migrations failed. ConsumerLog.bidata_migrated remains 0. Check Archive_BatchDetail for B1-B4 entries. | 2 |
| status | Success | Batch completed with zero table failures. | 2 |
| status | Failed | One or more tables in the delete sequence failed. The script stops on first failure. Check error_message and Archive_BatchDetail for specifics. | 3 |
| bidata_status | Skipped | BIDATA migration was not performed for this batch. Occurs when BIDATA instance is unavailable or during testing without the migration step enabled. | 3 |
| schedule_mode | Manual | Batch ran with manual parameter overrides, outside of schedule-driven execution. | 3 |
| schedule_mode | Retry | Batch was created to reprocess a previously failed batch. Consumer and account list sourced from Archive_ConsumerLog for the original failed batch rather than from TA_ARCH tag selection. | 4 |
| status | Aborted | Batch was terminated by the archive_abort emergency shutoff flag in GlobalConfig. The current batch completed but no further batches were started. | 4 |

**Recent batch history** [sort:1] -- Shows the last 20 archive batches with key metrics.

```sql
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
```

**Daily archive summary** [sort:2] -- Aggregated daily totals for accounts archived and rows deleted.

```sql
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
```

**BIDATA migration status summary** [sort:3] -- Breakdown of BIDATA P-to-C migration outcomes across all batches.

```sql
SELECT
    bidata_status,
    COUNT(*) AS batch_count,
    SUM(account_count) AS total_accounts
FROM DmOps.Archive_BatchLog
WHERE bidata_status IS NOT NULL
GROUP BY bidata_status
ORDER BY batch_count DESC;
```


### Archive_ConsumerExceptionLog

Audit trail of consumers selected as TC_ARCH-eligible at the start of a batch but removed by runtime re-verification because one or more of their accounts no longer carry TA_ARCH. The DM tagging job was correct when it ran — the consumer state changed afterward, typically a new account merging in. This is a state-change audit, not an error log. Captures which batch detected the change plus confirmation flags that the cnsmr_Tag soft-delete and the cnsmr_accnt_ar_log AR event both succeeded.

**Data Flow:** Execute-DmConsumerArchive.ps1 writes one row per consumer that fails runtime TC_ARCH re-verification within a batch. The script first inserts the row with both confirmation flags at 0, then performs the soft-delete UPDATE on crs5_oltp.dbo.cnsmr_Tag and the consumer-level AR event INSERT into crs5_oltp.dbo.cnsmr_accnt_ar_log, updating tag_removed and ar_event_written to 1 as each operation succeeds.

**State-Change Audit, Not Error Log:** [sort:1] Exceptions captured here are not errors. The TC_ARCH apply-job correctly identified each consumer as eligible at the time it ran. Between that point and when the archive process picks the consumer up, the consumer state changed — typically a new account merged in without TA_ARCH. The runtime re-verification catches the drift and removes the consumer from the batch with full audit trail.

**No Reason Column:** [sort:2] Only one reason for an exception exists by design: at least one account on the consumer lacks TA_ARCH at runtime.

**Two Confirmation Bits:** [sort:3] tag_removed and ar_event_written are tracked separately because the operations target different tables in crs5_oltp.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| exception_id (IDENTITY) | bigint | No | IDENTITY | Surrogate primary key for the exception row. |
| batch_id | bigint | No | — | Foreign key to Archive_BatchLog identifying the batch that detected this exception. Joins to Archive_BatchLog.batch_id. |
| cnsmr_id | bigint | No | — | The consumer removed from the batch by re-verification. References crs5_oltp.dbo.cnsmr.cnsmr_id (no FK constraint — cross-database). |
| cnsmr_idntfr_agncy_id | bigint | No | — | Standard agency identifier captured at exception time for cross-system reconciliation. Matches crs5_oltp.dbo.cnsmr.cnsmr_idntfr_agncy_id. |
| detected_dttm | datetime | No | getdate() | When the runtime re-verification check identified this consumer as no longer eligible. Defaults to GETDATE() at insert time. |
| tag_removed | bit | No | 0 | Confirmation that the soft-delete UPDATE against crs5_oltp.dbo.cnsmr_Tag (setting cnsmr_tag_sft_delete_flg = 'Y' on the consumer's active TC_ARCH row) succeeded. 0 = update failed or not yet attempted, 1 = update confirmed. |
| ar_event_written | bit | No | 0 | Confirmation that the AR event INSERT into crs5_oltp.dbo.cnsmr_accnt_ar_log (consumer-level event with cnsmr_accnt_id = NULL, actn_cd/rslt_cd = CC) succeeded. 0 = insert failed or not yet attempted, 1 = insert confirmed. |

  - **PK_Archive_ConsumerExceptionLog** (CLUSTERED): exception_id -- PRIMARY KEY
  - **IX_Archive_ConsumerExceptionLog_batch_id** (NONCLUSTERED): batch_id
  - **IX_Archive_ConsumerExceptionLog_cnsmr_id** (NONCLUSTERED): cnsmr_id

  - **Archive_BatchLog**: [sort:1] Operational link via batch_id (no FK constraint). Every exception row carries the batch_id of the batch that detected it. Joining to Archive_BatchLog by batch_id provides the operational context (schedule mode, batch size, status, duration) for when the exception occurred. The exception_count column on Archive_BatchLog provides a pre-aggregated count for fast batch-level visibility.
  - **cnsmr_Tag (crs5_oltp.dbo)**: [sort:2] No FK constraint (cross-database) but operationally critical. tag_removed = 1 indicates Execute-DmConsumerArchive.ps1 successfully soft-deleted the consumer's active TC_ARCH row in crs5_oltp.dbo.cnsmr_Tag (cnsmr_tag_sft_delete_flg = 'Y'). After the soft-delete the consumer falls out of the candidate pool naturally on subsequent batches.
  - **cnsmr_accnt_ar_log (crs5_oltp.dbo)**: [sort:3] No FK constraint (cross-database) but operationally critical. ar_event_written = 1 indicates a consumer-level AR event was inserted.


### Archive_ConsumerLog

Audit trail of every consumer and account archived. One row per account per batch — tall and skinny by design. Captures the minimum identifying fields needed for BI cross-reference, creditor-level archive counts, and reconciliation to ensure no consumers are overlooked in the transition from live to static tables.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| batch_id | bigint | No | — | FK to Archive_BatchLog. Identifies which batch this record was archived in. Part of the composite primary key. |
| cnsmr_id | bigint | No | — | Internal consumer ID from crs5_oltp. The system-generated primary key for the consumer record. |
| cnsmr_idntfr_agncy_id | varchar(50) | No | — | Agency-assigned consumer identifier visible in the Debt Manager GUI. The human-readable consumer number used by operations staff. |
| cnsmr_accnt_id | bigint | No | — | Internal account ID from crs5_oltp. The system-generated primary key for the account record. Part of the composite primary key. |
| cnsmr_accnt_idntfr_agncy_id | varchar(50) | No | — | Agency-assigned account identifier visible in the Debt Manager GUI. The human-readable account number used by operations staff. |
| crdtr_id | bigint | No | — | Creditor (client) ID from cnsmr_accnt.crdtr_id. Enables archive counts by client for reporting and business review. |
| bidata_migrated | bit | No | 0 | Whether this account's BIDATA records have been migrated from the P (production) tables to the C (static) tables. Set to 1 after successful P-to-C transaction for the batch. Default 0. Enables reconciliation queries to identify accounts archived but not yet migrated. |
| created_dttm | datetime | No | getdate() | When this record was logged. Defaulted to GETDATE(). Represents the time the batch captured this record, not the time the account data was deleted. |

  - **PK_Archive_ConsumerLog** (CLUSTERED): batch_id, cnsmr_accnt_id -- PRIMARY KEY
  - **IX_Archive_ConsumerLog_cnsmr_accnt_id** (NONCLUSTERED): cnsmr_accnt_id [includes: cnsmr_id, crdtr_id, batch_id]
  - **IX_Archive_ConsumerLog_cnsmr_id** (NONCLUSTERED): cnsmr_id [includes: cnsmr_accnt_id, crdtr_id]
  - **IX_Archive_ConsumerLog_crdtr_id** (NONCLUSTERED): crdtr_id [includes: cnsmr_id, cnsmr_accnt_id, batch_id]

**Foreign Keys:**

  - **FK_Archive_ConsumerLog_BatchLog**: batch_id -> DmOps.Archive_BatchLog.batch_id

**Archived accounts by creditor** [sort:1] -- Count of archived accounts per creditor — useful for client reporting.

```sql
SELECT
    crdtr_id,
    COUNT(*) AS accounts_archived
FROM DmOps.Archive_ConsumerLog
GROUP BY crdtr_id
ORDER BY accounts_archived DESC;
```

**Accounts not yet BIDATA migrated** [sort:2] -- Accounts that were archived but whose BIDATA P-to-C migration has not been confirmed.

```sql
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
```


### Archive_Schedule

Weekly schedule grid controlling archive execution mode per hour. Seven rows (one per day of week) with 24 tinyint columns representing hours. Each cell is 0 (blocked), 1 (full batch size), or 2 (reduced batch size). Execute-DmArchive.ps1 reads the current day/hour cell to determine whether to run and at what batch size. Managed via the DM Operations CC page schedule modal with drag-to-paint interaction.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| day_of_week | tinyint | No | — | Day of week: 1=Sunday, 2=Monday, 3=Tuesday, 4=Wednesday, 5=Thursday, 6=Friday, 7=Saturday. Matches SQL Server DATEPART(dw) convention. |
| hr00 | tinyint | No | 0 | Execution mode for midnight to 1 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr01 | tinyint | No | 0 | Execution mode for 1 AM to 2 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr02 | tinyint | No | 0 | Execution mode for 2 AM to 3 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr03 | tinyint | No | 0 | Execution mode for 3 AM to 4 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr04 | tinyint | No | 0 | Execution mode for 4 AM to 5 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr05 | tinyint | No | 0 | Execution mode for 5 AM to 6 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr06 | tinyint | No | 0 | Execution mode for 6 AM to 7 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr07 | tinyint | No | 0 | Execution mode for 7 AM to 8 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr08 | tinyint | No | 0 | Execution mode for 8 AM to 9 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr09 | tinyint | No | 0 | Execution mode for 9 AM to 10 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr10 | tinyint | No | 0 | Execution mode for 10 AM to 11 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr11 | tinyint | No | 0 | Execution mode for 11 AM to noon. 0=blocked, 1=full batch, 2=reduced batch. |
| hr12 | tinyint | No | 0 | Execution mode for noon to 1 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr13 | tinyint | No | 0 | Execution mode for 1 PM to 2 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr14 | tinyint | No | 0 | Execution mode for 2 PM to 3 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr15 | tinyint | No | 0 | Execution mode for 3 PM to 4 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr16 | tinyint | No | 0 | Execution mode for 4 PM to 5 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr17 | tinyint | No | 0 | Execution mode for 5 PM to 6 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr18 | tinyint | No | 0 | Execution mode for 6 PM to 7 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr19 | tinyint | No | 0 | Execution mode for 7 PM to 8 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr20 | tinyint | No | 0 | Execution mode for 8 PM to 9 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr21 | tinyint | No | 0 | Execution mode for 9 PM to 10 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr22 | tinyint | No | 0 | Execution mode for 10 PM to 11 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr23 | tinyint | No | 0 | Execution mode for 11 PM to midnight. 0=blocked, 1=full batch, 2=reduced batch. |
| created_dttm | datetime | No | getdate() | When this schedule row was created. |
| created_by | varchar(128) | No | suser_sname() | Who created this schedule row. |
| modified_dttm | datetime | Yes | — | When this schedule row was last modified. |
| modified_by | varchar(128) | Yes | — | Who last modified this schedule row. |

  - **PK_Archive_Schedule** (CLUSTERED): day_of_week -- PRIMARY KEY

**Check Constraints:**

  - **CK_Archive_Schedule_day_of_week**: `([day_of_week]>=(1) AND [day_of_week]<=(7))`
  - **CK_Archive_Schedule_hr00**: `([hr00]=(2) OR [hr00]=(1) OR [hr00]=(0))`
  - **CK_Archive_Schedule_hr01**: `([hr01]=(2) OR [hr01]=(1) OR [hr01]=(0))`
  - **CK_Archive_Schedule_hr02**: `([hr02]=(2) OR [hr02]=(1) OR [hr02]=(0))`
  - **CK_Archive_Schedule_hr03**: `([hr03]=(2) OR [hr03]=(1) OR [hr03]=(0))`
  - **CK_Archive_Schedule_hr04**: `([hr04]=(2) OR [hr04]=(1) OR [hr04]=(0))`
  - **CK_Archive_Schedule_hr05**: `([hr05]=(2) OR [hr05]=(1) OR [hr05]=(0))`
  - **CK_Archive_Schedule_hr06**: `([hr06]=(2) OR [hr06]=(1) OR [hr06]=(0))`
  - **CK_Archive_Schedule_hr07**: `([hr07]=(2) OR [hr07]=(1) OR [hr07]=(0))`
  - **CK_Archive_Schedule_hr08**: `([hr08]=(2) OR [hr08]=(1) OR [hr08]=(0))`
  - **CK_Archive_Schedule_hr09**: `([hr09]=(2) OR [hr09]=(1) OR [hr09]=(0))`
  - **CK_Archive_Schedule_hr10**: `([hr10]=(2) OR [hr10]=(1) OR [hr10]=(0))`
  - **CK_Archive_Schedule_hr11**: `([hr11]=(2) OR [hr11]=(1) OR [hr11]=(0))`
  - **CK_Archive_Schedule_hr12**: `([hr12]=(2) OR [hr12]=(1) OR [hr12]=(0))`
  - **CK_Archive_Schedule_hr13**: `([hr13]=(2) OR [hr13]=(1) OR [hr13]=(0))`
  - **CK_Archive_Schedule_hr14**: `([hr14]=(2) OR [hr14]=(1) OR [hr14]=(0))`
  - **CK_Archive_Schedule_hr15**: `([hr15]=(2) OR [hr15]=(1) OR [hr15]=(0))`
  - **CK_Archive_Schedule_hr16**: `([hr16]=(2) OR [hr16]=(1) OR [hr16]=(0))`
  - **CK_Archive_Schedule_hr17**: `([hr17]=(2) OR [hr17]=(1) OR [hr17]=(0))`
  - **CK_Archive_Schedule_hr18**: `([hr18]=(2) OR [hr18]=(1) OR [hr18]=(0))`
  - **CK_Archive_Schedule_hr19**: `([hr19]=(2) OR [hr19]=(1) OR [hr19]=(0))`
  - **CK_Archive_Schedule_hr20**: `([hr20]=(2) OR [hr20]=(1) OR [hr20]=(0))`
  - **CK_Archive_Schedule_hr21**: `([hr21]=(2) OR [hr21]=(1) OR [hr21]=(0))`
  - **CK_Archive_Schedule_hr22**: `([hr22]=(2) OR [hr22]=(1) OR [hr22]=(0))`
  - **CK_Archive_Schedule_hr23**: `([hr23]=(2) OR [hr23]=(1) OR [hr23]=(0))`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 | 0 | Blocked. Archive processing will not run during this hour. Script exits cleanly if currently in a blocked window. | 1 |
| hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 | 1 | Full. Archive processing runs at the full batch size configured in GlobalConfig (batch_size). Intended for off-hours and weekends. | 2 |
| hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 | 2 | Reduced. Archive processing runs at the reduced batch size configured in GlobalConfig (batch_size_reduced). Intended for business hours to minimize end-user impact. | 3 |


### Archive_WorkgroupRegistry

Authoritative registry of the DM workgroups that constitute the archive candidate pool, per line of business (1P/3P). The DM nightly tagging jobs (account-level JA_ARCH* and consumer-level JC_ARCH*) filter their candidate selection against the active rows in this table via cross-database reference, so pool changes are a row insert/update here rather than a DM job edit. Deliberately excludes the archive destination workgroups (WFAARCH1/WFAARCH3): this table defines where candidates come FROM, never where the archive process operates.

**Explicit List Over Pattern Matching:** [sort:1] Workgroup membership is an explicit per-row decision rather than a name-pattern rule. Explicit rows make inclusion a deliberate act with an audit trail.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| registry_id (IDENTITY) | int | No | IDENTITY | Surrogate identity key. |
| wrkgrp_shrt_nm | varchar(8) | No | — | DM workgroup short name, matching crs5_oltp.dbo.wrkgrp.wrkgrp_shrt_nm (VARCHAR(8)). Stored by name rather than wrkgrp_id because names are stable across environments while ids are environment-specific surrogates; consumers resolve the id at point of use. |
| lob | char(2) | No | — | Line of business this workgroup belongs to: 1P (first party) or 3P (third party). Each tagger job selects only its own LOB slice. |
| description | varchar(500) | Yes | — | Free-text rationale for the workgroup's inclusion in the candidate pool (client context, in-scope confirmation date, etc.). |
| is_active | bit | No | 1 | Soft enable/disable. Inactive rows are retained for history but excluded by all consumers. |
| created_dttm | datetime | No | getdate() | Row creation timestamp. |
| created_by | varchar(128) | No | suser_sname() | Login that created the row. |
| modified_dttm | datetime | Yes | — | Timestamp of the most recent modification. NULL when never modified. |
| modified_by | varchar(128) | Yes | — | Login that performed the most recent modification. NULL when never modified. |

  - **PK_Archive_WorkgroupRegistry** (CLUSTERED): registry_id -- PRIMARY KEY
  - **UQ_Archive_WorkgroupRegistry_wrkgrp_shrt_nm** (NONCLUSTERED): wrkgrp_shrt_nm

**Check Constraints:**

  - **CK_Archive_WorkgroupRegistry_lob**: `([lob]='3P' OR [lob]='1P')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| lob | 1P | First-party line of business. Candidate pool for the JA_ARCH1/JC_ARCH1 nightly jobs feeding WFAARCH1. | 1 |
| lob | 3P | Third-party line of business. Candidate pool for the JA_ARCH3/JC_ARCH3 nightly jobs feeding WFAARCH3. | 2 |


### ShellPurge_BatchDetail

Per-table operation detail within each shell purge batch. One row per table in the delete sequence per batch, capturing the delete order, table name, rows affected, duration, and status. Provides a full replay of every batch execution for audit trails and troubleshooting.

**Data Flow:** Execute-DmShellPurge.ps1 inserts one row per table operation during the delete sequence. Written inline as each table is processed — not batch-inserted at the end. Status is set at write time based on whether the delete succeeded, was skipped (zero rows), or failed.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| detail_id (IDENTITY) | bigint | No | IDENTITY | Auto-incrementing primary key. |
| batch_id | bigint | No | — | FK to ShellPurge_BatchLog. Identifies which batch this table operation belongs to. |
| delete_order | varchar(10) | No | — | Execution order from the delete sequence. Varchar to accommodate UDEF dynamic orders (U1, U2, etc.) alongside numeric orders. Matches the order logged in the script output. |
| table_name | varchar(128) | No | — | Target table name in crs5_oltp. Combined with delete_order and pass_description, uniquely identifies each operation in the delete sequence. |
| pass_description | varchar(200) | Yes | — | Human-readable description of the FK path for this delete operation. NULL for single-pass tables. Examples: via pymnt_jrnl, via smmry, Pass 1: direct, Pass 2: via pymnt_jrnl. |
| rows_affected | bigint | No | 0 | Number of rows deleted (execute mode) or that would be deleted (preview mode). Zero for skipped tables. |
| duration_ms | int | Yes | — | Time in milliseconds for this specific table operation. NULL for skipped tables. |
| status | varchar(20) | No | — | Outcome of this individual table operation. |
| error_message | varchar(2000) | Yes | — | Error detail when status is Failed. NULL for successful and skipped operations. |
| created_dttm | datetime | No | getdate() | When this detail row was created. Defaulted to GETDATE(). |

  - **PK_ShellPurge_BatchDetail** (CLUSTERED): detail_id -- PRIMARY KEY
  - **IX_ShellPurge_BatchDetail_batch_id** (NONCLUSTERED): batch_id [includes: delete_order, table_name, rows_affected, status]

**Check Constraints:**

  - **CK_ShellPurge_BatchDetail_status**: `([status]='Failed' OR [status]='Skipped' OR [status]='Success')`

**Foreign Keys:**

  - **FK_ShellPurge_BatchDetail_BatchLog**: batch_id -> DmOps.ShellPurge_BatchLog.batch_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| status | Success | Table operation completed successfully. rows_affected contains the count of deleted rows. | 1 |
| status | Skipped | Table had zero rows matching the WHERE clause. No delete was executed. | 2 |
| status | Failed | Table operation failed. error_message contains the exception detail. The script stops further processing after any failure. | 3 |

**Batch detail replay** [sort:1] -- Full detail for a specific batch — shows every table operation in execution order.

```sql
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
```

**Slowest table operations** [sort:2] -- Tables with the longest delete times — candidates for index investigation.

```sql
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
```


### ShellPurge_BatchLog

One row per shell purge batch execution. Captures the full execution summary including schedule mode, batch size, consumer counts, row deletion totals, per-table processing counts, timing, and final status. Primary audit and reporting table for shell purge operations.

**Data Flow:** Execute-DmShellPurge.ps1 inserts a Running row at batch start with schedule mode and batch size. On batch completion, updates the row with consumer count, total rows deleted, table processing counts, duration, and final status. The CC DM Operations page reads this table for execution history display and daily summary metrics.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| batch_id (IDENTITY) | bigint | No | IDENTITY | Auto-incrementing primary key. Referenced by ShellPurge_BatchDetail and ShellPurge_ConsumerLog as the parent batch identifier. |
| batch_start_dttm | datetime | No | getdate() | When this batch execution started. Defaulted to GETDATE() on insert. Used for daily summary aggregation and execution history display. |
| batch_end_dttm | datetime | Yes | — | When this batch execution completed. NULL while the batch is still running. Updated on completion regardless of success or failure. |
| schedule_mode | varchar(10) | No | — | Which schedule mode was active when this batch ran. Determines the batch size used and provides historical context for performance analysis. |
| batch_size_used | int | No | — | Actual batch size (number of consumers) used for this batch. Reflects the GlobalConfig value corresponding to the schedule mode, or a manual override. |
| consumer_count | int | No | 0 | Number of shell consumers selected in this batch. May be less than batch_size_used if fewer eligible consumers remain in the WFAPURGE workgroup. |
| total_rows_deleted | bigint | No | 0 | Sum of all rows deleted across all tables in the delete sequence. In preview mode, this is the count of rows that would be deleted. |
| tables_processed | int | No | 0 | Number of tables in the delete sequence that had rows deleted (non-zero row count). |
| tables_skipped | int | No | 0 | Number of tables in the delete sequence that had zero rows and were skipped. |
| tables_failed | int | No | 0 | Number of tables in the delete sequence where the DELETE operation failed. Any value greater than zero results in a Failed batch status. |
| duration_ms | int | Yes | — | Total batch execution time in milliseconds. NULL while the batch is still running. |
| status | varchar(20) | No | 'Running' | Final outcome of the batch execution. |
| error_message | varchar(2000) | Yes | — | Error detail when status is Failed. NULL on successful completion. Captures the first failure message from the delete sequence. |
| executed_by | varchar(128) | No | suser_sname() | Windows identity that executed this batch. Defaulted to SUSER_SNAME(). Distinguishes service account execution from manual runs. |

  - **PK_ShellPurge_BatchLog** (CLUSTERED): batch_id -- PRIMARY KEY
  - **IX_ShellPurge_BatchLog_start_dttm** (NONCLUSTERED): batch_start_dttm [includes: status, schedule_mode, consumer_count, total_rows_deleted, duration_ms]
  - **IX_ShellPurge_BatchLog_status_start** (NONCLUSTERED): status, batch_start_dttm [includes: consumer_count, total_rows_deleted]

**Check Constraints:**

  - **CK_ShellPurge_BatchLog_schedule_mode**: `([schedule_mode]='Manual' OR [schedule_mode]='Reduced' OR [schedule_mode]='Full')`
  - **CK_ShellPurge_BatchLog_status**: `([status]='Aborted' OR [status]='Failed' OR [status]='Success' OR [status]='Running')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| status | Running | Batch is currently executing. Set on initial insert, updated to final status on completion. | 1 |
| schedule_mode | Full | Batch ran during a full-mode schedule window using the standard batch_size from GlobalConfig. | 1 |
| schedule_mode | Reduced | Batch ran during a reduced-mode schedule window using batch_size_reduced from GlobalConfig. | 2 |
| status | Success | Batch completed with zero table failures. | 2 |
| status | Failed | One or more tables in the delete sequence failed. The script stops on first failure. Check error_message and ShellPurge_BatchDetail for specifics. | 3 |
| schedule_mode | Manual | Batch ran with manual parameter overrides, outside of schedule-driven execution. | 3 |
| status | Aborted | Batch was terminated by the shell_purge_abort emergency shutoff flag in GlobalConfig. The current batch completed but no further batches were started. | 4 |

**Recent batch history** [sort:1] -- Shows the last 20 shell purge batches with key metrics.

```sql
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
```

**Daily purge summary** [sort:2] -- Aggregated daily totals for consumers purged and rows deleted.

```sql
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
```

**Failed batches with error detail** [sort:3] -- All failed batches with their error messages for investigation.

```sql
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
```


### ShellPurge_ConsumerExceptionLog

Consumers excluded from shell purge due to qualifying data in tables not covered by the delete sequence. One row per consumer per exception reason. Maintained incrementally as the shell purge script discovers new exceptions during batch validation. Used as a filter in the candidate selection query to avoid re-evaluating expensive NOT EXISTS checks against large tables on every batch.

**Data Flow:** Maintained incrementally by Execute-DmShellPurge.ps1 which inserts new excluded consumers discovered during batch validation. Read by the script at session start to load into a temp table on the target connection for per-batch candidate filtering. A consumer may have multiple rows with different exception reasons.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| cnsmr_id | bigint | No | — | Internal consumer ID from crs5_oltp. Part of the composite primary key with exception_reason. |
| cnsmr_idntfr_agncy_id | varchar(50) | No | — | Agency-assigned consumer identifier. Stored for human-readable reference during triage and reporting. |
| exception_reason | varchar(50) | No | — | Which exception check flagged this consumer. Matches the table or condition name from the exception check list. A consumer may have multiple rows with different reasons. |
| created_dttm | datetime | No | getdate() | SELECT      exception_reason,      COUNT(*) AS consumer_count  FROM DmOps.ShellPurge_ConsumerExceptionLog  GROUP BY exception_reason  ORDER BY consumer_count DESC; |

  - **PK_ShellPurge_ConsumerExceptionLog** (CLUSTERED): cnsmr_id, exception_reason -- PRIMARY KEY
  - **IX_ShellPurge_ConsumerExceptionLog_reason** (NONCLUSTERED): exception_reason [includes: cnsmr_id]

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| exception_reason | cnsmr_pymnt_jrnl | Consumer has rows in cnsmr_pymnt_jrnl. Payment journal data exists that is not deleted by the shell purge sequence. | 1 |
| exception_reason | dcmnt_rqst | Consumer has rows in dcmnt_rqst (entity association code 2). Document request data exists that is intentionally left as orphaned historical records. | 2 |
| exception_reason | agnt_crdtbl_actvty | Consumer has rows in agnt_crdtbl_actvty via direct cnsmr_id reference. | 3 |
| exception_reason | agnt_crdtbl_actvty_via_smmry | Consumer has agnt_crdtbl_actvty records reachable through the schdld_pymnt_smmry chain. | 4 |
| exception_reason | bnkrptcy | Consumer has rows in bnkrptcy. Bankruptcy records are retained for legal compliance. | 5 |
| exception_reason | schdld_pymnt_smmry | Consumer has rows in schdld_pymnt_smmry. Scheduled payment summary data exists that is not safely deletable without cascading through child tables. | 6 |
| exception_reason | sspns_trnsctn_cnsmr_idntfr | Consumer has rows in sspns_trnsctn_cnsmr_idntfr. Suspense transaction data may indicate in-flight payment processing. This exception is controlled by the exclude_suspense GlobalConfig setting. | 7 |

**Count of excluded consumers per exception reason — shows which tables block the most shells.** [sort:1] -- Count of excluded consumers per exception reason — shows which tables block the most shells.

```sql
SELECT      exception_reason,      COUNT(*) AS consumer_count  FROM DmOps.ShellPurge_ConsumerExceptionLog  GROUP BY exception_reason  ORDER BY consumer_count DESC;
```

**Consumers with multiple exception reasons** [sort:2] -- Consumers blocked by more than one exception — may need different remediation approaches.

```sql
SELECT      cnsmr_id,      cnsmr_idntfr_agncy_id,      COUNT(*) AS reason_count,      STRING_AGG(exception_reason, ', ') AS reasons  FROM DmOps.ShellPurge_ConsumerExceptionLog  GROUP BY cnsmr_id, cnsmr_idntfr_agncy_id  HAVING COUNT(*) > 1  ORDER BY reason_count DESC;
```

**Consumers with only dcmnt_rqst exceptions** [sort:3] -- Consumers whose sole exception reason is dcmnt_rqst.

```sql
SELECT e.cnsmr_id, e.cnsmr_idntfr_agncy_id  FROM DmOps.ShellPurge_ConsumerExceptionLog e  WHERE e.exception_reason = 'dcmnt_rqst'    AND NOT EXISTS (        SELECT 1 FROM DmOps.ShellPurge_ConsumerExceptionLog e2        WHERE e2.cnsmr_id = e.cnsmr_id          AND e2.exception_reason <> 'dcmnt_rqst'    );
```


### ShellPurge_ConsumerLog

Audit trail of every consumer purged. One row per consumer per batch. Captures the minimum identifying fields needed for reconciliation and historical reference.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| batch_id | bigint | No | — | FK to ShellPurge_BatchLog. Identifies which batch this consumer was purged in. Part of the composite primary key. |
| cnsmr_id | bigint | No | — | Internal consumer ID from crs5_oltp. The system-generated primary key for the consumer record that was purged. |
| cnsmr_idntfr_agncy_id | varchar(50) | No | — | Agency-assigned consumer identifier visible in the Debt Manager GUI. The human-readable consumer number used by operations staff. |
| created_dttm | datetime | No | getdate() | When this record was logged. Defaulted to GETDATE(). Represents the time the batch captured this record, not the time the consumer data was deleted. |

  - **PK_ShellPurge_ConsumerLog** (CLUSTERED): batch_id, cnsmr_id -- PRIMARY KEY
  - **IX_ShellPurge_ConsumerLog_cnsmr_id** (NONCLUSTERED): cnsmr_id [includes: batch_id]

**Foreign Keys:**

  - **FK_ShellPurge_ConsumerLog_BatchLog**: batch_id -> DmOps.ShellPurge_BatchLog.batch_id


### ShellPurge_Schedule

Weekly schedule grid controlling shell purge execution mode per hour. Seven rows (one per day of week) with 24 tinyint columns representing hours. Each cell is 0 (blocked), 1 (full batch size), or 2 (reduced batch size). Execute-DmShellPurge.ps1 reads the current day/hour cell to determine whether to run and at what batch size.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| day_of_week | tinyint | No | — | Day of week: 1=Sunday, 2=Monday, 3=Tuesday, 4=Wednesday, 5=Thursday, 6=Friday, 7=Saturday. Matches SQL Server DATEPART(dw) convention. |
| hr00 | tinyint | No | 0 | Execution mode for midnight to 1 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr01 | tinyint | No | 0 | Execution mode for 1 AM to 2 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr02 | tinyint | No | 0 | Execution mode for 2 AM to 3 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr03 | tinyint | No | 0 | Execution mode for 3 AM to 4 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr04 | tinyint | No | 0 | Execution mode for 4 AM to 5 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr05 | tinyint | No | 0 | Execution mode for 5 AM to 6 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr06 | tinyint | No | 0 | Execution mode for 6 AM to 7 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr07 | tinyint | No | 0 | Execution mode for 7 AM to 8 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr08 | tinyint | No | 0 | Execution mode for 8 AM to 9 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr09 | tinyint | No | 0 | Execution mode for 9 AM to 10 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr10 | tinyint | No | 0 | Execution mode for 10 AM to 11 AM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr11 | tinyint | No | 0 | Execution mode for 11 AM to noon. 0=blocked, 1=full batch, 2=reduced batch. |
| hr12 | tinyint | No | 0 | Execution mode for noon to 1 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr13 | tinyint | No | 0 | Execution mode for 1 PM to 2 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr14 | tinyint | No | 0 | Execution mode for 2 PM to 3 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr15 | tinyint | No | 0 | Execution mode for 3 PM to 4 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr16 | tinyint | No | 0 | Execution mode for 4 PM to 5 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr17 | tinyint | No | 0 | Execution mode for 5 PM to 6 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr18 | tinyint | No | 0 | Execution mode for 6 PM to 7 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr19 | tinyint | No | 0 | Execution mode for 7 PM to 8 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr20 | tinyint | No | 0 | Execution mode for 8 PM to 9 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr21 | tinyint | No | 0 | Execution mode for 9 PM to 10 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr22 | tinyint | No | 0 | Execution mode for 10 PM to 11 PM. 0=blocked, 1=full batch, 2=reduced batch. |
| hr23 | tinyint | No | 0 | Execution mode for 11 PM to midnight. 0=blocked, 1=full batch, 2=reduced batch. |
| created_dttm | datetime | No | getdate() | When this schedule row was created. |
| created_by | varchar(128) | No | suser_sname() | Who created this schedule row. |
| modified_dttm | datetime | Yes | — | When this schedule row was last modified. |
| modified_by | varchar(128) | Yes | — | Who last modified this schedule row. |

  - **PK_ShellPurge_Schedule** (CLUSTERED): day_of_week -- PRIMARY KEY

**Check Constraints:**

  - **CK_ShellPurge_Schedule_day_of_week**: `([day_of_week]>=(1) AND [day_of_week]<=(7))`
  - **CK_ShellPurge_Schedule_hr00**: `([hr00]=(2) OR [hr00]=(1) OR [hr00]=(0))`
  - **CK_ShellPurge_Schedule_hr01**: `([hr01]=(2) OR [hr01]=(1) OR [hr01]=(0))`
  - **CK_ShellPurge_Schedule_hr02**: `([hr02]=(2) OR [hr02]=(1) OR [hr02]=(0))`
  - **CK_ShellPurge_Schedule_hr03**: `([hr03]=(2) OR [hr03]=(1) OR [hr03]=(0))`
  - **CK_ShellPurge_Schedule_hr04**: `([hr04]=(2) OR [hr04]=(1) OR [hr04]=(0))`
  - **CK_ShellPurge_Schedule_hr05**: `([hr05]=(2) OR [hr05]=(1) OR [hr05]=(0))`
  - **CK_ShellPurge_Schedule_hr06**: `([hr06]=(2) OR [hr06]=(1) OR [hr06]=(0))`
  - **CK_ShellPurge_Schedule_hr07**: `([hr07]=(2) OR [hr07]=(1) OR [hr07]=(0))`
  - **CK_ShellPurge_Schedule_hr08**: `([hr08]=(2) OR [hr08]=(1) OR [hr08]=(0))`
  - **CK_ShellPurge_Schedule_hr09**: `([hr09]=(2) OR [hr09]=(1) OR [hr09]=(0))`
  - **CK_ShellPurge_Schedule_hr10**: `([hr10]=(2) OR [hr10]=(1) OR [hr10]=(0))`
  - **CK_ShellPurge_Schedule_hr11**: `([hr11]=(2) OR [hr11]=(1) OR [hr11]=(0))`
  - **CK_ShellPurge_Schedule_hr12**: `([hr12]=(2) OR [hr12]=(1) OR [hr12]=(0))`
  - **CK_ShellPurge_Schedule_hr13**: `([hr13]=(2) OR [hr13]=(1) OR [hr13]=(0))`
  - **CK_ShellPurge_Schedule_hr14**: `([hr14]=(2) OR [hr14]=(1) OR [hr14]=(0))`
  - **CK_ShellPurge_Schedule_hr15**: `([hr15]=(2) OR [hr15]=(1) OR [hr15]=(0))`
  - **CK_ShellPurge_Schedule_hr16**: `([hr16]=(2) OR [hr16]=(1) OR [hr16]=(0))`
  - **CK_ShellPurge_Schedule_hr17**: `([hr17]=(2) OR [hr17]=(1) OR [hr17]=(0))`
  - **CK_ShellPurge_Schedule_hr18**: `([hr18]=(2) OR [hr18]=(1) OR [hr18]=(0))`
  - **CK_ShellPurge_Schedule_hr19**: `([hr19]=(2) OR [hr19]=(1) OR [hr19]=(0))`
  - **CK_ShellPurge_Schedule_hr20**: `([hr20]=(2) OR [hr20]=(1) OR [hr20]=(0))`
  - **CK_ShellPurge_Schedule_hr21**: `([hr21]=(2) OR [hr21]=(1) OR [hr21]=(0))`
  - **CK_ShellPurge_Schedule_hr22**: `([hr22]=(2) OR [hr22]=(1) OR [hr22]=(0))`
  - **CK_ShellPurge_Schedule_hr23**: `([hr23]=(2) OR [hr23]=(1) OR [hr23]=(0))`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 | 0 | Blocked. Shell purge processing will not run during this hour. Script exits cleanly if currently in a blocked window. | 1 |
| hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 | 1 | Full. Shell purge processing runs at the full batch size configured in GlobalConfig (batch_size). Intended for off-hours and weekends. | 2 |
| hr00,hr01,hr02,hr03,hr04,hr05,hr06,hr07,hr08,hr09,hr10,hr11,hr12,hr13,hr14,hr15,hr16,hr17,hr18,hr19,hr20,hr21,hr22,hr23 | 2 | Reduced. Shell purge processing runs at the reduced batch size configured in GlobalConfig (batch_size_reduced). Intended for business hours to minimize end-user impact. | 3 |


### Execute-DmConsumerArchive.ps1

PowerShell engine process for consumer-level archiving. Runs from FA-SQLDBB, targets any crs5_oltp instance via configuration. Selects consumers tagged TC_ARCH, performs runtime re-verification to confirm continued eligibility (excepting consumers whose account state has changed since tagging), and executes a unified hardcoded FK-ordered delete sequence covering both account-level and consumer-level removal. BIDATA P-to-C migration is interleaved between the account-level and consumer-level phases, ensuring financial reporting records are preserved with reentrant safety on partial failure. Replaces Execute-DmArchive.ps1, resolving the distributed-payment journal-mismatch issue inherent in account-level archiving. Schedule-aware with continuous batch loop, full batch/detail/consumer/exception logging, emergency abort, and Teams alerting. Preview mode by default.

**Data Flow:** Reads execution options from dbo.GlobalConfig (module DmOps, category Archive). Reads server enable flag from dbo.ServerRegistry (dmops_archive_enabled). Reads schedule mode from DmOps.Archive_Schedule by current day and hour. Resolves four startup lookups against crs5_oltp (actn_cd, rslt_cd, usr, tag) to translate human-readable GlobalConfig values into internal IDs needed for the runtime re-verification path. Selects TC_ARCH-tagged consumers from crs5_oltp via cnsmr_Tag joined to tag. Re-verifies each candidate consumer at processing time using Pattern B eligibility logic (count of consumer accounts equals count of those accounts carrying TA_ARCH); excepted consumers are removed from the batch, soft-deleted from cnsmr_Tag, and an AR event is written to cnsmr_accnt_ar_log. Executes a 230-step delete sequence against crs5_oltp using a persistent SqlConnection — account-level Phase 1 UDEFs and Phase 2 deletes (orders A1-A117 and AU*), then BIDATA P-to-C migration (orders AB1-AB4) on a separate persistent connection, then consumer-level Phase 1 UDEFs and Phase 2 deletes (orders C1-C110 and CU*). Writes batch summaries to DmOps.Archive_BatchLog, per-table detail to DmOps.Archive_BatchDetail, per-consumer audit trail to DmOps.Archive_ConsumerLog, and excepted-consumer records to DmOps.Archive_ConsumerExceptionLog. Queues Teams alerts via Send-TeamsAlert on batch failure. Reports completion to the orchestrator via Complete-OrchestratorTask.

**Consumer-Level Archive Driver:** [sort:1] The script archives at the consumer level rather than the account level. A consumer becomes archive-eligible only when every account on the consumer carries TA_ARCH; a separate nightly DM job evaluates this condition and applies TC_ARCH to qualifying consumers. xFACts then archives by consumer, removing every account, transaction, and consumer-level record in a single coordinated operation. This resolves the distributed-payment journal-mismatch issue that prevented safe account-level archiving — when a consumer payment was distributed across multiple accounts, account-level archiving could leave the consumer-level cnsmr_pymnt_jrnl row referencing a partial account set, putting the consumer into a state the DM UI rejects. Consumer-level archiving has no such intermediate state because there is no surviving account to mismatch with.

**Runtime Re-Verification:** [sort:2] TC_ARCH is point-in-time. Between when the apply-job tags a consumer and when xFACts processes the consumer, new accounts can merge in (new business loads, account splits, manual activity), invalidating eligibility. Each batch re-verifies every TC_ARCH candidate at processing time using Pattern B logic — the same eligibility check the apply-job uses, inverted to find candidates who no longer qualify. Excepted consumers are unconditionally removed from the batch first, then best-effort soft-deleted from cnsmr_Tag and a CC/CC AR event is written to cnsmr_accnt_ar_log noting the tag removal. A row is appended to Archive_ConsumerExceptionLog with confirmation flags. Excepted consumers are released back to the DM apply-job for future re-tagging once their account state changes; xFACts does no backfill. The batch processes whatever consumers pass the check.

**Persistent SqlConnection:** [sort:3] The script maintains a single persistent System.Data.SqlClient.SqlConnection to crs5_oltp for the entire session. Temp tables created on this connection persist across all delete operations within a batch — both the account-level and consumer-level halves operate on the same connection without re-establishing state. A separate persistent connection is opened to BIDATA for the P-to-C migration step and held open for the duration of the session. The xFACts database is accessed via the platform wrappers (Get-SqlData, Invoke-SqlNonQuery) which manage their own connections.

**Pre-Materialized Intermediate ID Tables:** [sort:4] Account-level intermediate temp tables are populated once per batch from the core account ID set: ar_log IDs, transaction IDs, payment journal IDs, payment journal transaction IDs, and encounter IDs — each gets a clustered index. After the BIDATA migration completes, consumer-level temp tables (#shell_*) are populated from the consumer ID set for use in the consumer-level delete sequence. Delete operations reference these temp tables instead of re-joining through the FK chains, reducing deep multi-table joins to simple IN clauses. This pattern carries over from the prior account-level script and was extended to cover consumer-level operations.

**Hardcoded Delete Sequence with Prefix Scheme:** [sort:5] The delete sequence is hardcoded in the script using a unified prefix scheme that distinguishes the four operational halves: A1-A117 for account-level Phase 2 deletes, AU* for account-level UDEF Phase 1, AB1-AB4 for BIDATA P-to-C migration, C1-C110 for consumer-level Phase 2 deletes, and CU* for consumer-level UDEF Phase 1. The single namespace via prefix lets the two halves evolve independently without renumbering each other, and Archive_BatchDetail rows can be filtered by prefix (e.g., WHERE delete_order LIKE C%) for halve-specific analysis. The sequence is static — changes require a script update — which eliminates the overhead and complexity of runtime registry reads and ensures the FK ordering is exactly as validated during testing.

**BIDATA P-to-C Migration Mid-Batch Timing:** [sort:6] BIDATA migration is placed between the account-level and consumer-level delete phases — not at start, not at end. Placing it at start would risk repopulation: if the OLTP delete fails, the next BIDATA daily build would regenerate P rows from OLTP (account still exists), creating duplicates against the C rows already migrated. Placing it at end would risk irrecoverable loss: if consumer-level deletes succeed but BIDATA migration fails, the consumer is gone from OLTP with no reporting record migrated. Mid-batch placement gives both safety properties — the next BIDATA build will not regenerate P rows for accounts no longer in OLTP, and a consumer-level delete failure leaves the consumer in a recoverable near-shell state that retry can complete. BIDATA migration failure halts the batch; consumer-level deletes are skipped to preserve recoverability.

**Stop-on-Failure Pattern:** [sort:7] A script-level $StopProcessing flag halts the delete sequence on the first table failure. Once a table fails, all subsequent tables are skipped to prevent cascading FK violations from attempting to delete parent tables when their children were not fully cleaned. The batch is logged as Failed and a Teams alert is queued. Abort flag is checked between full batches only — never mid-batch — so a partial batch always completes its current sequence before the script exits.

**Non-Blocking Delete Strategy:** [sort:8] Every DELETE in the sequence executes under SNAPSHOT isolation with DEADLOCK_PRIORITY LOW and chunked batching to ensure zero impact on production users. SNAPSHOT isolation means readers never wait for our deletes — they read from the version store (a point-in-time snapshot in tempdb) while we hold exclusive locks on rows being deleted. Users see a consistent view of the data completely unaware that rows are being removed underneath them. DEADLOCK_PRIORITY LOW ensures that if a deadlock occurs between our DELETE and any user operation, SQL Server always kills our session — never the user's. The script catches deadlock errors (1205), snapshot conflicts (3960), lock timeouts (1222), and resource limits (1204), waits 5 seconds, and retries up to 10 times. In practice deadlocks at SNAPSHOT isolation are rare — the retry exists as a safety net. Chunked deletes (DELETE TOP 5000) prevent any single statement from holding locks for extended periods. Between each chunk a 100ms pause gives other operations a window to acquire locks. The chunk size is configurable via GlobalConfig. After a retry, the isolation level is explicitly reset to READ COMMITTED to prevent a stuck session state on the persistent connection.

  - **Archive_BatchLog**: [sort:1] Primary output. One row inserted per batch after re-verification with Running status, updated on completion with consumer/account counts, exception count, row totals, timing, status, and BIDATA migration outcome.
  - **Archive_BatchDetail**: [sort:2] Detailed output. One row per table operation per batch, written inline during the delete sequence. Captures delete order (with prefix indicating halve and phase), table name, pass description, rows affected, duration, and status.
  - **Archive_ConsumerLog**: [sort:3] Audit trail output. One row per consumer-account pair written at the start of each batch before deletions begin. Includes consumer and account identifiers plus creditor ID for BI cross-reference. bidata_migrated flag updated after successful P-to-C migration.
  - **Archive_ConsumerExceptionLog**: [sort:4] Exception output. One row per consumer that failed runtime re-verification within a batch. Captures consumer ID, agency identifier, detection timestamp, and confirmation flags (tag_removed, ar_event_written) showing which downstream operations succeeded. The batch_id is retained for audit context but is not enforced as a foreign key — exception rows can outlive their originating batch.
  - **Archive_Schedule**: [sort:5] Schedule input. Read between batches to determine whether to continue processing and at what batch size. Mode transitions (Full to Reduced, etc.) are detected and logged.
  - **GlobalConfig**: [sort:6] Configuration input. Reads all DmOps/Archive settings at startup: target_instance, bidata_instance, batch_size, batch_size_reduced, chunk_size, alerting_enabled, archive_abort, bidata_build_job_name, plus four runtime re-verification parameters (tag_removal_actn_cd, tag_removal_rslt_cd, tag_removal_user, tag_removal_msg_txt) that are resolved against crs5_oltp lookup tables at startup.
  - **crs5_oltp.dbo.cnsmr_Tag / cnsmr_accnt_ar_log**: [sort:7] Runtime re-verification write target. For each excepted consumer, the script issues a soft-delete UPDATE against the active TC_ARCH row in cnsmr_Tag and an INSERT into cnsmr_accnt_ar_log recording the tag removal as a CC/CC internal-comment AR event. These are the only writes the script issues against crs5_oltp outside of the deletion sequence itself. Both operations are best-effort — the consumer is unconditionally removed from the in-memory batch first, so subsequent write failures cannot cause the consumer to be archived against current eligibility.


### Execute-DmShellPurge.ps1

PowerShell engine process for consumer shell purge. Runs from FA-SQLDBB, targets any crs5_oltp instance via configuration. Selects orphaned consumers in the WFAPURGE workgroup with no remaining accounts, validates against the ShellPurge_ExclusionLog, and executes a consumer-level delete sequence derived from Matt's sp_Delete_EmptyShell_Consumers. Schedule-aware with continuous batch loop, full batch/detail/consumer logging, emergency abort, and Teams alerting. Preview mode by default.

**Data Flow:** Reads execution options from dbo.GlobalConfig (module DmOps, category ShellPurge). Reads server enable flag from dbo.ServerRegistry (dmops_shell_purge_enabled). Reads schedule mode from DmOps.ShellPurge_Schedule by current day and hour. Loads known exclusions from DmOps.ShellPurge_ExclusionLog into a temp table on the target connection for per-batch filtering. Selects shell consumers from crs5_oltp in the WFAPURGE workgroup with no cnsmr_accnt records and not in the exclusion set. Validates batch candidates against exclusion tables and logs new discoveries. Executes a consumer-level delete sequence derived from sp_Delete_EmptyShell_Consumers with dynamic UDEF discovery. Writes batch summaries to DmOps.ShellPurge_BatchLog, per-table detail to DmOps.ShellPurge_BatchDetail, and per-consumer audit trail to DmOps.ShellPurge_ConsumerLog. Queues Teams alerts via Send-TeamsAlert on batch failure. Reports completion to the orchestrator via Complete-OrchestratorTask.

**Exclusion Log Pattern:** [sort:1] Consumers with data in tables not covered by the delete sequence (cnsmr_pymnt_jrnl, dcmnt_rqst, agnt_crdtbl_actvty, bnkrptcy, schdld_pymnt_smmry, sspns_trnsctn_cnsmr_idntfr) are excluded rather than partially deleted. The ShellPurge_ExclusionLog table is seeded by a one-time population script and maintained incrementally as the purge script discovers new exclusions during batch validation. At session start, the exclusion log is loaded into a temp table on the target connection for efficient per-batch filtering without cross-database queries.

**Delete Sequence Source:** [sort:2] The consumer-level delete sequence is derived from Matt's sp_Delete_EmptyShell_Consumers, which handles a streamlined subset of consumer-linked tables. This is a deliberate departure from the full Phase 3/4 sequence in the vendor archive proc — the vendor proc covers deep FK chains through tables like cnsmr_pymnt_instrmnt and schdld_pymnt_smmry that the exclusion pattern already filters out. Matt's approach is safer: if a shell has complex residual data, skip it.

**Workgroup-Based Selection:** [sort:3] Selection targets the WFAPURGE workgroup exclusively. A nightly DM scheduled job moves shell consumers (those with no cnsmr_accnt records) into WFAPURGE automatically. This decouples eligibility criteria from the purge script — modifying which consumers become eligible is a DM configuration change, not a script change.

**Session-Cached Exclusions:** [sort:4] The exclusion log is loaded from xFACts into a temp table on the target connection once per session. Subsequent batches reuse the temp table without re-querying xFACts. New exclusions discovered during batch validation are added to both the permanent ExclusionLog (for future sessions) and the temp table (for the current session). This eliminates cross-database query requirements and keeps batch selection fast.

**FK Supporting Indexes:** [sort:5] 25 nonclustered indexes on child tables referencing dbo.cnsmr are required for acceptable DELETE performance on the terminal cnsmr delete. Without these, FK validation during the cnsmr DELETE triggers full table scans on every child table. With indexes, the terminal delete dropped from 121 seconds to 2.2 seconds for 100 consumers.

**Non-Blocking Delete Strategy:** [sort:6] Identical non-blocking pattern to Execute-DmArchive.ps1. Every DELETE executes under SNAPSHOT isolation (readers never blocked), DEADLOCK_PRIORITY LOW (user operations always win deadlock resolution), and chunked batching (DELETE TOP 5000 with 100ms inter-chunk pause). Retryable errors (1205 deadlock, 3960 snapshot conflict, 1222 lock timeout, 1204 resource limit) trigger up to 10 retries with 5-second waits. Isolation level is reset to READ COMMITTED after any retry to prevent stuck session state. The combination ensures that shell purge operations running during business hours at reduced batch sizes have no observable impact on the 200+ daily users of the Debt Manager application.

  - **ShellPurge_BatchLog**: [sort:1] Primary output. One row inserted per batch at start (Running), updated on completion with consumer counts, row totals, timing, and status.
  - **ShellPurge_BatchDetail**: [sort:2] Detailed output. One row per table operation per batch, written inline during the delete sequence. Captures delete order, table name, pass description, rows affected, duration, and status.
  - **ShellPurge_ConsumerLog**: [sort:3] Audit trail output. One row per consumer written at the start of each batch before deletions begin. Captures consumer ID and agency identifier.
  - **ShellPurge_ExclusionLog**: [sort:4] Exclusion filter and discovery target. Loaded into a session temp table at startup. New exclusions discovered during batch validation are appended here for future sessions.
  - **ShellPurge_Schedule**: [sort:5] Schedule input. Read between batches to determine whether to continue processing and at what batch size.
  - **GlobalConfig**: [sort:6] Configuration input. Reads all DmOps/ShellPurge settings at startup: target_instance, batch_size, batch_size_reduced, chunk_size, alerting_enabled, shell_purge_abort, exclude_suspense.


### xFACts-DmOpsFunctions.ps1

Shared deletion engine dot-sourced by the DmOps consumer scripts (Execute-DmConsumerArchive.ps1 and Execute-DmShellPurge.ps1). Provides one definition of the connection management, chunked SQL primitives, and operation and step wrappers both scripts use to delete and update against the crs5_oltp target instance, plus the shared batch-detail audit writer. Each consuming script supplies its own script-level state through a fixed set of $script:dmo_ names: the target connection and resolved settings, the current batch id, the per-batch counters, and the audit detail table the writer targets. The engine operates on those names rather than defining them, so a single shared copy serves both consumers.



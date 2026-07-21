# Backup Monitoring

*Because backups that only exist on the server they're protecting aren't really protecting anything*

Backup Monitoring tracks every backup file from the moment it's created through network copy, cloud upload, and eventual cleanup. It doesn't *make* backups — SQL Server handles that. It makes sure those backups actually *went somewhere useful* and raises the alarm when they didn't.






The Problem

Every database gets backed up. That's table stakes. But knowing that backups *exist* isn't the same as knowing they're *safe*.

A backup sitting only on the production server isn't protecting you. If that server dies, the backups die with it. Congratulations, you've achieved nothing. A backup copied to a second server is better. A backup uploaded to AWS S3 and stored offsite? Now we're talking real disaster recovery.

But here's the thing nobody wants to talk about: backup pipelines break *silently*. The network share fills up. The AWS credentials expire. A server reboots at the wrong time and the copy job never catches up. Everything looks fine until the day you actually need a restore, and then it's a very, very bad day.

Backup Monitoring exists to catch those silent failures before they become loud ones. It watches the whole pipeline and yells when something stalls.






How It Works



SQL Server
Makes Backup
→
xFACts
Discovers It
→


Copied to
Second Server
Uploaded
to AWS S3


→
Eventually
Cleaned Up

From backup creation to offsite storage — network copy and cloud upload happen in parallel


Think of it as an assembly line. SQL Server creates backup files on a schedule. xFACts notices those new files and starts tracking them. From there, each file moves through a pipeline: copied to a second server for local redundancy, uploaded to AWS for offsite disaster recovery, and eventually cleaned up when it's old enough that newer backups have taken its place.

The network copy and cloud upload happen independently — neither waits for the other. If the network is having a moment, cloud uploads keep going. If AWS is slow, network copies keep going. Each file is tracked through every stage, so at any point you can see exactly where every backup stands.

The whole process runs automatically, every few minutes, across all enrolled databases on every monitored server — including databases in Always On Availability Groups, where backups can happen on either node. No manual intervention required. No configuration changes when a failover happens.






Retention: The Cleanup Crew

Backups are like leftovers in the office fridge. If nobody cleans them up, they accumulate until something breaks. Except instead of a biohazard, you get a full drive at 2 AM.

Retention keeps things tidy across two storage tiers. Each database is configured with how many recent backups to keep on the local server and on the network copy. When older backups age out of that window, they're cleaned up automatically. Cloud backups in S3 are managed by AWS's own lifecycle rules, independent of xFACts.

The critical safety rule: **a local backup is never deleted until the network copy is confirmed.** This means even if something goes wrong with the pipeline, you won't accidentally lose your only copy of a backup file.

When retention does clean up a file, the physical file is removed but the tracking record is preserved permanently. Every backup that ever passed through the system leaves a complete audit trail — when it was created, when it was copied, when it was uploaded, and when it was cleaned up.






When Things Go Wrong

The whole point of monitoring is catching problems before they become disasters. A dedicated health check evaluates three conditions on a regular cycle:

| Condition | Severity | What It Means |
| --- | --- | --- |
| **Missing backup** | CRITICAL | No backup detected within the expected window. Something is wrong with the backup job itself. |
| **Stale pipeline** | WARNING | A file has been stuck too long waiting to be copied or uploaded. The pipeline is clogged. |
| **Failed stage** | CRITICAL | A copy or upload explicitly failed. Investigate immediately. |


Alerts are delivered as color-coded cards in Microsoft Teams. The same problem only generates one alert per day — nobody needs 48 messages about the same broken network share.






The Control Center View

The Backup Monitoring page in the Control Center provides a live dashboard showing the current state of every enrolled database's backup pipeline. At a glance, you can see which databases have recent successful backups, which files are mid-pipeline, and which ones need attention.






The Bottom Line

SQL Server makes the backups. Backup Monitoring makes sure they actually go somewhere useful.

Every file is tracked from discovery through network copy, cloud upload, and retention. Every failure generates an alert. Every cleanup respects the safety rule. And every file that passes through the system leaves a permanent audit trail.

It's not the most exciting module in xFACts. But when an auditor asks "can you prove you have offsite backups for the last 90 days?" and the answer takes less than a second — that's this module earning its keep.

---

# Backup Monitoring — Control Center Guide

---

## Architecture
# Backup Monitoring Architecture

The narrative page tells you *what* Backup Monitoring does and *why* it matters. This page tells you *how*. Three tables and four PowerShell scripts that keep tabs on every backup file from creation through network copy, AWS upload, and eventual cleanup — across all registered SQL Server instances including Always On Availability Group listeners.



Schema Overview

The Backup component tracks two things: the configuration and health of each database's backup process, and the physical lifecycle of every backup file. These concerns are cleanly separated — configuration tables describe what *should* happen, while tracking tables record what *did* happen.



`Backup_DatabaseConfig` is the enrollment table — one row per monitored database, controlling which backup stages are enabled and what retention policies apply. `Backup_FileTracking` is the workhorse — one row per backup file, tracking its journey through every stage of the pipeline. `Backup_ExecutionLog` records per-file results from each script run, providing the detail behind the pipeline status cards on the Control Center page.

| Table | Role | Cardinality |
| --- | --- | --- |
| `Backup_DatabaseConfig` | Per-database backup configuration and enrollment | One per monitored database |
| `Backup_FileTracking` | Individual backup file lifecycle tracking | Many per database (one per backup file) |
| `Backup_ExecutionLog` | Per-file script execution history | Many per database over time |



Pipeline status comes from the Orchestrator. Timing, status, and duration for each pipeline stage are sourced from `Orchestrator.TaskLog` — the authoritative record of every script execution. File counts and bytes are aggregated from `Backup_ExecutionLog` for the corresponding run window. This eliminates the need for a dedicated status table and ensures the Control Center always reflects the orchestrator’s view of reality.







The Backup Pipeline

Backups follow a pipeline with four stages, each handled by a dedicated script. Collection discovers new backups and sets the initial statuses. Network copy and AWS upload then run **in parallel** — both read from the source server's local path and operate independently. Retention runs last, cleaning up files that have aged out of their configured retention chain.





SQL Server
Backup completes
on any registered server

→

Collect
Detect & register
Set PENDING statuses

→

Parallel

Network Copy
AWS Upload


→

Retention
Chain-count cleanup
local → network


Network copy and AWS upload run independently — both read from the source server's local path. Neither waits for the other.



Two potential backup sources. The `Backup_DatabaseConfig` table contains a flag called `backup_enabled` which drives whether or not the backup schedule itself is driven by xFACts or an external source. If this field is set to 0, xFACts does not create a backup, nor does the backup schedule in the table apply. At present, all backups are initiated by Redgate on an existing Redgate backup schedule. xFACts simply takes the handoff from Redgate once a backup is completed and available in msdb following the 4 stages outlined below.


Stage 1: Collection

`Collect-BackupStatus.ps1` queries `ServerRegistry` for all servers with `serverops_backup_enabled = 1` and `server_type IN ('SQL_SERVER', 'AG_LISTENER')`. For each server, it connects to `msdb.dbo.backupset` and discovers backup completions since the last collection timestamp for that server.





Server List
All backup-enabled
servers from Registry

→

Query msdb
Backups since last
collection per server

→

Filter & Enroll
Match against
DatabaseRegistry +
DatabaseConfig

→

Register
INSERT FileTracking
Set network/AWS
to PENDING or SKIPPED

→

Log
Per-file detail row
to ExecutionLog




For each discovered backup, the script checks whether the database is enrolled in `DatabaseRegistry` and active in `Backup_DatabaseConfig`. Unenrolled or inactive databases are silently skipped. For enrolled databases, the initial `network_copy_status` and `aws_upload_status` are set based on configuration flags: `PENDING` if the stage is enabled, `SKIPPED` if not. This is how the parallel pipeline stages know which files they need to process.

Each file is inserted individually using `OUTPUT INSERTED.tracking_id` to capture the new tracking ID, which is then written to `Backup_ExecutionLog` as a per-file detail row. This matches the pattern used by the other three pipeline scripts and provides the data for the Collection pipeline detail modal on the Control Center page.

The collector also detects backup source type from the file extension (`.sqb` = Redgate, all others = native) and captures compressed file size from the physical file via UNC path for ongoing collections. Only files with recognized backup extensions (`.sqb`, `.bak`, `.trn`) are collected — this extension whitelist prevents Redgate temporary filenames from entering the system.


AG Listener vs. physical server. When a server in the registry is an AG Listener, the collector connects through the listener and queries msdb on the current primary replica. For compressed file size collection, it parses the physical server name from the Redgate backup filename pattern (`TYPE_SERVER_DATABASE_TIMESTAMP.sqb`) to build the correct UNC admin share path, since admin shares don't resolve through listeners.


Stage 2: Network Copy

`Process-BackupNetworkCopy.ps1` queries `Backup_FileTracking` for files where `network_copy_status = 'PENDING'`, joined against the registry tables to confirm the server, database, and copy flag are still active. It processes up to `MaxFiles` (default 100) per run, ordered by backup finish time.





Find Candidates
network_copy_status
= PENDING

→

Claim Batch
Mark IN_PROGRESS
(atomic claim)

→

Copy-Item
Source UNC →
network share

→

Verify
Destination file
exists on share

→


COMPLETED
FAILED





The script uses an atomic batch claim pattern — it marks all candidate rows as `'IN_PROGRESS'` in a single UPDATE before starting any copies, preventing duplicate processing if two instances run concurrently. For AG databases (server_id 0), the source UNC path is built from the physical server name parsed from the backup filename, since admin shares don't work through AG listeners. The destination path follows a structured layout: `{network_root}\{server}\{database}\{type}\{filename}`.

After each copy, the script verifies the destination file exists. Successful copies update the status to `COMPLETED` and record the network path. Failures update to `FAILED` and log the error to `Backup_ExecutionLog`.


Automatic retry for failed copies. Before querying for PENDING files, the script checks for FAILED copies where the retry count is below the configurable maximum (`network_copy_max_retries` in GlobalConfig). Eligible files are reset to PENDING with an incremented retry count and picked up by the normal processing loop. Files that exhaust all retries remain FAILED permanently and generate a Teams alert via the shared `Send-TeamsAlert` function. The retry count is tracked per-file in `network_copy_retry_count` on `Backup_FileTracking`.


Stage 3: AWS Upload

`Process-BackupAWSUpload.ps1` queries `Backup_FileTracking` for files where `aws_upload_status = 'PENDING'`. It has **no dependency on network copy status** — it reads from the source server's local path via UNC, the same source as the network copy script. Both stages can process the same file simultaneously without conflict.





Find Candidates
aws_upload_status
= PENDING

→

Claim Batch
Mark IN_PROGRESS
(atomic claim)

→

AWS CLI Upload
Source UNC →
S3 bucket

→

Verify
S3 object
exists

→


COMPLETED
FAILED





The upload uses the AWS CLI with a configurable storage class (typically `GLACIER` for cost efficiency). The S3 path structure is built from GlobalConfig settings (`backup_s3_bucket`, `backup_s3_prefix`). After upload, the script verifies the S3 object exists before marking the file as `'COMPLETED'`. Like network copy, it uses the same atomic batch claim pattern and the same AG-aware UNC path resolution.


Automatic retry for failed uploads. Same retry mechanism as network copy. The script checks for FAILED uploads where `aws_upload_retry_count` is below the configurable maximum (`aws_upload_max_retries` in GlobalConfig), resets eligible files to PENDING, and alerts via `Send-TeamsAlert` when retries are exhausted.



**S3 lifecycle management.** S3 retention is handled by an AWS S3 lifecycle rule, not by xFACts. Once a file is uploaded, AWS manages its lifecycle independently — transitioning storage classes and expiring objects based on the configured rule. This is deliberate: S3 lifecycle rules are more reliable and cost-efficient than polling from an external script, and they continue working even if xFACts is offline.


Stage 4: Retention

`Process-BackupRetention.ps1` handles cleanup of local and network copies. Retention is **chain-count based**, not days-based — it keeps the N most recent FULL backups per database per tier, and deletes everything older. The chain counts are configured per-database in `Backup_DatabaseConfig`.





Local Cleanup
Older than Nth FULL?
Network copy confirmed?
→ Delete local file

→

Network Cleanup
Older than Nth FULL?
→ Delete network file

→

Record
Set deleted_dttm
Path columns preserved
Row never deleted


Chain-count retention: keep the N most recent FULLs, delete everything older. Local cleanup requires network copy confirmation.


For local cleanup, the script ranks FULL backups per database by finish time and finds the Nth oldest (configured by `full_retention_chain_local_count`). All files with a finish time before that cutoff are candidates for deletion — but only if `network_copy_status` is `'COMPLETED'` or `'HISTORICAL'`. This safety check ensures a local file is never deleted until a network copy is confirmed.

Network cleanup follows the same chain-count pattern using `full_retention_chain_network_count`, but has no downstream prerequisite — network is the final xFACts-managed tier. When a file is deleted, the script records the deletion timestamp (`local_deleted_dttm` or `network_deleted_dttm`) but preserves the path columns and never removes the tracking row. Every file that ever existed has a permanent record.


Chain counts, not calendar days. Retention is expressed as "keep the last N FULL backups," not "keep files for N days." This ensures there are always a known number of restore points available regardless of backup frequency. A database with daily FULLs and a chain count of 3 keeps three days of FULLs; a database with weekly FULLs and the same chain count keeps three weeks.







File Lifecycle

Each backup file tracked in `Backup_FileTracking` carries independent status columns for each pipeline stage. The collection stage sets the initial status for each downstream stage based on the database's configuration flags.

| Stage | Status Column | Lifecycle |
| --- | --- | --- |
| Collection | `collect_status` | Always COMPLETED on insert (collection *is* the insert) |
| Network Copy | `network_copy_status` | PENDING → IN_PROGRESS → COMPLETED / FAILED
or SKIPPED (if not enabled) or HISTORICAL (initial load) |
| AWS Upload | `aws_upload_status` | PENDING → IN_PROGRESS → COMPLETED / FAILED
or SKIPPED (if not enabled) or HISTORICAL (initial load) |


Each pipeline stage also records timing (`*_started_dttm`, `*_completed_dttm`) and file paths. The physical file paths (`local_path`, `network_path`, `s3_path`) are populated as files move through the pipeline. Retention records deletion timestamps (`local_deleted_dttm`, `network_deleted_dttm`) but preserves the path values for historical reference.


PENDING vs SKIPPED. When a file is registered, the collector checks `Backup_DatabaseConfig` for each stage's enabled flag. If `backup_network_copy_enabled = 1`, the status starts as `PENDING` and the network copy script will pick it up. If `0`, it starts as `SKIPPED` and is permanently excluded from that stage. This per-database, per-stage control means some databases can get network copy but not AWS, or vice versa.







Alerting & Escalation

Backup alerting is built into the pipeline scripts themselves rather than a separate monitoring process. Each pipeline stage handles its own failure detection and escalation through the retry mechanism.

| Alert Source | Trigger | Delivery |
| --- | --- | --- |
| Network Copy script | File fails all retry attempts (`network_copy_retry_count` reaches `network_copy_max_retries`) | `Send-TeamsAlert` with dedup |
| AWS Upload script | File fails all retry attempts (`aws_upload_retry_count` reaches `aws_upload_max_retries`) | `Send-TeamsAlert` with dedup |


When a network copy or AWS upload fails, the file is marked `FAILED` in `Backup_FileTracking`. On the next cycle, the script’s retry step checks for FAILED files below the max retry count, resets them to `PENDING` with an incremented retry count, and the normal processing loop picks them up. If a file exhausts all retries, it remains `FAILED` permanently and a Teams alert is queued via the shared `Send-TeamsAlert` function in `xFACts-OrchestratorFunctions.ps1`.

`Send-TeamsAlert` inserts directly into `Teams.AlertQueue` with mandatory deduplication against `Teams.RequestLog`. This ensures the same failure only generates one alert — subsequent cycles see the existing alert in the request log and skip it.


Retry counts are incremented at reset time, not failure time. A freshly failed file has `retry_count = 0`. The count increments when the file is actually retried (reset from FAILED to PENDING). This means a file with `max_retries = 2` gets 3 total attempts: the original try (count 0), first retry (count 1), and second retry (count 2). After the third failure, the count equals max and the alert fires.







Retention & Cleanup

Retention is managed across two xFACts-controlled tiers (local and network) plus one externally managed tier (S3). Each tier has independent retention policies, and the local tier enforces a safety prerequisite before deletion.

| Tier | Config Column | Retention Method | Deletion Prerequisite |
| --- | --- | --- | --- |
| Local (source server) | `full_retention_chain_local_count` | Keep last N FULLs | Network copy COMPLETED or HISTORICAL |
| Network (secondary server) | `full_retention_chain_network_count` | Keep last N FULLs | None (final xFACts-managed tier) |
| AWS S3 | S3 lifecycle rule | AWS-managed expiration | N/A (external to xFACts) |


The retention script never deletes a local file unless the network tier has a confirmed copy (`network_copy_status IN ('COMPLETED', 'HISTORICAL')`). This prevents the scenario where a network outage could leave no copy available for restore. Network cleanup has no downstream prerequisite because S3 lifecycle management is handled entirely by AWS.






Troubleshooting

**"A backup file is stuck in PENDING."**
Check `Orchestrator.TaskLog` for the relevant process (Process-BackupNetworkCopy or Process-BackupAWSUpload). If the last run shows FAILED, check the `error_output` column. If it shows SUCCESS but files are still PENDING, the file may not have met the query criteria — verify the database still has the stage enabled in `Backup_DatabaseConfig` and the server is active with `serverops_backup_enabled = 1`. The retry mechanism will pick up FAILED files automatically on subsequent cycles up to the configured maximum retry count.

**"Backup files aren't being discovered."**
Verify the database has a row in `Backup_DatabaseConfig` linked through `DatabaseRegistry`. Check the server-level master switch in `ServerRegistry` (`serverops_backup_enabled`). For AG Listener-enrolled databases, make sure the listener is reachable and resolving to the current primary.

**"AWS uploads are failing."**
The most common cause is expired AWS CLI credentials. The upload script uses the AWS CLI profile configured on the xFACts server. Verify the credentials are current and that the S3 bucket (`aws_bucket_name` in GlobalConfig) is accessible from the server. Also confirm the bucket allows the GLACIER storage class.

**"Network copies are failing."**
The script copies via UNC admin shares (`\\server\drive$\path`). Verify the service account has write access to the network backup root (configured as `network_backup_root` in GlobalConfig). For AG databases, the source UNC path is built from the physical server parsed from the filename — if the filename pattern doesn't match the expected format, the path resolution will fail.

**"Retention isn't cleaning up files."**
Local retention requires `network_copy_status` to be COMPLETED or HISTORICAL before it will delete. If network copies are failing, local files will accumulate because the safety prerequisite isn't met. Fix the network copy issue first, then retention will catch up on the next run. Also verify `full_retention_chain_local_count` and `full_retention_chain_network_count` are set to non-zero values in `Backup_DatabaseConfig`.






How Everything Connects

Internal Flow

| From | To | Relationship |
| --- | --- | --- |
| `Backup_DatabaseConfig` | `Backup_FileTracking` | Config determines which databases are monitored and which stages are enabled; FileTracking stores the results |
| `Backup_FileTracking` | `Backup_ExecutionLog` | Each script run logs per-file results with tracking_id linkage |
| `Process-BackupNetworkCopy.ps1` / `Process-BackupAWSUpload.ps1` | `Teams.AlertQueue` | Retry exhaustion alerts inserted directly via shared `Send-TeamsAlert` function with dedup against `Teams.RequestLog` |


External Dependencies

| Dependency | Module | Purpose |
| --- | --- | --- |
| `dbo.ServerRegistry` | Engine Room | Server-level enable flag (`serverops_backup_enabled`), server type (SQL_SERVER, AG_LISTENER), and instance name |
| `dbo.DatabaseRegistry` | Engine Room | Database enrollment and active status — only enrolled databases are tracked |
| `dbo.GlobalConfig` | Engine Room | S3 bucket/prefix, network backup root path, storage class, alert thresholds, monitoring intervals, retry maximums (`network_copy_max_retries`, `aws_upload_max_retries`) |
| `Orchestrator.ProcessRegistry` | Orchestrator | Scheduling for all four pipeline scripts; `TaskLog` provides authoritative run timing and status for the Control Center pipeline cards |
| msdb.dbo.backupset | SQL Server | Source data for backup detection — queried on each registered server via its connection string |
| AWS S3 | External | Cloud storage tier (upload via AWS CLI, retention via S3 lifecycle rule) |

---

## Reference

### Backup_DatabaseConfig

Per-database backup scheduling configuration including tier classification, full/differential/log schedules, and state tracking. Provides complete flexibility for staggered schedules while maintaining self-documenting tier assignments.

**Data Flow:** Rows are manually inserted per database during enrollment. Collect-BackupStatus.ps1 reads backup_network_copy_enabled and backup_aws_upload_enabled to determine initial pipeline statuses for discovered backups. Process-BackupNetworkCopy.ps1 and Process-BackupAWSUpload.ps1 join through this table to filter for eligible databases. Process-BackupRetention.ps1 reads full_retention_chain_local_count and full_retention_chain_network_count to calculate per-database cutoff timestamps for chain-based deletion. Collect-BackupStatus.ps1 updates last_full_dttm, last_diff_dttm, last_log_dttm, and the corresponding backup_set_id columns after discovering new backups.

**Active Pipeline Flags vs Future Scheduling:** [sort:1] Three columns drive current pipeline behavior: backup_network_copy_enabled controls whether discovered backups are queued for network copy, backup_aws_upload_enabled controls AWS upload queuing, and backup_enabled is reserved for a future switchover to native xFACts backup creation (currently 0 for all databases since Redgate manages backup execution). The scheduling columns (full_frequency, full_time, diff_time, log_frequency_minutes) define future-state schedules in conjunction with the backup_enabled flag.

**Chain-Based Retention:** [sort:2] Retention is driven by FULL backup chain counts rather than date-based policies. full_retention_chain_local_count and full_retention_chain_network_count specify how many complete FULL backup chains to retain on each storage tier. All files (FULL, DIFF, LOG) older than the Nth oldest FULL are candidates for deletion. This eliminates orphaned DIFFs and LOGs that cannot be used for recovery without their parent FULL.

**Explicit Per-Database Scheduling:** [sort:3] Each database has its own complete schedule definition rather than using tier-based templates. This allows fine-grained staggering to avoid resource contention and avoids template management overhead. The tier column provides operational grouping for reporting and filtering but does not constrain scheduling or retention behavior.

**Denormalized Names:** [sort:4] server_name and database_name are stored directly alongside the database_id foreign key. This avoids joins for the most common queries — tier summaries, schedule views, and retention configuration reviews — while the FK to DatabaseRegistry preserves referential integrity.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| config_id (IDENTITY) | int | No | IDENTITY | Unique identifier for the configuration |
| database_id | int | No | — | FK to DatabaseRegistry.database_id |
| database_name | varchar(128) | No | — | Denormalized database name for convenience |
| server_name | varchar(128) | No | — | Denormalized server name for convenience |
| backup_enabled | bit | No | 0 | Whether xFACts handles backup creation for this database (0 = Redgate handles) |
| backup_network_copy_enabled | bit | No | 0 | Whether xFACts copies completed backups to network storage |
| backup_aws_upload_enabled | bit | No | 0 | Whether xFACts uploads completed backups to AWS S3 |
| tier | varchar(20) | No | — | Critical, Standard, LowActivity, Working, System, Deprecated |
| full_backup_enabled | bit | No | 1 | Whether full backups are scheduled |
| full_frequency | varchar(10) | No | — | WEEKLY or DAILY |
| full_day_of_week | tinyint | Yes | — | 1=Sun, 2=Mon...7=Sat (NULL if DAILY) |
| full_time | time | No | — | Time of day for full backup |
| full_retention_chain_local_count | int | No | 1 | Number of full backup chains to retain on local storage. DIFFs and LOGs older than the Nth oldest FULL are automatically deleted |
| full_retention_chain_network_count | int | No | 1 | Number of full backup chains to retain on network storage. DIFFs and LOGs older than the Nth oldest FULL are automatically deleted |
| diff_backup_enabled | bit | No | 0 | Whether differential backups are scheduled |
| diff_time | time | Yes | — | Time of day for diff backup (runs all days except full_day_of_week) |
| log_backup_enabled | bit | No | 0 | Whether log backups are scheduled |
| log_frequency_minutes | int | Yes | — | Minutes between log backups (15, 240, 1440, etc.) |
| last_full_dttm | datetime | Yes | — | When last full backup completed |
| last_full_backup_set_id | int | Yes | — | msdb.backupset reference for chain tracking |
| last_diff_dttm | datetime | Yes | — | When last differential backup completed |
| last_diff_backup_set_id | int | Yes | — | msdb.backupset reference for chain tracking |
| last_log_dttm | datetime | Yes | — | When last log backup completed |
| created_dttm | datetime | No | getdate() | When the configuration was created |
| created_by | varchar(100) | No | suser_sname() | Who created the configuration |
| modified_dttm | datetime | Yes | — | When the configuration was last modified |
| modified_by | varchar(100) | Yes | — | Who last modified the configuration |

  - **PK_Backup_DatabaseConfig** (CLUSTERED): config_id -- PRIMARY KEY
  - **IX_Backup_DatabaseConfig_DiffSchedule** (NONCLUSTERED): diff_backup_enabled, diff_time
  - **IX_Backup_DatabaseConfig_FullSchedule** (NONCLUSTERED): full_backup_enabled, full_frequency, full_day_of_week, full_time
  - **IX_Backup_DatabaseConfig_LogSchedule** (NONCLUSTERED): log_backup_enabled, log_frequency_minutes, last_log_dttm
  - **IX_Backup_DatabaseConfig_Tier** (NONCLUSTERED): tier [includes: database_name, server_name]
  - **UQ_Backup_DatabaseConfig_DatabaseID** (NONCLUSTERED): database_id

**Check Constraints:**

  - **CK_Backup_DatabaseConfig_DiffTime**: `([diff_backup_enabled]=(0) OR [diff_backup_enabled]=(1) AND [diff_time] IS NOT NULL)`
  - **CK_Backup_DatabaseConfig_FullDayOfWeek**: `([full_day_of_week] IS NULL OR [full_day_of_week]>=(1) AND [full_day_of_week]<=(7))`
  - **CK_Backup_DatabaseConfig_FullFrequency**: `([full_frequency]='DAILY' OR [full_frequency]='WEEKLY' OR [full_frequency]='NONE')`
  - **CK_Backup_DatabaseConfig_FullFrequencyDay**: `([full_frequency]='WEEKLY' AND [full_day_of_week] IS NOT NULL OR [full_frequency]='DAILY' AND [full_day_of_week] IS NULL OR [full_frequency]='NONE' AND [full_day_of_week] IS NULL)`
  - **CK_Backup_DatabaseConfig_LogFrequency**: `([log_backup_enabled]=(0) OR [log_backup_enabled]=(1) AND [log_frequency_minutes] IS NOT NULL AND [log_frequency_minutes]>(0))`

**Foreign Keys:**

  - **FK_Backup_DatabaseConfig_DatabaseRegistry**: database_id -> dbo.DatabaseRegistry.database_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| tier | Critical | High-transaction, business-critical databases. Future schedule: weekly FULLs, daily DIFFs, 15-minute LOGs. Network copy and AWS upload enabled. | 1 |
| tier | Standard | Normal FULL recovery databases. Future schedule: weekly FULLs, daily DIFFs, 4-hour LOGs. Network copy and AWS upload enabled. | 2 |
| tier | LowActivity | Databases with sporadic activity. Future schedule: weekly FULLs, daily DIFFs, daily LOGs. Network copy enabled, AWS upload optional. | 3 |
| tier | Working | Transient or staging data in SIMPLE recovery mode. Future schedule: daily FULLs only. Local storage only — no network copy or AWS upload. | 4 |
| tier | System | System databases (master, model, msdb). Future schedule: weekly FULLs on Saturday. Network copy enabled, no AWS upload. | 5 |
| tier | Deprecated | Databases pending removal. Backups disabled. No network copy or AWS upload. | 6 |

**Configuration overview by server and tier** [sort:1] -- Shows all database configurations grouped by server and tier with pipeline flags and retention settings.

```sql
SELECT
    server_name,
    database_name,
    tier,
    backup_enabled,
    backup_network_copy_enabled,
    backup_aws_upload_enabled,
    full_retention_chain_local_count,
    full_retention_chain_network_count
FROM ServerOps.Backup_DatabaseConfig
ORDER BY server_name, tier, database_name;
```

**Summary by server and tier** [sort:2] -- Counts databases per server and tier with pipeline flag totals for capacity planning.

```sql
SELECT
    server_name,
    tier,
    COUNT(*) AS database_count,
    SUM(CAST(backup_network_copy_enabled AS INT)) AS network_enabled,
    SUM(CAST(backup_aws_upload_enabled AS INT)) AS aws_enabled
FROM ServerOps.Backup_DatabaseConfig
GROUP BY server_name, tier
ORDER BY server_name, tier;
```

**Retention configuration review** [sort:3] -- Shows per-database retention chain counts for verifying retention policies before or after changes.

```sql
SELECT
    server_name,
    database_name,
    tier,
    full_retention_chain_local_count,
    full_retention_chain_network_count
FROM ServerOps.Backup_DatabaseConfig
WHERE full_retention_chain_local_count > 0
   OR full_retention_chain_network_count > 0
ORDER BY server_name, database_name;
```

  - **Backup_FileTracking**: [sort:1] Pipeline flags in this table (backup_network_copy_enabled, backup_aws_upload_enabled) determine the initial statuses assigned to FileTracking records at collection time. Retention chain counts drive the cutoff calculations that determine which FileTracking records are eligible for deletion.
  - **dbo.DatabaseRegistry**: [sort:2] Each row references a database_id from DatabaseRegistry. A database must be enrolled (is_active = 1) in DatabaseRegistry and have a Backup_DatabaseConfig row for the pipeline to process its backups. DatabaseRegistry.backup_enabled is a separate flag that indicates whether xFACts creates backups — distinct from the pipeline flags here that control post-creation distribution.


### Backup_ExecutionLog

Detailed execution history for all Backup component operations including collection, network copy, AWS upload, and retention activities. Provides audit trail and troubleshooting data.

**Data Flow:** All four pipeline scripts write to this table. Collect-BackupStatus.ps1 logs per-server collection results (success or failure with error message). Process-BackupNetworkCopy.ps1 and Process-BackupAWSUpload.ps1 log per-file copy/upload operations with duration, byte counts, and error details. Process-BackupRetention.ps1 logs per-file deletion operations for both local and network storage, but skips logging for HISTORICAL records to prevent table bloat during large-scale cleanup.

**Component-Based Filtering:** [sort:1] The component column identifies which pipeline process generated each entry (COLLECTION, NETWORK_COPY, AWS_UPLOAD, RETENTION). This enables component-specific analysis — throughput trends for network copy, failure rates for AWS upload, collection timing per server — without requiring separate log tables per process.

**Selective Logging for HISTORICAL Records:** [sort:2] Process-BackupRetention.ps1 skips ExecutionLog writes when processing HISTORICAL records (checking network_copy_status != HISTORICAL before logging). During initial cleanup of pre-existing files, hundreds of thousands of records may be processed — logging each one would flood the table with low-value entries. Failures are always logged regardless of HISTORICAL status.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| log_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the log entry |
| run_id | int | Yes | — | Orchestrator run identifier (if applicable) |
| component | varchar(30) | No | — | COLLECTION, NETWORK_COPY, AWS_UPLOAD, RETENTION |
| server_name | varchar(128) | Yes | — | Server involved (if applicable) |
| database_name | varchar(128) | Yes | — | Database involved (if applicable) |
| file_name | varchar(500) | Yes | — | File processed (if applicable) |
| tracking_id | bigint | Yes | — | FK to FileTracking (if applicable) |
| operation | varchar(100) | No | — | Specific action performed (e.g., 'Discover new backups', 'Copy to network') |
| status | varchar(20) | No | — | SUCCESS, FAILED, SKIPPED, WARNING |
| duration_ms | int | Yes | — | Duration in milliseconds |
| bytes_processed | bigint | Yes | — | Bytes copied or uploaded |
| files_processed | int | Yes | — | Number of files (for batch operations) |
| error_message | varchar(MAX) | Yes | — | Error summary if failed |
| error_details | varchar(MAX) | Yes | — | Stack trace or additional context |
| started_dttm | datetime | No | getdate() | When the operation started |
| completed_dttm | datetime | Yes | — | When the operation completed |

  - **PK_Backup_ExecutionLog** (CLUSTERED): log_id -- PRIMARY KEY
  - **IX_Backup_ExecutionLog_Component** (NONCLUSTERED): component, started_dttm
  - **IX_Backup_ExecutionLog_StartedDttm** (NONCLUSTERED): started_dttm [includes: component, status]
  - **IX_Backup_ExecutionLog_TrackingId** (NONCLUSTERED): tracking_id

**Check Constraints:**

  - **CK_Backup_ExecutionLog_Component**: `([component]='RETENTION' OR [component]='AWS_UPLOAD' OR [component]='NETWORK_COPY' OR [component]='COLLECTION')`
  - **CK_Backup_ExecutionLog_Status**: `([status]='WARNING' OR [status]='SKIPPED' OR [status]='FAILED' OR [status]='SUCCESS')`

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| status | SUCCESS | Operation completed successfully. | 1 |
| component | COLLECTION | Logged by Collect-BackupStatus.ps1. Operations include per-server collection summaries with file counts and duration. | 1 |
| component | NETWORK_COPY | Logged by Process-BackupNetworkCopy.ps1. Operations include per-file copy results with byte counts and throughput. | 2 |
| status | FAILED | Operation encountered an error. error_message contains the summary; error_details may contain the full stack trace. | 2 |
| status | SKIPPED | Operation intentionally bypassed — typically logged when there is no work to do. | 3 |
| component | AWS_UPLOAD | Logged by Process-BackupAWSUpload.ps1. Operations include per-file upload results with byte counts and throughput. | 3 |
| component | RETENTION | Logged by Process-BackupRetention.ps1. Operations include LOCAL_DELETE and NETWORK_DELETE with byte counts. HISTORICAL record operations are excluded from logging. | 4 |
| status | WARNING | Operation completed with non-fatal issues. | 4 |

**Recent failures by component** [sort:1] -- Shows failed operations from the last 7 days grouped by pipeline component for troubleshooting.

```sql
SELECT
    component,
    operation,
    server_name,
    database_name,
    file_name,
    error_message,
    started_dttm
FROM ServerOps.Backup_ExecutionLog
WHERE status = 'FAILED'
  AND started_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY started_dttm DESC;
```

**Component summary — last 24 hours** [sort:2] -- Aggregated view of operations per component showing success/failure counts and throughput.

```sql
SELECT
    component,
    COUNT(*) AS total_operations,
    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) AS succeeded,
    SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) AS failed,
    SUM(bytes_processed) / 1073741824.0 AS total_gb_processed,
    AVG(duration_ms) AS avg_duration_ms
FROM ServerOps.Backup_ExecutionLog
WHERE started_dttm >= DATEADD(DAY, -1, GETDATE())
GROUP BY component
ORDER BY component;
```

**Network copy throughput trend** [sort:3] -- Daily throughput analysis for network copy operations over the last 30 days.

```sql
SELECT
    CAST(started_dttm AS DATE) AS copy_date,
    COUNT(*) AS files_copied,
    SUM(bytes_processed) / 1073741824.0 AS total_gb,
    CASE
        WHEN SUM(duration_ms) > 0
        THEN SUM(bytes_processed) / 1048576.0 / (SUM(duration_ms) / 1000.0)
        ELSE 0
    END AS avg_mb_per_second
FROM ServerOps.Backup_ExecutionLog
WHERE component = 'NETWORK_COPY'
  AND status = 'SUCCESS'
  AND started_dttm >= DATEADD(DAY, -30, GETDATE())
GROUP BY CAST(started_dttm AS DATE)
ORDER BY copy_date DESC;
```


### Backup_FileTracking

Tracks backup files through the complete pipeline from creation through network copy, AWS upload, and eventual deletion. Provides full audit trail and enables idempotent processing by preventing duplicate operations.

**Data Flow:** Collect-BackupStatus.ps1 queries msdb.backupset on each monitored server, inserts one row per discovered backup with PENDING or SKIPPED pipeline statuses based on Backup_DatabaseConfig flags (backup_network_copy_enabled, backup_aws_upload_enabled), and captures compressed_size_bytes from the on-disk file via UNC path. In InitialLoad mode all statuses are set to HISTORICAL. Process-BackupNetworkCopy.ps1 claims PENDING network rows via atomic batch UPDATE, copies files to the centralized network share on FA-SQLDBB, and sets network_copy_status to COMPLETED or FAILED with path and timing. Process-BackupAWSUpload.ps1 independently claims PENDING AWS rows, uploads to S3 Glacier via AWS CLI, and sets aws_upload_status to COMPLETED or FAILED with the S3 path. Process-BackupRetention.ps1 evaluates chain-based retention using FULL backup counts from Backup_DatabaseConfig, deletes expired files from local and network storage, and records local_deleted_dttm and network_deleted_dttm. sp_Backup_Monitor reads this table to detect stale PENDING files (status PENDING with NULL started timestamp aged beyond threshold) and logs detections to Backup_AlertHistory.

**Decoupled Pipeline Coordination:** [sort:1] FileTracking is the coordination layer for four independent scripts that each own one pipeline stage. No script depends on another having run — network copy and AWS upload both read from source servers via UNC paths, not from each other's output. This enables true parallel execution and fault isolation: S3 outages do not block network copies and vice versa.

**Atomic Batch Claim Pattern:** [sort:2] Process-BackupNetworkCopy and Process-BackupAWSUpload both use an atomic batch claim pattern: a single UPDATE sets all PENDING rows to IN_PROGRESS before per-file processing begins. The WHERE clause includes status = PENDING, so overlapping executions cannot claim the same files. Individual started_dttm timestamps are set when each file actually begins processing, creating three observable states: IN_PROGRESS with NULL start (claimed, queued), IN_PROGRESS with timestamp (actively processing), and COMPLETED/FAILED (finished).

**Source-Agnostic Discovery:** [sort:3] Tracks backups regardless of whether they were created by Redgate SQL Backup (.sqb files) or native SQL Server backup (.bak/.trn files). Detection is based on msdb.backupset entries, and backup_source is set automatically based on file extension. This supports the current Redgate-managed environment and a future transition to native xFACts backup execution.

**Compressed Size vs Logical Size:** [sort:4] file_size_bytes contains the logical/uncompressed size from msdb.backupset.backup_size. compressed_size_bytes contains the actual on-disk file size captured via UNC path at collection time. Redgate compression typically achieves 10:1 ratios, so without compressed_size_bytes, retention space reporting would overstate reclaimed space by an order of magnitude. Process-BackupRetention uses COALESCE(compressed_size_bytes, file_size_bytes) for accurate reporting, falling back to logical size for historical records where compressed size was not captured.

**HISTORICAL Status and Phased Migration:** [sort:5] The HISTORICAL status marks records that were not processed by xFACts — either because they pre-date xFACts tracking or were distributed by Redgate before xFACts took over. InitialLoad mode sets all statuses to HISTORICAL. Process-BackupRetention skips ExecutionLog writes for HISTORICAL records to prevent log flooding during large-scale cleanup of pre-existing files.

**AG Listener Path Resolution:** [sort:6] For databases enrolled under the AG Listener (server_id = 0), the server_name field contains AVG-PROD-LSNR which cannot be used for UNC admin shares. All four pipeline scripts use Get-PhysicalServerFromPath to parse the physical server name from the backup filename pattern (TYPE_SERVER_DATABASE_TIMESTAMP.ext). The destination folder structure still uses AVG-PROD-LSNR for unified organization. Process-BackupRetention has a legacy fallback for old (local) filename patterns that maps server_id to physical server name.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| tracking_id (IDENTITY) | bigint | No | IDENTITY | Unique identifier for the tracking record |
| server_id | int | No | — | FK to ServerRegistry.server_id |
| server_name | varchar(128) | No | — | Denormalized server name for query convenience |
| database_name | varchar(128) | No | — | Database name |
| backup_type | varchar(10) | No | — | FULL, DIFF, or LOG |
| backup_source | varchar(20) | No | 'REDGATE' | Source of backup: REDGATE (.sqb files) or NATIVE (.bak files) |
| file_name | varchar(500) | No | — | Backup filename |
| file_size_bytes | bigint | Yes | — | Logical/uncompressed file size from msdb.backupset |
| compressed_size_bytes | bigint | Yes | — | Actual on-disk file size (via UNC path at collection time) |
| backup_start_dttm | datetime | Yes | — | When backup started (from msdb.backupset) |
| backup_finish_dttm | datetime | No | — | When backup completed (from msdb.backupset) |
| local_path | varchar(500) | No | — | Full local path to backup file |
| local_deleted_dttm | datetime | Yes | — | When file was cleaned from local storage |
| network_copy_status | varchar(20) | No | 'PENDING' | PENDING, IN_PROGRESS, COMPLETED, FAILED, SKIPPED, HISTORICAL |
| network_copy_started_dttm | datetime | Yes | — | When network copy started |
| network_copy_completed_dttm | datetime | Yes | — | When network copy completed |
| network_path | varchar(500) | Yes | — | Full network path after successful copy |
| network_deleted_dttm | datetime | Yes | — | When file was cleaned from network storage |
| aws_upload_status | varchar(20) | No | 'PENDING' | PENDING, IN_PROGRESS, COMPLETED, FAILED, SKIPPED, HISTORICAL |
| aws_upload_started_dttm | datetime | Yes | — | When AWS upload started |
| aws_upload_completed_dttm | datetime | Yes | — | When AWS upload completed |
| aws_path | varchar(500) | Yes | — | S3 path after successful upload |
| msdb_backup_set_id | int | Yes | — | backup_set_id from source server's msdb.backupset |
| created_dttm | datetime | No | getdate() | When the tracking record was created |
| notes | varchar(500) | Yes | — | Relevant notes for context |
| network_copy_retry_count | smallint | No | 0 | Number of times this file has been retried for network copy. Incremented when the retry step resets a FAILED file to PENDING. When this value reaches the configured maximum (GlobalConfig network_copy_max_retries), the file is left FAILED permanently and a Teams alert is fired. |
| aws_upload_retry_count | smallint | No | 0 | Number of times this file has been retried for AWS upload. Incremented when the retry step resets a FAILED file to PENDING. When this value reaches the configured maximum (GlobalConfig aws_upload_max_retries), the file is left FAILED permanently and a Teams alert is fired. |

  - **PK_Backup_FileTracking** (CLUSTERED): tracking_id -- PRIMARY KEY
  - **IX_Backup_FileTracking_AWSPending** (NONCLUSTERED): aws_upload_status
  - **IX_Backup_FileTracking_NetworkPending** (NONCLUSTERED): network_copy_status
  - **IX_Backup_FileTracking_ServerDatabase** (NONCLUSTERED): server_id, database_name, backup_finish_dttm
  - **IX_Backup_FileTracking_Summary** (NONCLUSTERED): server_id, database_name, backup_type, backup_finish_dttm [includes: backup_start_dttm, file_size_bytes]
  - **UQ_Backup_FileTracking_ServerBackup** (NONCLUSTERED): server_id, msdb_backup_set_id

**Check Constraints:**

  - **CK_Backup_FileTracking_AWSStatus**: `([aws_upload_status]='HISTORICAL' OR [aws_upload_status]='SKIPPED' OR [aws_upload_status]='FAILED' OR [aws_upload_status]='COMPLETED' OR [aws_upload_status]='IN_PROGRESS' OR [aws_upload_status]='PENDING')`
  - **CK_Backup_FileTracking_BackupSource**: `([backup_source]='NATIVE' OR [backup_source]='REDGATE')`
  - **CK_Backup_FileTracking_BackupType**: `([backup_type]='LOG' OR [backup_type]='DIFF' OR [backup_type]='FULL')`
  - **CK_Backup_FileTracking_NetworkStatus**: `([network_copy_status]='HISTORICAL' OR [network_copy_status]='SKIPPED' OR [network_copy_status]='FAILED' OR [network_copy_status]='COMPLETED' OR [network_copy_status]='IN_PROGRESS' OR [network_copy_status]='PENDING')`

**Foreign Keys:**

  - **FK_Backup_FileTracking_ServerRegistry**: server_id -> dbo.ServerRegistry.server_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| network_copy_status,aws_upload_status | PENDING | Awaiting processing. Set by Collect-BackupStatus.ps1 when the corresponding Backup_DatabaseConfig flag is enabled (backup_network_copy_enabled or backup_aws_upload_enabled). The next run of the processing script will pick up this file. | 1 |
| network_copy_status,aws_upload_status | IN_PROGRESS | Claimed by a processing script via atomic batch UPDATE. If the started timestamp is NULL, the file is queued behind other files in the batch. If the started timestamp is populated, the file is actively being copied or uploaded. | 2 |
| network_copy_status,aws_upload_status | COMPLETED | Successfully processed. The corresponding path column (network_path or aws_path) contains the destination location. The completed timestamp records when processing finished. | 3 |
| network_copy_status,aws_upload_status | FAILED | Error occurred during processing. The Backup_ExecutionLog entry for this tracking_id contains the error message. FAILED files are automatically retried up to the configured maximum (GlobalConfig network_copy_max_retries / aws_upload_max_retries). Each retry increments the retry count column. Files that exhaust all retries remain FAILED permanently and generate a Teams alert via Send-TeamsAlert. | 4 |
| network_copy_status,aws_upload_status | SKIPPED | Intentionally bypassed based on database configuration. Set by Collect-BackupStatus.ps1 when the corresponding Backup_DatabaseConfig flag is disabled. Network copy: backup_network_copy_enabled = 0. AWS upload: backup_aws_upload_enabled = 0. | 5 |
| network_copy_status,aws_upload_status | HISTORICAL | Not processed by xFACts. Set during InitialLoad mode for all records, indicating the backup was distributed by Redgate or another mechanism before xFACts pipeline management began. Processing scripts ignore HISTORICAL records. Retention processes HISTORICAL records but skips ExecutionLog writes to prevent log flooding. | 6 |

**Pipeline status for recent backups** [sort:1] -- Shows all backups from the last 7 days with their network copy and AWS upload progress.

```sql
SELECT
    server_name,
    database_name,
    backup_type,
    backup_source,
    file_name,
    backup_finish_dttm,
    network_copy_status,
    network_copy_completed_dttm,
    aws_upload_status,
    aws_upload_completed_dttm
FROM ServerOps.Backup_FileTracking
WHERE backup_finish_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY backup_finish_dttm DESC;
```

**Stale PENDING files** [sort:2] -- Files stuck in PENDING with no started timestamp — the condition sp_Backup_Monitor checks for stale detection.

```sql
SELECT
    tracking_id,
    server_name,
    database_name,
    backup_type,
    file_name,
    network_copy_status,
    network_copy_started_dttm,
    aws_upload_status,
    aws_upload_started_dttm,
    DATEDIFF(MINUTE, backup_finish_dttm, GETDATE()) AS minutes_since_backup
FROM ServerOps.Backup_FileTracking
WHERE (network_copy_status = 'PENDING' AND network_copy_started_dttm IS NULL)
   OR (aws_upload_status = 'PENDING' AND aws_upload_started_dttm IS NULL)
ORDER BY backup_finish_dttm;
```

**Failed operations needing attention** [sort:3] -- Any file where network copy or AWS upload failed. Review Backup_ExecutionLog for error details or reset to PENDING for retry.

```sql
SELECT
    tracking_id,
    server_name,
    database_name,
    backup_type,
    file_name,
    network_copy_status,
    aws_upload_status,
    backup_finish_dttm
FROM ServerOps.Backup_FileTracking
WHERE network_copy_status = 'FAILED'
   OR aws_upload_status = 'FAILED'
ORDER BY backup_finish_dttm DESC;
```

**Compression ratio analysis** [sort:4] -- Compares logical vs compressed backup sizes per server and database. Useful for evaluating Redgate compression effectiveness and accurate space reporting.

```sql
SELECT
    server_name,
    database_name,
    COUNT(*) AS backup_count,
    SUM(compressed_size_bytes) / 1073741824.0 AS total_compressed_gb,
    SUM(file_size_bytes) / 1073741824.0 AS total_logical_gb,
    CAST(
        SUM(file_size_bytes) * 1.0
        / NULLIF(SUM(compressed_size_bytes), 0)
        AS DECIMAL(5,1)
    ) AS compression_ratio
FROM ServerOps.Backup_FileTracking
WHERE compressed_size_bytes IS NOT NULL
GROUP BY server_name, database_name
ORDER BY total_compressed_gb DESC;
```

**Reset a failed operation for retry** [sort:5] -- Resets a failed network copy back to PENDING for reprocessing. Change column names for AWS retry (aws_upload_status, aws_upload_started_dttm, aws_upload_completed_dttm, aws_path).

```sql
UPDATE ServerOps.Backup_FileTracking
SET network_copy_status = 'PENDING',
    network_copy_started_dttm = NULL,
    network_copy_completed_dttm = NULL
WHERE tracking_id = @TrackingID;
```

**Full pipeline history for a database** [sort:6] -- Complete lifecycle view for a single database showing sizes, pipeline statuses, and deletion timestamps.

```sql
SELECT
    backup_type,
    file_name,
    file_size_bytes / 1048576.0 AS logical_size_mb,
    compressed_size_bytes / 1048576.0 AS compressed_size_mb,
    backup_finish_dttm,
    network_copy_status,
    aws_upload_status,
    local_deleted_dttm,
    network_deleted_dttm
FROM ServerOps.Backup_FileTracking
WHERE server_name = 'DM-PROD-DB'
  AND database_name = 'crs5_oltp'
ORDER BY backup_finish_dttm DESC;
```

  - **Backup_DatabaseConfig**: [sort:1] Backup_DatabaseConfig controls which pipeline stages apply to each database (backup_network_copy_enabled, backup_aws_upload_enabled) and defines chain-based retention counts (full_retention_chain_local_count, full_retention_chain_network_count). Collect-BackupStatus.ps1 reads these flags to determine initial statuses. Process-BackupRetention.ps1 reads the retention counts to calculate per-database cutoff timestamps.
  - **Backup_ExecutionLog**: [sort:2] Each pipeline script logs per-file operations to Backup_ExecutionLog with the tracking_id as a foreign key. This provides a detailed audit trail for troubleshooting: when a file shows FAILED status, the ExecutionLog entry contains the error message and timing. HISTORICAL records are excluded from retention logging to prevent table bloat.
  - **Backup_AlertHistory**: [sort:3] sp_Backup_Monitor reads FileTracking to detect stale PENDING files — specifically records where status is PENDING, the started timestamp is NULL, and time since backup_finish_dttm exceeds the configurable threshold. Detections are logged to Backup_AlertHistory and auto-resolved when the file's status changes from PENDING.
  - **Backup_Status**: [sort:4] Backup_Status provides a dashboard summary of each pipeline process. The processing scripts update FileTracking per-file and Backup_Status per-run. FileTracking is the detailed record; Backup_Status is the operational at-a-glance view showing whether each process last succeeded and when.


### Collect-BackupStatus.ps1

Discovers backup completions from msdb.backupset across all registered SQL Server instances and populates Backup_FileTracking for pipeline processing. Runs as a WAIT process under Orchestrator v2 every 5 minutes. Supports two modes: InitialLoad (all historical data, HISTORICAL status) and ongoing (incremental since last collection, PENDING/SKIPPED based on database flags). Calls sp_Backup_Monitor at end of each run.

**Data Flow:** Reads dbo.ServerRegistry for SQL Server instances and AG Listeners with serverops_backup_enabled = 1. Reads dbo.DatabaseRegistry joined to Backup_DatabaseConfig for enrolled databases and their pipeline flags. Queries msdb.backupset with CROSS APPLY to backupmediafamily on each target server for backup records, filtering by device_type (2=Disk, 7=Redgate Virtual Device) and excluding GUID paths (VSS/virtual device backups). Reads Backup_FileTracking for last collected timestamp per server to build incremental date filters. Writes discovered backups to Backup_FileTracking in batches of 500 with compressed_size_bytes captured via UNC path. Logs per-server results to Backup_ExecutionLog. Updates Backup_Status (COLLECTION process). Calls sp_Backup_Monitor at completion to detect stale PENDING files. Reports to Orchestrator v2 via Complete-OrchestratorTask callback.

**Date-Based Incremental Collection:** [sort:1] Ongoing collection queries only backups newer than the last collected timestamp per server, using MAX(backup_finish_dttm) from FileTracking as the date filter. This keeps msdb queries fast regardless of history size and ensures no duplicate tracking records.

**Empty Results vs Connection Failure:** [sort:2] When the msdb query returns null, the script runs a test query (SELECT 1) to distinguish between "no new backups" and "server unreachable." This prevents false failure reports for servers that simply have no new backups since last collection.

**Backup Source Detection:** [sort:3] Determines backup_source from file extension: .sqb files are REDGATE, all others are NATIVE. This enables pipeline analysis by source and supports tracking through the phased migration from Redgate to native backups.

**Extension Whitelist Filtering:** [sort:4] Only backup files with recognized extensions (.sqb, .bak, .trn) are collected from msdb.backupmediafamily. This replaced an earlier GUID exclusion filter (NOT LIKE '{%') that failed to exclude Redgate temporary filenames (SQLBACKUP_<GUID>). Temporary filenames appear in msdb while Redgate is actively writing a backup; if collected, the real file is missed when Redgate renames it because the timestamp watermark has already advanced. The whitelist approach is more defensive — any unrecognized filename pattern is silently excluded.

  - **sp_Backup_Monitor**: [sort:1] Called at the end of each successful collection run with @PreviewOnly = 0. The monitor detects stale PENDING files and logs detections to Backup_AlertHistory. This ensures pipeline health monitoring runs on the collection schedule regardless of processing script status.
  - **Orchestrator v2**: [sort:2] Runs as a WAIT process — the orchestrator holds for completion before launching dependent pipeline processes (network copy, AWS upload). TaskId and ProcessId are passed by the engine; the script calls back via Complete-OrchestratorTask with status, duration, and output summary.


### Process-BackupAWSUpload.ps1

Uploads completed backup files to AWS S3 Glacier Flexible Retrieval storage. Reads from source servers via UNC admin shares (not from the network copy destination), enabling true parallel execution with Process-BackupNetworkCopy.ps1. Uses AWS CLI for uploads with explicit credential paths. Runs as a FIRE_AND_FORGET process under Orchestrator v2.

**Data Flow:** Reads aws_bucket_name and aws_path_prefix from dbo.GlobalConfig. Verifies AWS CLI accessibility. Queries Backup_FileTracking for PENDING AWS upload records, joining through DatabaseRegistry, ServerRegistry (serverops_backup_enabled = 1), and Backup_DatabaseConfig (backup_aws_upload_enabled = 1). Claims files via atomic batch UPDATE to IN_PROGRESS. For each file: converts local path to UNC (with AG Listener path resolution), uploads to S3 via AWS CLI with Glacier storage class, and sets status to COMPLETED or FAILED with aws_path and timing. Logs per-file operations to Backup_ExecutionLog. Updates Backup_Status (AWS_UPLOAD process). Reports to Orchestrator v2 via callback.

**Parallel Execution via Source Path Independence:** [sort:1] Reads backup files from source servers via UNC admin shares — the same source as Process-BackupNetworkCopy.ps1. Neither script depends on the other's output. Both can process the same file simultaneously: one copying to the network share, the other uploading to S3. This eliminates a serial bottleneck and provides fault isolation between the two distribution paths.

**Glacier Flexible Retrieval Storage Class:** [sort:2] All uploads use S3 Glacier Flexible Retrieval, hardcoded in the Invoke-S3Upload function. This provides the lowest-cost archival storage appropriate for disaster recovery backups that are rarely accessed. Retrieval takes several hours, making network copy the primary path for operational restores.

**Automatic Retry with Exhaustion Alerting:** [sort:3] Before querying for PENDING files, the script checks for FAILED uploads where aws_upload_retry_count is below the configurable maximum (GlobalConfig aws_upload_max_retries, default 2). Eligible files are reset to PENDING with an incremented retry count, then picked up by the normal processing loop. Files that exhaust all retries remain FAILED and a Teams alert is fired via the shared Send-TeamsAlert function with trigger type BACKUP_AWS_UPLOAD_EXHAUSTED and the tracking_id as trigger value. Dedup in Teams.RequestLog prevents repeat alerts for the same file.


### Process-BackupNetworkCopy.ps1

Copies completed backup files from source servers to the centralized network share on FA-SQLDBB. Reads from source servers via UNC admin shares, creates a standardized folder hierarchy (server/database/type), and updates Backup_FileTracking pipeline status. Runs as a FIRE_AND_FORGET process under Orchestrator v2.

**Data Flow:** Reads network_backup_root from dbo.GlobalConfig. Queries Backup_FileTracking for PENDING network copy records, joining through DatabaseRegistry, ServerRegistry (serverops_backup_enabled = 1), and Backup_DatabaseConfig (backup_network_copy_enabled = 1). Claims files via atomic batch UPDATE to IN_PROGRESS. For each file: converts local path to UNC using source server name (with AG Listener path resolution via filename parsing), copies to network share, and sets status to COMPLETED or FAILED with network_path and timing. Logs per-file operations to Backup_ExecutionLog. Updates Backup_Status (NETWORK_COPY process). Reports to Orchestrator v2 via callback.

**Fire-and-Forget Execution:** [sort:1] Runs as FIRE_AND_FORGET under Orchestrator v2. The orchestrator does not hold for completion, preventing large file copies from blocking subsequent orchestrator cycles. Multiple runs catch up naturally if backups accumulate. MaxFiles parameter (default 100) caps per-run processing.

**Automatic Retry with Exhaustion Alerting:** [sort:2] Before querying for PENDING files, the script checks for FAILED copies where network_copy_retry_count is below the configurable maximum (GlobalConfig network_copy_max_retries, default 2). Eligible files are reset to PENDING with an incremented retry count, then picked up by the normal processing loop. Files that exhaust all retries remain FAILED and a Teams alert is fired via the shared Send-TeamsAlert function with trigger type BACKUP_NETWORK_COPY_EXHAUSTED and the tracking_id as trigger value. Dedup in Teams.RequestLog prevents repeat alerts for the same file.


### Process-BackupRetention.ps1

Deletes backup files past their retention period from local source servers and the centralized network share. Uses chain-based retention logic: keeps N full backup chains per database as configured in Backup_DatabaseConfig, deleting all files (FULL, DIFF, LOG) older than the Nth oldest FULL. Runs daily as a FIRE_AND_FORGET process under Orchestrator v2.

**Data Flow:** Reads dbo.ServerRegistry for master switch check. Queries Backup_FileTracking with a CTE that ranks FULL backups per database and joins Backup_DatabaseConfig for chain counts to calculate per-database cutoff timestamps. Processes local deletes first (requiring network_copy_status IN COMPLETED or HISTORICAL as a safety check), then network deletes. For each file: builds UNC path (with AG Listener resolution and legacy (local) filename fallback), deletes the file or marks complete if already gone externally, and updates local_deleted_dttm or network_deleted_dttm. Logs per-file operations to Backup_ExecutionLog (excluding HISTORICAL records). Uses COALESCE(compressed_size_bytes, file_size_bytes) for accurate space reporting. Updates Backup_Status (RETENTION process). Reports to Orchestrator v2 via callback.

**Chain-Based Cutoff Calculation:** [sort:1] Uses a CTE with ROW_NUMBER() OVER (PARTITION BY server_name, database_name ORDER BY backup_finish_dttm DESC) to rank FULL backups still on each storage tier. The Nth ranked FULL's backup_finish_dttm becomes the cutoff — all files older than this are eligible for deletion. This ensures complete backup chains are always available and prevents orphaned DIFFs or LOGs.

**Local Delete Safety Check:** [sort:2] Local files are only deleted when network_copy_status is COMPLETED or HISTORICAL. This ensures a file has been safely copied to the network share before being removed from the source server. The check prevents data loss if the network copy pipeline is stalled.

**Graceful Handling of Externally Deleted Files:** [sort:3] When a file targeted for deletion no longer exists on disk, the script marks it complete with a note ("Retention marked complete - file already deleted externally") rather than logging an error. This handles files cleaned up by Redgate, manual intervention, or disk maintenance without generating false failure alerts.


### xFACts-BackupFunctions.ps1

Shared scoped-function library for the ServerOps.Backup pipeline scripts. Centralizes the backup-filename physical-server parsing, the local-to-UNC admin-share path conversion, the Backup_ExecutionLog detail writer, the AWS-upload and network-copy Backup_FileTracking status writes, and the retry-handling routine that the backup collector and the network-copy, AWS-upload, and retention processors previously duplicated. Dot-sourced after xFACts-OrchestratorFunctions.ps1, which supplies the Write-Log, Get-SqlData, Invoke-SqlNonQuery, and Send-TeamsAlert it calls.

**Data Flow:** Dot-sourced by Collect-BackupStatus.ps1, Process-BackupNetworkCopy.ps1, Process-BackupAWSUpload.ps1, and Process-BackupRetention.ps1 after xFACts-OrchestratorFunctions.ps1. Get-bkp_PhysicalServerFromPath and Convert-bkp_ToUncPath resolve the physical server and admin-share UNC path for a backup file so the processors can reach files on whichever AG replica produced them. Write-bkp_ExecutionLog writes one detail row per operation to ServerOps.Backup_ExecutionLog. Set-bkp_AwsUploadStatus and Set-bkp_NetworkCopyStatus update the per-file status columns in ServerOps.Backup_FileTracking that the Control Center Backup Monitoring page displays. Invoke-bkp_RetryFailedFiles resets retry-eligible failed files in Backup_FileTracking back to PENDING and posts the retries-exhausted alert via the shared Send-TeamsAlert. The functions hold no state of their own; they operate on values the calling script passes in.

**No self-import of the orchestrator:** [sort:1] As a shared-library file it declares no IMPORTS section, so it does not dot-source xFACts-OrchestratorFunctions.ps1 even though it depends on that file's Write-Log, Get-SqlData, Invoke-SqlNonQuery, and Send-TeamsAlert. Consuming scripts dot-source the orchestrator first, then this helper. This keeps the load order explicit at the call site and avoids a shared library reaching back into platform infrastructure.

**One execution-log writer for all callers:** [sort:2] Write-bkp_ExecutionLog takes the union of every pipeline's columns, including the error_details column only the AWS-upload path supplies, so all four scripts share one writer. Any unsupplied duration, byte count, error message, or error detail is written as a SQL NULL rather than a zero or empty string, which keeps a missing metric distinguishable from a real zero in Backup_ExecutionLog.

**Separate status writers per column family:** [sort:3] The AWS-upload and network-copy pipelines write to different Backup_FileTracking column families, so each has its own writer (Set-bkp_AwsUploadStatus, Set-bkp_NetworkCopyStatus) rather than one writer parameterized across both. Each writer includes only the columns it was given, building the UPDATE set clause from the supplied values.

**Retry handling parameterized by operation:** [sort:4] Invoke-bkp_RetryFailedFiles serves both the network-copy and AWS-upload pipelines over their separate column families through a single -Operation discriminator that selects the column family, the alert label, and the trigger type. It performs both halves of the retry step: resetting retry-eligible failed files to PENDING and alerting on files that have exhausted their retries. The network-copy script's network-root verification stays inline in that script because it is adjacent to, not part of, the shared retry pattern.



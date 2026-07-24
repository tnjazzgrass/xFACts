# Batch Monitoring

*Watching the pipeline so you don't have to stare at it*

Clients send us data in batches — new accounts, payments, phone numbers, address updates. Those batches go through a series of processing stages before the data actually lands in the system. Batch Monitoring watches every step of that journey for all three batch types, and when something goes sideways, it tells you about it before anyone else notices. Think of it as the person in the control room who actually pays attention to the monitors.






The Problem

Clients send us data. That data arrives as files. Those files become batches. Those batches go through a series of processing stages — uploading, releasing, merging, posting, importing — until eventually the accounts land in the system and everyone's happy.

*Eventually.*

Because somewhere in that chain, things can go wrong. An upload fails. A batch gets stuck and never starts processing. A payment file sits in limbo for three hours while everyone assumes someone else is watching it. A bulk data update stages fine but never imports. And nobody finds out until the next morning when the reports look wrong and a client asks why their data isn't in the system.

That's a domino effect. Accounts that didn't load. Reports that show the wrong numbers. Phone numbers that didn't update. Someone in Operations having a very long day because nobody noticed the failure until it was too late.

BatchOps catches failures early — before they become *situations*.






How It Works



Collector
Polls DM
→
Tracking Table
Updated
→
Alert Conditions
Evaluated
→
Teams / Jira
Notified
→
Someone
Investigates

Collect → Track → Evaluate → Alert — every 5 minutes, three pipelines


Three independent collectors check on Debt Manager every 5 minutes, each watching a different kind of batch. They look at what's happening, compare it to what *should* be happening, and raise their hand when something doesn't add up.

When something goes wrong, you get notified. Teams message. Jira ticket. While you're still asleep maybe, but at least someone knows.






Three Batch Types, One Goal

Debt Manager processes three fundamentally different kinds of batch data, and each one can fail in its own special way.

| Batch Type | What It Is | What Can Go Wrong |
| --- | --- | --- |
| **New Business** | New account placements from clients — the files that bring accounts into the system for the first time. | Uploads fail. Releases stall. Merges freeze halfway through. A batch sits in a queue for six hours and nobody notices. |
| **Payments** | Payment files, manual entries, and reversals — the money moving through the system. | Import failures. Posting stalls. Partial postings where half the payments go through and the other half don't. Reversals that fail midway. |
| **BDL Import** | Bulk data updates — phone numbers, addresses, account tags, consumer updates. Both scheduled daily runs and user-initiated imports from the BDL Import wizard. | Staging failures where the data doesn't validate. Import failures where validated data doesn't make it into the system. Processing stalls where partitions stop moving. |


Different data, different pipelines, different failure modes. But the monitoring pattern is the same for all three: watch Debt Manager, track what's happening, and tell someone when it stops.






What It Catches

Not all problems announce themselves. Some batch failures are obvious — an upload errors out and the status turns red. Those are easy. The hard ones are the batches that *look* fine but aren't actually doing anything. The status says "processing" but nothing has moved in an hour. The batch says "released" but it's been sitting in a queue all afternoon. Everything looks green. Everything is *not* fine.

BatchOps catches both kinds. The loud failures get immediate alerts. The quiet stalls get detected through activity monitoring — if the underlying logs stop showing progress, something is stuck, and you need to know about it.

And not every hiccup is worth a phone call. Some rejection is expected business behavior — an account doesn't meet criteria, a record fails validation. BatchOps distinguishes between "the system has a problem" and "the data has a problem" so that when you get notified, it's because something actually needs human attention.






The Evening Report

Every evening before the maintenance window, a summary card shows up in Teams. It's the batch pipeline's status report — a quick visual answer to "is anything still running?"

Green means all clear, nothing in flight. Yellow means batches are still processing — maybe hold off on that reboot. It's the automated equivalent of yelling "IS ANYONE STILL IN THE BUILDING?" before locking the doors.






The Control Center View

The Batch Monitoring page in the Control Center shows the current state of the pipeline at a glance — what's actively processing, what finished today, and the complete history of every batch that's been through the system. You can filter by batch type, drill down to a specific day, and see exactly what happened to each individual batch, including how long each processing phase took.

Historical data is available for trend analysis. Monthly batch volumes, average processing times, failure rates — all the data you need to spot patterns before they become problems. The batch that consistently takes longer than the others? You'll see it.






The Bottom Line

Batch processing is one of those things where small problems become big problems if nobody's watching. A failed upload at 2 AM turns into a missing report at 8 AM turns into an unhappy client by noon. A bulk data update that silently stalled means phone numbers that didn't update and calls that go to the wrong place.

BatchOps watches so you don't have to. Upload failures get tickets. Stalled processing gets flagged. Import failures get caught immediately. And every evening, a simple card tells you whether it's safe to start maintenance or whether you should wait five more minutes.

Three collectors. Four tables. One evening report. And the confidence that if something goes wrong in the batch pipeline, you'll know about it before anyone asks.

---

# Batch Monitoring — Control Center Guide

---

## Architecture
# Batch Monitoring Architecture

The narrative page tells you *what* Batch Monitoring does and *why*. This page tells you *how*. Four tables, four scripts, three parallel pipelines, and a whole lot of DM status codes that determine when something needs attention.






Schema Overview

The BatchOps schema is simple by design. Three tracking tables (one per batch type), one health dashboard, and no stored procedures or triggers. All logic lives in the PowerShell collectors, which makes the system easy to reason about: the tables store state, the scripts do everything else.



| Table | Role | Cardinality |
| --- | --- | --- |
| `NB_BatchTracking` | New Business batch lifecycle tracking | One row per batch (batch_id from DM) |
| `PMT_BatchTracking` | Payment batch lifecycle tracking | One row per batch (batch_id from DM) |
| `BDL_BatchTracking` | BDL import file lifecycle tracking | One row per file (file_registry_id from DM) |
| `Status` | Collector execution health | One row per process (collector_name) |



No foreign keys between the tracking tables. NB, PMT, and BDL are completely independent pipelines. They don't reference each other, don't share state, and don't coordinate timing. The only shared resource is `Status`, which each collector updates for its own row.







NB Batch Lifecycle

New Business batches have a dual state machine. The *batch status* tracks upload through release. The *merge status* tracks what happens after release. Nearly all batches reach RELEASED without issue — the merge phase is where things get interesting.





Upload
UPLOADING →
UPLOADED

→

Release
RELEASING →
RELEASED

→

Merge
MERGING →
MERGE_COMPLETE

→

Terminal
Success or
failure state


Batch status drives upload → release. Merge status takes over after RELEASED. Most batches reach RELEASED without issue — the merge is where things get interesting.


Batch Status (State Machine 1)

Tracks the upload/release lifecycle. In practice, nearly all batches progress smoothly to RELEASED (status 8). The interesting exceptions are UPLOADFAILED (status 7) and batches that stall in UPLOADED without being released.

| Status | Code | Terminal? | Notes |
| --- | --- | --- | --- |
| UPLOADING | 1 | No | Transient — rarely observed in polling snapshots |
| UPLOADED | 2 | No | Waiting for release. Monitored for unreleased stall. |
| RELEASED | 8 | No | The handoff point. Merge status takes over from here. |
| UPLOADFAILED | 7 | Yes | Immediate alert. Includes error details from batch log. |
| DELETED | 13 | Yes | Batch removed from DM. |


Statuses 3–6, 9–12, 14–15 exist in DM's reference table but have zero occurrences in historical data. They're transient states that don't appear in 5-minute polling snapshots.

Merge Status (State Machine 2)

Once a batch reaches RELEASED, the merge status tracks the consumer merge process. This is where the monitoring earns its keep.

| Status | Code | Terminal? | In Practice |
| --- | --- | --- | --- |
| POST_RELEASE_MERGE_COMPLETE | 3 | Yes | Primary success path (~204K batches historically) |
| PRTL_MRGD_WTH_ERS | 5 | Yes | Partial merge with errors |
| MERGE_CMPLT_WTH_ERS | 6 | Yes | Merge completed but with issues |
| PARTIAL_MERGED | 8 | Yes | Partial merge |
| FAILED | 10 | Yes | Merge failure |



Linking statuses are not in use. Merge statuses 4 (LINK_QUEUED), 5 (LINKING), and 9 (LINK_COMPLETE) have zero occurrences at Frost Arnett. If consumer linking is enabled in the future, the terminal state detection logic in the collector will need revisiting — LINK_COMPLETE would become the new success terminal instead of POST_RELEASE_MERGE_COMPLETE.







PMT Batch Lifecycle

Payment batches have a single state machine but multiple processing paths depending on batch type. The collector tracks all types but only alerts on terminal failures.





Import
NEWIMPORT →
IMPORTING

→

Process
RELEASED →
INPROCESS

→

Post
Journal entries
posted per payment

→

Terminal
POSTED / FAILED /
PARTIAL


Multiple processing paths depending on batch type (IMPORT, MANUAL, REVERSAL, REAPPLY). The collector tracks all types but only alerts on terminal failures.


Batch Types

| Type | Code | Description |
| --- | --- | --- |
| IMPORT | 1 | Standard payment file imports — the primary batch type |
| MANUAL | 2 | Manually entered payment batches |
| REVERSAL | 3 | Payment reversal batches |
| REAPPLY | 4 | Reapplied payment batches |


Terminal Failure States

The collector alerts on four terminal failure statuses. Everything else is either in-progress (continue tracking) or successful (mark complete, move on).

| Status | Severity | Behavior |
| --- | --- | --- |
| **IMPORTFAILED** | CRITICAL | File import failed before processing could begin |
| **FAILED** | CRITICAL | Batch failed during processing |
| **PARTIAL** | WARNING | Non-terminal — batch can be re-fired. Alert resets on recovery. |
| **REVERSALFAILED** | CRITICAL | Reversal processing failed |



PARTIAL is special. Unlike the other terminal failures, PARTIAL is non-terminal. The batch stays incomplete in the tracking table and continues polling. If someone re-fires it in DM and the status changes, the collector clears the completion fields and resets alert_count. This means the batch re-enters the monitoring pipeline as if it were new. A second failure generates a fresh alert.


Journal-Level Progress

While a payment batch is INPROCESS, the collector queries `cnsmr_pymnt_jrnl` to count posted (status 5) and failed (status 4) journals against the total header count. This gives real-time progress visibility that the batch header status alone doesn't provide.

The `posted_count`, `failed_count`, and `last_posted_dttm` columns in the tracking table update every polling cycle during INPROCESS. The Control Center uses these to show posting progress without anyone needing to query DM directly.


Journal counts can exceed header counts. When suspense items are resolved, they generate additional journal entries against existing batch headers. This is expected behavior, not a bug — the posted_count legitimately exceeds total_count in these cases.







BDL File Lifecycle

BDL (Bulk Data Load) files are architecturally different from NB and PMT batches. There's no `bdl_batch` table with a status column. Instead, the file's current state is derived from log entries in `bdl_log`. File-level entries (where `sub_entty_nm_txt IS NULL`) track the overall lifecycle. Partition-level entries (where `sub_entty_nm_txt IS NOT NULL`) track processing progress within the file.





Register
File registered
in File_Registry

→

Stage
PROCESSING →
STAGED

→

Import
Partitions processed
records imported

→

Terminal
IMPORTED /
STAGEFAILED /
IMPORT_FAILED


File-level status is derived from the most recent bdl_log entry. Partition-level entries provide processing progress between file-level transitions.


File-Level Status Codes

| Status | Code | Terminal? | Notes |
| --- | --- | --- | --- |
| PROCESSING | 2 | No | File is being staged — partitions are being created and validated |
| STAGED | 10 | No | All partitions staged successfully, awaiting import |
| IMPORTED | 12 | Yes | Primary success path — all records imported into DM |
| STAGEFAILED | 8 | Yes | Staging validation failed — XML or data issues |
| IMPORT_FAILED | 11 | Yes | Staged successfully but import processing failed |
| DELETING | 13 | Yes | DM cleanup — file data being purged |
| DELETED | 14 | Yes | DM cleanup complete |


Partition-Based Progress

During the PROCESSING phase, DM splits the file into numbered partitions and processes each independently. The collector tracks progress by counting partitions with completed processing (status 3 with a non-null `bdl_prcssd_cnt`) against the total partition count. This provides a progress indicator similar to NB's merge progress or PMT's journal posting progress.

DM also captures summary counts in `file_rgstry_cstm_dtl` after processing: staging success/failure counts and import processed/success/failure counts. The collector reads these into the tracking table for historical analysis.

Orphan Detection

NB batches can be hard-deleted from DM outside the normal lifecycle (e.g., manual cleanup of failed rollover batches). When this happens, the batch row disappears from `new_bsnss_btch` and the collector can no longer query its status. The NB collector detects these orphans by checking all incomplete batch IDs against DM each cycle and marking any missing batches as `HARD_DELETED`.


Log-based vs. row-based status. NB and PMT batch status lives on the batch row itself (`new_bsnss_btch.new_bsnss_btch_stts_cd`, `cnsmr_pymnt_btch.cnsmr_pymnt_btch_stts_cd`). BDL status lives in `bdl_log` entries. This means the active batches live query for BDL must find the most recent file-level log entry to determine current status, whereas NB and PMT simply read the status column. The terminal status exclusion happens after ranking to ensure the true latest status is found.







Stall Detection

Stall detection is the core value proposition of the NB collector. A batch that's actively processing looks the same in DM's status tables as one that's frozen — both show INPROCESS or MERGING. The difference is activity in the logs.

NB: Log-Based Stall Detection

Each polling cycle, the collector reads the latest `new_bsnss_log` entry for the batch. If the log ID hasn't changed since last poll, the `stall_poll_count` increments. If new log activity appears, the counter resets to zero.

When `stall_poll_count` reaches the configured threshold (default: 12 polls = ~60 minutes of inactivity), the stall alert fires. The alert includes the last known log entry to give context on where processing stopped.

| Stall Type | What's Tracked | Default Threshold |
| --- | --- | --- |
| Merge stall | No new entries in new_bsnss_log | 12 polls (~60 min) |
| Upload stall | Batch stuck in UPLOADING status | 120 minutes |
| Queue wait (auto-merge) | Batch in RELEASED, auto-merge enabled | 300 minutes |
| Queue wait (no auto-merge) | Batch in RELEASED, no auto-merge | 1440 minutes (24h) |
| Unreleased | Batch stuck in UPLOADED | 480 minutes (8h) |
| Release-merge skip | RELEASED but no merge activity for N polls | 6 polls (~30 min) |



Auto-merge awareness. The queue wait threshold is different depending on whether the batch is configured for auto-merge in DM. Auto-merge batches should start processing on their own, so 5 hours in a queue is concerning. Non-auto-merge batches require manual intervention to start merging, so a much longer threshold (24 hours) is appropriate before alerting. The collector reads the auto-merge flag from DM to make this distinction.


PMT: Stall Detection (Planned)

Payment batch stall detection is deferred to a future phase. Currently, the PMT collector only alerts on terminal failure states. Log-based stall detection using `cnsmr_pymnt_btch_log` activity is architecturally supported — the `stall_poll_count` and `last_log_id` columns exist in PMT_BatchTracking and are updated each cycle — but the alert evaluation logic hasn't been implemented yet.

BDL: Partition-Based Stall Detection

BDL stall detection follows the same principle as NB but monitors partition-level activity in `bdl_log` instead of merge log entries. Each polling cycle, the collector reads the maximum `bdl_log_id` for partition-level entries. If unchanged from the previous poll, `stall_poll_count` increments. New partition activity resets the counter and clears `alert_count` for re-alerting on subsequent stall episodes.

The stall threshold (`bdl_stall_poll_threshold`, default 12) triggers an alert when partition processing has shown no activity for approximately 60 minutes. This catches files that start processing but freeze mid-partition without reaching a terminal file-level status.






Alert Conditions

NB: Eight Alert Conditions

| # | Condition | Dedup Strategy | Default Routing |
| --- | --- | --- | --- |
| 1 | Upload Failed (UPLOADFAILED) | batch_id only (one-time) | Jira + Teams |
| 2 | Release Failed | batch_id only (one-time) | Teams |
| 3 | Stalled Merge (log inactive) | batch_id + last_log_id (per-episode) | Teams |
| 4 | Upload Stall (stuck uploading) | batch_id + date (daily) | Teams |
| 5a | Queue Wait (auto-merge enabled) | batch_id + date (daily) | Teams |
| 5b | Queue Wait (no auto-merge) | batch_id + date (daily) | Teams (INFO) |
| 6 | Unreleased (stuck in UPLOADED) | batch_id + date (daily) | Teams |
| 7 | Release-Merge Skip Stall | batch_id only (one-time) | Teams |


Deduplication Strategies

| Strategy | Dedup Key | Behavior | Used By |
| --- | --- | --- | --- |
| One-time | batch_id | One alert per batch, ever. Once fired, never again for this batch. | Checks 1, 2, 7 |
| Per-episode | batch_id + last_log_id | One alert per stall episode. If the batch resumes and stalls again at a different log position, a new alert fires. | Check 3 |
| Daily re-alert | batch_id + date | One alert per day. Same condition tomorrow generates a fresh alert. Good for ongoing conditions that need daily visibility. | Checks 4, 5a, 5b, 6 |


PMT: Four Terminal Failure Conditions

| Condition | Severity | Jira Cascading Field | Dedup |
| --- | --- | --- | --- |
| IMPORTFAILED | CRITICAL | File Processing → Payment File Issue | alert_count (one per batch) |
| FAILED | CRITICAL | File Processing → Payment File Issue | alert_count (one per batch) |
| PARTIAL | WARNING | File Processing → Payment File Issue | alert_count (resets on recovery) |
| REVERSALFAILED | CRITICAL | File Processing → Payment File Issue | alert_count (one per batch) |


BDL: Three Alert Conditions


IMPORTFAILED insert-path timing. There's a known one-cycle delay for batches that are already in IMPORTFAILED when first discovered by the collector. The insert-path terminal detection doesn't include IMPORTFAILED (status 11), so these batches are inserted as incomplete and detected as terminal on the next polling cycle. The update path handles all terminal states correctly. This means a ~5 minute delay for this specific edge case.


| Condition | Severity | Jira Cascading Field | Dedup |
| --- | --- | --- | --- |
| STAGEFAILED | CRITICAL | File Processing → BDL Import Failure | alert_count (one per file) |
| IMPORT_FAILED | CRITICAL | File Processing → BDL Import Failure | alert_count (one per file) |
| Stall (partition inactive) | WARNING | File Processing → BDL Import Failure | batch_id + last_log_id (per-episode, re-alertable) |



NB alerting exclusion. Batches where `is_auto_release = 0 AND is_manual_upload = 0 AND is_auto_merge = 0` are excluded from all NB alert evaluations. These are manually-managed batches (such as Matt's Rollover Link Monitor process) that are intentionally handled outside the normal lifecycle and should not generate automated alerts.







Pre-Maintenance Summary

`Send-OpenBatchSummary.ps1` runs once daily before the maintenance window. Unlike the collectors, it queries DM directly for current state rather than reading the tracking tables.

Card Architecture

The Adaptive Card is built programmatically in PowerShell using a modular architecture. Each batch type has its own check function returning a standardized result object with `BatchType`, `Count`, `Details`, and `HasIssues` properties. The card builder iterates through all results and builds sections accordingly.

| Card Element | Content |
| --- | --- |
| Header | Yellow background, title, date |
| Active section | Yellow/warning color, bold ALL CAPS header, per-batch detail rows |
| Clear section | Green/good color, "All clear" message |
| Not-monitored section | Gray/subtle, placeholder for future expansion |
| Footer | Status message based on overall severity |


The script uses emoji placeholder tokens (`{{FIRE}}`, `{{WARN}}`, `{{CHECK}}`) instead of literal emoji characters. PowerShell 5.1 mangles multi-byte Unicode during JSON conversion, so the tokens are resolved by `Process-TeamsAlertQueue.ps1` at send time.


Direct INSERT, not sp_QueueAlert. The summary card uses the rich path — pre-built Adaptive Card JSON inserted directly into `Teams.AlertQueue` with the `card_json` field populated. The standard `sp_QueueAlert` path doesn't support pre-built cards. The `TR_Teams_AlertQueue_QueueDepth` trigger fires on the INSERT, signaling the Teams processor to deliver the card.







How Everything Connects

BatchOps reads from one external system and writes to three xFACts subsystems. The data flow is strictly one-directional: read from DM, write to xFACts. No feedback loops, no write-backs to the source.

Internal Flow

| From | To | Relationship |
| --- | --- | --- |
| `Collect-NBBatchStatus.ps1` | `NB_BatchTracking` | Creates, updates, completes, and detects orphaned tracking rows |
| `Collect-PMTBatchStatus.ps1` | `PMT_BatchTracking` | Creates, updates, and completes tracking rows |
| `Collect-BDLBatchStatus.ps1` | `BDL_BatchTracking` | Creates, updates, and completes tracking rows |
| All three collectors + summary | `Status` | Update own health row at execution start/end |
| All three collectors | `Teams.AlertQueue` | Direct INSERT for alert conditions |
| All three collectors | `Jira.TicketQueue` | Via sp_QueueTicket for Jira-routed conditions |
| `Send-OpenBatchSummary.ps1` | `Teams.AlertQueue` | Direct INSERT with pre-built card_json |


External Dependencies

| Dependency | Module | Purpose |
| --- | --- | --- |
| `Orchestrator.ProcessRegistry` | Orchestrator | Schedules all four scripts (5-min cycle for collectors, daily for summary) |
| `dbo.GlobalConfig` | Shared Infrastructure | AG config, alert thresholds, routing settings, feature toggles |
| Debt Manager (crs5_oltp) | External | Source system — read-only via AG secondary replica |
| `Teams.RequestLog` / `Jira.RequestLog` | Integration | Deduplication checks before alert queueing |


DM Source Tables

| DM Table | Used By | Purpose |
| --- | --- | --- |
| `new_bsnss_btch` | NB collector, Summary | Batch header data (status, counts, timestamps) |
| `Ref_new_bsnss_btch_stts_cd` | NB collector | Batch status code reference |
| `ref_cnsmr_mrg_lnk_stts_cd` | NB collector | Merge status code reference |
| `new_bsnss_log` | NB collector | Merge log activity for stall detection |
| `cnsmr_pymnt_btch` | PMT collector, Summary | Payment batch header data |
| `ref_pymnt_btch_stts_cd` | PMT collector | Payment status code reference |
| `ref_pymnt_btch_typ_cd` | PMT collector | Payment batch type reference |
| `cnsmr_pymnt_btch_log` | PMT collector | Payment log activity for stall detection |
| `cnsmr_pymnt_jrnl` | PMT collector | Journal-level posting progress |
| `bdl_log` | BDL collector, Active Batches | File-level status and partition-level processing progress |
| `ref_entty_async_stts_cd` | BDL collector, Active Batches | BDL status code reference |
| `File_Registry` | NB collector, BDL collector, Active Batches | Source filename and file metadata |
| `file_rgstry_dtl` | BDL collector, Active Batches | File record counts and batch identifier |
| `file_rgstry_cstm_dtl` | BDL collector | DM summary counts (staging success/failure, import success/failure) |

---

## Reference

### BDL_BatchTracking

BDL import lifecycle tracking table. Captures each BDL file from registration through terminal state with partition-based progress tracking, DM summary count capture from file_rgstry_cstm_dtl, and log-based stall detection. Tracks files from all BDL sources including Sterling ETL pipelines, manual IT imports, and xFACts BDL Import tool submissions.

**Data Flow:** Collect-BDLBatchStatus.ps1 queries the DM replica for BDL file data from multiple source tables: bdl_log for file-level status and partition progress, File_Registry and Ref_File_Stts_Cd for authoritative terminal state detection, file_rgstry_dtl for record counts, and file_rgstry_cstm_dtl for DM summary metrics. New files are inserted with terminal detection at insert time via File_Registry.file_stts_cd. Incomplete files are updated each polling cycle with current status from both bdl_log (bdl_log_status_code, bdl_log_status) and File_Registry (file_registry_status_code, file_registry_status). The collector writes to BDL_BatchTracking via the AG listener.

**Single-Table Source with Dual Row Types:** [sort:1] BDL has no separate batch header table. bdl_log serves as both status log and partition tracker. File-level rows (sub_entty_nm_txt IS NULL) track processing progress: PROCESSING, STAGED, and optionally IMPORTED. However, bdl_log does not reliably reflect the true terminal state of a file — some files complete processing without DM writing the expected terminal rows. Terminal state is determined exclusively from File_Registry.file_stts_cd (stored as file_registry_status_code), which is the authoritative source DM uses to record file outcomes.

**File-Level Row Identification:** [sort:2] File-level rows in bdl_log are identified by sub_entty_nm_txt IS NULL. The bdl_prttn_flg column is not a reliable discriminator because individual record failures (status 4 FAILED) also carry bdl_prttn_flg = N but have partition numbers and entity types. The sub_entty_nm_txt IS NULL filter was validated against the full dataset and produces a clean separation between file lifecycle events and partition processing events.

**Partition-Based Stall Detection:** [sort:3] Unlike NB which uses a separate log table (new_bsnss_log) for stall detection, BDL uses the partition-level rows in bdl_log itself. The max bdl_log_id across partition rows serves as the activity indicator. If this value is unchanged between polling cycles, stall_poll_count increments. When new partition rows appear (new max log_id), stall_poll_count and alert_count reset to zero, enabling re-alerting on subsequent stall episodes. This approach detects genuine stalls without false positives from large files that process slowly.

**DM Summary Counts from file_rgstry_cstm_dtl:** [sort:4] Record-level success and failure counts are stored by DM as name-value pairs in file_rgstry_cstm_dtl, linked through file_rgstry_dtl via file_registry_id. Five metrics are captured: Dm_staging_success_count, Dm_staging_failed_count, Dm_import_processed_count, Dm_import_success_count, Dm_import_failed_count. These are populated by DM at or near import completion, not during processing. For in-flight files, partition counts provide progress indication until the summary counts become available.

**Total Record Count from XML Header:** [sort:5] The total_record_count column comes from file_rgstry_dtl.file_rgstry_dtl_rec_ttl_cnt, which DM populates by parsing the total_count element from the BDL XML file header at registration time. This provides the denominator for completion percentage. The staging_failed_count can be derived as total_record_count minus staging_success_count — records that failed XML validation and were never written to the entity-specific staging tables (bdl_*_stgng).

**Cleanup Phase Not Monitored:** [sort:6] BDL files go through a cleanup phase (DELETING status 13, DELETED status 14) after successful import. This cleanup purges staging table data and occurs on a scheduled basis, sometimes days or weeks after import completion. The collector does not monitor the cleanup phase — IMPORTED (12) is treated as the terminal success state. Historical files that only have cleanup rows remaining in bdl_log were loaded during the initial backfill with completed_status IMPORTED inferred from the cleanup evidence.

**Source-Agnostic Collection:** [sort:7] The collector tracks all BDL files regardless of origin. Sources include Sterling/IBM ETL pipelines (SENDRIGHT_*, CLIENTS_*, DM_ACCNTS_*, LINK_DHS_*, ACRNT_*), manual IT ticket imports (SD-* filenames), and xFACts BDL Import tool submissions (xFACts_* filenames). The tracking table does not distinguish between sources — all files follow the same lifecycle through bdl_log. The future BDL Import write-back feature will use file_registry_id to correlate xFACts-originated imports with their tracking rows.

**File_Registry-Based Terminal Detection:** [sort:8] Terminal state is determined by File_Registry.file_stts_cd (stored as file_registry_status_code) rather than bdl_log status codes. Investigation revealed that bdl_log file-level rows do not reliably reflect the true file outcome: files can complete processing in DM without receiving IMPORTED (12) rows in bdl_log, and files that DM marks as FAILED (file_stts_cd = 6) may still show IMPORTED in bdl_log. File_Registry.file_stts_cd is the single authoritative source DM uses for file lifecycle state. The file_registry_status_code and file_registry_status columns are updated from File_Registry each polling cycle, and completed_dttm is sourced from File_Registry.upsrt_dttm when a terminal status is detected.

**Dual Status Column Naming:** [sort:9] Two distinct status sources are tracked on each row. bdl_log_status_code and bdl_log_status reflect the latest file-level entry from bdl_log — used for progress display and partition timing. file_registry_status_code and file_registry_status reflect File_Registry.file_stts_cd — used for authoritative terminal detection and displayed as the primary status in the Control Center. Column names include their source system prefix to prevent confusion between the two.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| tracking_id (IDENTITY) | bigint | No | IDENTITY | Unique xFACts identifier for each tracked BDL file. |
| file_registry_id | bigint | No | — | DM File_Registry ID. The trackable unit for BDL — one row per file. Unique constraint ensures no duplicates. |
| file_name | varchar(512) | Yes | — | Source filename from File_Registry.file_name_full_txt. Contains Sterling output filename for ETL files or user-specified filename for manual/xFACts imports. |
| entity_type | varchar(100) | Yes | — | BDL entity type from bdl_log partition rows (sub_entty_nm_txt). Values like CONSUMER_TAG, CONSUMER_PHONE, CONSUMER_ACCOUNT_AR_LOG. Identifies what type of data the file contains. |
| batch_identifier | varchar(256) | Yes | — | Batch identifier from file_rgstry_dtl.btch_idntfr_txt. The batch_id_txt value from the BDL XML file header. |
| total_record_count | int | Yes | — | Total record count from file_rgstry_dtl.file_rgstry_dtl_rec_ttl_cnt. Represents the total_count value parsed from the BDL XML file header at registration time. Serves as the denominator for completion percentage calculation. |
| bdl_log_status_code | smallint | Yes | — | Current file-level status code from bdl_log (bdl_prcss_stss_cd). Only file-level rows are tracked (sub_entty_nm_txt IS NULL). Joined to ref_entty_async_stts_cd for status text. Used for progress display and timing — not for terminal state detection, which is driven by file_registry_status_code from File_Registry. |
| bdl_log_status | varchar(32) | Yes | — | Human-readable file-level status text from ref_entty_async_stts_cd. Reflects bdl_log status for progress display. Terminal state is determined by file_registry_status_code from File_Registry. |
| file_created_dttm | datetime | Yes | — | When the file was registered in DM (File_Registry.file_crt_dttm). Slightly precedes the first PROCESSING row in bdl_log. |
| processing_started_dttm | datetime | Yes | — | Timestamp of the first PROCESSING (status 2) row in bdl_log for this file. Marks when DM began working on the file. |
| staged_dttm | datetime | Yes | — | Timestamp of the STAGED (status 10) row in bdl_log. Marks when DM completed staging file content into partition tables and is ready for import processing. |
| imported_dttm | datetime | Yes | — | Timestamp of the IMPORTED (status 12) row in bdl_log, if one was written. Some files complete processing without DM writing an IMPORTED row to bdl_log. This column is informational — terminal state is determined by file_registry_status_code, not by the presence of this timestamp. |
| staging_success_count | int | Yes | — | Records successfully staged. From file_rgstry_cstm_dtl where file_rgstry_cstm_dtl_nm = Dm_staging_success_count. Populated at or near import completion. |
| staging_failed_count | int | Yes | — | Records that failed staging validation. From file_rgstry_cstm_dtl where file_rgstry_cstm_dtl_nm = Dm_staging_failed_count. Calculated by DM as total_record_count minus staging_success_count. |
| import_processed_count | int | Yes | — | Records processed during import phase. From file_rgstry_cstm_dtl where file_rgstry_cstm_dtl_nm = Dm_import_processed_count. |
| import_success_count | int | Yes | — | Records successfully imported. From file_rgstry_cstm_dtl where file_rgstry_cstm_dtl_nm = Dm_import_success_count. |
| import_failed_count | int | Yes | — | Records that failed during import processing. From file_rgstry_cstm_dtl where file_rgstry_cstm_dtl_nm = Dm_import_failed_count. |
| partition_count | int | Yes | — | Count of distinct partitions created in bdl_log for this file. DM splits BDL files into partitions of approximately 100 operational units each. Used as progress denominator during in-flight processing. |
| partitions_completed | int | Yes | — | Number of partitions that have reached PROCESSED (3) or PARTIALLYPROCESSED (7) status with bdl_prcssd_cnt populated. Used as progress numerator during in-flight processing. |
| error_message | varchar(512) | Yes | — | Error message captured from bdl_log.bdl_log_msg on failure rows or from File_Registry.file_err_msg_txt. The collector checks bdl_log first, falling back to File_Registry if no log message exists. |
| file_registry_status_code | int | Yes | — | File_Registry status code from DM (File_Registry.file_stts_cd joined to Ref_File_Stts_Cd). The authoritative source for terminal state detection. Updated from File_Registry each polling cycle. Terminal values: 5 (PROCESSED), 6 (FAILED), 7 (CANCELED), 8 (PARTIALLY_PROCESSED). Non-terminal values indicate the file is still in-flight. |
| file_registry_status | varchar(50) | Yes | — | Human-readable File_Registry status text from Ref_File_Stts_Cd.file_stts_val_txt. Paired with file_registry_status_code. Displayed in the Control Center active batches view as the primary BDL status indicator. |
| is_complete | bit | No | 0 | Whether the file has reached a terminal state in File_Registry. Incomplete files are updated each polling cycle. Terminal File_Registry statuses: PROCESSED (5), FAILED (6), CANCELED (7), PARTIALLY_PROCESSED (8). |
| completed_dttm | datetime | Yes | — | When the file reached terminal state. Sourced from File_Registry.upsrt_dttm when file_stts_cd transitions to a terminal value (5, 6, 7, or 8). |
| completed_status | varchar(50) | Yes | — | How the file completed. Set from Ref_File_Stts_Cd.file_stts_val_txt when File_Registry.file_stts_cd reaches a terminal value. Values align with DM file status terminology. |
| last_log_id | bigint | Yes | — | Max bdl_log_id from partition-level rows for this file. Compared across polls to detect activity. Unlike NB which uses a separate log table, BDL stall detection uses the partition rows in bdl_log itself as the activity indicator. |
| last_log_dttm | datetime | Yes | — | Timestamp of the most recent partition-level bdl_log entry. Provides human-readable recency of processing activity. |
| stall_poll_count | int | No | 0 | Consecutive polls with no new partition activity. Increments when last_log_id is unchanged, resets to 0 on new activity. Drives stall detection alerting when threshold is exceeded. |
| alert_count | int | No | 0 | Number of alerts fired for this file. Used to prevent duplicate alerting. Resets to 0 when partition activity resumes, enabling re-alerting on subsequent stall episodes. |
| collected_dttm | datetime | No | getdate() | When this row was first inserted by the collector. |
| last_polled_dttm | datetime | No | — | When this row was last updated by the collector. |

  - **PK_BDL_BatchTracking** (CLUSTERED): tracking_id -- PRIMARY KEY
  - **IX_BDL_BatchTracking_Created** (NONCLUSTERED): file_created_dttm [includes: file_registry_id, file_name, is_complete, bdl_log_status_code, entity_type]
  - **IX_BDL_BatchTracking_Incomplete** (NONCLUSTERED): is_complete, last_polled_dttm [includes: file_registry_id, bdl_log_status_code, last_log_id, stall_poll_count]
  - **UQ_BDL_BatchTracking_FileRegistryID** (NONCLUSTERED): file_registry_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| completed_status | PROCESSED | File successfully processed by DM (file_registry_status_code = 5). All records staged and imported without file-level failure. Individual record-level failures may still exist within partitions but the overall file outcome is success. | 1 |
| completed_status | PARTIALLY_PROCESSED | File processed by DM with partial success (file_registry_status_code = 8). Some records failed during staging or import. The import_failed_count and staging_failed_count columns indicate the scope of failures. Common for large ETL files where business rules reject a subset of records. | 2 |
| completed_status | FAILED | File failed processing in DM (file_registry_status_code = 6). Covers both staging failures (XML validation, unconfigured entity types) and import processing failures. The error_message column and File_Registry.file_err_msg_txt provide failure details. | 3 |
| completed_status | CANCELED | File was canceled in DM (file_registry_status_code = 7). Never observed in production data but exists as a valid terminal state in the DM reference table. | 4 |
| completed_status | RETRY | Historical edge case. Four files from the initial data backfill had file_registry_status_code = 11 (RETRY) and were manually marked complete. RETRY is not treated as a terminal state by the collector — if new files land on this status, the collector will continue polling them and stall-alert if no progress is detected. | 5 |

**Active files with progress** [sort:1] -- All incomplete BDL files with partition progress, total record count, and stall detection state.

```sql
SELECT file_registry_id, file_name, bdl_log_status, entity_type,
        file_registry_status_code, file_registry_status,
        total_record_count, partition_count, partitions_completed,
        stall_poll_count, last_log_dttm,
        DATEDIFF(MINUTE, file_created_dttm, GETDATE()) AS age_minutes
FROM BatchOps.BDL_BatchTracking
WHERE is_complete = 0
ORDER BY file_created_dttm DESC;
```

**Recent completions with duration and record counts** [sort:2] -- Completed BDL files from the last 7 days with processing duration and DM summary counts.

```sql
SELECT file_registry_id, file_name, entity_type, completed_status,
       total_record_count, import_success_count, import_failed_count,
       staging_failed_count,
       file_created_dttm, completed_dttm,
       DATEDIFF(MINUTE, processing_started_dttm, completed_dttm) AS total_minutes
FROM BatchOps.BDL_BatchTracking
WHERE is_complete = 1
  AND completed_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY completed_dttm DESC;
```

**Stalled files** [sort:3] -- Incomplete files with active stall counters — partition activity has stopped.

```sql
SELECT file_registry_id, file_name, bdl_log_status, entity_type,
        file_registry_status_code, file_registry_status,
        total_record_count, partition_count, partitions_completed,
        stall_poll_count, last_log_dttm,
        DATEDIFF(MINUTE, last_log_dttm, GETDATE()) AS minutes_since_activity
FROM BatchOps.BDL_BatchTracking
WHERE is_complete = 0
  AND stall_poll_count > 0
ORDER BY stall_poll_count DESC;
```

**Daily BDL volume summary** [sort:4] -- Seven-day trend of BDL file volume, outcomes, and total records processed.

```sql
SELECT CAST(file_created_dttm AS DATE) AS file_date,
        COUNT(*) AS total_files,
        SUM(CASE WHEN completed_status IN ('PROCESSED', 'PARTIALLY_PROCESSED') THEN 1 ELSE 0 END) AS succeeded,
        SUM(CASE WHEN completed_status IN ('FAILED', 'CANCELED') THEN 1 ELSE 0 END) AS failed,
        SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS in_flight,
        SUM(ISNULL(total_record_count, 0)) AS total_records
FROM BatchOps.BDL_BatchTracking
WHERE file_created_dttm >= DATEADD(DAY, -7, GETDATE())
GROUP BY CAST(file_created_dttm AS DATE)
ORDER BY file_date DESC;
```

  - **Collect-BDLBatchStatus.ps1**: [sort:1] The collector script creates, updates, and completes rows in this table. It also reads incomplete rows during alert evaluation to detect stall conditions and terminal failures. The stall_poll_count and alert_count columns are maintained exclusively by the collector.
  - **Status**: [sort:2] The collector updates its own row in BatchOps.Status at the start (RUNNING) and end (IDLE + SUCCESS/FAILED) of each execution cycle. Status provides the proof-of-life signal for the Control Center dashboard.
  - **Teams.AlertQueue / Jira.TicketQueue**: [sort:3] Alert evaluation inserts directly into Teams.AlertQueue and calls Jira.sp_QueueTicket for detected conditions. Deduplication checks Teams.RequestLog and Jira.RequestLog before firing to prevent duplicate alerts.
  - **Tools.BDL_ImportLog**: [sort:4] Future integration: BDL files originated from the xFACts BDL Import tool carry a file_registry_id that can be joined to Tools.BDL_ImportLog.file_registry_id. The collector will write completion status back to BDL_ImportLog for xFACts-originated imports, closing the loop between the import tool and the monitoring collector.


### NB_BatchTracking

New Business batch lifecycle tracking table. Captures each NB batch from creation through terminal state with dual state machine timing, log-based stall detection, and event counters for resets and alerts.

**Data Flow:** Collect-NBBatchStatus.ps1 queries the DM secondary replica for new_bsnss_btch rows within the configured lookback window and inserts one tracking row per new batch with initial state, metrics, and terminal detection. Each subsequent polling cycle updates all incomplete rows with current DM status codes, merge status, batch metrics, and log-based stall detection counters from new_bsnss_log. Terminal states (DELETED, FAILED, or merge statuses 3/5/6/8/10) set is_complete = 1 and record completed_status. The alert evaluation step reads incomplete rows to detect 8 alert conditions and increments alert_count after firing. Send-OpenBatchSummary.ps1 queries DM directly for its pre-maintenance card rather than reading this table. The Control Center BatchOps page reads this table for active batch status display and historical analysis.

**Dual State Machine:** [sort:1] NB batches have two independent status progressions. batch_status_code tracks upload through release (UPLOADING to RELEASED). merge_status_code tracks post-release processing (POST_RELEASE_MERGING to POST_RELEASE_MERGE_COMPLETE). In practice, nearly all batches reach RELEASED (code 8) and remain there while the merge status drives the remaining lifecycle. The collector detects terminal states from both machines independently.

**Log-Based Stall Detection:** [sort:2] Stall detection monitors the new_bsnss_log table for activity rather than using static time thresholds. Each poll compares the current max log ID against the stored last_log_id. Unchanged means stall_poll_count increments. New activity resets both stall_poll_count and alert_count to zero, enabling re-alerting if the batch stalls again. This approach detects genuine stalls without false positives from large batches that process slowly.

**Auto-Merge Aware Queue Waits:** [sort:3] Batches with is_auto_merge = 1 use the shorter nb_queue_wait_minutes threshold because they should be merging automatically. Batches with is_auto_merge = 0 are intentionally held in RELEASED status pending manual merge initiation and use the longer nb_queue_wait_no_merge_minutes threshold to avoid false positive alerts. The no-auto-merge alerts generate INFO-level notifications rather than WARNING.

**Source System Decoupling:** [sort:4] All DM data is captured at collection time. Once a batch is in this table, monitoring queries never need to hit DM again for that batch's current state — only for detecting new log entries on incomplete batches. Completed batches are retained permanently for historical analysis, trend reporting, and duration benchmarking even if deleted from DM.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| tracking_id (IDENTITY) | bigint | No | IDENTITY | Unique xFACts identifier for each tracked batch |
| batch_id | bigint | No | — | DM source batch ID (new_bsnss_btch_id). Unique constraint ensures one row per batch |
| batch_name | varchar(8) | No | — | DM batch short name (new_bsnss_btch_shrt_nm) |
| file_registry_id | bigint | Yes | — | DM File_Registry reference for the uploaded file |
| upload_filename | varchar(512) | Yes | — | Source filename from File_Registry or batch upload text |
| is_manual_upload | bit | No | — | Whether the batch was manually uploaded (vs automated) |
| is_auto_release | bit | No | — | Whether the batch is configured for automatic release |
| batch_status_code | smallint | Yes | — | Current DM batch status code (Ref_new_bsnss_btch_stts_cd) |
| batch_status | varchar(32) | Yes | — | Human-readable batch status text |
| batch_created_dttm | datetime | Yes | — | When the batch was created in DM |
| release_started_dttm | datetime | Yes | — | When the release process began (new_bsnss_btch_rls_strt_dttm) |
| release_completed_dttm | datetime | Yes | — | When the batch was fully released (new_bsnss_btch_rlsd_dt) |
| merge_status_code | smallint | Yes | — | Current DM merge status code (ref_cnsmr_mrg_lnk_stts_cd) |
| merge_status | varchar(50) | Yes | — | Human-readable merge status text |
| merge_started_dttm | datetime | Yes | — | When merge activity began (derived from first log entry) |
| merge_completed_dttm | datetime | Yes | — | When merge reached terminal state |
| consumer_count | bigint | Yes | — | Total consumers in batch |
| account_count | bigint | Yes | — | Total accounts in batch |
| total_balance_amt | decimal(18,2) | Yes | — | Total account balance amount |
| posted_account_count | bigint | Yes | — | Accounts successfully posted |
| posted_balance_amt | decimal(18,2) | Yes | — | Posted account balance amount |
| excluded_consumer_count | bigint | Yes | — | Consumers excluded during processing |
| excluded_balance_amt | decimal(18,2) | Yes | — | Excluded consumer balance amount |
| original_principal_amt | decimal(18,2) | Yes | — | Original principal amount |
| original_interest_amt | decimal(18,2) | Yes | — | Original interest amount |
| original_collection_charges_amt | decimal(18,2) | Yes | — | Original collection charges amount |
| original_cost_amt | decimal(18,2) | Yes | — | Original cost amount |
| original_other_amt | decimal(18,2) | Yes | — | Original other charges amount |
| is_complete | bit | No | 0 | Whether the batch has reached a terminal state. Incomplete batches are updated each polling cycle |
| completed_dttm | datetime | Yes | — | When the batch reached terminal state |
| completed_status | varchar(50) | Yes | — | How the batch completed. Values are set from the DM merge status text for merge completions, or from the batch status for pre-merge terminals. See the completed_status values table in the Batch Status Reference section |
| last_log_id | bigint | Yes | — | Max new_bsnss_log_id from DM for this batch. Compared across polls to detect activity |
| last_log_dttm | datetime | Yes | — | Timestamp of the most recent log entry |
| stall_poll_count | int | No | 0 | Consecutive polls with no new log activity. Increments when last_log_id unchanged, resets to 0 on new activity. Only active when last_log_id is not NULL (merge has started) |
| reset_count | int | No | 0 | Number of times the batch was reset back to RELEASED during merge processing |
| last_reset_dttm | datetime | Yes | — | When the most recent reset occurred |
| alert_count | int | No | 0 | Number of alerts fired for this batch. Used to prevent duplicate alerting. Resets to 0 when log activity resumes, enabling re-alerting on subsequent stall episodes |
| collected_dttm | datetime | No | getdate() | When this row was first inserted by the collector |
| last_polled_dttm | datetime | No | — | When this row was last updated by the collector |
| is_auto_merge | bit | No | — | Whether the batch is configured for automatic merge after release. Batches with auto-merge disabled are intentionally held in RELEASED status and use a longer queue wait threshold |

  - **PK_NB_BatchTracking** (CLUSTERED): tracking_id -- PRIMARY KEY
  - **IX_NB_BatchTracking_Created** (NONCLUSTERED): batch_created_dttm [includes: batch_id, batch_name, is_complete, batch_status_code, merge_status_code]
  - **IX_NB_BatchTracking_Incomplete** (NONCLUSTERED): is_complete, last_polled_dttm [includes: batch_id, batch_status_code, merge_status_code, last_log_id, stall_poll_count]
  - **UQ_NB_BatchTracking_BatchID** (NONCLUSTERED): batch_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| completed_status | POST_RELEASE_MERGE_COMPLETE | Merge processing complete. Primary successful terminal state — represents the vast majority of completions. | 1 |
| completed_status | POST_RELEASE_PRTL_MRGD_WTH_ERS | Merge completed with partial errors. Terminal — manual resolution required for error accounts. | 2 |
| completed_status | POST_RELEASE_MERGE_CMPLT_WTH_ERS | Merge completed with errors. Terminal — manual resolution required. | 3 |
| completed_status | POST_RELEASE_PARTIAL_MERGED | Partial merge — processing stopped before completion. Terminal — manual resolution required. | 4 |
| completed_status | POST_RELEASE_LINK_COMPLETE | Link processing complete. Included in terminal detection for completeness but linking is not enabled in this environment — zero occurrences in historical data. | 5 |
| completed_status | DELETED | Batch deleted from DM (batch_status_code 5). Detected as terminal from the batch status state machine. | 6 |
| completed_status | FAILED | General failure (batch_status_code 13). Detected as terminal from the batch status state machine. | 7 |
| completed_status | INVESTIGATE | Historical batches marked for review during initial deployment. Internal value only. | 8 |

**Active batches with stall status** [sort:1] -- All incomplete NB batches with time since release and stall detection state.

```sql
SELECT batch_id, batch_name, batch_status, merge_status, is_auto_merge,
       batch_created_dttm, stall_poll_count, last_log_dttm,
       DATEDIFF(MINUTE, release_completed_dttm, GETDATE()) AS minutes_since_release
FROM BatchOps.NB_BatchTracking
WHERE is_complete = 0
ORDER BY batch_created_dttm DESC;
```

**Recent completions with duration** [sort:2] -- Completed batches from the last 7 days with total and merge duration metrics.

```sql
SELECT batch_id, batch_name, completed_status, batch_created_dttm, completed_dttm,
       DATEDIFF(MINUTE, batch_created_dttm, completed_dttm) AS total_minutes,
       DATEDIFF(MINUTE, merge_started_dttm, merge_completed_dttm) AS merge_minutes,
       account_count, total_balance_amt
FROM BatchOps.NB_BatchTracking
WHERE is_complete = 1
  AND completed_dttm >= DATEADD(DAY, -7, GETDATE())
ORDER BY completed_dttm DESC;
```

**Stalled batches only** [sort:3] -- Incomplete batches with active stall counters — merge has started but log activity has stopped.

```sql
SELECT batch_id, batch_name, stall_poll_count, last_log_id, last_log_dttm,
       last_polled_dttm,
       DATEDIFF(MINUTE, last_log_dttm, GETDATE()) AS minutes_since_activity
FROM BatchOps.NB_BatchTracking
WHERE is_complete = 0
  AND last_log_id IS NOT NULL
  AND stall_poll_count > 0
ORDER BY stall_poll_count DESC;
```

**Monthly batch volume summary** [sort:4] -- Six-month trend of batch volume, completion outcomes, and average account counts.

```sql
SELECT FORMAT(batch_created_dttm, 'yyyy-MM') AS month,
       COUNT(*) AS total_batches,
       SUM(CASE WHEN completed_status = 'POST_RELEASE_MERGE_COMPLETE' THEN 1 ELSE 0 END) AS merge_complete,
       SUM(CASE WHEN completed_status IN ('POST_RELEASE_PRTL_MRGD_WTH_ERS', 'POST_RELEASE_MERGE_CMPLT_WTH_ERS', 'POST_RELEASE_PARTIAL_MERGED') THEN 1 ELSE 0 END) AS merge_with_errors,
       SUM(CASE WHEN completed_status IN ('FAILED', 'DELETED') THEN 1 ELSE 0 END) AS failed_or_deleted,
       SUM(CASE WHEN is_complete = 0 THEN 1 ELSE 0 END) AS still_active,
       AVG(account_count) AS avg_accounts
FROM BatchOps.NB_BatchTracking
WHERE batch_created_dttm >= DATEADD(MONTH, -6, GETDATE())
GROUP BY FORMAT(batch_created_dttm, 'yyyy-MM')
ORDER BY month DESC;
```

  - **Collect-NBBatchStatus.ps1**: [sort:1] The collector script creates, updates, and completes rows in this table. It also reads incomplete rows during alert evaluation to detect 8 alert conditions. The stall_poll_count, alert_count, and reset_count columns are maintained exclusively by the collector.
  - **Status**: [sort:2] The collector updates its own row in BatchOps.Status at the start (RUNNING) and end (IDLE + SUCCESS/FAILED) of each execution cycle. Status provides the proof-of-life signal for the Control Center dashboard.
  - **Teams.AlertQueue / Jira.TicketQueue**: [sort:3] Alert evaluation inserts directly into Teams.AlertQueue and calls Jira.sp_QueueTicket for detected conditions. Deduplication checks Teams.RequestLog and Jira.RequestLog before firing to prevent duplicate alerts.


### PMT_BatchTracking

Payment batch lifecycle tracking table. Captures all payment batch types (Import, Manual, Reversal, Reapply, etc.) from creation through terminal state with log-based and journal-based stall detection, real-time posting progress via the consumer payment journal, and event counters for alerts.

**Data Flow:** Collect-PMTBatchStatus.ps1 queries the DM secondary replica for cnsmr_pymnt_btch rows within the configured lookback window and inserts one tracking row per new batch with initial state, metrics, and terminal detection. Each subsequent polling cycle updates all incomplete rows with current DM status, log activity from cnsmr_pymnt_btch_log, and journal-based progress from cnsmr_pymnt_jrnl (posted/failed counts and last posted timestamp). Terminal states (POSTED, FAILED, IMPORTFAILED, REVERSALFAILED) and hard deletes set is_complete = 1. PARTIAL batches remain incomplete and continue polling since they can be re-fired in DM. Alert evaluation reads incomplete terminal batches and routes notifications to Jira and/or Teams via per-condition GlobalConfig routing. The Control Center BatchOps page reads this table for active batch status display and historical analysis.

**Track All Alert Selectively:** [sort:1] All payment batch types (Import, Manual, Reversal, Reapply, Balance Adjustment, Virtual) are tracked for visibility, but stall detection and alerting only apply to IMPORT batches (batch_type_code = 3). Manual, Reversal, Reapply, and other batch types have unpredictable lifecycles that would generate false positives.

**Dual Activity Indicators:** [sort:2] IMPORT batches use different activity sources depending on lifecycle phase. During IMPORTING through RELEASED, the batch log table (cnsmr_pymnt_btch_log) tracks status transitions. During INPROCESS, the log goes quiet and real-time progress comes from the consumer payment journal (cnsmr_pymnt_jrnl) where individual payments transition from BATCHED to POSTED. The collector switches stall detection source accordingly.

**Journal vs Header Counts:** [sort:3] The table stores both the batch header posted_count (frozen snapshot from automated processing, only updates at terminal state) and journal_posted_count (real-time total from cnsmr_pymnt_jrnl including resolved suspense payments). Header counts match what DM displays for reconciliation. Journal counts provide the true operational picture for the Control Center. journal_posted_count is typically >= posted_count for batches with resolved suspense.

**PARTIAL Non-Terminal Recovery:** [sort:4] PARTIAL (batch_status_code 5) is not treated as terminal because batches can be re-fired in DM back to INPROCESS. When the collector detects a batch that was previously PARTIAL but now shows a non-PARTIAL status, it clears completed_status, completed_dttm, and resets alert_count to 0. This enables fresh alerting if the batch fails again after recovery.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| tracking_id (IDENTITY) | bigint | No | IDENTITY | Unique xFACts identifier for each tracked batch |
| batch_id | bigint | No | — | DM source batch ID (cnsmr_pymnt_btch_id). Unique constraint ensures one row per batch |
| batch_name | varchar(128) | Yes | — | DM batch name (cnsmr_pymnt_btch_nm) |
| external_name | varchar(128) | Yes | — | External batch name for file-based imports (cnsmr_pymnt_btch_extrnl_nm) |
| file_registry_id | bigint | Yes | — | DM File_Registry reference for the source file |
| batch_type_code | smallint | Yes | — | DM batch type code (cnsmr_pymnt_btch_typ_cd) |
| batch_type | varchar(20) | Yes | — | Human-readable batch type (e.g., IMPORT, MANUAL, REVERSAL, REAPPLY) |
| is_auto_post | bit | No | — | Whether the batch is configured for automatic posting (cnsmr_pymnt_btch_auto_post_flg) |
| original_batch_id | bigint | Yes | — | Source batch ID for REAPPLY batches (cnsmr_pymnt_btch_orgnl_id) |
| created_by_userid | bigint | Yes | — | DM user who created the batch (cnsmr_pymnt_btch_crt_usrid) |
| assigned_userid | bigint | Yes | — | DM user assigned to the batch (cnsmr_pymnt_btch_assgnd_usrid) |
| batch_status_code | smallint | Yes | — | Current DM batch status code (ref_pymnt_btch_stts_cd) |
| batch_status | varchar(32) | Yes | — | Human-readable batch status text |
| batch_created_dttm | datetime | Yes | — | When the batch was created in DM |
| released_dttm | datetime | Yes | — | When the batch was released for processing (cnsmr_pymnt_btch_rlsd_dttm) |
| processed_dttm | datetime | Yes | — | When batch processing completed (cnsmr_pymnt_btch_prcssd_dttm) |
| reversal_dttm | datetime | Yes | — | When a reversal was processed (cnsmr_pymnt_btch_rvrsl_dt) |
| payment_count | int | Yes | — | Total payments in batch (cnsmr_pymnt_btch_pymnt_cnt_nmbr) |
| imported_count | bigint | Yes | — | Records successfully imported (cnsmr_pymnt_btch_imprtd_rec_cnt) |
| active_count | int | Yes | — | Records sent to posting pipeline (cnsmr_pymnt_btch_actv_rec_cnt) |
| posted_count | int | Yes | — | Records posted per batch header (cnsmr_pymnt_btch_pstd_rec_cnt). Only updates at terminal state, not during INPROCESS |
| suspense_count | int | Yes | — | Records routed to suspense (cnsmr_pymnt_btch_sspns_rec_cnt) |
| payment_total_amt | decimal(18,2) | Yes | — | Total payment amount |
| active_total_amt | decimal(18,2) | Yes | — | Active payment amount |
| posted_total_amt | decimal(18,2) | Yes | — | Posted payment amount (batch header) |
| suspense_total_amt | decimal(18,2) | Yes | — | Suspense payment amount |
| is_complete | bit | No | 0 | Whether the batch has reached a terminal state. Incomplete batches are updated each polling cycle |
| completed_dttm | datetime | Yes | — | When the batch reached terminal state |
| completed_status | varchar(50) | Yes | — | How the batch completed. Currently set by the collector for: POSTED, FAILED, IMPORTFAILED, REVERSALFAILED, DELETED. PARTIAL may appear temporarily for batches that reached PARTIAL before being re-fired — the value is cleared if the batch recovers. See the completed_status values table in the Batch Status Reference section |
| last_log_id | bigint | Yes | — | Max cnsmr_pymnt_btch_log_id from DM for this batch. Used for stall detection during pre-INPROCESS phases |
| last_log_dttm | datetime | Yes | — | Timestamp of the most recent batch log entry |
| stall_poll_count | int | No | 0 | Consecutive polls with no new activity. Uses log_id during early phases, journal_posted_count during INPROCESS. Only tracks IMPORT batches (type_code = 3); non-IMPORT batches stay at 0 |
| alert_count | int | No | 0 | Number of alerts fired for this batch. Used to prevent duplicate alerting |
| collected_dttm | datetime | No | getdate() | When this row was first inserted by the collector |
| last_polled_dttm | datetime | No | — | When this row was last updated by the collector |
| journal_posted_count | int | Yes | — | Real-time posted count from cnsmr_pymnt_jrnl (status 5). Includes resolved suspense payments. NULL for batch types that do not use the payment journal |
| journal_failed_count | int | Yes | — | Failed count from cnsmr_pymnt_jrnl (status 4). Extremely rare in practice. NULL for batch types that do not use the payment journal |
| last_posted_dttm | datetime | Yes | — | Timestamp of the most recent posted payment in the journal. Provides real-time recency of posting activity |

  - **PK_PMT_BatchTracking** (CLUSTERED): tracking_id -- PRIMARY KEY
  - **IX_PMT_BatchTracking_Created** (NONCLUSTERED): batch_created_dttm [includes: batch_id, batch_name, is_complete, batch_status_code, batch_type_code]
  - **IX_PMT_BatchTracking_Incomplete** (NONCLUSTERED): is_complete, last_polled_dttm [includes: batch_id, batch_status_code, batch_type_code, last_log_id, stall_poll_count]
  - **UQ_PMT_BatchTracking_BatchID** (NONCLUSTERED): batch_id

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| batch_type | IMPORT | File-based payment import (batch_type_code 3). Primary batch type for automated processing. Stall detection and alerting apply to this type only. | 1 |
| batch_type | MANUAL | Manually entered payment batch. Tracked for visibility but no stall detection or alerting. | 2 |
| batch_type | REVERSAL | Payment reversal batch. Tracked for visibility but no stall detection. | 3 |
| batch_type | REAPPLY | Reapplied payment batch referencing an original_batch_id. Tracked for visibility but no stall detection. | 4 |
| completed_status | POSTED | All payments posted successfully (batch_status_code 4). Primary success terminal state — represents the vast majority of completions. | 1 |
| completed_status | FAILED | Batch processing failed (batch_status_code 6). Terminal failure requiring investigation. | 2 |
| completed_status | IMPORTFAILED | File import failed (batch_status_code 11). Terminal failure — source file could not be imported. | 3 |
| completed_status | REVERSALFAILED | Reversal processing failed (batch_status_code 27). Terminal failure requiring manual intervention. | 4 |
| completed_status | DELETED | Batch removed from DM. Detected via hard delete detection when the batch no longer exists in the source table. | 5 |
| completed_status | PARTIAL | Some payments posted, some failed (batch_status_code 5). Transitional only — not a true terminal state. Cleared if the batch is re-fired and recovers. May exist on historical batches from before the PARTIAL non-terminal fix. | 6 |

**Active batches with journal progress** [sort:1] -- All incomplete PMT batches with real-time posting progress and stall detection state.

```sql
SELECT batch_id, batch_name, batch_type, batch_status, active_count,
       journal_posted_count, journal_failed_count, stall_poll_count,
       last_posted_dttm,
       DATEDIFF(MINUTE, batch_created_dttm, GETDATE()) AS minutes_since_created
FROM BatchOps.PMT_BatchTracking
WHERE is_complete = 0
ORDER BY batch_created_dttm DESC;
```

**Journal vs header count comparison** [sort:2] -- Batches where journal posted count differs from header posted count — indicates resolved suspense payments.

```sql
SELECT batch_id, batch_name, batch_status, active_count,
       posted_count AS header_posted,
       journal_posted_count AS journal_posted,
       journal_posted_count - ISNULL(posted_count, 0) AS resolved_suspense_posted,
       suspense_count
FROM BatchOps.PMT_BatchTracking
WHERE journal_posted_count IS NOT NULL
  AND journal_posted_count <> ISNULL(posted_count, 0)
ORDER BY batch_id DESC;
```

**IMPORT batch stall status** [sort:3] -- Incomplete IMPORT batches with active stall counters showing minutes since last activity.

```sql
SELECT batch_id, batch_name, batch_status, stall_poll_count,
       journal_posted_count, last_posted_dttm, last_log_dttm, last_polled_dttm,
       DATEDIFF(MINUTE, COALESCE(last_posted_dttm, last_log_dttm), GETDATE()) AS minutes_since_activity
FROM BatchOps.PMT_BatchTracking
WHERE is_complete = 0
  AND batch_type_code = 3
  AND stall_poll_count > 0
ORDER BY stall_poll_count DESC;
```

  - **Collect-PMTBatchStatus.ps1**: [sort:1] The collector script creates, updates, and completes rows in this table. It also handles PARTIAL recovery detection (clearing completed fields and resetting alert_count when a re-fired batch leaves PARTIAL status). Stall detection counters and journal metrics are maintained exclusively by the collector.
  - **Status**: [sort:2] The collector updates its own row in BatchOps.Status at the start (RUNNING) and end (IDLE + SUCCESS/FAILED) of each execution cycle.
  - **Teams.AlertQueue / Jira.TicketQueue**: [sort:3] Terminal failure alert evaluation inserts directly into Teams.AlertQueue and calls Jira.sp_QueueTicket for IMPORTFAILED, FAILED, PARTIAL, and REVERSALFAILED conditions. Deduplication checks RequestLog tables before firing.


### Status

Multi-row collector execution dashboard. One row per BatchOps process, tracking execution state and timing for Control Center summary cards and operational health checks.

**Data Flow:** Each BatchOps collector script updates its own row at execution start (processing_status = RUNNING, started_dttm) and at execution end (processing_status = IDLE, completed_dttm, last_duration_ms, last_status). Rows are pre-seeded with one entry per registered process. The Control Center BatchOps page reads this table for process health dashboard cards showing last run time, duration, and success/failure status.

**Proof-of-Life Only:** [sort:1] The table tracks execution metadata (timing, status) rather than business metrics. Batch counts, alert counts, and error details live in their respective tracking tables and the Orchestrator TaskLog. This avoids maintaining duplicate counters that drift out of sync.

**Columns:**

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| status_id (IDENTITY) | int | No | IDENTITY | Unique row identifier |
| collector_name | varchar(50) | No | — | Name of the collector or reporting script (e.g., Collect-NBBatchStatus, Send-OpenBatchSummary) |
| batch_type | varchar(10) | No | — | Which batch type this process monitors: NB, PMT, BDL, or ALL |
| processing_status | varchar(20) | Yes | — | Current state: RUNNING, IDLE |
| started_dttm | datetime | Yes | — | When the current or most recent execution started |
| completed_dttm | datetime | Yes | — | When the most recent execution completed |
| last_duration_ms | int | Yes | — | Duration of the most recent execution in milliseconds |
| last_status | varchar(20) | Yes | — | Result of the most recent execution: SUCCESS, FAILED |

  - **PK_BatchOps_Status** (CLUSTERED): status_id -- PRIMARY KEY
  - **UQ_BatchOps_Status_CollectorName** (NONCLUSTERED): collector_name

**Status Values:**

| Column | Value | Meaning | Sort |
| --- | --- | --- | --- |
| last_status | SUCCESS | Most recent execution completed without errors. | 1 |
| last_status | FAILED | Most recent execution encountered errors. Check Orchestrator TaskLog for details. | 2 |
| processing_status | RUNNING | Collector is currently executing. Set at the start of each execution cycle. | 1 |
| processing_status | IDLE | Collector is between execution cycles. Set at the end of each execution cycle. | 2 |

**Process health check** [sort:1] -- All BatchOps processes with health classification based on last status and recency.

```sql
SELECT collector_name,
       CASE
           WHEN last_status = 'SUCCESS' AND DATEDIFF(MINUTE, completed_dttm, GETDATE()) <= 15
               THEN 'HEALTHY'
           WHEN last_status = 'FAILED' THEN 'FAILED'
           WHEN DATEDIFF(MINUTE, completed_dttm, GETDATE()) > 15 THEN 'STALE'
           ELSE 'UNKNOWN'
       END AS health_status,
       last_status, completed_dttm, last_duration_ms
FROM BatchOps.Status;
```

  - **Collect-NBBatchStatus.ps1**: [sort:1] Updates the row where collector_name = 'Collect-NBBatchStatus' at execution start and end.
  - **Collect-PMTBatchStatus.ps1**: [sort:2] Updates the row where collector_name = 'Collect-PMTBatchStatus' at execution start and end.
  - **Send-OpenBatchSummary.ps1**: [sort:3] Updates the row where collector_name = 'Send-OpenBatchSummary' at execution start and end.


### Collect-BDLBatchStatus.ps1

Monitors Debt Manager BDL file lifecycle from registration through terminal state. Collects new files, updates status for in-flight files with partition-based progress tracking, captures DM summary counts from file_rgstry_cstm_dtl, and evaluates alert conditions. Terminal state determined by File_Registry.file_stts_cd (PROCESSED, FAILED, CANCELED, PARTIALLY_PROCESSED). Two alert conditions: FAILED files and stalled partition processing.

**Data Flow:** Reads GlobalConfig for AG replica settings, alert thresholds, and routing configuration. Reads bdl_log (file-level and partition-level rows), ref_entty_async_stts_cd, File_Registry, Ref_File_Stts_Cd, file_rgstry_dtl, and file_rgstry_cstm_dtl from the DM replica for BDL file status and progress data. Terminal state detection uses File_Registry.file_stts_cd as the authoritative source, stored as file_registry_status_code and file_registry_status on the tracking row. Writes to BatchOps.BDL_BatchTracking for lifecycle tracking. Queues alerts to Teams.AlertQueue and Jira.sp_QueueTicket with deduplication checks against Teams.RequestLog and Jira.RequestLog. Updates BatchOps.Status for proof-of-life monitoring.

**Three-Step Execution Pattern:** [sort:1] Follows the established BatchOps collector pattern: Step 1 (Collect) discovers new files via bdl_log and inserts tracking rows with terminal detection from File_Registry.file_stts_cd at insert time. Step 2 (Update) polls all incomplete files for current status from both bdl_log (progress info, partition counts, timestamps) and File_Registry (terminal state via file_registry_status_code). Step 3 (Evaluate) checks two alert conditions: FAILED completions and stalled processing.

**Multi-Table DM Source Queries:** [sort:2] Unlike NB which reads primarily from one batch header table and one log table, the BDL collector reads from five DM source tables per file: bdl_log for lifecycle status and partition progress, File_Registry for filename and timestamps, file_rgstry_dtl for XML header metadata (total record count, batch identifier), and file_rgstry_cstm_dtl for DM-calculated summary counts (staging/import success/failed/processed). This requires multiple queries per file but captures the complete picture that DM displays in its own BDL logging screen.

**Bitwise Alert Routing:** [sort:3] Each of the two alert conditions has an independent GlobalConfig routing value using bitwise flags: 0 = disabled, 1 = Teams only, 2 = Jira only, 3 = Both. The script checks routing -band 2 for Jira and -band 1 for Teams. Alert conditions: bdl_alert_failed_routing (covers all FAILED completions regardless of failure phase) and bdl_alert_stall_routing (partition processing stalls). Deduplication checks prevent duplicate alerts for the same trigger.

**Stall Deduplication via Composite Trigger:** [sort:4] Stall alerts use a composite trigger_value of fileRegId_lastLogId. This ensures one alert per stall episode — if the file resumes activity (new partition rows), alert_count resets to zero. If it stalls again at a different log position, the new trigger_value produces a fresh dedup key, enabling re-alerting. Terminal failure alerts (STAGEFAILED, IMPORT_FAILED) use fileRegId alone for one-time alerting.

  - **BDL_BatchTracking**: [sort:1] Primary data store. The script inserts new tracking rows, updates all incomplete rows each cycle with status from bdl_log (bdl_log_status_code, bdl_log_status) and File_Registry (file_registry_status_code, file_registry_status), partition progress, DM summary counts, and stall detection counters. Terminal state detection uses File_Registry.file_stts_cd via file_registry_status_code.
  - **Collect-NBBatchStatus.ps1 / Collect-PMTBatchStatus.ps1**: [sort:2] Sibling collector following the same three-step architectural pattern for BDL files. All three collectors run independently under the orchestrator in the same dependency group.
  - **Send-OpenBatchSummary.ps1**: [sort:3] Complementary script for daily pre-maintenance summary. Currently has a BDL placeholder returning not-monitored status. Future enhancement: implement Get-OpenBDLImports function to include active BDL files in the summary card.


### Collect-NBBatchStatus.ps1

PowerShell script that monitors Debt Manager New Business batch lifecycle from creation through terminal state. Collects new batches, updates status for in-flight batches, tracks merge log activity for stall detection, and evaluates 8 alert conditions with configurable Jira/Teams routing.

**Data Flow:** Reads GlobalConfig for AG replica settings, alert thresholds, and routing configuration. Reads new_bsnss_btch, Ref_new_bsnss_btch_stts_cd, ref_cnsmr_mrg_lnk_stts_cd, File_Registry, and new_bsnss_log from the DM secondary replica. Writes to BatchOps.NB_BatchTracking (inserts and updates), BatchOps.Status (execution state). Alert evaluation writes to Teams.AlertQueue (direct INSERT) and Jira.TicketQueue (via sp_QueueTicket). Reads Teams.RequestLog and Jira.RequestLog for deduplication checks. Calls Complete-OrchestratorTask for orchestrator callback.

**Bitwise Alert Routing:** [sort:1] Each of the 8 alert conditions has an independent GlobalConfig routing value using bitwise flags: 0 = disabled, 1 = Teams only, 2 = Jira only, 3 = Both. The script checks routing -band 2 for Jira and routing -band 1 for Teams. A master switch (nb_alerting_enabled) must be 1 for any alerts to fire regardless of individual routing.

**Deduplication Strategy:** [sort:2] Three deduplication patterns by alert type: batch_id only (checks 1, 2, 7) for one alert per stall episode; batch_id + last_log_id (check 3) for one alert per stall episode with re-alerting on new stall points; batch_id + date (checks 4, 5a, 5b, 6) for daily re-alerting on ongoing conditions.

**Error Extraction for Upload Failures:** [sort:3] Upload failure alerts (Check 1) include error details extracted from new_bsnss_log via CTE with STRING_AGG, showing up to 5 distinct errors with noise filtering. Messages matching known non-actionable patterns are excluded to keep alerts focused on actual problems.

  - **NB_BatchTracking**: [sort:1] Primary data store. The script inserts new tracking rows, updates all incomplete rows each cycle, and sets terminal state when reached. Stall counters, alert counters, and reset counters are maintained exclusively by this script.
  - **Collect-PMTBatchStatus.ps1**: [sort:2] Sibling collector following the same architectural pattern for Payment batches. Both run independently under the orchestrator.
  - **Send-OpenBatchSummary.ps1**: [sort:3] Complementary script with a different purpose — daily summary rather than continuous monitoring. Queries DM directly rather than reading tracking tables.


### Collect-PMTBatchStatus.ps1

PowerShell script that monitors Debt Manager Payment batch lifecycle from creation through terminal state. Tracks all batch types, updates status with log and journal-based progress, and evaluates terminal failure alert conditions with configurable Jira/Teams routing.

**Data Flow:** Reads GlobalConfig for AG replica settings, lookback window, and alert routing configuration. Reads cnsmr_pymnt_btch, ref_pymnt_btch_stts_cd, ref_pymnt_btch_typ_cd, cnsmr_pymnt_btch_log, and cnsmr_pymnt_jrnl from the DM secondary replica. Writes to BatchOps.PMT_BatchTracking (inserts and updates), BatchOps.Status (execution state). Terminal failure alerts write to Teams.AlertQueue and Jira.TicketQueue. Reads RequestLog tables for deduplication. Calls Complete-OrchestratorTask for orchestrator callback.

**Config Source Tracking:** [sort:1] The script logs whether each configuration setting loaded from GlobalConfig or fell back to the script default. Log entries tagged with "(GlobalConfig)" or "(default)" provide diagnostic visibility into which settings are active and whether any are missing from the database.

**IMPORTFAILED Insert-Path Limitation:** [sort:2] The insert-path terminal detection does not include IMPORTFAILED (status 11). Batches already in IMPORTFAILED when first discovered are inserted as incomplete and detected as terminal on the next polling cycle. This causes a one-cycle delay before the alert fires. The update path correctly handles all terminal failure states.

  - **PMT_BatchTracking**: [sort:1] Primary data store. The script inserts new tracking rows, updates all incomplete rows each cycle with status, metrics, journal progress, and stall detection. Handles PARTIAL recovery by clearing completion fields and resetting alert_count.
  - **Collect-NBBatchStatus.ps1**: [sort:2] Sibling collector following the same architectural pattern for New Business batches. Both run independently under the orchestrator.


### Send-OpenBatchSummary.ps1

PowerShell script that generates a daily pre-maintenance processing summary across all Debt Manager batch types and sends a color-coded Adaptive Card notification to Teams before the nightly maintenance window.

**Data Flow:** Reads GlobalConfig for AG replica settings. Queries new_bsnss_btch and cnsmr_pymnt_btch on the DM secondary replica for in-flight batches, filtering out terminal and idle states. Builds a complete Adaptive Card JSON with sectioned layout and inserts directly into Teams.AlertQueue with the card_json field populated. Process-TeamsAlertQueue.ps1 delivers the card to Teams. Updates BatchOps.Status at execution start and end.

**Direct Card JSON Insert:** [sort:1] Inserts directly into Teams.AlertQueue with the card_json field rather than calling sp_QueueAlert, because the pre-built Adaptive Card requires the card_json field for rich formatting. The TR_Teams_AlertQueue_QueueDepth trigger fires on INSERT, signaling the processor to deliver the card.

**Modular Batch Check Functions:** [sort:2] Each batch type has its own function (Get-OpenNBBatches, Get-OpenPMTBatches, etc.) returning a standardized result object. Adding a new batch type requires writing one function and calling it in the main flow. BDL and Notice Processing sections exist as placeholders returning not-monitored status.

**State-Driven Card Colors:** [sort:3] Card color is determined by overall severity: yellow (warning) if any batch type has active open batches, green (good) if all monitored sections are clear. Individual sections use matching colors. The goal is to keep the card green before maintenance begins.

  - **Teams.AlertQueue**: [sort:1] Inserts one row per execution with the pre-built Adaptive Card JSON. Uses trigger_type = OpenBatchSummary and trigger_value = current date. No deduplication needed since this runs once daily on a schedule.
  - **Collect-NBBatchStatus.ps1 / Collect-PMTBatchStatus.ps1**: [sort:2] Complementary but independent — the summary queries DM directly for current state rather than reading the tracking tables. This means it reflects the live DM state at query time, which may differ slightly from the tracking table state depending on polling timing.


### xFACts-BatchOpsFunctions.ps1

Shared scoped-function library for the BatchOps batch-status collectors. Centralizes the read-replica source querying, availability-group read-server resolution, stall-duration text formatting, BatchOps.Status run-state writes, and Jira/Teams alert dispatch that the collectors and the pre-maintenance summary previously duplicated. Dot-sourced after xFACts-OrchestratorFunctions.ps1, which supplies the Get-AGReplicaRoles it calls.

**Data Flow:** Dot-sourced by Collect-BDLBatchStatus.ps1, Collect-NBBatchStatus.ps1, Collect-PMTBatchStatus.ps1, and Send-OpenBatchSummary.ps1 after xFACts-OrchestratorFunctions.ps1. Get-bat_SourceData runs read-only queries against the Debt Manager source database on the resolved read replica. Resolve-bat_ReadServer calls the shared Get-AGReplicaRoles to pick the read server by replica role. Set-bat_BatchStatus writes the RUNNING and IDLE rows to BatchOps.Status that the Control Center Process Status cards display. Send-bat_BatchAlert deduplicates against Jira.RequestLog, queues tickets via Jira.sp_QueueTicket, and posts Teams alerts via the shared Send-TeamsAlert. The functions hold no state of their own; they operate on the calling script's script-scope context ($script:ReadServer, $script:Config, $script:PollingIntervalMinutes).

**No self-import of the orchestrator:** [sort:1] As a shared-library file it declares no IMPORTS section, so it does not dot-source xFACts-OrchestratorFunctions.ps1 even though Resolve-bat_ReadServer depends on Get-AGReplicaRoles from it. Consuming scripts dot-source the orchestrator first, then this helper. This keeps the load order explicit at the call site and avoids a shared library reaching back into platform infrastructure.

**Caller-side execute gating:** [sort:2] Set-bat_BatchStatus and Send-bat_BatchAlert do no preview or execute checking of their own. The calling script gates each invocation with its own execute guard. This keeps the functions as pure writers with one calling convention across all four scripts rather than each carrying its own preview awareness.

**Alert dispatch owns the shared fields, callers own the counts:** [sort:3] Send-bat_BatchAlert holds the invariant Jira ticket field set, the deduplication query, and the weekend-aware due-date calculation, taking only the per-alert values as parameters. The per-script alert_count increment stays at the call site because it keys each collector's own tracking table.



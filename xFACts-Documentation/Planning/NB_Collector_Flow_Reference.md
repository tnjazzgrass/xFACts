# Collect-NBBatchStatus.ps1 — Step-by-Step Flow Reference

> **Source:** Collect-NBBatchStatus.ps1 v1.3.0 — all information derived directly from script code.
> **Purpose:** Team review document to confirm collector behavior is correct.

---

## Execution Order

The script runs four phases in sequence every cycle:

1. **Initialize Configuration**
2. **Step 1: Collect New Batches** (discover batches in DM not yet tracked)
3. **Step 2: Update Incomplete Batches** (poll DM for current state of tracked batches)
4. **Step 3: Evaluate Alert Conditions** (check for alert-worthy situations)
5. **Update Status** (write execution results to BatchOps.Status)
6. **Orchestrator Callback** (report back to v2 engine if launched by orchestrator)

---

## Phase 0: Initialize Configuration

**What it does:**
- Loads GlobalConfig settings for modules `BatchOps`, `Shared`, and `dbo`
- Sets script defaults, then overrides with any GlobalConfig values found

**Key defaults (used if GlobalConfig entry is missing):**

| Setting | Default | Purpose |
|---------|---------|---------|
| AGName | DMPRODAG | Availability Group name for replica detection |
| SourceReplica | SECONDARY | Which AG replica to read DM data from |
| NB_LookbackDays | 7 | How far back to look for new batches in DM |
| NB_StallPollThreshold | 12 | Consecutive unchanged polls before stall alert |
| NB_ReleaseMergeSkipStallThreshold | 6 | Stall threshold for RELEASING+merging anomaly |
| NB_UploadStallMinutes | 120 | Minutes in UPLOADING before stall alert |
| NB_QueueWaitMinutes | 300 | Minutes in RELEASED (auto-merge ON) before alert |
| NB_QueueWaitNoMergeMinutes | 1440 | Minutes in RELEASED (auto-merge OFF) before alert |
| NB_UnreleasedMinutes | 480 | Minutes in UPLOADED/RELEASENEEDED before alert |
| NB_AlertingEnabled | false | Master switch for all alerting |

**After config load:**
- Detects AG PRIMARY and SECONDARY server names
- Sets ReadServer based on SourceReplica config (or ForceSourceServer parameter)
- Sets WriteServer to the AG listener (always)
- Resolves polling interval from ProcessRegistry (if launched by orchestrator)
- Marks BatchOps.Status as RUNNING

---

## Step 1: Collect New Batches

**Purpose:** Discover NB batches in DM that xFACts doesn't know about yet.

**How it works:**

1. Queries `BatchOps.NB_BatchTracking` for ALL existing `batch_id` values (no filter)
2. Queries DM `new_bsnss_btch` for batches created within the last `NB_LookbackDays` days
   - Joins to `Ref_new_bsnss_btch_stts_cd` for status text
   - Joins to `ref_cnsmr_mrg_lnk_stts_cd` for merge status text
   - Joins to `File_Registry` for upload filename
3. Filters in memory: keeps only batches whose `batch_id` is NOT already in the tracking table
4. For each new batch, determines terminal state at insert time:

**Insert-path terminal detection:**

| Condition | is_complete | completed_status | completed_dttm |
|-----------|-------------|------------------|----------------|
| batch_status_code IN (5, 13) | 1 | 'DELETED' or 'FAILED' | DM upsrt_dttm |
| merge_status_code IN (3, 5, 6, 8, 10) | 1 | DM merge status text value | DM upsrt_dttm |
| Anything else | 0 | NULL | NULL |

**What this means:**
- A batch discovered in UPLOADFAILED (3) is inserted with `is_complete = 0`
- A batch discovered in RELEASEFAILED (9) is inserted with `is_complete = 0`
- A batch discovered in DELETED (5) or FAILED (13) is inserted with `is_complete = 1`
- A batch discovered already in a terminal merge state is inserted with `is_complete = 1`

**Fields populated on insert:**
- batch_id, batch_name, file_registry_id, upload_filename
- is_manual_upload, is_auto_release, is_auto_merge
- batch_status_code, batch_status (text)
- merge_status_code, merge_status (text)
- batch_created_dttm, release_started_dttm, release_completed_dttm
- merge_completed_dttm (only if terminal merge detected)
- consumer_count, account_count, total_balance_amt
- posted_account_count, posted_balance_amt
- excluded_consumer_count, excluded_balance_amt
- original amounts (principal, interest, collection charges, cost, other)
- is_complete, completed_dttm, completed_status
- stall_poll_count = 0, alert_count = 0, reset_count = 0

---

## Step 2: Update Incomplete Batches

**Purpose:** Poll DM for current state of every batch where `is_complete = 0`.

**How it works:**

1. Queries `BatchOps.NB_BatchTracking WHERE is_complete = 0` — **no lookback filter, no date filter**
   - This means ANY incomplete batch will be polled regardless of age
2. For each incomplete batch, queries DM for:
   - Current batch status and merge status (from `new_bsnss_btch` with ref table joins)
   - Log activity summary (from `new_bsnss_log`): max log ID, max/min log timestamps, reset count, last reset timestamp

**Stall detection logic (per batch):**

| Scenario | stall_poll_count | alert_count |
|----------|-----------------|-------------|
| No log entries exist yet (last_log_id is NULL) | Unchanged from previous | Unchanged |
| Log ID same as last poll (no new activity) | Increments by 1 | Unchanged |
| New log ID detected (activity resumed) | Resets to 0 | Resets to 0 |
| Batch transitioned from RELEASING (7) to any other status | Resets to 0 | Resets to 0 |

**Merge started detection:**
- If merge_started_dttm is not already set AND log entries exist, sets it from the earliest log entry timestamp

**Update-path terminal detection:**

| Condition | is_complete | completed_status | completed_dttm |
|-----------|-------------|------------------|----------------|
| batch_status_code IN (5, 13) | 1 | 'DELETED' or 'FAILED' | GETDATE() |
| merge_status_code IN (3, 5, 6, 8, 10) | 1 | DM merge status text value | GETDATE() |
| Anything else | 0 | (not changed) | (not changed) |

**What this means:**
- UPLOADFAILED (3) is **NOT** detected as terminal — batch remains is_complete = 0
- RELEASEFAILED (9) is **NOT** detected as terminal — batch remains is_complete = 0
- DELETED (5) and FAILED (13) ARE detected as terminal
- Terminal merge statuses ARE detected as terminal

**Update query writes:**
- batch_status_code, batch_status, merge_status_code, merge_status
- release_started_dttm, release_completed_dttm
- merge_started_dttm, merge_completed_dttm (uses COALESCE to not overwrite existing)
- consumer_count, account_count, total_balance_amt
- posted_account_count, posted_balance_amt
- excluded_consumer_count, excluded_balance_amt
- last_log_id, last_log_dttm
- stall_poll_count, alert_count
- reset_count, last_reset_dttm
- is_complete, completed_dttm (COALESCE), completed_status (COALESCE)
- last_polled_dttm = GETDATE()

---

## Step 3: Evaluate Alert Conditions

**Master switch:** `NB_AlertingEnabled` must be true (1) for any alerts to fire. Detection is always logged regardless.

Each check queries `BatchOps.NB_BatchTracking` (not DM directly). Each has its own routing config (0=None, 1=Teams, 2=Jira, 3=Both). All use RequestLog dedup to prevent duplicates.

After firing an alert, the script increments `alert_count` on the tracking row.

### CHECK 1: Upload Failures
- **Query:** `is_complete = 0 AND batch_status_code IN (3, 13) AND alert_count = 0`
- **What it catches:** UPLOADFAILED (3) and FAILED (13) batches that haven't been alerted yet
- **Trigger type:** `NB_UploadFailed`
- **Trigger value:** `{batchId}`
- **Alert behavior:** One alert per batch (alert_count check). Extracts error messages from `new_bsnss_log` in DM (up to 5 distinct errors).
- **Routing config:** NB_Alert_UploadFailed (default: 3 = Both)

### CHECK 2: Release Failures
- **Query:** `is_complete = 0 AND batch_status_code = 9 AND alert_count = 0`
- **What it catches:** RELEASEFAILED (9) batches that haven't been alerted yet
- **Trigger type:** `NB_ReleaseFailed`
- **Trigger value:** `{batchId}`
- **Alert behavior:** One alert per batch
- **Routing config:** NB_Alert_ReleaseFailed (default: 3 = Both)

### CHECK 3: Stalled Merges
- **Query:** `is_complete = 0 AND stall_poll_count >= {threshold} AND last_log_id IS NOT NULL AND alert_count = 0`
- **What it catches:** Batches with merge activity that has gone silent for too many consecutive polls
- **Trigger type:** `NB_StalledMerge`
- **Trigger value:** `{batchId}_{lastLogId}` (composite — new stall episode gets new trigger value since log ID changes when activity resumes)
- **Alert behavior:** One alert per stall episode. If activity resumes and stalls again, alert_count resets to 0 enabling re-alert.
- **Routing config:** NB_Alert_StalledMerge (default: 3 = Both)

### CHECK 4: Upload Stall
- **Query:** `is_complete = 0 AND batch_status_code = 2 AND DATEDIFF(MINUTE, batch_created_dttm, GETDATE()) >= {threshold}`
- **What it catches:** Batches stuck in UPLOADING (2) for longer than NB_UploadStallMinutes
- **Trigger type:** `NB_UploadStall`
- **Trigger value:** `{batchId}_{today's date}` (daily re-alert)
- **Routing config:** NB_Alert_UploadStall (default: 1 = Teams only)

### CHECK 5a: Queue Wait (Auto-Merge ON)
- **Query:** `is_complete = 0 AND batch_status_code = 8 AND last_log_id IS NULL AND release_completed_dttm IS NOT NULL AND is_auto_merge = 1 AND DATEDIFF(MINUTE, release_completed_dttm, GETDATE()) >= {threshold}`
- **What it catches:** RELEASED batches with auto-merge enabled that have never started merging (no log activity)
- **Trigger type:** `NB_QueueWait`
- **Trigger value:** `{batchId}_{today's date}` (daily re-alert)
- **Routing config:** NB_Alert_QueueWait (default: 1 = Teams only)

### CHECK 5b: Queue Wait (Auto-Merge OFF)
- **Query:** Same as 5a but `is_auto_merge = 0` and uses NB_QueueWaitNoMergeMinutes threshold
- **What it catches:** RELEASED batches with auto-merge disabled that have been waiting longer than the extended threshold
- **Trigger type:** `NB_QueueWaitNoMerge`
- **Trigger value:** `{batchId}_{today's date}` (daily re-alert)
- **Routing config:** NB_Alert_QueueWaitNoMerge (default: 1 = Teams only)

### CHECK 6: Unreleased Batch
- **Query:** `is_complete = 0 AND batch_status_code IN (4, 6) AND is_auto_release = 0 AND DATEDIFF(MINUTE, batch_created_dttm, GETDATE()) >= {threshold}`
- **What it catches:** Batches in UPLOADED (4) or RELEASENEEDED (6) with auto-release disabled, waiting too long for manual release
- **Trigger type:** `NB_Unreleased`
- **Trigger value:** `{batchId}_{today's date}` (daily re-alert)
- **Routing config:** NB_Alert_Unreleased (default: 1 = Teams only)

### CHECK 7: Release-Merge Skip Stall
- **Query:** `is_complete = 0 AND batch_status_code = 7 AND merge_status_code >= 2 AND stall_poll_count >= {threshold} AND alert_count = 0`
- **What it catches:** Batches in the anomalous state of RELEASING (7) with active merge status but no log activity. This is a DM quirk where the batch status skipped past RELEASED.
- **Trigger type:** `NB_ReleaseMergeSkip`
- **Trigger value:** `{batchId}`
- **Alert behavior:** One alert per batch (alert_count check). Resets if activity resumes.
- **Routing config:** NB_Alert_ReleaseMergeSkip (default: 3 = Both)

---

## Phase 4: Update Status and Callback

1. Updates `BatchOps.Status` row for `Collect-NBBatchStatus`:
   - Sets `processing_status = 'IDLE'`
   - Records `completed_dttm`, `last_duration_ms`, `last_status` (SUCCESS or FAILED)
2. If launched by orchestrator (TaskId > 0), calls `Complete-OrchestratorTask` with summary output

---

## Key Observations for Team Discussion

### Statuses NOT treated as terminal by the collector:

| Status Code | Status Name | What happens in the collector |
|-------------|-------------|-------------------------------|
| 3 | UPLOADFAILED | Inserted as is_complete = 0. Never marked terminal by update step. Alert fires via CHECK 1. Batch stays incomplete until deleted in DM (becomes status 5). |
| 9 | RELEASEFAILED | Inserted as is_complete = 0. Never marked terminal by update step. Alert fires via CHECK 2. Batch stays incomplete until resolved in DM. |

### The two status fields:

- **batch_status** / **batch_status_code**: Updated every poll cycle from DM. Always reflects current DM state.
- **completed_status**: Only set when is_complete flips to 1. Records HOW the batch completed. Once set, it is protected by COALESCE (won't be overwritten).

### Lookback scope:

- **New batch discovery:** Limited to NB_LookbackDays (default 7). Batches older than this window will never be discovered.
- **Incomplete batch updates:** No date limit. All is_complete = 0 rows are polled every cycle regardless of age.
- **Alert evaluation:** No date limit. All alert checks query is_complete = 0 rows with no date filter.

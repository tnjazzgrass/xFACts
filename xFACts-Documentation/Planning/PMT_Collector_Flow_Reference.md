# Collect-PMTBatchStatus.ps1 — Step-by-Step Flow Reference

> **Source:** Collect-PMTBatchStatus.ps1 v1.2.0 — all information derived directly from script code.
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
- Tracks which settings came from GlobalConfig vs. script defaults (config source diagnostics)

**Key defaults (used if GlobalConfig entry is missing):**

| Setting | Default | Purpose |
|---------|---------|---------|
| AGName | DMPRODAG | Availability Group name for replica detection |
| SourceReplica | SECONDARY | Which AG replica to read DM data from |
| PMT_LookbackDays | 7 | How far back to look for new batches in DM |
| PMT_AlertingEnabled | false | Master switch for all alerting |
| PMT_Alert_ImportFailed | 3 (Both) | Routing for IMPORTFAILED alerts |
| PMT_Alert_Failed | 3 (Both) | Routing for FAILED alerts |
| PMT_Alert_Partial | 3 (Both) | Routing for PARTIAL alerts |
| PMT_Alert_ReversalFailed | 3 (Both) | Routing for REVERSALFAILED alerts |

**Notable difference from NB collector:** PMT has config source tracking (logs whether each setting came from GlobalConfig or fell back to default). NB does not have this.

**After config load:**
- Detects AG PRIMARY and SECONDARY server names
- Sets ReadServer based on SourceReplica config (or ForceSourceServer parameter)
- Sets WriteServer to the AG listener (always)
- Marks BatchOps.Status as RUNNING

**Notable difference from NB collector:** PMT does NOT resolve polling interval from ProcessRegistry. No stall duration text formatting.

---

## Step 1: Collect New Batches

**Purpose:** Discover PMT batches in DM that xFACts doesn't know about yet.

**How it works:**

1. Queries `BatchOps.PMT_BatchTracking` for ALL existing `batch_id` values (no filter)
2. Queries DM `cnsmr_pymnt_btch` for batches created within the last `PMT_LookbackDays` days
   - Joins to `Ref_pymnt_btch_stts_cd` for status text
   - Joins to `Ref_pymnt_btch_typ_cd` for batch type text
3. Filters in memory: keeps only batches whose `batch_id` is NOT already in the tracking table
4. For each new batch, determines terminal state at insert time:

**Insert-path terminal detection:**

| Condition | is_complete | completed_status | completed_dttm |
|-----------|-------------|------------------|----------------|
| batch_status_code IN (4, 6, 27) | 1 | 'POSTED', 'FAILED', or 'REVERSALFAILED' | DM processed_dttm (for POSTED) or upsrt_dttm |
| Anything else | 0 | NULL | NULL |

**What this means:**
- A batch discovered in POSTED (4) is inserted as `is_complete = 1` with completed_status = 'POSTED'
- A batch discovered in FAILED (6) is inserted as `is_complete = 1` with completed_status = 'FAILED'
- A batch discovered in REVERSALFAILED (27) is inserted as `is_complete = 1` with completed_status = 'REVERSALFAILED'
- A batch discovered in IMPORTFAILED (11) is inserted as `is_complete = 0` — **status 11 is NOT in the insert-path array despite the code comment saying it should be**. The `elseif` block for status 11 on line 492 is unreachable because 11 is not in `@(4, 6, 27)`.
- A batch discovered in PARTIAL (5) is inserted as `is_complete = 0` (intentional — PARTIAL is not terminal)
- A batch discovered in ACTIVE (1) is inserted as `is_complete = 0`
- All other statuses insert as `is_complete = 0`

**Fields populated on insert:**
- batch_id, batch_name, external_name, file_registry_id
- batch_type_code, batch_type (text), is_auto_post
- original_batch_id, created_by_userid, assigned_userid
- batch_status_code, batch_status (text)
- batch_created_dttm, released_dttm, processed_dttm, reversal_dttm
- payment_count, imported_count, active_count, posted_count, suspense_count
- payment_total_amt, active_total_amt, posted_total_amt, suspense_total_amt
- is_complete, completed_dttm, completed_status
- stall_poll_count = 0, alert_count = 0

---

## Step 2: Update Incomplete Batches

**Purpose:** Poll DM for current state of every batch where `is_complete = 0`.

**How it works:**

1. Queries `BatchOps.PMT_BatchTracking WHERE is_complete = 0` — **no lookback filter, no date filter**
   - Also loads: batch_type_code, journal_posted_count, completed_status, alert_count
2. For each incomplete batch:

### 2a. Hard Delete Detection

Queries DM for current batch state. If the query returns **no rows** (batch no longer exists in DM), the batch is marked:
- `is_complete = 1`
- `completed_status = 'DELETED'`
- `completed_dttm = GETDATE()`

**This is unique to the PMT collector.** NB does not have hard delete detection. PMT batches can be physically removed from DM, while NB batches get a DELETED status code (soft delete).

### 2b. Log Activity Query

Queries DM `cnsmr_pymnt_btch_log` for:
- `MAX(cnsmr_pymnt_btch_log_id)` as max_log_id
- `MAX(cnsmr_pymnt_btch_log_dttm)` as max_log_dttm

### 2c. Journal Query (conditional)

Only runs when `batch_status_code IN (3, 4, 5, 6, 27)` — INPROCESS, POSTED, PARTIAL, FAILED, REVERSALFAILED.

Queries DM `cnsmr_pymnt_jrnl` for:
- Count of journal entries with `cnsmr_pymnt_stts_cd = 5` (posted)
- Count of journal entries with `cnsmr_pymnt_stts_cd = 4` (failed)
- Max upsrt_dttm for posted entries (last_posted_dttm)

### 2d. Stall Detection (IMPORT batches only)

Stall tracking ONLY applies when `batch_type_code = 3` (IMPORT). Manual and other batch types have `stall_poll_count` held at 0.

For IMPORT batches:

| Scenario | stall_poll_count |
|----------|-----------------|
| **Status is INPROCESS (3):** journal_posted_count same as last poll | Increments by 1 |
| **Status is INPROCESS (3):** journal_posted_count changed | Resets to 0 |
| **Status is NOT INPROCESS:** no log entries yet (last_log_id NULL) | Unchanged |
| **Status is NOT INPROCESS:** log ID same as last poll | Increments by 1 |
| **Status is NOT INPROCESS:** new log ID detected | Resets to 0 |

**Key difference from NB:** PMT uses journal_posted_count delta for INPROCESS stall detection (not log ID), because the journal table shows real posting progress. Log ID is used for non-INPROCESS phases.

### 2e. Terminal State Detection

| Condition | is_complete | completed_status | completed_dttm |
|-----------|-------------|------------------|----------------|
| batch_status_code = 4 (POSTED) | 1 | 'POSTED' | DM processed_dttm or GETDATE() |
| batch_status_code = 6 (FAILED) | 1 | 'FAILED' | GETDATE() |
| batch_status_code = 11 (IMPORTFAILED) | 1 | 'IMPORTFAILED' | GETDATE() |
| batch_status_code = 27 (REVERSALFAILED) | 1 | 'REVERSALFAILED' | GETDATE() |
| Anything else | 0 | (not changed) | (not changed) |

**PARTIAL (5) is NOT terminal.** This is intentional — PARTIAL batches can be re-fired back to INPROCESS.

### 2f. PARTIAL Recovery Detection

If the tracking row's `completed_status` is 'PARTIAL' but the current DM status is NOT PARTIAL (status 5):
- `completed_status` is reset to NULL
- `completed_dttm` is reset to NULL
- `alert_count` is reset to 0

This handles the case where a PARTIAL batch was re-fired and is now back in INPROCESS or another active state. Resetting alert_count enables fresh alerts if it fails again.

**Note on how PARTIAL gets into completed_status:** This happens through the alert evaluation step (CHECK 3), which sets `completed_status = 'PARTIAL'` when it fires a PARTIAL alert. It does NOT happen through the terminal detection in Step 2e (PARTIAL is excluded). See Step 3, CHECK 3 notes.

*Actually — let me re-check this.* Looking at the update query (lines 830-857), `completed_status` is set using direct assignment: `completed_status = $(if ($completedStatus -eq 'NULL') { 'NULL' } else { $completedStatus })`. The PARTIAL recovery check (line 812) sets `$completedStatus = "NULL"` when the batch transitions out of PARTIAL. But when the batch IS in PARTIAL status, the terminal detection at line 787 doesn't match (5 is not in the array), so `$completedStatus` stays "NULL". The completed_status value of 'PARTIAL' must be coming from somewhere else — likely the alert step setting it, or from a previous update cycle.

*Correction:* Looking more carefully at the update query, when `$completedStatus` is "NULL", the SQL writes literal `NULL`. So on a normal PARTIAL poll cycle: terminal detection doesn't fire (status 5 not in array), `$completedStatus` stays "NULL", and the UPDATE sets `completed_status = NULL`. This means completed_status for a PARTIAL batch would be NULL unless something else sets it. The recovery detection (line 812) checks `$currentCompletedStatus -eq 'PARTIAL'` — this value was loaded from the tracking table at the start of the loop. So something must set completed_status = 'PARTIAL' in the tracking table. This is likely done by the alert evaluation step or a previous version of the script. This needs team clarification.

### 2g. Update Query Writes

- batch_status_code, batch_status
- released_dttm, processed_dttm, reversal_dttm
- payment_count, imported_count, active_count, posted_count, suspense_count
- payment_total_amt, active_total_amt, posted_total_amt, suspense_total_amt
- last_log_id, last_log_dttm
- journal_posted_count, journal_failed_count, last_posted_dttm
- stall_poll_count
- is_complete, completed_dttm, completed_status (direct assignment, not COALESCE)
- alert_count (reset to 0 on PARTIAL recovery, otherwise unchanged)
- last_polled_dttm = GETDATE()

**Key difference from NB:** PMT uses direct assignment for completed_dttm and completed_status (not COALESCE). This means these fields can be overwritten — including being set back to NULL during PARTIAL recovery. NB uses COALESCE, which means once set they're never overwritten.

---

## Step 3: Evaluate Alert Conditions

**Master switch:** `PMT_AlertingEnabled` must be true (1) for any alerts to fire. Detection is always logged regardless.

Each check queries `BatchOps.PMT_BatchTracking`. Each has its own routing config (0=None, 1=Teams, 2=Jira, 3=Both). All use RequestLog dedup to prevent duplicates.

After firing an alert, the script increments `alert_count` on the tracking row.

**Important difference from NB:** The PMT alert queries do NOT filter on `is_complete`. They only filter on `batch_status_code` and `alert_count = 0`. This means:
- CHECK 1 could match a batch that was already marked `is_complete = 1` by the update step (for FAILED, REVERSALFAILED — these are terminal in both steps)
- CHECK 1 (IMPORTFAILED): Since IMPORTFAILED IS terminal in the update step, by the time the alert evaluates, the batch is already `is_complete = 1`. The alert still fires because there's no `is_complete = 0` filter.

### CHECK 1: Import Failed
- **Query:** `batch_status_code = 11 AND alert_count = 0`
- **What it catches:** IMPORTFAILED batches that haven't been alerted yet
- **Trigger type:** `PMT_ImportFailed`
- **Trigger value:** `{batchId}`
- **Error extraction:** Placeholder only — "Check Debt Manager batch log for error details." (pending confirmation that cnsmr_pymnt_btch_log contains useful errors)
- **Routing config:** PMT_Alert_ImportFailed (default: 3 = Both)

### CHECK 2: Failed
- **Query:** `batch_status_code = 6 AND alert_count = 0`
- **What it catches:** FAILED batches that haven't been alerted yet
- **Trigger type:** `PMT_Failed`
- **Trigger value:** `{batchId}`
- **Includes in alert:** batch type, external name, payment count, active/posted/journal counts
- **Routing config:** PMT_Alert_Failed (default: 3 = Both)

### CHECK 3: Partial
- **Query:** `batch_status_code = 5 AND alert_count = 0`
- **What it catches:** PARTIAL batches that haven't been alerted yet
- **Trigger type:** `PMT_Partial`
- **Trigger value:** `{batchId}`
- **Includes in alert:** suspense count in addition to active/posted/journal counts
- **Routing config:** PMT_Alert_Partial (default: 3 = Both)
- **Note:** PARTIAL is not terminal, so this batch stays is_complete = 0 and continues to be polled. If the batch is re-fired to INPROCESS and then reaches PARTIAL again, the recovery detection in Step 2f resets alert_count to 0, enabling a fresh alert.

### CHECK 4: Reversal Failed
- **Query:** `batch_status_code = 27 AND alert_count = 0`
- **What it catches:** REVERSALFAILED batches that haven't been alerted yet
- **Trigger type:** `PMT_ReversalFailed`
- **Trigger value:** `{batchId}`
- **Includes in alert:** original_batch_id for the batch being reversed
- **Routing config:** PMT_Alert_ReversalFailed (default: 3 = Both)

---

## Phase 4: Update Status and Callback

1. Updates `BatchOps.Status` row for `Collect-PMTBatchStatus`:
   - Sets `processing_status = 'IDLE'`
   - Records `completed_dttm`, `last_duration_ms`, `last_status` (SUCCESS or FAILED)
2. If launched by orchestrator (TaskId > 0), calls `Complete-OrchestratorTask` with summary including config source counts

---

## Key Observations for Team Discussion

### The IMPORTFAILED insert-path bug:

Line 476: `if ($batchStatusCd -in @(4, 6, 27))` — status 11 is missing from this array. The comment on line 470 says "Terminal: POSTED (4), FAILED (6), IMPORTFAILED (11), REVERSALFAILED (27)" but the code only checks for 4, 6, 27. The `elseif` handler for status 11 on line 492 exists but is unreachable.

**Impact:** A batch discovered already in IMPORTFAILED state gets inserted as `is_complete = 0`. On the next update cycle (Step 2e), it gets correctly marked terminal. One-cycle delay. Operationally zero impact since no IMPORTFAILED batches have been observed historically.

### PMT statuses NOT treated as terminal:

| Status Code | Status Name | What happens in the collector |
|-------------|-------------|-------------------------------|
| 1 | ACTIVE | Stays is_complete = 0. Manual batches sit in ACTIVE until manually released. |
| 5 | PARTIAL | Stays is_complete = 0. Intentional — can be re-fired. Alert fires via CHECK 3. Recovery detection resets if re-fired. |
| 30 | ACTIVEWITHSUSPENSE | Stays is_complete = 0. No alert condition exists for this status. |

### ACTIVE (status 1) — the manual batch question:

Manual payment batches are created in ACTIVE status and stay there until someone releases them. The collector discovers these within the lookback window and inserts them as `is_complete = 0`. They then get polled every cycle indefinitely. There is no alert condition for ACTIVE batches sitting too long. This is the "PMT EOD manual batch alert" backlog item.

### ACTIVEWITHSUSPENSE (status 30):

Batches in this status are stuck — they need business resolution. The collector tracks them as `is_complete = 0` but there is no alert for this condition. These are the 12 stuck batches mentioned in the backlog. They will be polled every cycle indefinitely until resolved in DM.

### Hard delete detection (unique to PMT):

If a batch disappears from DM entirely (query returns no rows), the collector marks it `completed_status = 'DELETED'`. NB does not have this because NB batches get soft-deleted (status 5) rather than physically removed.

### No stall-based or time-based alerting yet:

The current PMT alert conditions are all terminal failure detections (status code checks). There are no stall threshold checks, no time-in-status checks, and no stuck-batch alerts. This is the "PMT Phase 3b-2" backlog item, which is gated on the DM concurrency cap investigation.

### Lookback scope (same pattern as NB):

- **New batch discovery:** Limited to PMT_LookbackDays (default 7). Batches older than this will never be discovered.
- **Incomplete batch updates:** No date limit. All is_complete = 0 rows are polled every cycle.
- **Alert evaluation:** No date limit. All alert checks query by status code and alert_count only.

### PARTIAL completed_status question:

The PARTIAL recovery detection (Step 2f) checks whether `completed_status = 'PARTIAL'` in the tracking table. However, the normal update path never sets `completed_status = 'PARTIAL'` because PARTIAL (5) is excluded from terminal detection. The alert evaluation step also doesn't write completed_status. This needs team investigation to confirm how 'PARTIAL' gets into completed_status — it may be from an earlier version of the script or a manual data correction.

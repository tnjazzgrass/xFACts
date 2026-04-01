# xFACts Alert Trigger Type Inventory

Comprehensive catalog of all trigger types used across the platform, sourced from script analysis. This inventory supports the planned `dbo.AlertRegistry` table and Teams webhook routing expansion.

---

## Current Trigger Types

### BatchOps — Collect-NBBatchStatus.ps1

| Trigger Type | Trigger Value Pattern | Re-alert | Alert Category | Teams Color | Channels |
|---|---|---|---|---|---|
| NB_UploadFailed | {batch_id} | One-time | CRITICAL | attention | Teams + Jira |
| NB_ReleaseFailed | {batch_id} | One-time | CRITICAL | attention | Teams + Jira |
| NB_StalledMerge | {batch_id}_{last_log_id} | Per-episode | CRITICAL | attention | Teams + Jira |
| NB_UploadStall | {batch_id}_{date} | Daily | WARNING | warning | Teams only |
| NB_QueueWait | {batch_id}_{date} | Daily | WARNING | warning | Teams only |
| NB_QueueWaitNoMerge | {batch_id}_{date} | Daily | INFO | accent | Teams only |
| NB_Unreleased | {batch_id}_{date} | Daily | WARNING | warning | Teams only |
| NB_ReleaseMergeSkip | {batch_id} | One-time | CRITICAL | attention | Teams + Jira |

### BatchOps — Send-OpenBatchSummary.ps1

| Trigger Type | Trigger Value Pattern | Re-alert | Alert Category | Teams Color | Channels |
|---|---|---|---|---|---|
| OpenBatchSummary | {date} | Daily | varies (good/warning) | varies | Teams only |

### JobFlow — Monitor-JobFlow.ps1

| Trigger Type | Trigger Value Pattern | Re-alert | Alert Category | Teams Color | Channels |
|---|---|---|---|---|---|
| JobFlow_Stall | {date} | Daily | CRITICAL | attention | Teams + Jira |
| JobFlow_MissingFlow | {flow_code}_{date} | Daily | WARNING | warning | Teams only |
| JobFlow_Validation | {flow_code}_{date} | Daily | — | — | Jira only (no Teams) |

Note: `JobFlow_Validation` and `JobFlow_MissingFlow` fire for the same condition (missing scheduled flow). Teams uses `JobFlow_MissingFlow`, Jira uses `JobFlow_Validation`. Consider aligning these to a single trigger type in a future cleanup.

### BIDATA — Monitor-BIDATABuild.ps1

| Trigger Type | Trigger Value Pattern | Re-alert | Alert Category | Teams Color | Channels |
|---|---|---|---|---|---|
| BuildStatus | NOT_STARTED-{date} | Per-event | WARNING/CRITICAL | warning/attention | Teams only |
| BuildStatus | {status}-{instance_id} | Per-event | varies | varies | Teams only |

Note: `BuildStatus` is a single trigger type used for multiple conditions (not started, failed, success). The trigger value differentiates the condition. If routing needs to split these (e.g., only send failures to a specific channel), the trigger type would need to be split into `BuildStatus_NotStarted`, `BuildStatus_Failed`, etc.

### ServerOps — Collect-ServerHealth.ps1

| Trigger Type | Trigger Value Pattern | Re-alert | Alert Category | Teams Color | Channels |
|---|---|---|---|---|---|
| ServerOps_DiskSpace | {server}_{drive} | Per-event | — | — | Jira only (no Teams) |

Note: Disk space alerts go to Jira only. The daily disk summary (`DiskHealthSummary`) handles the Teams notification separately.

### ServerOps — Send-DiskHealthSummary.ps1

| Trigger Type | Trigger Value Pattern | Re-alert | Alert Category | Teams Color | Channels |
|---|---|---|---|---|---|
| DiskHealthSummary | {date} | Daily | varies (good/warning) | varies | Teams only |

### Orchestrator — Start-xFACtsOrchestrator.ps1

| Trigger Type | Trigger Value Pattern | Re-alert | Alert Category | Teams Color | Channels |
|---|---|---|---|---|---|
| Orchestrator_Timeout | {process_name} | Per-event | CRITICAL | attention | Teams only |

### ControlCenter — ServerHealth-API.ps1

| Trigger Type | Trigger Value Pattern | Re-alert | Alert Category | Teams Color | Channels |
|---|---|---|---|---|---|
| ZombieKill | {server_name} | Per-event | INFO | good | Teams only (direct send, audit row) |

Note: This is a manual action triggered from the Control Center UI, not an automated alert. The AlertQueue insert is an audit trail with status pre-set to 'Sent'.

### FileOps — Scan-SFTPFiles.ps1

| Trigger Type | Trigger Value Pattern | Re-alert | Alert Category | Teams Color | Channels |
|---|---|---|---|---|---|
| *(none — NULL)* | *(none — NULL)* | Per-event | INFO or WARNING | — | Teams only |

**Gap:** FileOps does not pass `@TriggerType` or `@TriggerValue` to `sp_QueueAlert`. All FileOps alerts have NULL trigger_type/trigger_value in AlertQueue. This means:
- FileOps alerts **cannot** be routed to specific channels via WebhookSubscription
- FileOps alerts have **no deduplication** on the Teams side
- Suggested trigger types to add:
  - `FileOps_Detected` — value: `{config_name}_{date}`
  - `FileOps_LateDetected` — value: `{config_name}_{date}`
  - `FileOps_Escalated` — value: `{config_name}_{date}`

---

## Summary Statistics

| Module | Trigger Types | Teams | Jira | Both |
|---|---|---|---|---|
| BatchOps | 9 | 6 | 0 | 3 (via routing config) |
| JobFlow | 3 | 2 | 1 | 1 (stall fires both) |
| BIDATA | 1 | 1 | 0 | 0 |
| ServerOps | 2 | 1 | 1 | 0 |
| Orchestrator | 1 | 1 | 0 | 0 |
| ControlCenter | 1 | 1 | 0 | 0 |
| FileOps | 0 (gap) | — | — | — |
| **Total** | **17** | **12** | **2** | **4** |

---

## Observations

1. **FileOps needs trigger types** — currently unroutable and undeduplicable on the Teams side.

2. **BIDATA uses a single trigger type for multiple conditions** — `BuildStatus` covers not-started, failed, and success. If channel routing needs to differentiate these, the trigger type needs to be split.

3. **JobFlow has mismatched trigger types** — `JobFlow_MissingFlow` (Teams) vs `JobFlow_Validation` (Jira) for the same condition. Consider aligning.

4. **ServerOps_DiskSpace is Jira-only** — no corresponding Teams alert trigger. Disk Teams notifications go through the summary card (`DiskHealthSummary`) instead.

5. **ZombieKill is a manual action audit** — not a traditional automated alert. Consider whether it belongs in AlertRegistry or is out of scope.

6. **Re-alert patterns vary** — one-time, daily, per-episode, and per-event patterns are all in use. The AlertRegistry table should document which pattern each trigger uses.

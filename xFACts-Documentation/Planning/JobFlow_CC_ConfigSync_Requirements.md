# JobFlow Control Center - ConfigSync Enhancement Requirements

## Context

ConfigSync functionality has been integrated into Monitor-JobFlow.ps1 (v1.1.0) as Step 0, replacing the standalone sp_ConfigSync stored procedure. The monitor now detects new, deactivated, and reactivated flows every cycle and inserts stub rows into FlowConfig with `expected_schedule = 'UNCONFIGURED'` for new flows.

The Control Center JobFlow Monitoring page needs enhancements to surface this information and provide a configuration workflow.

## What Changed

- **Monitor-JobFlow.ps1 v1.1.0** runs ConfigSync every 5-minute cycle
- New DM flows get stub rows in FlowConfig: `is_monitored = 0`, `expected_schedule = 'UNCONFIGURED'`, alerts off
- Jira tickets are still queued for new/deactivated flows (Trigger_Type: JobFlow_NewFlow, JobFlow_Deactivated)
- `dm_is_active` and `dm_last_sync_dttm` updated every cycle for all known flows
- GlobalConfig `SourceReplica` promoted from JobFlow to Core module

## Control Center Enhancements Needed

### 1. Unconfigured Flow Indicator

Badge or indicator on the JobFlow Monitoring page showing how many flows need configuration.

**Data source:**
```sql
SELECT COUNT(*) 
FROM JobFlow.FlowConfig 
WHERE expected_schedule = 'UNCONFIGURED'
```

**Behavior:**
- Visible only when count > 0
- Prominent enough to notice without being intrusive
- Could be a badge on a header button, a banner, or integrated into existing layout

### 2. Flow Configuration Management

Ability to view and configure unconfigured flows (and potentially manage all FlowConfig entries).

**Minimum scope:**
- List unconfigured flows with flow code, flow name, DM flow ID, detection date
- Configuration action: set expected_schedule, enable monitoring
- When configured: set real schedule value, flip `is_monitored = 1`

**Fields to set during configuration:**
- `expected_schedule` (dropdown: DAILY, WEEKLY, MONTHLY, EVERY_N_HOURS, VARIABLE, ON-DEMAND)
- `is_monitored` (toggle, defaults to 1 when configuring)
- `alert_on_missing` (toggle)
- `alert_on_critical_failure` (toggle)
- `expected_start_time` (optional)
- `start_time_tolerance_minutes` (optional)
- `expected_max_duration_hours` (optional)

**Visual distinction:**
- Unconfigured flows should be visually distinct in any lists or dropdowns
- Consider whether this is a modal, slideout, or dedicated section

### 3. ConfigSync Status Visibility (optional/nice-to-have)

Surface the sync results somewhere so there's visibility that ConfigSync is running.

**Possible approaches:**
- Last sync timestamp in page footer or header
- Sync status in an existing status area
- Only needed if there's a natural place for it — not worth adding UI clutter

## Existing Page Structure

The JobFlow Monitoring page has a three-column layout:
- **Left:** Daily Summary (flow cards)
- **Center:** Live Activity (executing jobs, pending queue)
- **Right:** Execution History (year/month tree)
- **Header:** Refresh button, Pending Queue button, App Server Tasks button

The unconfigured flow indicator could fit in the header bar alongside existing buttons. The configuration interface could be a modal (similar to App Server Tasks) or a slideout.

## FlowConfig Table Reference

Key fields for the configuration workflow:

| Field | Type | Notes |
|---|---|---|
| config_id | INT | PK, identity |
| job_sqnc_id | INT | DM flow ID |
| job_sqnc_shrt_nm | VARCHAR(20) | Flow code |
| job_sqnc_nm | VARCHAR(100) | Flow name |
| dm_is_active | BIT | Synced from DM |
| dm_last_sync_dttm | DATETIME | Last sync timestamp |
| is_monitored | BIT | Enable monitoring |
| expected_schedule | VARCHAR(50) | DAILY, WEEKLY, etc. or UNCONFIGURED |
| alert_on_missing | BIT | Alert if flow doesn't start |
| alert_on_critical_failure | BIT | Alert on critical failure |
| expected_start_time | TIME | Expected start |
| start_time_tolerance_minutes | INT | Tolerance window |
| expected_max_duration_hours | DECIMAL(5,2) | Max expected duration |
| created_by | VARCHAR(100) | Audit |
| modified_by | VARCHAR(100) | Audit |

## CHECK Constraint Values for expected_schedule

DAILY, WEEKLY, MONTHLY, EVERY_N_HOURS, VARIABLE, ON-DEMAND, UNCONFIGURED

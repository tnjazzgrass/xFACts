# xFACts Backlog Items
## Updated: March 15, 2026

Open build, enhancement, and bug fix items across the xFACts platform. Organized by module and component. Components with no open items are omitted.

**Type labels:** Build = net-new feature or module. Enhance = improvement to existing functionality. Bug = defect fix.

---

## Engine

### Orchestrator

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Bug | Stale FIRE_AND_FORGET task detection | High | Two-part fix needed: (1) **Startup orphan cleanup** — on engine start, auto-fail any tasks in LAUNCHED/RUNNING status (guaranteed orphans from prior crash/restart). (2) **Heartbeat timeout detection** — each orchestrator cycle, check for LAUNCHED tasks exceeding ProcessRegistry timeout_seconds, auto-fail with alert. timeout_seconds must account for worst-case catch-up scenarios (XE Events observed at 22 minutes after 8-hour backlog). Need per-process timeout values in ProcessRegistry. Occurred again 2026-03-10: both Collect-XEEvents and Collect-ReplicationHealth hung simultaneously at 20:44, blocked for 8 hours until manual cleanup. |
| Build | Python script execution support | Medium | Teach orchestrator launch function to detect file extension and invoke python.exe for .py files. ProcessRegistry script_path would accept .py filenames alongside .ps1. Enables language-agnostic process scheduling. First use case: BI file cleanup script. |
| Enhance | Parallel execution within dependency groups | Low | Currently all processes within a dependency group execute sequentially. Enable parallel execution for processes in the same group that have no interdependencies. Not currently causing concerns — sequential execution completes well within cycle time. |

### Shared Infrastructure

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Enhance | Platform-wide data retention policy | Medium | No retention is currently in place for any module. Design and implement a retention strategy covering all historical data tables: Activity DMV/XE snapshots, backup/disk/replication history, API_RequestLog, Teams/Jira RequestLog, Orchestrator TaskLog/CycleLog, index execution history, batch tracking history. Define per-table retention periods based on operational value. Implement via orchestrator-scheduled cleanup process. |
| Enhance | Config source tracking for GlobalConfig-referencing scripts | Low | Enhance Initialize-Configuration in all scripts to log whether each setting was loaded from GlobalConfig or fell back to script default. PMT collector is the reference implementation. Enables quick diagnosis when alerts fire unexpectedly due to config connection issues. |
| Enhance | Extended property cleanup | Low | Remove legacy MS_Description extended properties from all objects. Object_Metadata is the sole documentation source. Properties are inert — cleanup is cosmetic but removes confusion about which system is authoritative. |
| Enhance | Index_ table constraint and index rename | Low | Four ServerOps tables renamed to Index_ prefix but constraints/indexes still carry old names. Rename to match convention. Cosmetic only. |

---

## ServerOps

### ServerHealth

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Build | Performance Analysis Page | High | New page for forensic time-range analysis. Correlates waits, LRQs, HADR metrics, blocking, scheduled jobs. Answers "what happened at 8:15 AM?" Time-range selector with overlaid metrics from DMV and XE data. |
| Build | Incident History Page | Future | Timeline view of correlated incidents from Activity_IncidentLog and XE tables. Plain-English explanations. Builds on sp_Activity_CorrelateIncidents. Phase 2 — needs planning session for correlation rules. |
| Enhance | sp_DiagnoseServerHealth Evolution | High | Enhance to analyze time windows and output ranked probable causes. Correlate HADR_SYNC waits + secondary PLE drops + scheduled job windows. Automated diagnosis with plain-English conclusions. |
| Enhance | Current Activity Rethink | Medium | Consolidate Lead Blocker and Longest Wait into Blocked Sessions card as subtitle lines (only meaningful during active blocking). Free up two card slots for live wait stats display. Goal: Eliminate SSMS Activity Monitor dependency for wait-type diagnosis. |
| Enhance | Incident correlation expansion | Medium | Extend sp_Activity_CorrelateIncidents to detect multi-source patterns (e.g., PLE crash + blocking + AG sync delay within same time window). Currently single-source only. |
| Enhance | Diagnostic Report Button | Low | Find appropriate home for sp_DiagnoseServerHealth button (removed from Server Health page). |
| Enhance | Card value font refactor | Low | Split .metric-value class into separate classes for gauges vs. card display numbers to enable independent font sizing. |
| Enhance | Incident Analyzer Enhancement | Future | Smarter correlation: time-window clustering, cross-source correlation, plain-English narrative generation. Major enhancement to diagnostic capabilities. |

### Index

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Enhance | Exception Schedule Input | Low | Create an input form/method for creating an Exception Schedule entry. Links to sp_AddExceptionSchedule. Can leverage stored procedure or direct insert. |
| Enhance | sp_AddExceptionSchedule | Low | Create stored procedure for adding exception schedule entries with validation. |
| Enhance | Smart scheduling | Low | Evaluate scheduling index maintenance runs through Orchestrator ProcessRegistry instead of manual launch. |

### Replication

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Enhance | Replication registry source server column | Low | Add source_server column to Replication_PublicationRegistry. Populate from sys.servers via publisher_id in the collector. Replace agent_name parsing in the CC card rendering with the stored value. Currently using string parsing of agent_name as a workaround. |

### DBCC

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Enhance | Disk space alert suppression during CHECKDB | Medium | CHECKDB internal snapshot temporarily consumes significant space on data drives during FULL runs. ServerHealth disk monitoring generates Jira tickets for IT Ops on low disk space. Need cross-component awareness to suppress or annotate disk alerts when CHECKDB is actively running on that server. Could check DBCC_ExecutionLog for IN_PROGRESS status on the same server before firing disk threshold alerts. |
---

## JobFlow

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Enhance | Process Status Consolidation | Medium | Process Status cards take up significant space showing mostly 0 values. Evaluate combining flow transition cards into a single consolidated display to free space for execution history expansion. |
| Enhance | Execution State Accuracy for Pending Jobs | Medium | Flows with pending jobs can show as COMPLETE when all detected jobs have finished but pending jobs haven't started. Cross-reference pending queue to maintain EXECUTING state. |
| Enhance | Validation threshold review | Low | Revisit min_failure_threshold for critical jobs. Proposed: critical jobs bypass threshold, alert on any failure. |
| Enhance | Review JobFlow.Status.last_error_message for removal | Low | Transient field not useful when TaskLog has full error history. Evaluate if anything reads this field. |
| Enhance | ConfigSync Management | Low | Evaluate sp_AnalyzeHistory and sp_PopulateConfig for potential ConfigSync management panel. Unconfigured flow indicator, configuration modal with schedule/alert settings. |
| Enhance | Centralized Scheduler API | Low | Replace Windows Task Scheduler dependency with xFACts-managed scheduling for flow execution. |
| Enhance | Cancelling Status Alert | Low | stts_cd 5 (CANCELLING) stuck job detection/alerting after a certain time period in status

---

## BatchOps

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Enhance | Shared Send-TeamsAlert | Migrate NB, PMT and BDL scripts to use shared Send-TeamsAlert in xFACts-OrchestratorFunctions. Currently they are direct inserting? |
| Build | Send-OpenBatchSummary BDL/Notice sections | Medium | Implement remaining check functions (Get-OpenBDLImports, Get-ActiveNoticeProcessing). Requires Phase 0 investigation. |
| Enhance | DM concurrency cap investigation | High | Investigate all DM processing thread caps via env_prfl_cnfg_ovrrd and config_item tables. Findings impact stall detection logic for both PMT and NB collectors. |
| Enhance | PMT Phase 3b-2: Stall and time-based alerting | Medium | INPROCESS stall detection, stuck ACTIVE, stuck DELETING, ACTIVEWITHSUSPENSE. Requires DM concurrency cap investigation. |
| Enhance | PMT EOD manual batch alert | Medium | Daily alert for manual payment batches still in ACTIVE status at end of business day. Requires accounting team input on cutoff time. |
| Enhance | PMT error extraction for IMPORTFAILED | Medium | Confirm whether cnsmr_pymnt_btch_log contains actionable error messages for import failures. Currently using placeholder text in Jira tickets. |
| Enhance | PMT ACTIVEWITHSUSPENSE batch resolution | Medium | 12 stuck batches from 2023-2026 requiring business resolution. Review with Matt. |
| Enhance | Alert lookback period evaluation | Medium | Evaluate applying lookback period to alert evaluation so old batches are excluded from checks. Confirm with Matt whether any lifecycle could exceed the lookback window. |
| Enhance | PMT insert-path IMPORTFAILED terminal detection | Low | One-cycle delay before terminal detection. No operational impact — zero IMPORTFAILED batches exist historically. |
| Enhance | Investigate 270 historical incomplete NB batches | Low | Batches marked INVESTIGATE during initial deployment. Review and resolve with appropriate completed_status. 2025 batches are highest priority. |

---

## FileOps

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Enhance | Alert architecture alignment | High | Migrate from sp_QueueAlert to shared Send-TeamsAlert. Move detection/escalation decision from MonitorConfig booleans to WebhookSubscription filters. Populate alert_category on subscriptions. Dependent on Teams Workflow migration completing first. |

---

## DeptOps

### BusinessIntelligence

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Build | BI file storage cleanup integration | Medium | Integrate BI Manager's Python cleanup script (remote file site, deletes files older than 16 months). Determine execution model (scheduled via orchestrator vs. on-demand button on BI page). Display results on Business Intelligence page. Pending script finalization and requirements gathering. |

---

## JBoss

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Enhance | App Server Health Alerting | High | Composite alert for impending application freeze using ds_in_use_count sustained elevation + undertow throughput collapse. Reference implementation in session 2026-03-17 Collect-DmHealthMetrics.ps1 (now renamed to Collect-JBossMetrics.ps1) output. Prerequisites: deeper metric analysis across all three servers, per-server alerting toggle design (ServerRegistry column + CC badge), alerting badge UI pattern applicable to multiple modules. |

---

## ControlCenter

### Admin

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Build | Health & Usage Sub-Page | Medium | Platform diagnostics dashboard. Platform Pulse, CC Performance, Operational Volume, Usage Analytics. Consolidates concepts from Admin Section Plan and Self Monitoring Plan. Data collection infrastructure already deployed. |
| Build | Alert Subscription Management Page | Medium | Self-service page for department leads to manage channel subscriptions. Apps team retains admin control over webhook creation. Dependent on RBAC. |

### Shared

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Enhance | Nav bar redesign for growing page count | Medium | Current inline nav with bullet separators will overflow as pages are added. Options: dropdown/mega-menu, two-row layout, collapsible groups. All pages must remain visible. |
| Enhance | Shared CC CSS consolidation | Low | Extract duplicated CSS patterns (nav-bar, h1, header-bar, modal/slideout, status badges, scrollbar) into cc-engine-events.css. See Development Guidelines Section 5.11 for inventory. Migrate incrementally. Consider rename if necessary. |
| Enhance | Shared CC JS extraction | Low | Evaluate common JS patterns (modal open/close, slideout animation, refresh badge updates) for extraction into cc-engine-events.js. Consider rename if necessary. |

---

## Documentation

### Pipeline

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Enhance | Remaining module enrichment | Medium | DeptOps needs full enrichment. |

---

## New Modules

Modules not yet started. No schema, no tables, no CC pages.

### Sterling

| Type | Item | Priority | Notes |
|------|------|----------|-------|
| Build | Sterling schema and foundation tables | High | Create schema, Process_Config, Alert_History, Execution_Log. Failure detection, missing process detection, volume anomaly detection. Integration team input needed. |

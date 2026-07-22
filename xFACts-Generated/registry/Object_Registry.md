# Object Registry
Source: dbo.Object_Registry
Generated: 2026-07-22 16:14:17

| module_name | component_name | object_name | object_category | object_type | object_path | zone | scope | scope_tier | description |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| B2B | B2B | INT_PipelineTracking | Database | Table | B2B |  |  |  | Comprehensive pipeline-run tracking for the B2B module. One row per Sterling pipeline run, mirrored from Integration.ETL.tbl_B2B_CLIENTS_BATCH_STATUS and enriched with snapshotted client identity and process configuration. Carries a disambiguated status classification verified against Debt Manager batch outcomes and b2bi runtime state, plus completion and alerting lifecycle columns. |
| B2B | B2B | INT_RunFiles | Database | Table | B2B |  |  |  | Per-run capture of client file names associated with B2B pipeline runs. One row per file: the Integration file listing (etl.tbl_B2B_CLIENTS_BATCH_FILES) mirrored for tracked runs, covering both pickups and deliveries. |
| B2B | B2B | INT_RunTickets | Database | Table | B2B |  |  |  | Per-run capture of Jira tickets generated for issues in B2B pipeline runs. One row per (run, or ticket reason): the Jira ticket outcomes recorded against a Sterling run, aggregated from the rows in Integration.etl.tbl_B2B_CLIENTS_TICKETS. |
| B2B | B2B | SI_FaultReport | Database | Table | B2B |  |  |  | Per-run capture of the Sterling translation status report for failed B2B pipeline runs. One row per failed run that carried an extractable report, sourced from b2bi.dbo.TRANS_DATA (the gzip-compressed status-report blob) reached via the failing step's STATUS_RPT handle in WORKFLOW_CONTEXT. Holds the full parsed report as JSON plus the raw decompressed text fallback. Captured once at collection time and retained permanently. |
| B2B | B2B | SI_ScheduleRegistry | Database | Table | B2B |  |  |  | Master catalog of IBM Sterling B2B Integrator schedules sourced from b2bi.dbo.SCHEDULE. Stores one row per SCHEDULEID with parsed TIMINGXML structure for auditing, monitoring, and Control Center display. |
| B2B | B2B | SI_WorkflowRegistry | Database | Table | B2B |  |  |  | Catalog of Sterling workflow definitions sourced from b2bi.dbo.WFD on FA-INT-DBP. One row per workflow definition carrying its current version, the immediately prior version, and version-change timing - the persistence layer for the workflow version census that detects Sterling definition changes between collector cycles. |
| B2B | B2B | Collect-B2BPipeline.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-B2BPipeline.ps1 | standalone | LOCAL |  | The B2B module collector. Synchronizes the schedule registry from b2bi, maintains the workflow definition catalog and version census in SI_WorkflowRegistry, and mirrors the Integration pipeline lifecycle tracker into INT_PipelineTracking with set-based T-SQL classification: DM outcome verification, the BATCH_FILES pickup check, dispatcher name resolution, and a Sterling runtime cross-check for aged in-flight runs. |
| B2B | B2B | B2BPipeline-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\B2BPipeline-API.ps1 | cc | LOCAL |  | Read-only API surface for the B2B Pipeline page: pulse summary, live incomplete runs, workflow census changes, filtered paged run history, and single-run detail. |
| B2B | B2B | b2b-pipeline.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\b2b-pipeline.css | cc | LOCAL |  | Page styles for the B2B Pipeline dashboard: layout grid, pulse cards, classification badges, run tables, history filter bar, and the workflow-changes list. |
| B2B | B2B | b2b-pipeline.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\b2b-pipeline.js | cc | LOCAL |  | Page module for the B2B Pipeline dashboard: section loaders and renderers, history filtering and paging, the run-detail slideout, and the collector engine-card wiring. |
| B2B | B2B | B2BPipeline.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\B2BPipeline.ps1 | cc | LOCAL |  | The /b2b-pipeline page route: daily pulse cards, live pipeline activity, recent workflow changes, and the searchable paged run-history table with a run-detail slideout. |
| BatchOps | BatchOps | BDL_BatchTracking | Database | Table | BatchOps |  |  |  | BDL import lifecycle tracking table with partition-based progress tracking, DM summary count capture, and stall detection. |
| BatchOps | BatchOps | NB_BatchTracking | Database | Table | BatchOps |  |  |  | NewBatch batch processing status tracking |
| BatchOps | BatchOps | PMT_BatchTracking | Database | Table | BatchOps |  |  |  | PMT batch processing status tracking |
| BatchOps | BatchOps | Status | Database | Table | BatchOps |  |  |  | Batch status code definitions |
| BatchOps | BatchOps | Collect-BDLBatchStatus.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-BDLBatchStatus.ps1 | standalone | LOCAL |  | Collects BDL batch processing status with partition-based progress tracking, DM summary count capture, and stall detection. |
| BatchOps | BatchOps | Collect-NBBatchStatus.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-NBBatchStatus.ps1 | standalone | LOCAL |  | Collects NewBatch processing status |
| BatchOps | BatchOps | Collect-PMTBatchStatus.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-PMTBatchStatus.ps1 | standalone | LOCAL |  | Collects PMT processing status |
| BatchOps | BatchOps | Send-OpenBatchSummary.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Send-OpenBatchSummary.ps1 | standalone | LOCAL |  | Evaluates open batches and queues summary alert |
| BatchOps | BatchOps | xFACts-BatchOpsFunctions.ps1 | PowerShell | Script | E:\xFACts-PowerShell\xFACts-BatchOpsFunctions.ps1 | standalone | SHARED | SCOPED | Shared function library for the BatchOps batch-status collectors. Centralizes read-replica source querying, availability-group read-server resolution, stall-duration text formatting, the BatchOps.Status run-state writes (RUNNING and IDLE transitions), and the Jira/Teams alert dispatch with mandatory deduplication that the collectors and the pre-maintenance summary share. |
| BatchOps | BatchOps | BatchMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\BatchMonitoring-API.ps1 | cc | LOCAL |  | Batch Monitoring CC API endpoints |
| BatchOps | BatchOps | batch-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\batch-monitoring.css | cc | LOCAL |  | Batch Monitoring CC styles |
| BatchOps | BatchOps | batch-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\batch-monitoring.js | cc | LOCAL |  | Batch Monitoring CC client-side logic |
| BatchOps | BatchOps | BatchMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\BatchMonitoring.ps1 | cc | LOCAL |  | Batch Monitoring CC page route |
| BIDATA | BIDATA | BuildExecution | Database | Table | BIDATA |  |  |  | Nightly BIDATA build execution tracking |
| BIDATA | BIDATA | StepExecution | Database | Table | BIDATA |  |  |  | Build step execution detail |
| BIDATA | BIDATA | Monitor-BIDATABuild.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Monitor-BIDATABuild.ps1 | standalone | LOCAL |  | Monitors BIDATA nightly build and queues alerts |
| BIDATA | BIDATA | BIDATAMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\BIDATAMonitoring-API.ps1 | cc | LOCAL |  | BIDATA Monitoring CC API endpoints |
| BIDATA | BIDATA | bidata-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\bidata-monitoring.css | cc | LOCAL |  | BIDATA Monitoring CC styles |
| BIDATA | BIDATA | bidata-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\bidata-monitoring.js | cc | LOCAL |  | BIDATA Monitoring CC client-side logic |
| BIDATA | BIDATA | BIDATAMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\BIDATAMonitoring.ps1 | cc | LOCAL |  | BIDATA Monitoring CC page route |
| ControlCenter | ControlCenter.Admin | Admin-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\Admin-API.ps1 | cc | LOCAL |  | Administration CC API endpoints |
| ControlCenter | ControlCenter.Admin | admin.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\admin.css | cc | LOCAL |  | Administration CC styles |
| ControlCenter | ControlCenter.Admin | admin.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\admin.js | cc | LOCAL |  | Administration CC client-side logic |
| ControlCenter | ControlCenter.Admin | Admin.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\Admin.ps1 | cc | LOCAL |  | Administration CC page route |
| ControlCenter | ControlCenter.Home | home.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\home.css | cc | LOCAL |  | Home page CC styles |
| ControlCenter | ControlCenter.Home | Home.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\Home.ps1 | cc | LOCAL |  | Home page route |
| ControlCenter | ControlCenter.Platform | PlatformMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\PlatformMonitoring-API.ps1 | cc | LOCAL |  | Platform Monitoring CC API endpoints |
| ControlCenter | ControlCenter.Platform | platform-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\platform-monitoring.css | cc | LOCAL |  | Platform Monitoring CC styles |
| ControlCenter | ControlCenter.Platform | platform-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\platform-monitoring.js | cc | LOCAL |  | Platform Monitoring CC client-side logic |
| ControlCenter | ControlCenter.Platform | PlatformMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\PlatformMonitoring.ps1 | cc | LOCAL |  | Platform Monitoring CC page route |
| ControlCenter | ControlCenter.Shared | server.psd1 | PowerShell | Config | E:\xFACts-ControlCenter\scripts\server.psd1 | exempt | exempt |  | Pode server configuration. Sets request timeout to 180 seconds for long-running API operations (e.g., DM App Server firewall commit). |
| ControlCenter | ControlCenter.Shared | xFACts-CCShared.psm1 | PowerShell | Module | E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1 | cc | SHARED | PLATFORM | Shared helper functions module for all CC pages |
| ControlCenter | ControlCenter.Shared | Start-ControlCenter.ps1 | PowerShell | Script | E:\xFACts-ControlCenter\scripts\Start-ControlCenter.ps1 | cc | LOCAL | BOOTSTRAP | Control Center Pode server entry point |
| ControlCenter | ControlCenter.Shared | engine-events-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\engine-events-API.ps1 | cc | SHARED |  | Shared API Endpoints |
| ControlCenter | ControlCenter.Shared | cc-shared.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\cc-shared.css | cc | SHARED | SHELL | Shared styles and classes |
| ControlCenter | ControlCenter.Shared | cc-shared.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\cc-shared.js | cc | SHARED | SHELL | Shared JavaScript functions |
| ControlCenter | Documentation.Pipeline | Deploy-xFACts.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Deploy-xFACts.ps1 | standalone | LOCAL |  | Deploys authored xFACts content from GitHub into the live server folders - the deploy half of the inverted sync. Verifies a server-side staging clone, pulls authored files with a per-invocation GitHub token, maps changed authored repository paths to their live locations and copies them. |
| ControlCenter | Documentation.Pipeline | Generate-DDLReference.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Generate-DDLReference.ps1 | standalone | LOCAL |  | Orchestrates DDL reference JSON generation |
| ControlCenter | Documentation.Pipeline | Invoke-DocPipeline.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Invoke-DocPipeline.ps1 | standalone | LOCAL |  | Orchestrates the full documentation pipeline |
| ControlCenter | Documentation.Pipeline | Publish-ConfluenceDocumentation.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Publish-ConfluenceDocumentation.ps1 | standalone | LOCAL |  | Publishes HTML docs to Confluence and exports markdown |
| ControlCenter | Documentation.Pipeline | Publish-GitHubRepository.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Publish-GitHubRepository.ps1 | standalone | LOCAL |  | Publishes all xFACts platform files to GitHub repository via REST API with manifest generation |
| ControlCenter | Documentation.Pipeline | xFACts-DocPipelineFunctions.ps1 | PowerShell | Script | E:\xFACts-PowerShell\xFACts-DocPipelineFunctions.ps1 | standalone | SHARED | SCOPED | Shared function library for the Documentation.Pipeline scripts. Shared functions: user SQL object definition extraction and Platform Registry markdown generation. Dot-sourced by the documentation-pipeline scripts. |
| ControlCenter | Documentation.Site | docs-architecture.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-architecture.css | docs | SHARED |  | Architecture page styles |
| ControlCenter | Documentation.Site | docs-base.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-base.css | docs | SHARED | SHELL | Documentation site base styles |
| ControlCenter | Documentation.Site | docs-controlcenter.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-controlcenter.css | docs | SHARED |  | Module Control Center page styles |
| ControlCenter | Documentation.Site | docs-erd.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-erd.css | docs | SHARED |  | ERD diagram styles |
| ControlCenter | Documentation.Site | docs-hub.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-hub.css | docs | SHARED |  | Documentation hub page styles |
| ControlCenter | Documentation.Site | docs-narrative.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-narrative.css | docs | SHARED |  | Narrative page styles |
| ControlCenter | Documentation.Site | docs-reference.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-reference.css | docs | SHARED |  | Reference page styles |
| ControlCenter | Documentation.Site | b2b-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\b2b-arch.html | docs | LOCAL |  | IBM/B2B architecture page |
| ControlCenter | Documentation.Site | b2b-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\b2b-cc.html | docs | LOCAL |  | IBM/B2B Control Center guide page |
| ControlCenter | Documentation.Site | b2b-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\b2b-ref.html | docs | LOCAL |  | IBM/B2B DDL reference page |
| ControlCenter | Documentation.Site | b2b.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\b2b.html | docs | LOCAL |  | IBM/B2B narrative documentation page |
| ControlCenter | Documentation.Site | backup-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\backup-arch.html | docs | LOCAL |  | Backup architecture page |
| ControlCenter | Documentation.Site | backup-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\backup-cc.html | docs | LOCAL |  | Backup Monitoring Control Center guide page |
| ControlCenter | Documentation.Site | backup-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\backup-ref.html | docs | LOCAL |  | Backup DDL reference page |
| ControlCenter | Documentation.Site | backup.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\backup.html | docs | LOCAL |  | Backup narrative page |
| ControlCenter | Documentation.Site | batchops-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\batchops-arch.html | docs | LOCAL |  | BatchOps architecture page |
| ControlCenter | Documentation.Site | batchops-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\batchops-cc.html | docs | LOCAL |  | Batch Monitoring Control Center guide page |
| ControlCenter | Documentation.Site | batchops-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\batchops-ref.html | docs | LOCAL |  | BatchOps DDL reference page |
| ControlCenter | Documentation.Site | batchops.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\batchops.html | docs | LOCAL |  | BatchOps narrative page |
| ControlCenter | Documentation.Site | bdl-import-guide.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\guides\bdl-import-guide.html | docs | LOCAL |  | BDL Import user guide — standalone step-by-step walkthrough |
| ControlCenter | Documentation.Site | bidata-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\bidata-arch.html | docs | LOCAL |  | BIDATA architecture page |
| ControlCenter | Documentation.Site | bidata-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\bidata-cc.html | docs | LOCAL |  | BIDATA Monitoring Control Center guide page |
| ControlCenter | Documentation.Site | bidata-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\bidata-ref.html | docs | LOCAL |  | BIDATA DDL reference page |
| ControlCenter | Documentation.Site | bidata.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\bidata.html | docs | LOCAL |  | BIDATA narrative page |
| ControlCenter | Documentation.Site | controlcenter-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\controlcenter-arch.html | docs | LOCAL |  | Control Center architecture page |
| ControlCenter | Documentation.Site | controlcenter-cc-admin.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\controlcenter-cc-admin.html | docs | LOCAL |  | Administration Control Center guide page |
| ControlCenter | Documentation.Site | controlcenter-cc-platform.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\controlcenter-cc-platform.html | docs | LOCAL |  | Platform Monitoring Control Center guide page |
| ControlCenter | Documentation.Site | controlcenter-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\controlcenter-ref.html | docs | LOCAL |  | Control Center DDL reference page |
| ControlCenter | Documentation.Site | controlcenter.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\controlcenter.html | docs | LOCAL |  | Control Center narrative page |
| ControlCenter | Documentation.Site | dbcc-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\dbcc-arch.html | docs | LOCAL |  | DBCC Operations architecture page |
| ControlCenter | Documentation.Site | dbcc-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\dbcc-cc.html | docs | LOCAL |  | DBCC Control Center guide page |
| ControlCenter | Documentation.Site | dbcc-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\dbcc-ref.html | docs | LOCAL |  | DBCC Operations DDL reference page |
| ControlCenter | Documentation.Site | dbcc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\dbcc.html | docs | LOCAL |  | DBCC Operations narrative page |
| ControlCenter | Documentation.Site | dmops-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\dmops-arch.html | docs | LOCAL |  | DM Operations architecture documentation page |
| ControlCenter | Documentation.Site | dmops-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\dmops-cc.html | docs | LOCAL |  | DM Operations Control Center guide page |
| ControlCenter | Documentation.Site | dmops-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\dmops-ref.html | docs | LOCAL |  | DM Operations reference documentation page |
| ControlCenter | Documentation.Site | dmops.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\dmops.html | docs | LOCAL |  | DM Operations narrative documentation page |
| ControlCenter | Documentation.Site | engine-room-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\engine-room-arch.html | docs | LOCAL |  | Engine Room architecture page |
| ControlCenter | Documentation.Site | engine-room-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\engine-room-ref.html | docs | LOCAL |  | Engine Room DDL reference page |
| ControlCenter | Documentation.Site | engine-room.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\engine-room.html | docs | LOCAL |  | Engine Room narrative page |
| ControlCenter | Documentation.Site | fileops-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\fileops-arch.html | docs | LOCAL |  | FileOps architecture page |
| ControlCenter | Documentation.Site | fileops-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\fileops-cc.html | docs | LOCAL |  | File Monitoring Control Center guide page |
| ControlCenter | Documentation.Site | fileops-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\fileops-ref.html | docs | LOCAL |  | FileOps DDL reference page |
| ControlCenter | Documentation.Site | fileops.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\fileops.html | docs | LOCAL |  | FileOps narrative page |
| ControlCenter | Documentation.Site | index.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\index.html | docs | LOCAL |  | Documentation hub page |
| ControlCenter | Documentation.Site | indexmaint-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\indexmaint-arch.html | docs | LOCAL |  | Index Maintenance architecture page |
| ControlCenter | Documentation.Site | indexmaint-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\indexmaint-cc.html | docs | LOCAL |  | Index Maintenance Control Center guide page |
| ControlCenter | Documentation.Site | indexmaint-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\indexmaint-ref.html | docs | LOCAL |  | Index Maintenance DDL reference page |
| ControlCenter | Documentation.Site | indexmaint.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\indexmaint.html | docs | LOCAL |  | Index Maintenance narrative page |
| ControlCenter | Documentation.Site | jboss-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\jboss-arch.html | docs | LOCAL |  | JBoss Monitoring architecture page |
| ControlCenter | Documentation.Site | jboss-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\jboss-cc.html | docs | LOCAL |  | JBoss Monitoring Control Center guide page |
| ControlCenter | Documentation.Site | jboss-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\jboss-ref.html | docs | LOCAL |  | JBoss Monitoring DDL reference page |
| ControlCenter | Documentation.Site | jboss.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\jboss.html | docs | LOCAL |  | JBoss Monitoring narrative page |
| ControlCenter | Documentation.Site | jira-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\jira-arch.html | docs | LOCAL |  | Jira architecture page |
| ControlCenter | Documentation.Site | jira-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\jira-ref.html | docs | LOCAL |  | Jira DDL reference page |
| ControlCenter | Documentation.Site | jira.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\jira.html | docs | LOCAL |  | Jira narrative page |
| ControlCenter | Documentation.Site | jobflow-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\jobflow-arch.html | docs | LOCAL |  | JobFlow architecture page |
| ControlCenter | Documentation.Site | jobflow-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\jobflow-cc.html | docs | LOCAL |  | JobFlow Monitoring Control Center guide page |
| ControlCenter | Documentation.Site | jobflow-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\jobflow-ref.html | docs | LOCAL |  | JobFlow DDL reference page |
| ControlCenter | Documentation.Site | jobflow.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\jobflow.html | docs | LOCAL |  | JobFlow narrative page |
| ControlCenter | Documentation.Site | replication-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\replication-arch.html | docs | LOCAL |  | Replication architecture page |
| ControlCenter | Documentation.Site | replication-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\replication-cc.html | docs | LOCAL |  | Replication Monitoring Control Center guide page |
| ControlCenter | Documentation.Site | replication-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\replication-ref.html | docs | LOCAL |  | Replication DDL reference page |
| ControlCenter | Documentation.Site | replication.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\replication.html | docs | LOCAL |  | Replication narrative page |
| ControlCenter | Documentation.Site | serverhealth-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\serverhealth-arch.html | docs | LOCAL |  | ServerHealth architecture page |
| ControlCenter | Documentation.Site | serverhealth-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\serverhealth-cc.html | docs | LOCAL |  | ServerHealth Control Center guide page |
| ControlCenter | Documentation.Site | serverhealth-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\serverhealth-ref.html | docs | LOCAL |  | ServerHealth DDL reference page |
| ControlCenter | Documentation.Site | serverhealth.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\serverhealth.html | docs | LOCAL |  | ServerHealth narrative page |
| ControlCenter | Documentation.Site | teams-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\teams-arch.html | docs | LOCAL |  | Teams architecture page |
| ControlCenter | Documentation.Site | teams-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\teams-ref.html | docs | LOCAL |  | Teams DDL reference page |
| ControlCenter | Documentation.Site | teams.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\teams.html | docs | LOCAL |  | Teams narrative page |
| ControlCenter | Documentation.Site | tools-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\tools-ref.html | docs | LOCAL |  | Tools DDL reference page |
| ControlCenter | Documentation.Site | tools.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\tools.html | docs | LOCAL |  | Tools narrative page |
| ControlCenter | Documentation.Site | ddl-erd.js | Documentation | JavaScript | E:\xFACts-ControlCenter\public\docs\js\ddl-erd.js | docs | SHARED |  | ERD diagram renderer |
| ControlCenter | Documentation.Site | ddl-loader.js | Documentation | JavaScript | E:\xFACts-ControlCenter\public\docs\js\ddl-loader.js | docs | SHARED |  | DDL reference JSON loader and renderer |
| ControlCenter | Documentation.Site | docs-controlcenter.js | Documentation | JavaScript | E:\xFACts-ControlCenter\public\docs\js\docs-controlcenter.js | docs | SHARED |  | CC guide page interactive behavior and slideout panel |
| ControlCenter | Documentation.Site | docs-shared.js | Documentation | JavaScript | E:\xFACts-ControlCenter\public\docs\js\docs-shared.js | docs | SHARED | SHELL | Documentation site shared file |
| ControlCenter | Documentation.Site | nav.js | Documentation | JavaScript | E:\xFACts-ControlCenter\public\docs\js\nav.js | docs | SHARED |  | Documentation site navigation |
| dbo | Engine.RBAC | RBAC_ActionGrant | Database | Table | dbo |  |  |  | Granted actions per user |
| dbo | Engine.RBAC | RBAC_ActionRegistry | Database | Table | dbo |  |  |  | Defined actions available for granting |
| dbo | Engine.RBAC | RBAC_AuditLog | Database | Table | dbo |  |  |  | RBAC change audit trail |
| dbo | Engine.RBAC | RBAC_DepartmentRegistry | Database | Table | dbo |  |  |  | Department definitions for access scoping |
| dbo | Engine.RBAC | RBAC_NavRegistry | Database | Table | dbo |  |  |  | Master inventory of CC pages with navigation metadata: labels, descriptions, section grouping, sort order, doc link, and visibility flags. |
| dbo | Engine.RBAC | RBAC_NavSection | Database | Table | dbo |  |  |  | Section groupings for the dynamic Control Center navigation, with display ordering and CSS accent class for visual styling. |
| dbo | Engine.RBAC | RBAC_PermissionMapping | Database | Table | dbo |  |  |  | Role-to-page route access mappings |
| dbo | Engine.RBAC | RBAC_Role | Database | Table | dbo |  |  |  | Defined access roles |
| dbo | Engine.RBAC | RBAC_RoleMapping | Database | Table | dbo |  |  |  | User-to-role assignments |
| dbo | Engine.SharedInfrastructure | TR_xFACts_ProtectCriticalObjects | Database | DDL Trigger | dbo |  |  |  | DDL trigger preventing DROP/ALTER on protected objects |
| dbo | Engine.SharedInfrastructure | sp_AddHoliday | Database | Procedure | dbo |  |  |  | Adds a single holiday entry |
| dbo | Engine.SharedInfrastructure | sp_GenerateHolidays | Database | Procedure | dbo |  |  |  | Generates holiday entries for a given year |
| dbo | Engine.SharedInfrastructure | sp_LogProtectionViolation | Database | Procedure | dbo |  |  |  | Logs blocked DDL operations to Protection_ViolationLog |
| dbo | Engine.SharedInfrastructure | ActionAuditLog | Database | Table | dbo |  |  |  | Audit trail for Control Center administrative actions |
| dbo | Engine.SharedInfrastructure | API_RequestLog | Database | Table | dbo |  |  |  | HTTP request logging for Control Center API endpoints |
| dbo | Engine.SharedInfrastructure | Asset_Registry | Database | Table | dbo |  |  |  | Catalog of every component (CSS class, JS function, HTML ID, API route, etc.) extracted from Control Center source files. One row per definition or usage instance, distinguishing local from shared scope and mapping consumption to definition. Populated by the Asset_Registry parser pipeline. Enables drift detection, consumption tracking, and naming-convention enforcement across the Control Center codebase. |
| dbo | Engine.SharedInfrastructure | ClientHierarchy | Database | Table | dbo |  |  |  | Complete flattened DM creditor hierarchy for cross-module client resolution. |
| dbo | Engine.SharedInfrastructure | Component_Registry | Database | Table | dbo |  |  |  | Logical component grouping catalog |
| dbo | Engine.SharedInfrastructure | Credentials | Database | Table | dbo |  |  |  | Encrypted credential storage for service accounts |
| dbo | Engine.SharedInfrastructure | CredentialServices | Database | Table | dbo |  |  |  | Service-to-credential mapping |
| dbo | Engine.SharedInfrastructure | DatabaseRegistry | Database | Table | dbo |  |  |  | Registered databases for monitoring enrollment |
| dbo | Engine.SharedInfrastructure | GlobalConfig | Database | Table | dbo |  |  |  | Runtime configuration settings for all modules |
| dbo | Engine.SharedInfrastructure | Holiday | Database | Table | dbo |  |  |  | Holiday calendar for scheduling decisions |
| dbo | Engine.SharedInfrastructure | Module_Registry | Database | Table | dbo |  |  |  | Module definitions completing the Module ? Component ? Object hierarchy |
| dbo | Engine.SharedInfrastructure | Object_Metadata | Database | Table | dbo |  |  |  | Documentation content for all database objects and scripts |
| dbo | Engine.SharedInfrastructure | Object_Registry | Database | Table | dbo |  |  |  | Complete object inventory linked to components |
| dbo | Engine.SharedInfrastructure | Protection_ViolationLog | Database | Table | dbo |  |  |  | Blocked DDL operations on protected objects |
| dbo | Engine.SharedInfrastructure | ServerRegistry | Database | Table | dbo |  |  |  | Registered SQL Server instances |
| dbo | Engine.SharedInfrastructure | System_Metadata | Database | Table | dbo |  |  |  | Component version changelog |
| dbo | Engine.SharedInfrastructure | Sync-ClientHierarchy.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Sync-ClientHierarchy.ps1 | standalone | LOCAL |  | Daily rebuild of dbo.ClientHierarchy via recursive CTE and MERGE from crs5_oltp creditor hierarchy. |
| dbo | Tools.Catalog | Catalog_ApiRegistry | Database | Table | Tools |  |  |  | REST API endpoint catalog — one row per path+method combination. Parsed from OpenAPI 3.0 YAML specs. |
| dbo | Tools.Catalog | Catalog_ApiSchemaRegistry | Database | Table | Tools |  |  |  | REST API schema property catalog — one row per property within each model object. Links to Catalog_ApiRegistry via schema name. |
| dbo | Tools.Catalog | Catalog_BDLElementRegistry | Database | Table | Tools |  |  |  | BDL element catalog — one row per element within each entity type. Links to Catalog_BDLFormatRegistry via spec_version + type_name. |
| dbo | Tools.Catalog | Catalog_BDLFormatRegistry | Database | Table | Tools |  |  |  | BDL entity type catalog — one row per bulk data load format. Parsed from XSD schema definitions. |
| dbo | Tools.Catalog | Catalog_CDLElementRegistry | Database | Table | Tools |  |  |  | CDL element catalog — one row per element within each entity type. Links to Catalog_CDLFormatRegistry via spec_version + type_name. |
| dbo | Tools.Catalog | Catalog_CDLFormatRegistry | Database | Table | Tools |  |  |  | CDL entity type catalog — one row per configuration data format. Parsed from XSD schema definitions. |
| DeptOps | DeptOps.ApplicationsIntegration | ApplicationsIntegration-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\ApplicationsIntegration-API.ps1 | cc | LOCAL |  | Applications & Integration CC API endpoints — BDL catalog management |
| DeptOps | DeptOps.ApplicationsIntegration | applications-integration.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\applications-integration.css | cc | LOCAL |  | Applications & Integration CC styles |
| DeptOps | DeptOps.ApplicationsIntegration | applications-integration.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\applications-integration.js | cc | LOCAL |  | Applications & Integration CC client-side logic — BDL catalog management panels |
| DeptOps | DeptOps.ApplicationsIntegration | ApplicationsIntegration.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\ApplicationsIntegration.ps1 | cc | LOCAL |  | Applications & Integration CC page route |
| DeptOps | DeptOps.BusinessIntelligence | BusinessIntelligence-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\BusinessIntelligence-API.ps1 | cc | LOCAL |  | Business Intelligence CC API endpoints |
| DeptOps | DeptOps.BusinessIntelligence | business-intelligence.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\business-intelligence.css | cc | LOCAL |  | Business Intelligence CC styles |
| DeptOps | DeptOps.BusinessIntelligence | business-intelligence.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\business-intelligence.js | cc | LOCAL |  | Business Intelligence CC client-side logic |
| DeptOps | DeptOps.BusinessIntelligence | BusinessIntelligence.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\BusinessIntelligence.ps1 | cc | LOCAL |  | Business Intelligence CC page route |
| DeptOps | DeptOps.BusinessServices | BS_ReviewRequest_Group | Database | Table | DeptOps |  |  |  | Review request group definitions |
| DeptOps | DeptOps.BusinessServices | BS_ReviewRequest_Tracking | Database | Table | DeptOps |  |  |  | Review request processing tracking |
| DeptOps | DeptOps.BusinessServices | BS_ReviewRequest_User | Database | Table | DeptOps |  |  |  | Review request user assignments |
| DeptOps | DeptOps.BusinessServices | Collect-BSReviewRequests.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-BSReviewRequests.ps1 | standalone | LOCAL |  | Collects Business Services review request data |
| DeptOps | DeptOps.BusinessServices | Distribute-BSReviewRequests.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Distribute-BSReviewRequests.ps1 | standalone | LOCAL |  | Distributes review requests to analysts |
| DeptOps | DeptOps.BusinessServices | BusinessServices-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\BusinessServices-API.ps1 | cc | LOCAL |  | Business Services CC API endpoints |
| DeptOps | DeptOps.BusinessServices | business-services.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\business-services.css | cc | LOCAL |  | Business Services CC styles |
| DeptOps | DeptOps.BusinessServices | business-services.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\business-services.js | cc | LOCAL |  | Business Services CC client-side logic |
| DeptOps | DeptOps.BusinessServices | BusinessServices.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\BusinessServices.ps1 | cc | LOCAL |  | Business Services CC page route |
| DeptOps | DeptOps.ClientRelations | ClientRelations-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\ClientRelations-API.ps1 | cc | LOCAL |  | Client Relations CC API endpoints |
| DeptOps | DeptOps.ClientRelations | client-relations.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\client-relations.css | cc | LOCAL |  | Client Relations CC styles |
| DeptOps | DeptOps.ClientRelations | client-relations.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\client-relations.js | cc | LOCAL |  | Client Relations CC client-side logic |
| DeptOps | DeptOps.ClientRelations | ClientRelations.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\ClientRelations.ps1 | cc | LOCAL |  | Client Relations CC page route |
| DmOps | DmOps | Archive_BatchDetail | Database | Table | DmOps |  |  |  | Per-table operation detail within each archive batch — delete order, rows affected, duration, and status |
| DmOps | DmOps | Archive_BatchLog | Database | Table | DmOps |  |  |  | Batch-level execution summary for archive processing — one row per batch with counts, timing, and status |
| DmOps | DmOps | Archive_ConsumerExceptionLog | Database | Table | DmOps |  |  |  | Audit trail of TC_ARCH-tagged consumers removed from a batch by runtime re-verification — one row per excepted consumer with confirmation flags for tag removal and AR event writes |
| DmOps | DmOps | Archive_ConsumerLog | Database | Table | DmOps |  |  |  | Audit trail of every consumer and account archived — tall skinny log for BI cross-reference and reconciliation |
| DmOps | DmOps | Archive_Schedule | Database | Table | DmOps |  |  |  | Weekly schedule grid controlling archive execution mode per hour — blocked, full batch, or reduced batch |
| DmOps | DmOps | Archive_WorkgroupRegistry | Database | Table | DmOps |  |  |  | Authoritative registry of archive candidate-pool workgroups per line of business. Consumed by the DM nightly tagging job filters (via cross-database reference), the Control Center DM Operations UI, and candidate-pool drift auditing. Deliberately excludes the destination workgroups (WFAARCH1/WFAARCH3). |
| DmOps | DmOps | ShellPurge_BatchDetail | Database | Table | DmOps |  |  |  | Per-table operation detail within each shell purge batch — delete order, rows affected, duration, and status |
| DmOps | DmOps | ShellPurge_BatchLog | Database | Table | DmOps |  |  |  | Batch-level execution summary for shell purge processing — one row per batch with counts, timing, and status |
| DmOps | DmOps | ShellPurge_ConsumerExceptionLog | Database | Table | DmOps |  |  |  | Consumers excluded from shell purge due to qualifying data in tables not covered by the delete sequence — one row per consumer per exclusion reason |
| DmOps | DmOps | ShellPurge_ConsumerLog | Database | Table | DmOps |  |  |  | Audit trail of every consumer purged — batch and consumer ID for reconciliation |
| DmOps | DmOps | ShellPurge_Schedule | Database | Table | DmOps |  |  |  | Weekly schedule grid controlling shell purge execution mode per hour — blocked, full batch, or reduced batch |
| DmOps | DmOps | Execute-DmConsumerArchive.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Execute-DmConsumerArchive.ps1 | standalone | LOCAL |  | Unified consumer-level archive execution — TC_ARCH-driven batch deletion of consumers and all linked accounts/transactions from crs5_oltp, with mid-batch BIDATA P-to-C migration |
| DmOps | DmOps | Execute-DmShellPurge.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Execute-DmShellPurge.ps1 | standalone | LOCAL |  | Consumer shell purge execution — removes orphaned consumer records with no remaining accounts from crs5_oltp |
| DmOps | DmOps | xFACts-DmOpsFunctions.ps1 | PowerShell | Script | E:\xFACts-PowerShell\xFACts-DmOpsFunctions.ps1 | standalone | SHARED | SCOPED | Shared function library for the DmOps consumer-deletion scripts. Centralizes persistent-connection management, chunked snapshot-isolation DELETE and UPDATE primitives, per-table operation wrappers with the preview/execute split, and the stop-on-failure step wrappers that both scripts share. |
| DmOps | DmOps | DmOperations-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\DmOperations-API.ps1 | cc | LOCAL |  | DM Operations CC API endpoints |
| DmOps | DmOps | dm-operations.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\dm-operations.css | cc | LOCAL |  | DM Operations CC styles |
| DmOps | DmOps | dm-operations.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\dm-operations.js | cc | LOCAL |  | DM Operations CC client-side logic |
| DmOps | DmOps | DmOperations.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\DmOperations.ps1 | cc | LOCAL |  | DM Operations CC page route |
| FileOps | FileOps | sp_AddNewMonitorConfig | Database | Procedure | FileOps |  |  |  | Adds a new file monitoring configuration entry |
| FileOps | FileOps | MonitorConfig | Database | Table | FileOps |  |  |  | SFTP file monitoring configuration |
| FileOps | FileOps | MonitorLog | Database | Table | FileOps |  |  |  | File monitoring event log |
| FileOps | FileOps | MonitorStatus | Database | Table | FileOps |  |  |  | Current monitoring status per configuration |
| FileOps | FileOps | ServerConfig | Database | Table | FileOps |  |  |  | SFTP server connection configuration |
| FileOps | FileOps | TR_FileOps_MonitorLog_DisableETL_OneGI | Database | Trigger | FileOps |  |  |  | Monitors OneGI file escalation and disables automation |
| FileOps | FileOps | Scan-SFTPFiles.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Scan-SFTPFiles.ps1 | standalone | LOCAL |  | Scans SFTP directories for expected files |
| FileOps | FileOps | FileMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\FileMonitoring-API.ps1 | cc | LOCAL |  | File Monitoring CC API endpoints |
| FileOps | FileOps | file-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\file-monitoring.css | cc | LOCAL |  | File Monitoring CC styles |
| FileOps | FileOps | file-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\file-monitoring.js | cc | LOCAL |  | File Monitoring CC client-side logic |
| FileOps | FileOps | FileMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\FileMonitoring.ps1 | cc | LOCAL |  | File Monitoring CC page route |
| JBoss | JBoss | ConfigHistory | Database | Table | JBoss |  |  |  | JBoss configuration change detection for application servers |
| JBoss | JBoss | QueueSnapshot | Database | Table | JBoss |  |  |  | Per-queue JMS metrics for JBoss application servers |
| JBoss | JBoss | Snapshot | Database | Table | JBoss |  |  |  | Append-only point-in-time health snapshots per JBoss application server per collection cycle |
| JBoss | JBoss | Collect-JBossMetrics.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-JBossMetrics.ps1 | standalone | LOCAL |  | JBoss Management API metrics collector for application servers |
| JBoss | JBoss | JBossMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\JBossMonitoring-API.ps1 | cc | LOCAL |  | JBoss Monitoring CC API endpoints |
| JBoss | JBoss | jboss-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\jboss-monitoring.css | cc | LOCAL |  | JBoss Monitoring CC styles |
| JBoss | JBoss | jboss-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\jboss-monitoring.js | cc | LOCAL |  | JBoss Monitoring CC client-side logic |
| JBoss | JBoss | JBossMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\JBossMonitoring.ps1 | cc | LOCAL |  | JBoss Monitoring CC page route |
| Jira | Jira | sp_QueueTicket | Database | Procedure | Jira |  |  |  | Queues a new ticket for Jira creation |
| Jira | Jira | RequestLog | Database | Table | Jira |  |  |  | Jira API request attempt log |
| Jira | Jira | TicketQueue | Database | Table | Jira |  |  |  | Queued Jira tickets awaiting creation |
| Jira | Jira | TR_Jira_TicketQueue_QueueDepth | Database | Trigger | Jira |  |  |  | Monitors ticket queue depth and raises warnings |
| Jira | Jira | Process-JiraTicketQueue.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Process-JiraTicketQueue.ps1 | standalone | LOCAL |  | Processes pending tickets and creates via Jira API |
| JobFlow | JobFlow | ErrorCategory | Database | Table | JobFlow |  |  |  | Error category definitions |
| JobFlow | JobFlow | FlowConfig | Database | Table | JobFlow |  |  |  | SSIS flow monitoring configuration |
| JobFlow | JobFlow | FlowExecutionTracking | Database | Table | JobFlow |  |  |  | SSIS package execution tracking |
| JobFlow | JobFlow | JobConfig | Database | Table | JobFlow |  |  |  | SQL Agent job monitoring configuration |
| JobFlow | JobFlow | JobExecutionLog | Database | Table | JobFlow |  |  |  | SQL Agent job execution log |
| JobFlow | JobFlow | JobStatus | Database | Table | JobFlow |  |  |  | Current job status summary |
| JobFlow | JobFlow | Schedule | Database | Table | JobFlow |  |  |  | Expected execution schedules |
| JobFlow | JobFlow | StallDetectionLog | Database | Table | JobFlow |  |  |  | Detected stalled job/flow records |
| JobFlow | JobFlow | Status | Database | Table | JobFlow |  |  |  | Status code definitions |
| JobFlow | JobFlow | ValidationException | Database | Table | JobFlow |  |  |  | Validation exception rules |
| JobFlow | JobFlow | ValidationLog | Database | Table | JobFlow |  |  |  | Validation check results |
| JobFlow | JobFlow | Monitor-JobFlow.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Monitor-JobFlow.ps1 | standalone | LOCAL |  | Monitors job/flow executions and queues alerts |
| JobFlow | JobFlow | JobFlowMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\JobFlowMonitoring-API.ps1 | cc | LOCAL |  | JobFlow Monitoring CC API endpoints |
| JobFlow | JobFlow | jobflow-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\jobflow-monitoring.css | cc | LOCAL |  | JobFlow Monitoring CC styles |
| JobFlow | JobFlow | jobflow-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\jobflow-monitoring.js | cc | LOCAL |  | JobFlow Monitoring CC client-side logic |
| JobFlow | JobFlow | JobFlowMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\JobFlowMonitoring.ps1 | cc | LOCAL |  | JobFlow Monitoring CC page route |
| Orchestrator | Engine.Orchestrator | CycleLog | Database | Table | Orchestrator |  |  |  | Orchestrator heartbeat cycle log |
| Orchestrator | Engine.Orchestrator | ProcessRegistry | Database | Table | Orchestrator |  |  |  | Registered processes with schedules and run modes |
| Orchestrator | Engine.Orchestrator | TaskLog | Database | Table | Orchestrator |  |  |  | Individual process execution records |
| Orchestrator | Engine.Orchestrator | Start-xFACtsOrchestrator.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Start-xFACtsOrchestrator.ps1 | standalone | LOCAL |  | Main orchestrator engine entry point |
| Orchestrator | Engine.Orchestrator | xFACts-OrchestratorFunctions.ps1 | PowerShell | Script | E:\xFACts-PowerShell\xFACts-OrchestratorFunctions.ps1 | standalone | SHARED | PLATFORM | Shared orchestrator function library |
| ServerOps | ServerOps.Backup | Backup_DatabaseConfig | Database | Table | ServerOps |  |  |  | Per-database backup configuration and policies |
| ServerOps | ServerOps.Backup | Backup_ExecutionLog | Database | Table | ServerOps |  |  |  | Backup execution records |
| ServerOps | ServerOps.Backup | Backup_FileTracking | Database | Table | ServerOps |  |  |  | Tracks backup files through copy/upload/retention lifecycle |
| ServerOps | ServerOps.Backup | Collect-BackupStatus.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-BackupStatus.ps1 | standalone | LOCAL |  | Collects backup status from all enrolled servers |
| ServerOps | ServerOps.Backup | Process-BackupAWSUpload.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Process-BackupAWSUpload.ps1 | standalone | LOCAL |  | Uploads backup files to AWS S3 |
| ServerOps | ServerOps.Backup | Process-BackupNetworkCopy.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Process-BackupNetworkCopy.ps1 | standalone | LOCAL |  | Copies backup files to network share |
| ServerOps | ServerOps.Backup | Process-BackupRetention.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Process-BackupRetention.ps1 | standalone | LOCAL |  | Manages backup file retention and cleanup |
| ServerOps | ServerOps.Backup | xFACts-BackupFunctions.ps1 | PowerShell | Script | E:\xFACts-PowerShell\xFACts-BackupFunctions.ps1 | standalone | SHARED | SCOPED | Shared function library for the ServerOps.Backup pipeline scripts. Dot-sourced by the backup collector and the network-copy, AWS-upload, and retention processors. Centralizes backup-filename physical-server parsing, local-to-UNC admin-share path conversion, the Backup_ExecutionLog detail writer, and the AWS-upload and network-copy Backup_FileTracking status writes that the collectors and processors share. |
| ServerOps | ServerOps.Backup | Backup-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\Backup-API.ps1 | cc | LOCAL |  | Backup Monitoring CC API endpoints |
| ServerOps | ServerOps.Backup | backup.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\backup.css | cc | LOCAL |  | Backup Monitoring CC styles |
| ServerOps | ServerOps.Backup | backup.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\backup.js | cc | LOCAL |  | Backup Monitoring CC client-side logic |
| ServerOps | ServerOps.Backup | Backup.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\Backup.ps1 | cc | LOCAL |  | Backup Monitoring CC page route |
| ServerOps | ServerOps.DBCC | DBCC_ExecutionLog | Database | Table | ServerOps |  |  |  | DBCC operation execution history — one row per database per operation per run |
| ServerOps | ServerOps.DBCC | DBCC_ScheduleConfig | Database | Table | ServerOps |  |  |  | Per-database DBCC operation scheduling — one row per database with independent day/time per operation |
| ServerOps | ServerOps.DBCC | Execute-DBCC.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Execute-DBCC.ps1 | standalone | LOCAL |  | Executes scheduled DBCC operations against databases per DBCC_ScheduleConfig. Supports manual targeting via parameters. |
| ServerOps | ServerOps.DBCC | DBCCOperations-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\DBCCOperations-API.ps1 | cc | LOCAL |  | DBCC Operations CC API endpoints — live progress, today's executions, execution history, schedule overview, schedule editing |
| ServerOps | ServerOps.DBCC | dbcc-operations.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\dbcc-operations.css | cc | LOCAL |  | DBCC Operations CC styles — viewport-constrained layout, grid sections, modals |
| ServerOps | ServerOps.DBCC | dbcc-operations.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\dbcc-operations.js | cc | LOCAL |  | DBCC Operations CC client-side logic — live polling, accordion history, schedule modals |
| ServerOps | ServerOps.DBCC | DBCCOperations.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\DBCCOperations.ps1 | cc | LOCAL |  | DBCC Operations CC page route |
| ServerOps | ServerOps.Disk | Disk_AlertHistory | Database | Table | ServerOps |  |  |  | Disk space alert history |
| ServerOps | ServerOps.Disk | Disk_Snapshot | Database | Table | ServerOps |  |  |  | Point-in-time disk space snapshots |
| ServerOps | ServerOps.Disk | Disk_Status | Database | Table | ServerOps |  |  |  | Current disk space status per drive |
| ServerOps | ServerOps.Disk | Disk_ThresholdConfig | Database | Table | ServerOps |  |  |  | Disk space alert threshold configuration |
| ServerOps | ServerOps.Disk | Collect-ServerHealth.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-ServerHealth.ps1 | standalone | LOCAL |  | Collects server-level health metrics including disk space |
| ServerOps | ServerOps.Disk | Send-DiskHealthSummary.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Send-DiskHealthSummary.ps1 | standalone | LOCAL |  | Evaluates disk space and queues Teams alerts |
| ServerOps | ServerOps.Index | sp_Index_AddDatabaseHolidaySchedule | Database | Procedure | ServerOps |  |  |  | Adds a holiday maintenance window for a database |
| ServerOps | ServerOps.Index | sp_Index_AddDatabaseSchedule | Database | Procedure | ServerOps |  |  |  | Adds a maintenance window schedule for a database |
| ServerOps | ServerOps.Index | Index_DatabaseConfig | Database | Table | ServerOps |  |  |  | Per-database index maintenance configuration |
| ServerOps | ServerOps.Index | Index_DatabaseSchedule | Database | Table | ServerOps |  |  |  | Maintenance window schedules per database |
| ServerOps | ServerOps.Index | Index_ExceptionSchedule | Database | Table | ServerOps |  |  |  | Override schedules for specific date ranges |
| ServerOps | ServerOps.Index | Index_ExecutionLog | Database | Table | ServerOps |  |  |  | Completed rebuild operation records |
| ServerOps | ServerOps.Index | Index_ExecutionSummary | Database | Table | ServerOps |  |  |  | Aggregated execution summary per run |
| ServerOps | ServerOps.Index | Index_HolidaySchedule | Database | Table | ServerOps |  |  |  | Holiday-specific maintenance windows |
| ServerOps | ServerOps.Index | Index_Queue | Database | Table | ServerOps |  |  |  | Priority-ordered queue of indexes awaiting rebuild |
| ServerOps | ServerOps.Index | Index_Registry | Database | Table | ServerOps |  |  |  | Master catalog of all discovered indexes |
| ServerOps | ServerOps.Index | Index_StatsExecutionLog | Database | Table | ServerOps |  |  |  | Statistics update execution records |
| ServerOps | ServerOps.Index | Index_Status | Database | Table | ServerOps |  |  |  | Current index health status |
| ServerOps | ServerOps.Index | Execute-IndexMaintenance.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Execute-IndexMaintenance.ps1 | standalone | LOCAL |  | Window-aware index rebuild execution engine |
| ServerOps | ServerOps.Index | Scan-IndexFragmentation.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Scan-IndexFragmentation.ps1 | standalone | LOCAL |  | Scans physical fragmentation levels |
| ServerOps | ServerOps.Index | Sync-IndexRegistry.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Sync-IndexRegistry.ps1 | standalone | LOCAL |  | Daily discovery and metadata refresh of all indexes |
| ServerOps | ServerOps.Index | Update-IndexStatistics.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Update-IndexStatistics.ps1 | standalone | LOCAL |  | Updates statistics on recently rebuilt indexes |
| ServerOps | ServerOps.Index | xFACts-IndexFunctions.ps1 | PowerShell | Script | E:\xFACts-PowerShell\xFACts-IndexFunctions.ps1 | standalone | SHARED | SCOPED | Shared function library for index operations |
| ServerOps | ServerOps.Index | IndexMaintenance-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\IndexMaintenance-API.ps1 | cc | LOCAL |  | Index Maintenance CC API endpoints |
| ServerOps | ServerOps.Index | index-maintenance.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\index-maintenance.css | cc | LOCAL |  | Index Maintenance CC styles |
| ServerOps | ServerOps.Index | index-maintenance.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\index-maintenance.js | cc | LOCAL |  | Index Maintenance CC client-side logic |
| ServerOps | ServerOps.Index | IndexMaintenance.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\IndexMaintenance.ps1 | cc | LOCAL |  | Index Maintenance CC page route |
| ServerOps | ServerOps.Replication | Replication_AgentHistory | Database | Table | ServerOps |  |  |  | Replication agent execution history |
| ServerOps | ServerOps.Replication | Replication_EventLog | Database | Table | ServerOps |  |  |  | Replication event log |
| ServerOps | ServerOps.Replication | Replication_LatencyHistory | Database | Table | ServerOps |  |  |  | Historical replication latency measurements |
| ServerOps | ServerOps.Replication | Replication_PublicationRegistry | Database | Table | ServerOps |  |  |  | Replication publication monitoring configuration |
| ServerOps | ServerOps.Replication | Collect-ReplicationHealth.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-ReplicationHealth.ps1 | standalone | LOCAL |  | Collects replication agent status and latency metrics |
| ServerOps | ServerOps.Replication | ReplicationMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\ReplicationMonitoring-API.ps1 | cc | LOCAL |  | Replication Monitoring CC API endpoints |
| ServerOps | ServerOps.Replication | replication-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\replication-monitoring.css | cc | LOCAL |  | Replication Monitoring CC styles |
| ServerOps | ServerOps.Replication | replication-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\replication-monitoring.js | cc | LOCAL |  | Replication Monitoring CC client-side logic |
| ServerOps | ServerOps.Replication | ReplicationMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\ReplicationMonitoring.ps1 | cc | LOCAL |  | Replication Monitoring CC page route |
| ServerOps | ServerOps.ServerHealth | sp_Activity_CorrelateIncidents | Database | Procedure | ServerOps |  |  |  | Correlates DMV anomalies with XE events into incidents |
| ServerOps | ServerOps.ServerHealth | sp_DiagnoseServerHealth | Database | Procedure | ServerOps |  |  |  | Diagnostic analysis combining DMV and XE data |
| ServerOps | ServerOps.ServerHealth | Activity_DMV_ConnectionHealth | Database | Table | ServerOps |  |  |  | Connection health DMV snapshots |
| ServerOps | ServerOps.ServerHealth | Activity_DMV_IO_Stats | Database | Table | ServerOps |  |  |  | I/O statistics DMV snapshots |
| ServerOps | ServerOps.ServerHealth | Activity_DMV_Memory | Database | Table | ServerOps |  |  |  | Memory DMV snapshots |
| ServerOps | ServerOps.ServerHealth | Activity_DMV_WaitStats | Database | Table | ServerOps |  |  |  | Wait statistics DMV snapshots |
| ServerOps | ServerOps.ServerHealth | Activity_DMV_Workload | Database | Table | ServerOps |  |  |  | Workload DMV snapshots |
| ServerOps | ServerOps.ServerHealth | Activity_DMV_xFACts | Database | Table | ServerOps |  |  |  | xFACts-specific DMV snapshots |
| ServerOps | ServerOps.ServerHealth | Activity_Heartbeat | Database | Table | ServerOps |  |  |  | Server heartbeat tracking |
| ServerOps | ServerOps.ServerHealth | Activity_IncidentLog | Database | Table | ServerOps |  |  |  | Correlated incident records |
| ServerOps | ServerOps.ServerHealth | Activity_IncidentType | Database | Table | ServerOps |  |  |  | Incident type definitions |
| ServerOps | ServerOps.ServerHealth | Activity_XE_AGHealth | Database | Table | ServerOps |  |  |  | Always On availability group health events |
| ServerOps | ServerOps.ServerHealth | Activity_XE_BlockedProcess | Database | Table | ServerOps |  |  |  | Blocked process extended events |
| ServerOps | ServerOps.ServerHealth | Activity_XE_CollectionState | Database | Table | ServerOps |  |  |  | XE session collection state tracking |
| ServerOps | ServerOps.ServerHealth | Activity_XE_Deadlock | Database | Table | ServerOps |  |  |  | Deadlock extended events |
| ServerOps | ServerOps.ServerHealth | Activity_XE_LinkedServerIn | Database | Table | ServerOps |  |  |  | Inbound linked server query events |
| ServerOps | ServerOps.ServerHealth | Activity_XE_LinkedServerOut | Database | Table | ServerOps |  |  |  | Outbound linked server query events |
| ServerOps | ServerOps.ServerHealth | Activity_XE_LRQ | Database | Table | ServerOps |  |  |  | Long-running query extended events |
| ServerOps | ServerOps.ServerHealth | Activity_XE_SystemHealth | Database | Table | ServerOps |  |  |  | System health extended events |
| ServerOps | ServerOps.ServerHealth | Activity_XE_xFACts | Database | Table | ServerOps |  |  |  | xFACts-specific extended events |
| ServerOps | ServerOps.ServerHealth | AlwaysOn_health | Database | XE Session | ServerOps |  |  |  | Always On health XE session definition |
| ServerOps | ServerOps.ServerHealth | system_health | Database | XE Session | ServerOps |  |  |  | System health XE session definition |
| ServerOps | ServerOps.ServerHealth | xFACts_BlockedProcess | Database | XE Session | ServerOps |  |  |  | Blocked process XE session definition |
| ServerOps | ServerOps.ServerHealth | xFACts_Deadlock | Database | XE Session | ServerOps |  |  |  | Deadlock XE session definition |
| ServerOps | ServerOps.ServerHealth | xFACts_LongQueries | Database | XE Session | ServerOps |  |  |  | Long-running query XE session definition |
| ServerOps | ServerOps.ServerHealth | xFACts_LS_Inbound | Database | XE Session | ServerOps |  |  |  | Inbound linked server XE session definition |
| ServerOps | ServerOps.ServerHealth | xFACts_LS_Outbound | Database | XE Session | ServerOps |  |  |  | Outbound linked server XE session definition |
| ServerOps | ServerOps.ServerHealth | xFACts_Tracking | Database | XE Session | ServerOps |  |  |  | xFACts tracking XE session definition |
| ServerOps | ServerOps.ServerHealth | Collect-DMVMetrics.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-DMVMetrics.ps1 | standalone | LOCAL |  | Collects DMV performance snapshots from all enrolled servers |
| ServerOps | ServerOps.ServerHealth | Collect-XEEvents.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-XEEvents.ps1 | standalone | LOCAL |  | Harvests Extended Events data from configured sessions |
| ServerOps | ServerOps.ServerHealth | ServerHealth-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\ServerHealth-API.ps1 | cc | LOCAL |  | Server Health CC API endpoints |
| ServerOps | ServerOps.ServerHealth | server-health.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\server-health.css | cc | LOCAL |  | Server Health CC styles |
| ServerOps | ServerOps.ServerHealth | server-health.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\server-health.js | cc | LOCAL |  | Server Health CC client-side logic |
| ServerOps | ServerOps.ServerHealth | ServerHealth.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\ServerHealth.ps1 | cc | LOCAL |  | Server Health CC page route |
| Teams | Teams | sp_QueueAlert | Database | Procedure | Teams |  |  |  | Queues a new alert for Teams delivery |
| Teams | Teams | AlertQueue | Database | Table | Teams |  |  |  | Queued Teams webhook alerts awaiting delivery |
| Teams | Teams | RequestLog | Database | Table | Teams |  |  |  | Teams webhook delivery attempt log |
| Teams | Teams | WebhookConfig | Database | Table | Teams |  |  |  | Teams webhook channel configuration |
| Teams | Teams | WebhookSubscription | Database | Table | Teams |  |  |  | Module-to-webhook subscription mappings |
| Teams | Teams | TR_Teams_AlertQueue_QueueDepth | Database | Trigger | Teams |  |  |  | Monitors alert queue depth and raises warnings |
| Teams | Teams | Process-TeamsAlertQueue.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Process-TeamsAlertQueue.ps1 | standalone | LOCAL |  | Processes pending alerts and delivers via Teams webhook |
| Tools | Tools.BDLImport | BDLImport-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\BDLImport-API.ps1 | cc | LOCAL |  | BDL Import CC API endpoints |
| Tools | Tools.BDLImport | bdl-import.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\bdl-import.css | cc | LOCAL |  | BDL Import CC styles |
| Tools | Tools.BDLImport | bdl-import.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\bdl-import.js | cc | LOCAL |  | BDL Import CC client-side logic |
| Tools | Tools.BDLImport | BDLImport.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\BDLImport.ps1 | cc | LOCAL |  | BDL Import CC page route |
| Tools | Tools.ClientPortal | ClientPortal-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\ClientPortal-API.ps1 | cc | LOCAL |  | Client Portal CC API endpoints — search, consumer/account detail, lookups |
| Tools | Tools.ClientPortal | client-portal.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\client-portal.css | cc | LOCAL |  | Client Portal CC styles — dark chrome with light-themed portal content area |
| Tools | Tools.ClientPortal | client-portal.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\client-portal.js | cc | LOCAL |  | Client Portal CC client-side logic — navigation, rendering, lookup resolution |
| Tools | Tools.ClientPortal | ClientPortal.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\ClientPortal.ps1 | cc | LOCAL |  | Client Portal CC page route — consumer and account lookup |
| Tools | Tools.Operations | AccessConfig | Database | Table | Tools |  |  |  | Controls which tools and entity types are available per department. Admin tier users bypass department filtering. |
| Tools | Tools.Operations | AccessFieldConfig | Database | Table | Tools |  |  |  | Department-scoped field-level whitelist for BDL entity access. Child of AccessConfig. |
| Tools | Tools.Operations | BDL_ImportLog | Database | Table | Tools |  |  |  | Audit trail for BDL import executions. One row per import capturing the full lifecycle from validation through DM submission. |
| Tools | Tools.Operations | BDL_ImportTemplate | Database | Table | Tools |  |  |  | Saved column mapping templates for BDL Import. Stores reusable source-to-element field mappings per entity type, allowing users to apply a known file layout without manual column pairing. |
| Tools | Tools.Operations | EnvironmentConfig | Database | Table | Tools |  |  |  | Per-environment configuration for Tools module operations. One row per DM environment with database instance and dmfs file import paths. API URLs sourced from dbo.ServerRegistry. |
| Tools | Tools.Operations | chart.min.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\chart.min.js | cc | LOCAL |  | Chart.js charting library for canvas-based time-series charts |
| Tools | Tools.Operations | chartjs-adapter-date-fns.min.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\chartjs-adapter-date-fns.min.js | cc | LOCAL |  | Chart.js date adapter (self-contained date-fns bundle) for time-scale axes |
| Tools | Tools.Operations | xlsx.full.min.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\xlsx.full.min.js | cc | LOCAL |  | SheetJS library for Excel file parsing |
| Tools | Tools.Utilities | sp_SyncColumnOrdinals | Database | Procedure | Tools |  |  |  | Aligns Object_Metadata column description sort_order values with actual sys.columns column_id ordinals for a specified table. Deactivates Object_Metadata rows for dropped columns. |
| Tools | Tools.Utilities | Invoke-AssetRegistryPipeline.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Invoke-AssetRegistryPipeline.ps1 | standalone | LOCAL |  | Orchestrates the full asset registry pipeline |
| Tools | Tools.Utilities | parse-css.js | PowerShell | Script | E:\xFACts-PowerShell\parse-css.js | standalone | LOCAL |  | Node.js helper script that parses CSS source into structured AST output. Reads CSS from stdin, uses PostCSS 8.5.12 with postcss-selector-parser 7.1.1 to produce JSON containing rules, at-rules, comments, and decomposed selector trees with line numbers. Invoked as a subprocess by Populate-AssetRegistry-CSS.ps1 during catalog refresh. |
| Tools | Tools.Utilities | parse-js.js | PowerShell | Script | E:\xFACts-PowerShell\parse-js.js | standalone | LOCAL |  | Node.js helper script that parses JavaScript source into structured AST output. Reads JS from stdin, uses Acorn 8.16.0 with acorn-walk 8.3.5 to produce ESTree-format JSON with full source position information. Invoked as a subprocess by Populate-AssetRegistry-JS.ps1 during catalog refresh. |
| Tools | Tools.Utilities | Populate-AssetRegistry-CSS.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Populate-AssetRegistry-CSS.ps1 | standalone | LOCAL |  | Asset_Registry parser pipeline component for CSS source files. Walks every CSS file in the Control Center codebase, parses each via the parse-css.js Node helper, and emits one Asset_Registry row per cataloged construct. Validates each row against CC_CSS_Spec.md rules and attaches drift codes for any deviation. |
| Tools | Tools.Utilities | Populate-AssetRegistry-HTML.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Populate-AssetRegistry-HTML.ps1 | standalone | LOCAL |  | Asset_Registry parser pipeline component for HTML markup embedded in PowerShell files. Walks every .ps1 and .psm1 file under the Control Center route and helper directories, identifies HTML-emitting constructs, and emits one Asset_Registry row per cataloged HTML construct. Validates each row against CC_HTML_Spec.md rules and attaches drift codes for any deviation. |
| Tools | Tools.Utilities | Populate-AssetRegistry-JS.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Populate-AssetRegistry-JS.ps1 | standalone | LOCAL |  | Asset_Registry parser pipeline component for JavaScript source files. Walks every JS file in the Control Center codebase, parses each via the parse-js.js Node helper, and emits Asset_Registry rows for both JS code constructs and HTML markup found inside template strings. Validates each row against CC_JS_Spec.md rules and attaches drift codes for any deviation. |
| Tools | Tools.Utilities | Populate-AssetRegistry-PS.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Populate-AssetRegistry-PS.ps1 | standalone | LOCAL |  | Asset_Registry parser pipeline component for PowerShell source files. Walks every .ps1 and .psm1 file under the xFACts PowerShell roots, parses each via the native PowerShell AST, and emits one Asset_Registry row per cataloged construct. Validates each row against CC_PS_Spec.md rules and attaches drift codes for any deviation. |
| Tools | Tools.Utilities | Resolve-AssetRegistryReferences.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Resolve-AssetRegistryReferences.ps1 | standalone | LOCAL |  | Cross-spec resolution phase of the Asset_Registry pipeline. Runs after the four populators have written DEFINITION and USAGE rows. Resolves every cross-spec USAGE row's source_file and scope against matching DEFINITION rows; emits edge-specific drift codes when references cannot be resolved, and a catch-all UNRESOLVED_REFERENCE code on any row that remains in the <pending> state after the resolve phase completes. |
| Tools | Tools.Utilities | xFACts-AssetRegistryFunctions.ps1 | PowerShell | Script | E:\xFACts-PowerShell\xFACts-AssetRegistryFunctions.ps1 | standalone | SHARED | SCOPED | Shared function library for the Asset_Registry parser pipeline. Dot-sourced by every populator in the family. Centralizes row construction, drift code attachment, occurrence-index computation, registry loads, bulk insert, banner detection and parsing, file-header parsing, pre-built section list construction, and the generic AST visitor walker. Per-language logic stays in each populator. |

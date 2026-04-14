# xFACts Platform Registry
Generated: 2026-04-14 13:34:30

## Module Registry

| module_name | description |
| --- | --- |
| BatchOps | Debt Manager batch file loading monitoring |
| BIDATA | Nightly data warehouse build monitoring |
| ControlCenter | Web-based user interface for xFACts |
| dbo | Core platform infrastructure and shared services |
| DeptOps | Departmental operational dashboards |
| DmOps | Debt Manager direct data operations |
| FileOps | Client SFTP file monitoring |
| JBoss | JBoss application server monitoring |
| Jira | Global Jira ticket creation pipeline |
| JobFlow | Debt Manager job and process flow monitoring |
| Orchestrator | xFACts process scheduling and execution engine |
| ServerOps | SQL Server infrastructure health monitoring |
| Teams | Global Microsoft Teams alert delivery pipeline |
| Tools | Shared operational tools and vendor specification catalogs |

## Component Registry

| module_name | component_name | description | doc_page_id | doc_title | doc_json_schema | doc_json_categories | doc_sort_order | doc_section_order |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| BatchOps | BatchOps | Real-time Debt Manager batch processing activity, complete pipeline tracking, and execution history | batchops | Batch Monitoring | BatchOps |  | 80 | 1 |
| BIDATA | BIDATA | Real-time BIDATA nightly build monitoring with process status, duration trending and build history | bidata | BIDATA Monitoring | BIDATA |  | 90 | 1 |
| ControlCenter | ControlCenter.Admin | Administration page: process timeline, engine controls, platform management tools | controlcenter | Administration |  |  |  |  |
| ControlCenter | ControlCenter.Home | Home page and documentation hub |  |  |  |  |  |  |
| ControlCenter | ControlCenter.Platform | Platform Monitoring page: XE event viewer, API request logs | controlcenter | Platform Monitoring |  |  |  |  |
| ControlCenter | ControlCenter.Shared | Shared Control Center infrastructure: startup, helpers module, engine events | controlcenter | Control Center |  |  | 130 | 1 |
| ControlCenter | Documentation.Pipeline | Documentation pipeline: DDL reference generation, Confluence publishing, file consolidation | controlcenter |  | ControlCenter |  |  | 2 |
| ControlCenter | Documentation.Site | Documentation site: navigation, DDL loader, ERD renderer, shared CSS, all HTML narrative/architecture/reference pages | index | xFACts Secrets Revealed |  |  | 0 |  |
| dbo | Engine.RBAC | Role-based access control and tracking | engine-room |  | dbo | RBAC |  | 3 |
| dbo | Engine.SharedInfrastructure | Core platform tables and procedures | engine-room | Engine Room | dbo |  | 10 | 1 |
| DeptOps | DeptOps.ApplicationsIntegration | Applications & Integration departmental page |  |  |  |  |  |  |
| DeptOps | DeptOps.BusinessIntelligence | Business Intelligence departmental page |  |  |  |  |  |  |
| DeptOps | DeptOps.BusinessServices | Business Services departmental page |  |  |  |  |  |  |
| DeptOps | DeptOps.ClientRelations | Client Relations departmental page |  |  |  |  |  |  |
| DmOps | DmOps.Archive | Account-level data archiving with BIDATA capture and consumer shell cleanup | dmops | DM Operations | DmOps |  | 105 | 1 |
| DmOps | DmOps.ShellPurge | Consumer shell purge — removes orphaned consumer records with no remaining accounts from crs5_oltp | dmops | DM Operations | DmOps |  |  |  |
| FileOps | FileOps | Real-time SFTP file tracking and escalation management | fileops | File Monitoring | FileOps |  | 100 | 1 |
| JBoss | JBoss | Real-time JBoss application server health monitoring and management metrics | jboss | JBoss Monitoring | JBoss |  | 60 | 1 |
| Jira | Jira | Global ticket queue and creation processing | jira | Jira Integration | Jira |  | 120 | 1 |
| JobFlow | JobFlow | Real-time Debt Manager job and flow level queue activity, flow and ad-hoc job tracking, and execution history | jobflow | Job/Flow Monitoring | JobFlow |  | 70 | 1 |
| Orchestrator | Engine.Orchestrator | Process orchestration engine with version tracking, credential management, and DDL protection  | engine-room |  | Orchestrator |  |  | 2 |
| ServerOps | ServerOps.Backup | Real-time SQL backup monitoring, network copy, AWS upload, retention management, and storage utilization | backup | Backup Monitoring | ServerOps | Backup | 40 | 1 |
| ServerOps | ServerOps.DBCC | Scheduled DBCC integrity operations with per-database scheduling, on-demand execution, constraint tracking, and alerting | dbcc | DBCC Operations | ServerOps | DBCC | 55 | 1 |
| ServerOps | ServerOps.Disk | Disk space monitoring and health summary alerts |  |  |  |  |  |  |
| ServerOps | ServerOps.Index | Real-time index queue management, Index discovery, fragmentation scanning, priority-based rebuilds, and statistics maintenance | indexmaint | Index Maintenance | ServerOps | Index | 50 | 1 |
| ServerOps | ServerOps.Replication | Real-time metrics for agent health, queue depth, end-to-end latency, delivery rate and event tracking | replication | Replication Monitoring | ServerOps | Replication | 30 | 1 |
| ServerOps | ServerOps.ServerHealth | Real-time SQL Server performance and Activity monitoring, XE event capture, disk health, and server diagnostics | serverhealth | Server Health | ServerOps | Activity,Disk | 20 | 1 |
| Teams | Teams | Global webhook alert queue and delivery processing | teams | Teams Integration | Teams |  | 110 | 1 |
| Tools | Tools.Catalog | Vendor specification catalogs for API endpoints, XML schemas, and data formats | tools | Tools | Tools |  | 140 | 1 |
| Tools | Tools.Operations | Operational infrastructure for DM integration tools — server configuration, access control, and import tracking |  |  |  |  |  |  |
| Tools | Tools.Utilities | Platform maintenance utilities for metadata management, data hygiene, and operational tooling |  |  |  |  |  |  |

## Object Registry

| component_name | object_name | object_category | object_type | object_path | description |
| --- | --- | --- | --- | --- | --- |
| BatchOps | BDL_BatchTracking | Database | Table |  | BDL import lifecycle tracking table with partition-based progress tracking, DM summary count capture, and stall detection. |
| BatchOps | NB_BatchTracking | Database | Table | BatchOps | NewBatch batch processing status tracking |
| BatchOps | PMT_BatchTracking | Database | Table | BatchOps | PMT batch processing status tracking |
| BatchOps | Status | Database | Table | BatchOps | Batch status code definitions |
| BatchOps | Collect-BDLBatchStatus.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-BDLBatchStatus.ps1 | Collects BDL batch processing status with partition-based progress tracking, DM summary count capture, and stall detection. |
| BatchOps | Collect-NBBatchStatus.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-NBBatchStatus.ps1 | Collects NewBatch processing status |
| BatchOps | Collect-PMTBatchStatus.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-PMTBatchStatus.ps1 | Collects PMT processing status |
| BatchOps | Send-OpenBatchSummary.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Send-OpenBatchSummary.ps1 | Evaluates open batches and queues summary alert |
| BatchOps | BatchMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\BatchMonitoring-API.ps1 | Batch Monitoring CC API endpoints |
| BatchOps | batch-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\batch-monitoring.css | Batch Monitoring CC styles |
| BatchOps | batch-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\batch-monitoring.js | Batch Monitoring CC client-side logic |
| BatchOps | BatchMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\BatchMonitoring.ps1 | Batch Monitoring CC page route |
| BIDATA | BuildExecution | Database | Table | BIDATA | Nightly BIDATA build execution tracking |
| BIDATA | StepExecution | Database | Table | BIDATA | Build step execution detail |
| BIDATA | Monitor-BIDATABuild.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Monitor-BIDATABuild.ps1 | Monitors BIDATA nightly build and queues alerts |
| BIDATA | BIDATAMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\BIDATAMonitoring-API.ps1 | BIDATA Monitoring CC API endpoints |
| BIDATA | bidata-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\bidata-monitoring.css | BIDATA Monitoring CC styles |
| BIDATA | bidata-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\bidata-monitoring.js | BIDATA Monitoring CC client-side logic |
| BIDATA | BIDATAMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\BIDATAMonitoring.ps1 | BIDATA Monitoring CC page route |
| ControlCenter.Admin | Admin-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\Admin-API.ps1 | Administration CC API endpoints |
| ControlCenter.Admin | admin.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\admin.css | Administration CC styles |
| ControlCenter.Admin | admin.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\admin.js | Administration CC client-side logic |
| ControlCenter.Admin | Admin.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\Admin.ps1 | Administration CC page route |
| ControlCenter.Home | index.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\index.html | Documentation hub page |
| ControlCenter.Home | Home.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\Home.ps1 | Home page route |
| ControlCenter.Platform | PlatformMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\PlatformMonitoring-API.ps1 | Platform Monitoring CC API endpoints |
| ControlCenter.Platform | platform-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\platform-monitoring.css | Platform Monitoring CC styles |
| ControlCenter.Platform | platform-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\platform-monitoring.js | Platform Monitoring CC client-side logic |
| ControlCenter.Platform | PlatformMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\PlatformMonitoring.ps1 | Platform Monitoring CC page route |
| ControlCenter.Shared | server.psd1 | PowerShell | Config | E:\xFACts-ControlCenter\scripts\server.psd1 | Pode server configuration. Sets request timeout to 180 seconds for long-running API operations (e.g., DM App Server firewall commit). |
| ControlCenter.Shared | xFACts-Helpers.psm1 | PowerShell | Module | E:\xFACts-ControlCenter\scripts\modules\xFACts-Helpers.psm1 | Shared helper functions module for all CC pages |
| ControlCenter.Shared | Start-ControlCenter.ps1 | PowerShell | Script | E:\xFACts-ControlCenter\scripts\Start-ControlCenter.ps1 | Control Center Pode server entry point |
| ControlCenter.Shared | engine-events.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\engine-events.css | Shared engine event styles |
| ControlCenter.Shared | engine-events.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\engine-events.js | Shared engine event stream client |
| DeptOps.ApplicationsIntegration | ApplicationsIntegration-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\ApplicationsIntegration-API.ps1 | Applications & Integration CC API endpoints — BDL catalog management |
| DeptOps.ApplicationsIntegration | applications-integration.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\applications-integration.css | Applications & Integration CC styles |
| DeptOps.ApplicationsIntegration | applications-integration.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\applications-integration.js | Applications & Integration CC client-side logic — BDL catalog management panels |
| DeptOps.ApplicationsIntegration | ApplicationsIntegration.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\ApplicationsIntegration.ps1 | Applications & Integration CC page route |
| DeptOps.BusinessIntelligence | BusinessIntelligence-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\BusinessIntelligence-API.ps1 | Business Intelligence CC API endpoints |
| DeptOps.BusinessIntelligence | business-intelligence.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\business-intelligence.css | Business Intelligence CC styles |
| DeptOps.BusinessIntelligence | business-intelligence.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\business-intelligence.js | Business Intelligence CC client-side logic |
| DeptOps.BusinessIntelligence | BusinessIntelligence.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\BusinessIntelligence.ps1 | Business Intelligence CC page route |
| DeptOps.BusinessServices | BS_ReviewRequest_Group | Database | Table | DeptOps | Review request group definitions |
| DeptOps.BusinessServices | BS_ReviewRequest_Tracking | Database | Table | DeptOps | Review request processing tracking |
| DeptOps.BusinessServices | BS_ReviewRequest_User | Database | Table | DeptOps | Review request user assignments |
| DeptOps.BusinessServices | Collect-BSReviewRequests.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-BSReviewRequests.ps1 | Collects Business Services review request data |
| DeptOps.BusinessServices | Distribute-BSReviewRequests.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Distribute-BSReviewRequests.ps1 | Distributes review requests to analysts |
| DeptOps.BusinessServices | BusinessServices-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\BusinessServices-API.ps1 | Business Services CC API endpoints |
| DeptOps.BusinessServices | business-services.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\business-services.css | Business Services CC styles |
| DeptOps.BusinessServices | business-services.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\business-services.js | Business Services CC client-side logic |
| DeptOps.BusinessServices | BusinessServices.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\BusinessServices.ps1 | Business Services CC page route |
| DeptOps.ClientRelations | ClientRelations-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\ClientRelations-API.ps1 | Client Relations CC API endpoints |
| DeptOps.ClientRelations | client-relations.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\client-relations.css | Client Relations CC styles |
| DeptOps.ClientRelations | client-relations.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\client-relations.js | Client Relations CC client-side logic |
| DeptOps.ClientRelations | ClientRelations.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\ClientRelations.ps1 | Client Relations CC page route |
| DmOps.Archive | Archive_BatchDetail | Database | Table | DmOps | Per-table operation detail within each archive batch — delete order, rows affected, duration, and status |
| DmOps.Archive | Archive_BatchLog | Database | Table | DmOps | Batch-level execution summary for archive processing — one row per batch with counts, timing, and status |
| DmOps.Archive | Archive_ConsumerLog | Database | Table | DmOps | Audit trail of every consumer and account archived — tall skinny log for BI cross-reference and reconciliation |
| DmOps.Archive | Archive_Schedule | Database | Table | DmOps | Weekly schedule grid controlling archive execution mode per hour — blocked, full batch, or reduced batch |
| DmOps.Archive | dmops-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\dmops-arch.html | DM Operations architecture documentation page |
| DmOps.Archive | dmops-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\dmops-ref.html | DM Operations reference documentation page |
| DmOps.Archive | dmops.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\dmops.html | DM Operations narrative documentation page |
| DmOps.Archive | Execute-DmArchive.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Execute-DmArchive.ps1 | Account-level archive execution — registry-driven batch deletion of tagged accounts from crs5_oltp |
| DmOps.Archive | DmOperations-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\DmOperations-API.ps1 | DM Operations CC API endpoints |
| DmOps.Archive | dm-operations.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\dm-operations.css | DM Operations CC styles |
| DmOps.Archive | dm-operations.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\dm-operations.js | DM Operations CC client-side logic |
| DmOps.Archive | DmOperations.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\DmOperations.ps1 | DM Operations CC page route |
| DmOps.ShellPurge | ShellPurge_BatchDetail | Database | Table | DmOps | Per-table operation detail within each shell purge batch — delete order, rows affected, duration, and status |
| DmOps.ShellPurge | ShellPurge_BatchLog | Database | Table | DmOps | Batch-level execution summary for shell purge processing — one row per batch with counts, timing, and status |
| DmOps.ShellPurge | ShellPurge_ConsumerLog | Database | Table | DmOps | Audit trail of every consumer purged — batch and consumer ID for reconciliation |
| DmOps.ShellPurge | ShellPurge_ExclusionLog | Database | Table | DmOps | Consumers excluded from shell purge due to qualifying data in tables not covered by the delete sequence — one row per consumer per exclusion reason |
| DmOps.ShellPurge | ShellPurge_Schedule | Database | Table | DmOps | Weekly schedule grid controlling shell purge execution mode per hour — blocked, full batch, or reduced batch |
| DmOps.ShellPurge | Execute-DmShellPurge.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Execute-DmShellPurge.ps1 | Consumer shell purge execution — removes orphaned consumer records with no remaining accounts from crs5_oltp |
| Documentation.Pipeline | Consolidate-UploadFiles.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Consolidate-UploadFiles.ps1 | Collects all platform files into upload folder |
| Documentation.Pipeline | Generate-DDLReference.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Generate-DDLReference.ps1 | Orchestrates DDL reference JSON generation |
| Documentation.Pipeline | Invoke-DocPipeline.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Invoke-DocPipeline.ps1 | Orchestrates the full documentation pipeline |
| Documentation.Pipeline | Publish-ConfluenceDocumentation.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Publish-ConfluenceDocumentation.ps1 | Publishes HTML docs to Confluence and exports markdown |
| Documentation.Pipeline | Publish-GitHubRepository.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Publish-GitHubRepository.ps1 | Publishes all xFACts platform files to GitHub repository via REST API with manifest generation |
| Documentation.Site | docs-architecture.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-architecture.css | Architecture page styles |
| Documentation.Site | docs-base.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-base.css | Documentation site base styles |
| Documentation.Site | docs-controlcenter.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-controlcenter.css | Module Control Center page styles |
| Documentation.Site | docs-erd.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-erd.css | ERD diagram styles |
| Documentation.Site | docs-hub.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-hub.css | Documentation hub page styles |
| Documentation.Site | docs-narrative.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-narrative.css | Narrative page styles |
| Documentation.Site | docs-reference.css | Documentation | CSS | E:\xFACts-ControlCenter\public\docs\css\docs-reference.css | Reference page styles |
| Documentation.Site | backup-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\backup-arch.html | Backup architecture page |
| Documentation.Site | backup-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\backup-cc.html | Backup Monitoring Control Center guide page |
| Documentation.Site | backup-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\backup-ref.html | Backup DDL reference page |
| Documentation.Site | backup.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\backup.html | Backup narrative page |
| Documentation.Site | batchops-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\batchops-arch.html | BatchOps architecture page |
| Documentation.Site | batchops-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\batchops-cc.html | Batch Monitoring Control Center guide page |
| Documentation.Site | batchops-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\batchops-ref.html | BatchOps DDL reference page |
| Documentation.Site | batchops.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\batchops.html | BatchOps narrative page |
| Documentation.Site | bdl-import-guide.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\guides\bdl-import-guide.html | BDL Import user guide — standalone step-by-step walkthrough |
| Documentation.Site | bidata-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\bidata-arch.html | BIDATA architecture page |
| Documentation.Site | bidata-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\bidata-cc.html | BIDATA Monitoring Control Center guide page |
| Documentation.Site | bidata-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\bidata-ref.html | BIDATA DDL reference page |
| Documentation.Site | bidata.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\bidata.html | BIDATA narrative page |
| Documentation.Site | controlcenter-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\controlcenter-arch.html | Control Center architecture page |
| Documentation.Site | controlcenter-cc-admin.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\controlcenter-cc-admin.html | Administration Control Center guide page |
| Documentation.Site | controlcenter-cc-platform.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\controlcenter-cc-platform.html | Platform Monitoring Control Center guide page |
| Documentation.Site | controlcenter-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\controlcenter-ref.html | Control Center DDL reference page |
| Documentation.Site | controlcenter.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\controlcenter.html | Control Center narrative page |
| Documentation.Site | dbcc-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\dbcc-arch.html | DBCC Operations architecture page |
| Documentation.Site | dbcc-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\dbcc-ref.html | DBCC Operations DDL reference page |
| Documentation.Site | dbcc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\dbcc.html | DBCC Operations narrative page |
| Documentation.Site | engine-room-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\engine-room-arch.html | Engine Room architecture page |
| Documentation.Site | engine-room-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\engine-room-ref.html | Engine Room DDL reference page |
| Documentation.Site | engine-room.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\engine-room.html | Engine Room narrative page |
| Documentation.Site | fileops-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\fileops-arch.html | FileOps architecture page |
| Documentation.Site | fileops-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\fileops-cc.html | File Monitoring Control Center guide page |
| Documentation.Site | fileops-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\fileops-ref.html | FileOps DDL reference page |
| Documentation.Site | fileops.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\fileops.html | FileOps narrative page |
| Documentation.Site | indexmaint-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\indexmaint-arch.html | Index Maintenance architecture page |
| Documentation.Site | indexmaint-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\indexmaint-cc.html | Index Maintenance Control Center guide page |
| Documentation.Site | indexmaint-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\indexmaint-ref.html | Index Maintenance DDL reference page |
| Documentation.Site | indexmaint.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\indexmaint.html | Index Maintenance narrative page |
| Documentation.Site | jboss-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\jboss-arch.html | JBoss Monitoring architecture page |
| Documentation.Site | jboss-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\jboss-cc.html | JBoss Monitoring Control Center guide page |
| Documentation.Site | jboss-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\jboss-ref.html | JBoss Monitoring DDL reference page |
| Documentation.Site | jboss.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\jboss.html | JBoss Monitoring narrative page |
| Documentation.Site | jira-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\jira-arch.html | Jira architecture page |
| Documentation.Site | jira-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\jira-ref.html | Jira DDL reference page |
| Documentation.Site | jira.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\jira.html | Jira narrative page |
| Documentation.Site | jobflow-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\jobflow-arch.html | JobFlow architecture page |
| Documentation.Site | jobflow-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\jobflow-cc.html | JobFlow Monitoring Control Center guide page |
| Documentation.Site | jobflow-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\jobflow-ref.html | JobFlow DDL reference page |
| Documentation.Site | jobflow.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\jobflow.html | JobFlow narrative page |
| Documentation.Site | replication-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\replication-arch.html | Replication architecture page |
| Documentation.Site | replication-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\replication-cc.html | Replication Monitoring Control Center guide page |
| Documentation.Site | replication-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\replication-ref.html | Replication DDL reference page |
| Documentation.Site | replication.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\replication.html | Replication narrative page |
| Documentation.Site | serverhealth-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\serverhealth-arch.html | ServerHealth architecture page |
| Documentation.Site | serverhealth-cc.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\cc\serverhealth-cc.html | ServerHealth Control Center guide page |
| Documentation.Site | serverhealth-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\serverhealth-ref.html | ServerHealth DDL reference page |
| Documentation.Site | serverhealth.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\serverhealth.html | ServerHealth narrative page |
| Documentation.Site | teams-arch.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\arch\teams-arch.html | Teams architecture page |
| Documentation.Site | teams-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\teams-ref.html | Teams DDL reference page |
| Documentation.Site | teams.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\teams.html | Teams narrative page |
| Documentation.Site | tools-ref.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\ref\tools-ref.html | Tools DDL reference page |
| Documentation.Site | tools.html | Documentation | HTML | E:\xFACts-ControlCenter\public\docs\pages\tools.html | Tools narrative page |
| Documentation.Site | ddl-erd.js | Documentation | JavaScript | E:\xFACts-ControlCenter\public\docs\js\ddl-erd.js | ERD diagram renderer |
| Documentation.Site | ddl-loader.js | Documentation | JavaScript | E:\xFACts-ControlCenter\public\docs\js\ddl-loader.js | DDL reference JSON loader and renderer |
| Documentation.Site | docs-controlcenter.js | Documentation | JavaScript | E:\xFACts-ControlCenter\public\docs\js\docs-controlcenter.js | CC guide page interactive behavior and slideout panel |
| Documentation.Site | nav.js | Documentation | JavaScript | E:\xFACts-ControlCenter\public\docs\js\nav.js | Documentation site navigation |
| Engine.Orchestrator | CycleLog | Database | Table | Orchestrator | Orchestrator heartbeat cycle log |
| Engine.Orchestrator | ProcessRegistry | Database | Table | Orchestrator | Registered processes with schedules and run modes |
| Engine.Orchestrator | TaskLog | Database | Table | Orchestrator | Individual process execution records |
| Engine.Orchestrator | Start-xFACtsOrchestrator.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Start-xFACtsOrchestrator.ps1 | Main orchestrator engine entry point |
| Engine.Orchestrator | xFACts-OrchestratorFunctions.ps1 | PowerShell | Script | E:\xFACts-PowerShell\xFACts-OrchestratorFunctions.ps1 | Shared orchestrator function library |
| Engine.RBAC | RBAC_ActionGrant | Database | Table | dbo | Granted actions per user |
| Engine.RBAC | RBAC_ActionRegistry | Database | Table | dbo | Defined actions available for granting |
| Engine.RBAC | RBAC_AuditLog | Database | Table | dbo | RBAC change audit trail |
| Engine.RBAC | RBAC_DepartmentRegistry | Database | Table | dbo | Department definitions for access scoping |
| Engine.RBAC | RBAC_PermissionMapping | Database | Table | dbo | Role-to-page route access mappings |
| Engine.RBAC | RBAC_Role | Database | Table | dbo | Defined access roles |
| Engine.RBAC | RBAC_RoleMapping | Database | Table | dbo | User-to-role assignments |
| Engine.SharedInfrastructure | TR_xFACts_ProtectCriticalObjects | Database | DDL Trigger | dbo | DDL trigger preventing DROP/ALTER on protected objects |
| Engine.SharedInfrastructure | sp_AddHoliday | Database | Procedure | dbo | Adds a single holiday entry |
| Engine.SharedInfrastructure | sp_GenerateHolidays | Database | Procedure | dbo | Generates holiday entries for a given year |
| Engine.SharedInfrastructure | sp_LogProtectionViolation | Database | Procedure | dbo | Logs blocked DDL operations to Protection_ViolationLog |
| Engine.SharedInfrastructure | ActionAuditLog | Database | Table | dbo | Audit trail for Control Center administrative actions |
| Engine.SharedInfrastructure | API_RequestLog | Database | Table | dbo | HTTP request logging for Control Center API endpoints |
| Engine.SharedInfrastructure | Component_Registry | Database | Table | dbo | Logical component grouping catalog |
| Engine.SharedInfrastructure | Credentials | Database | Table | dbo | Encrypted credential storage for service accounts |
| Engine.SharedInfrastructure | CredentialServices | Database | Table | dbo | Service-to-credential mapping |
| Engine.SharedInfrastructure | DatabaseRegistry | Database | Table | dbo | Registered databases for monitoring enrollment |
| Engine.SharedInfrastructure | GlobalConfig | Database | Table | dbo | Runtime configuration settings for all modules |
| Engine.SharedInfrastructure | Holiday | Database | Table | dbo | Holiday calendar for scheduling decisions |
| Engine.SharedInfrastructure | Module_Registry | Database | Table | dbo | Module definitions completing the Module ? Component ? Object hierarchy |
| Engine.SharedInfrastructure | Object_Metadata | Database | Table | dbo | Documentation content for all database objects and scripts |
| Engine.SharedInfrastructure | Object_Registry | Database | Table | dbo | Complete object inventory linked to components |
| Engine.SharedInfrastructure | Protection_ViolationLog | Database | Table | dbo | Blocked DDL operations on protected objects |
| Engine.SharedInfrastructure | ServerRegistry | Database | Table | dbo | Registered SQL Server instances |
| Engine.SharedInfrastructure | System_Metadata | Database | Table | dbo | Component version changelog |
| FileOps | sp_AddNewMonitorConfig | Database | Procedure | FileOps | Adds a new file monitoring configuration entry |
| FileOps | MonitorConfig | Database | Table | FileOps | SFTP file monitoring configuration |
| FileOps | MonitorLog | Database | Table | FileOps | File monitoring event log |
| FileOps | MonitorStatus | Database | Table | FileOps | Current monitoring status per configuration |
| FileOps | ServerConfig | Database | Table | FileOps | SFTP server connection configuration |
| FileOps | Scan-SFTPFiles.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Scan-SFTPFiles.ps1 | Scans SFTP directories for expected files |
| FileOps | FileMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\FileMonitoring-API.ps1 | File Monitoring CC API endpoints |
| FileOps | file-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\file-monitoring.css | File Monitoring CC styles |
| FileOps | file-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\file-monitoring.js | File Monitoring CC client-side logic |
| FileOps | FileMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\FileMonitoring.ps1 | File Monitoring CC page route |
| JBoss | ConfigHistory | Database | Table | JBoss | JBoss configuration change detection for application servers |
| JBoss | QueueSnapshot | Database | Table | JBoss | Per-queue JMS metrics for JBoss application servers |
| JBoss | Snapshot | Database | Table | JBoss | Append-only point-in-time health snapshots per JBoss application server per collection cycle |
| JBoss | Collect-JBossMetrics.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-JBossMetrics.ps1 | JBoss Management API metrics collector for application servers |
| JBoss | JBossMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\JBossMonitoring-API.ps1 | JBoss Monitoring CC API endpoints |
| JBoss | jboss-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\jboss-monitoring.css | JBoss Monitoring CC styles |
| JBoss | jboss-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\jboss-monitoring.js | JBoss Monitoring CC client-side logic |
| JBoss | JBossMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\JBossMonitoring.ps1 | JBoss Monitoring CC page route |
| Jira | sp_QueueTicket | Database | Procedure | Jira | Queues a new ticket for Jira creation |
| Jira | RequestLog | Database | Table | Jira | Jira API request attempt log |
| Jira | TicketQueue | Database | Table | Jira | Queued Jira tickets awaiting creation |
| Jira | TR_Jira_TicketQueue_QueueDepth | Database | Trigger | Jira | Monitors ticket queue depth and raises warnings |
| Jira | Process-JiraTicketQueue.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Process-JiraTicketQueue.ps1 | Processes pending tickets and creates via Jira API |
| JobFlow | ErrorCategory | Database | Table | JobFlow | Error category definitions |
| JobFlow | FlowConfig | Database | Table | JobFlow | SSIS flow monitoring configuration |
| JobFlow | FlowExecutionTracking | Database | Table | JobFlow | SSIS package execution tracking |
| JobFlow | JobConfig | Database | Table | JobFlow | SQL Agent job monitoring configuration |
| JobFlow | JobExecutionLog | Database | Table | JobFlow | SQL Agent job execution log |
| JobFlow | JobStatus | Database | Table | JobFlow | Current job status summary |
| JobFlow | Schedule | Database | Table | JobFlow | Expected execution schedules |
| JobFlow | StallDetectionLog | Database | Table | JobFlow | Detected stalled job/flow records |
| JobFlow | Status | Database | Table | JobFlow | Status code definitions |
| JobFlow | ValidationException | Database | Table | JobFlow | Validation exception rules |
| JobFlow | ValidationLog | Database | Table | JobFlow | Validation check results |
| JobFlow | Monitor-JobFlow.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Monitor-JobFlow.ps1 | Monitors job/flow executions and queues alerts |
| JobFlow | JobFlowMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\JobFlowMonitoring-API.ps1 | JobFlow Monitoring CC API endpoints |
| JobFlow | jobflow-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\jobflow-monitoring.css | JobFlow Monitoring CC styles |
| JobFlow | jobflow-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\jobflow-monitoring.js | JobFlow Monitoring CC client-side logic |
| JobFlow | JobFlowMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\JobFlowMonitoring.ps1 | JobFlow Monitoring CC page route |
| ServerOps.Backup | Backup_DatabaseConfig | Database | Table | ServerOps | Per-database backup configuration and policies |
| ServerOps.Backup | Backup_ExecutionLog | Database | Table | ServerOps | Backup execution records |
| ServerOps.Backup | Backup_FileTracking | Database | Table | ServerOps | Tracks backup files through copy/upload/retention lifecycle |
| ServerOps.Backup | Collect-BackupStatus.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-BackupStatus.ps1 | Collects backup status from all enrolled servers |
| ServerOps.Backup | Process-BackupAWSUpload.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Process-BackupAWSUpload.ps1 | Uploads backup files to AWS S3 |
| ServerOps.Backup | Process-BackupNetworkCopy.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Process-BackupNetworkCopy.ps1 | Copies backup files to network share |
| ServerOps.Backup | Process-BackupRetention.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Process-BackupRetention.ps1 | Manages backup file retention and cleanup |
| ServerOps.Backup | Backup-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\Backup-API.ps1 | Backup Monitoring CC API endpoints |
| ServerOps.Backup | backup.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\backup.css | Backup Monitoring CC styles |
| ServerOps.Backup | backup.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\backup.js | Backup Monitoring CC client-side logic |
| ServerOps.Backup | Backup.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\Backup.ps1 | Backup Monitoring CC page route |
| ServerOps.DBCC | DBCC_ExecutionLog | Database | Table | ServerOps | DBCC operation execution history — one row per database per operation per run |
| ServerOps.DBCC | DBCC_ScheduleConfig | Database | Table | ServerOps | Per-database DBCC operation scheduling — one row per database with independent day/time per operation |
| ServerOps.DBCC | Execute-DBCC.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Execute-DBCC.ps1 | Executes scheduled DBCC operations against databases per DBCC_ScheduleConfig. Supports manual targeting via parameters. |
| ServerOps.DBCC | DBCCOperations-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\DBCCOperations-API.ps1 | DBCC Operations CC API endpoints — live progress, today's executions, execution history, schedule overview, schedule editing |
| ServerOps.DBCC | dbcc-operations.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\dbcc-operations.css | DBCC Operations CC styles — viewport-constrained layout, grid sections, modals |
| ServerOps.DBCC | dbcc-operations.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\dbcc-operations.js | DBCC Operations CC client-side logic — live polling, accordion history, schedule modals |
| ServerOps.DBCC | DBCCOperations.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\DBCCOperations.ps1 | DBCC Operations CC page route |
| ServerOps.Disk | Disk_AlertHistory | Database | Table | ServerOps | Disk space alert history |
| ServerOps.Disk | Disk_Snapshot | Database | Table | ServerOps | Point-in-time disk space snapshots |
| ServerOps.Disk | Disk_Status | Database | Table | ServerOps | Current disk space status per drive |
| ServerOps.Disk | Disk_ThresholdConfig | Database | Table | ServerOps | Disk space alert threshold configuration |
| ServerOps.Disk | Collect-ServerHealth.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-ServerHealth.ps1 | Collects server-level health metrics including disk space |
| ServerOps.Disk | Send-DiskHealthSummary.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Send-DiskHealthSummary.ps1 | Evaluates disk space and queues Teams alerts |
| ServerOps.Index | sp_Index_AddDatabaseHolidaySchedule | Database | Procedure | ServerOps | Adds a holiday maintenance window for a database |
| ServerOps.Index | sp_Index_AddDatabaseSchedule | Database | Procedure | ServerOps | Adds a maintenance window schedule for a database |
| ServerOps.Index | Index_DatabaseConfig | Database | Table | ServerOps | Per-database index maintenance configuration |
| ServerOps.Index | Index_DatabaseSchedule | Database | Table | ServerOps | Maintenance window schedules per database |
| ServerOps.Index | Index_ExceptionSchedule | Database | Table | ServerOps | Override schedules for specific date ranges |
| ServerOps.Index | Index_ExecutionLog | Database | Table | ServerOps | Completed rebuild operation records |
| ServerOps.Index | Index_ExecutionSummary | Database | Table | ServerOps | Aggregated execution summary per run |
| ServerOps.Index | Index_HolidaySchedule | Database | Table | ServerOps | Holiday-specific maintenance windows |
| ServerOps.Index | Index_Queue | Database | Table | ServerOps | Priority-ordered queue of indexes awaiting rebuild |
| ServerOps.Index | Index_Registry | Database | Table | ServerOps | Master catalog of all discovered indexes |
| ServerOps.Index | Index_StatsExecutionLog | Database | Table | ServerOps | Statistics update execution records |
| ServerOps.Index | Index_Status | Database | Table | ServerOps | Current index health status |
| ServerOps.Index | Execute-IndexMaintenance.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Execute-IndexMaintenance.ps1 | Window-aware index rebuild execution engine |
| ServerOps.Index | Scan-IndexFragmentation.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Scan-IndexFragmentation.ps1 | Scans physical fragmentation levels |
| ServerOps.Index | Sync-IndexRegistry.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Sync-IndexRegistry.ps1 | Daily discovery and metadata refresh of all indexes |
| ServerOps.Index | Update-IndexStatistics.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Update-IndexStatistics.ps1 | Updates statistics on recently rebuilt indexes |
| ServerOps.Index | xFACts-IndexFunctions.ps1 | PowerShell | Script | E:\xFACts-PowerShell\xFACts-IndexFunctions.ps1 | Shared function library for index operations |
| ServerOps.Index | IndexMaintenance-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\IndexMaintenance-API.ps1 | Index Maintenance CC API endpoints |
| ServerOps.Index | index-maintenance.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\index-maintenance.css | Index Maintenance CC styles |
| ServerOps.Index | index-maintenance.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\index-maintenance.js | Index Maintenance CC client-side logic |
| ServerOps.Index | IndexMaintenance.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\IndexMaintenance.ps1 | Index Maintenance CC page route |
| ServerOps.Replication | Replication_AgentHistory | Database | Table | ServerOps | Replication agent execution history |
| ServerOps.Replication | Replication_EventLog | Database | Table | ServerOps | Replication event log |
| ServerOps.Replication | Replication_LatencyHistory | Database | Table | ServerOps | Historical replication latency measurements |
| ServerOps.Replication | Replication_PublicationRegistry | Database | Table | ServerOps | Replication publication monitoring configuration |
| ServerOps.Replication | Collect-ReplicationHealth.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-ReplicationHealth.ps1 | Collects replication agent status and latency metrics |
| ServerOps.Replication | ReplicationMonitoring-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\ReplicationMonitoring-API.ps1 | Replication Monitoring CC API endpoints |
| ServerOps.Replication | replication-monitoring.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\replication-monitoring.css | Replication Monitoring CC styles |
| ServerOps.Replication | replication-monitoring.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\replication-monitoring.js | Replication Monitoring CC client-side logic |
| ServerOps.Replication | ReplicationMonitoring.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\ReplicationMonitoring.ps1 | Replication Monitoring CC page route |
| ServerOps.ServerHealth | sp_Activity_CorrelateIncidents | Database | Procedure | ServerOps | Correlates DMV anomalies with XE events into incidents |
| ServerOps.ServerHealth | sp_DiagnoseServerHealth | Database | Procedure | ServerOps | Diagnostic analysis combining DMV and XE data |
| ServerOps.ServerHealth | Activity_DMV_ConnectionHealth | Database | Table | ServerOps | Connection health DMV snapshots |
| ServerOps.ServerHealth | Activity_DMV_IO_Stats | Database | Table | ServerOps | I/O statistics DMV snapshots |
| ServerOps.ServerHealth | Activity_DMV_Memory | Database | Table | ServerOps | Memory DMV snapshots |
| ServerOps.ServerHealth | Activity_DMV_WaitStats | Database | Table | ServerOps | Wait statistics DMV snapshots |
| ServerOps.ServerHealth | Activity_DMV_Workload | Database | Table | ServerOps | Workload DMV snapshots |
| ServerOps.ServerHealth | Activity_DMV_xFACts | Database | Table | ServerOps | xFACts-specific DMV snapshots |
| ServerOps.ServerHealth | Activity_Heartbeat | Database | Table | ServerOps | Server heartbeat tracking |
| ServerOps.ServerHealth | Activity_IncidentLog | Database | Table | ServerOps | Correlated incident records |
| ServerOps.ServerHealth | Activity_IncidentType | Database | Table | ServerOps | Incident type definitions |
| ServerOps.ServerHealth | Activity_XE_AGHealth | Database | Table | ServerOps | Always On availability group health events |
| ServerOps.ServerHealth | Activity_XE_BlockedProcess | Database | Table | ServerOps | Blocked process extended events |
| ServerOps.ServerHealth | Activity_XE_CollectionState | Database | Table | ServerOps | XE session collection state tracking |
| ServerOps.ServerHealth | Activity_XE_Deadlock | Database | Table | ServerOps | Deadlock extended events |
| ServerOps.ServerHealth | Activity_XE_LinkedServerIn | Database | Table | ServerOps | Inbound linked server query events |
| ServerOps.ServerHealth | Activity_XE_LinkedServerOut | Database | Table | ServerOps | Outbound linked server query events |
| ServerOps.ServerHealth | Activity_XE_LRQ | Database | Table | ServerOps | Long-running query extended events |
| ServerOps.ServerHealth | Activity_XE_SystemHealth | Database | Table | ServerOps | System health extended events |
| ServerOps.ServerHealth | Activity_XE_xFACts | Database | Table | ServerOps | xFACts-specific extended events |
| ServerOps.ServerHealth | AlwaysOn_health | Database | XE Session | ServerOps | Always On health XE session definition |
| ServerOps.ServerHealth | system_health | Database | XE Session | ServerOps | System health XE session definition |
| ServerOps.ServerHealth | xFACts_BlockedProcess | Database | XE Session | ServerOps | Blocked process XE session definition |
| ServerOps.ServerHealth | xFACts_Deadlock | Database | XE Session | ServerOps | Deadlock XE session definition |
| ServerOps.ServerHealth | xFACts_LongQueries | Database | XE Session | ServerOps | Long-running query XE session definition |
| ServerOps.ServerHealth | xFACts_LS_Inbound | Database | XE Session | ServerOps | Inbound linked server XE session definition |
| ServerOps.ServerHealth | xFACts_LS_Outbound | Database | XE Session | ServerOps | Outbound linked server XE session definition |
| ServerOps.ServerHealth | xFACts_Tracking | Database | XE Session | ServerOps | xFACts tracking XE session definition |
| ServerOps.ServerHealth | Collect-DMVMetrics.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-DMVMetrics.ps1 | Collects DMV performance snapshots from all enrolled servers |
| ServerOps.ServerHealth | Collect-XEEvents.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Collect-XEEvents.ps1 | Harvests Extended Events data from configured sessions |
| ServerOps.ServerHealth | ServerHealth-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\ServerHealth-API.ps1 | Server Health CC API endpoints |
| ServerOps.ServerHealth | server-health.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\server-health.css | Server Health CC styles |
| ServerOps.ServerHealth | server-health.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\server-health.js | Server Health CC client-side logic |
| ServerOps.ServerHealth | ServerHealth.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\ServerHealth.ps1 | Server Health CC page route |
| Teams | sp_QueueAlert | Database | Procedure | Teams | Queues a new alert for Teams delivery |
| Teams | AlertQueue | Database | Table | Teams | Queued Teams webhook alerts awaiting delivery |
| Teams | RequestLog | Database | Table | Teams | Teams webhook delivery attempt log |
| Teams | WebhookConfig | Database | Table | Teams | Teams webhook channel configuration |
| Teams | WebhookSubscription | Database | Table | Teams | Module-to-webhook subscription mappings |
| Teams | TR_Teams_AlertQueue_QueueDepth | Database | Trigger | Teams | Monitors alert queue depth and raises warnings |
| Teams | Process-TeamsAlertQueue.ps1 | PowerShell | Script | E:\xFACts-PowerShell\Process-TeamsAlertQueue.ps1 | Processes pending alerts and delivers via Teams webhook |
| Tools.Catalog | Catalog_ApiRegistry | Database | Table | Tools | REST API endpoint catalog — one row per path+method combination. Parsed from OpenAPI 3.0 YAML specs. |
| Tools.Catalog | Catalog_ApiSchemaRegistry | Database | Table | Tools | REST API schema property catalog — one row per property within each model object. Links to Catalog_ApiRegistry via schema name. |
| Tools.Catalog | Catalog_BDLElementRegistry | Database | Table | Tools | BDL element catalog — one row per element within each entity type. Links to Catalog_BDLFormatRegistry via spec_version + type_name. |
| Tools.Catalog | Catalog_BDLFormatRegistry | Database | Table | Tools | BDL entity type catalog — one row per bulk data load format. Parsed from XSD schema definitions. |
| Tools.Catalog | Catalog_CDLElementRegistry | Database | Table | Tools | CDL element catalog — one row per element within each entity type. Links to Catalog_CDLFormatRegistry via spec_version + type_name. |
| Tools.Catalog | Catalog_CDLFormatRegistry | Database | Table | Tools | CDL entity type catalog — one row per configuration data format. Parsed from XSD schema definitions. |
| Tools.Operations | AccessConfig | Database | Table | Tools | Controls which tools and entity types are available per department. Admin tier users bypass department filtering. |
| Tools.Operations | AccessFieldConfig | Database | Table | Tools | Department-scoped field-level whitelist for BDL entity access. Child of AccessConfig. |
| Tools.Operations | BDL_ImportLog | Database | Table | Tools | Audit trail for BDL import executions. One row per import capturing the full lifecycle from validation through DM submission. |
| Tools.Operations | BDL_ImportTemplate | Database | Table | Tools | Saved column mapping templates for BDL Import. Stores reusable source-to-element field mappings per entity type, allowing users to apply a known file layout without manual column pairing. |
| Tools.Operations | EnvironmentConfig | Database | Table | Tools | Per-environment configuration for Tools module operations. One row per DM environment with database instance and dmfs file import paths. API URLs sourced from dbo.ServerRegistry. |
| Tools.Operations | BDLImport-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\BDLImport-API.ps1 | BDL Import CC API endpoints |
| Tools.Operations | ClientPortal-API.ps1 | WebAsset | API | E:\xFACts-ControlCenter\scripts\routes\ClientPortal-API.ps1 | Client Portal CC API endpoints — search, consumer/account detail, lookups |
| Tools.Operations | bdl-import.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\bdl-import.css | BDL Import CC styles |
| Tools.Operations | client-portal.css | WebAsset | CSS | E:\xFACts-ControlCenter\public\css\client-portal.css | Client Portal CC styles — dark chrome with light-themed portal content area |
| Tools.Operations | bdl-import.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\bdl-import.js | BDL Import CC client-side logic |
| Tools.Operations | client-portal.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\client-portal.js | Client Portal CC client-side logic — navigation, rendering, lookup resolution |
| Tools.Operations | xlsx.full.min.js | WebAsset | JavaScript | E:\xFACts-ControlCenter\public\js\xlsx.full.min.js | SheetJS library for Excel file parsing (BDL Import) |
| Tools.Operations | BDLImport.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\BDLImport.ps1 | BDL Import CC page route |
| Tools.Operations | ClientPortal.ps1 | WebAsset | Route | E:\xFACts-ControlCenter\scripts\routes\ClientPortal.ps1 | Client Portal CC page route — consumer and account lookup |
| Tools.Utilities | sp_SyncColumnOrdinals | Database | Procedure | Tools | Aligns Object_Metadata column description sort_order values with actual sys.columns column_id ordinals for a specified table. Deactivates Object_Metadata rows for dropped columns. |

## Global Configuration

| module_name | category | setting_name | setting_value | data_type | description |
| --- | --- | --- | --- | --- | --- |
| BatchOps | BDL | bdl_alert_failed_routing | 3 | ALERT_MODE | Alert destination(s) when a BDL file reaches FAILED status in File_Registry |
| BatchOps | BDL | bdl_alert_stall_routing | 1 | ALERT_MODE | Alert destination(s) when BDL partition processing stalls |
| BatchOps | BDL | bdl_alerting_enabled | 0 | BIT | Master on/off switch for all BDL batch alerting |
| BatchOps | BDL | bdl_lookback_days | 7 | INT | How many days back xFACts checks DM for BDL file collection |
| BatchOps | BDL | bdl_stall_poll_threshold | 12 | INT | Consecutive idle polls with no new partition activity before stall alert |
| BatchOps | NB | nb_alert_queue_wait_no_merge_routing | 1 | ALERT_MODE | Alert destination(s) when non-auto-merge batches exceed threshold |
| BatchOps | NB | nb_alert_queue_wait_routing | 1 | ALERT_MODE | Alert destination(s) when batches wait in merge queue with no activity |
| BatchOps | NB | nb_alert_release_failed_routing | 3 | ALERT_MODE | Alert destination(s) when a batch release fails |
| BatchOps | NB | nb_alert_release_merge_skip_routing | 1 | ALERT_MODE | Alert destination(s) when release-merge processing stalls |
| BatchOps | NB | nb_alert_stalled_merge_routing | 1 | ALERT_MODE | Alert destination(s) when merge processing stalls |
| BatchOps | NB | nb_alert_unreleased_routing | 1 | ALERT_MODE | Alert destination(s) when unreleased batches exceed threshold |
| BatchOps | NB | nb_alert_upload_failed_routing | 3 | ALERT_MODE | Alert destination(s) when a batch upload fails |
| BatchOps | NB | nb_alert_upload_stall_routing | 1 | ALERT_MODE | Alert destination(s) when batch upload processing stalls |
| BatchOps | NB | nb_alerting_enabled | 1 | BIT | Master on/off switch for all NB batch alerting |
| BatchOps | NB | nb_lookback_days | 7 | INT | How many days back xFACts checks DM for new business batch collection |
| BatchOps | NB | nb_queue_wait_minutes | 300 | INT | Minutes a batch can wait in merge queue before alerting |
| BatchOps | NB | nb_queue_wait_no_merge_minutes | 1440 | INT | Minutes a non-auto-merge batch can wait before alerting |
| BatchOps | NB | nb_release_merge_skip_stall_threshold | 24 | INT | Consecutive idle polls before release-merge stall alert |
| BatchOps | NB | nb_stall_poll_threshold | 24 | INT | Consecutive idle polls before merge stall alert |
| BatchOps | NB | nb_unreleased_minutes | 480 | INT | Minutes unreleased before alerting (manual release required) |
| BatchOps | NB | nb_upload_stall_minutes | 120 | INT | Minutes in uploading status before upload stall alert |
| BatchOps | PMT | pmt_alert_failed_routing | 3 | ALERT_MODE | Alert destination(s) when a payment batch fails |
| BatchOps | PMT | pmt_alert_import_failed_routing | 3 | ALERT_MODE | Alert destination(s) when a payment import fails |
| BatchOps | PMT | pmt_alert_partial_routing | 3 | ALERT_MODE | Alert destination(s) for partial payment failures |
| BatchOps | PMT | pmt_alert_reversal_failed_routing | 1 | ALERT_MODE | Alert destination(s) when a payment reversal fails |
| BatchOps | PMT | pmt_alerting_enabled | 1 | BIT | Master on/off switch for all PMT batch alerting |
| BatchOps | PMT | pmt_lookback_days | 7 | INT | How many days back xFACts checks DM for payment batch collection |
| BIDATA |  | bidata_build_job_name | BIDATA Daily Build | VARCHAR | SQL Agent job name to monitor for the nightly build |
| BIDATA |  | bidata_build_source_server | DM-PROD-REP | VARCHAR | Server where the nightly BIDATA build runs |
| BIDATA |  | bidata_build_start_grace_minutes | 15 | INT | Minutes after scheduled start before alerting that the build has not started |
| ControlCenter | ApiCache | cache_ttl_default_seconds | 600 | INT | Default cache duration for API responses (seconds) |
| ControlCenter | ApiCache.ClientRelations | cache_ttl_regf_queue_seconds | 300 | INT | Cache duration for Client Relations Reg F queue data (seconds) |
| ControlCenter | Connection | refresh_idle_timeout_seconds | 240 | INT | Seconds of inactivity before dashboard pauses and shows idle overlay |
| ControlCenter | Connection | refresh_reconnect_grace_seconds | 60 | INT | Seconds to show reconnecting banner before displaying an error |
| ControlCenter | RBAC | rbac_audit_verbosity | all | VARCHAR | What access checks to log: denials_only or all |
| ControlCenter | RBAC | rbac_enforcement_mode | audit | VARCHAR | Access control mode: disabled, audit (log only), or enforce (block) |
| ControlCenter | Refresh | refresh_backup_seconds | 5 | INT | Backup Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_batch_seconds | 5 | INT | Batch Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_bidata_seconds | 30 | INT | BIDATA Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_businessservices_seconds | 60 | INT | Business Services page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_clientrelations_seconds | 1800 | INT | Client Relations page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_dbcc-operations_seconds | 5 | INT | DBCC Operations page refresh live window interval (seconds) |
| ControlCenter | Refresh | refresh_fileops_seconds | 30 | INT | File Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_indexmaintenance_seconds | 5 | INT | Index Maintenance page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_jboss_monitoring_seconds | 60 | INT | Auto-refresh interval for the JBoss Monitoring page |
| ControlCenter | Refresh | refresh_jobflow_seconds | 10 | INT | JobFlow Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_replication_seconds | 10 | INT | Replication Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_serverhealth_seconds | 5 | INT | Server Health page refresh live window interval (seconds) |
| DeptOps | ApplicationsIntegration | cooldown_balance_sync_seconds | 3600 | INT | Minimum seconds between Balance Sync executions per environment. Enforced via ActionAuditLog. |
| DeptOps | ApplicationsIntegration | cooldown_release_notices_seconds | 300 | INT | Minimum seconds between Release Notices executions per environment. Enforced via ActionAuditLog. |
| DeptOps | BS_ReviewRequest | bs_default_assignment_cap | 100 | INT | Default max assignments for new distribution users |
| DeptOps | BS_ReviewRequest | bs_distribution_enabled | 1 | BIT | Master on/off switch for automated review request distribution |
| DmOps | Archive | alerting_enabled | 0 | BIT | Master switch for archive alerting: 1 = Teams alerts active, 0 = alerting suppressed. Does not affect archive execution. |
| DmOps | Archive | archive_abort | 0 | BIT | Emergency shutoff: 1 = stop after current batch completes. Overrides schedule and enabled flag. Reset to 0 manually after investigation. |
| DmOps | Archive | batch_size | 25000 | INT | Number of consumers per batch during full-mode schedule windows |
| DmOps | Archive | batch_size_reduced | 500 | INT | Number of consumers per batch during reduced-mode schedule windows |
| DmOps | Archive | bidata_build_job_name | BIDATA Daily Build | VARCHAR | SQL Agent job name for the BIDATA Daily Build. Used by pre-flight check to detect build-in-progress on bidata_instance server. |
| DmOps | Archive | bidata_instance | DM-TEST-APP | VARCHAR | SQL Server instance hosting the BIDATA database for P-to-C migration. Production: DM-PROD-REP. |
| DmOps | Archive | chunk_size | 5000 | INT | Maximum rows per DELETE operation — larger tables are deleted in chunks of this size |
| DmOps | Archive | target_instance | DM-TEST-APP | VARCHAR | SQL Server instance hosting crs5_oltp for archive processing |
| DmOps | ShellPurge | alerting_enabled | 0 | BIT | Master switch for shell purge alerting: 1 = Teams alerts active, 0 = alerting suppressed |
| DmOps | ShellPurge | batch_size | 25000 | INT | Number of shell consumers per batch during full-mode schedule windows |
| DmOps | ShellPurge | batch_size_reduced | 500 | INT | Number of shell consumers per batch during reduced-mode schedule windows |
| DmOps | ShellPurge | chunk_size | 5000 | INT | Maximum rows per DELETE operation — larger tables are deleted in chunks of this size |
| DmOps | ShellPurge | shell_purge_abort | 0 | BIT | Emergency shutoff: 1 = stop after current batch completes. Reset to 0 manually after investigation. |
| DmOps | ShellPurge | target_instance | DM-TEST-APP | VARCHAR | SQL Server instance hosting crs5_oltp for shell purge processing |
| FileOps | Detection | cda_base_path | \\kingkong\dpbackup\Client_Data_Archive | VARCHAR | UNC path to Client Data Archive (fallback location when files not found on SFTP) |
| JBoss | Admin | dm_sharepoint_active_server | DM-PROD-APP2 | VARCHAR | Currently active DM app server in the SharePoint navigation link. |
| JBoss | Admin | management_api_url | http://dm-prod-app:9990/management | VARCHAR | JBoss Management API base URL on the domain controller. Used by Collect-DmHealthMetrics.ps1 for all Management API calls. |
| JBoss | App | alerting_enabled | 0 | BIT | Master on/off switch for DmOps alerting |
| JBoss | App | api_timeout_seconds | 30 | INT | Timeout in seconds for JBoss Management API REST calls |
| JBoss | App | http_base_path | /CRSServicesWeb/ | VARCHAR | URL path appended to server name for HTTP responsiveness. |
| JBoss | App | http_timeout_seconds | 10 | INT | HTTP request timeout for HTTP responsiveness calls |
| JBoss | App | snapshot_retention_days | 90 | INT | Days to retain App_Snapshot history |
| JobFlow | Monitoring | StallThreshold | 6 | INT | Consecutive idle polls before JobFlow process stall alert |
| JobFlow | Monitoring | ValidationRetryEnabled | 1 | BIT | Enable automatic retry of missed flow validations |
| Orchestrator |  | orchestrator_drain_mode | 0 | INT | Drain mode: stops new process launches while in-flight ones finish |
| Orchestrator | Engine | heartbeat_interval_seconds | 60 | INT | Seconds between orchestrator engine heartbeats |
| ServerOps | Activity_DMV | dmv_retention_days | 90 | INT | Days to keep DMV snapshot data |
| ServerOps | Activity_DMV | incident_hadr_spike_critical_ms | 5000000 | INT | AG sync wait spike threshold for critical incidents (milliseconds) |
| ServerOps | Activity_DMV | incident_hadr_spike_warning_ms | 500000 | INT | AG sync wait spike threshold for warning incidents (milliseconds) |
| ServerOps | Activity_DMV | incident_memory_grants_threshold | 5 | INT | Pending memory grants threshold for incidents |
| ServerOps | Activity_DMV | incident_ple_critical_threshold | 100 | INT | Page life expectancy threshold for critical incidents |
| ServerOps | Activity_DMV | incident_ple_warning_threshold | 300 | INT | Page life expectancy threshold for warning incidents |
| ServerOps | Activity_DMV | incident_zombie_warning_threshold | 500 | INT | Zombie connection count threshold for warning incidents |
| ServerOps | Activity_DMV | threshold_blocked_sessions_crisis | 10 | INT | Blocked sessions: crisis threshold |
| ServerOps | Activity_DMV | threshold_blocked_sessions_critical | 5 | INT | Blocked sessions: critical threshold |
| ServerOps | Activity_DMV | threshold_blocked_sessions_warning | 1 | INT | Blocked sessions: warning threshold |
| ServerOps | Activity_DMV | threshold_buffer_cache_crisis | 80 | INT | Buffer cache hit ratio: crisis threshold (%) |
| ServerOps | Activity_DMV | threshold_buffer_cache_critical | 95 | INT | Buffer cache hit ratio: critical threshold (%) |
| ServerOps | Activity_DMV | threshold_buffer_cache_warning | 99 | INT | Buffer cache hit ratio: warning threshold (%) |
| ServerOps | Activity_DMV | threshold_hadr_sync_critical_ms | 5000000 | INT | AG sync wait: critical threshold (milliseconds) |
| ServerOps | Activity_DMV | threshold_hadr_sync_warning_ms | 500000 | INT | AG sync wait: warning threshold (milliseconds) |
| ServerOps | Activity_DMV | threshold_lazy_writes_crisis | 100 | INT | Lazy writes/sec: crisis threshold |
| ServerOps | Activity_DMV | threshold_lazy_writes_critical | 50 | INT | Lazy writes/sec: critical threshold |
| ServerOps | Activity_DMV | threshold_lazy_writes_warning | 20 | INT | Lazy writes/sec: warning threshold |
| ServerOps | Activity_DMV | threshold_memory_grants_crisis | 10 | INT | Pending memory grants: crisis threshold |
| ServerOps | Activity_DMV | threshold_memory_grants_critical | 5 | INT | Pending memory grants: critical threshold |
| ServerOps | Activity_DMV | threshold_memory_grants_warning | 1 | INT | Pending memory grants: warning threshold |
| ServerOps | Activity_DMV | threshold_open_trans_crisis | 10 | INT | Idle open transactions: crisis threshold |
| ServerOps | Activity_DMV | threshold_open_trans_critical | 5 | INT | Idle open transactions: critical threshold |
| ServerOps | Activity_DMV | threshold_open_trans_idle_minutes | 5 | INT | Minutes idle with open transaction before counting |
| ServerOps | Activity_DMV | threshold_open_trans_warning | 1 | INT | Idle open transactions: warning threshold |
| ServerOps | Activity_DMV | threshold_ple_crisis | 100 | INT | Page life expectancy: crisis threshold |
| ServerOps | Activity_DMV | threshold_ple_critical | 300 | INT | Page life expectancy: critical threshold |
| ServerOps | Activity_DMV | threshold_ple_warning | 1000 | INT | Page life expectancy: warning threshold |
| ServerOps | Activity_DMV | threshold_zombie_count_crisis | 800 | INT | Zombie connections: crisis threshold |
| ServerOps | Activity_DMV | threshold_zombie_count_critical | 500 | INT | Zombie connections: critical threshold |
| ServerOps | Activity_DMV | threshold_zombie_count_warning | 200 | INT | Zombie connections: warning threshold |
| ServerOps | Activity_DMV | threshold_zombie_idle_minutes | 60 | INT | Minutes idle before a JDBC session counts as a zombie |
| ServerOps | Activity_XE | aghealth_retain_raw_xml | 1 | BIT | Keep raw XML data for AG health events |
| ServerOps | Activity_XE | blocked_process_retain_raw_xml | 1 | BIT | Keep raw XML data for blocked process events |
| ServerOps | Backup | alert_threshold_aws_pending_min | 30 | INT | Minutes before a pending AWS upload triggers an alert |
| ServerOps | Backup | alert_threshold_network_pending_min | 30 | INT | Minutes before a pending network copy triggers an alert |
| ServerOps | Backup | aws_bucket_name | faitdbredgate | VARCHAR | AWS S3 bucket name for backup uploads |
| ServerOps | Backup | aws_path_prefix | xFACts | VARCHAR | Folder prefix within the AWS S3 bucket |
| ServerOps | Backup | aws_upload_max_retries | 2 | INT | Maximum retry attempts for failed AWS uploads. Total tries = 1 original + this value. |
| ServerOps | Backup | network_backup_root | \\fa-sqldbb\g$\BACKUP\xFACts | VARCHAR | Network share root path for backup copies |
| ServerOps | Backup | network_copy_max_retries | 2 | INT | Maximum retry attempts for failed network copies. Total tries = 1 original + this value. |
| ServerOps | DBCC | dbcc_alerting_enabled | 1 | BIT | Master on/off switch for DBCC alerting. When enabled: Teams alert on any non-SUCCESS, Jira ticket on ERRORS_FOUND |
| ServerOps | DBCC | dbcc_extended_logical_checks | 0 | BIT | Enable EXTENDED_LOGICAL_CHECKS for indexed views, XML indexes, and spatial indexes. Adds execution time. Only relevant with check_type = FULL |
| ServerOps | DBCC | dbcc_max_dop | 4 | INT | MAXDOP for DBCC CHECKDB execution. Higher values use more CPU/IO but complete faster |
| ServerOps | Disk | default_threshold_pct | 20.00 | DECIMAL | Default free space alert threshold for new drives (%) |
| ServerOps | Disk | snapshot_retention_days | 90 | INT | Days to keep disk space snapshot history |
| ServerOps | Disk | space_request_buffer_pct | 5.00 | DECIMAL | Extra % above threshold when calculating Jira space requests |
| ServerOps | Disk | stale_data_minutes | 90 | INT | Minutes without new data before showing stale warning |
| ServerOps | Disk | warning_buffer_pct | 2.00 | DECIMAL | Extra % above threshold to flag drives as approaching limit |
| ServerOps | Index | index_default_maxdop | 0 | INT | Default parallelism for rebuilds (0 = server default) |
| ServerOps | Index | index_default_operation | REBUILD | VARCHAR | Default rebuild method: REBUILD or REORGANIZE |
| ServerOps | Index | index_deferral_base_score | 5 | INT | Priority score for indexes deferred fewer times than threshold |
| ServerOps | Index | index_deferral_max_score | 10 | INT | Priority score for indexes deferred at or above threshold |
| ServerOps | Index | index_deferral_threshold | 5 | INT | Deferral count that triggers maximum priority score |
| ServerOps | Index | index_execute_abort | 0 | BIT | Emergency stop: finish current index then halt rebuilds |
| ServerOps | Index | index_frag_high_score | 20 | INT | Priority score for severely fragmented indexes (60%+) |
| ServerOps | Index | index_frag_low_max | 30 | INT | Upper fragmentation bound for low range (%) |
| ServerOps | Index | index_frag_low_score | 10 | INT | Priority score for lightly fragmented indexes (15-30%) |
| ServerOps | Index | index_frag_med_max | 60 | INT | Upper fragmentation bound for medium range (%) |
| ServerOps | Index | index_frag_med_score | 15 | INT | Priority score for moderately fragmented indexes (30-60%) |
| ServerOps | Index | index_fragmentation_threshold | 15.00 | DECIMAL | Minimum fragmentation % to qualify for maintenance |
| ServerOps | Index | index_lock_timeout_seconds | 60 | INT | Seconds to wait for a lock before skipping an index |
| ServerOps | Index | index_maintenance_priority_1_score | 40 | INT | Priority score for Critical maintenance priority databases |
| ServerOps | Index | index_maintenance_priority_2_score | 25 | INT | Priority score for High maintenance priority databases |
| ServerOps | Index | index_maintenance_priority_3_score | 15 | INT | Priority score for Normal maintenance priority databases |
| ServerOps | Index | index_max_deferrals_before_alert | 5 | INT | Deferrals before alerting about a perpetually skipped index |
| ServerOps | Index | index_min_page_count | 1000 | INT | Minimum index size to qualify for maintenance (~8MB) |
| ServerOps | Index | index_overrun_tolerance_minutes | 15 | INT | Grace period for in-progress rebuild past window end (minutes) |
| ServerOps | Index | index_page_large_score | 30 | INT | Priority score for large indexes (100K+ pages) |
| ServerOps | Index | index_page_medium_max | 100000 | INT | Upper page count bound for medium indexes |
| ServerOps | Index | index_page_medium_score | 20 | INT | Priority score for medium indexes (10K-100K pages) |
| ServerOps | Index | index_page_small_max | 10000 | INT | Upper page count bound for small indexes |
| ServerOps | Index | index_page_small_score | 10 | INT | Priority score for small indexes (1K-10K pages) |
| ServerOps | Index | index_rescan_interval_days | 2 | INT | Minimum days between rescans of the same index |
| ServerOps | Index | index_scan_abort | 0 | BIT | Emergency stop: abort fragmentation scanning after current batch |
| ServerOps | Index | index_scan_batch_check_size | 50 | INT | Indexes to scan between abort/time-limit checks |
| ServerOps | Index | index_scan_interval_minutes | 2880 | INT | Minimum minutes between full fragmentation scan runs |
| ServerOps | Index | index_scan_pages_per_second | 150000 | INT | Estimated scan speed for timeout calculation (pages/sec) |
| ServerOps | Index | index_scan_skip_rebuilt_days | 3 | INT | Days to skip scanning recently rebuilt indexes |
| ServerOps | Index | index_scan_time_limit_minutes | 0 | INT | Maximum scan duration in minutes (0 = no limit) |
| ServerOps | Index | index_scan_timeout_base_seconds | 90 | INT | Minimum timeout per index during scanning (seconds) |
| ServerOps | Index | index_seconds_per_page_offline | 0.00025 | DECIMAL | Time estimate factor for offline rebuilds (seconds per page) |
| ServerOps | Index | index_seconds_per_page_online | 0.0005 | DECIMAL | Time estimate factor for online rebuilds (seconds per page) |
| ServerOps | Index | index_sync_interval_minutes | 1440 | INT | Minimum minutes between index discovery runs |
| ServerOps | Index | stats_max_days_stale | 60 | INT | Force statistics update if older than this many days |
| ServerOps | Index | stats_min_rows | 1000 | INT | Minimum table row count for statistics maintenance |
| ServerOps | Index | stats_modification_pct_threshold | 10 | DECIMAL | Row modification % that triggers statistics update |
| ServerOps | Index | stats_respect_schedule | 0 | BIT | Restrict statistics updates to maintenance windows only |
| ServerOps | Index | stats_sample_pct | 0 | INT | Statistics sampling rate (0 = full scan) |
| ServerOps | Index | stats_update_interval_minutes | 1440 | INT | Minimum minutes between statistics update runs |
| ServerOps | Replication | replication_agent_down_alert_minutes | 5 | INT | Minutes replication agent can be down before alerting |
| ServerOps | Replication | replication_alerting_enabled | 0 | BIT | Master on/off switch for replication alerting |
| ServerOps | Replication | replication_latency_critical_ms | 120000 | INT | Latency threshold for critical alert (milliseconds) |
| ServerOps | Replication | replication_latency_warning_ms | 30000 | INT | Latency threshold for warning alert (milliseconds) |
| ServerOps | Replication | replication_queue_critical_threshold | 50000 | INT | Undistributed commands threshold for critical alert |
| ServerOps | Replication | replication_queue_warning_threshold | 5000 | INT | Undistributed commands threshold for warning alert |
| ServerOps | Replication | replication_tracer_interval_minutes | 5 | INT | Minutes between latency measurement checks |
| ServerOps | Replication | replication_tracer_wait_seconds | 15 | INT | Seconds to wait for latency results after posting tracer |
| Shared |  | AGListenerName | AVG-PROD-LSNR | VARCHAR | Always On Availability Group listener name for crs5_oltp. Used by Get-CRS5Connection to determine AG-aware vs direct connection routing. |
| Shared |  | AGName | DMPRODAG | VARCHAR | Availability Group name for primary/secondary detection |
| Shared | Credentials | master_passphrase | P0w3rSh3LL-M@5t3R | VARCHAR | Global master passphrase for decrypting service-specific passphrases in dbo.Credentials |
| Shared | Monitoring | SourceReplica | SECONDARY | VARCHAR | Which AG replica to query for source data (PRIMARY or SECONDARY) |
| Teams | AlertFailures | alert_failure_lookback_days | 3 | INT | Days to look back when showing failed alerts on Admin page |
| Teams | Retry | teams_retry_max_attempts | 3 | INT | Max delivery retries before marking an alert as permanently failed |
| Tools | Operations | bdl_promote_cooldown_seconds | 300 | INT | Countdown timer in seconds before the Promote to Production button activates after a successful non-PROD import. Gives users time to verify their data in Debt Manager before promoting. |
| Tools | Portal | crs5_portal_query_timeout_seconds | 60 | INT | Command timeout in seconds for Client Portal queries against crs5_oltp |

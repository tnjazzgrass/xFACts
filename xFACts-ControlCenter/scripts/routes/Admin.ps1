<#
.SYNOPSIS
    xFACts Control Center - Administration page route.
.DESCRIPTION
    Admin-only page presenting the platform process timeline and the platform
    management tools. The timeline is a full-width canvas visualization driven
    by live orchestrator WebSocket events. The management tools open as slide-up
    panels and a paired detail dock: Engine Controls, System Metadata, Global
    Configuration, Process Scheduler, Documentation pipeline, and Alert
    Failures. Renders the page shell and static overlay scaffolding; all dynamic
    behavior is in admin.js, loaded by the cc-shared.js bootloader.
.COMPONENT
    ControlCenter.Admin
.NOTES
    File Name : Admin.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\Admin.ps1

    FILE ORGANIZATION
    -----------------
    ROUTE: PAGE PATH
#>

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers GET /admin. Performs the RBAC access check, resolves the dynamic
   nav, page header, browser title, and banner chrome from the shared helpers,
   then emits the page shell: process timeline, platform-management cards, and
   the overlay block (six slide-up panels, the detail dock, and two modals).
   Prefix: adm
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/admin' -Authentication 'ADLogin' -ScriptBlock {
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/admin'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/admin') -StatusCode 403
        return
    }

    $ctx          = Get-UserContext      -WebEvent $WebEvent
    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/admin'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/admin'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/admin'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/admin.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-admin" data-cc-page="admin" data-cc-prefix="adm">
$navHtml

    <div class="cc-header-bar">
        <div>
            $headerHtml
        </div>
        <div class="cc-header-right">
            <div class="cc-refresh-info">
                <span class="cc-live-indicator"></span>
                <span>Live</span> | Updated: <span id="cc-last-update" class="cc-last-updated">-</span>
                <button class="cc-page-refresh-btn" data-action-click="cc-page-refresh" title="Refresh all data">&#8635;</button>
            </div>
        </div>
    </div>

    $bannerHtml

    <!-- Process timeline: full-width canvas visualization -->
    <div class="adm-timeline-section">
        <div class="adm-timeline-toolbar">
            <div class="adm-timeline-toolbar-left">
                <span class="adm-section-title">Process Timeline</span>
                <div class="adm-filter-bar">
                    <button class="adm-filter-pill adm-active" data-action-click="adm-set-filter" data-action-adm-filter="all">All</button>
                    <button class="adm-filter-pill" data-action-click="adm-set-filter" data-action-adm-filter="running">Running</button>
                    <button class="adm-filter-pill" data-action-click="adm-set-filter" data-action-adm-filter="failed">Failed</button>
                </div>
            </div>
            <div class="adm-timeline-toolbar-right">
                <div class="adm-timeline-legend" id="adm-timeline-legend"></div>
                <div class="adm-window-selector">
                    <button class="adm-window-btn" data-action-click="adm-set-window" data-action-adm-window="10">10m</button>
                    <button class="adm-window-btn adm-active" data-action-click="adm-set-window" data-action-adm-window="30">30m</button>
                    <button class="adm-window-btn" data-action-click="adm-set-window" data-action-adm-window="60">60m</button>
                </div>
            </div>
        </div>

        <div class="adm-timeline-body">
            <div class="adm-timeline-sidebar" id="adm-timeline-sidebar">
                <div class="adm-loading">Loading...</div>
            </div>
            <div class="adm-timeline-canvas-wrap" id="adm-timeline-canvas-wrap">
                <canvas id="adm-timeline-canvas" class="adm-timeline-canvas"></canvas>
            </div>
        </div>
    </div>

    <!-- Timeline hover tooltip (positioned at the cursor) -->
    <div class="adm-tooltip" id="adm-tooltip"></div>

    <!-- Platform management entry cards -->
    <div class="adm-section-divider"></div>
    <div class="adm-section-title adm-bottom-title">Platform Management</div>
    <div class="adm-platform-row">
        <button class="adm-card" data-action-click="adm-open-engine">
            <div class="adm-card-icon">&#9881;</div>
            <div class="adm-card-title">Engine Controls</div>
            <div class="adm-engine-pips">
                <span class="adm-engine-status-pip" id="adm-engine-pip" title="Engine"></span>
                <span class="adm-service-status-pip" id="adm-service-pip" title="Service"></span>
            </div>
        </button>
        <button class="adm-card" data-action-click="adm-open-metadata">
            <div class="adm-card-icon">&#128203;</div>
            <div class="adm-card-title">System Metadata</div>
        </button>
        <button class="adm-card" data-action-click="adm-open-globalconfig">
            <div class="adm-card-icon">&#9889;</div>
            <div class="adm-card-title">Global Configuration</div>
        </button>
        <button class="adm-card" data-action-click="adm-open-schedule">
            <div class="adm-card-icon">&#128339;</div>
            <div class="adm-card-title">Process Scheduler</div>
        </button>
        <button class="adm-card" data-action-click="adm-open-platmon">
            <div class="adm-card-icon">&#128200;</div>
            <div class="adm-card-title">Platform Monitoring</div>
        </button>
        <button class="adm-card" data-action-click="adm-open-docpipeline">
            <div class="adm-card-icon">&#128218;</div>
            <div class="adm-card-title">Documentation</div>
        </button>
        <button class="adm-card" data-action-click="adm-open-alertfailures">
            <div class="adm-card-icon">&#9888;</div>
            <div class="adm-card-title">Alert Failures</div>
            <div class="adm-af-badge adm-clean" id="adm-af-badge">
                <span class="adm-af-badge-count adm-hidden" id="adm-af-badge-count">0</span>
            </div>
        </button>
    </div>

    <!-- Engine Controls: orchestrator drain breaker and Windows-service controls -->
    <div id="adm-slideup-engine" class="cc-slideup-overlay" data-action-click="adm-close-engine">
        <div class="cc-dialog cc-dialog-slideup cc-narrow cc-h-short">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Orchestrator Engine</h3>
                <button class="cc-dialog-close" data-action-click="adm-close-engine">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="adm-engine-body">
                    <div class="adm-engine-inner">
                        <div class="adm-drain-label">Engine</div>
                        <button class="adm-breaker-housing" data-action-click="adm-toggle-drain">
                            <div class="adm-breaker-plate" id="adm-breaker-plate">
                                <div class="adm-screw adm-tl"></div><div class="adm-screw adm-tr"></div>
                                <div class="adm-screw adm-bl"></div><div class="adm-screw adm-br"></div>
                                <div class="adm-switch-slot">
                                    <span class="adm-switch-label adm-on-label">ON</span>
                                    <span class="adm-switch-label adm-off-label">OFF</span>
                                    <div class="adm-switch-handle" id="adm-switch-handle"></div>
                                </div>
                            </div>
                            <div class="adm-spark-container" id="adm-spark-container"></div>
                        </button>
                        <div class="adm-status-light" id="adm-status-light"></div>
                        <div class="adm-drain-status" id="adm-drain-status">ONLINE</div>
                        <div class="adm-svc-divider"></div>
                        <div class="adm-svc-section-label">Service</div>
                        <div class="adm-svc-section-icon"><svg viewBox="0 0 100 100" width="44" height="44" fill="currentColor"><path d="M42 2h16v11a38 38 0 0 1 11.3 4.7l7.8-7.8 11.3 11.3-7.8 7.8A38 38 0 0 1 85.3 40H98v16H85.3a38 38 0 0 1-4.7 11.3l7.8 7.8-11.3 11.3-7.8-7.8A38 38 0 0 1 58 83.3V98H42V83.3a38 38 0 0 1-11.3-4.7l-7.8 7.8L11.6 75.1l7.8-7.8A38 38 0 0 1 14.7 56H2V40h12.7a38 38 0 0 1 4.7-11.3l-7.8-7.8L22.9 9.6l7.8 7.8A38 38 0 0 1 42 12.7zM50 34a16 16 0 1 0 0 32 16 16 0 0 0 0-34z"/></svg></div>
                        <div class="adm-svc-badge-row">
                            <span class="adm-svc-badge" id="adm-svc-badge">SERVICE RUNNING</span>
                        </div>
                        <div class="adm-svc-buttons" id="adm-svc-buttons">
                            <button class="adm-svc-btn adm-stop" id="adm-svc-btn-stop" data-action-click="adm-service-control" data-action-adm-svc="stop" disabled title="Stop the xFACtsOrchestrator service">Stop</button>
                            <button class="adm-svc-btn adm-start" id="adm-svc-btn-start" data-action-click="adm-service-control" data-action-adm-svc="start" disabled title="Start the xFACtsOrchestrator service">Start</button>
                            <button class="adm-svc-btn adm-restart" id="adm-svc-btn-restart" data-action-click="adm-service-control" data-action-adm-svc="restart" disabled title="Stop and restart the xFACtsOrchestrator service">Restart</button>
                        </div>
                        <div class="adm-svc-guidance" id="adm-svc-guidance"></div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- System Metadata: component-versioning tree -->
    <div id="adm-slideup-metadata" class="cc-slideup-overlay" data-action-click="adm-close-metadata">
        <div class="cc-dialog cc-dialog-slideup cc-wide cc-h-tall">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">System Metadata</h3>
                <div class="cc-dialog-header-actions">
                    <span class="adm-results-count" id="adm-meta-results-count"></span>
                </div>
                <button class="cc-dialog-close" data-action-click="adm-close-metadata">&times;</button>
            </div>
            <div class="cc-dialog-subheader">
                <div class="adm-meta-status" id="adm-meta-status"></div>
            </div>
            <div class="cc-dialog-body" id="adm-meta-tree-list"></div>
        </div>
    </div>

    <!-- System Metadata detail dock: object catalog and version history -->
    <div id="adm-dock-detail" class="cc-dialog cc-dialog-dock cc-wide cc-dock-at-wide cc-h-tall">
        <div class="cc-dialog-header">
            <button class="cc-dialog-back" data-action-click="adm-close-detail">&larr;</button>
            <h3 class="cc-dialog-title" id="adm-detail-title">Details</h3>
            <div class="cc-dialog-header-actions">
                <span class="adm-results-count" id="adm-detail-count"></span>
            </div>
        </div>
        <div class="cc-dialog-body" id="adm-detail-body"></div>
    </div>

    <!-- Global Configuration: module/setting tree with inline editing -->
    <div id="adm-slideup-globalconfig" class="cc-slideup-overlay" data-action-click="adm-close-globalconfig">
        <div class="cc-dialog cc-dialog-slideup cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">GlobalConfig</h3>
                <div class="cc-dialog-header-actions">
                    <span class="adm-results-count" id="adm-gc-results-count"></span>
                </div>
                <button class="cc-dialog-close" data-action-click="adm-close-globalconfig">&times;</button>
            </div>
            <div class="cc-dialog-subheader">
                <div class="adm-meta-status" id="adm-gc-status"></div>
            </div>
            <div class="cc-dialog-body" id="adm-gc-tree-list"></div>
        </div>
    </div>

    <!-- Process Scheduler: module/process tree with per-process config -->
    <div id="adm-slideup-schedule" class="cc-slideup-overlay" data-action-click="adm-close-schedule">
        <div class="cc-dialog cc-dialog-slideup cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Process Schedules</h3>
                <div class="cc-dialog-header-actions">
                    <span class="adm-results-count" id="adm-sched-results-count"></span>
                </div>
                <button class="cc-dialog-close" data-action-click="adm-close-schedule">&times;</button>
            </div>
            <div class="cc-dialog-subheader">
                <div class="adm-meta-status" id="adm-sched-status"></div>
            </div>
            <div class="cc-dialog-body" id="adm-sched-tree-list"></div>
        </div>
    </div>

    <!-- Documentation pipeline: step selection and run results -->
    <div id="adm-slideup-docpipeline" class="cc-slideup-overlay" data-action-click="adm-close-docpipeline">
        <div class="cc-dialog cc-dialog-slideup cc-h-max">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Documentation</h3>
                <button class="cc-dialog-close" data-action-click="adm-close-docpipeline">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="adm-doc-pipeline-body">
                    <div class="adm-doc-step-list">
                        <div class="adm-doc-card" id="adm-doc-card-ddl">
                            <div class="adm-doc-card-row">
                                <div class="adm-doc-card-body">
                                    <div class="adm-doc-card-title">Generate DDL Reference</div>
                                    <div class="adm-doc-card-desc">Regenerate JSON data files from Object_Metadata</div>
                                </div>
                                <span class="adm-doc-card-status" id="adm-doc-status-generate-ddl"></span>
                                <label class="adm-doc-toggle"><input type="checkbox" id="adm-doc-step-ddl" checked><div class="adm-doc-toggle-track"></div><div class="adm-doc-toggle-knob"></div></label>
                            </div>
                        </div>
                        <div class="adm-doc-card" id="adm-doc-card-publish">
                            <div class="adm-doc-card-row">
                                <div class="adm-doc-card-body">
                                    <div class="adm-doc-card-title">Publish to Confluence</div>
                                    <div class="adm-doc-card-desc">Publish HTML pages to Confluence Server</div>
                                </div>
                                <span class="adm-doc-card-status" id="adm-doc-status-publish-confluence"></span>
                                <label class="adm-doc-toggle"><input type="checkbox" id="adm-doc-step-publish" checked><div class="adm-doc-toggle-track"></div><div class="adm-doc-toggle-knob"></div></label>
                            </div>
                            <div class="adm-doc-card-options" id="adm-doc-step-publish-options">
                                <button class="adm-doc-pill adm-active" id="adm-doc-opt-confluence" data-action-click="adm-doc-toggle-pill" title="Push pages to Confluence Server via REST API">Publish to Confluence</button>
                                <button class="adm-doc-pill adm-active" id="adm-doc-opt-markdown" data-action-click="adm-doc-toggle-pill" title="Export markdown files for Claude upload">Export Markdown</button>
                            </div>
                        </div>
                        <div class="adm-doc-card" id="adm-doc-card-github">
                            <div class="adm-doc-card-row">
                                <div class="adm-doc-card-body">
                                    <div class="adm-doc-card-title">Publish to GitHub</div>
                                    <div class="adm-doc-card-desc">Push platform files and manifest to GitHub repository</div>
                                </div>
                                <span class="adm-doc-card-status" id="adm-doc-status-publish-github"></span>
                                <label class="adm-doc-toggle"><input type="checkbox" id="adm-doc-step-github" checked><div class="adm-doc-toggle-track"></div><div class="adm-doc-toggle-knob"></div></label>
                            </div>
                        </div>
                        <div class="adm-doc-card" id="adm-doc-card-consolidate">
                            <div class="adm-doc-card-row">
                                <div class="adm-doc-card-body">
                                    <div class="adm-doc-card-title">Consolidate Upload Files</div>
                                    <div class="adm-doc-card-desc">Collect all platform files into upload folder</div>
                                </div>
                                <span class="adm-doc-card-status" id="adm-doc-status-consolidate-upload"></span>
                                <label class="adm-doc-toggle"><input type="checkbox" id="adm-doc-step-consolidate" checked><div class="adm-doc-toggle-track"></div><div class="adm-doc-toggle-knob"></div></label>
                            </div>
                            <div class="adm-doc-card-options" id="adm-doc-step-consolidate-options">
                                <button class="adm-doc-pill adm-active" id="adm-doc-opt-sql" data-action-click="adm-doc-toggle-pill" title="Extract SQL object definitions from database">Include SQL Objects</button>
                                <button class="adm-doc-pill" id="adm-doc-opt-json" data-action-click="adm-doc-toggle-pill" title="Include JSON data files in upload folder">Include JSON</button>
                            </div>
                        </div>
                    </div>

                    <div class="adm-doc-run-row">
                        <button class="adm-doc-run-btn" id="adm-doc-run-btn" data-action-click="adm-doc-run">Run Selected</button>
                        <span class="adm-doc-run-status" id="adm-doc-run-status"></span>
                    </div>

                    <div class="adm-doc-results" id="adm-doc-results"></div>
                </div>
            </div>
        </div>
    </div>

    <!-- Alert Failures: unresolved notification-delivery failures -->
    <div id="adm-slideup-alertfailures" class="cc-slideup-overlay" data-action-click="adm-close-alertfailures">
        <div class="cc-dialog cc-dialog-slideup cc-h-short">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Alert Failures</h3>
                <div class="cc-dialog-header-actions">
                    <span class="adm-results-count" id="adm-af-results-count"></span>
                </div>
                <button class="cc-dialog-close" data-action-click="adm-close-alertfailures">&times;</button>
            </div>
            <div class="cc-dialog-body" id="adm-af-body">
                <div class="adm-loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Name-entry modal (replaces the native browser prompt) -->
    <div id="adm-modal-input" class="cc-modal-overlay cc-hidden" data-action-click="adm-close-input">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="adm-input-modal-title">Enter Name</h3>
                <button class="cc-dialog-close" data-action-click="adm-close-input">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <input type="text" class="adm-input-modal-field" id="adm-input-modal-field" maxlength="128" data-action-keydown="adm-input-keydown">
                <div class="adm-input-modal-hint" id="adm-input-modal-hint"></div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="adm-close-input">Cancel</button>
                <button class="cc-dialog-btn-primary" id="adm-input-modal-confirm" data-action-click="adm-confirm-input">OK</button>
            </div>
        </div>
    </div>

    <!-- Task-log modal: output/error tabs -->
    <div id="adm-modal-log" class="cc-modal-overlay cc-hidden" data-action-click="adm-close-log">
        <div class="cc-dialog cc-dialog-modal cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="adm-log-modal-title">Task Log</h3>
                <button class="cc-dialog-close" data-action-click="adm-close-log">&times;</button>
            </div>
            <div class="cc-dialog-subheader">
                <div class="adm-log-modal-tabs">
                    <button class="adm-log-tab adm-active" id="adm-log-tab-output" data-action-click="adm-switch-log-tab" data-action-adm-tab="output">Output</button>
                    <button class="adm-log-tab" id="adm-log-tab-error" data-action-click="adm-switch-log-tab" data-action-adm-tab="error">Error</button>
                </div>
            </div>
            <div class="cc-dialog-body">
                <pre class="adm-log-content" id="adm-log-content"></pre>
            </div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
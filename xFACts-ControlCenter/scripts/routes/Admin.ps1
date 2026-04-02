# ============================================================================
# xFACts Control Center - Administration Page
# Location: E:\xFACts-ControlCenter\scripts\routes\Admin.ps1
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.Admin)
# ============================================================================

Add-PodeRoute -Method Get -Path '/admin' -Authentication 'ADLogin' -ScriptBlock {

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/admin'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/admin') -StatusCode 403
        return
    }

    $html = @'

<!DOCTYPE html>
<html>
<head>
    <title>Administration - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/admin.css">
    <link rel="stylesheet" href="/css/engine-events.css">
</head>
<body>
    <!-- Navigation Bar -->
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/server-health" class="nav-link">Server Health</a>
        <a href="/jobflow-monitoring" class="nav-link">Job/Flow Monitoring</a>
        <a href="/batch-monitoring" class="nav-link">Batch Monitoring</a>
        <a href="/backup" class="nav-link">Backup Monitoring</a>
        <a href="/index-maintenance" class="nav-link">Index Maintenance</a>
        <a href="/dbcc-operations" class="nav-link">DBCC Operations</a>
        <a href="/bidata-monitoring" class="nav-link">BIDATA Monitoring</a>
        <a href="/file-monitoring" class="nav-link">File Monitoring</a>
        <a href="/replication-monitoring" class="nav-link">Replication Monitoring</a>
        <a href="/jboss-monitoring" class="nav-link">JBoss Monitoring</a>
        <a href="/dm-operations" class="nav-link">DM Operations</a>
        <span class="nav-separator">|</span>
        <a href="/departmental/business-services" class="nav-link">Business Services</a>
        <a href="/departmental/business-intelligence" class="nav-link">Business Intelligence</a>
        <a href="/departmental/client-relations" class="nav-link">Client Relations</a>
        <span class="nav-spacer"></span>
        <a href="/admin" class="nav-link nav-admin active" title="Administration">&#9881;</a>
    </nav>

    <!-- Header -->
    <div class="page-header">
        <div>
            <h1>Administration</h1>
            <p class="header-subtitle">Process timeline and platform management</p>
        </div>
        <div class="refresh-info">
            <span class="live-indicator"></span>
            <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
            <button class="page-refresh-btn" onclick="Admin.pageRefresh()" title="Refresh all data">&#8635;</button>
        </div>
    </div>

    <!-- Connection Error -->
    <div id="connection-error" class="connection-error"></div>

    <!-- ============================================================
         PROCESS TIMELINE — Full-width canvas visualization
         ============================================================ -->
    <div class="timeline-section">
        <!-- Timeline toolbar -->
        <div class="timeline-toolbar">
            <div class="timeline-toolbar-left">
                <span class="section-title" style="margin:0;">Process Timeline</span>
                <div class="filter-bar">
                    <button class="filter-pill active" data-filter="all" onclick="Admin.setFilter('all')">All</button>
                    <button class="filter-pill" data-filter="running" onclick="Admin.setFilter('running')">Running</button>
                    <button class="filter-pill" data-filter="failed" onclick="Admin.setFilter('failed')">Failed</button>
                </div>
            </div>
            <div class="timeline-toolbar-right">
                <!-- Module legend -->
                <div class="timeline-legend" id="timeline-legend"></div>
                <!-- Window selector -->
                <div class="window-selector">
                    <button class="window-btn" data-window="10" onclick="Admin.setWindow(10)">10m</button>
                    <button class="window-btn active" data-window="30" onclick="Admin.setWindow(30)">30m</button>
                    <button class="window-btn" data-window="60" onclick="Admin.setWindow(60)">60m</button>
                </div>
            </div>
        </div>

        <!-- Timeline body: label sidebar + canvas -->
        <div class="timeline-body">
            <!-- Process label sidebar -->
            <div class="timeline-sidebar" id="timeline-sidebar">
                <div class="loading">Loading...</div>
            </div>
            <!-- Canvas area -->
            <div class="timeline-canvas-wrap" id="timeline-canvas-wrap">
                <canvas id="timeline-canvas"></canvas>
            </div>
        </div>
    </div>

    <!-- ============================================================
         PLATFORM MANAGEMENT
         ============================================================ -->
    <div class="section-divider"></div>
    <div class="section-title bottom-title">Platform Management</div>
    <div class="platform-row">
        <div class="admin-card" onclick="Admin.openEngineControls()">
            <div class="admin-card-icon">&#9881;</div>
            <div class="admin-card-title">Engine Controls</div>
            <div class="engine-pips">
                <span class="engine-status-pip" id="engine-pip" title="Engine"></span>
                <span class="service-status-pip" id="service-pip" title="Service"></span>
            </div>
        </div>
        <div class="admin-card" onclick="Admin.openMetadata()">
            <div class="admin-card-icon">&#128203;</div>
            <div class="admin-card-title">System Metadata</div>
        </div>
        <div class="admin-card" onclick="Admin.openGlobalConfig()">
            <div class="admin-card-icon">&#9889;</div>
            <div class="admin-card-title">Global Configuration</div>
        </div>
        <div class="admin-card" onclick="Admin.openSchedules()">
            <div class="admin-card-icon">&#128339;</div>
            <div class="admin-card-title">Process Scheduler</div>
        </div>
        <div class="admin-card" onclick="window.location.href='/platform-monitoring'">
            <div class="admin-card-icon">&#128200;</div>
            <div class="admin-card-title">Platform Monitoring</div>
        </div>
        <div class="admin-card" onclick="Admin.openDocPipeline()">
            <div class="admin-card-icon">&#128218;</div>
            <div class="admin-card-title">Documentation</div>
        </div>
        <div class="admin-card" onclick="Admin.openAlertFailures()">
            <div class="admin-card-icon">&#9888;</div>
            <div class="admin-card-title">Alert Failures</div>
            <div class="af-badge" id="af-badge" style="display:none;">
                <span class="af-badge-count" id="af-badge-count">0</span>
            </div>
        </div>
    </div>

    <!-- ============================================================
         ENGINE CONTROLS SLIDEOUT
         ============================================================ -->
    <div class="slideup-backdrop" id="engine-backdrop" onclick="Admin.closeEngineControls()"></div>
    <div class="slideup-panel engine-panel" id="engine-panel">
        <div class="slideup-handle" onclick="Admin.closeEngineControls()"><div class="handle-bar"></div></div>
        <div class="slideup-header">
            <h2 class="slideup-title">Orchestrator Engine</h2>
            <button class="slideup-close" onclick="Admin.closeEngineControls()">&times;</button>
        </div>
        <div class="engine-slideout-body">
            <div class="engine-panel-inner">
                <div class="drain-label">Engine</div>
                <div class="breaker-housing" onclick="Admin.toggleDrain()">
                    <div class="breaker-plate">
                        <div class="screw tl"></div><div class="screw tr"></div>
                        <div class="screw bl"></div><div class="screw br"></div>
                        <div class="switch-slot">
                            <span class="switch-label on-label">ON</span>
                            <span class="switch-label off-label">OFF</span>
                            <div class="switch-handle" id="switch-handle"></div>
                        </div>
                    </div>
                    <div class="spark-container" id="spark-container"></div>
                </div>
                <div class="status-light" id="status-light"></div>
                <div class="drain-status" id="drain-status">ONLINE</div>
                <div class="svc-divider"></div>
                <div class="svc-section-label">Service</div>
                <div class="svc-section-icon"><svg viewBox="0 0 100 100" width="44" height="44" fill="currentColor"><path d="M42 2h16v11a38 38 0 0 1 11.3 4.7l7.8-7.8 11.3 11.3-7.8 7.8A38 38 0 0 1 85.3 40H98v16H85.3a38 38 0 0 1-4.7 11.3l7.8 7.8-11.3 11.3-7.8-7.8A38 38 0 0 1 58 83.3V98H42V83.3a38 38 0 0 1-11.3-4.7l-7.8 7.8L11.6 75.1l7.8-7.8A38 38 0 0 1 14.7 56H2V40h12.7a38 38 0 0 1 4.7-11.3l-7.8-7.8L22.9 9.6l7.8 7.8A38 38 0 0 1 42 12.7zM50 34a16 16 0 1 0 0 32 16 16 0 0 0 0-34z"/></svg></div>
                <div class="svc-badge-row">
                    <span class="svc-badge" id="svc-badge">SERVICE RUNNING</span>
                </div>
                <div class="svc-buttons" id="svc-buttons">
                    <button class="svc-btn svc-stop" id="svc-btn-stop" onclick="Admin.serviceControl('stop')" disabled title="Stop the xFACtsOrchestrator service">Stop</button>
                    <button class="svc-btn svc-start" id="svc-btn-start" onclick="Admin.serviceControl('start')" disabled title="Start the xFACtsOrchestrator service">Start</button>
                    <button class="svc-btn svc-restart" id="svc-btn-restart" onclick="Admin.serviceControl('restart')" disabled title="Stop and restart the xFACtsOrchestrator service">Restart</button>
                </div>
                <div class="svc-guidance" id="svc-guidance"></div>
            </div>
        </div>
    </div>

    <!-- System Metadata Slide-Up: Tree Panel -->
    <div class="slideup-backdrop" id="meta-backdrop" onclick="Admin.closeMetadata()"></div>
    <div class="slideup-panel meta-panel" id="meta-panel">
        <div class="slideup-handle" onclick="Admin.closeMetadata()"><div class="handle-bar"></div></div>
        <div class="slideup-header">
            <h2 class="slideup-title">System Metadata</h2>
            <div class="meta-header-right">
                <span class="meta-results-count" id="meta-results-count"></span>
                <button class="slideup-close" onclick="Admin.closeMetadata()">&times;</button>
            </div>
        </div>
        <div class="meta-status" id="meta-status"></div>
        <div class="meta-tree-list" id="meta-tree-list">
        </div>
    </div>

    <!-- Detail Slide-Out (shared: version history + object catalog) -->
    <div class="detail-panel" id="detail-panel">
        <div class="detail-header">
            <button class="detail-back" onclick="Admin.closeDetail()" title="Back">&#8592;</button>
            <h3 class="detail-title" id="detail-title">Details</h3>
            <span class="detail-count" id="detail-count"></span>
        </div>
        <div class="detail-body" id="detail-body">
        </div>
    </div>

    <!-- GlobalConfig Slide-Up: Tree Panel -->
    <div class="slideup-backdrop" id="gc-backdrop" onclick="Admin.closeGlobalConfig()"></div>
    <div class="slideup-panel gc-panel" id="gc-panel">
        <div class="slideup-handle" onclick="Admin.closeGlobalConfig()"><div class="handle-bar"></div></div>
        <div class="slideup-header">
            <h2 class="slideup-title">GlobalConfig</h2>
            <div class="gc-header-right">
                <span class="meta-results-count" id="gc-results-count"></span>
                <button class="slideup-close" onclick="Admin.closeGlobalConfig()">&times;</button>
            </div>
        </div>
        <div class="meta-status" id="gc-status"></div>
        <div class="gc-tree-list" id="gc-tree-list">
        </div>
    </div>

    <!-- Schedules Slide-Up Panel -->
    <div class="slideup-backdrop" id="sched-backdrop" onclick="Admin.closeSchedules()"></div>
    <div class="slideup-panel sched-panel" id="sched-panel">
        <div class="slideup-handle" onclick="Admin.closeSchedules()"><div class="handle-bar"></div></div>
        <div class="slideup-header">
            <h2 class="slideup-title">Process Schedules</h2>
            <div class="sched-header-right">
                <span class="meta-results-count" id="sched-results-count"></span>
                <button class="slideup-close" onclick="Admin.closeSchedules()">&times;</button>
            </div>
        </div>
        <div class="meta-status" id="sched-status"></div>
        <div class="sched-tree-list" id="sched-tree-list">
        </div>
    </div>

    <!-- Documentation Pipeline Slide-Up -->
    <div class="slideup-backdrop" id="doc-backdrop" onclick="Admin.closeDocPipeline()"></div>
    <div class="slideup-panel doc-panel" id="doc-panel">
        <div class="slideup-handle" onclick="Admin.closeDocPipeline()"><div class="handle-bar"></div></div>
        <div class="slideup-header">
            <h2 class="slideup-title">Documentation</h2>
            <button class="slideup-close" onclick="Admin.closeDocPipeline()">&times;</button>
        </div>
        <div class="doc-pipeline-body">
            <!-- Step cards with toggle switches -->
            <div class="doc-step-list">
                <div class="doc-card" id="doc-card-ddl">
                    <div class="doc-card-row">
                        <div class="doc-card-body">
                            <div class="doc-card-title">Generate DDL Reference</div>
                            <div class="doc-card-desc">Regenerate JSON data files from Object_Metadata</div>
                        </div>
                        <label class="doc-toggle"><input type="checkbox" id="doc-step-ddl" checked><div class="doc-toggle-track"></div><div class="doc-toggle-knob"></div></label>
                    </div>
                </div>
                <div class="doc-card" id="doc-card-publish">
                    <div class="doc-card-row">
                        <div class="doc-card-body">
                            <div class="doc-card-title">Publish to Confluence</div>
                            <div class="doc-card-desc">Publish HTML pages to Confluence Server</div>
                        </div>
                        <label class="doc-toggle"><input type="checkbox" id="doc-step-publish" checked><div class="doc-toggle-track"></div><div class="doc-toggle-knob"></div></label>
                    </div>
                    <div class="doc-card-options" id="doc-step-publish-options">
                        <span class="doc-pill active" id="doc-opt-confluence" onclick="Admin.docTogglePill(this)" title="Push pages to Confluence Server via REST API">Publish to Confluence</span>
                        <span class="doc-pill active" id="doc-opt-markdown" onclick="Admin.docTogglePill(this)" title="Export markdown files for Claude upload">Export Markdown</span>
                    </div>
                </div>
                <div class="doc-card" id="doc-card-github">
                    <div class="doc-card-row">
                        <div class="doc-card-body">
                            <div class="doc-card-title">Publish to GitHub</div>
                            <div class="doc-card-desc">Push platform files and manifest to GitHub repository</div>
                        </div>
                        <label class="doc-toggle"><input type="checkbox" id="doc-step-github" checked><div class="doc-toggle-track"></div><div class="doc-toggle-knob"></div></label>
                    </div>
                </div>
                <div class="doc-card" id="doc-card-consolidate">
                    <div class="doc-card-row">
                        <div class="doc-card-body">
                            <div class="doc-card-title">Consolidate Upload Files</div>
                            <div class="doc-card-desc">Collect all platform files into upload folder</div>
                        </div>
                        <label class="doc-toggle"><input type="checkbox" id="doc-step-consolidate" checked><div class="doc-toggle-track"></div><div class="doc-toggle-knob"></div></label>
                    </div>
                    <div class="doc-card-options" id="doc-step-consolidate-options">
                        <span class="doc-pill active" id="doc-opt-sql" onclick="Admin.docTogglePill(this)" title="Extract SQL object definitions from database">Include SQL Objects</span>
                        <span class="doc-pill" id="doc-opt-json" onclick="Admin.docTogglePill(this)" title="Include JSON data files in upload folder">Include JSON</span>
                    </div>
                </div>
            </div>

            <!-- Run button + overall status -->
            <div class="doc-run-row">
                <button class="doc-run-btn" id="doc-run-btn" onclick="Admin.runDocPipeline()">Run Selected</button>
                <span class="doc-run-status" id="doc-run-status"></span>
            </div>

            <!-- Results area (shown after execution) -->
            <div class="doc-results" id="doc-results"></div>
        </div>
    </div>

    <!-- Alert Failures Slide-Up -->
    <div class="slideup-backdrop" id="af-backdrop" onclick="Admin.closeAlertFailures()"></div>
    <div class="slideup-panel af-panel" id="af-panel">
        <div class="slideup-handle" onclick="Admin.closeAlertFailures()"><div class="handle-bar"></div></div>
        <div class="slideup-header">
            <h2 class="slideup-title">Alert Failures</h2>
            <div class="af-header-right">
                <span class="meta-results-count" id="af-results-count"></span>
                <button class="slideup-close" onclick="Admin.closeAlertFailures()">&times;</button>
            </div>
        </div>
        <div class="af-body" id="af-body">
            <div class="loading" style="padding:20px;">Loading...</div>
        </div>
    </div>

    <!-- Themed input modal (replaces browser prompt) -->
    <div class="input-modal-overlay" id="input-modal-overlay" onclick="Admin.cancelInput()"></div>
    <div class="input-modal" id="input-modal">
        <div class="input-modal-title" id="input-modal-title">Enter Name</div>
        <input type="text" class="input-modal-field" id="input-modal-field" maxlength="128" onkeydown="if(event.key==='Enter')Admin.confirmInput()">
        <div class="input-modal-hint" id="input-modal-hint"></div>
        <div class="input-modal-buttons">
            <button class="btn-cancel" onclick="Admin.cancelInput()">Cancel</button>
            <button class="btn-confirm" id="input-modal-confirm" onclick="Admin.confirmInput()">OK</button>
        </div>
    </div>

    <!-- Log Modal -->
    <div class="log-overlay" id="log-overlay" onclick="Admin.closeLog()">
        <div class="log-modal" onclick="event.stopPropagation()">
            <div class="log-modal-header">
                <span class="log-modal-title" id="log-modal-title">Task Log</span>
                <button class="log-modal-close" onclick="Admin.closeLog()">&times;</button>
            </div>
            <div class="log-modal-tabs">
                <button class="log-tab active" id="log-tab-output" onclick="Admin.switchLogTab('output')">Output</button>
                <button class="log-tab" id="log-tab-error" onclick="Admin.switchLogTab('error')">Error</button>
            </div>
            <div class="log-modal-body">
                <pre class="log-content" id="log-content"></pre>
            </div>
        </div>
    </div>

    <!-- Timeline Tooltip (positioned absolutely) -->
    <div class="tl-tooltip" id="tl-tooltip"></div>

    <!-- Confirm -->
    <div class="confirm-overlay" id="confirm-overlay">
        <div class="confirm-dialog">
            <h3 id="confirm-title">Confirm</h3>
            <p id="confirm-message">Are you sure?</p>
            <div class="confirm-buttons">
                <button class="confirm-btn cancel" onclick="Admin.cancelConfirm()">Cancel</button>
                <button class="confirm-btn action" id="confirm-btn" onclick="Admin.executeConfirm()">Confirm</button>
            </div>
        </div>
    </div>

    <script src="/js/admin.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>

'@
    Write-PodeHtmlResponse -Value $html
}
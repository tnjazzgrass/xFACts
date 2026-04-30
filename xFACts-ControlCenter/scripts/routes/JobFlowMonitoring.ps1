# ============================================================================
# xFACts Control Center - JobFlow Monitoring Page
# Location: E:\xFACts-ControlCenter\scripts\routes\JobFlowMonitoring.ps1
#
# Renders the JobFlow monitoring dashboard page with real-time DM queue
# visibility, process status, today's summary, and execution history.
# CSS: /css/jobflow-monitoring.css
# JS:  /js/jobflow-monitoring.js
# APIs: JobFlowMonitoring-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: JobFlow)
#
# CHANGELOG
# ---------
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle.
# ============================================================================

Add-PodeRoute -Method Get -Path '/jobflow-monitoring' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/jobflow-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/jobflow-monitoring') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering) ---
    $ctx = Get-UserContext -WebEvent $WebEvent

    # --- Render dynamic nav bar and page header from RBAC_NavRegistry ---
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/jobflow-monitoring'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/jobflow-monitoring'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/jobflow-monitoring'

    $html = @"

<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/jobflow-monitoring.css">
    <link rel="stylesheet" href="/css/engine-events.css">
</head>
<body>
$navHtml

    <div class="header-bar">
        <div>
            $headerHtml
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span class="live-indicator"></span>
                <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
            <div class="engine-row">
                <div class="engine-card" id="card-engine-jobflow">
                    <span class="engine-label">JobFlow</span>
                    <div class="engine-bar disabled" id="engine-bar-jobflow"></div>
                    <span class="engine-countdown" id="engine-cd-jobflow">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>

    <div id="connection-error" class="connection-error"></div>

    <!-- Two Column Layout -->
    <div class="grid-layout">

        <!-- Left Column - Daily Summary and Live Activity -->
        <div class="grid-column">
            <!-- Daily Summary -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Daily Summary</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="daily-summary" class="summary-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>

            <!-- Live Activity from Debt Manager -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Live Activity</h2>
                    <div class="section-header-right">
                        <button id="btn-pending-queue" class="refresh-btn pending-btn" title="View pending queue">
                            &#9202; Pending <span id="pending-count-badge" class="pending-badge hidden">0</span>
                        </button>
                        <span class="refresh-badge-live" title="Refreshes on live interval"><span class="badge-dot"></span></span>
                    </div>
                </div>

                <!-- Currently Executing Jobs -->
                <div class="subsection">
                    <h3 class="subsection-title">Currently Executing</h3>
                    <div id="executing-jobs" class="activity-content">
                        <div class="loading">Loading...</div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Right Column - Status, History -->
        <div class="grid-column">
            <!-- Process Status Dashboard -->
            <div class="section section-compact">
                <div class="section-header">
                    <h2 class="section-title">Process Status</h2>
                    <div class="section-header-right">
                        <button id="btn-app-tasks" class="section-action-btn" title="View and manage scheduled tasks across application servers">
                            <span class="btn-icon">&#9881;</span> App Server Tasks
                        </button>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="process-status" class="status-grid">
                    <div class="loading">Loading...</div>
                </div>
            </div>

            <!-- Flow/Job History - Expandable, at bottom -->
            <div class="section section-history">
                <div class="section-header">
                    <h2 class="section-title">Execution History</h2>
                    <div class="section-header-right">
                        <span class="history-count" id="history-count"></span>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="execution-history" class="history-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
        </div>

    </div>

    <!-- Flow Details Slideout -->
    <div id="flow-slideout" class="slideout">
        <div class="slideout-content">
            <div class="slideout-header">
                <h2 id="slideout-title">Flow Details</h2>
                <button class="slideout-close" onclick="closeSlideout()">&times;</button>
            </div>
            <div id="slideout-body" class="slideout-body">
                <div class="loading">Loading...</div>
            </div>
        </div>
    </div>
    <div id="slideout-overlay" class="slideout-overlay" onclick="closeSlideout()"></div>

    <!-- App Server Tasks Modal -->
    <div id="tasks-modal-overlay" class="modal-overlay hidden">
        <div class="modal-content modal-wide">
            <div class="modal-header">
                <h3>App Server Task Distribution</h3>
                <button class="modal-close" onclick="closeTasksModal()">&times;</button>
            </div>
            <div class="modal-body">
                <p class="modal-subtitle">Click a cell to stage changes. Only one server should be enabled per flow.</p>
                <div id="tasks-grid" class="tasks-grid">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            <div class="modal-footer">
                <span id="pending-changes-indicator" class="hidden"></span>
                <button id="btn-apply-changes" class="hidden" onclick="showApplyConfirmation()">Apply Changes</button>
                <button class="modal-btn modal-btn-cancel" onclick="closeTasksModal()">Close</button>
            </div>
        </div>
    </div>

    <!-- Confirmation Modal -->
    <div id="confirm-modal-overlay" class="modal-overlay hidden">
        <div class="confirm-modal">
            <div class="confirm-modal-header">
                <h3>Confirm Changes</h3>
            </div>
            <div class="confirm-modal-body" id="confirm-changes-body">
            </div>
            <div class="confirm-modal-footer">
                <button id="btn-confirm-cancel" onclick="cancelAllChanges()">Cancel</button>
                <button id="btn-confirm-apply" onclick="applyAllChanges()">Apply</button>
            </div>
        </div>
    </div>

    <!-- ConfigSync Modal -->
    <div id="configsync-modal-overlay" class="modal-overlay hidden">
        <div class="modal-content">
            <div class="modal-header">
                <h3>Flow Configuration</h3>
                <button class="modal-close" onclick="closeConfigSyncModal()">&times;</button>
            </div>
            <div class="cs-selector-bar">
                <label>Flow:</label>
                <select id="configsync-flow-select" onchange="onConfigSyncFlowSelected()">
                    <option value="">Loading...</option>
                </select>
            </div>
            <div id="configsync-body" class="modal-body">
                <div class="loading">Loading...</div>
            </div>
            <div class="modal-footer">
                <div id="configsync-footer-actions"></div>
                <button class="modal-btn modal-btn-cancel" onclick="closeConfigSyncModal()">Close</button>
            </div>
        </div>
    </div>

    <!-- ConfigSync Confirmation Dialog -->
    <div id="cs-confirm-overlay" class="modal-overlay hidden">
        <div class="cs-confirm-modal">
            <div class="cs-confirm-modal-header">
                <h3>Confirm Changes</h3>
            </div>
            <div id="cs-confirm-body" class="cs-confirm-modal-body">
            </div>
            <div class="cs-confirm-modal-footer">
                <button class="modal-btn modal-btn-cancel" onclick="closeConfigSyncConfirmation()">Cancel</button>
                <button class="cs-btn cs-btn-primary" onclick="confirmAndSaveConfigSync()">Apply Changes</button>
            </div>
        </div>
    </div>

    <script src="/js/jobflow-monitoring.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>

"@
    Write-PodeHtmlResponse -Value $html
}
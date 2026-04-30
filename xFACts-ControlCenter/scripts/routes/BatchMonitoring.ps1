# ============================================================================
# xFACts Control Center - Batch Monitoring Page
# Location: E:\xFACts-ControlCenter\scripts\routes\BatchMonitoring.ps1
#
# Renders the Batch Monitoring dashboard page showing batch lifecycle
# tracking across NB, PMT, and BDL batch types with live activity, process
# health, and historical analysis with phase duration breakdowns.
#
# CSS: /css/batch-monitoring.css
# JS:  /js/batch-monitoring.js
# APIs: BatchMonitoring-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: BatchOps)
#
# CHANGELOG
# ---------
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle.
# ============================================================================

Add-PodeRoute -Method Get -Path '/batch-monitoring' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/batch-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/batch-monitoring') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering) ---
    $ctx = Get-UserContext -WebEvent $WebEvent

    # --- Render dynamic nav bar and page header from RBAC_NavRegistry ---
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/batch-monitoring'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/batch-monitoring'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/batch-monitoring'

    $html = @"

<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/batch-monitoring.css">
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
                <div class="engine-card" id="card-engine-nb">
                    <span class="engine-label">NB</span>
                    <div class="engine-bar disabled" id="engine-bar-nb"></div>
                    <span class="engine-countdown" id="engine-cd-nb">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-pmt">
                    <span class="engine-label">PMT</span>
                    <div class="engine-bar disabled" id="engine-bar-pmt"></div>
                    <span class="engine-countdown" id="engine-cd-pmt">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-bdl">
                    <span class="engine-label">BDL</span>
                    <div class="engine-bar disabled" id="engine-bar-bdl"></div>
                    <span class="engine-countdown" id="engine-cd-bdl">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-summary">
                    <span class="engine-label">Summary</span>
                    <div class="engine-bar disabled" id="engine-bar-summary"></div>
                    <span class="engine-countdown" id="engine-cd-summary">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>

    <div id="connection-error" class="connection-error"></div>

    <!-- Two Column Layout -->
    <div class="grid-layout">

        <!-- Left Column: Daily Summary, Active Batches -->
        <div class="grid-column">

            <!-- Daily Batch Summary -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Today's Activity</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="daily-summary" class="summary-cards">
                    <div class="loading">Loading...</div>
                </div>
            </div>

            <!-- Active Batches (Unified View) -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Active Batches</h2>
                    <div class="section-header-right">
                        <div class="filter-group">
                            <button class="active-filter-btn active" data-filter="ALL">All</button>
                            <button class="active-filter-btn" data-filter="NB">NB</button>
                            <button class="active-filter-btn" data-filter="PMT">PMT</button>
                            <button class="active-filter-btn" data-filter="BDL">BDL</button>
                        </div>
                        <span class="refresh-badge-live" title="Refreshes on live interval"><span class="badge-dot"></span></span>
                    </div>
                </div>
                <div id="active-batches" class="activity-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
        </div>

        <!-- Right Column: Process Status, Batch History -->
        <div class="grid-column">

            <!-- Process Status -->
            <div class="section section-compact">
                <div class="section-header">
                    <h2 class="section-title">Process Status</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="process-status" class="status-grid">
                    <div class="loading">Loading...</div>
                </div>
            </div>

            <!-- Batch History (Tree Drill-Down) -->
            <div class="section section-history">
                <div class="section-header">
                    <h2 class="section-title">Batch History</h2>
                    <div class="section-header-right">
                        <div class="filter-group">
                            <button class="filter-btn active" data-filter="ALL">All</button>
                            <button class="filter-btn" data-filter="NB">NB</button>
                            <button class="filter-btn" data-filter="PMT">PMT</button>
                            <button class="filter-btn" data-filter="BDL">BDL</button>
                        </div>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="batch-history" class="history-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
        </div>

    </div>

    <!-- Batch Detail Slideout -->
    <div id="batch-slideout" class="slideout">
        <div class="slideout-content">
            <div class="slideout-header">
                <h2 id="slideout-title">Batch Details</h2>
                <button class="slideout-close" onclick="closeSlideout()">&times;</button>
            </div>
            <div id="slideout-body" class="slideout-body">
                <div class="loading">Loading...</div>
            </div>
        </div>
    </div>
    <div id="slideout-overlay" class="slideout-overlay" onclick="closeSlideout()"></div>

    <script src="/js/batch-monitoring.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>

"@
    Write-PodeHtmlResponse -Value $html
}
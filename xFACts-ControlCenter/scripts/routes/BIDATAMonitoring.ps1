# ============================================================================
# xFACts Control Center - BIDATA Monitoring Page
# Location: E:\xFACts-ControlCenter\scripts\routes\BIDATAMonitoring.ps1
#
# Renders the BIDATA Daily Build monitoring dashboard page.
# CSS: /css/bidata-monitoring.css
# JS:  /js/bidata-monitoring.js
# APIs: BIDATAMonitoring-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: BIDATA)
#
# CHANGELOG
# ---------
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle.
# ============================================================================

Add-PodeRoute -Method Get -Path '/bidata-monitoring' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/bidata-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/bidata-monitoring') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering) ---
    $ctx = Get-UserContext -WebEvent $WebEvent

    # --- Render dynamic nav bar and page header from RBAC_NavRegistry ---
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/bidata-monitoring'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/bidata-monitoring'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/bidata-monitoring'

    $html = @"

<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/bidata-monitoring.css">
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
                <div class="engine-card" id="card-engine-bidata">
                    <span class="engine-label">BIDATA</span>
                    <div class="engine-bar disabled" id="engine-bar-bidata"></div>
                    <span class="engine-countdown" id="engine-cd-bidata">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>

    <div id="connection-error" class="connection-error"></div>

    <!-- Two Column Layout -->
    <div class="grid-layout">

        <!-- Left Column -->
        <div class="grid-column">
            <!-- Live Activity -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Live Activity</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="live-activity" class="activity-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>

            <!-- Current Build Execution -->
            <div class="section section-execution">
                <div class="section-header">
                    <h2 class="section-title">Current Build Execution</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="current-build-execution" class="execution-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
        </div>

        <!-- Right Column -->
        <div class="grid-column">
            <!-- Duration Trend -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Duration Trend</h2>
                    <div class="section-header-right">
                        <div class="trend-controls">
                            <button class="trend-btn active" data-days="30">30d</button>
                            <button class="trend-btn" data-days="60">60d</button>
                            <button class="trend-btn" data-days="90">90d</button>
                            <button class="trend-btn" data-days="custom">Custom</button>
                        </div>
                        <span class="refresh-badge-action" title="Refreshes on date range selection">&#128260;</span>
                    </div>
                </div>
                <div id="duration-trend" class="trend-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>

            <!-- Build History -->
            <div class="section section-history">
                <div class="section-header">
                    <h2 class="section-title">Build History</h2>
                    <div class="section-header-right">
                        <span class="history-count" id="history-count"></span>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="build-history" class="history-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
        </div>

    </div>

    <!-- Build Details Slideout -->
    <div id="build-slideout" class="slideout">
        <div class="slideout-content">
            <div class="slideout-header">
                <h2 id="slideout-title">Build Details</h2>
                <button class="slideout-close" onclick="closeSlideout()">&times;</button>
            </div>
            <div id="slideout-body" class="slideout-body">
                <div class="loading">Loading...</div>
            </div>
        </div>
    </div>
    <div id="slideout-overlay" class="slideout-overlay" onclick="closeSlideout()"></div>

    <!-- Date Range Modal -->
    <div id="date-modal-overlay" class="modal-overlay">
        <div class="modal-content">
            <div class="modal-header">
                <h3>Custom Date Range</h3>
                <button class="modal-close" onclick="closeDateRangeModal()">&times;</button>
            </div>
            <div class="modal-body">
                <div class="date-field">
                    <label for="date-from">From</label>
                    <input type="date" id="date-from">
                </div>
                <div class="date-field">
                    <label for="date-to">To</label>
                    <input type="date" id="date-to">
                </div>
            </div>
            <div class="modal-footer">
                <button class="modal-btn modal-btn-cancel" id="modal-cancel">Cancel</button>
                <button class="modal-btn modal-btn-apply" id="modal-apply">Apply</button>
            </div>
        </div>
    </div>

    <script src="/js/bidata-monitoring.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>

"@
    Write-PodeHtmlResponse -Value $html
}
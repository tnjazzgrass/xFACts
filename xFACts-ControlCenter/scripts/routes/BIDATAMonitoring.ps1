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
# 2026-04-30  Phase 4 (Standardization): full alignment to shared infrastructure.
#               - Added body class="section-platform" so H1 color is driven
#                 by shared CSS via RBAC_NavRegistry section_key.
#               - Renamed connection banner placeholder from id/class
#                 connection-error to connection-banner matching the
#                 engine-events.js rename.
#               - Build details slideout migrated from page-local
#                 .slideout/.slideout-overlay/.slideout-header/.slideout-body
#                 markup to shared .slide-panel-overlay/.slide-panel/
#                 .slide-panel-header/.slide-panel-body/.modal-close from
#                 engine-events.css (Section 9). Default 550px width fits
#                 the build summary + step table content.
#               - Custom date range modal migrated from page-local
#                 .modal-overlay/.modal-content/.modal-header/.modal-body/
#                 .modal-footer/.modal-btn-* markup to shared
#                 .xf-modal-overlay.hidden/.xf-modal/.xf-modal-header/
#                 .xf-modal-body/.modal-close/.xf-modal-actions/
#                 .xf-modal-btn-cancel/.xf-modal-btn-primary from
#                 engine-events.css (Section 10).
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
<body class="section-platform">
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

    <div id="connection-banner" class="connection-banner"></div>

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
            <div class="section section-fill section-execution">
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
            <div class="section section-fill section-history">
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

    <!-- ================================================================
         BUILD DETAILS SLIDEOUT
         Shared .slide-panel-* infrastructure from engine-events.css.
         Default 550px width fits the build summary + step detail table.
         ================================================================ -->
    <div id="build-slideout-overlay" class="slide-panel-overlay" onclick="closeSlideout()"></div>
    <div id="build-slideout" class="slide-panel">
        <div class="slide-panel-header">
            <h3 id="slideout-title">Build Details</h3>
            <button class="modal-close" onclick="closeSlideout()">&times;</button>
        </div>
        <div class="slide-panel-body" id="slideout-body">
            <div class="loading">Loading...</div>
        </div>
    </div>

    <!-- ================================================================
         CUSTOM DATE RANGE MODAL
         Shared .xf-modal-* infrastructure from engine-events.css.
         Default 460px width is appropriate for a two-field date picker.
         ================================================================ -->
    <div id="date-modal-overlay" class="xf-modal-overlay hidden" onclick="if(event.target === this) closeDateRangeModal()">
        <div class="xf-modal">
            <div class="xf-modal-header">
                <h3>Custom Date Range</h3>
                <button class="modal-close" onclick="closeDateRangeModal()">&times;</button>
            </div>
            <div class="xf-modal-body">
                <div class="date-field">
                    <label for="date-from">From</label>
                    <input type="date" id="date-from">
                </div>
                <div class="date-field">
                    <label for="date-to">To</label>
                    <input type="date" id="date-to">
                </div>
            </div>
            <div class="xf-modal-actions">
                <button class="xf-modal-btn-cancel" id="modal-cancel">Cancel</button>
                <button class="xf-modal-btn-primary" id="modal-apply">Apply</button>
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
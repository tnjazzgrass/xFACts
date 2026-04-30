# ============================================================================
# xFACts Control Center - Business Services Manager Dashboard
# Location: E:\xFACts-ControlCenter\scripts\routes\BusinessServices.ps1
#
# Manager-only dashboard for Business Services review request operations.
# Components:
#   - Live Activity: Real-time group summary cards from CRS5 (Live)
#   - Distribution:  Flip card showing user assignment status from xFACts (Event)
#   - History:       Drill-down tree with group filter badges from xFACts (Event)
#
# CSS: /css/business-services.css, /css/engine-events.css
# JS:  /js/business-services.js, /js/engine-events.js
# APIs: BusinessServices-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessServices)
#
# CHANGELOG
# ---------
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle. Dropped the
#             $access.IsDeptOnly branching since Get-NavBarHtml already
#             filters nav items by user permissions (a dept-only user
#             naturally sees only Home + their dept page).
# ============================================================================

Add-PodeRoute -Method Get -Path '/departmental/business-services' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/business-services'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/business-services') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering) ---
    $ctx = Get-UserContext -WebEvent $WebEvent

    # --- Render dynamic nav bar and page header from RBAC_NavRegistry ---
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/departmental/business-services'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/departmental/business-services'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/departmental/business-services'

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/business-services.css">
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
                <div class="engine-card" id="card-engine-collect">
                    <span class="engine-label">Collect</span>
                    <div class="engine-bar disabled" id="engine-bar-collect"></div>
                    <span class="engine-countdown" id="engine-cd-collect">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-distribute">
                    <span class="engine-label">Distribute</span>
                    <div class="engine-bar disabled" id="engine-bar-distribute"></div>
                    <span class="engine-countdown" id="engine-cd-distribute">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>

    <div id="connection-error" class="connection-error"></div>

    <!-- ================================================================ -->
    <!-- LIVE ACTIVITY + DISTRIBUTION ROW                                 -->
    <!-- ================================================================ -->
    <div class="top-row">
        <!-- Live Activity Cards -->
        <div class="section" id="live-activity-section">
            <div class="section-header">
                <h2>Live Activity</h2>
                <span class="refresh-badge-live" title="Refreshes on live polling timer"><span class="badge-dot"></span></span>
            </div>
            <div class="section-body">
                <div id="live-activity-loading" class="loading">Loading live activity...</div>
                <div id="live-activity-cards" class="activity-cards hidden"></div>
            </div>
        </div>

        <!-- Distribution Flip Card -->
        <div class="section section-narrow" id="distribution-section">
            <div class="section-header">
                <h2>Distribution</h2>
                <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
            </div>
            <div class="section-body">
                <div id="distribution-loading" class="loading">Loading...</div>
                <div id="distribution-cards" class="distribution-cards hidden"></div>
            </div>
        </div>
    </div>

    <!-- ================================================================ -->
    <!-- HISTORY SECTION                                                  -->
    <!-- ================================================================ -->
    <div class="section" id="history-section">
        <div class="section-header">
            <h2>Request History</h2>
            <div class="section-header-right">
                <div id="group-badges" class="group-badges"></div>
                <span id="history-count" class="badge-count"></span>
                <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
            </div>
        </div>
        <div class="section-body">
            <div id="history-loading" class="loading">Loading history...</div>
            <div id="history-tree" class="hidden"></div>
        </div>
    </div>

    <!-- ================================================================ -->
    <!-- SLIDEOUT PANEL (day details, user requests)                      -->
    <!-- ================================================================ -->
    <div id="slideout" class="slideout">
        <div class="slideout-header">
            <h3 id="slideout-title">Details</h3>
            <button class="slideout-close" onclick="closeSlideout()">&times;</button>
        </div>
        <div id="slideout-body" class="slideout-body"></div>
    </div>
    <div id="slideout-backdrop" class="slideout-backdrop" onclick="closeSlideout()"></div>

    <!-- ================================================================ -->
    <!-- REQUEST DETAIL MODAL (comment view)                              -->
    <!-- ================================================================ -->
    <div id="detail-modal" class="modal-overlay hidden">
        <div class="modal-dialog modal-wide">
            <div class="modal-header">
                <h3 id="detail-modal-title">Request Detail</h3>
                <button class="modal-close" onclick="closeDetailModal()">&times;</button>
            </div>
            <div id="detail-modal-body" class="modal-body">
                <div class="loading">Loading...</div>
            </div>
        </div>
    </div>

    <script src="/js/business-services.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
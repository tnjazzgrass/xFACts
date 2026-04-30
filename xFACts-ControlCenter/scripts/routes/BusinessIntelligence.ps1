# ============================================================================
# xFACts Control Center - Business Intelligence Departmental Page
# Location: E:\xFACts-ControlCenter\scripts\routes\BusinessIntelligence.ps1
#
# Departmental dashboard for the Business Intelligence team.
# Components:
#   - Tools & Processes tile row:
#       * Notice Recon: Horizontal status badges for daily reconciliation
#         processes (SndRight, Revspring, Validation, FAND). Each badge
#         is independently clickable to open a detail slideout.
#       * BDL Import: Links to Tools BDL Import page.
#       * LiveVox / SndRight Texting: Placeholder tiles for Phase 2 monitors.
#
# CSS: /css/business-intelligence.css, /css/engine-events.css
# JS:  /js/business-intelligence.js, /js/engine-events.js
# APIs: BusinessIntelligence-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.BusinessIntelligence)
#
# CHANGELOG
# ---------
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1, subtitle, and browser tab title
#             now render from RBAC_NavRegistry via Get-PageHeaderHtml and
#             Get-PageBrowserTitle. Dropped the $access.IsDeptOnly branching
#             since Get-NavBarHtml already filters nav items by user
#             permissions (a dept-only user naturally sees only Home + their
#             dept page). CSS link order normalized (page CSS first, then
#             engine-events.css) to match the rest of the platform.
#             Header retains its no-live-indicator form pending future live
#             polling on this page (BACKLOG: add live indicator if/when
#             real-time data sources are wired up).
# ============================================================================

Add-PodeRoute -Method Get -Path '/departmental/business-intelligence' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/business-intelligence'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/business-intelligence') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering) ---
    $ctx = Get-UserContext -WebEvent $WebEvent

    # --- Render dynamic nav bar and page header from RBAC_NavRegistry ---
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/departmental/business-intelligence'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/departmental/business-intelligence'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/departmental/business-intelligence'

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/business-intelligence.css">
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
                Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="BI.pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
        </div>
    </div>

    <div id="connection-error" class="connection-error"></div>

    <!-- ================================================================ -->
    <!-- TOOLS & PROCESSES                                                -->
    <!-- ================================================================ -->
    <div class="section" id="tools-section">
        <div class="section-header">
            <h2>Tools &amp; Processes</h2>
        </div>
        <div class="section-body">
            <div class="tool-cards">
                <!-- Notice Recon: status-badge tile (badges rendered/updated by JS) -->
                <div class="tool-card notice-recon-tile">
                    <div class="nr-badges" id="nr-badges"></div>
                    <div class="tool-label">Notice Recon</div>
                    <div class="tool-status">Daily Reconciliation</div>
                </div>
                <div class="tool-card" id="bdl-import-card" onclick="window.location.href='/bdl-import'">
                    <div class="tool-icon">&#128230;</div>
                    <div class="tool-label">BDL Import</div>
                    <div class="tool-status">Open</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128222;</div>
                    <div class="tool-label">LiveVox</div>
                    <div class="tool-status">Phase 2</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128172;</div>
                    <div class="tool-label">SndRight Texting</div>
                    <div class="tool-status">Phase 2</div>
                </div>
            </div>
        </div>
    </div>

    <!-- ================================================================ -->
    <!-- EXECUTION DETAIL SLIDEOUT                                        -->
    <!-- ================================================================ -->
    <div id="nr-detail-overlay" class="slide-panel-overlay" onclick="BI.closeDetail()"></div>
    <div id="nr-detail-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3 id="nr-detail-title">Execution Detail</h3>
            <button class="modal-close" onclick="BI.closeDetail()" title="Close">&times;</button>
        </div>
        <div class="slide-panel-body">
            <div id="nr-detail-content"></div>
        </div>
    </div>

    <script src="/js/business-intelligence.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
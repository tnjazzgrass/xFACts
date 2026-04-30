# ============================================================================
# xFACts Control Center - Applications & Integration Departmental Page
# Location: E:\xFACts-ControlCenter\scripts\routes\ApplicationsIntegration.ps1
#
# Departmental dashboard for the Applications & Integration team.
# Components:
#   - BDL Import: Card linking to the BDL Import workflow page
#   - Refresh Drools: Trigger rules engine refresh across DM app servers
#   - BDL Content Management: Admin-only catalog maintenance (slide-up panel)
#     with Global Configuration and Department Access modes
#   - Future: Additional toolkit functions migrated from Access DB
#
# CSS: /css/applications-integration.css
# JS:  /js/applications-integration.js
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.ApplicationsIntegration)
#
# CHANGELOG
# ---------
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle. Subtitle reverted
#             from "Departmental Operations & Tools" to standard
#             "Departmental Operations" in line with all departmental pages.
#             Admin-conditional sections ($pageIsAdmin) preserved.
# 2026-04-13  Added Refresh Drools card with environment selection modal
# ============================================================================

Add-PodeRoute -Method Get -Path '/departmental/applications-integration' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/applications-integration') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering) ---
    $ctx = Get-UserContext -WebEvent $WebEvent
    $pageIsAdmin = $access.Tier -eq 'admin'

    # --- Render dynamic nav bar and page header from RBAC_NavRegistry ---
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/departmental/applications-integration'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/departmental/applications-integration'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/departmental/applications-integration'

    # --- Admin-only sections (page body, not nav) ---
    $adminSection = ''
    $adminPanelHtml = ''
    if ($pageIsAdmin) {
        $adminSection = @'
    <!-- ================================================================ -->
    <!-- ADMIN TOOLS (Admin-only)                                         -->
    <!-- ================================================================ -->
    <div class="section" id="admin-section">
        <div class="section-header">
            <h2>Administration</h2>
            <span class="section-subtitle">Catalog management, configuration, and DM operations</span>
        </div>
        <div class="section-body">
            <div class="tool-cards">
                <div class="tool-card admin-tool" onclick="BdlCatalog.open()">
                    <div class="tool-icon">&#128218;</div>
                    <div class="tool-label">BDL Content Management</div>
                    <div class="tool-status admin-badge">Entity Types &amp; Field Settings</div>
                </div>
                <div class="tool-card admin-tool" onclick="DmJobs.refreshDrools()">
                    <div class="tool-icon">&#9881;</div>
                    <div class="tool-label">Refresh Drools</div>
                    <div class="tool-status admin-badge">Rules Engine Refresh</div>
                </div>
                <div class="tool-card admin-tool" onclick="DmJobs.releaseNotices()">
                    <div class="tool-icon">&#128196;</div>
                    <div class="tool-label">Release Notices</div>
                    <div class="tool-status admin-badge">Release Document Requests</div>
                </div>
                <div class="tool-card admin-tool" onclick="DmJobs.balanceSync()">
                    <div class="tool-icon">&#128176;</div>
                    <div class="tool-label">Balance Sync</div>
                    <div class="tool-status admin-badge">Update Account Balances</div>
                </div>
            </div>
        </div>
    </div>
'@

        $adminPanelHtml = @'
    <!-- ================================================================ -->
    <!-- BDL CATALOG MANAGEMENT — Slide-Up Panel (Tier 1: Format List)    -->
    <!-- ================================================================ -->
    <div id="bdlcat-backdrop" class="bdlcat-backdrop" onclick="BdlCatalog.close()"></div>
    <div id="bdlcat-panel" class="bdlcat-panel">
        <div class="bdlcat-handle" onclick="BdlCatalog.close()">
            <div class="bdlcat-handle-bar"></div>
        </div>
        <div class="bdlcat-header">
            <div class="bdlcat-header-left">
                <h2 id="bdlcat-title" class="bdlcat-title">BDL Content Management</h2>
                <span id="bdlcat-count" class="bdlcat-count"></span>
            </div>
            <button class="bdlcat-close" onclick="BdlCatalog.close()">&times;</button>
        </div>
        <div id="bdlcat-mode-selector" class="bdlcat-mode-selector"></div>
        <div id="bdlcat-status" class="bdlcat-status"></div>
        <div id="bdlcat-body" class="bdlcat-body"></div>
    </div>

    <!-- ================================================================ -->
    <!-- BDL CATALOG MANAGEMENT — Detail Slideout (Tier 2: Elements)      -->
    <!-- ================================================================ -->
    <div id="bdlcat-detail" class="bdlcat-detail">
        <div class="bdlcat-detail-header">
            <button class="bdlcat-detail-back" onclick="BdlCatalog.closeDetail()" title="Back to format list">&#9664;</button>
            <h3 id="bdlcat-detail-title" class="bdlcat-detail-title"></h3>
            <span id="bdlcat-detail-count" class="bdlcat-detail-count"></span>
        </div>
        <div id="bdlcat-detail-status" class="bdlcat-detail-status"></div>
        <div id="bdlcat-detail-body" class="bdlcat-detail-body"></div>
    </div>
'@
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/applications-integration.css">
    <link rel="stylesheet" href="/css/engine-events.css">
</head>
<body>
$navHtml

    <div class="header-bar">
        <div>
            $headerHtml
        </div>
    </div>

    <div id="connection-error" class="connection-error"></div>

    <!-- ================================================================ -->
    <!-- DM TOOLS                                                         -->
    <!-- ================================================================ -->
    <div class="section" id="tools-section">
        <div class="section-header">
            <h2>Debt Manager Tools</h2>
            <span class="section-subtitle">File imports, API operations, and scheduled job management</span>
        </div>
        <div class="section-body">
            <div class="tool-cards">
                <div class="tool-card" onclick="window.location.href='/bdl-import'">
                    <div class="tool-icon">&#128230;</div>
                    <div class="tool-label">BDL Import</div>
                    <div class="tool-status">Bulk Data Load</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128100;</div>
                    <div class="tool-label">Consumer Ops</div>
                    <div class="tool-status">Phase 4</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128179;</div>
                    <div class="tool-label">Payment Import</div>
                    <div class="tool-status">Future</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128196;</div>
                    <div class="tool-label">CDL Import</div>
                    <div class="tool-status">Future</div>
                </div>
                <div class="tool-card placeholder">
                    <div class="tool-icon">&#128268;</div>
                    <div class="tool-label">API Caller</div>
                    <div class="tool-status">Future</div>
                </div>
            </div>
        </div>
    </div>

    $adminSection

    $adminPanelHtml

    <script src="/js/engine-events.js"></script>
    <script src="/js/applications-integration.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
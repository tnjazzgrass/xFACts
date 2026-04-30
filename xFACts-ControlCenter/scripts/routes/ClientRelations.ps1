# ============================================================================
# xFACts Control Center - Client Relations Dashboard
# Location: E:\xFACts-ControlCenter\scripts\routes\ClientRelations.ps1
#
# Departmental page for Client Relations team.
# Components:
#   - Summary Cards: Total consumers, total accounts, rejection reason breakdown (Live)
#   - Reg F Queue:   Expandable consumer/account tree with sorting and filtering (Live)
#
# CSS: /css/client-relations.css, /css/engine-events.css
# JS:  /js/client-relations.js, /js/engine-events.js
# APIs: ClientRelations-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: DeptOps.ClientRelations)
#
# CHANGELOG
# ---------
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1, subtitle, and browser tab title
#             now render from RBAC_NavRegistry via Get-PageHeaderHtml and
#             Get-PageBrowserTitle. Dropped the $access.IsDeptOnly branching
#             since Get-NavBarHtml already filters nav items by user
#             permissions (a dept-only user naturally sees only Home + their
#             dept page). Custom cache indicator preserved (heavy queries
#             use page-level caching rather than the standard live indicator).
# ============================================================================

Add-PodeRoute -Method Get -Path '/departmental/client-relations' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/client-relations'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/client-relations') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering) ---
    $ctx = Get-UserContext -WebEvent $WebEvent

    # --- Render dynamic nav bar and page header from RBAC_NavRegistry ---
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/departmental/client-relations'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/departmental/client-relations'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/departmental/client-relations'

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/client-relations.css">
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
                <span id="cache-indicator" class="cache-indicator" title="Serving cached data">&#9679;</span>
                <span id="cache-label">Cached</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data (bypasses cache)">&#8635;</button>
            </div>
            <div class="engine-row" id="engine-row">
                <!-- Engine cards will be added here when collectors are implemented -->
            </div>
        </div>
    </div>

    <div id="connection-error" class="connection-error"></div>

    <!-- ================================================================ -->
    <!-- SUMMARY CARDS                                                    -->
    <!-- ================================================================ -->
    <div class="section" id="summary-section">
        <div class="section-header">
            <h2>Reg F Compliance Queue</h2>
            <span class="refresh-badge-live" title="Refreshes on live polling timer"><span class="badge-dot"></span></span>
        </div>
        <div class="section-body">
            <div id="summary-loading" class="loading">Loading summary...</div>
            <div id="summary-cards" class="summary-cards hidden"></div>
        </div>
    </div>

    <!-- ================================================================ -->
    <!-- QUEUE TABLE (Consumer/Account Tree)                              -->
    <!-- ================================================================ -->
    <div class="section" id="queue-section">
        <div class="section-header">
            <h2>Queue Detail</h2>
            <div class="section-controls">
                <input type="text" id="queue-search" class="search-input" placeholder="Search consumers...">
                <div id="reason-filters" class="reason-filters"></div>
                <span class="refresh-badge-live" title="Refreshes on live polling timer"><span class="badge-dot"></span></span>
            </div>
        </div>
        <div class="section-body section-body-table">
            <div id="queue-loading" class="loading">Loading queue...</div>
            <div id="queue-table" class="queue-scroll-container hidden"></div>
        </div>
    </div>

    <script src="/js/client-relations.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
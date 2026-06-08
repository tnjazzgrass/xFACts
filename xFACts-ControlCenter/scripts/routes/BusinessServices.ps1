<#
.SYNOPSIS
    Business Services departmental dashboard page route.

.DESCRIPTION
    Manager dashboard for Business Services review request operations. Renders
    three sections: Live Activity (real-time group summary cards polled from
    CRS5), Distribution (per-group flip cards showing user assignment status
    from xFACts, refreshed on engine events), and Request History (a
    year/month/day drill-down with group filter badges from xFACts, refreshed
    on engine events). The page consumes engine events for the
    Collect-BSReviewRequests and Distribute-BSReviewRequests orchestrator
    processes via the shared chrome. Page chrome, nav, header, banners, and
    overlays are supplied by xFACts-CCShared.psm1 and cc-shared.css/js.

.COMPONENT
    DeptOps.BusinessServices

.NOTES
    File Name : BusinessServices.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\BusinessServices.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this route file, most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-02  Refactored to the CC File Format standard: adopted the cc- chrome
#             contract (cc-header-bar, cc-refresh-info, cc-engine-row, cc-section,
#             cc-slide-overlay, cc-modal-overlay), data-cc-page / data-cc-prefix
#             body attributes, data-action-* event wiring in place of inline
#             onclick handlers, the unified overlay constructs (slideout and
#             modal), and the single cc-shared.js script reference. Page-local
#             content classes carry the bsv- prefix.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml. Page H1 link, title, subtitle, and browser tab
#             title now render from RBAC_NavRegistry via Get-PageHeaderHtml and
#             Get-PageBrowserTitle.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the GET /departmental/business-services page route. Performs the
   page-level RBAC access check, resolves the user context and the shared
   nav / header / banner fragments, and emits the page HTML shell with the
   Live Activity, Distribution, and History sections plus the day-detail
   slideout and request-detail modal overlays.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/departmental/business-services' -Authentication 'ADLogin' -ScriptBlock {
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/business-services'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/business-services') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent
    $navHtml = Get-NavBarHtml -UserContext $ctx -CurrentPageRoute '/departmental/business-services'
    $headerHtml = Get-PageHeaderHtml -PageRoute '/departmental/business-services'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/departmental/business-services'
    $bannerHtml = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/business-services.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-departmental" data-cc-page="business-services" data-cc-prefix="bsv">
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
            <div class="cc-engine-row">
                <div class="cc-card-engine" id="cc-card-engine-collect">
                    <span class="cc-engine-label">Collect</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-collect"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-collect"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-distribute">
                    <span class="cc-engine-label">Distribute</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-distribute"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-distribute"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div class="bsv-top-row">
        <div class="cc-section" id="bsv-live-activity-section">
            <div class="cc-section-header">
                <h2 class="cc-section-title">Live Activity</h2>
                <div class="cc-section-header-right">
                    <span class="cc-refresh-badge-live" title="Refreshes on live polling timer"><span class="cc-refresh-badge-dot"></span></span>
                </div>
            </div>
            <div class="bsv-section-body">
                <div id="bsv-connection-error" class="bsv-no-activity bsv-hidden"></div>
                <div id="bsv-live-activity-loading" class="bsv-loading">Loading live activity...</div>
                <div id="bsv-live-activity-cards" class="bsv-activity-cards bsv-hidden"></div>
            </div>
        </div>

        <div class="cc-section" id="bsv-distribution-section">
            <div class="cc-section-header">
                <h2 class="cc-section-title">Distribution</h2>
                <div class="cc-section-header-right">
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
            </div>
            <div class="bsv-section-body">
                <div id="bsv-distribution-loading" class="bsv-loading">Loading...</div>
                <div id="bsv-distribution-cards" class="bsv-distribution-cards bsv-hidden"></div>
            </div>
        </div>
    </div>

    <div class="cc-section" id="bsv-history-section">
        <div class="cc-section-header">
            <h2 class="cc-section-title">Request History</h2>
            <div class="cc-section-header-right">
                <div id="bsv-group-badges" class="bsv-group-badges"></div>
                <span id="bsv-history-count" class="cc-section-title"></span>
                <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
            </div>
        </div>
        <div class="bsv-section-body">
            <div id="bsv-history-loading" class="bsv-loading">Loading history...</div>
            <div id="bsv-history-tree" class="bsv-hidden"></div>
        </div>
    </div>

    <!-- Day-detail slideout: per-day group summary and per-user completed requests -->
    <div id="bsv-slideout-detail" class="cc-slide-overlay" data-action-click="bsv-close-slideout">
        <div class="cc-dialog cc-dialog-slide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="bsv-detail-slideout-title">Details</h3>
                <button class="cc-dialog-close" data-action-click="bsv-close-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="bsv-detail-slideout-body"></div>
        </div>
    </div>

    <!-- Request-detail modal: full record and comment for a single tracking id -->
    <div id="bsv-modal-detail" class="cc-modal-overlay cc-hidden" data-action-click="bsv-close-modal">
        <div class="cc-dialog cc-dialog-modal cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="bsv-detail-modal-title">Request Detail</h3>
                <button class="cc-dialog-close" data-action-click="bsv-close-modal">&times;</button>
            </div>
            <div class="cc-dialog-body" id="bsv-detail-modal-body"></div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
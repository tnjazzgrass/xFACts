<#
.SYNOPSIS
    Business Services departmental dashboard page route.

.DESCRIPTION
    Manager dashboard for Business Services. Renders a Business Services
    Tools section (a tool-card grid whose first live card opens the Request
    History slide-up, plus a live Profanity Redaction card and greyed-out
    future cards) above the Review Requests workspace. The workspace holds
    Live Activity (real-time group summary cards polled from CRS5) and
    Distribution (per-group flip cards showing user assignment status from
    xFACts, refreshed on engine events). Request History (a year/month/day
    drill-down with group filter badges from xFACts) is loaded on demand into
    a slide-up panel when its tool card is clicked. The page consumes engine
    events for the Collect-BSReviewRequests and Distribute-BSReviewRequests
    orchestrator processes via the shared chrome. Page chrome, nav, header,
    banners, and overlays are supplied by xFACts-CCShared.psm1 and
    cc-shared.css/js.

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

# 2026-06-11  Activated the Profanity Redaction tool card: the placeholder card
#             became a live button wired to the shared cc-open-redaction chrome
#             action, which opens the shared redaction modal in cc-shared.js. The
#             tool's logic, modal, and styling live in the shared layer; this
#             page contributes the tile and its two API endpoints.
# 2026-06-11  Reframed the page as a tool-card dashboard. Added a Business
#             Services Tools section (bsv-tool-cards grid) above the workspace,
#             with a live Request History card, a Profanity Redaction
#             placeholder, and greyed-out future cards. Renamed the Live
#             Activity section to Review Requests (bsv-review-requests-*).
#             Moved Request History out of its inline full-width section into a
#             cc-slideup-overlay (bsv-slideup-history) loaded on demand; the
#             group filter badges and history count moved into the slide-up's
#             header-actions. Distribution and the engine chrome are unchanged.
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
   Business Services Tools card grid, the Review Requests workspace (Live
   Activity and Distribution), and the history slide-up, day-detail slideout,
   and request-detail modal overlays.
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

    <div class="cc-section" id="bsv-tools-section">
        <div class="cc-section-header">
            <h2 class="cc-section-title">Business Services Tools</h2>
        </div>
        <div class="bsv-tool-cards">
            <button class="bsv-tool-card" data-action-click="bsv-open-history">
                <div class="bsv-tool-icon">&#128202;</div>
                <div class="bsv-tool-label">Review Request History</div>
                <div class="bsv-tool-status">Year / Month / Day Drill-Down</div>
            </button>
            <button class="bsv-tool-card" data-action-click="cc-open-redaction">
                <div class="bsv-tool-icon">&#128683;</div>
                <div class="bsv-tool-label">Profanity Redaction</div>
                <div class="bsv-tool-status">Redact AR Events</div>
            </button>
            <div class="bsv-tool-card bsv-placeholder">
                <div class="bsv-tool-icon"><svg xmlns="http://www.w3.org/2000/svg" width="42" height="28" viewBox="0 0 172.88213 114.26353"><g transform="matrix(1.25 0 0 -1.25 -294.83 549.09)"><g><path d="m304.47 438.5c-36.88-0.003-68.038-20.673-68.038-45.138 0-25.468 29.252-44.672 68.038-44.672 22.637 0 44.099 7.9562 57.413 21.281 7.3285 7.3333 11.359 15.643 11.351 23.391-0.01 12.063-7.106 23.393-19.981 31.906-12.909 8.5342-30.232 13.232-48.783 13.232" fill="#ffb612"/><path d="m256.89 363.45c-11.833 7.8921-18.351 18.519-18.351 29.915 0 22.921 30.81 43.028 65.931 43.031 36.735 0.002 66.636-19.302 66.658-43.031 0.006-7.1892-3.806-14.966-10.736-21.902-12.926-12.937-33.831-20.663-55.922-20.663-18.457 0-35.355 4.4945-47.58 12.651" fill="#203731"/><path d="m333.99 405.19c-5.2966 7.8889-16.894 13.36-30.55 13.36-18.743 0-33.941-10.31-33.941-23.026 0-12.715 10.728-23.88 33.941-23.867 13.94 0.006 25.148 6.0268 30.384 13.935l-39.595-0.0688-0.1217 10.286 68.732 0.024c0.0929-0.82461 0.18895-1.6284 0.18895-2.4642 0-19.798-26.216-35.847-58.553-35.847-32.335 0-58.55 16.048-58.55 35.847 0 19.798 27.771 36.454 58.55 36.574 25.619 0.0977 47.396-10.488 55.338-24.736l-25.822-0.016" fill="#fff"/></g></g></svg></div>
                <div class="bsv-tool-label">Allison's Choice</div>
                <div class="bsv-tool-status">Future</div>
            </div>
            <div class="bsv-tool-card bsv-placeholder">
                <div class="bsv-tool-icon"><svg xmlns="http://www.w3.org/2000/svg" width="42" height="28" viewBox="0 0 172.88213 114.26353"><g transform="matrix(1.25 0 0 -1.25 -294.83 549.09)"><g><path d="m304.47 438.5c-36.88-0.003-68.038-20.673-68.038-45.138 0-25.468 29.252-44.672 68.038-44.672 22.637 0 44.099 7.9562 57.413 21.281 7.3285 7.3333 11.359 15.643 11.351 23.391-0.01 12.063-7.106 23.393-19.981 31.906-12.909 8.5342-30.232 13.232-48.783 13.232" fill="#ffb612"/><path d="m256.89 363.45c-11.833 7.8921-18.351 18.519-18.351 29.915 0 22.921 30.81 43.028 65.931 43.031 36.735 0.002 66.636-19.302 66.658-43.031 0.006-7.1892-3.806-14.966-10.736-21.902-12.926-12.937-33.831-20.663-55.922-20.663-18.457 0-35.355 4.4945-47.58 12.651" fill="#203731"/><path d="m333.99 405.19c-5.2966 7.8889-16.894 13.36-30.55 13.36-18.743 0-33.941-10.31-33.941-23.026 0-12.715 10.728-23.88 33.941-23.867 13.94 0.006 25.148 6.0268 30.384 13.935l-39.595-0.0688-0.1217 10.286 68.732 0.024c0.0929-0.82461 0.18895-1.6284 0.18895-2.4642 0-19.798-26.216-35.847-58.553-35.847-32.335 0-58.55 16.048-58.55 35.847 0 19.798 27.771 36.454 58.55 36.574 25.619 0.0977 47.396-10.488 55.338-24.736l-25.822-0.016" fill="#fff"/></g></g></svg></div>
                <div class="bsv-tool-label">Allison's Choice</div>
                <div class="bsv-tool-status">Future</div>
            </div>
            <div class="bsv-tool-card bsv-placeholder">
                <div class="bsv-tool-icon"><svg xmlns="http://www.w3.org/2000/svg" width="42" height="28" viewBox="0 0 172.88213 114.26353"><g transform="matrix(1.25 0 0 -1.25 -294.83 549.09)"><g><path d="m304.47 438.5c-36.88-0.003-68.038-20.673-68.038-45.138 0-25.468 29.252-44.672 68.038-44.672 22.637 0 44.099 7.9562 57.413 21.281 7.3285 7.3333 11.359 15.643 11.351 23.391-0.01 12.063-7.106 23.393-19.981 31.906-12.909 8.5342-30.232 13.232-48.783 13.232" fill="#ffb612"/><path d="m256.89 363.45c-11.833 7.8921-18.351 18.519-18.351 29.915 0 22.921 30.81 43.028 65.931 43.031 36.735 0.002 66.636-19.302 66.658-43.031 0.006-7.1892-3.806-14.966-10.736-21.902-12.926-12.937-33.831-20.663-55.922-20.663-18.457 0-35.355 4.4945-47.58 12.651" fill="#203731"/><path d="m333.99 405.19c-5.2966 7.8889-16.894 13.36-30.55 13.36-18.743 0-33.941-10.31-33.941-23.026 0-12.715 10.728-23.88 33.941-23.867 13.94 0.006 25.148 6.0268 30.384 13.935l-39.595-0.0688-0.1217 10.286 68.732 0.024c0.0929-0.82461 0.18895-1.6284 0.18895-2.4642 0-19.798-26.216-35.847-58.553-35.847-32.335 0-58.55 16.048-58.55 35.847 0 19.798 27.771 36.454 58.55 36.574 25.619 0.0977 47.396-10.488 55.338-24.736l-25.822-0.016" fill="#fff"/></g></g></svg></div>
                <div class="bsv-tool-label">Allison's Choice</div>
                <div class="bsv-tool-status">Future</div>
            </div>
        </div>
    </div>

    <div class="bsv-top-row">
        <div class="cc-section" id="bsv-review-requests-section">
            <div class="cc-section-header">
                <h2 class="cc-section-title">Review Requests</h2>
                <div class="cc-section-header-right">
                    <span class="cc-refresh-badge-live" title="Refreshes on live polling timer"><span class="cc-refresh-badge-dot"></span></span>
                </div>
            </div>
            <div class="bsv-section-body">
                <div id="bsv-connection-error" class="bsv-no-activity bsv-hidden"></div>
                <div id="bsv-review-requests-loading" class="bsv-loading">Loading review requests...</div>
                <div id="bsv-review-requests-cards" class="bsv-activity-cards bsv-hidden"></div>
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

    <!-- Request History slide-up: year/month/day drill-down with group filter badges -->
    <div id="bsv-slideup-history" class="cc-slideup-overlay" data-action-click="bsv-close-history">
        <div class="cc-dialog cc-dialog-slideup cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Request History</h3>
                <div class="cc-dialog-header-actions">
                    <div id="bsv-group-badges" class="bsv-group-badges"></div>
                    <span id="bsv-history-count" class="bsv-history-count"></span>
                </div>
                <button class="cc-dialog-close" data-action-click="bsv-close-history">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div id="bsv-history-loading" class="bsv-loading">Loading history...</div>
                <div id="bsv-history-tree" class="bsv-hidden"></div>
            </div>
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
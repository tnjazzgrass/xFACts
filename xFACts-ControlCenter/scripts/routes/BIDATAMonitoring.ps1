<#
.SYNOPSIS
    BIDATA Monitoring dashboard page route.

.DESCRIPTION
    Display dashboard for the BIDATA nightly data-warehouse build. Renders
    four sections: Live Activity (today's build status as a row of status
    cards), Build Execution (step-by-step detail for today's build),
    Duration Trend (a selectable-range bar chart of build durations with a
    custom date-range modal), and Build History (a year/month/day drill-down
    of past builds). The page consumes engine events for the
    Monitor-BIDATABuild orchestrator process via the shared chrome. Page
    chrome, nav, header, banners, and overlays are supplied by
    xFACts-CCShared.psm1 and cc-shared.css/js.

.COMPONENT
    BIDATA

.NOTES
    File Name : BIDATAMonitoring.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\BIDATAMonitoring.ps1

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
#             onclick handlers, the unified overlay constructs (build-detail
#             slideout and date-range modal), and the single cc-shared.js script
#             reference. Page-local content classes carry the bid- prefix. The
#             page now consumes cc-shared.css/js in place of engine-events.css/js.
# 2026-04-30  Phase 4 (Standardization): full alignment to shared infrastructure.
#             Migrated the build-details slideout and custom date-range modal to
#             the shared overlay markup and added the section-platform body class.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml. Page H1 link, title, subtitle, and browser tab
#             title now render from RBAC_NavRegistry via Get-PageHeaderHtml and
#             Get-PageBrowserTitle.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the GET /bidata-monitoring page route. Performs the page-level
   RBAC access check, resolves the user context and the shared nav / header /
   banner fragments, and emits the page HTML shell with the Live Activity,
   Build Execution, Duration Trend, and Build History sections plus the
   build-detail slideout and custom date-range modal overlays.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/bidata-monitoring' -Authentication 'ADLogin' -ScriptBlock {
    Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/bidata-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/bidata-monitoring') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent
    $navHtml = Get-NavBarHtml -UserContext $ctx -CurrentPageRoute '/bidata-monitoring'
    $headerHtml = Get-PageHeaderHtml -PageRoute '/bidata-monitoring'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/bidata-monitoring'
    $bannerHtml = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/bidata-monitoring.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="bidata-monitoring" data-cc-prefix="bid">
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
                <div class="cc-card-engine" id="cc-card-engine-bidata">
                    <span class="cc-engine-label">BIDATA</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-bidata"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-bidata"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div class="bid-grid-layout">

        <div class="bid-grid-column">
            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Live Activity</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="bid-live-activity">
                    <div class="bid-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section cc-fill">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Current Build Execution</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="bid-current-build-execution" class="bid-execution-content">
                    <div class="bid-loading">Loading...</div>
                </div>
            </div>
        </div>

        <div class="bid-grid-column">
            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Duration Trend</h2>
                    <div class="cc-section-header-right">
                        <div class="bid-trend-controls">
                            <button class="bid-trend-btn bid-active" data-action-click="bid-set-trend-range" data-action-bid-days="30">30d</button>
                            <button class="bid-trend-btn" data-action-click="bid-set-trend-range" data-action-bid-days="60">60d</button>
                            <button class="bid-trend-btn" data-action-click="bid-set-trend-range" data-action-bid-days="90">90d</button>
                            <button class="bid-trend-btn" data-action-click="bid-open-date-modal" data-action-bid-days="custom">Custom</button>
                        </div>
                        <span class="cc-refresh-badge-action" title="Refreshes on date range selection">&#128260;</span>
                    </div>
                </div>
                <div id="bid-duration-trend">
                    <div class="bid-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section cc-fill">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Build History</h2>
                    <div class="cc-section-header-right">
                        <span id="bid-history-count" class="bid-history-count"></span>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="bid-build-history" class="bid-history-content">
                    <div class="bid-loading">Loading...</div>
                </div>
            </div>
        </div>

    </div>

    <!-- Purpose: build-detail slideout showing a build's summary and per-step detail -->
    <div id="bid-slideout-detail" class="cc-slide-overlay" data-action-click="bid-close-slideout">
        <div class="cc-dialog cc-dialog-slide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="bid-detail-slideout-title">Build Details</h3>
                <button class="cc-dialog-close" data-action-click="bid-close-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="bid-detail-slideout-body">
                <div class="bid-loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Purpose: custom date-range modal for selecting a Duration Trend window -->
    <div id="bid-modal-daterange" class="cc-modal-overlay cc-hidden" data-action-click="bid-close-date-modal">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="bid-daterange-modal-title">Custom Date Range</h3>
                <button class="cc-dialog-close" data-action-click="bid-close-date-modal">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="bid-date-field">
                    <label class="bid-date-field-label" for="bid-date-from">From</label>
                    <input class="bid-date-field-input" type="date" id="bid-date-from">
                </div>
                <div class="bid-date-field">
                    <label class="bid-date-field-label" for="bid-date-to">To</label>
                    <input class="bid-date-field-input" type="date" id="bid-date-to">
                </div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="bid-close-date-modal">Cancel</button>
                <button class="cc-dialog-btn-primary" data-action-click="bid-apply-date-range">Apply</button>
            </div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
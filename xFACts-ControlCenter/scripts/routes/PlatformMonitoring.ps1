<#
.SYNOPSIS
    Control Center page route for the Platform Monitoring dashboard.

.DESCRIPTION
    Registers the GET /platform-monitoring page route. Renders the admin-only
    platform impact dashboard shell: the narrative summary strip, the top
    section (Platform Performance frame, CPU-impact hero gauge with per-server
    mini gauges, Control Center API frame), and the bottom three-column section
    (Process Breakdown, CPU Impact Over Time chart, Top API Endpoints), plus the
    page's info, detail, and custom-range overlay constructs. All interactive
    behavior and charting is supplied by the page JavaScript loaded via the
    cc-shared.js bootloader; this route emits only the static shell and chrome.

.COMPONENT
    ControlCenter.Platform

.NOTES
    File Name : PlatformMonitoring.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\PlatformMonitoring.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this route file, most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-06  Migrated to the CC file-format spec. Adopted the cc-shared
#             bootloader shell: cc-header-bar, cc-refresh-info, the chrome
#             banner substitution, and the body data attributes for the admin
#             section. Renamed every identifier from the pm- prefix to the
#             registered plt- prefix. Converted all interactive markup from
#             inline onclick handlers to data-action attributes; clickable
#             cards and the ALL pill became button elements (full-cover hit
#             button where a card contains a nested info button). Rebuilt the
#             info modal, detail slideout, and custom-range modal as cc- overlay
#             constructs in a contiguous overlay block. Moved Chart.js from the
#             CDN to the vendored /js/chart.min.js reference. Removed the
#             vestigial back-link and its inline script (a pre-RBAC navigation
#             guardrail made obsolete by the permission-filtered dynamic nav)
#             and the retired engine-events.css/js references.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and browser
#             tab title now render from RBAC_NavRegistry via Get-PageHeaderHtml
#             and Get-PageBrowserTitle. Fixed the access check to use
#             '/platform-monitoring' for proper permission validation against
#             this route's registry entry.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the GET /platform-monitoring page route. Resolves access, composes
   the nav, header, and banner chrome, and emits the dashboard shell HTML.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/platform-monitoring' -Authentication 'ADLogin' -ScriptBlock {
    Import-Module -Name "E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1" -Force -DisableNameChecking
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/platform-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/platform-monitoring') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent
    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/platform-monitoring'
    $headerHtml   = Get-PageHeaderHtml    -PageRoute '/platform-monitoring'
    $browserTitle = Get-PageBrowserTitle  -PageRoute '/platform-monitoring'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/platform-monitoring.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>

<body class="cc-section-admin" data-cc-page="platform-monitoring" data-cc-prefix="plt">
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
        </div>
    </div>

    $bannerHtml

    <div class="plt-narrative" id="plt-narrative-strip">
        <div class="plt-narrative-accent"></div>
        <div class="plt-narrative-text" id="plt-narrative-text">Loading summary...</div>
    </div>

    <div class="plt-content">

        <div class="plt-top-section">

            <div class="plt-card-frame">
                <div class="plt-card-frame-title">
                    <span>Platform Performance <button type="button" class="plt-info-icon" data-action-click="plt-show-info" data-action-plt-info-key="perf-section">?</button></span>
                    <span class="plt-refresh-badge" title="Refreshes on server or time range selection">&#128260;</span>
                </div>
                <div class="plt-card-grid">
                    <div class="plt-card"><div class="plt-card-header"><span class="plt-card-title">Active Sessions</span><button type="button" class="plt-info-icon" data-action-click="plt-show-info" data-action-plt-info-key="active-sessions">?</button></div><div class="plt-card-body"><div class="plt-card-val" id="plt-card-sessions">-</div></div></div>
                    <div class="plt-card"><div class="plt-card-header"><span class="plt-card-title">Total Queries</span><button type="button" class="plt-info-icon" data-action-click="plt-show-info" data-action-plt-info-key="total-queries">?</button></div><div class="plt-card-body"><div class="plt-card-val" id="plt-card-queries">-</div></div></div>
                    <div class="plt-card"><div class="plt-card-header"><span class="plt-card-title">Avg Duration (ms)</span><button type="button" class="plt-info-icon" data-action-click="plt-show-info" data-action-plt-info-key="avg-duration">?</button></div><div class="plt-card-body"><div class="plt-card-val" id="plt-card-avg-dur">-</div></div></div>
                    <div class="plt-card plt-clickable">
                        <button type="button" class="plt-card-hit" data-action-click="plt-open-slideout" data-action-plt-slideout="blocking"></button>
                        <div class="plt-card-header"><span class="plt-card-title">Blocking Events</span><button type="button" class="plt-info-icon" data-action-click="plt-show-info" data-action-plt-info-key="blocking-events">?</button></div>
                        <div class="plt-card-body plt-dual"><div class="plt-card-dual"><div class="plt-card-val" id="plt-card-blocked-by">-</div><div class="plt-card-sublbl">blocked by others</div></div><div class="plt-card-dual-sep"></div><div class="plt-card-dual"><div class="plt-card-val" id="plt-card-caused-by">-</div><div class="plt-card-sublbl">caused by xFACts</div></div></div>
                    </div>
                    <div class="plt-card plt-clickable">
                        <button type="button" class="plt-card-hit" data-action-click="plt-open-slideout" data-action-plt-slideout="lrq"></button>
                        <div class="plt-card-header"><span class="plt-card-title">LRQ Crossovers</span><button type="button" class="plt-info-icon" data-action-click="plt-show-info" data-action-plt-info-key="lrq-crossovers">?</button></div>
                        <div class="plt-card-body"><div class="plt-card-val" id="plt-card-lrq">-</div></div>
                    </div>
                    <div class="plt-card"><div class="plt-card-header"><span class="plt-card-title">Open Transactions</span><button type="button" class="plt-info-icon" data-action-click="plt-show-info" data-action-plt-info-key="open-transactions">?</button></div><div class="plt-card-body"><div class="plt-card-val" id="plt-card-open-tx">-</div></div></div>
                </div>
            </div>

            <div class="plt-hero-col">
                <div class="plt-hero-gauge">
                    <canvas id="plt-gauge-chart" width="260" height="260"></canvas>
                    <div class="plt-hero-overlay">
                        <div class="plt-hero-pct" id="plt-gauge-pct">-</div>
                        <div class="plt-hero-label">CPU IMPACT <button type="button" class="plt-info-icon plt-hero-info" data-action-click="plt-show-info" data-action-plt-info-key="cpu-impact">?</button></div>
                    </div>
                </div>
                <div class="plt-hero-detail" id="plt-gauge-detail">-</div>
                <div class="plt-hero-server" id="plt-gauge-server">ALL SERVERS</div>

                <div class="plt-server-selector">
                    <button type="button" class="plt-server-all plt-active" id="plt-srv-all" data-action-click="plt-select-server" data-action-plt-server="all">ALL</button>
                    <div class="plt-mini-gauges" id="plt-mini-gauges"></div>
                </div>
            </div>

            <div class="plt-card-frame plt-api-frame">
                <div class="plt-card-frame-title plt-api-frame-title">
                    <span>Control Center API <button type="button" class="plt-info-icon plt-api-info" data-action-click="plt-show-info" data-action-plt-info-key="api-section">?</button></span>
                    <span class="plt-refresh-badge" title="Refreshes on server or time range selection">&#128260;</span>
                </div>
                <div class="plt-card-grid">
                    <div class="plt-card plt-api"><div class="plt-card-header"><span class="plt-card-title plt-api">API Requests</span><button type="button" class="plt-info-icon plt-api-info" data-action-click="plt-show-info" data-action-plt-info-key="api-requests">?</button></div><div class="plt-card-body"><div class="plt-card-val" id="plt-card-api-reqs">-</div></div></div>
                    <div class="plt-card plt-api"><div class="plt-card-header"><span class="plt-card-title plt-api">API Req/Min</span><button type="button" class="plt-info-icon plt-api-info" data-action-click="plt-show-info" data-action-plt-info-key="api-rpm">?</button></div><div class="plt-card-body"><div class="plt-card-val" id="plt-card-api-rpm">-</div></div></div>
                    <div class="plt-card plt-api"><div class="plt-card-header"><span class="plt-card-title plt-api">API Avg (ms)</span><button type="button" class="plt-info-icon plt-api-info" data-action-click="plt-show-info" data-action-plt-info-key="api-avg">?</button></div><div class="plt-card-body"><div class="plt-card-val" id="plt-card-api-avg">-</div></div></div>
                    <div class="plt-card plt-api"><div class="plt-card-header"><span class="plt-card-title plt-api">API P95 (ms)</span><button type="button" class="plt-info-icon plt-api-info" data-action-click="plt-show-info" data-action-plt-info-key="api-p95">?</button></div><div class="plt-card-body"><div class="plt-card-val" id="plt-card-api-p95">-</div></div></div>
                    <div class="plt-card plt-api plt-clickable">
                        <button type="button" class="plt-card-hit" data-action-click="plt-open-slideout" data-action-plt-slideout="api-users"></button>
                        <div class="plt-card-header"><span class="plt-card-title plt-api">API Users</span><button type="button" class="plt-info-icon plt-api-info" data-action-click="plt-show-info" data-action-plt-info-key="api-users">?</button></div>
                        <div class="plt-card-body"><div class="plt-card-val" id="plt-card-api-users">-</div></div>
                    </div>
                    <div class="plt-card plt-api plt-clickable">
                        <button type="button" class="plt-card-hit" data-action-click="plt-open-slideout" data-action-plt-slideout="api-errors"></button>
                        <div class="plt-card-header"><span class="plt-card-title plt-api">API Errors</span><button type="button" class="plt-info-icon plt-api-info" data-action-click="plt-show-info" data-action-plt-info-key="api-errors">?</button></div>
                        <div class="plt-card-body"><div class="plt-card-val" id="plt-card-api-errors">-</div></div>
                    </div>
                </div>
            </div>
        </div>

        <div class="plt-bottom-section">
            <div class="plt-col-frame">
                <div class="plt-section-header"><h3 class="plt-section-title plt-platform-title">Process Breakdown <button type="button" class="plt-info-icon" data-action-click="plt-show-info" data-action-plt-info-key="process-breakdown">?</button></h3><span class="plt-refresh-badge" title="Refreshes on server or time range selection">&#128260;</span></div>
                <div class="plt-table-scroll" id="plt-process-table-wrap"><div class="plt-loading">Loading...</div></div>
            </div>
            <div class="plt-col-frame">
                <div class="plt-section-header">
                    <h3 class="plt-section-title">CPU Impact Over Time <button type="button" class="plt-info-icon" data-action-click="plt-show-info" data-action-plt-info-key="cpu-trend">?</button></h3>
                    <div class="plt-section-header-right">
                        <div class="plt-time-controls">
                            <button type="button" class="plt-time-btn plt-active" data-action-click="plt-set-range" data-action-plt-range="1h">1h</button>
                            <button type="button" class="plt-time-btn" data-action-click="plt-set-range" data-action-plt-range="12h">12h</button>
                            <button type="button" class="plt-time-btn" data-action-click="plt-set-range" data-action-plt-range="24h">24h</button>
                            <button type="button" class="plt-time-btn" data-action-click="plt-set-range" data-action-plt-range="7d">7d</button>
                            <button type="button" class="plt-time-btn" data-action-click="plt-open-date">Custom</button>
                        </div>
                        <span class="plt-refresh-badge" title="Refreshes on server or time range selection">&#128260;</span>
                    </div>
                </div>
                <div class="plt-chart-inner"><canvas id="plt-trend-chart"></canvas></div>
            </div>
            <div class="plt-col-frame">
                <div class="plt-section-header"><h3 class="plt-section-title plt-api-title">Top API Endpoints <button type="button" class="plt-info-icon plt-api-info" data-action-click="plt-show-info" data-action-plt-info-key="api-endpoints">?</button></h3><span class="plt-refresh-badge" title="Refreshes on server or time range selection">&#128260;</span></div>
                <div class="plt-table-scroll" id="plt-api-table-wrap"><div class="plt-loading">Loading...</div></div>
            </div>
        </div>
    </div>

    <!-- Purpose: contextual help modal explaining a metric or section -->
    <div id="plt-modal-info" class="cc-modal-overlay cc-hidden" data-action-click="plt-close-info">
        <div class="cc-dialog cc-dialog-modal cc-medium">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="plt-info-title">-</h3>
                <button class="cc-dialog-close" data-action-click="plt-close-info">&times;</button>
            </div>
            <div class="cc-dialog-body" id="plt-info-body"></div>
        </div>
    </div>

    <!-- Purpose: detail slideout for blocking events, LRQ crossovers, API users, and API errors -->
    <div id="plt-slideout-detail" class="cc-slide-overlay" data-action-click="plt-close-slideout">
        <div class="cc-dialog cc-dialog-slide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="plt-slideout-title">-</h3>
                <button class="cc-dialog-close" data-action-click="plt-close-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="plt-slideout-summary" id="plt-slideout-summary"></div>
                <div id="plt-slideout-body"></div>
            </div>
        </div>
    </div>

    <!-- Purpose: custom date-range picker for the CPU trend chart -->
    <div id="plt-modal-date" class="cc-modal-overlay cc-hidden" data-action-click="plt-close-date">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Custom Date Range</h3>
                <button class="cc-dialog-close" data-action-click="plt-close-date">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="plt-date-fields">
                    <div class="plt-date-field"><label for="plt-date-from">From</label><input type="date" id="plt-date-from"></div>
                    <div class="plt-date-field"><label for="plt-date-to">To</label><input type="date" id="plt-date-to"></div>
                </div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="plt-close-date">Cancel</button>
                <button class="cc-dialog-btn-primary" data-action-click="plt-apply-range">Apply</button>
            </div>
        </div>
    </div>

    <script src="/js/chart.min.js"></script>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@

    Write-PodeHtmlResponse -Value $html
}
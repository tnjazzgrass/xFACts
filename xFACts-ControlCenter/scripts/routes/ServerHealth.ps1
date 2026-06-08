<#
.SYNOPSIS
    Renders the Server Health dashboard page route.

.DESCRIPTION
    Registers the /server-health page route. Renders the per-server SQL health
    dashboard: a header-bar server selector, live memory / connection / activity
    metrics, Extended Events activity, server info, disk space, and availability
    group health, plus drill-down modals and slideouts for trends, zombie kills,
    transactions, blocking, requests, and the Extended Events detail views. Page
    chrome (nav, header, banners) is rendered by the shared CCShared helpers and
    the page consumes the shared cc- chrome and overlay classes.

.COMPONENT
    ServerOps.ServerHealth

.NOTES
    File Name : ServerHealth.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\ServerHealth.ps1

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

# 2026-06-05  Refactored to the CC file format specs. Replaced the legacy
#             engine-events chrome with shared cc- chrome: cc-header-bar with
#             the cc-has-center server selector, cc-refresh-info, cc-engine-row,
#             and the cc-shared.js bootloader contract. Body now declares
#             cc-section-platform plus the data-cc-page / data-cc-prefix
#             bootloader attributes. Engine cards reprefixed to the shared
#             cc-card-engine-<slug> / cc-engine-bar-<slug> / cc-engine-cd-<slug>
#             ids for the four ServerOps processes (dmv, xe, disk, disksummary).
#             The 14 page overlays migrated to the shared cc-modal-overlay and
#             cc-slide-overlay constructs with backdrop close wired via
#             data-action-click. All inline onclick handlers replaced by
#             data-action-click values routed through the page dispatch tables;
#             info icons converted from clickable spans to buttons. Chart.js
#             switched from the CDN reference to the vendored /js/chart.min.js.
#             CCShared import shim added as the first statement inside the
#             route scriptblock.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   The /server-health page route. Gates on page access, resolves the user
   context, renders the shared chrome with the centered server selector, and
   emits the page shell with its metric sections and the modal / slideout
   overlay block.
   Prefix: srv
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/server-health' -Authentication 'ADLogin' -ScriptBlock {
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/server-health'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/server-health') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $navHtml      = Get-NavBarHtml -UserContext $ctx -CurrentPageRoute '/server-health'
    $headerHtml   = Get-PageHeaderHtml -PageRoute '/server-health'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/server-health'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/server-health.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="server-health" data-cc-prefix="srv">
$navHtml

    <div class="cc-header-bar cc-has-center">
        <div>
            $headerHtml
        </div>
        <div class="cc-header-center">
            <div id="srv-server-tabs" class="srv-server-tabs">
                <span class="srv-loading-inline">Loading servers...</span>
            </div>
        </div>
        <div class="cc-header-right">
            <div class="cc-refresh-info">
                <span class="cc-live-indicator"></span>
                <span>Live</span> | Updated: <span id="cc-last-update" class="cc-last-updated">-</span>
                <button class="cc-page-refresh-btn" data-action-click="cc-page-refresh" title="Refresh all data">&#8635;</button>
            </div>
            <div class="cc-engine-row">
                <div class="cc-card-engine" id="cc-card-engine-dmv">
                    <span class="cc-engine-label">DMV</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-dmv"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-dmv"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-xe">
                    <span class="cc-engine-label">XE</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-xe"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-xe"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-disk">
                    <span class="cc-engine-label">DISK</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-disk"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-disk"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-disksummary">
                    <span class="cc-engine-label">SUMMARY</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-disksummary"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-disksummary"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div id="srv-connection-error" class="srv-connection-error"></div>

    <div class="srv-main-layout">

        <div class="srv-metrics-column">

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Memory</h2>
                    <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                </div>
                <div id="srv-memory-metrics" class="srv-metrics-grid">
                    <div class="srv-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Connections</h2>
                    <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                </div>
                <div id="srv-connection-metrics" class="srv-metrics-grid">
                    <div class="srv-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Current Activity</h2>
                    <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                </div>
                <div id="srv-activity-metrics" class="srv-metrics-grid">
                    <div class="srv-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Extended Events Activity</h2>
                    <div class="cc-section-header-right">
                        <div class="srv-time-window-control">
                            <span id="srv-recent-activity-window">15</span>m
                            <button class="srv-time-window-btn" data-action-click="srv-open-time-window" title="Change time window">&#9881;</button>
                        </div>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="srv-xe-activity" class="srv-metrics-grid">
                    <div class="srv-loading">Loading...</div>
                </div>
            </div>
        </div>

        <div class="srv-info-column">

            <div class="cc-section srv-info-panel">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Server Info</h2>
                    <span class="cc-refresh-badge-action" title="Refreshes on server select">&#128260;</span>
                </div>
                <div id="srv-server-info" class="srv-server-info-content">
                    <div class="srv-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section srv-info-panel">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Disk Space</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="srv-disk-space" class="srv-disk-space-content">
                    <div class="srv-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section srv-info-panel">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">DMPRODAG Health</h2>
                    <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                </div>
                <div id="srv-ag-health" class="srv-ag-health-content">
                    <div class="srv-loading">Loading...</div>
                </div>
            </div>
        </div>
    </div>

    <!-- Purpose: zombie kill confirmation modal -->
    <div id="srv-modal-zombie" class="cc-modal-overlay cc-hidden" data-action-click="srv-close-zombie-modal">
        <div class="cc-dialog cc-dialog-modal cc-medium">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">&#129503; Zombie Eradication</h3>
                <button class="cc-dialog-close" data-action-click="srv-close-zombie-modal">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-zombie-modal-body">
                <div class="srv-zombie-icon">&#129503;&#128299;</div>
                <div class="srv-zombie-message">
                    Are you sure you want to eradicate
                    <span class="srv-zombie-count" id="srv-zombie-kill-count">0</span> zombies?
                </div>
                <div class="srv-zombie-threshold" id="srv-zombie-threshold-info"></div>
            </div>
            <div class="cc-dialog-actions" id="srv-zombie-modal-footer">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-close-zombie-modal">Never Mind</button>
                <button class="cc-dialog-btn-danger" data-action-click="srv-execute-zombie-kill">&#128299; Double Tap Them</button>
            </div>
        </div>
    </div>

    <!-- Purpose: metric trend modal with range selector and chart -->
    <div id="srv-modal-trend" class="cc-modal-overlay cc-hidden" data-action-click="srv-close-trend-modal">
        <div class="cc-dialog cc-dialog-modal cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="srv-trend-modal-title">Trend</h3>
                <button class="cc-dialog-close" data-action-click="srv-close-trend-modal">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="srv-trend-header">
                    <div class="srv-trend-left">
                        <div class="srv-trend-metric-name" id="srv-trend-metric-name"></div>
                        <div class="srv-trend-range-selector">
                            <button class="srv-trend-range-btn srv-active" data-action-click="srv-select-trend-range" data-action-srv-hours="24">24h</button>
                            <button class="srv-trend-range-btn" data-action-click="srv-select-trend-range" data-action-srv-hours="168">7d</button>
                            <button class="srv-trend-range-btn" data-action-click="srv-select-trend-range" data-action-srv-hours="720">30d</button>
                        </div>
                    </div>
                    <div class="srv-trend-current-value" id="srv-trend-current-value">-</div>
                </div>
                <div id="srv-trend-loading" class="srv-trend-loading cc-hidden">Loading trend data...</div>
                <div class="srv-trend-chart-container">
                    <canvas id="srv-trend-chart"></canvas>
                </div>
                <div class="srv-trend-note" id="srv-trend-aggregation-note"></div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-close-trend-modal">Close</button>
            </div>
        </div>
    </div>

    <!-- Purpose: Extended Events time-window selector modal -->
    <div id="srv-modal-xe-time" class="cc-modal-overlay cc-hidden" data-action-click="srv-close-time-window-modal">
        <div class="cc-dialog cc-dialog-modal cc-medium">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">XE Time Window</h3>
                <button class="cc-dialog-close" data-action-click="srv-close-time-window-modal">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <p class="srv-xe-time-prompt">Select the time window for Extended Events activity</p>
                <div class="srv-trend-range-selector srv-centered">
                    <button class="srv-trend-range-btn srv-xe-time-btn" data-action-click="srv-apply-time-window" data-action-srv-minutes="5">5m</button>
                    <button class="srv-trend-range-btn srv-xe-time-btn" data-action-click="srv-apply-time-window" data-action-srv-minutes="15">15m</button>
                    <button class="srv-trend-range-btn srv-xe-time-btn" data-action-click="srv-apply-time-window" data-action-srv-minutes="30">30m</button>
                    <button class="srv-trend-range-btn srv-xe-time-btn" data-action-click="srv-apply-time-window" data-action-srv-minutes="60">60m</button>
                </div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-close-time-window-modal">Cancel</button>
            </div>
        </div>
    </div>

    <!-- Purpose: open transactions detail slideout -->
    <div id="srv-slideout-trans" class="cc-slide-overlay" data-action-click="srv-close-trans-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Open Transactions</h3>
                <button class="cc-dialog-close" data-action-click="srv-close-trans-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-trans-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-copy-kill-script">&#128203; Copy KILL Script</button>
            </div>
        </div>
    </div>

    <!-- Purpose: blocking details slideout -->
    <div id="srv-slideout-blocking" class="cc-slide-overlay" data-action-click="srv-close-blocking-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Blocking Details</h3>
                <button class="cc-dialog-close" data-action-click="srv-close-blocking-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-blocking-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-copy-blocker-kill-script">&#128203; Copy KILL Script (Blockers)</button>
            </div>
        </div>
    </div>

    <!-- Purpose: active requests slideout -->
    <div id="srv-slideout-requests" class="cc-slide-overlay" data-action-click="srv-close-requests-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Active Requests</h3>
                <button class="cc-dialog-close" data-action-click="srv-close-requests-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-requests-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-refresh-active-requests">&#8635; Refresh</button>
            </div>
        </div>
    </div>

    <!-- Purpose: Extended Events long running queries slideout -->
    <div id="srv-slideout-xe-lrq" class="cc-slide-overlay" data-action-click="srv-close-xe-lrq-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Long Running Queries <span id="srv-xe-lrq-time-window" class="srv-slideout-subtitle"></span></h3>
                <button class="cc-dialog-close" data-action-click="srv-close-xe-lrq-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-xe-lrq-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-refresh-xe-lrq">&#8635; Refresh</button>
            </div>
        </div>
    </div>

    <!-- Purpose: Extended Events blocking events slideout -->
    <div id="srv-slideout-xe-blocking" class="cc-slide-overlay" data-action-click="srv-close-xe-blocking-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Blocking Events <span id="srv-xe-blocking-time-window" class="srv-slideout-subtitle"></span></h3>
                <button class="cc-dialog-close" data-action-click="srv-close-xe-blocking-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-xe-blocking-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-refresh-xe-blocking">&#8635; Refresh</button>
            </div>
        </div>
    </div>

    <!-- Purpose: Extended Events deadlock events slideout -->
    <div id="srv-slideout-xe-deadlock" class="cc-slide-overlay" data-action-click="srv-close-xe-deadlock-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Deadlock Events <span id="srv-xe-deadlock-time-window" class="srv-slideout-subtitle"></span></h3>
                <button class="cc-dialog-close" data-action-click="srv-close-xe-deadlock-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-xe-deadlock-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-refresh-xe-deadlock">&#8635; Refresh</button>
            </div>
        </div>
    </div>

    <!-- Purpose: Extended Events linked server inbound slideout -->
    <div id="srv-slideout-xe-ls-inbound" class="cc-slide-overlay" data-action-click="srv-close-xe-ls-inbound-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Linked Server Inbound <span id="srv-xe-ls-inbound-time-window" class="srv-slideout-subtitle"></span></h3>
                <button class="cc-dialog-close" data-action-click="srv-close-xe-ls-inbound-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-xe-ls-inbound-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-refresh-xe-ls-inbound">&#8635; Refresh</button>
            </div>
        </div>
    </div>

    <!-- Purpose: Extended Events linked server outbound slideout -->
    <div id="srv-slideout-xe-ls-outbound" class="cc-slide-overlay" data-action-click="srv-close-xe-ls-outbound-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Linked Server Outbound <span id="srv-xe-ls-outbound-time-window" class="srv-slideout-subtitle"></span></h3>
                <button class="cc-dialog-close" data-action-click="srv-close-xe-ls-outbound-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-xe-ls-outbound-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-refresh-xe-ls-outbound">&#8635; Refresh</button>
            </div>
        </div>
    </div>

    <!-- Purpose: Extended Events availability group health slideout -->
    <div id="srv-slideout-xe-ag-events" class="cc-slide-overlay" data-action-click="srv-close-xe-ag-events-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">AG Health Events <span id="srv-xe-ag-events-time-window" class="srv-slideout-subtitle"></span></h3>
                <button class="cc-dialog-close" data-action-click="srv-close-xe-ag-events-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-xe-ag-events-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-refresh-xe-ag-events">&#8635; Refresh</button>
            </div>
        </div>
    </div>

    <!-- Purpose: availability group replica detail slideout -->
    <div id="srv-slideout-ag-detail" class="cc-slide-overlay" data-action-click="srv-close-ag-detail-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">AG Replica Detail <span id="srv-ag-detail-server" class="srv-slideout-subtitle"></span></h3>
                <button class="cc-dialog-close" data-action-click="srv-close-ag-detail-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-ag-detail-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-refresh-ag-detail">&#8635; Refresh</button>
            </div>
        </div>
    </div>

    <!-- Purpose: Extended Events system health slideout -->
    <div id="srv-slideout-xe-system-health" class="cc-slide-overlay" data-action-click="srv-close-xe-system-health-slideout">
        <div class="cc-dialog cc-dialog-slide cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">System Health Events <span id="srv-xe-system-health-time-window" class="srv-slideout-subtitle"></span></h3>
                <button class="cc-dialog-close" data-action-click="srv-close-xe-system-health-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="srv-xe-system-health-panel-body">
                <div class="srv-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="srv-refresh-xe-system-health">&#8635; Refresh</button>
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
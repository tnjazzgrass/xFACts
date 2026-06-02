<#
.SYNOPSIS
    Pode route for the Replication Monitoring page (/replication-monitoring).

.DESCRIPTION
    Registers the GET /replication-monitoring route. Performs RBAC access check via
    Get-UserAccess and returns the Access Denied page on failure. Resolves user
    context, renders nav and page header from RBAC_NavRegistry, and emits the
    Replication Monitoring page HTML following the CC HTML Spec for body attributes,
    page-local prefixing, engine card rendering, and data-action event dispatch.

    During the CC File Format Standardization Section 11.2.4 unified prefix rename
    migration, this route explicitly imports the xFACts-CCShared module at the top
    of its scriptblock. This shadows the auto-loaded xFACts-Helpers module for this
    route's execution so Get-NavBarHtml and Get-PageHeaderHtml emit cc- prefixed
    chrome classes that match cc-shared.css and cc-shared.js. Once every page has
    migrated, xFACts-Helpers.psm1 is deleted, Start-ControlCenter.ps1 is updated to
    load xFACts-CCShared.psm1 at startup, and the explicit Import-Module line in
    this route is removed.

.COMPONENT
    ServerOps.Replication

.NOTES
    File Name : ReplicationMonitoring.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes

    FILE ORGANIZATION
    -----------------
        CHANGELOG: CHANGE HISTORY
        ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-driven change history for this page route. Entries appear
   most-recent first. Each entry begins with the ISO date followed by two
   spaces and the description; continuation lines align with the start of
   the description text.
   Prefix: (none)
   ============================================================================ #>

# 2026-05-28  CC File Format Standardization (Phase 2 page migration):
#             refactored the page route to the CC HTML Spec and CC PS Spec.
#             Replaced the engine-events.css reference and the engine-
#             events.js script tag with the single /js/cc-shared.js
#             bootloader tag and the /css/replication-monitoring.css +
#             /css/cc-shared.css references. Converted the file header to
#             comment-based-help form and the CHANGELOG and ROUTE banners to
#             the spec-mandated block-comment form. Added the body
#             data-cc-page / data-cc-prefix attributes and the cc-section-
#             platform class. Renamed all chrome classes and IDs to the cc-
#             prefix (header-bar, header-right, refresh-info, live-indicator,
#             last-updated, page-refresh-btn, engine-row, card-engine,
#             engine-label, engine-bar, engine-cd, section, section-header,
#             section-title, section-header-right, refresh-badge-event,
#             connection-banner, page-error-banner). Engine label rendered
#             uppercase (REPLICATION) to match ProcessRegistry.cc_engine_
#             label. Prefixed all page-local IDs and classes with rpm-.
#             Replaced inline onclick handlers with data-action-click /
#             data-action-change attributes dispatched by rpm_clickActions /
#             rpm_changeActions in replication-monitoring.js; chart time-
#             range buttons carry data-action-rpm-chart and data-action-rpm-
#             minutes argument attributes; the date picker carries data-
#             action-change="rpm-event-date-change"; the correlation toggle
#             carries data-action-click="rpm-toggle-correlation". Replaced
#             the JS-injected help panel with a static slide dialog
#             (rpm-slideout-info) consuming the shared cc-slide-overlay /
#             cc-dialog chrome. Added the explicit Import-Module of
#             xFACts-CCShared.psm1 inside the route scriptblock.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the Replication Monitoring dashboard page at GET
   /replication-monitoring. Performs RBAC access check, resolves user
   context, renders nav and header from the RBAC_NavRegistry, and emits the
   page HTML.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/replication-monitoring' -Authentication 'ADLogin' -ScriptBlock {

    # Import the cc- emission helpers. During the CC File Format
    # Standardization Section 11.2.4 migration this overrides the auto-loaded
    # xFACts-Helpers module for this route's execution, so Get-NavBarHtml
    # and Get-PageHeaderHtml emit cc- prefixed chrome classes that match
    # cc-shared.css and cc-shared.js. Once every page has migrated and
    # Start-ControlCenter.ps1 loads xFACts-CCShared.psm1 at startup
    # instead of xFACts-Helpers.psm1, this line is removed.
    Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/replication-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/replication-monitoring') -StatusCode 403
        return
    }

    $ctx          = Get-UserContext      -WebEvent $WebEvent
    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/replication-monitoring'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/replication-monitoring'
    $bannerHtml   = Get-ChromeBannersHtml
    $browserTitle = Get-PageBrowserTitle -PageRoute '/replication-monitoring'

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/replication-monitoring.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="replication-monitoring" data-cc-prefix="rpm">
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
                <div class="cc-card-engine" id="cc-card-engine-replication">
                    <span class="cc-engine-label">REPLICATION</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-replication"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-replication"></span>
                </div>
            </div>
        </div>
    </div>

$bannerHtml

    <div class="cc-section">
        <div class="cc-section-header">
            <h2 class="cc-section-title">Agent Status</h2>
            <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
        </div>
        <div id="rpm-agent-cards" class="rpm-agent-cards-grid">
            <div class="rpm-loading">Loading...</div>
        </div>
    </div>

    <div class="cc-section">
        <div class="cc-section-header">
            <h2 class="cc-section-title">Delivery Rate</h2>
            <div class="cc-section-header-right">
                <div class="rpm-time-buttons">
                    <button class="rpm-time-btn rpm-active" data-action-click="rpm-set-time-range" data-action-rpm-chart="throughput" data-action-rpm-minutes="60">1h</button>
                    <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="throughput" data-action-rpm-minutes="240">4h</button>
                    <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="throughput" data-action-rpm-minutes="720">12h</button>
                    <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="throughput" data-action-rpm-minutes="1440">24h</button>
                    <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="throughput" data-action-rpm-minutes="10080">7d</button>
                </div>
                <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
            </div>
        </div>
        <div class="rpm-chart-container rpm-chart-wide">
            <canvas id="rpm-throughput-chart"></canvas>
        </div>
    </div>

    <div class="rpm-lower-grid">

        <div class="rpm-lower-left">

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Queue Depth</h2>
                    <div class="cc-section-header-right">
                        <div class="rpm-time-buttons">
                            <button class="rpm-time-btn rpm-active" data-action-click="rpm-set-time-range" data-action-rpm-chart="queue" data-action-rpm-minutes="60">1h</button>
                            <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="queue" data-action-rpm-minutes="240">4h</button>
                            <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="queue" data-action-rpm-minutes="720">12h</button>
                            <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="queue" data-action-rpm-minutes="1440">24h</button>
                            <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="queue" data-action-rpm-minutes="10080">7d</button>
                        </div>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div class="rpm-chart-container rpm-chart-half">
                    <canvas id="rpm-queue-chart"></canvas>
                </div>
            </div>

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">End-to-End Latency</h2>
                    <div class="cc-section-header-right">
                        <div class="rpm-time-buttons">
                            <button class="rpm-time-btn rpm-active" data-action-click="rpm-set-time-range" data-action-rpm-chart="latency" data-action-rpm-minutes="60">1h</button>
                            <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="latency" data-action-rpm-minutes="240">4h</button>
                            <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="latency" data-action-rpm-minutes="720">12h</button>
                            <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="latency" data-action-rpm-minutes="1440">24h</button>
                            <button class="rpm-time-btn" data-action-click="rpm-set-time-range" data-action-rpm-chart="latency" data-action-rpm-minutes="10080">7d</button>
                        </div>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div class="rpm-chart-container rpm-chart-half-tall">
                    <canvas id="rpm-latency-chart"></canvas>
                </div>
            </div>

        </div>

        <div class="rpm-lower-right">
            <div class="cc-section rpm-section-event-log">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Event Log</h2>
                    <div class="cc-section-header-right">
                        <button id="rpm-btn-correlated" class="rpm-btn-correlation" data-action-click="rpm-toggle-correlation" title="Show all BIDATA-correlated events">&#x1F517; Correlated</button>
                        <input type="date" id="rpm-event-date-picker" class="rpm-event-date-picker" data-action-change="rpm-event-date-change">
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="rpm-event-agent-filter" class="rpm-event-agent-filter"></div>
                <div id="rpm-event-log" class="rpm-event-log-container">
                    <div class="rpm-loading">Loading...</div>
                </div>
            </div>
        </div>

    </div>

    <!-- Slideout for the per-section help text opened from the section info icons -->
    <div id="rpm-slideout-info" class="cc-slide-overlay" data-action-click="rpm-close-info">
        <div class="cc-dialog cc-dialog-slide">
            <div class="cc-dialog-header">
                <h3 id="rpm-info-title" class="cc-dialog-title">Help</h3>
                <button class="cc-dialog-close" data-action-click="rpm-close-info">&times;</button>
            </div>
            <div class="cc-dialog-body" id="rpm-info-body"></div>
        </div>
    </div>

    <script src="/js/chart.min.js"></script>
    <script src="/js/chartjs-adapter-date-fns.min.js"></script>
    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
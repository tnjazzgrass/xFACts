<#
.SYNOPSIS
    Renders the Index Maintenance monitoring dashboard page.

.DESCRIPTION
    Page route for the Control Center Index Maintenance dashboard. Performs the
    RBAC access check, resolves user context, composes the dynamic nav bar,
    page header, and chrome banners from the registry helpers, and emits the
    page shell. The page presents live activity, process status, the index
    queue, active rebuild execution, and a database overview, with detail
    slideouts and an admin launch modal. Page behavior and content rendering
    are driven by index-maintenance.js; styling by index-maintenance.css and
    cc-shared.css.

.COMPONENT
    ServerOps.Index

.NOTES
    File Name : IndexMaintenance.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\IndexMaintenance.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for the Index Maintenance page route.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-03  Refactored to the cc-shared model: cc-section body shell with
#             data-cc-page/data-cc-prefix, cc-shared.css/js replacing the
#             legacy engine-events pair, cc- chrome classes, $bannerHtml
#             chrome, cc- engine cards, and single-rooted cc-dialog overlay
#             constructs with data-action-click wiring. Admin-only launch
#             badges are now gated server-side via a per-process flag in the
#             process-status API rather than a client-side admin flag.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the GET /index-maintenance page route, gated by ADLogin
   authentication and an RBAC access check, and renders the dashboard shell.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/index-maintenance' -Authentication 'ADLogin' -ScriptBlock {

    # Import the cc- emission helpers. During the CC File Format
    # Standardization Section 11.2.4 migration this overrides the auto-loaded
    # xFACts-Helpers module for this route's execution, so Get-NavBarHtml
    # and Get-PageHeaderHtml emit cc- prefixed chrome classes that match
    # cc-shared.css and cc-shared.js. Once every page has migrated and
    # Start-ControlCenter.ps1 loads xFACts-CCShared.psm1 at startup
    # instead of xFACts-Helpers.psm1, this line is removed.
    Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/index-maintenance'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/index-maintenance') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/index-maintenance'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/index-maintenance'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/index-maintenance'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/index-maintenance.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="index-maintenance" data-cc-prefix="idx">
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
                <div class="cc-card-engine" id="cc-card-engine-sync">
                    <span class="cc-engine-label">SYNC</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-sync"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-sync"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-scan">
                    <span class="cc-engine-label">SCAN</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-scan"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-scan"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-execute">
                    <span class="cc-engine-label">EXECUTE</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-execute"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-execute"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-stats">
                    <span class="cc-engine-label">STATS</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-stats"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-stats"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div class="idx-two-column-layout">

        <div class="idx-left-column">

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Live Activity</h2>
                    <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                </div>
                <div id="idx-live-activity" class="idx-live-activity-content">
                    <div class="cc-slide-empty">Loading...</div>
                </div>
            </div>

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Process Status</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="idx-process-status" class="idx-process-cards">
                    <div class="cc-slide-empty">Loading...</div>
                </div>
            </div>

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Index Queue</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="idx-queue-summary" class="idx-queue-summary-content">
                    <div class="cc-slide-empty">Loading...</div>
                </div>
            </div>

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Active Execution</h2>
                    <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                </div>
                <div id="idx-active-execution" class="idx-active-execution-content">
                    <div class="cc-slide-empty">Loading...</div>
                </div>
            </div>

        </div>

        <div class="idx-right-column">

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Database Overview</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="idx-database-health" class="idx-database-health-content">
                    <div class="cc-slide-empty">Loading...</div>
                </div>
            </div>

        </div>

    </div>

    <!-- Queue details slideout: full index queue table -->
    <div id="idx-slideout-queue" class="cc-slide-overlay" data-action-click="idx-close-queue">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Queue Details</h3>
                <button class="cc-dialog-close" data-action-click="idx-close-queue">&times;</button>
            </div>
            <div class="cc-dialog-body" id="idx-slideout-queue-body">
                <div class="cc-slide-empty">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Sync details slideout: last registry-sync run -->
    <div id="idx-slideout-sync" class="cc-slide-overlay" data-action-click="idx-close-sync">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Registry Sync - Last Run</h3>
                <button class="cc-dialog-close" data-action-click="idx-close-sync">&times;</button>
            </div>
            <div class="cc-dialog-body" id="idx-slideout-sync-body">
                <div class="cc-slide-empty">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Scan details slideout: last fragmentation-scan run -->
    <div id="idx-slideout-scan" class="cc-slide-overlay" data-action-click="idx-close-scan">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Fragmentation Scan - Last Run</h3>
                <button class="cc-dialog-close" data-action-click="idx-close-scan">&times;</button>
            </div>
            <div class="cc-dialog-body" id="idx-slideout-scan-body">
                <div class="cc-slide-empty">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Execute details slideout: last index-maintenance run -->
    <div id="idx-slideout-execute" class="cc-slide-overlay" data-action-click="idx-close-execute">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Index Maintenance - Last Run</h3>
                <button class="cc-dialog-close" data-action-click="idx-close-execute">&times;</button>
            </div>
            <div class="cc-dialog-body" id="idx-slideout-execute-body">
                <div class="cc-slide-empty">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Stats details slideout: last statistics-update run -->
    <div id="idx-slideout-stats" class="cc-slide-overlay" data-action-click="idx-close-stats">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Statistics Update - Last Run</h3>
                <button class="cc-dialog-close" data-action-click="idx-close-stats">&times;</button>
            </div>
            <div class="cc-dialog-body" id="idx-slideout-stats-body">
                <div class="cc-slide-empty">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Schedule slideout: per-database maintenance window editor -->
    <div id="idx-slideout-schedule" class="cc-slide-overlay" data-action-click="idx-close-schedule">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="idx-slideout-schedule-title">Maintenance Schedule</h3>
                <button class="cc-dialog-close" data-action-click="idx-close-schedule">&times;</button>
            </div>
            <div class="cc-dialog-body" id="idx-slideout-schedule-body">
                <div class="cc-slide-empty">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Launch confirmation modal: admin manual process launch -->
    <div id="idx-modal-launch" class="cc-modal-overlay cc-hidden" data-action-click="idx-close-launch">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="idx-modal-launch-title">Launch Process</h3>
                <button class="cc-dialog-close" data-action-click="idx-close-launch">&times;</button>
            </div>
            <div class="cc-dialog-body" id="idx-modal-launch-body"></div>
            <div class="cc-dialog-actions" id="idx-modal-launch-footer"></div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
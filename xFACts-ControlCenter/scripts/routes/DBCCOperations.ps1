<#
.SYNOPSIS
    Control Center page route for the DBCC Operations monitoring dashboard.

.DESCRIPTION
    Registers the GET /dbcc-operations page route. Renders the page shell:
    dynamic nav, page header, chrome banners, the two-column dashboard
    layout (live progress, today's executions, schedule overview, execution
    history), and the schedule modals. All data is loaded client-side by the
    page JS module via the DBCC API endpoints.

.COMPONENT
    ServerOps.DBCC

.NOTES
    File Name : DBCCOperations.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\DBCCOperations.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this route file. Most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-04  Refactored to CC file-format specs: cc-shared chrome classes,
#             $bannerHtml chrome banners, data-action attributes (no inline
#             handlers), static cc-dialog modals, server-side admin gating
#             (removed window.isAdmin injection), single cc-shared.js asset.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   The GET /dbcc-operations page route. Performs the RBAC access check, then
   emits the page shell as a here-string with nav, header, banner chrome, and
   the dashboard content and modal overlays.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/dbcc-operations' -Authentication 'ADLogin' -ScriptBlock {
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/dbcc-operations'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/dbcc-operations') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/dbcc-operations'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/dbcc-operations'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/dbcc-operations'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/dbcc-operations.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="dbcc-operations" data-cc-prefix="dbc">
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
                <div class="cc-card-engine" id="cc-card-engine-dbcc">
                    <span class="cc-engine-label">DBCC</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-dbcc"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-dbcc"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div class="dbc-two-column">

        <div class="dbc-column">

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Live Progress</h2>
                    <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                </div>
                <div id="dbc-live-progress" class="dbc-live-progress-content">
                    <div class="dbc-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section cc-fill">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Today's Executions</h2>
                    <div class="cc-section-header-right">
                        <button id="dbc-btn-pending-queue" class="dbc-pending-btn" data-action-click="dbc-open-pending" title="View pending queue">
                            &#9202; Pending <span id="dbc-pending-count-badge" class="dbc-pending-badge cc-hidden">0</span>
                        </button>
                        <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                    </div>
                </div>
                <div id="dbc-todays-executions">
                    <div class="dbc-loading">Loading...</div>
                </div>
            </div>

        </div>

        <div class="dbc-column">

            <div class="cc-section dbc-section-schedule">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Schedule Overview</h2>
                    <span class="cc-refresh-badge-static" title="Loads once on page load">&#128204;</span>
                </div>
                <div id="dbc-schedule-overview">
                    <div class="dbc-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section cc-fill">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Execution History</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="dbc-execution-history">
                    <div class="dbc-loading">Loading...</div>
                </div>
            </div>

        </div>

    </div>

    <!-- Purpose: pending DBCC queue list, opened from the Today's Executions header -->
    <div id="dbc-modal-pending" class="cc-modal-overlay cc-hidden" data-action-click="dbc-close-pending">
        <div class="cc-dialog cc-dialog-modal cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Pending Queue</h3>
                <button class="cc-dialog-close" data-action-click="dbc-close-pending">&times;</button>
            </div>
            <div class="cc-dialog-body" id="dbc-pending-body">
                <div class="dbc-loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Purpose: server-level schedule detail, listing each database's per-operation schedule -->
    <div id="dbc-modal-schedule" class="cc-modal-overlay cc-hidden" data-action-click="dbc-close-schedule">
        <div class="cc-dialog cc-dialog-modal cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="dbc-schedule-title">Server Schedule</h3>
                <button class="cc-dialog-close" data-action-click="dbc-close-schedule">&times;</button>
            </div>
            <div class="cc-dialog-body" id="dbc-schedule-body">
                <div class="dbc-loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Purpose: database-level schedule editor for one schedule row -->
    <div id="dbc-modal-edit" class="cc-modal-overlay cc-hidden" data-action-click="dbc-close-edit">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="dbc-edit-title">Edit Schedule</h3>
                <button class="cc-dialog-close" data-action-click="dbc-close-edit">&times;</button>
            </div>
            <div class="cc-dialog-body" id="dbc-edit-body">
                <div class="dbc-loading">Loading...</div>
            </div>
            <div class="cc-dialog-actions" id="dbc-edit-actions"></div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
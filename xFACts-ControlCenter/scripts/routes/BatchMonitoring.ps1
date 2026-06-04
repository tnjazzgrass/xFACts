<#
.SYNOPSIS
    Renders the Batch Monitoring dashboard page route.

.DESCRIPTION
    Registers the /batch-monitoring page route. Renders the batch lifecycle
    dashboard covering NB, PMT, and BDL batch types: a daily activity summary,
    a live view of in-flight batches, collector process health, and a
    drill-down batch history tree with a day-detail slideout. Page chrome
    (nav, header, banners) is rendered by the shared CCShared helpers and the
    page consumes the shared cc- chrome and overlay classes.

.COMPONENT
    BatchOps

.NOTES
    File Name : BatchMonitoring.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\BatchMonitoring.ps1

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

# 2026-06-04  Refactored to the CC file format specs. Replaced the legacy
#             engine-events chrome with shared cc- chrome: cc-header-bar,
#             cc-refresh-info, cc-engine-row, and the cc-shared.js bootloader
#             contract. Body now declares cc-section-platform plus the
#             data-cc-page / data-cc-prefix bootloader attributes. Engine
#             cards reprefixed to the shared cc-card-engine-<slug> /
#             cc-engine-bar-<slug> / cc-engine-cd-<slug> ids for the four
#             BatchOps processes (nb, pmt, bdl, summary). Batch detail
#             slideout migrated to the shared cc-slide-overlay /
#             cc-dialog cc-dialog-slide cc-xwide construct with backdrop
#             close wired via data-action-click. All inline onclick handlers
#             replaced by data-action-click values routed through the page
#             dispatch tables. CCShared import shim added as the first
#             statement inside the route scriptblock.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   The /batch-monitoring page route. Gates on page access, resolves the user
   context, renders the shared chrome, and emits the page shell with its
   content sections and the batch detail slideout.
   Prefix: bat
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/batch-monitoring' -Authentication 'ADLogin' -ScriptBlock {
    Import-Module -Name "E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1" -Force -DisableNameChecking

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/batch-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/batch-monitoring') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $navHtml      = Get-NavBarHtml -UserContext $ctx -CurrentPageRoute '/batch-monitoring'
    $headerHtml   = Get-PageHeaderHtml -PageRoute '/batch-monitoring'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/batch-monitoring'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/batch-monitoring.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="batch-monitoring" data-cc-prefix="bat">
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
                <div class="cc-card-engine" id="cc-card-engine-nb">
                    <span class="cc-engine-label">NB</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-nb"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-nb"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-pmt">
                    <span class="cc-engine-label">PMT</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-pmt"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-pmt"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-bdl">
                    <span class="cc-engine-label">BDL</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-bdl"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-bdl"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-summary">
                    <span class="cc-engine-label">SUMMARY</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-summary"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-summary"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div class="bat-grid-layout">

        <div class="bat-grid-column">

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Today's Activity</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="bat-daily-summary" class="bat-summary-cards">
                    <div class="bat-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section cc-fill">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Active Batches</h2>
                    <div class="cc-section-header-right">
                        <div class="bat-filter-group">
                            <button class="bat-active-filter-btn bat-active" data-action-click="bat-set-active-filter" data-bat-filter="ALL">All</button>
                            <button class="bat-active-filter-btn" data-action-click="bat-set-active-filter" data-bat-filter="NB">NB</button>
                            <button class="bat-active-filter-btn" data-action-click="bat-set-active-filter" data-bat-filter="PMT">PMT</button>
                            <button class="bat-active-filter-btn" data-action-click="bat-set-active-filter" data-bat-filter="BDL">BDL</button>
                        </div>
                        <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                    </div>
                </div>
                <div id="bat-active-batches" class="bat-activity-content">
                    <div class="bat-loading">Loading...</div>
                </div>
            </div>
        </div>

        <div class="bat-grid-column">

            <div class="cc-section bat-section-compact">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Process Status</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="bat-process-status" class="bat-status-grid">
                    <div class="bat-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section cc-fill">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Batch History</h2>
                    <div class="cc-section-header-right">
                        <div class="bat-filter-group">
                            <button class="bat-filter-btn bat-active" data-action-click="bat-set-history-filter" data-bat-filter="ALL">All</button>
                            <button class="bat-filter-btn" data-action-click="bat-set-history-filter" data-bat-filter="NB">NB</button>
                            <button class="bat-filter-btn" data-action-click="bat-set-history-filter" data-bat-filter="PMT">PMT</button>
                            <button class="bat-filter-btn" data-action-click="bat-set-history-filter" data-bat-filter="BDL">BDL</button>
                        </div>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="bat-batch-history" class="bat-history-content">
                    <div class="bat-loading">Loading...</div>
                </div>
            </div>
        </div>

    </div>

    <!-- Purpose: batch detail slideout showing per-day batch rows with metrics and phase timelines -->
    <div id="bat-slideout-detail" class="cc-slide-overlay" data-action-click="bat-close-slideout">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="bat-slideout-title">Batch Details</h3>
                <button class="cc-dialog-close" data-action-click="bat-close-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="bat-slideout-body">
                <div class="bat-loading">Loading...</div>
            </div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
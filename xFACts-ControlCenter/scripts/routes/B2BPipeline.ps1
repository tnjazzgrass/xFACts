<#
.SYNOPSIS
    Renders the B2B Pipeline dashboard page route.

.DESCRIPTION
    Registers the /b2b-pipeline page route. Renders the B2B pipeline
    dashboard backed by B2B.INT_PipelineTracking and B2B.SI_WorkflowRegistry:
    a daily pulse card row, a real-time live view of in-motion pipeline
    runs read directly from the Integration source, the recent
    workflow-definition changes captured by the version census, and a
    year/month/day run-history summary tree with a filtered runs modal and
    a run-detail slideout. Page
    chrome (nav, header, banners) is rendered by the shared CCShared helpers
    and the page consumes the shared cc- chrome and overlay classes.

.COMPONENT
    B2B

.NOTES
    File Name : B2BPipeline.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\B2BPipeline.ps1

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

# 2026-07-13  Second visual pass: history tree restyled to the platform
#             history-tree convention (year header rows, column-headed month
#             table, nested day rows, average durations); day rows open a
#             day-runs slideout instead of the modal; the runs modal and both
#             slideouts widen to cc-xwide; the content grid is bound to the
#             viewport height so sections scroll internally.
# 2026-07-13  Visual restructure from first-pass review: run history becomes
#             a year/month/day summary accordion; search results and day
#             drill-down move to a paged runs modal; sections gain the flex
#             helper so content scrolls inside its container instead of
#             expanding the page; the live view now reads the Integration
#             source directly for true real-time activity.
# 2026-07-12  Initial implementation. Two-column layout: pulse summary cards,
#             live pipeline activity, and recent workflow changes on the
#             left; the searchable paged run-history table on the right with
#             client search, classification / process-type / date filters,
#             and a pager. Run rows open a run-detail slideout built on the
#             shared cc-slide chrome. One engine card for the
#             Collect-B2BPipeline collector (slug b2b).

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   The /b2b-pipeline page route. Gates on page access, resolves the user
   context, renders the shared chrome, and emits the page shell with its
   content sections, the runs modal, and the run-detail slideout.
   Prefix: b2b
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/b2b-pipeline' -Authentication 'ADLogin' -ScriptBlock {
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/b2b-pipeline'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/b2b-pipeline') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $navHtml      = Get-NavBarHtml -UserContext $ctx -CurrentPageRoute '/b2b-pipeline'
    $headerHtml   = Get-PageHeaderHtml -PageRoute '/b2b-pipeline'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/b2b-pipeline'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/b2b-pipeline.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="b2b-pipeline" data-cc-prefix="b2b">
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
                <div class="cc-card-engine" id="cc-card-engine-b2b">
                    <span class="cc-engine-label">B2B</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-b2b"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-b2b"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div class="b2b-grid-layout">

        <div class="b2b-grid-column">

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Today's Pipeline Pulse</h2>
                    <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                </div>
                <div id="b2b-summary-cards" class="b2b-summary-cards">
                    <div class="b2b-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section cc-fill b2b-section-flex">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Live Pipeline Activity</h2>
                    <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                </div>
                <div id="b2b-live-activity" class="b2b-table-scroll">
                    <div class="b2b-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section b2b-section-compact">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Recent Workflow Changes</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="b2b-workflow-changes">
                    <div class="b2b-loading">Loading...</div>
                </div>
            </div>
        </div>

        <div class="b2b-grid-column">

            <div class="cc-section cc-fill b2b-section-flex">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Run History</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div class="b2b-filter-bar">
                    <input id="b2b-search-input" class="b2b-search-input" type="text" placeholder="Search client..." data-action-keydown="b2b-search-on-enter">
                    <select id="b2b-filter-classification" class="b2b-filter-select"></select>
                    <select id="b2b-filter-type" class="b2b-filter-select"></select>
                    <input id="b2b-filter-from" class="b2b-filter-date" type="date" title="From date">
                    <input id="b2b-filter-to" class="b2b-filter-date" type="date" title="To date">
                    <button class="b2b-filter-btn" data-action-click="b2b-run-search">Search</button>
                    <button class="b2b-filter-btn" data-action-click="b2b-reset-filters">Reset</button>
                </div>
                <div id="b2b-history-tree" class="b2b-table-scroll">
                    <div class="b2b-loading">Loading...</div>
                </div>
            </div>
        </div>

    </div>

    <!-- Purpose: runs slideout listing filtered or per-day pipeline runs with paging -->
    <div id="b2b-slideout-runs" class="cc-slide-overlay" data-action-click="b2b-close-runs-slideout">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="b2b-slideout-runs-title">Pipeline Runs</h3>
                <button class="cc-dialog-close" data-action-click="b2b-close-runs-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="b2b-runs-layout">
                    <div id="b2b-runs-caption" class="b2b-runs-caption">-</div>
                    <div id="b2b-runs-content" class="b2b-table-scroll">
                        <div class="b2b-loading">Loading...</div>
                    </div>
                    <div class="b2b-pager">
                        <button id="b2b-runs-prev" class="b2b-pager-btn" data-action-click="b2b-runs-page" data-b2b-dir="prev">&larr; Prev</button>
                        <span id="b2b-runs-count" class="b2b-pager-info">-</span>
                        <button id="b2b-runs-next" class="b2b-pager-btn" data-action-click="b2b-runs-page" data-b2b-dir="next">Next &rarr;</button>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Purpose: day-runs slideout listing one day's pipeline runs with paging -->
    <div id="b2b-slideout-day" class="cc-slide-overlay" data-action-click="b2b-close-day-slideout">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="b2b-slideout-day-title">Day Runs</h3>
                <button class="cc-dialog-close" data-action-click="b2b-close-day-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="b2b-day-layout">
                    <div id="b2b-day-content" class="b2b-table-scroll">
                        <div class="b2b-loading">Loading...</div>
                    </div>
                    <div class="b2b-pager">
                        <button id="b2b-day-prev" class="b2b-pager-btn" data-action-click="b2b-day-page" data-b2b-dir="prev">&larr; Prev</button>
                        <span id="b2b-day-count" class="b2b-pager-info">-</span>
                        <button id="b2b-day-next" class="b2b-pager-btn" data-action-click="b2b-day-page" data-b2b-dir="next">Next &rarr;</button>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Purpose: run-detail slideout telling one pipeline run's full classification story -->
    <div id="b2b-slideout-run" class="cc-slide-overlay" data-action-click="b2b-close-slideout">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="b2b-slideout-title">Run Details</h3>
                <button class="cc-dialog-close" data-action-click="b2b-close-slideout">&times;</button>
            </div>
            <div class="cc-dialog-body" id="b2b-slideout-body">
                <div class="b2b-loading">Loading...</div>
            </div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
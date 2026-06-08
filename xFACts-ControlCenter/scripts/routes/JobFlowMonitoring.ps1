<#
.SYNOPSIS
    Control Center page route for the JobFlow Monitoring dashboard.

.DESCRIPTION
    Renders the JobFlow monitoring dashboard: live Debt Manager activity, the
    orchestrator process-status grid, the day's flow summary, and the
    expandable execution history. Authenticated and access-gated, then composes
    the page shell from shared chrome helpers and emits page-specific content
    plus the overlay constructs the page's JavaScript drives.

.COMPONENT
    JobFlow

.NOTES
    File Name : JobFlowMonitoring.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\JobFlowMonitoring.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-driven change history for this route file. Most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-04  Refactored to the CC file-format specs. Adopted the cc-shared
#             chrome model (cc-shared.css, cc-shared.js bootloader), the
#             data-cc-page / data-cc-prefix body contract, $bannerHtml chrome
#             banners, the unified cc- overlay constructs, and data-action-*
#             dispatch in place of inline handlers.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the GET /jobflow-monitoring page route. Gates on RBAC access,
   resolves the user context, composes the shared chrome fragments, and emits
   the full page document.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/jobflow-monitoring' -Authentication 'ADLogin' -ScriptBlock {
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/jobflow-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/jobflow-monitoring') -StatusCode 403
        return
    }

    $ctx          = Get-UserContext -WebEvent $WebEvent
    $navHtml      = Get-NavBarHtml -UserContext $ctx -CurrentPageRoute '/jobflow-monitoring'
    $headerHtml   = Get-PageHeaderHtml -PageRoute '/jobflow-monitoring'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/jobflow-monitoring'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/jobflow-monitoring.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="jobflow-monitoring" data-cc-prefix="jfm">
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
                <div class="cc-card-engine" id="cc-card-engine-jobflow">
                    <span class="cc-engine-label">JobFlow</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-jobflow"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-jobflow"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div class="jfm-grid-layout">

        <div class="jfm-grid-column">
            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Daily Summary</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="jfm-daily-summary" class="jfm-summary-content">
                    <div class="jfm-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Live Activity</h2>
                    <div class="cc-section-header-right">
                        <button id="jfm-btn-pending-queue" class="jfm-pending-btn" data-action-click="jfm-open-pending-queue" title="View pending queue">
                            &#9202; Pending <span id="jfm-pending-count-badge" class="jfm-pending-badge jfm-hidden">0</span>
                        </button>
                        <span class="cc-refresh-badge-live" title="Refreshes on live interval"><span class="cc-refresh-badge-dot"></span></span>
                    </div>
                </div>
                <div class="jfm-subsection">
                    <h3 class="jfm-subsection-title">Currently Executing</h3>
                    <div id="jfm-executing-jobs" class="jfm-activity-content">
                        <div class="jfm-loading">Loading...</div>
                    </div>
                </div>
            </div>
        </div>

        <div class="jfm-grid-column">
            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Process Status</h2>
                    <div class="cc-section-header-right">
                        <button id="jfm-btn-app-tasks" class="jfm-section-action-btn" data-action-click="jfm-open-tasks" title="View and manage scheduled tasks across application servers">
                            <span class="jfm-btn-icon">&#9881;</span> App Server Tasks
                        </button>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="jfm-process-status" class="jfm-status-grid">
                    <div class="jfm-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section cc-fill">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Execution History</h2>
                    <div class="cc-section-header-right">
                        <span class="jfm-history-count" id="jfm-history-count"></span>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="jfm-execution-history" class="jfm-history-content">
                    <div class="jfm-loading">Loading...</div>
                </div>
            </div>
        </div>

    </div>

    <!-- Purpose: flow / day / pending / ad-hoc / stall detail slideout -->
    <div id="jfm-slideout-flow" class="cc-slide-overlay" data-action-click="jfm-close-slideout">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 id="jfm-slideout-title" class="cc-dialog-title">Flow Details</h3>
                <button class="cc-dialog-close" data-action-click="jfm-close-slideout">&times;</button>
            </div>
            <div id="jfm-slideout-body" class="cc-dialog-body">
                <div class="jfm-loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Purpose: app server task distribution editor modal -->
    <div id="jfm-modal-tasks" class="cc-modal-overlay cc-hidden" data-action-click="jfm-close-tasks">
        <div class="cc-dialog cc-dialog-modal cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">App Server Task Distribution</h3>
                <button class="cc-dialog-close" data-action-click="jfm-close-tasks">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <p class="jfm-modal-subtitle">Click a cell to stage changes. Only one server should be enabled per flow.</p>
                <div id="jfm-tasks-grid" class="jfm-tasks-grid">
                    <div class="jfm-loading">Loading...</div>
                </div>
            </div>
            <div class="cc-dialog-actions">
                <span id="jfm-pending-changes-indicator" class="jfm-pending-changes-indicator jfm-hidden"></span>
                <button id="jfm-btn-apply-changes" class="cc-dialog-btn-primary jfm-hidden" data-action-click="jfm-show-apply-confirmation">Apply Changes</button>
                <button class="cc-dialog-btn-cancel" data-action-click="jfm-close-tasks">Close</button>
            </div>
        </div>
    </div>

    <!-- Purpose: confirm staged app server task changes -->
    <div id="jfm-modal-confirm" class="cc-modal-overlay cc-hidden" data-action-click="jfm-close-confirm">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Confirm Changes</h3>
                <button class="cc-dialog-close" data-action-click="jfm-close-confirm">&times;</button>
            </div>
            <div id="jfm-confirm-changes-body" class="cc-dialog-body">
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="jfm-cancel-all-changes">Cancel</button>
                <button class="cc-dialog-btn-primary" data-action-click="jfm-apply-all-changes">Apply</button>
            </div>
        </div>
    </div>

    <!-- Purpose: flow configuration viewer and drift resolution modal -->
    <div id="jfm-modal-configsync" class="cc-modal-overlay cc-hidden" data-action-click="jfm-close-configsync">
        <div class="cc-dialog cc-dialog-modal cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Flow Configuration</h3>
                <button class="cc-dialog-close" data-action-click="jfm-close-configsync">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="jfm-cs-selector-bar">
                    <label for="jfm-configsync-flow-select">Flow:</label>
                    <select id="jfm-configsync-flow-select" class="jfm-cs-selector-select" data-action-change="jfm-configsync-flow-selected">
                        <option value="">Loading...</option>
                    </select>
                </div>
                <div id="jfm-configsync-body" class="jfm-cs-content">
                    <div class="jfm-loading">Loading...</div>
                </div>
            </div>
            <div class="cc-dialog-actions">
                <div id="jfm-configsync-footer-actions" class="jfm-cs-footer-actions"></div>
                <button class="cc-dialog-btn-cancel" data-action-click="jfm-close-configsync">Close</button>
            </div>
        </div>
    </div>

    <!-- Purpose: confirm flow configuration changes before save -->
    <div id="jfm-modal-cs-confirm" class="cc-modal-overlay cc-hidden" data-action-click="jfm-close-cs-confirm">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Confirm Changes</h3>
                <button class="cc-dialog-close" data-action-click="jfm-close-cs-confirm">&times;</button>
            </div>
            <div id="jfm-cs-confirm-body" class="cc-dialog-body">
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="jfm-close-cs-confirm">Cancel</button>
                <button class="cc-dialog-btn-primary" data-action-click="jfm-confirm-and-save-configsync">Apply Changes</button>
            </div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
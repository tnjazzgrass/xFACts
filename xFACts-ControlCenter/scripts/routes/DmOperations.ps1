<#
.SYNOPSIS
    Renders the DM Operations monitoring dashboard page.

.DESCRIPTION
    Page route for the Control Center DM Operations dashboard. Performs the
    RBAC access check, resolves user context, composes the dynamic nav bar,
    page header, and chrome banners from the registry helpers, and emits the
    page shell. The page presents lifetime totals and, per process, a Today
    summary and execution history for the unified consumer archive and the
    consumer shell purge, with batch-detail slideouts, a per-process schedule
    modal, and an admin launch-confirmation modal. Page behavior and content
    rendering are driven by dm-operations.js; styling by dm-operations.css and
    cc-shared.css.

.COMPONENT
    DmOps

.NOTES
    File Name : DmOperations.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\DmOperations.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for the DM Operations page route.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-03  Refactored to the cc-shared model: cc-section body shell with
#             data-cc-page/data-cc-prefix, cc-shared.css/js replacing the
#             legacy engine-events pair, cc- chrome classes, $bannerHtml
#             chrome, cc- engine cards, and single-rooted cc-dialog overlay
#             constructs with data-action-click wiring. Per-process schedule
#             converted from a slideout to a wide modal. Admin-only schedule,
#             abort, and launch controls are now gated server-side via a
#             per-process flag in the process-status API and rendered by the
#             page module rather than emitted as hidden markup here.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the GET /dm-operations page route, gated by ADLogin
   authentication and an RBAC access check, and renders the dashboard shell.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/dm-operations' -Authentication 'ADLogin' -ScriptBlock {

    # Import the cc- emission helpers. During the CC File Format
    # Standardization migration this overrides the auto-loaded xFACts-Helpers
    # module for this route's execution, so Get-NavBarHtml and
    # Get-PageHeaderHtml emit cc- prefixed chrome classes that match
    # cc-shared.css and cc-shared.js. Once every page has migrated and
    # Start-ControlCenter.ps1 loads xFACts-CCShared.psm1 at startup instead
    # of xFACts-Helpers.psm1, this line is removed.
    Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/dm-operations'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/dm-operations') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/dm-operations'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/dm-operations'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/dm-operations'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/dm-operations.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="dm-operations" data-cc-prefix="dmo">
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
                <div class="cc-card-engine" id="cc-card-engine-archive">
                    <span class="cc-engine-label">ARCHIVE</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-archive"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-archive"></span>
                </div>
                <div class="cc-card-engine" id="cc-card-engine-shell">
                    <span class="cc-engine-label">SHELL</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-shell"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-shell"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div class="cc-section">
        <div class="cc-section-header">
            <h2 class="cc-section-title">Lifetime Totals</h2>
            <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
        </div>
        <div id="dmo-lifetime-totals" class="dmo-summary-cards">
            <div class="cc-slide-empty">Loading...</div>
        </div>
    </div>

    <div class="dmo-two-column-layout">

        <div class="dmo-column">

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Consumer Archive &mdash; Today</h2>
                    <div class="cc-section-header-right">
                        <span class="dmo-target-badge dmo-env-unknown" id="dmo-archive-target-badge" title="Loading target server&hellip;">&hellip;</span>
                        <div class="dmo-admin-controls" id="dmo-archive-admin-controls"></div>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="dmo-archive-today">
                    <div class="cc-slide-empty">Loading...</div>
                </div>
            </div>

            <div class="cc-section cc-fill">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Consumer Archive &mdash; History</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="dmo-archive-history">
                    <div class="cc-slide-empty">Loading...</div>
                </div>
            </div>

        </div>

        <div class="dmo-column">

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Shell Purge &mdash; Today</h2>
                    <div class="cc-section-header-right">
                        <span class="dmo-target-badge dmo-env-unknown" id="dmo-shell-target-badge" title="Loading target server&hellip;">&hellip;</span>
                        <div class="dmo-admin-controls" id="dmo-shell-admin-controls"></div>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="dmo-shell-today">
                    <div class="cc-slide-empty">Loading...</div>
                </div>
            </div>

            <div class="cc-section cc-fill">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Shell Purge &mdash; History</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="dmo-shell-history">
                    <div class="cc-slide-empty">Loading...</div>
                </div>
            </div>

        </div>

    </div>

    <!-- Batch detail slideout: full batch-detail rows for a selected archive or shell purge batch -->
    <div id="dmo-slideout-batch-detail" class="cc-slide-overlay" data-action-click="dmo-close-batch-detail">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="dmo-slideout-batch-detail-title">Batch Detail</h3>
                <button class="cc-dialog-close" data-action-click="dmo-close-batch-detail">&times;</button>
            </div>
            <div class="cc-dialog-body" id="dmo-slideout-batch-detail-body">
                <div class="cc-slide-empty">Loading batch detail&hellip;</div>
            </div>
        </div>
    </div>

    <!-- Schedule modal: per-process weekly execution-window editor, shared between archive and shell purge -->
    <div id="dmo-modal-schedule" class="cc-modal-overlay cc-hidden" data-action-click="dmo-close-schedule">
        <div class="cc-dialog cc-dialog-modal cc-wide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="dmo-modal-schedule-title">Schedule</h3>
                <button class="cc-dialog-close" data-action-click="dmo-close-schedule">&times;</button>
            </div>
            <div class="cc-dialog-body" id="dmo-modal-schedule-body">
                <div class="cc-slide-empty">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Launch confirmation modal: admin manual process launch -->
    <div id="dmo-modal-launch" class="cc-modal-overlay cc-hidden" data-action-click="dmo-close-launch">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="dmo-modal-launch-title">Launch Process</h3>
                <button class="cc-dialog-close" data-action-click="dmo-close-launch">&times;</button>
            </div>
            <div class="cc-dialog-body" id="dmo-modal-launch-body"></div>
            <div class="cc-dialog-actions" id="dmo-modal-launch-footer"></div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
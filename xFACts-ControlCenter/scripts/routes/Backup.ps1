<#
.SYNOPSIS
    Pode route for the Backup Monitoring page (/backup).

.DESCRIPTION
    Registers the GET /backup route. Performs RBAC access check via Get-UserAccess and
    returns the Access Denied page on failure. Resolves user context, renders nav and
    page header from RBAC_NavRegistry, and emits the Backup Monitoring page HTML
    following the CC HTML Spec for body attributes, page-local prefixing, engine card
    rendering, and data-action-click event dispatch.

.COMPONENT
    ServerOps.Backup

.NOTES
    FILE ORGANIZATION
        1. CHANGELOG
        2. ROUTE: PAGE PATH
#>

# ============================================================================
# CHANGELOG
# ----------------------------------------------------------------------------
# 2026-05-17  Phase 1 (CC File Format Standardization): refactored to the
#             CC HTML Spec and CC PS Spec. Replaced engine-events.css/
#             engine-events.js references with cc-shared.css and the
#             literal /js/cc-shared.js script tag (the spec requires the
#             literal tag in markup; Get-PageScriptTagHtml is no longer
#             called from this route). Added body data-page/data-prefix
#             attributes, the section-platform body class, the connection
#             banner placeholder, and the page-error-banner placeholder.
#             Prefixed page-local IDs and classes with bkp-; preserved
#             chrome IDs (engine cards, connection-banner, page-error-
#             banner, last-update). Engine card labels rendered in
#             uppercase to match ProcessRegistry.cc_engine_label.
#             Replaced inline onclick handlers with data-action-click
#             attributes dispatched by bkp_clickActions in backup.js.
#             Renamed modal sub-element IDs from bkp-modal-detail-title/
#             body to bkp-detail-title/body so the modal-ID grammar parses
#             cleanly. Renamed badge-live-active to bkp-badge-live-active
#             and the inner dot class from badge-dot to refresh-badge-dot
#             (the actual cc-shared.css class).
# 2026-04-30  Phase 4 (Chrome Standardization, modal migration): pipeline
#             and queue detail modal HTML migrated from the legacy custom
#             .modal/.modal-content/.modal-header/.modal-body pattern to
#             the shared .xf-modal-overlay/.xf-modal.wide/.xf-modal-header/
#             .xf-modal-body classes. The outer element ID was renamed
#             from detail-modal to detail-modal-overlay; the .hidden class
#             on the overlay is the initial state, toggled by JS via
#             openDetailModal/closeDetailModal.
# 2026-04-30  Phase 4 (Chrome Standardization): added body section class
#             (section-platform) so H1 color is driven by shared CSS via
#             RBAC_NavRegistry section_key. Renamed connection banner
#             placeholder from id/class connection-error to connection-banner
#             matching the engine-events.js rename.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle.
# ============================================================================

# ============================================================================
# ROUTE: PAGE PATH
# ----------------------------------------------------------------------------
# Registers the Backup Monitoring dashboard page at GET /backup. Performs
# RBAC access check, resolves user context, renders nav and header from
# the RBAC_NavRegistry, and emits the page HTML.
# ============================================================================

Add-PodeRoute -Method Get -Path '/backup' -Authentication 'ADLogin' -ScriptBlock {

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/backup'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/backup') -StatusCode 403
        return
    }

    $ctx          = Get-UserContext      -WebEvent $WebEvent
    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/backup'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/backup'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/backup'

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/backup.css">
    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="section-platform" data-page="backup" data-prefix="bkp">
$navHtml

    <div class="header-bar">
        <div>
            $headerHtml
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span class="live-indicator"></span>
                <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" data-action-click="cc-page-refresh" title="Refresh all data">&#8635;</button>
            </div>
            <div class="engine-row">
                <div class="engine-card" id="card-engine-collection">
                    <span class="engine-label">BACKUP</span>
                    <div class="engine-bar disabled" id="engine-bar-collection"></div>
                    <span class="engine-countdown" id="engine-cd-collection">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-networkcopy">
                    <span class="engine-label">NETWORK</span>
                    <div class="engine-bar disabled" id="engine-bar-networkcopy"></div>
                    <span class="engine-countdown" id="engine-cd-networkcopy">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-awsupload">
                    <span class="engine-label">AWS</span>
                    <div class="engine-bar disabled" id="engine-bar-awsupload"></div>
                    <span class="engine-countdown" id="engine-cd-awsupload">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-retention">
                    <span class="engine-label">RETENTION</span>
                    <div class="engine-bar disabled" id="engine-bar-retention"></div>
                    <span class="engine-countdown" id="engine-cd-retention">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>

    <div id="page-error-banner" class="page-error-banner"></div>
    <div id="connection-banner" class="connection-banner"></div>

    <div class="bkp-two-column-layout">

        <div class="bkp-left-column">

            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Pipeline Status</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="bkp-pipeline-status">
                    <div class="bkp-loading">Loading...</div>
                </div>
            </div>

            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Active Operations</h2>
                    <div class="section-header-right">
                        <span class="refresh-badge-live" id="bkp-badge-live-active" title="Refreshes on live interval">
                            <span class="refresh-badge-dot"></span>
                        </span>
                    </div>
                </div>
                <div id="bkp-active-operations" class="bkp-active-operations-content">
                    <div class="bkp-loading">Loading...</div>
                </div>
            </div>

        </div>

        <div class="bkp-right-column">

            <div class="bkp-side-by-side-row">

                <div class="section bkp-half-section">
                    <div class="section-header">
                        <h2 class="section-title">Queue Status</h2>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                    <div id="bkp-queue-status">
                        <div class="bkp-loading">Loading...</div>
                    </div>
                </div>

                <div class="section bkp-half-section">
                    <div class="section-header">
                        <h2 class="section-title">Retention Status</h2>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                    <div id="bkp-retention-status">
                        <div class="bkp-loading">Loading...</div>
                    </div>
                </div>

            </div>

            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Storage Status</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="bkp-storage-status">
                    <div class="bkp-loading">Loading...</div>
                </div>
            </div>

        </div>

    </div>

    <!-- Modal for pipeline and queue file-level detail breakdowns -->
    <div id="bkp-modal-detail-overlay" class="xf-modal-overlay hidden" data-action-click="modal-close-on-overlay">
        <div class="xf-modal wide">
            <div class="xf-modal-header">
                <h3 id="bkp-detail-title">Detail</h3>
                <button class="xf-modal-close" data-action-click="modal-close">&times;</button>
            </div>
            <div class="xf-modal-body" id="bkp-detail-body">
                <div class="bkp-loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Slideout for displaying local-drive backup retention candidates -->
    <div id="bkp-slideout-local-retention-overlay" class="slide-overlay" data-action-click="slideout-close" data-action-type="local"></div>
    <!-- Slideout for displaying local-drive backup retention candidates -->
    <div id="bkp-slideout-local-retention" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3 class="slide-panel-title">&#128465; Local Retention Candidates</h3>
            <button class="xf-modal-close" data-action-click="slideout-close" data-action-type="local">&times;</button>
        </div>
        <div class="slide-panel-body" id="bkp-local-retention-body">
            <div class="bkp-loading">Loading...</div>
        </div>
    </div>

    <!-- Slideout for displaying network-share backup retention candidates -->
    <div id="bkp-slideout-network-retention-overlay" class="slide-overlay" data-action-click="slideout-close" data-action-type="network"></div>
    <!-- Slideout for displaying network-share backup retention candidates -->
    <div id="bkp-slideout-network-retention" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3 class="slide-panel-title">&#128465; Network Retention Candidates</h3>
            <button class="xf-modal-close" data-action-click="slideout-close" data-action-type="network">&times;</button>
        </div>
        <div class="slide-panel-body" id="bkp-network-retention-body">
            <div class="bkp-loading">Loading...</div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
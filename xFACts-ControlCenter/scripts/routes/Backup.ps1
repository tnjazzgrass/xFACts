<#
.SYNOPSIS
    Pode route for the Backup Monitoring page (/backup).

.DESCRIPTION
    Registers the GET /backup route. Performs RBAC access check via Get-UserAccess and
    returns the Access Denied page on failure. Resolves user context, renders nav and
    page header from RBAC_NavRegistry, and emits the Backup Monitoring page HTML
    following the CC HTML Spec for body attributes, page-local prefixing, engine card
    rendering, and data-action-click event dispatch.

    During the CC File Format Standardization §11.2.4 unified prefix rename
    migration, this route explicitly imports the xFACts-CCShared module at
    the top of its scriptblock. This shadows the auto-loaded xFACts-Helpers
    module for this route's execution so Get-NavBarHtml and Get-PageHeaderHtml
    emit cc- prefixed chrome classes that match cc-shared.css and cc-shared.js.
    Once every page has migrated, xFACts-Helpers.psm1 is deleted,
    Start-ControlCenter.ps1 is updated to load xFACts-CCShared.psm1 at
    startup, and the explicit Import-Module line in this route is removed.

.COMPONENT
    ServerOps.Backup

.NOTES
    FILE ORGANIZATION
        CHANGELOG
        ROUTE: PAGE PATH
#>

# ============================================================================
# CHANGELOG
# ----------------------------------------------------------------------------
# 2026-05-18  CC File Format Standardization §11.2.4 (unified prefix rename
#             pass): adopted the new cc- chrome class convention across the
#             entire page emission. Body data-page/data-prefix attributes
#             renamed to data-cc-page/data-cc-prefix. All chrome class names
#             (header-bar, header-right, refresh-info, live-indicator,
#             page-refresh-btn, engine-row, engine-card, engine-label,
#             engine-bar, engine-countdown, page-error-banner,
#             connection-banner, section, section-header, section-title,
#             section-header-right, refresh-badge-event, refresh-badge-live,
#             refresh-badge-dot, last-updated) renamed with cc- prefix. All
#             chrome IDs (last-update, page-error-banner, connection-banner,
#             card-engine-<slug>, engine-bar-<slug>, engine-cd-<slug>)
#             renamed with cc- prefix. Modal chrome migrated from xf-modal
#             family to cc-modal family (cc-modal-overlay, cc-modal, cc-
#             modal-header, cc-modal-close, cc-modal-body); xf- prefix
#             dropped entirely. Slideout chrome (slide-overlay, slide-
#             panel, slide-panel-header, slide-panel-title, slide-panel-
#             body) renamed with cc- prefix. Compound modifiers (section-
#             platform, hidden, wide, disabled) stay unprefixed per spec.
#             Page-local bkp- identifiers are unchanged. Added explicit
#             Import-Module of xFACts-CCShared.psm1 inside the route
#             scriptblock so Get-NavBarHtml and Get-PageHeaderHtml emit
#             cc- prefixed nav and header classes during the page-by-page
#             migration window.
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

    # Import the cc- emission helpers. During the CC File Format
    # Standardization §11.2.4 migration this overrides the auto-loaded
    # xFACts-Helpers module for this route's execution, so Get-NavBarHtml
    # and Get-PageHeaderHtml emit cc- prefixed chrome classes that match
    # cc-shared.css and cc-shared.js. Once every page has migrated and
    # Start-ControlCenter.ps1 loads xFACts-CCShared.psm1 at startup
    # instead of xFACts-Helpers.psm1, this line is removed.
    Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking

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
<body class="section-platform" data-cc-page="backup" data-cc-prefix="bkp">
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
                <div class="cc-engine-card" id="cc-card-engine-collection">
                    <span class="cc-engine-label">BACKUP</span>
                    <div class="cc-engine-bar disabled" id="cc-engine-bar-collection"></div>
                    <span class="cc-engine-countdown" id="cc-engine-cd-collection">&nbsp;</span>
                </div>
                <div class="cc-engine-card" id="cc-card-engine-networkcopy">
                    <span class="cc-engine-label">NETWORK</span>
                    <div class="cc-engine-bar disabled" id="cc-engine-bar-networkcopy"></div>
                    <span class="cc-engine-countdown" id="cc-engine-cd-networkcopy">&nbsp;</span>
                </div>
                <div class="cc-engine-card" id="cc-card-engine-awsupload">
                    <span class="cc-engine-label">AWS</span>
                    <div class="cc-engine-bar disabled" id="cc-engine-bar-awsupload"></div>
                    <span class="cc-engine-countdown" id="cc-engine-cd-awsupload">&nbsp;</span>
                </div>
                <div class="cc-engine-card" id="cc-card-engine-retention">
                    <span class="cc-engine-label">RETENTION</span>
                    <div class="cc-engine-bar disabled" id="cc-engine-bar-retention"></div>
                    <span class="cc-engine-countdown" id="cc-engine-cd-retention">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>

    <div id="cc-page-error-banner" class="cc-page-error-banner"></div>
    <div id="cc-connection-banner" class="cc-connection-banner"></div>

    <div class="bkp-two-column-layout">

        <div class="bkp-left-column">

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Pipeline Status</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="bkp-pipeline-status">
                    <div class="bkp-loading">Loading...</div>
                </div>
            </div>

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Active Operations</h2>
                    <div class="cc-section-header-right">
                        <span class="cc-refresh-badge-live" id="bkp-badge-live-active" title="Refreshes on live interval">
                            <span class="cc-refresh-badge-dot"></span>
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

                <div class="cc-section bkp-half-section">
                    <div class="cc-section-header">
                        <h2 class="cc-section-title">Queue Status</h2>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                    <div id="bkp-queue-status">
                        <div class="bkp-loading">Loading...</div>
                    </div>
                </div>

                <div class="cc-section bkp-half-section">
                    <div class="cc-section-header">
                        <h2 class="cc-section-title">Retention Status</h2>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                    <div id="bkp-retention-status">
                        <div class="bkp-loading">Loading...</div>
                    </div>
                </div>

            </div>

            <div class="cc-section">
                <div class="cc-section-header">
                    <h2 class="cc-section-title">Storage Status</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="bkp-storage-status">
                    <div class="bkp-loading">Loading...</div>
                </div>
            </div>

        </div>

    </div>

    <!-- Modal for pipeline and queue file-level detail breakdowns -->
    <div id="bkp-modal-detail-overlay" class="cc-modal-overlay hidden" data-action-click="modal-close-on-overlay">
        <div class="cc-modal wide">
            <div class="cc-modal-header">
                <h3 id="bkp-detail-title">Detail</h3>
                <button class="cc-modal-close" data-action-click="modal-close">&times;</button>
            </div>
            <div class="cc-modal-body" id="bkp-detail-body">
                <div class="bkp-loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Slideout for displaying local-drive backup retention candidates -->
    <div id="bkp-slideout-local-retention-overlay" class="cc-slide-overlay" data-action-click="slideout-close" data-action-type="local"></div>
    <!-- Slideout for displaying local-drive backup retention candidates -->
    <div id="bkp-slideout-local-retention" class="cc-slide-panel wide">
        <div class="cc-slide-panel-header">
            <h3 class="cc-slide-panel-title">&#128465; Local Retention Candidates</h3>
            <button class="cc-modal-close" data-action-click="slideout-close" data-action-type="local">&times;</button>
        </div>
        <div class="cc-slide-panel-body" id="bkp-local-retention-body">
            <div class="bkp-loading">Loading...</div>
        </div>
    </div>

    <!-- Slideout for displaying network-share backup retention candidates -->
    <div id="bkp-slideout-network-retention-overlay" class="cc-slide-overlay" data-action-click="slideout-close" data-action-type="network"></div>
    <!-- Slideout for displaying network-share backup retention candidates -->
    <div id="bkp-slideout-network-retention" class="cc-slide-panel wide">
        <div class="cc-slide-panel-header">
            <h3 class="cc-slide-panel-title">&#128465; Network Retention Candidates</h3>
            <button class="cc-modal-close" data-action-click="slideout-close" data-action-type="network">&times;</button>
        </div>
        <div class="cc-slide-panel-body" id="bkp-network-retention-body">
            <div class="bkp-loading">Loading...</div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
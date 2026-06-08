<#
.SYNOPSIS
    Renders the JBoss Monitoring Control Center dashboard page.

.DESCRIPTION
    Page route for the JBoss Monitoring dashboard. Emits the page shell, the
    standard Control Center chrome (header bar, refresh info, the Collect-JBossMetrics
    engine card, and banner chrome), the three-column application-server grid, and
    the two page overlays (server-metric info modal and the admin DM app-server
    switch modal). All page data is loaded client-side via the JBoss Monitoring API.

.COMPONENT
    JBoss

.NOTES
    File Name : JBossMonitoring.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\JBossMonitoring.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this file, most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-03  Migrated to CC file-format specs. Header converted to CBH block;
#             CHANGELOG moved to dedicated section. Chrome reshelled to cc-*
#             (cc-header-bar/cc-header-right/cc-refresh-info/cc-card-engine/
#             cc-engine-bar/cc-engine-cd); body now cc-section-platform with
#             data-cc-page/data-cc-prefix; banner chrome via $bannerHtml; assets
#             switched to cc-shared.css/cc-shared.js. Page-local ids/classes
#             reprefixed jbm-. Inline onclick handlers replaced with
#             data-action-click. Info and switch modals rebuilt as cc-modal-overlay
#             /cc-dialog constructs (jbm-modal-info, jbm-modal-switch) with
#             backdrop-close. Admin gating moved server-side: window.isAdmin inline
#             script and __IS_ADMIN__ string-replace removed; the switch affordance
#             is gated by the API CanSwitch flag. Transitional CCShared import shim
#             added as first scriptblock statement.
# 2026-04-30  Phase 4 (Chrome Standardization, modal migration): three local
#             modal/dialog systems migrated to the shared modal system. Info modal
#             and DM switch modal moved to shared overlay/dialog markup; the local
#             confirm overlay was deleted in favor of the shared confirm helper.
# 2026-04-30  Phase 4 (Chrome Standardization): added body section class so the
#             page H1 color is driven by shared CSS via the nav section key.
#             Renamed the connection banner placeholder to the shared name.
# 2026-04-29  Phase 3d of dynamic nav: page H1 link, title, subtitle, and browser
#             tab title now render from the nav registry via Get-PageHeaderHtml
#             and Get-PageBrowserTitle.
# 2026-04-29  Phase 3 of dynamic nav: replaced the hardcoded nav block with the
#             Get-NavBarHtml helper. Nav renders from the nav registry with
#             per-user permission filtering and section-based grouping.
# 2026-03-18  Renamed from DmMonitoring.ps1. Route /dm-monitoring -> /jboss-monitoring.
#             CSS/JS references updated. Page title -> JBoss Monitoring.
# 2026-03-08  Added info modal and section-level help icon. Removed queue slideout
#             (replaced by inline accordion in JS).
# 2026-03-08  Replaced lower section placeholder with queue slideout panel.
# 2026-03-08  Added Users badge, server switch modal, confirm dialog, and admin
#             context injection (migrated from the Admin page).
# 2026-03-07  Initial implementation.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers GET /jboss-monitoring. Performs the page access check, renders the
   chrome shell and three-column server grid, and emits the info and switch
   overlays. Server data, deltas, and the switch flow are handled client-side.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/jboss-monitoring' -Authentication 'ADLogin' -ScriptBlock {
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/jboss-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/jboss-monitoring') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/jboss-monitoring'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/jboss-monitoring'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/jboss-monitoring'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/jboss-monitoring.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="jboss-monitoring" data-cc-prefix="jbm">
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
                <div class="cc-card-engine" id="cc-card-engine-jboss">
                    <span class="cc-engine-label">JBOSS</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-jboss"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-jboss"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div class="cc-section cc-fill">
        <div class="cc-section-header">
            <h3 class="cc-section-title">Application Servers <button type="button" class="jbm-info-icon" data-action-click="jbm-show-info" data-action-jbm-info-key="overview">?</button></h3>
            <div class="cc-section-header-right">
                <span class="cc-refresh-badge-event" title="Updates when Health collector completes">&#9889;</span>
            </div>
        </div>
        <div class="jbm-server-grid" id="jbm-server-grid">
            <div class="jbm-server-card" id="jbm-server-card-0">
                <div class="jbm-server-card-header">
                    <span class="jbm-server-name" id="jbm-server-name-0">Loading...</span>
                    <span class="jbm-server-role" id="jbm-server-role-0"></span>
                </div>
                <div class="jbm-server-card-body" id="jbm-server-body-0">
                    <div class="jbm-loading">Loading...</div>
                </div>
            </div>
            <div class="jbm-server-card" id="jbm-server-card-1">
                <div class="jbm-server-card-header">
                    <span class="jbm-server-name" id="jbm-server-name-1">Loading...</span>
                    <span class="jbm-server-role" id="jbm-server-role-1"></span>
                </div>
                <div class="jbm-server-card-body" id="jbm-server-body-1">
                    <div class="jbm-loading">Loading...</div>
                </div>
            </div>
            <div class="jbm-server-card" id="jbm-server-card-2">
                <div class="jbm-server-card-header">
                    <span class="jbm-server-name" id="jbm-server-name-2">Loading...</span>
                    <span class="jbm-server-role" id="jbm-server-role-2"></span>
                </div>
                <div class="jbm-server-card-body" id="jbm-server-body-2">
                    <div class="jbm-loading">Loading...</div>
                </div>
            </div>
        </div>
    </div>

    <!-- Purpose: server-metric help modal; body populated from the JS INFO dictionary -->
    <div id="jbm-modal-info" class="cc-modal-overlay cc-hidden" data-action-click="jbm-close-info">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="jbm-info-title">-</h3>
                <button class="cc-dialog-close" data-action-click="jbm-close-info">&times;</button>
            </div>
            <div class="cc-dialog-body" id="jbm-info-body"></div>
        </div>
    </div>

    <!-- Purpose: admin DM application-server switch picker (SharePoint link target) -->
    <div id="jbm-modal-switch" class="cc-modal-overlay cc-hidden" data-action-click="jbm-close-switch">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">DM Application Server</h3>
                <button class="cc-dialog-close" data-action-click="jbm-close-switch">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="jbm-switch-subtitle">SharePoint navigation link target</div>
                <div class="jbm-switch-grid" id="jbm-switch-grid">
                    <button class="jbm-switch-btn" data-action-click="jbm-select-server" data-action-jbm-server="DM-PROD-APP">
                        <div class="jbm-switch-name">APP</div>
                        <div class="jbm-switch-host">dm-prod-app</div>
                    </button>
                    <button class="jbm-switch-btn" data-action-click="jbm-select-server" data-action-jbm-server="DM-PROD-APP2">
                        <div class="jbm-switch-name">APP2</div>
                        <div class="jbm-switch-host">dm-prod-app2</div>
                    </button>
                    <button class="jbm-switch-btn" data-action-click="jbm-select-server" data-action-jbm-server="DM-PROD-APP3">
                        <div class="jbm-switch-name">APP3</div>
                        <div class="jbm-switch-host">dm-prod-app3</div>
                    </button>
                </div>
                <div class="jbm-switch-status" id="jbm-switch-status"></div>
            </div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
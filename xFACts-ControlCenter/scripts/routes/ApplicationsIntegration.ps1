<#
.SYNOPSIS
    Applications & Integration departmental dashboard page route.

.DESCRIPTION
    Departmental tools dashboard for the Applications & Integration team.
    Renders a Debt Manager Tools section (links to the BDL Import workflow
    plus placeholder cards for future toolkit functions) and, for admins, an
    Administration section exposing BDL Content Management (a two-tier
    slide-up catalog dock) and the DM job triggers (Refresh Drools, Release
    Notices, Balance Sync) via environment-selection modals. The page has no
    orchestrator-driven engine cards. Page chrome, nav, header, and banners
    are supplied by xFACts-CCShared.psm1 and cc-shared.css/js; page-local
    content classes and ids carry the aai- prefix.

.COMPONENT
    DeptOps.ApplicationsIntegration

.NOTES
    File Name : ApplicationsIntegration.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\ApplicationsIntegration.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this route file, most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-03  Refactored to the CC File Format standard: adopted the cc- chrome
#             contract (cc-header-bar, cc-refresh-info, cc-section), data-cc-page
#             / data-cc-prefix body attributes, the cc-shared.css/js asset
#             references, the $bannerHtml chrome substitution, and the CCShared
#             import shim. Admin tool cards and the BDL Catalog slide-up dock
#             rewritten with data-action-* event wiring in place of inline
#             onclick handlers; page-local content classes and ids carry the
#             aai- prefix. Admin-conditional body sections preserved.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml. Page H1 link, title, subtitle, and browser tab
#             title now render from RBAC_NavRegistry via Get-PageHeaderHtml and
#             Get-PageBrowserTitle.
# 2026-04-13  Added Refresh Drools card with environment selection modal.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the GET /departmental/applications-integration page route.
   Performs the page-level RBAC access check, resolves the user context and
   the shared nav / header / banner fragments, and emits the page HTML shell.
   The Administration section and the BDL Catalog dock are rendered only for
   admin users; non-admins receive the Debt Manager Tools section alone.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/departmental/applications-integration' -Authentication 'ADLogin' -ScriptBlock {
    Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/applications-integration'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/applications-integration') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/departmental/applications-integration'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/departmental/applications-integration'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/departmental/applications-integration'
    $bannerHtml   = Get-ChromeBannersHtml

    # Administration section visibility. The admin markup (tool-card section,
    # BDL Catalog dock, and DM job modals) is always emitted in the page shell
    # so its element IDs resolve in the asset registry; the section is hidden
    # from non-admins via the aai-hidden modifier. The API independently
    # enforces admin access on every admin endpoint, so hiding is presentation
    # only, not the security boundary.
    $adminSectionClassList = @('cc-section', 'aai-admin-section')
    if (-not $ctx.IsAdmin) { $adminSectionClassList += 'aai-hidden' }
    $adminSectionClass = ($adminSectionClassList -join ' ')

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/applications-integration.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-departmental" data-cc-page="applications-integration" data-cc-prefix="aai">
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
        </div>
    </div>

    $bannerHtml

    <div class="cc-section" id="aai-tools-section">
        <div class="cc-section-header">
            <h2 class="cc-section-title">Debt Manager Tools</h2>
        </div>
        <div class="aai-tool-cards">
            <a class="aai-tool-card" href="/bdl-import">
                <div class="aai-tool-icon">&#128230;</div>
                <div class="aai-tool-label">BDL Import</div>
                <div class="aai-tool-status">Bulk Data Load</div>
            </a>
            <div class="aai-tool-card aai-placeholder">
                <div class="aai-tool-icon">&#128100;</div>
                <div class="aai-tool-label">Consumer Ops</div>
                <div class="aai-tool-status">Phase 4</div>
            </div>
            <div class="aai-tool-card aai-placeholder">
                <div class="aai-tool-icon">&#128179;</div>
                <div class="aai-tool-label">Payment Import</div>
                <div class="aai-tool-status">Future</div>
            </div>
            <div class="aai-tool-card aai-placeholder">
                <div class="aai-tool-icon">&#128196;</div>
                <div class="aai-tool-label">CDL Import</div>
                <div class="aai-tool-status">Future</div>
            </div>
            <div class="aai-tool-card aai-placeholder">
                <div class="aai-tool-icon">&#128268;</div>
                <div class="aai-tool-label">API Caller</div>
                <div class="aai-tool-status">Future</div>
            </div>
        </div>
    </div>

    <div class="$adminSectionClass" id="aai-admin-section">
        <div class="cc-section-header">
            <h2 class="cc-section-title">Administration</h2>
        </div>
        <div class="aai-tool-cards">
            <button class="aai-tool-card aai-admin-tool" data-action-click="aai-open-catalog">
                <div class="aai-tool-icon">&#128218;</div>
                <div class="aai-tool-label">BDL Content Management</div>
                <div class="aai-tool-status aai-admin-badge">Entity Types &amp; Field Settings</div>
            </button>
            <button class="aai-tool-card aai-admin-tool" data-action-click="aai-open-refresh-drools">
                <div class="aai-tool-icon">&#9881;</div>
                <div class="aai-tool-label">Refresh Drools</div>
                <div class="aai-tool-status aai-admin-badge">Rules Engine Refresh</div>
            </button>
            <button class="aai-tool-card aai-admin-tool" data-action-click="aai-open-release-notices">
                <div class="aai-tool-icon">&#128196;</div>
                <div class="aai-tool-label">Release Notices</div>
                <div class="aai-tool-status aai-admin-badge">Release Document Requests</div>
            </button>
            <button class="aai-tool-card aai-admin-tool" data-action-click="aai-open-balance-sync">
                <div class="aai-tool-icon">&#128176;</div>
                <div class="aai-tool-label">Balance Sync</div>
                <div class="aai-tool-status aai-admin-badge">Update Account Balances</div>
            </button>
        </div>
    </div>

    <div id="aai-catalog-backdrop" class="aai-catalog-backdrop" data-action-click="aai-close-catalog"></div>
    <div id="aai-catalog-panel" class="aai-catalog-panel">
        <div class="aai-catalog-handle" data-action-click="aai-close-catalog">
            <div class="aai-catalog-handle-bar"></div>
        </div>
        <div class="aai-catalog-header">
            <div class="aai-catalog-header-left">
                <h2 id="aai-catalog-title" class="aai-catalog-title">BDL Content Management</h2>
                <span id="aai-catalog-count" class="aai-catalog-count"></span>
            </div>
            <button class="aai-catalog-close" data-action-click="aai-close-catalog">&times;</button>
        </div>
        <div id="aai-catalog-mode-selector" class="aai-catalog-mode-selector"></div>
        <div id="aai-catalog-status" class="aai-catalog-status"></div>
        <div id="aai-catalog-body" class="aai-catalog-body"></div>
    </div>

    <div id="aai-catalog-detail" class="aai-catalog-detail">
        <div class="aai-catalog-detail-header">
            <button class="aai-catalog-detail-back" data-action-click="aai-close-catalog-detail" title="Back to format list">&#9664;</button>
            <h3 id="aai-catalog-detail-title" class="aai-catalog-detail-title"></h3>
            <span id="aai-catalog-detail-count" class="aai-catalog-detail-count"></span>
        </div>
        <div id="aai-catalog-detail-status" class="aai-catalog-detail-status"></div>
        <div id="aai-catalog-detail-body" class="aai-catalog-detail-body"></div>
    </div>

    <div id="aai-job-drools-modal" class="cc-modal-overlay cc-hidden" data-action-click="aai-job-close-modal" data-aai-modal-id="aai-job-drools-modal">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Refresh Drools</h3>
                <button class="cc-dialog-close" data-action-click="aai-job-close-modal" data-aai-modal-id="aai-job-drools-modal">&times;</button>
            </div>
            <div class="cc-dialog-body" id="aai-job-drools-modal-body"></div>
            <div class="cc-dialog-actions" id="aai-job-drools-modal-actions"></div>
        </div>
    </div>

    <div id="aai-job-release-modal" class="cc-modal-overlay cc-hidden" data-action-click="aai-job-close-modal" data-aai-modal-id="aai-job-release-modal">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Release Notices</h3>
                <button class="cc-dialog-close" data-action-click="aai-job-close-modal" data-aai-modal-id="aai-job-release-modal">&times;</button>
            </div>
            <div class="cc-dialog-body" id="aai-job-release-modal-body"></div>
            <div class="cc-dialog-actions" id="aai-job-release-modal-actions"></div>
        </div>
    </div>

    <div id="aai-job-balance-modal" class="cc-modal-overlay cc-hidden" data-action-click="aai-job-close-modal" data-aai-modal-id="aai-job-balance-modal">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Balance Sync</h3>
                <button class="cc-dialog-close" data-action-click="aai-job-close-modal" data-aai-modal-id="aai-job-balance-modal">&times;</button>
            </div>
            <div class="cc-dialog-body" id="aai-job-balance-modal-body"></div>
            <div class="cc-dialog-actions" id="aai-job-balance-modal-actions"></div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
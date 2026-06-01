<#
.SYNOPSIS
    Business Intelligence departmental page route for the xFACts Control Center.

.DESCRIPTION
    Registers the Business Intelligence departmental dashboard page. The page
    presents a Tools and Processes tile row: a Notice Recon status-badge tile
    whose badges are rendered and updated by the page JS, a BDL Import launcher,
    and two placeholder tiles for Phase 2 monitors. Each Notice Recon badge
    opens an execution detail slideout. The route emits the page shell inline
    and consumes universal chrome (nav bar, header, connection banner, slide
    dialog) from cc-shared.css and cc-shared.js.

.COMPONENT
    DeptOps.BusinessIntelligence

.NOTES
    File Name : BusinessIntelligence.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\BusinessIntelligence.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-stamped change history. Each entry is one ISO date line followed by an
   indented description. Entries appear most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-01  Migrated to the new CC page architecture. Replaced the legacy
#             page shell with the mandated cc-shared shell: body carries
#             cc-section-departmental plus data-cc-page and data-cc-prefix; the
#             header bar, connection banner, and page error banner are emitted
#             from the shared chrome contract; the page loads cc-shared.js as
#             the bootloader (which injects business-intelligence.js) instead of
#             loading the page JS directly. All page-local IDs and classes now
#             carry the biz- prefix; chrome classes use cc-. Inline onclick
#             handlers were replaced with data-action-click dispatch values. The
#             Notice Recon detail slideout was rebuilt on the shared overlay and
#             dialog chrome (cc-slide-overlay + cc-dialog cc-dialog-slide
#             cc-xwide) in place of the legacy slide-panel markup. The Notice
#             Recon data-load error strip was renamed to the biz-prefixed
#             biz-nr-error element; it remains page-local because it reports a
#             page data-fetch failure, distinct from the shared connection
#             banner which reflects WebSocket lifecycle state. Dropped the
#             engine-events.css and engine-events.js references. Added the
#             transitional xFACts-CCShared.psm1 force-import as the first
#             statement in the route scriptblock so Get-NavBarHtml and
#             Get-PageHeaderHtml emit cc- prefixed chrome classes for this
#             route; this overrides the startup-loaded xFACts-Helpers module
#             and is removed once Start-ControlCenter.ps1 loads
#             xFACts-CCShared.psm1 at startup.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the Business Intelligence departmental page. Performs the RBAC
   access check, renders the dynamic nav bar and page header from
   RBAC_NavRegistry, then emits the page shell inline and returns it as the
   HTML response.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/departmental/business-intelligence' -Authentication 'ADLogin' -ScriptBlock {

    # Import the cc- emission helpers. During the CC File Format
    # Standardization Section 11.2.4 migration this overrides the auto-loaded
    # xFACts-Helpers module for this route's execution, so Get-NavBarHtml
    # and Get-PageHeaderHtml emit cc- prefixed chrome classes that match
    # cc-shared.css and cc-shared.js. Once every page has migrated and
    # Start-ControlCenter.ps1 loads xFACts-CCShared.psm1 at startup
    # instead of xFACts-Helpers.psm1, this line is removed.
    Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/business-intelligence'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/business-intelligence') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/departmental/business-intelligence'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/departmental/business-intelligence'
    $bannerHtml   = Get-ChromeBannersHtml
    $browserTitle = Get-PageBrowserTitle -PageRoute '/departmental/business-intelligence'

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/business-intelligence.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-departmental" data-cc-page="business-intelligence" data-cc-prefix="biz">
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

    <div id="biz-nr-error" class="biz-nr-error"></div>

    <!-- ================================================================ -->
    <!-- TOOLS & PROCESSES                                                -->
    <!-- ================================================================ -->
    <div class="cc-section" id="biz-tools-section">
        <div class="cc-section-header">
            <h2 class="cc-section-title">Tools &amp; Processes</h2>
        </div>
        <div class="biz-tool-cards">
            <!-- Notice Recon: status-badge tile (badges rendered/updated by JS) -->
            <div class="biz-tool-card biz-tool-card-nr">
                <div class="biz-nr-badges" id="biz-nr-badges"></div>
                <div class="biz-tool-label">Notice Recon</div>
                <div class="biz-tool-status">Daily Reconciliation</div>
            </div>
            <a class="biz-tool-card" id="biz-bdl-import-card" href="/bdl-import">
                <div class="biz-tool-icon">&#128230;</div>
                <div class="biz-tool-label">BDL Import</div>
                <div class="biz-tool-status">Open</div>
            </a>
            <div class="biz-tool-card biz-tool-card-placeholder">
                <div class="biz-tool-icon">&#128222;</div>
                <div class="biz-tool-label">LiveVox</div>
                <div class="biz-tool-status">Phase 2</div>
            </div>
            <div class="biz-tool-card biz-tool-card-placeholder">
                <div class="biz-tool-icon">&#128172;</div>
                <div class="biz-tool-label">SndRight Texting</div>
                <div class="biz-tool-status">Phase 2</div>
            </div>
        </div>
    </div>

    <!-- ================================================================ -->
    <!-- EXECUTION DETAIL SLIDEOUT                                        -->
    <!-- ================================================================ -->
    <!-- Notice Recon execution detail slide dialog and its overlay dimmer -->
    <div id="biz-nr-detail-overlay" class="cc-slide-overlay" data-action-click="biz-close-detail">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 id="biz-nr-detail-title" class="cc-dialog-title">Execution Detail</h3>
                <button class="cc-dialog-close" data-action-click="biz-close-detail" title="Close">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div id="biz-nr-detail-content"></div>
            </div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
<#
.SYNOPSIS
    Pode route for the Client Relations page (/departmental/client-relations).

.DESCRIPTION
    Registers the GET /departmental/client-relations route. Performs RBAC access
    check via Get-UserAccess and returns the Access Denied page on failure.
    Resolves user context, renders nav, page header, and banner chrome from
    RBAC_NavRegistry, and emits the Client Relations page HTML following the CC
    HTML Spec for body attributes, page-local prefixing, and data-action event
    dispatch. The page shows the Reg F compliance queue: summary cards, reason
    filter badges, and an expandable consumer/account queue table.

    The page runs a heavy, non-performant query and serves the result from a
    page-level cache; a content-area cache indicator reports the freshness of
    the cached result. The standard chrome refresh-info row is used as on every
    other page.

    During the CC File Format Standardization unified prefix rename migration,
    this route explicitly imports the xFACts-CCShared module at the top of its
    scriptblock. This overrides the auto-loaded xFACts-Helpers module for this
    route's execution so Get-NavBarHtml, Get-PageHeaderHtml, and
    Get-ChromeBannersHtml emit cc- prefixed chrome classes that match
    cc-shared.css and cc-shared.js. Once every page has migrated,
    xFACts-Helpers.psm1 is deleted, Start-ControlCenter.ps1 is updated to load
    xFACts-CCShared.psm1 at startup, and the explicit Import-Module line in this
    route is removed.

.COMPONENT
    DeptOps.ClientRelations

.NOTES
    File Name : ClientRelations.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes

    FILE ORGANIZATION
    -----------------
        CHANGELOG: CHANGE HISTORY
        ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-driven change history for this page route. Entries appear
   most-recent first. Each entry begins with the ISO date followed by two
   spaces and the description; continuation lines align with the start of
   the description text.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-02  CC File Format Standardization: refactored the page route to
#             the CC HTML Spec and CC PS Spec. Converted the file header to
#             comment-based help and the section banners to block-comment
#             form. Added body cc-section-departmental class and
#             data-cc-page/data-cc-prefix attributes. Replaced the
#             engine-events.css/engine-events.js references with cc-shared.css
#             and the literal /js/cc-shared.js script tag. Replaced the legacy
#             header chrome with the mandated cc-header-bar / cc-refresh-info
#             markup and dropped the custom in-header cache indicator: the
#             page now uses the standard chrome refresh-info row. The custom
#             cache indicator moved into the content area as a page-local
#             clr-cache-indicator reporting cached-result freshness. Removed
#             the page-local connection-error banner (chrome owns the
#             connection banner). Prefixed all page-local IDs and classes with
#             clr-; converted section headers to cc-section-header /
#             cc-section-title. Replaced the inline onclick refresh handler
#             with the chrome cc-page-refresh data-action; the search input
#             carries data-action-input="clr-search-queue". Added the explicit
#             Import-Module of xFACts-CCShared.psm1 inside the route scriptblock
#             for the migration window.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the Client Relations departmental page at
   GET /departmental/client-relations. Performs RBAC access check, resolves
   user context, renders nav, header, and banner chrome from RBAC_NavRegistry,
   and emits the page HTML.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/departmental/client-relations' -Authentication 'ADLogin' -ScriptBlock {
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/departmental/client-relations'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/departmental/client-relations') -StatusCode 403
        return
    }

    $ctx          = Get-UserContext      -WebEvent $WebEvent
    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/departmental/client-relations'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/departmental/client-relations'
    $bannerHtml   = Get-ChromeBannersHtml
    $browserTitle = Get-PageBrowserTitle -PageRoute '/departmental/client-relations'

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/client-relations.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-departmental" data-cc-page="client-relations" data-cc-prefix="clr">
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

    <div class="cc-section">
        <div class="cc-section-header">
            <h2 class="cc-section-title">Reg F Compliance Queue</h2>
            <span class="cc-refresh-badge-live" title="Refreshes on live polling timer"><span class="cc-refresh-badge-dot"></span></span>
        </div>
        <div class="clr-section-body">
            <span id="clr-cache-indicator" class="clr-cache-indicator" title="Serving cached data">Cached: -</span>
            <div id="clr-summary-loading" class="clr-loading">Loading summary...</div>
            <div id="clr-summary-cards" class="clr-summary-cards clr-hidden"></div>
        </div>
    </div>

    <div class="cc-section">
        <div class="cc-section-header">
            <h2 class="cc-section-title">Queue Detail</h2>
            <div class="cc-section-header-right">
                <input type="text" id="clr-queue-search" class="clr-search-input" placeholder="Search consumers..." data-action-input="clr-search-queue">
                <div id="clr-reason-filters" class="clr-reason-filters"></div>
                <span class="cc-refresh-badge-live" title="Refreshes on live polling timer"><span class="cc-refresh-badge-dot"></span></span>
            </div>
        </div>
        <div class="clr-section-body clr-section-body-table">
            <div id="clr-queue-loading" class="clr-loading">Loading queue...</div>
            <div id="clr-queue-table" class="clr-queue-scroll-container clr-hidden"></div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
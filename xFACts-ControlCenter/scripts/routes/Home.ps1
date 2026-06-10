<#
.SYNOPSIS
    Control Center landing page route.

.DESCRIPTION
    Registers the post-login landing page at route '/'. Renders the dynamic
    navigation tile grid from the user's permitted RBAC_NavRegistry sections,
    a top user bar with sign-out, an optional admin gear, and a status bar.
    Dept-only users with no landing-page access are redirected to their
    department page.

.COMPONENT
    ControlCenter.Home

.NOTES
    File Name : Home.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\Home.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Date-stamped change history, most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-09  Converted to CC file-format spec. Moved page styling out of the
#             inline <style> block into home.css; re-prefixed all page-local
#             classes to the hom- page prefix; switched the tile accent class
#             to the array-join pattern; reordered the scriptblock so
#             Get-UserAccess is the first statement. Landing-page chrome
#             carve-out (HTML spec 1.5) applies: no nav/header/banner chrome,
#             no shared CSS/JS references.
# 2026-04-29  Phase 3 of dynamic nav: replaced hardcoded section/tile HTML
#             with a loop over Get-HomePageSections. Section headers and tile
#             accents now driven by RBAC_NavSection / RBAC_NavRegistry.
#             Dept-only redirect logic preserved.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   The landing page route at '/'. Resolves access first, redirects dept-only
   users with no landing access to their department page, then renders the
   permitted navigation tile grid.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/' -Authentication 'ADLogin' -ScriptBlock {
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/'

    if (-not $access.HasAccess -and $access.IsDeptOnly -and $access.DepartmentScopes.Count -gt 0) {
        $deptKey = $access.DepartmentScopes[0]
        $deptPages = Invoke-XFActsQuery -Query @"
    SELECT page_route
    FROM dbo.RBAC_DepartmentRegistry
    WHERE department_key = @key
      AND is_active = 1
"@ -Parameters @{ key = $deptKey }
        if ($deptPages -and $deptPages.Count -gt 0) {
            Move-PodeResponseUrl -Url $deptPages[0].page_route
            return
        }
    }

    $ctx = Get-UserContext -WebEvent $WebEvent
    $displayName = if ($ctx.DisplayName) { $ctx.DisplayName } else { $ctx.Username }

    $adminGear = if ($ctx.IsAdmin) {
        '<a href="/admin" class="hom-admin-gear" title="Administration">&#9881;</a>'
    } else { '' }

    $sections = Get-HomePageSections -UserContext $ctx

    $sectionsHtml = ''
    $isFirstSection = $true
    foreach ($section in $sections) {
        $headerClasses = @('hom-section-header')
        if (-not $isFirstSection) { $headerClasses += 'hom-section-spaced' }
        $headerClass = ($headerClasses -join ' ')
        $isFirstSection = $false

        $sectionLabel = [System.Net.WebUtility]::HtmlEncode($section.SectionLabel)
        $sectionsHtml += @"

        <div class="$headerClass">$sectionLabel</div>
        <div class="hom-nav-grid">

"@

        foreach ($page in $section.Pages) {
            $title = [System.Net.WebUtility]::HtmlEncode($page.DisplayTitle)
            $description = if ($page.Description) { [System.Net.WebUtility]::HtmlEncode($page.Description) } else { '' }

            $cardClasses = @('hom-nav-card')
            if ($section.AccentClass) { $cardClasses += "hom-$($section.AccentClass)" }
            $cardClass = ($cardClasses -join ' ')

            $titleClasses = @('hom-nav-card-title')
            if ($section.AccentClass) { $titleClasses += "hom-$($section.AccentClass)" }
            $titleClass = ($titleClasses -join ' ')

            $sectionsHtml += @"
            <a href="$($page.Route)" class="$cardClass">
                <h3 class="$titleClass">$title</h3>
                <p class="hom-nav-card-desc">$description</p>
            </a>

"@
        }

        $sectionsHtml += @"
        </div>

"@
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>xFACts Control Center</title>
    <link rel="stylesheet" href="/css/home.css">
    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body>
    <div class="hom-user-bar">
        <div class="hom-user-info">Signed in as <span class="hom-user-name">$displayName</span></div>
        <div class="hom-user-bar-right">
            $adminGear
            <a href="/logout" class="hom-logout-link">Sign Out</a>
        </div>
    </div>

    <div class="hom-main-content">
        <h1><a href="/docs/pages/index.html" target="_blank" class="hom-page-title-link">xFACts Control Center</a></h1>
        <p class="hom-subtitle">Enterprise IT Operations Platform</p>
        $sectionsHtml
    </div>

    <div class="hom-status-bar">
        xFACts Control Center | Port 8085 | Connected to AVG-PROD-LSNR
    </div>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
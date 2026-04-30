# ============================================================================
# xFACts Control Center - Engine Events API (Shared Endpoints)
# Location: E:\xFACts-ControlCenter\scripts\routes\engine-events-API.ps1
#
# Purpose
# -------
# This file is the home for shared Control Center API endpoints that don't
# belong to any single page. It follows the established "engine-events"
# naming convention used throughout the platform for ControlCenter.Shared
# infrastructure:
#
#   engine-events.css   - Shared CSS (nav-bar, refresh badges, modals, ...)
#   engine-events.js    - Shared JS  (engine card updates, modals, idle, ...)
#   engine-events-API.ps1 - Shared API endpoints (this file)
#
# Any future cross-page API endpoint that doesn't naturally belong to a
# single page's API file should be added here. Examples of what would
# belong here: nav registry lookups, idle/session helpers, shared label
# resolvers, anything reusable by 2+ pages.
#
# Component: ControlCenter.Shared
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.Shared)
#
# Endpoints
# ---------
# GET /api/nav-registry/label?route=<path>
#   Returns the human-readable display title for a CC route, but only if
#   the requesting user has access to it. Returns 404 in all other cases
#   (route not found, user lacks access, route hidden from this user's
#   tier, etc.). The endpoint does double duty as a "is this a place I
#   can go?" check, used by the Back-link feature on tool pages.
#
#   Response 200: { "label": "<display_title>" }
#   Response 404: { "error": "Not found or no access" }
#
# CHANGELOG
# ---------
# 2026-04-29  Initial creation. Phase 3d back-link feature for BDLImport
#             and PlatformMonitoring pages depends on this endpoint.
# ============================================================================

Add-PodeRoute -Method Get -Path '/api/nav-registry/label' -Authentication 'ADLogin' -ScriptBlock {

    # --- Validate query parameter ---
    $route = $WebEvent.Query['route']
    if ([string]::IsNullOrWhiteSpace($route)) {
        Write-PodeJsonResponse -Value @{ error = 'Missing required query parameter: route' } -StatusCode 400
        return
    }

    # --- Verify the requesting user has access to the requested route ---
    # Get-UserAccess returns HasAccess=$false for unknown routes too, so a
    # single check covers both "doesn't exist" and "user lacks access".
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute $route
    if (-not $access.HasAccess) {
        Write-PodeJsonResponse -Value @{ error = 'Not found or no access' } -StatusCode 404
        return
    }

    # --- Look up the display label from RBAC_NavRegistry ---
    $sql = @"
SELECT TOP 1 display_title
FROM dbo.RBAC_NavRegistry
WHERE page_route = @route
  AND is_active = 1
"@

    try {
        $result = Get-SqlData -ServerInstance 'AVG-PROD-LSNR' -Database 'xFACts' `
                              -Query $sql `
                              -Parameters @{ route = $route } `
                              -ApplicationName 'xFACts.CC.NavRegistryLabel'

        if (-not $result -or -not $result.display_title) {
            Write-PodeJsonResponse -Value @{ error = 'Not found or no access' } -StatusCode 404
            return
        }

        Write-PodeJsonResponse -Value @{ label = $result.display_title }
    }
    catch {
        Write-PodeJsonResponse -Value @{ error = 'Lookup failed' } -StatusCode 500
    }
}
# ============================================================================
# xFACts Control Center - JBoss Monitoring Page
# Location: E:\xFACts-ControlCenter\scripts\routes\JBossMonitoring.ps1
#
# Renders the JBoss Monitoring dashboard page.
# Three-column layout for side-by-side application server visibility.
#
# CSS: /css/jboss-monitoring.css
# JS:  /js/jboss-monitoring.js
# APIs: JBossMonitoring-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: JBoss)
#
# CHANGELOG
# ---------
# 2026-04-29  Phase 3 of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Nav now renders from RBAC_NavRegistry
#             with per-user permission filtering, section-based grouping,
#             and admin gear handled by the helper.
# 2026-03-18  Renamed from DmMonitoring.ps1. Route /dm-monitoring -> /jboss-monitoring.
#             CSS/JS references updated. Page title -> JBoss Monitoring.
# 2026-03-08  Phase 3: Added info modal, section-level ? icon.
#             Removed queue slideout (replaced by inline accordion in JS).
# 2026-03-08  Phase 2: Replaced lower section placeholder with queue slideout panel
# 2026-03-08  Added "Users" badge, server switch modal, confirm dialog,
#             isAdmin context injection (migrated from Admin page)
# 2026-03-07  Initial implementation
# ============================================================================

Add-PodeRoute -Method Get -Path '/jboss-monitoring' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/jboss-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/jboss-monitoring') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering and isAdmin flag) ---
    $ctx = Get-UserContext -WebEvent $WebEvent

    # --- Render dynamic nav bar ---
    $navHtml = Get-NavBarHtml -UserContext $ctx -CurrentPageRoute '/jboss-monitoring'

    $html = @"

<!DOCTYPE html>
<html>
<head>
    <title>JBoss Monitoring - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/jboss-monitoring.css">
    <link rel="stylesheet" href="/css/engine-events.css">
</head>
<body>
$navHtml

    <!-- Header Bar -->
    <div class="header-bar">
        <div>
            <h1><a href="/docs/pages/jboss.html" target="_blank">JBoss Monitoring</a></h1>
            <p class="page-subtitle">JBoss application server health, responsiveness, and management metrics</p>
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span class="live-indicator"></span>
                <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
            <div class="engine-row">
                <div class="engine-card" id="card-engine-jboss">
                    <span class="engine-label">JBOSS</span>
                    <div class="engine-bar disabled" id="engine-bar-jboss"></div>
                    <span class="engine-countdown" id="engine-cd-jboss">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>

    <div id="connection-error" class="connection-error"></div>

    <!-- ================================================================
         SERVER CARDS - Three Column Layout
         ================================================================ -->
    <div class="section">
        <div class="section-header">
            <h3 class="section-title">Application Servers <span class="section-info-icon" onclick="showInfo('overview')">?</span></h3>
            <div class="section-header-right">
                <span class="refresh-badge-event" title="Updates when Health collector completes">&#9889;</span>
            </div>
        </div>
        <div class="server-grid" id="server-grid">
            <!-- Cards rendered by JS -->
            <div class="server-card" id="server-card-0">
                <div class="server-card-header">
                    <span class="server-name" id="server-name-0">Loading...</span>
                    <span class="server-role" id="server-role-0"></span>
                </div>
                <div class="server-card-body" id="server-body-0">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            <div class="server-card" id="server-card-1">
                <div class="server-card-header">
                    <span class="server-name" id="server-name-1">Loading...</span>
                    <span class="server-role" id="server-role-1"></span>
                </div>
                <div class="server-card-body" id="server-body-1">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            <div class="server-card" id="server-card-2">
                <div class="server-card-header">
                    <span class="server-name" id="server-name-2">Loading...</span>
                    <span class="server-role" id="server-role-2"></span>
                </div>
                <div class="server-card-body" id="server-body-2">
                    <div class="loading">Loading...</div>
                </div>
            </div>
        </div>
    </div>

    <!-- ================================================================
         INFO MODAL
         ================================================================ -->
    <div class="info-modal-overlay" id="info-modal-overlay" onclick="closeInfoModal(event)">
        <div class="info-modal">
            <div class="info-modal-header">
                <h3 id="info-modal-title">-</h3>
                <button class="info-modal-close" onclick="closeInfoModal()">&times;</button>
            </div>
            <div class="info-modal-body" id="info-modal-body"></div>
        </div>
    </div>

    <!-- ================================================================
         SERVER SWITCH MODAL
         ================================================================ -->
    <div class="dm-modal-overlay" id="dm-modal-overlay" onclick="closeSwitchModal()"></div>
    <div class="dm-modal" id="dm-modal">
        <div class="dm-modal-header">
            <h3 class="dm-modal-title">DM Application Server</h3>
            <button class="dm-modal-close" onclick="closeSwitchModal()">&times;</button>
        </div>
        <div class="dm-modal-subtitle">SharePoint navigation link target</div>
        <div class="dm-server-grid" id="dm-server-grid">
            <button class="dm-server-btn" data-server="DM-PROD-APP" onclick="selectServer('DM-PROD-APP')">
                <div class="dm-server-name">APP</div>
                <div class="dm-server-host">dm-prod-app</div>
            </button>
            <button class="dm-server-btn" data-server="DM-PROD-APP2" onclick="selectServer('DM-PROD-APP2')">
                <div class="dm-server-name">APP2</div>
                <div class="dm-server-host">dm-prod-app2</div>
            </button>
            <button class="dm-server-btn" data-server="DM-PROD-APP3" onclick="selectServer('DM-PROD-APP3')">
                <div class="dm-server-name">APP3</div>
                <div class="dm-server-host">dm-prod-app3</div>
            </button>
        </div>
        <div class="dm-status" id="dm-status"></div>
    </div>

    <!-- ================================================================
         CONFIRM DIALOG
         ================================================================ -->
    <div class="confirm-overlay" id="confirm-overlay">
        <div class="confirm-dialog">
            <h3 id="confirm-title">Confirm</h3>
            <p id="confirm-message">Are you sure?</p>
            <div class="confirm-buttons">
                <button class="confirm-btn cancel" onclick="cancelConfirm()">Cancel</button>
                <button class="confirm-btn action" id="confirm-btn" onclick="executeConfirm()">Confirm</button>
            </div>
        </div>
    </div>

    <!-- Admin context for conditional UI -->
    <script>window.isAdmin = __IS_ADMIN__;</script>

    <script src="/js/jboss-monitoring.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>

"@
    $html = $html.Replace('__IS_ADMIN__', $(if ($ctx.IsAdmin) { 'true' } else { 'false' }))
    Write-PodeHtmlResponse -Value $html
}
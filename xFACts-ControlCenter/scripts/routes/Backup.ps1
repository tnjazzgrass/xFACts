# ============================================================================
# xFACts Control Center - Backup Monitoring Page
# Location: E:\xFACts-ControlCenter\scripts\routes\Backup.ps1
#
# Renders the Backup Monitoring dashboard page.
# CSS: /css/backup.css
# JS:  /js/backup.js
# APIs: Backup-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: ServerOps.Backup)
#
# CHANGELOG
# ---------
# 2026-04-30  Phase 4 (Chrome Standardization): added body section class
#             (section-platform) so H1 color is driven by shared CSS via
#             RBAC_NavRegistry section_key. Renamed connection banner
#             placeholder from id/class connection-error to connection-banner
#             matching the engine-events.js rename. No content changes.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle.
# ============================================================================

Add-PodeRoute -Method Get -Path '/backup' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/backup'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/backup') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering) ---
    $ctx = Get-UserContext -WebEvent $WebEvent

    # --- Render dynamic nav bar and page header from RBAC_NavRegistry ---
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/backup'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/backup'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/backup'

    $html = @"

<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/backup.css">
    <link rel="stylesheet" href="/css/engine-events.css">
</head>
<body class="section-platform">
$navHtml

    <div class="header-bar">
        <div>
            $headerHtml
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span class="live-indicator"></span>
                <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
            <div class="engine-row">
                <div class="engine-card" id="card-engine-collection">
                    <span class="engine-label">Backup</span>
                    <div class="engine-bar disabled" id="engine-bar-collection"></div>
                    <span class="engine-countdown" id="engine-cd-collection">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-networkcopy">
                    <span class="engine-label">Network</span>
                    <div class="engine-bar disabled" id="engine-bar-networkcopy"></div>
                    <span class="engine-countdown" id="engine-cd-networkcopy">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-awsupload">
                    <span class="engine-label">AWS</span>
                    <div class="engine-bar disabled" id="engine-bar-awsupload"></div>
                    <span class="engine-countdown" id="engine-cd-awsupload">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-retention">
                    <span class="engine-label">Retention</span>
                    <div class="engine-bar disabled" id="engine-bar-retention"></div>
                    <span class="engine-countdown" id="engine-cd-retention">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>

    <div id="connection-banner" class="connection-banner"></div>

    <!-- Two Column Layout -->
    <div class="two-column-layout">

        <!-- Left Column: Pipeline + Active Operations -->
        <div class="left-column">

            <!-- Pipeline Status -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Pipeline Status</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="pipeline-status" class="pipeline-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>

            <!-- Active Operations -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Active Operations</h2>
                    <div class="section-header-right">
                        <span class="refresh-badge-live" id="badge-live-active" title="Refreshes on live interval">
                            <span class="badge-dot"></span>
                        </span>
                    </div>
                </div>
                <div id="active-operations" class="active-operations-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>

        </div>

        <!-- Right Column: Queue/Retention side by side + Storage full width -->
        <div class="right-column">

            <!-- Queue + Retention Row -->
            <div class="side-by-side-row">
                <!-- Queue Status -->
                <div class="section half-section">
                    <div class="section-header">
                        <h2 class="section-title">Queue Status</h2>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                    <div id="queue-status" class="card-row">
                        <div class="loading">Loading...</div>
                    </div>
                </div>

                <!-- Retention Status -->
                <div class="section half-section">
                    <div class="section-header">
                        <h2 class="section-title">Retention Status</h2>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                    <div id="retention-status" class="card-row">
                        <div class="loading">Loading...</div>
                    </div>
                </div>
            </div>

            <!-- Storage Status - Full Width -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Storage Status</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="storage-status" class="storage-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>

        </div>

    </div>

    <!-- Reusable Detail Modal (pipeline + queue) -->
    <div id="detail-modal" class="modal hidden" onclick="if(event.target === this) closeDetailModal()">
        <div class="modal-content" id="detail-modal-content">
            <div class="modal-header">
                <h3 id="detail-modal-title">Detail</h3>
                <button class="modal-close" onclick="closeDetailModal()">&times;</button>
            </div>
            <div class="modal-body" id="detail-modal-body">
                <div class="loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Local Retention Slideout -->
    <div id="local-retention-overlay" class="slide-panel-overlay" onclick="closeRetentionPanel('local')"></div>
    <div id="local-retention-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>&#128465; Local Retention Candidates</h3>
            <button class="modal-close" onclick="closeRetentionPanel('local')">&times;</button>
        </div>
        <div class="slide-panel-body" id="local-retention-body">
            <div class="loading">Loading...</div>
        </div>
    </div>

    <!-- Network Retention Slideout -->
    <div id="network-retention-overlay" class="slide-panel-overlay" onclick="closeRetentionPanel('network')"></div>
    <div id="network-retention-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>&#128465; Network Retention Candidates</h3>
            <button class="modal-close" onclick="closeRetentionPanel('network')">&times;</button>
        </div>
        <div class="slide-panel-body" id="network-retention-body">
            <div class="loading">Loading...</div>
        </div>
    </div>

    <script src="/js/backup.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>

"@
    Write-PodeHtmlResponse -Value $html
}
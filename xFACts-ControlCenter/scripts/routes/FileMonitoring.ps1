<#
.SYNOPSIS
    Control Center page route for File Monitoring.

.DESCRIPTION
    Registers the File Monitoring dashboard page route. Renders the SFTP file
    arrival tracking dashboard: a two-column layout with the daily monitor
    queue and status summary on the left and configuration cards plus
    detection history on the right. A slide-up management console, a day
    detail slideout, and two modals provide configuration and drill-down.

.COMPONENT
    FileOps

.NOTES
    File Name : FileMonitoring.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\FileMonitoring.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this page route.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-04  Rebuilt to the Control Center file format. Reworked the page
#             shell to the shared chrome (cc-section body class,
#             data-cc-page/data-cc-prefix, $navHtml/$headerHtml/$bannerHtml
#             substitutions, single engine card, single cc-shared.js script).
#             Converted all inline onclick handlers to data-action-click
#             attributes and prefixed every page-local id and class with flm-.
#             The day detail slideout, scheduled modal, and webhook modal are
#             the cc- overlay constructs; the slide-up management console
#             remains a page-local construct pending a shared slide-up dock.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1 link, title, subtitle, and
#             browser tab title now render from RBAC_NavRegistry via
#             Get-PageHeaderHtml and Get-PageBrowserTitle.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the GET /file-monitoring page route. Performs the RBAC access
   check, resolves the user context and chrome substitutions, then emits the
   page shell HTML via a here-string.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/file-monitoring' -Authentication 'ADLogin' -ScriptBlock {
    Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/file-monitoring'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/file-monitoring') -StatusCode 403
        return
    }

    $ctx          = Get-UserContext -WebEvent $WebEvent
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/file-monitoring'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/file-monitoring'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/file-monitoring'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/file-monitoring.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="file-monitoring" data-cc-prefix="flm">
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
                <div class="cc-card-engine" id="cc-card-engine-sftp">
                    <span class="cc-engine-label">SFTP</span>
                    <div class="cc-engine-bar" id="cc-engine-bar-sftp"></div>
                    <span class="cc-engine-cd" id="cc-engine-cd-sftp"></span>
                </div>
            </div>
        </div>
    </div>

    $bannerHtml

    <div class="flm-grid">

        <div class="flm-column">

            <div class="flm-section flm-section-compact">
                <div class="flm-section-header">
                    <h2 class="flm-section-title">Status</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div class="flm-status-cards" id="flm-status-cards">
                    <div class="flm-summary-card" id="flm-card-escalated">
                        <div class="flm-card-label">Escalated</div>
                        <div class="flm-card-value flm-zero" id="flm-val-escalated">0</div>
                    </div>
                    <div class="flm-summary-card" id="flm-card-monitoring">
                        <div class="flm-card-label">Monitoring</div>
                        <div class="flm-card-value flm-zero" id="flm-val-monitoring">0</div>
                    </div>
                    <div class="flm-summary-card" id="flm-card-detected">
                        <div class="flm-card-label">Detected</div>
                        <div class="flm-card-value flm-zero" id="flm-val-detected">0</div>
                    </div>
                </div>
            </div>

            <div class="flm-section">
                <div class="flm-section-header">
                    <h2 class="flm-section-title">Daily Queue</h2>
                    <div class="flm-section-header-right">
                        <button class="flm-sched-btn" data-action-click="flm-open-scheduled" title="View monitors scheduled for today that haven't started yet">
                            &#9202; Scheduled <span id="flm-sched-count-badge" class="flm-sched-badge cc-hidden">0</span>
                        </button>
                        <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>

                <div class="flm-queue-content">
                <table class="flm-monitor-table" id="flm-queue-table">
                    <thead>
                        <tr><th class="flm-monitor-table-th flm-col-status">Status</th><th class="flm-monitor-table-th flm-col-monitor">Monitor</th><th class="flm-monitor-table-th flm-col-time">Time</th><th class="flm-monitor-table-th flm-col-file">File</th></tr>
                    </thead>
                    <tbody id="flm-queue-body">
                        <tr><td colspan="4" class="flm-no-activity">Loading...</td></tr>
                    </tbody>
                </table>
                </div>
            </div>

        </div>

        <div class="flm-column">

            <div class="flm-config-card-row">
                <button class="flm-section flm-section-compact flm-config-card" data-action-click="flm-open-console" data-action-flm-face="monitors">
                    <div class="flm-section-header">
                        <h2 class="flm-section-title">Monitors</h2>
                        <span class="cc-refresh-badge-static" title="Loaded on page open">&#128204;</span>
                    </div>
                    <div class="flm-config-card-body">
                        <span class="flm-config-card-value" id="flm-monitor-count">-</span>
                        <span class="flm-config-card-label">File Monitors</span>
                    </div>
                </button>
                <button class="flm-section flm-section-compact flm-config-card" data-action-click="flm-open-console" data-action-flm-face="servers">
                    <div class="flm-section-header">
                        <h2 class="flm-section-title">Servers</h2>
                        <span class="cc-refresh-badge-static" title="Loaded on page open">&#128204;</span>
                    </div>
                    <div class="flm-config-card-body">
                        <span class="flm-config-card-value" id="flm-server-count">-</span>
                        <span class="flm-config-card-label">SFTP Servers</span>
                    </div>
                </button>
            </div>

            <div class="flm-section flm-section-history">
                <div class="flm-section-header">
                    <h2 class="flm-section-title">Detection History</h2>
                    <span class="cc-refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="flm-detection-history" class="flm-history-content">
                    <div class="flm-loading">Loading...</div>
                </div>
            </div>

        </div>

    </div>

    <!-- Purpose: slide-up management console with a flip card between the monitor and server faces -->
    <div id="flm-slideup-console" class="cc-slideup-overlay" data-action-click="flm-close-console">
        <div class="cc-dialog cc-dialog-slideup cc-full cc-h-tall">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="flm-console-face-title">Monitors</h3>
                <div class="cc-dialog-header-actions">
                    <button class="flm-console-flip-btn" id="flm-console-flip-btn" data-action-click="flm-flip-console" title="Flip to other side">&#x27F3;</button>
                    <button class="flm-btn-action" id="flm-console-add-btn" data-action-click="flm-add-monitor">+ Add Monitor</button>
                </div>
                <button class="cc-dialog-close" data-action-click="flm-close-console">&times;</button>
            </div>
            <div class="cc-dialog-body flm-console-body">
                <div class="flm-console-flip-card" id="flm-console-flip-card">
                    <div class="flm-console-flip-front" id="flm-console-monitors">
                        <div id="flm-monitor-list" class="flm-console-list">
                            <div class="flm-loading">Loading...</div>
                        </div>
                    </div>
                    <div class="flm-console-flip-back" id="flm-console-servers">
                        <div id="flm-server-list" class="flm-console-list">
                            <div class="flm-loading">Loading...</div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Purpose: day detail slideout showing the detection events for a selected date -->
    <div id="flm-slideout-day" class="cc-slide-overlay" data-action-click="flm-close-day">
        <div class="cc-dialog cc-dialog-slide cc-xwide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="flm-day-title">Detection Details</h3>
                <button class="cc-dialog-close" data-action-click="flm-close-day">&times;</button>
            </div>
            <div class="cc-dialog-body" id="flm-day-body">
                <div class="flm-loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Purpose: modal listing monitors scheduled for today that have not yet started -->
    <div id="flm-modal-scheduled" class="cc-modal-overlay cc-hidden" data-action-click="flm-close-scheduled">
        <div class="cc-dialog cc-dialog-modal cc-medium">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Scheduled Monitors</h3>
                <button class="cc-dialog-close" data-action-click="flm-close-scheduled">&times;</button>
            </div>
            <div class="cc-dialog-body" id="flm-sched-modal-body">
                <div class="flm-loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Purpose: modal for creating a new Teams webhook from the monitor configuration row -->
    <div id="flm-modal-webhook" class="cc-modal-overlay cc-hidden" data-action-click="flm-close-webhook">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">New Webhook</h3>
                <button class="cc-dialog-close" data-action-click="flm-close-webhook">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="flm-modal-field">
                    <label class="flm-modal-label">Webhook Name</label>
                    <input type="text" id="flm-wh-new-name" class="flm-modal-input" placeholder="e.g., IFU Alerts">
                </div>
                <div class="flm-modal-field">
                    <label class="flm-modal-label">Webhook URL</label>
                    <input type="text" id="flm-wh-new-url" class="flm-modal-input" placeholder="https://...">
                </div>
                <div class="flm-modal-field">
                    <label class="flm-modal-label">Description</label>
                    <input type="text" id="flm-wh-new-desc" class="flm-modal-input" placeholder="Optional description">
                </div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="flm-close-webhook">Cancel</button>
                <button class="cc-dialog-btn-primary" data-action-click="flm-save-webhook">Create Webhook</button>
            </div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}
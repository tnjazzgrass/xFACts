# ============================================================================
# xFACts Control Center - File Monitoring Page
# Location: E:\xFACts-ControlCenter\scripts\routes\FileMonitoring.ps1
# 
# Renders the File Monitoring dashboard page for SFTP file arrival tracking.
# Two-column layout: Daily Queue (left), Status/Config/History (right).
# Slide-up management console with flip card for Monitors/Servers.
#
# CSS: /css/file-monitoring.css
# JS:  /js/file-monitoring.js
# APIs: FileMonitoring-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: FileOps)
# ============================================================================

   Add-PodeRoute -Method Get -Path '/file-monitoring' -Authentication 'ADLogin' -ScriptBlock {

       # --- RBAC Access Check ---
       $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/file-monitoring'
       if (-not $access.HasAccess) {
           Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/file-monitoring') -StatusCode 403
           return
       }

       # --- Admin gear icon (visible only to admin role holders) ---
       $ctx = Get-UserContext -WebEvent $WebEvent
       $adminGear = if ($ctx.IsAdmin) {
           '<span class="nav-spacer"></span><a href="/admin" class="nav-link nav-admin" title="Administration">&#9881;</a>'
       } else { '' }

       $html = @'

<!DOCTYPE html>
<html>
<head>
    <title>File Monitoring - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/file-monitoring.css">
    <link rel="stylesheet" href="/css/engine-events.css">
</head>
<body>
    <!-- Navigation Bar -->
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/server-health" class="nav-link">Server Health</a>
        <a href="/jobflow-monitoring" class="nav-link">Job/Flow Monitoring</a>
        <a href="/batch-monitoring" class="nav-link">Batch Monitoring</a>
        <a href="/backup" class="nav-link">Backup Monitoring</a>
        <a href="/index-maintenance" class="nav-link">Index Maintenance</a>
        <a href="/dbcc-operations" class="nav-link">DBCC Operations</a>
        <a href="/bidata-monitoring" class="nav-link">BIDATA Monitoring</a>
        <a href="/file-monitoring" class="nav-link active">File Monitoring</a>
        <a href="/replication-monitoring" class="nav-link">Replication Monitoring</a>
        <a href="/jboss-monitoring" class="nav-link">JBoss Monitoring</a>
        <a href="/dm-operations" class="nav-link">DM Operations</a>
        <span class="nav-separator">|</span>
        <a href="/departmental/business-services" class="nav-link">Business Services</a>
        <a href="/departmental/business-intelligence" class="nav-link">Business Intelligence</a>
        <a href="/departmental/client-relations" class="nav-link">Client Relations</a>
    </nav>
    
    <!-- Header Bar -->
    <div class="header-bar">
        <div>
            <h1><a href="/docs/pages/fileops.html" target="_blank">File Monitoring</a></h1>
            <p class="page-subtitle">SFTP file arrival tracking and escalation management</p>
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span class="live-indicator"></span>
                <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
            <div class="engine-row">
                <div class="engine-card" id="card-engine">
                    <span class="engine-label">SFTP</span>
                    <div class="engine-bar disabled" id="engine-bar"></div>
                    <span class="engine-countdown" id="engine-cd">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <!-- Two Column Layout -->
    <div class="grid-layout">
        
        <!-- Left Column: Status + Daily Queue -->
        <div class="grid-column">
            
            <!-- Status Section -->
            <div class="section section-compact">
                <div class="section-header">
                    <h2 class="section-title">Status</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div class="status-cards" id="status-cards">
                    <div class="summary-card" id="card-escalated">
                        <div class="card-label">Escalated</div>
                        <div class="card-value zero" id="val-escalated">0</div>
                    </div>
                    <div class="summary-card" id="card-monitoring">
                        <div class="card-label">Monitoring</div>
                        <div class="card-value zero" id="val-monitoring">0</div>
                    </div>
                    <div class="summary-card" id="card-detected">
                        <div class="card-label">Detected</div>
                        <div class="card-value zero" id="val-detected">0</div>
                    </div>
                </div>
            </div>
            
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Daily Queue</h2>
                    <div class="section-header-right">
                        <button class="sched-btn" onclick="openScheduledModal()" title="View monitors scheduled for today that haven't started yet">
                            &#9202; Scheduled <span id="sched-count-badge" class="sched-badge hidden">0</span>
                        </button>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                
                <!-- Scrollable queue container -->
                <div class="queue-content">
                <table class="monitor-table" id="queue-table">
                    <thead>
                        <tr><th class="col-status">Status</th><th class="col-monitor">Monitor</th><th class="col-time">Time</th><th class="col-file">File</th></tr>
                    </thead>
                    <tbody id="queue-body">
                        <tr><td colspan="4" class="no-activity">Loading...</td></tr>
                    </tbody>
                </table>
                </div>
            </div>
            
        </div>
        
        <!-- Right Column: Configuration, History -->
        <div class="grid-column">
            
            <!-- Configuration Cards -->
            <div class="config-card-row">
                <div class="section section-compact config-card" onclick="openConsole('monitors')">
                    <div class="section-header">
                        <h2 class="section-title">Monitors</h2>
                        <span class="refresh-badge-static" title="Loaded on page open">&#128204;</span>
                    </div>
                    <div class="config-card-body">
                        <span class="config-card-value" id="monitor-count">-</span>
                        <span class="config-card-label">File Monitors</span>
                    </div>
                </div>
                <div class="section section-compact config-card" onclick="openConsole('servers')">
                    <div class="section-header">
                        <h2 class="section-title">Servers</h2>
                        <span class="refresh-badge-static" title="Loaded on page open">&#128204;</span>
                    </div>
                    <div class="config-card-body">
                        <span class="config-card-value" id="server-count">-</span>
                        <span class="config-card-label">SFTP Servers</span>
                    </div>
                </div>
            </div>
            
            <!-- Detection History -->
            <div class="section section-history">
                <div class="section-header">
                    <h2 class="section-title">Detection History</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="detection-history" class="history-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
        </div>
        
    </div>
    
    <!-- ================================================================
         SLIDE-UP MANAGEMENT CONSOLE
         ================================================================ -->
    <div id="console-overlay" class="console-overlay" onclick="closeConsole()"></div>
    <div id="console-panel" class="console-panel">
        
        <!-- Console Title Bar -->
        <div class="console-title-bar">
            <div class="console-title-left">
                <h2 id="console-face-title">Monitors</h2>
                <button class="console-flip-btn" id="console-flip-btn" onclick="flipConsole()" title="Flip to other side">&#x27F3;</button>
            </div>
            <div class="console-title-right">
                <button class="btn-action" id="console-add-btn" onclick="addNewMonitor()">+ Add Monitor</button>
                <button class="console-close" onclick="closeConsole()">&times;</button>
            </div>
        </div>
        
        <!-- Console Body - Flip Card -->
        <div class="console-body">
            <div class="console-flip-card" id="console-flip-card">
                
                <!-- Front: Monitors -->
                <div class="console-flip-front" id="console-monitors">
                    <div id="monitor-list" class="console-list">
                        <div class="loading">Loading...</div>
                    </div>
                </div>
                
                <!-- Back: Servers -->
                <div class="console-flip-back" id="console-servers">
                    <div id="server-list" class="console-list">
                        <div class="loading">Loading...</div>
                    </div>
                </div>
                
            </div>
        </div>
        
    </div>
    
    <!-- Day Detail Slideout -->
    <div id="day-overlay" class="slideout-overlay" onclick="closeDayPanel()"></div>
    <div id="day-slideout" class="slideout">
        <div class="slideout-content">
            <div class="slideout-header">
                <h2 id="day-slideout-title">Detection Details</h2>
                <button class="slideout-close" onclick="closeDayPanel()">&times;</button>
            </div>
            <div class="slideout-body" id="day-body">
                <div class="loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- Scheduled Monitors Modal -->
    <div class="wh-modal-overlay" id="sched-modal-overlay" onclick="closeScheduledModal()">
        <div class="wh-modal sched-modal" onclick="event.stopPropagation()">
            <div class="wh-modal-header">
                <h3>Scheduled Monitors</h3>
                <button class="wh-modal-close" onclick="closeScheduledModal()">&times;</button>
            </div>
            <div class="sched-modal-body" id="sched-modal-body">
                <div class="loading">Loading...</div>
            </div>
        </div>
    </div>

    <!-- New Webhook Modal (must be last to ensure highest stacking) -->
    <div class="wh-modal-overlay" id="wh-modal-overlay" onclick="closeWebhookModal()">
        <div class="wh-modal" onclick="event.stopPropagation()">
            <div class="wh-modal-header">
                <h3>New Webhook</h3>
                <button class="wh-modal-close" onclick="closeWebhookModal()">&times;</button>
            </div>
            <div class="wh-modal-body">
                <div class="wh-modal-field">
                    <label>Webhook Name</label>
                    <input type="text" id="wh-new-name" class="wh-modal-input" placeholder="e.g., IFU Alerts">
                </div>
                <div class="wh-modal-field">
                    <label>Webhook URL</label>
                    <input type="text" id="wh-new-url" class="wh-modal-input" placeholder="https://...">
                </div>
                <div class="wh-modal-field">
                    <label>Description</label>
                    <input type="text" id="wh-new-desc" class="wh-modal-input" placeholder="Optional description">
                </div>
            </div>
            <div class="wh-modal-footer">
                <button class="btn btn-secondary" onclick="closeWebhookModal()">Cancel</button>
                <button class="btn btn-primary" onclick="saveNewWebhook()">Create Webhook</button>
            </div>
        </div>
    </div>

    <script src="/js/file-monitoring.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>
'@
    $html = $html.Replace('</nav>', "$adminGear</nav>")
    Write-PodeHtmlResponse -Value $html
}
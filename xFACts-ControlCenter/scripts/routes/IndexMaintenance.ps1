# ============================================================================
# xFACts Control Center - Index Maintenance Page
# Location: E:\xFACts-ControlCenter\scripts\routes\IndexMaintenance.ps1
# 
# Renders the Index Maintenance monitoring dashboard page.
# CSS: /css/index-maintenance.css
# JS:  /js/index-maintenance.js
# APIs: IndexMaintenance-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: ServerOps.Index)
# ============================================================================

   Add-PodeRoute -Method Get -Path '/index-maintenance' -Authentication 'ADLogin' -ScriptBlock {

       # --- RBAC Access Check ---
       $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/index-maintenance'
       if (-not $access.HasAccess) {
           Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/index-maintenance') -StatusCode 403
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
    <title>Index Maintenance - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/index-maintenance.css">
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
        <a href="/index-maintenance" class="nav-link active">Index Maintenance</a>
        <a href="/dbcc-operations" class="nav-link">DBCC Operations</a>
        <a href="/bidata-monitoring" class="nav-link">BIDATA Monitoring</a>
		<a href="/file-monitoring" class="nav-link">File Monitoring</a>
        <a href="/replication-monitoring" class="nav-link">Replication Monitoring</a>
        <a href="/jboss-monitoring" class="nav-link">JBoss Monitoring</a>
        <a href="/dm-operations" class="nav-link">DM Operations</a>
        <span class="nav-separator">|</span>
        <a href="/departmental/business-services" class="nav-link">Business Services</a>
        <a href="/departmental/business-intelligence" class="nav-link">Business Intelligence</a>
        <a href="/departmental/client-relations" class="nav-link">Client Relations</a>
    </nav>
    
    <div class="header-bar">
        <div>
            <h1><a href="/docs/pages/indexmaint.html" target="_blank">Index Maintenance</a></h1>
            <p class="page-subtitle">Process status, queue management, active rebuilds, database overview, schedule management</p>
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span class="live-indicator"></span>
                <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
            <div class="engine-row">
                <div class="engine-card" id="card-engine-sync">
                    <span class="engine-label">Sync</span>
                    <div class="engine-bar disabled" id="engine-bar-sync"></div>
                    <span class="engine-countdown" id="engine-cd-sync">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-scan">
                    <span class="engine-label">Scan</span>
                    <div class="engine-bar disabled" id="engine-bar-scan"></div>
                    <span class="engine-countdown" id="engine-cd-scan">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-execute">
                    <span class="engine-label">Execute</span>
                    <div class="engine-bar disabled" id="engine-bar-execute"></div>
                    <span class="engine-countdown" id="engine-cd-execute">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-stats">
                    <span class="engine-label">Stats</span>
                    <div class="engine-bar disabled" id="engine-bar-stats"></div>
                    <span class="engine-countdown" id="engine-cd-stats">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <!-- Two Column Layout -->
    <div class="two-column-layout">
        
        <!-- Left Column: Process Status + Index Queue + Active Execution -->
        <div class="left-column">
            
            <!-- Live Activity Widget -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Live Activity</h2>
                    <span class="refresh-badge-live" title="Refreshes on live interval"><span class="badge-dot"></span></span>
                </div>
                <div id="live-activity" class="live-activity-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Process Status Cards -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Process Status</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="process-status" class="process-cards">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Index Queue (formerly Queue Summary) -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Index Queue</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="queue-summary" class="queue-summary-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Active Execution (real-time rebuild progress) -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Active Execution</h2>
                    <span class="refresh-badge-live" title="Refreshes on live interval"><span class="badge-dot"></span></span>
                </div>
                <div id="active-execution" class="active-execution-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
        </div>
        
        <!-- Right Column: Database Overview -->
        <div class="right-column">
            
            <!-- Database Overview (formerly Database Health) -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Database Overview</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="database-health" class="database-health-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
        </div>
        
    </div>
    
    <script>window.isAdmin = __IS_ADMIN__;</script>
    <script src="/js/index-maintenance.js"></script>
    <script src="/js/engine-events.js"></script>
    
    <!-- Queue Details Slideout -->
    <div id="queue-overlay" class="slide-panel-overlay" onclick="closeQueuePanel()"></div>
    <div id="queue-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Queue Details</h3>
            <button class="modal-close" onclick="closeQueuePanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="queue-panel-body">
            <div class="loading">Loading...</div>
        </div>
    </div>
    
    <!-- SYNC Details Slideout -->
    <div id="sync-overlay" class="slide-panel-overlay" onclick="closeSyncPanel()"></div>
    <div id="sync-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Registry Sync - Last Run</h3>
            <button class="modal-close" onclick="closeSyncPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="sync-panel-body">
            <div class="loading">Loading...</div>
        </div>
    </div>
    
    <!-- SCAN Details Slideout -->
    <div id="scan-overlay" class="slide-panel-overlay" onclick="closeScanPanel()"></div>
    <div id="scan-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Fragmentation Scan - Last Run</h3>
            <button class="modal-close" onclick="closeScanPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="scan-panel-body">
            <div class="loading">Loading...</div>
        </div>
    </div>
    
    <!-- EXECUTE Details Slideout -->
    <div id="execute-overlay" class="slide-panel-overlay" onclick="closeExecutePanel()"></div>
    <div id="execute-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Index Maintenance - Last Run</h3>
            <button class="modal-close" onclick="closeExecutePanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="execute-panel-body">
            <div class="loading">Loading...</div>
        </div>
    </div>
    
    <!-- STATS Details Slideout -->
    <div id="stats-overlay" class="slide-panel-overlay" onclick="closeStatsPanel()"></div>
    <div id="stats-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Statistics Update - Last Run</h3>
            <button class="modal-close" onclick="closeStatsPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="stats-panel-body">
            <div class="loading">Loading...</div>
        </div>
    </div>
    
    <!-- Schedule Modal -->
    <div id="schedule-overlay" class="slide-panel-overlay" onclick="closeSchedulePanel()"></div>
    <div id="schedule-panel" class="slide-panel wide auto-height">
        <div class="slide-panel-header">
            <h3 id="schedule-panel-title">Maintenance Schedule</h3>
            <button class="modal-close" onclick="closeSchedulePanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="schedule-panel-body">
            <div class="loading">Loading...</div>
        </div>
    </div>
    
    <!-- Admin Launch Confirmation Modal -->
    <div id="launch-modal" class="launch-modal-overlay hidden" onclick="closeLaunchModal()">
        <div class="launch-modal-dialog" onclick="event.stopPropagation()">
            <div class="launch-modal-body" id="launch-modal-body"></div>
            <div class="launch-modal-footer" id="launch-modal-footer"></div>
        </div>
    </div>
</body>
</html>
'@
    $html = $html.Replace('</nav>', "$adminGear</nav>")
    $html = $html.Replace('__IS_ADMIN__', $(if ($ctx.IsAdmin) { 'true' } else { 'false' }))
    Write-PodeHtmlResponse -Value $html
}
# ============================================================================
# xFACts Control Center - DBCC Operations Page
# Location: E:\xFACts-ControlCenter\scripts\routes\DBCCOperations.ps1
# 
# Renders the DBCC Operations monitoring dashboard page.
# CSS: /css/dbcc-operations.css
# JS:  /js/dbcc-operations.js
# APIs: DBCCOperations-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: ServerOps.DBCC)
# ============================================================================

   Add-PodeRoute -Method Get -Path '/dbcc-operations' -Authentication 'ADLogin' -ScriptBlock {

       # --- RBAC Access Check ---
       $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/dbcc-operations'
       if (-not $access.HasAccess) {
           Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/dbcc-operations') -StatusCode 403
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
    <title>DBCC Operations - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/dbcc-operations.css">
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
        <a href="/dbcc-operations" class="nav-link active">DBCC Operations</a>
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
            <h1><a href="/docs/pages/dbcc.html" target="_blank">DBCC Operations</a></h1>
            <p class="page-subtitle">Live integrity check progress, execution history, schedule overview</p>
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span class="live-indicator"></span>
                <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
            <div class="engine-row">
                <div class="engine-card" id="card-engine-dbcc">
                    <span class="engine-label">DBCC</span>
                    <div class="engine-bar disabled" id="engine-bar-dbcc"></div>
                    <span class="engine-countdown" id="engine-cd-dbcc">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <!-- Two Column Layout -->
    <div class="two-column-layout">
        
        <!-- Left Column: Live Progress + Today's Executions -->
        <div class="left-column">
            
            <!-- Live Progress -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Live Progress</h2>
                    <span class="refresh-badge-live" title="Refreshes on live interval"><span class="badge-dot"></span></span>
                </div>
                <div id="live-progress" class="live-progress-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Today's Executions -->
            <div class="section section-fill">
                <div class="section-header">
                    <h2 class="section-title">Today's Executions</h2>
                    <div class="section-header-right">
                        <button id="btn-pending-queue" class="refresh-btn pending-btn" title="View pending queue" onclick="openPendingPanel()">
                            &#9202; Pending <span id="pending-count-badge" class="pending-badge hidden">0</span>
                        </button>
                        <span class="refresh-badge-live" title="Refreshes on live interval"><span class="badge-dot"></span></span>
                    </div>
                </div>
                <div id="todays-executions">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
        </div>
        
        <!-- Right Column: Schedule Overview + Execution History -->
        <div class="right-column">
            
            <!-- Schedule Overview (server list) -->
            <div class="section section-fixed-schedule">
                <div class="section-header">
                    <h2 class="section-title">Schedule Overview</h2>
                    <span class="refresh-badge-static" title="Loads once on page load">&#128204;</span>
                </div>
                <div id="schedule-overview">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Execution History (fills remaining height) -->
            <div class="section section-fill">
                <div class="section-header">
                    <h2 class="section-title">Execution History</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="execution-history">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
        </div>
        
    </div>
    
    <script>window.isAdmin = __IS_ADMIN__;</script>
    <script src="/js/dbcc-operations.js"></script>
    <script src="/js/engine-events.js"></script>
    
    <!-- Pending Queue Modal -->
    <div id="pending-modal-overlay" class="modal-overlay hidden" onclick="closePendingPanel()">
        <div class="modal-dialog" onclick="event.stopPropagation()">
            <div class="modal-header">
                <h3>Pending Queue</h3>
                <button class="modal-close" onclick="closePendingPanel()">&times;</button>
            </div>
            <div class="modal-body" id="pending-panel-body">
                <div class="loading">Loading...</div>
            </div>
        </div>
    </div>
    
    <!-- Schedule Detail Modal (server-level: view databases) -->
    <div id="schedule-modal-overlay" class="modal-overlay hidden" onclick="closeScheduleModal()">
        <div class="modal-dialog" onclick="event.stopPropagation()">
            <div class="modal-header">
                <h3 id="schedule-modal-title">Server Schedule</h3>
                <button class="modal-close" onclick="closeScheduleModal()">&times;</button>
            </div>
            <div class="modal-body" id="schedule-modal-body">
                <div class="loading">Loading...</div>
            </div>
        </div>
    </div>
    
    <!-- Schedule Edit Modal (database-level: edit operations) -->
    <div id="edit-modal-overlay" class="modal-overlay hidden" onclick="closeEditModal()">
        <div class="modal-dialog modal-narrow" onclick="event.stopPropagation()">
            <div class="modal-header">
                <h3 id="edit-modal-title">Edit Schedule</h3>
                <button class="modal-close" onclick="closeEditModal()">&times;</button>
            </div>
            <div class="modal-body" id="edit-modal-body">
                <div class="loading">Loading...</div>
            </div>
            <div class="modal-footer" id="edit-modal-footer"></div>
        </div>
    </div>
</body>
</html>
'@
    $html = $html.Replace('</nav>', "$adminGear</nav>")
    $html = $html.Replace('__IS_ADMIN__', $(if ($ctx.IsAdmin) { 'true' } else { 'false' }))
    Write-PodeHtmlResponse -Value $html
}
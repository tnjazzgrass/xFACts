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
# ============================================================================

   Add-PodeRoute -Method Get -Path '/backup' -Authentication 'ADLogin' -ScriptBlock {

       # --- RBAC Access Check ---
       $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/backup'
       if (-not $access.HasAccess) {
           Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/backup') -StatusCode 403
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
    <title>Backup Monitoring - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/backup.css">
    <link rel="stylesheet" href="/css/engine-events.css">
</head>
<body>
    <!-- Navigation Bar -->
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/server-health" class="nav-link">Server Health</a>
        <a href="/jobflow-monitoring" class="nav-link">Job/Flow Monitoring</a>
        <a href="/batch-monitoring" class="nav-link">Batch Monitoring</a>
        <a href="/backup" class="nav-link active">Backup Monitoring</a>
        <a href="/index-maintenance" class="nav-link">Index Maintenance</a>
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
            <h1><a href="/docs/pages/backup.html" target="_blank">Backup Monitoring</a></h1>
            <p class="page-subtitle">Backup pipeline status, active operations, queue/retention status, storage utilization</p>
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
    
    <div id="connection-error" class="connection-error"></div>
    
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
'@
    $html = $html.Replace('</nav>', "$adminGear</nav>")
    Write-PodeHtmlResponse -Value $html
}
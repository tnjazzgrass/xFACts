# ============================================================================
# xFACts Control Center - DM Operations Page
# Location: E:\xFACts-ControlCenter\scripts\routes\DmOperations.ps1
# 
# Renders the DM Operations monitoring dashboard page for the unified consumer
# archive and shell consumer purge processes.
# CSS: /css/dm-operations.css
# JS:  /js/dm-operations.js
# APIs: DmOperations-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: DmOps.Archive)
# ============================================================================

   Add-PodeRoute -Method Get -Path '/dm-operations' -Authentication 'ADLogin' -ScriptBlock {

       # --- RBAC Access Check ---
       $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/dm-operations'
       if (-not $access.HasAccess) {
           Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/dm-operations') -StatusCode 403
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
    <title>DM Operations - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/dm-operations.css">
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
        <a href="/file-monitoring" class="nav-link">File Monitoring</a>
        <a href="/replication-monitoring" class="nav-link">Replication Monitoring</a>
        <a href="/jboss-monitoring" class="nav-link">JBoss Monitoring</a>
        <a href="/dm-operations" class="nav-link active">DM Operations</a>
        <span class="nav-separator">|</span>
        <a href="/departmental/business-services" class="nav-link">Business Services</a>
        <a href="/departmental/business-intelligence" class="nav-link">Business Intelligence</a>
        <a href="/departmental/client-relations" class="nav-link">Client Relations</a>
    </nav>
    
    <div class="header-bar">
        <div>
            <h1><a href="/docs/pages/dmops.html" target="_blank">DM Operations</a></h1>
            <p class="page-subtitle">Consumer archiving, shell consumer purge, execution history, schedule management</p>
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span class="live-indicator"></span>
                <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
            <div class="engine-row">
                <div class="engine-card" id="card-engine-archive">
                    <span class="engine-label">Archive</span>
                    <div class="engine-bar disabled" id="engine-bar-archive"></div>
                    <span class="engine-countdown" id="engine-cd-archive">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-shellpurge">
                    <span class="engine-label">Shells</span>
                    <div class="engine-bar disabled" id="engine-bar-shellpurge"></div>
                    <span class="engine-countdown" id="engine-cd-shellpurge">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <!-- ================================================================ -->
    <!-- Lifetime Totals -->
    <!-- ================================================================ -->
    <div class="section">
        <div class="section-header">
            <h2 class="section-title">Lifetime Totals</h2>
            <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
        </div>
        <div class="summary-cards" id="lifetime-totals">
            <div class="loading">Loading...</div>
        </div>
    </div>
    
    <!-- ================================================================ -->
    <!-- Two Column Layout: Archive (left) + Shell Purge (right) -->
    <!-- ================================================================ -->
    <div class="two-column-layout">
        
        <!-- Left Column: Archive -->
        <div class="column">
            
            <!-- Archive Today -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Consumer Archive &mdash; Today</h2>
                    <div class="section-header-right">
                        <span class="target-server-badge env-unknown" id="archive-target-badge" title="Loading target server&hellip;">&hellip;</span>
                        <button class="action-btn schedule-btn" id="archive-schedule-btn" onclick="openScheduleModal('archive')" title="View/edit archive schedule" style="display:none;">&#128197; Schedule</button>
                        <button class="action-btn abort-btn" id="archive-abort-btn" onclick="toggleAbort('archive')" title="Emergency stop" style="display:none;">&#9632; Abort</button>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="archive-today">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Archive Execution History -->
            <div class="section section-fill">
                <div class="section-header">
                    <h2 class="section-title">Consumer Archive &mdash; History</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="archive-history">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
        </div>
        
        <!-- Right Column: Shell Purge -->
        <div class="column">
            
            <!-- Shell Purge Today -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Shell Purge &mdash; Today</h2>
                    <div class="section-header-right">
                        <span class="target-server-badge env-unknown" id="shellpurge-target-badge" title="Loading target server&hellip;">&hellip;</span>
                        <button class="action-btn schedule-btn" id="shellpurge-schedule-btn" onclick="openScheduleModal('shellpurge')" title="View/edit shell purge schedule" style="display:none;">&#128197; Schedule</button>
                        <button class="action-btn abort-btn" id="shellpurge-abort-btn" onclick="toggleAbort('shellpurge')" title="Emergency stop" style="display:none;">&#9632; Abort</button>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="shellpurge-today">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Shell Purge Execution History -->
            <div class="section section-fill">
                <div class="section-header">
                    <h2 class="section-title">Shell Purge &mdash; History</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="shellpurge-history">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
        </div>
        
    </div>
    
    <script>window.isAdmin = __IS_ADMIN__;</script>
    <script src="/js/dm-operations.js"></script>
    <script src="/js/engine-events.js"></script>
    
    <!-- Schedule Modal (shared for both Archive and Shell Purge) -->
    <div id="schedule-overlay" class="slide-panel-overlay" onclick="closeSchedulePanel()"></div>
    <div id="schedule-panel" class="slide-panel wide auto-height">
        <div class="slide-panel-header">
            <h3 id="schedule-panel-title">Schedule</h3>
            <button class="modal-close" onclick="closeSchedulePanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="schedule-panel-body">
            <div class="loading">Loading...</div>
        </div>
    </div>

    <!-- Batch Detail Slide-out (full Archive_BatchDetail / ShellPurge_BatchDetail rows) -->
    <div id="batch-detail-overlay" class="slide-panel-overlay" onclick="closeBatchDetailPanel()"></div>
    <div id="batch-detail-panel" class="slide-panel extra-wide">
        <div class="slide-panel-header">
            <h3 id="batch-detail-title">Batch Detail</h3>
            <button class="modal-close" onclick="closeBatchDetailPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="batch-detail-body">
            <div class="loading">Loading batch detail&hellip;</div>
        </div>
    </div>
</body>
</html>
'@
    $html = $html.Replace('</nav>', "$adminGear</nav>")
    $html = $html.Replace('__IS_ADMIN__', $(if ($ctx.IsAdmin) { 'true' } else { 'false' }))
    Write-PodeHtmlResponse -Value $html
}
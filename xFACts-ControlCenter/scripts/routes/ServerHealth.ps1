# ============================================================================
# xFACts Control Center - Server Health Page
# Location: E:\xFACts-ControlCenter\scripts\routes\ServerHealth.ps1
# 
# Renders the Server Health dashboard page.
# CSS: /css/server-health.css
# JS:  /js/server-health.js
# APIs: ServerHealth-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: ServerOps.ServerHealth)
# ============================================================================

   Add-PodeRoute -Method Get -Path '/server-health' -Authentication 'ADLogin' -ScriptBlock {

       # --- RBAC Access Check ---
       $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/server-health'
       if (-not $access.HasAccess) {
           Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/server-health') -StatusCode 403
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
    <title>Server Health - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/server-health.css">
    <link rel="stylesheet" href="/css/engine-events.css">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
</head>
<body>
    <!-- Navigation Bar -->
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/server-health" class="nav-link active">Server Health</a>
        <a href="/jobflow-monitoring" class="nav-link">Job/Flow Monitoring</a>
        <a href="/batch-monitoring" class="nav-link">Batch Monitoring</a>
        <a href="/backup" class="nav-link">Backup Monitoring</a>
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
        <div class="header-left">
            <h1><a href="/docs/pages/serverhealth.html" target="_blank">Server Health</a></h1>
            <p class="page-subtitle">Real-time SQL Server performance and health monitoring</p>
        </div>
        <div class="header-center">
            <div id="server-tabs" class="server-tabs">
                <span class="loading-inline">Loading servers...</span>
            </div>
        </div>
        <div class="header-right">
            <div class="refresh-info">
                <span class="live-indicator"></span>
                <span>Live</span> | Updated: <span id="last-update" class="last-updated">-</span>
                <button class="page-refresh-btn" onclick="pageRefresh()" title="Refresh all data">&#8635;</button>
            </div>
            <div class="engine-row">
                <div class="engine-card" id="card-engine-dmv">
                    <span class="engine-label">DMV</span>
                    <div class="engine-bar disabled" id="engine-bar-dmv"></div>
                    <span class="engine-countdown" id="engine-cd-dmv">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-xe">
                    <span class="engine-label">XE</span>
                    <div class="engine-bar disabled" id="engine-bar-xe"></div>
                    <span class="engine-countdown" id="engine-cd-xe">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-disk">
                    <span class="engine-label">Disk</span>
                    <div class="engine-bar disabled" id="engine-bar-disk"></div>
                    <span class="engine-countdown" id="engine-cd-disk">&nbsp;</span>
                </div>
                <div class="engine-card" id="card-engine-disksummary">
                    <span class="engine-label">Summary</span>
                    <div class="engine-bar disabled" id="engine-bar-disksummary"></div>
                    <span class="engine-countdown" id="engine-cd-disksummary">&nbsp;</span>
                </div>
            </div>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <div class="main-layout">
        <div class="metrics-column">
            <!-- Memory Section -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Memory</h2>
                    <span class="refresh-badge-live" title="Refreshes on live interval"><span class="badge-dot"></span></span>
                </div>
                <div id="memory-metrics" class="metrics-grid">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Connections Section -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Connections</h2>
                    <span class="refresh-badge-live" title="Refreshes on live interval"><span class="badge-dot"></span></span>
                </div>
                <div id="connection-metrics" class="metrics-grid">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Activity Section -->
            <div class="section">
                <div class="section-header">
                    <h2 class="section-title">Current Activity</h2>
                    <span class="refresh-badge-live" title="Refreshes on live interval"><span class="badge-dot"></span></span>
                </div>
                <div id="activity-metrics" class="metrics-grid">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Extended Events Activity Section -->
            <div class="section">
                <div class="section-header section-header-with-control">
                    <h2 class="section-title">Extended Events Activity</h2>
                    <div class="section-header-right">
                        <div class="time-window-control">
                            <span id="recent-activity-window">15</span>m
                            <button class="time-window-btn" onclick="openTimeWindowSelector()" title="Change time window">&#9881;</button>
                        </div>
                        <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                    </div>
                </div>
                <div id="xe-activity" class="metrics-grid">
                    <div class="loading">Loading...</div>
                </div>
            </div>
        </div>
        
        <div class="info-column">
            <!-- Server Info Panel -->
            <div class="section info-panel">
                <div class="section-header">
                    <h2 class="section-title">Server Info</h2>
                    <span class="refresh-badge-action" title="Refreshes on server select">&#128260;</span>
                </div>
                <div id="server-info" class="server-info-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- Disk Space Panel -->
            <div class="section info-panel">
                <div class="section-header">
                    <h2 class="section-title">Disk Space</h2>
                    <span class="refresh-badge-event" title="Refreshes when engine process completes">&#9889;</span>
                </div>
                <div id="disk-space" class="disk-space-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
            
            <!-- AG Health Panel -->
            <div class="section info-panel">
                <div class="section-header">
                    <h2 class="section-title">DMPRODAG Health</h2>
                    <span class="refresh-badge-live" title="Refreshes on live interval"><span class="badge-dot"></span></span>
                </div>
                <div id="ag-health" class="ag-health-content">
                    <div class="loading">Loading...</div>
                </div>
            </div>
        </div>
    </div>
    
    <!-- Zombie Kill Confirmation Modal -->
    <div id="zombie-modal" class="modal hidden" onclick="if(event.target === this) closeZombieModal()">
        <div class="modal-content">
            <div class="modal-header">
                <h3>&#129503; Zombie Eradication</h3>
                <button class="modal-close" onclick="closeZombieModal()">&times;</button>
            </div>
            <div class="modal-body" id="zombie-modal-body">
                <div class="zombie-icon">&#129503;&#128299;</div>
                <div class="zombie-message">
                    Are you sure you want to eradicate<br>
                    <span class="zombie-count" id="zombie-kill-count">0</span> zombies?
                </div>
                <div class="zombie-threshold" id="zombie-threshold-info"></div>
            </div>
            <div class="modal-footer" id="zombie-modal-footer">
                <button class="btn btn-secondary" onclick="closeZombieModal()">Never Mind</button>
                <button class="btn btn-danger" onclick="executeZombieKill()">&#128299; Double Tap Them</button>
            </div>
        </div>
    </div>
    
    <!-- Trend Modal -->
    <div id="trend-modal" class="modal hidden" onclick="if(event.target === this) closeTrendModal()">
        <div class="modal-content wide">
            <div class="modal-header">
                <h3 id="trend-modal-title">Trend</h3>
                <button class="modal-close" onclick="closeTrendModal()">&times;</button>
            </div>
            <div class="modal-body">
                <div class="trend-header">
                    <div class="trend-left">
                        <div class="trend-metric-name" id="trend-metric-name"></div>
                        <div class="trend-range-selector">
                            <button class="trend-range-btn active" data-hours="24" onclick="selectTrendRange(24)">24h</button>
                            <button class="trend-range-btn" data-hours="168" onclick="selectTrendRange(168)">7d</button>
                            <button class="trend-range-btn" data-hours="720" onclick="selectTrendRange(720)">30d</button>
                        </div>
                    </div>
                    <div class="trend-current-value" id="trend-current-value">-</div>
                </div>
                <div id="trend-loading" class="trend-loading hidden">Loading trend data...</div>
                <div class="trend-chart-container">
                    <canvas id="trend-chart"></canvas>
                </div>
                <div class="trend-note" id="trend-aggregation-note"></div>
            </div>
            <div class="modal-footer">
                <button class="btn btn-secondary" onclick="closeTrendModal()">Close</button>
            </div>
        </div>
    </div>
    
    <!-- XE Time Window Selector Modal -->
    <div id="xe-time-modal" class="modal hidden" onclick="if(event.target === this) closeTimeWindowModal()">
        <div class="modal-content">
            <div class="modal-header">
                <h3>XE Time Window</h3>
                <button class="modal-close" onclick="closeTimeWindowModal()">&times;</button>
            </div>
            <div class="modal-body" style="text-align:center;">
                <p style="margin-bottom:15px;color:#888;">Select the time window for Extended Events activity</p>
                <div class="trend-range-selector" style="justify-content:center;">
                    <button class="trend-range-btn xe-time-btn" data-minutes="5" onclick="applyTimeWindow(5)">5m</button>
                    <button class="trend-range-btn xe-time-btn" data-minutes="15" onclick="applyTimeWindow(15)">15m</button>
                    <button class="trend-range-btn xe-time-btn" data-minutes="30" onclick="applyTimeWindow(30)">30m</button>
                    <button class="trend-range-btn xe-time-btn" data-minutes="60" onclick="applyTimeWindow(60)">60m</button>
                </div>
            </div>
            <div class="modal-footer">
                <button class="btn btn-secondary" onclick="closeTimeWindowModal()">Cancel</button>
            </div>
        </div>
    </div>
    
    <!-- Open Transactions Slide Panel -->
    <div id="trans-overlay" class="slide-panel-overlay" onclick="closeTransPanel()"></div>
    <div id="trans-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Open Transactions</h3>
            <button class="modal-close" onclick="closeTransPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="trans-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="copyKillScript()">&#128203; Copy KILL Script</button>
        </div>
    </div>
    
    <!-- Blocking Details Slide Panel -->
    <div id="blocking-overlay" class="slide-panel-overlay" onclick="closeBlockingPanel()"></div>
    <div id="blocking-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Blocking Details</h3>
            <button class="modal-close" onclick="closeBlockingPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="blocking-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="copyBlockerKillScript()">&#128203; Copy KILL Script (Blockers)</button>
        </div>
    </div>
    
    <!-- Active Requests Slide Panel -->
    <div id="requests-overlay" class="slide-panel-overlay" onclick="closeRequestsPanel()"></div>
    <div id="requests-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Active Requests</h3>
            <button class="modal-close" onclick="closeRequestsPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="requests-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="refreshActiveRequests()">&#8635; Refresh</button>
        </div>
    </div>
    
    <!-- XE Long Running Queries Slideout -->
    <div id="xe-lrq-overlay" class="slide-panel-overlay" onclick="closeXELRQPanel()"></div>
    <div id="xe-lrq-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Long Running Queries <span id="xe-lrq-time-window" style="font-size:12px;color:#888;font-weight:normal;"></span></h3>
            <button class="modal-close" onclick="closeXELRQPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="xe-lrq-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="refreshXELRQPanel()">&#8635; Refresh</button>
        </div>
    </div>
    
    <!-- XE Blocking Events Slideout -->
    <div id="xe-blocking-overlay" class="slide-panel-overlay" onclick="closeXEBlockingPanel()"></div>
    <div id="xe-blocking-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Blocking Events <span id="xe-blocking-time-window" style="font-size:12px;color:#888;font-weight:normal;"></span></h3>
            <button class="modal-close" onclick="closeXEBlockingPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="xe-blocking-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="refreshXEBlockingPanel()">&#8635; Refresh</button>
        </div>
    </div>
    
    <!-- XE Deadlock Events Slideout -->
    <div id="xe-deadlock-overlay" class="slide-panel-overlay" onclick="closeXEDeadlockPanel()"></div>
    <div id="xe-deadlock-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Deadlock Events <span id="xe-deadlock-time-window" style="font-size:12px;color:#888;font-weight:normal;"></span></h3>
            <button class="modal-close" onclick="closeXEDeadlockPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="xe-deadlock-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="refreshXEDeadlockPanel()">&#8635; Refresh</button>
        </div>
    </div>
    
    <!-- XE Linked Server Inbound Slideout -->
    <div id="xe-ls-inbound-overlay" class="slide-panel-overlay" onclick="closeXELSInboundPanel()"></div>
    <div id="xe-ls-inbound-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Linked Server Inbound <span id="xe-ls-inbound-time-window" style="font-size:12px;color:#888;font-weight:normal;"></span></h3>
            <button class="modal-close" onclick="closeXELSInboundPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="xe-ls-inbound-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="refreshXELSInboundPanel()">&#8635; Refresh</button>
        </div>
    </div>
    
    <!-- XE Linked Server Outbound Slideout -->
    <div id="xe-ls-outbound-overlay" class="slide-panel-overlay" onclick="closeXELSOutboundPanel()"></div>
    <div id="xe-ls-outbound-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>Linked Server Outbound <span id="xe-ls-outbound-time-window" style="font-size:12px;color:#888;font-weight:normal;"></span></h3>
            <button class="modal-close" onclick="closeXELSOutboundPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="xe-ls-outbound-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="refreshXELSOutboundPanel()">&#8635; Refresh</button>
        </div>
    </div>
    
    <!-- XE AG Health Events Slideout -->
    <div id="xe-ag-events-overlay" class="slide-panel-overlay" onclick="closeXEAGEventsPanel()"></div>
    <div id="xe-ag-events-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>AG Health Events <span id="xe-ag-events-time-window" style="font-size:12px;color:#888;font-weight:normal;"></span></h3>
            <button class="modal-close" onclick="closeXEAGEventsPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="xe-ag-events-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="refreshXEAGEventsPanel()">&#8635; Refresh</button>
        </div>
    </div>
    
    <!-- AG Replica Detail Slideout -->
    <div id="ag-detail-overlay" class="slide-panel-overlay" onclick="closeAGDetailPanel()"></div>
    <div id="ag-detail-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>AG Replica Detail <span id="ag-detail-server" style="font-size:12px;color:#888;font-weight:normal;"></span></h3>
            <button class="modal-close" onclick="closeAGDetailPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="ag-detail-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="refreshAGDetailPanel()">&#8635; Refresh</button>
        </div>
    </div>
    
    <!-- XE System Health Events Slideout -->
    <div id="xe-system-health-overlay" class="slide-panel-overlay" onclick="closeXESystemHealthPanel()"></div>
    <div id="xe-system-health-panel" class="slide-panel wide">
        <div class="slide-panel-header">
            <h3>System Health Events <span id="xe-system-health-time-window" style="font-size:12px;color:#888;font-weight:normal;"></span></h3>
            <button class="modal-close" onclick="closeXESystemHealthPanel()">&times;</button>
        </div>
        <div class="slide-panel-body" id="xe-system-health-panel-body">
            <div class="loading">Loading...</div>
        </div>
        <div class="slide-panel-footer">
            <button class="btn btn-secondary" onclick="refreshXESystemHealthPanel()">&#8635; Refresh</button>
        </div>
    </div>
    
    <script src="/js/server-health.js"></script>
    <script src="/js/engine-events.js"></script>
</body>
</html>
'@
    $html = $html.Replace('</nav>', "$adminGear</nav>")
    Write-PodeHtmlResponse -Value $html
}